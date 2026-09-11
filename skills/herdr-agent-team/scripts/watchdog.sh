#!/usr/bin/env bash
#
# skills/herdr-agent-team/scripts/watchdog.sh
#
# 用法：watchdog.sh [--once]
#
# 職責（規格 §5、§8、§9、§13，Task 12）：事件層的長駐看門狗，一個迴圈
# 四個職責：自動推進、升級、停滯偵測、投遞重試與待補送補投。`--once`
# 只跑一輪就結束，供測試與人工巡檢；不帶參數則以 AGENT_TEAM_POLL_
# SECONDS 為間隔無限迴圈。
#
# ---- 一個迴圈、一個資料來源、兩個時間視野 ----
# 每輪只呼叫一次 `herdr agent list`，經 hat_whitelist_agents 投影後才
# 使用。自動推進看的是「這一輪」的即時狀態；停滯偵測看的是同一份輪詢
# 歷史累積出來的 state_change_seq 變化——兩者共用同一次呼叫，不是兩個
# 各自輪詢的機制。理由：自動推進不能等停滯門檻那麼久，worker 的 CLI 每
# 結束一個回合就閒置，要是等半小時才被推一把，整個團隊會慢到不能用；
# 但停滯偵測本來就需要跨輪比較，沒有第二個獨立輪詢的必要，用同一份歷
# 史算就好。
#
# ---- 為什麼只用 agent list，不用 agent get 或 api snapshot ----
# 三者都拿得到 agent_status 與 state_change_seq 這兩個判斷要用的欄
# 位，但 agent get 一次只回一個目標，team 有 N 個 worker 就要 N 次往
# 返；api snapshot 回的是整個 session 的快照，欄位一樣但量體大得多。
# agent list 一次呼叫拿到全部 agent，是三者裡唯一同時滿足「一次往
# 返」與「量體最小」的。
#
# ---- state_change_seq 是全域共用的遞增計數器，不是每個 agent 各自的
#      計數 ----
# 已實測連續取樣時多個 agent 的值落在同一區間、跨兩個 workspace 交
# 錯。判斷「這個 worker 動了沒」一律比對同一個 worker 前後兩次觀測到
# 的值有沒有改變，不得判斷數值有沒有增加——這個全域序號永遠在增加，
# 「有沒有增加」這個讀法會讓停滯偵測恆真式地失效。跟 wait-peer.sh 的
# 死鎖防護判準是同一個成因，這裡是它的多 worker 版本。
#
# ---- 四個門檻值都能覆寫，而且都沒有實測依據 ----
# AGENT_TEAM_POLL_SECONDS（預設 20）、AGENT_TEAM_STALL_SECONDS（預設
# 1800）、AGENT_TEAM_AUTO_PUSH_LIMIT（預設 10）、AGENT_TEAM_NEEDYOU_
# LIMIT_SECONDS（預設 AGENT_TEAM_STALL_SECONDS 的三倍，見下方「豁免的
# 時間上限」一節）四者皆可用同名環境變數覆寫；四個數字都是私用階段的
# 起點，沒有任何實測依據（規格 §15 未驗清單「摘要長度上限、自動推進上
# 限、空轉判定秒數都是估的」；三倍這個倍數是最終審查修正時拍的，同樣
# 沒有實測依據）。
#
# ---- 停滯門檻的代價 ----
# worker 靜默停住，最壞情況要等滿一個 AGENT_TEAM_STALL_SECONDS 週期才
# 會被偵測到並升級——這個延遲是本設計的已知代價，不是遺漏；把門檻調
# 小會提早發現，但也會提高低保真 kind（agy、opencode，見下方「低保真
# kind」一節）誤判原地繞圈的機率。這件事也會寫進 SKILL.md（Task 14）。
#
# ---- 四個職責，逐一說明 ----
#
# 1. 自動推進：worker 狀態是 idle 或 done、沒有未回覆的 need-you、持
#    有旗標為 false、自動推進計數未達上限 → 直接經 `hat_herdr agent
#    prompt` 送出一則「繼續」，計數加一，orchestrator 完全不知情。不
#    走 instruct.sh：那支腳本會設持有旗標，語意是「orchestrator 正在
#    跟這個 worker 對話」，自動推進正是給沒有人在對話的 worker 用的，
#    走 instruct.sh 會讓每一次自動推進都自己把自己擋掉下一輪。看門狗
#    自己在 registry 根目錄（跟 peer-log/ 同層，不是它裡面）落一行日
#    誌記下推進了誰。
#
#    計數重置：只在收到 delivered 或 orchestrator 送出定案回覆（inbox
#    記錄的 .processed_at 被設值）時歸零；fyi 不歸零，因為要抓的是原
#    地繞圈——如果任何狀態變化都能重置計數，一個不斷 working/idle 交
#    替、每次都只送 fyi 的 worker 永遠不會被判定卡住。實作用一個水位
#    線欄位 .auto_push_reset_seq 記錄「上一次歸零檢查已經看過的最高
#    inbox seq」，只在看到水位線之後出現的 delivered／已處理記錄時才
#    歸零一次，避免同一則 delivered 記錄在後續每一輪都被重複判定成
#    「新的」而把計數重置到 0，讓上限形同虛設（見 lib/common.sh 欄位
#    白名單一節對這個欄位的說明）。
#
# 2. 升級：自動推進計數達上限 → 投遞一則摘要給 orchestrator，不再自
#    動推進。狀態是 blocked → 一律投遞給 orchestrator，不送任何文字下
#    行給那個 worker 本身（文字下行會被 herdr 以 agent_blocked 拒絕，
#    只有代按這條路，而代按需要調查者先讀畫面判讀那個框放行什麼）。
#    狀態是 unknown → 不得自動推進（它不證明工作已完成，可能打斷正在
#    做事的 worker），只有停滯門檻到了才升級。
#
#    「投遞一則摘要給 orchestrator」實作成：在 inbox/ 落一筆記錄
#    （token=fyi、worker=<被升級的那個 worker>），並嘗試呼叫
#    `hat_herdr agent prompt <orchestrator>` 通知 orchestrator——這是
#    best-effort，送不到只是記在 .delivery（同 report.sh「投遞失敗不
#    是本腳本的失敗」一節的既有處理方式），落檔本身已經是持久記錄，
#    不因為這次送不到就遺失。
#
# 3. 停滯偵測：worker 的 state_change_seq 連續超過 AGENT_TEAM_STALL_
#    SECONDS 沒有改變、且狀態落在 idle／done／blocked／unknown 四種
#    之一 → 升級（跟第 2 點共用同一個升級動作）。working 不在這個判斷
#    範圍內：worker 持續做同一件事、狀態沒有轉換時，state_change_seq
#    本來就可能長時間不動，那是正常的，不是停滯。低保真 kind（agy、
#    opencode）必須依賴這一項：它們的 idle 不帶正向證據（herdr 規則檔
#    對這兩種 kind 完全沒有正向 idle 規則，見 lib/common.sh
#    hat_kind_fidelity 檔頭），「違約沒回報就停下」與「原地繞圈」只能
#    靠停滯偵測接住，本腳本不因為 kind 是 low 保真就跳過這一項或降低
#    門檻——目前沒有材料支持一個更精細的門檻，統一沿用同一個
#    AGENT_TEAM_STALL_SECONDS。
#
# 4. 投遞重試與待補送補投：兩種佇列，各自的「對象」不同。
#    a) inbox/ 裡 .delivery 是 blocked 的記錄——這些是 worker 上行時
#       orchestrator 剛好卡在核准框，投遞失敗（見 report.sh 檔頭「投
#       遞失敗不是本腳本的失敗」一節）。這裡的「對象」是 orchestrator
#       自己：只在這一輪觀測到 orchestrator 本人的狀態不是 blocked
#       時才重投，逐筆呼叫 `hat_herdr agent prompt <orchestrator>
#       <summary>`，成功就把該筆 .delivery 改成 delivered。
#    b) workers/*.json 的 .pending_resend 清單——這些是 orchestrator
#       下行時那個 worker 剛好卡在核准框（見 instruct.sh 檔頭
#       「blocked 是待補送」一節）。這裡的「對象」是那個 worker：只在
#       這一輪觀測到它的狀態不是 blocked 時才逐筆補投，每成功一筆就
#       呼叫 hat_remove_pending_resend 移除該筆。持有旗標跟這個佇列清
#       不清空無關，本腳本完全不寫 .held（見 hat_wd_retry_pending_
#       resend 檔頭「最終審查 Critical」一節）。
#
# ---- 豁免：等待 need-you 回覆的 worker 一律豁免自動推進與停滯升級 ----
# 有未回覆 need-you 的 worker 停著是正常的——它在等 orchestrator 決
# 定，不是卡住。豁免範圍包含第 1、3 兩項（第 2 項的 blocked／達上限升
# 級不受影響：核准框與達上限本身就是需要人介入的訊號，跟等 need-you
# 回覆是兩件不同的事，兩者可能同時成立，此時仍要升級）。
#
# ---- 豁免的時間上限：最終審查 Important 修正 ----
# 上面這個豁免原本沒有上限，而它能不能結束完全繫於 orchestrator 有沒
# 有回覆——判準是 inbox 那筆定案請求有沒有被標成已處理，而這個標記只
# 有下行腳本帶 --reply-to 回覆時才會寫。orchestrator（一個 context 固
# 定、會被壓縮的 LLM）若回覆時漏帶這個參數、或根本忘了回，那筆記錄永
# 遠是未處理：該 worker 從此同時豁免自動推進與停滯升級，且
# shutdown-worker.sh 本身也會因為同一筆未回覆記錄拒絕關閉它——三條出
# 口同時關上，全程零訊息。停滯偵測是設計裡「worker 停住而沒人知道」的
# 唯一後盾，尤其對低保真 kind（見第 3 項），把它對「等定案」無上限地
# 關掉，等於假設 orchestrator 永遠不會忘記回覆。
#
# 修法：從這個 worker 名下最早一筆仍未回覆的定案請求算起（用它的
# .created_at），等待超過 AGENT_TEAM_NEEDYOU_LIMIT_SECONDS（預設是
# AGENT_TEAM_STALL_SECONDS 的三倍）就視為豁免到期，不論當下 agent_
# status 是什麼都直接升級，摘要明講「有一則你還沒回的定案請求」，讓
# orchestrator 一看就知道該做什麼。這個檢查獨立於第 3 項的停滯偵測
# （state_change_seq 比對）：等待中的 worker 完全可能持續轉換狀態、
# state_change_seq 一直在動，那套機制永遠不會判定它停滯，因此上限到期
# 這件事不能只靠放寬第 3 項的豁免條件，需要一條不看 state_change_seq
# 的獨立路徑。
#
# ---- 白名單欄位：任何要投遞給 orchestrator 的內容只能是本腳本自己組
#      出來的摘要文字 ----
# hat_whitelist_agents 六個欄位裡沒有 terminal_title／terminal_title_
# stripped（帶的是模型與使用者原文），本腳本組摘要時也只用 worker 名
# 稱、agent_status、門檻數字這些已知安全的值，不會把任何 herdr 原始回
# 應轉發出去。
#
# ---- 單一 worker 的致命失敗不得帶走整個行程：保護放在逐筆的呼叫點 ----
# 競態：`shutdown-worker.sh` 從讀取記錄開始一路持有
# `${worker_file}.lock`，直到最後 `rm -f "$worker_file"` 才放手（見該腳
# 本「參與檔案鎖協定」一節）。`hat_wd_process_worker` 開頭的
# `[ -f "$worker_file" ]` 只證明「進入這一筆的當下」記錄還在；關閉序列
# 完全可以在那之後才跑完，於是本輪後續任何一次寫入——更新
# .last_seq_stamp／.last_seq_changed_at、推進計數、升級時寫 inbox 記
# 錄的 `hat_json_set`，以及補投佇列走的 `hat_remove_pending_resend`
# ——都會在等到鎖之後發現目標檔已經不在，以 `hat_die 5` 結束。那是真正
# 的 `exit`，不是 `return`。
#
# 舊版的後果：這個 `hat_die` 一路傳播出 `hat_wd_run_once`，把底下的
# `while :; do ... done` 整個帶走，自動推進、停滯偵測、投遞重試三項一
# 起停止；沒有重掛機制，也沒有人會發現看門狗已經不在了。這正是本設計
# 最想消滅的失效形狀，成因跟 `hat_wd_process_worker`「修正迴圈第一輪」
# 那一節同一類：原則寫在檔頭，沒有寫進控制流程——當時只有 workspace 那
# 一道守衛被包進子殼，寫入這條路徑完全沒有被涵蓋。
#
# 保護放在哪一層：放在 `hat_wd_run_once` 逐筆呼叫
# `hat_wd_process_worker` 的那一個點，整次呼叫包進子殼，而不是逐一包住
# 每個 `hat_json_set`。三個理由——一、要擋的不是某幾個特定呼叫，而是
# 「處理這一筆時發生致命失敗」這整個類別：逐一包只保護得到今天數得出
# 來的呼叫點（光 `hat_wd_escalate` 內部就有七次 `hat_json_set`，補投走
# 的又是另一個同樣會 `hat_die 5` 的函式），明天多一個寫入就漏一個，而
# 漏掉的代價是整個行程再次靜默消失。二、這一筆的記錄既然已經讀不到，
# 後面所有評估都建立在不存在的狀態上，本來就該整筆放棄，沒有「跳過這
# 一句、繼續往下做」這種中間語意。三、`hat_wd_process_worker` 全程只用
# local 變數、狀態一律落在檔案上，子殼不會吞掉任何該留下的變動：已經
# 寫出去的部分照樣留著，跟原本中止在同一個點的結果一致。
#
# 被跳過的那一筆在 registry 根目錄的 watchdog.log 留一行
# `skip worker=... reason=process_failed rc=... at=...`（欄位風格沿用
# 同一個檔案既有的 skip／auto-push 行）。子殼的 stderr 刻意不攔截，
# `hat_die` 印出的原始訊息照樣出得來：日誌行負責「哪一筆、什麼時候、
# 以什麼結束碼」這種事後追得到的骨架，原始訊息負責「是哪個函式、哪個
# 欄位、哪個檔案」這種細節，兩者缺一都追不完整。
#
# 跟 `hat_wd_process_worker` 入口那道 workspace 子殼的關係：兩道並存，
# 不是重複。內層那一道處理的是一個已知且良性的情況（座標對不上或缺
# 席），它吞掉 `hat_assert_workspace` 的 stderr、缺座標時另外落一行語
# 意明確的 `reason=missing_pane_id`；外層這一道是對「其餘任何致命失
# 敗」的兜底。拿掉內層不會讓行程掛掉，但會把一個已經分類好的情況降級
# 成不明失敗，日誌多噪音而少資訊。
#
# ---- `--once` 與長駐模式一律同樣處理，不分模式 ----
# `hat_wd_process_worker`「入口守衛」一節提到的「一次性腳本才維持中止
# 語意」，區分的是 instruct.sh／press-approval.sh 那種「呼叫端指定單一
# target」的腳本與本腳本這種「一輪掃過全部 worker」的腳本，不是同一支
# 腳本的兩種跑法：`--once` 就是這個長駐迴圈的一次迭代，它照樣要掃過每
# 一個 worker，一筆壞掉就讓其餘 worker 這一輪完全沒被看到，代價跟長駐
# 模式的單輪一模一樣。另一個決定性的理由是可測性：測試只能從 `--once`
# 進來（長駐模式要背景行程加 kill 才測得到），`--once` 若改回中止語
# 意，這道保護在唯一測得到的路徑上等於從來沒有被驗證過。
#
# 這使 `--once` 有一處明確改變的行為，在此寫明而不是無聲帶過：以前一
# 筆 worker 記錄在處理途中消失，會讓整個指令以 5 結束、其餘 worker 不
# 再被處理；現在改成以 0 結束、其餘照常處理。診斷不因此減少——`hat_
# die` 的原始訊息仍然印在 stderr，另外多一行持久的 watchdog.log 記錄。
# 受影響的是「用結束碼判斷這一輪有沒有出事」這個讀法，改判準為「看
# watchdog.log 這一輪有沒有多出 skip 行」。附帶一提，記錄在處理途中消
# 失多半根本不是故障，而是一次成功的 `shutdown-worker.sh` 剛好跟這一輪
# 重疊，用非 0 結束碼回報它本來就偏重。
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

hat_require_herdr_env

readonly HAT_POLL_SECONDS_DEFAULT=20
readonly HAT_STALL_SECONDS_DEFAULT=1800
readonly HAT_AUTO_PUSH_LIMIT_DEFAULT=10

poll_seconds="${AGENT_TEAM_POLL_SECONDS:-$HAT_POLL_SECONDS_DEFAULT}"
stall_seconds="${AGENT_TEAM_STALL_SECONDS:-$HAT_STALL_SECONDS_DEFAULT}"
auto_push_limit="${AGENT_TEAM_AUTO_PUSH_LIMIT:-$HAT_AUTO_PUSH_LIMIT_DEFAULT}"

case "$poll_seconds" in
  '' | *[!0-9]*) hat_die 2 "watchdog.sh: AGENT_TEAM_POLL_SECONDS 必須是純數字秒數，收到：$poll_seconds" ;;
esac
case "$stall_seconds" in
  '' | *[!0-9]*) hat_die 2 "watchdog.sh: AGENT_TEAM_STALL_SECONDS 必須是純數字秒數，收到：$stall_seconds" ;;
esac
case "$auto_push_limit" in
  '' | *[!0-9]*) hat_die 2 "watchdog.sh: AGENT_TEAM_AUTO_PUSH_LIMIT 必須是純數字，收到：$auto_push_limit" ;;
esac

# 預設是 stall_seconds 的三倍（見檔頭「豁免的時間上限」一節）；算預設
# 值之前 stall_seconds 已經過上面的純數字檢查，這裡的算術是安全的。
needyou_limit_seconds="${AGENT_TEAM_NEEDYOU_LIMIT_SECONDS:-$((stall_seconds * 3))}"
case "$needyou_limit_seconds" in
  '' | *[!0-9]*) hat_die 2 "watchdog.sh: AGENT_TEAM_NEEDYOU_LIMIT_SECONDS 必須是純數字秒數，收到：$needyou_limit_seconds" ;;
esac

once=0
if [ "$#" -eq 1 ] && [ "$1" = "--once" ]; then
  once=1
elif [ "$#" -gt 0 ]; then
  hat_die 2 "watchdog.sh: 用法：watchdog.sh [--once]"
fi

# hat_json_string <text>
# 把任意文字安全地轉成一個 JSON 字串字面並印出來。用法與理由同
# report.sh／instruct.sh／set-goal.sh／launch-worker.sh 的同名局部函
# 式：各腳本各自獨立定義，不共用。
hat_json_string() {
  jq -Rn --arg v "$1" '$v'
}

# hat_watchdog_allocate_seq <registry_root>
# 在 <registry_root>/team.json.lock 的鎖保護下，從 team.json 的
# next_seq 取號並遞增，印出取到的號碼。手法與鎖檔路徑沿用 report.sh
# 的 hat_allocate_seq（理由見該函式檔頭「序號配發」一節：取號是
# fetch-and-increment，不透過 hat_json_set；鎖檔路徑必須跟
# hat_json_set 用的同一條，否則各自序列化、彼此不排隊，等於沒鎖）。
hat_watchdog_allocate_seq() {
  local registry_root="$1" team_json lock_file lock_fd tmp seq new_seq

  team_json="$registry_root/team.json"
  lock_file="${team_json}.lock"

  lock_fd=""
  exec {lock_fd}>"$lock_file"
  flock -x "$lock_fd"

  seq="$(jq -r '.next_seq // 1' "$team_json" 2>/dev/null)" || seq=""
  case "$seq" in
    '' | *[!0-9]*)
      hat_die 5 "watchdog.sh: team.json 的 next_seq 不是合法的十進位整數：'$seq'" ;;
  esac
  new_seq=$((seq + 1))

  tmp="$(mktemp "${team_json}.XXXXXX")" || hat_die 5 "watchdog.sh: 無法建立暫存檔，取號失敗：$team_json"
  if ! { jq --argjson v "$new_seq" '.next_seq = $v' "$team_json" > "$tmp" && mv "$tmp" "$team_json"; }; then
    rm -f "$tmp"
    hat_die 5 "watchdog.sh: 寫入失敗（jq 解析或置換未成功），next_seq 未遞增：$team_json"
  fi

  exec {lock_fd}>&-
  printf '%s\n' "$seq"
}

# hat_wd_lookup <whitelisted_tsv> <name>
# 從 hat_whitelist_agents 的六欄 TSV 輸出裡篩出 name 欄等於 <name> 的
# 那一行；找不到印空字串。
hat_wd_lookup() {
  local whitelisted="$1" name="$2"
  printf '%s\n' "$whitelisted" | awk -F'\t' -v n="$name" '$1 == n'
}

# hat_wd_needyou_pending <registry_root> <worker>
# <worker> 在 inbox/ 裡有沒有屬於自己、token 是 need-you、且
# processed_at 仍是 JSON null 的紀錄（見檔頭「豁免」一節）。找到印
# "1"，否則印 "0"。手法沿用 shutdown-worker.sh 的 hat_need_you_
# pending（各腳本各自獨立定義，不共用，理由同本腳本其餘小型輔助函
# 式）。
hat_wd_needyou_pending() {
  local registry_root="$1" worker="$2" f token who processed

  while IFS= read -r -d '' f; do
    token="$(jq -r '.token // empty' "$f")"
    who="$(jq -r '.worker // empty' "$f")"
    processed="$(jq -r '.processed_at' "$f")"
    if [ "$token" = "need-you" ] && [ "$who" = "$worker" ] && [ "$processed" = "null" ]; then
      printf '1\n'
      return 0
    fi
  done < <(find "$registry_root/inbox" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)

  printf '0\n'
}

# hat_wd_needyou_oldest_created_at <registry_root> <worker>
# <worker> 名下最早一筆仍未回覆（token=need-you、processed_at 仍是
# JSON null）的定案請求，印出它的 .created_at（report.sh／本腳本一律
# 寫成 `date -u +%Y-%m-%dT%H:%M:%SZ` 這個固定格式）；沒有這種記錄則印
# 空字串。用途見檔頭「豁免的時間上限」一節。ISO 8601 UTC 字串照字典序
# 排序就是時間序，直接用 `[[ < ]]` 比大小取最早一筆，不需要先各自轉成
# epoch。
hat_wd_needyou_oldest_created_at() {
  local registry_root="$1" worker="$2" f token who processed created oldest

  oldest=""
  while IFS= read -r -d '' f; do
    token="$(jq -r '.token // empty' "$f")"
    who="$(jq -r '.worker // empty' "$f")"
    processed="$(jq -r '.processed_at' "$f")"
    if [ "$token" = "need-you" ] && [ "$who" = "$worker" ] && [ "$processed" = "null" ]; then
      created="$(jq -r '.created_at // empty' "$f")"
      [ -n "$created" ] || continue
      if [ -z "$oldest" ] || [[ "$created" < "$oldest" ]]; then
        oldest="$created"
      fi
    fi
  done < <(find "$registry_root/inbox" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)

  printf '%s\n' "$oldest"
}

# hat_wd_escalate <registry_root> <orchestrator_name> <worker> <summary>
# 見檔頭「升級」一節：落一筆 inbox 記錄（token=fyi，worker=<worker>），
# 並 best-effort 呼叫 hat_herdr agent prompt 通知 orchestrator。
hat_wd_escalate() {
  local registry_root="$1" orchestrator_name="$2" worker="$3" summary="$4"
  local seq inbox_file created_at rc

  seq="$(hat_watchdog_allocate_seq "$registry_root")"
  inbox_file="$registry_root/inbox/${seq}-${worker}.json"
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  printf '{}' > "$inbox_file"
  hat_json_set "$inbox_file" '.token' '"fyi"'
  hat_json_set "$inbox_file" '.worker' "$(hat_json_string "$worker")"
  hat_json_set "$inbox_file" '.summary' "$(hat_json_string "$summary")"
  hat_json_set "$inbox_file" '.detail_path' 'null'
  hat_json_set "$inbox_file" '.locator' 'null'
  hat_json_set "$inbox_file" '.created_at' "$(hat_json_string "$created_at")"

  rc=0
  if [ -n "$orchestrator_name" ]; then
    hat_herdr agent prompt "$orchestrator_name" "$summary" >/dev/null || rc=$?
  else
    rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    hat_json_set "$inbox_file" '.delivery' '"delivered"'
  else
    hat_json_set "$inbox_file" '.delivery' '"blocked"'
  fi
}

# hat_wd_apply_auto_push_reset <registry_root> <worker> <worker_file>
# 見檔頭「計數重置」一節：掃 <worker> 在 inbox/ 裡 seq 大於水位線
# （.auto_push_reset_seq，缺席視為 0）的記錄，任何一筆 token=delivered
# 或 .processed_at 非 null（orchestrator 送出定案回覆）就把
# .auto_push_count 歸零；不論有沒有歸零都把水位線推到這一輪看過的最
# 大 seq，避免同一筆記錄在下一輪被重複判定成「新的」。
hat_wd_apply_auto_push_reset() {
  local registry_root="$1" worker="$2" worker_file="$3"
  local last_seen latest_seq reset_needed f who base seq token processed

  last_seen="$(jq -r '.auto_push_reset_seq // 0' "$worker_file")"
  latest_seq="$last_seen"
  reset_needed=0

  while IFS= read -r -d '' f; do
    who="$(jq -r '.worker // empty' "$f")"
    [ "$who" = "$worker" ] || continue

    base="$(basename "$f")"
    seq="${base%%-*}"
    case "$seq" in *[!0-9]*) continue ;; esac
    [ "$seq" -gt "$last_seen" ] || continue

    if [ "$seq" -gt "$latest_seq" ]; then
      latest_seq="$seq"
    fi

    token="$(jq -r '.token // empty' "$f")"
    processed="$(jq -r '.processed_at' "$f")"
    if [ "$token" = "delivered" ] || [ "$processed" != "null" ]; then
      reset_needed=1
    fi
  done < <(find "$registry_root/inbox" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)

  if [ "$latest_seq" != "$last_seen" ]; then
    hat_json_set "$worker_file" '.auto_push_reset_seq' "$latest_seq"
  fi
  if [ "$reset_needed" -eq 1 ]; then
    hat_json_set "$worker_file" '.auto_push_count' '0'
  fi
}

# hat_wd_retry_blocked_inbox <registry_root> <orchestrator_name> <whitelisted>
# 見檔頭「投遞重試與待補送補投」a) 一節：inbox/ 裡 .delivery 是
# blocked 的記錄，orchestrator 目前不是 blocked 時逐筆重投一次。
# orchestrator 這一輪查無觀測值（未知）時保守跳過，不猜測。
hat_wd_retry_blocked_inbox() {
  local registry_root="$1" orchestrator_name="$2" whitelisted="$3"
  local orch_line orch_status f delivery worker summary rc

  [ -n "$orchestrator_name" ] || return 0

  orch_line="$(hat_wd_lookup "$whitelisted" "$orchestrator_name")"
  orch_status=""
  if [ -n "$orch_line" ]; then
    orch_status="$(printf '%s' "$orch_line" | cut -f3)"
  fi
  if [ -z "$orch_status" ] || [ "$orch_status" = "blocked" ]; then
    return 0
  fi

  while IFS= read -r -d '' f; do
    delivery="$(jq -r '.delivery // empty' "$f")"
    [ "$delivery" = "blocked" ] || continue

    worker="$(jq -r '.worker // empty' "$f")"
    summary="$(jq -r '.summary // empty' "$f")"
    [ -n "$worker" ] || continue

    rc=0
    hat_herdr agent prompt "$orchestrator_name" "$summary" >/dev/null || rc=$?
    if [ "$rc" -eq 0 ]; then
      hat_json_set "$f" '.delivery' '"delivered"'
    fi
  done < <(find "$registry_root/inbox" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)
}

# hat_wd_retry_pending_resend <worker> <worker_file> <whitelisted>
# 見檔頭「投遞重試與待補送補投」b) 一節：<worker> 目前不是 blocked
# 時，逐筆嘗試補投 .pending_resend 佇列，每成功一筆就移除該筆；一旦
# 有一筆失敗（例如又卡進 blocked），停止處理這個 worker 剩下的佇列，
# 留給下一輪。
#
# ---- 最終審查 Critical：本函式不寫 .held，佇列清空跟持有旗標無關 ----
# 舊版在佇列清空後無條件把 .held 寫回 false，理由是「沒清空代表還有
# 訊息沒補投出去，orchestrator 仍在跟它對話中」——但這個推論反過來不成
# 立：佇列為空是 instruct.sh 送出下行期間的正常狀態（它只有在收到
# agent_blocked 才會入列，而那條路徑本身就會把 .held 設回 false，見該
# 腳本「blocked 是待補送」一節）。持有旗標的語意是「orchestrator 正在
# 跟這個 worker 對話，這個空窗期不要有第三則訊息插進來」，設不設、收
# 不收全由下行腳本自己決定，不是「待補送佇列還沒清空」的衍生欄位。舊
# 版把兩者混為一談的後果：審查者用樁重現過——旗標為真、佇列為空、狀態
# 閒置這個組合下跑一輪，旗標被清成 false、自動推進計數加一、且真的送
# 出了一則「繼續」，直接踩爛下行腳本剛設下的持有窗口。修法是本函式完
# 全不寫 .held，讓這個欄位回到單一語意：orchestrator 端腳本設它，中斷
# 恢復由 team-init.sh --recover 收回殘留（規格 §13 第 3 步），看門狗
# 不再是第三個寫入端（連帶更新 lib/common.sh 欄位白名單一節的分配表註
# 解）。
hat_wd_retry_pending_resend() {
  local worker="$1" worker_file="$2" whitelisted="$3"
  local line status entry text rc

  [ -f "$worker_file" ] || return 0

  line="$(hat_wd_lookup "$whitelisted" "$worker")"
  status=""
  if [ -n "$line" ]; then
    status="$(printf '%s' "$line" | cut -f3)"
  fi
  if [ "$status" = "blocked" ]; then
    return 0
  fi

  while :; do
    entry="$(jq -c '(.pending_resend // [])[0] // empty' "$worker_file")"
    [ -n "$entry" ] || break

    text="$(printf '%s' "$entry" | jq -r '.text')"

    rc=0
    hat_herdr agent prompt "$worker" "$text" >/dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
      break
    fi

    hat_remove_pending_resend "$worker_file"
  done
}

# hat_wd_process_worker <registry_root> <orchestrator_name> <worker> \
#   <whitelisted> <stall_seconds> <auto_push_limit> <needyou_limit_seconds>
# 對單一 worker 依序執行：4b) 待補送補投 → 讀取這一輪觀測值 → 更新
# stamp 追蹤 → 豁免的時間上限到期就直接升級（檔頭同名一節，不看
# status） → 3) 停滯偵測（內建豁免） → 2) blocked／達上限升級（不受豁
# 免影響） → unknown 直接跳過 → 豁免檢查（只擋第 1 項） → 1) 自動推
# 進。先做補投，把上一輪卡住、這一輪解除的下行儘快送出；持有旗標由下
# 行腳本自己收放，本函式的執行順序不會改變它的值（見 hat_wd_retry_
# pending_resend 檔頭「最終審查 Critical」一節），因此這個順序跟後面
# 的自動推進評估互不影響，純粹是「先把積壓的事做完」。
#
# ---- 修正迴圈第一輪：豁免檢查不得排在 2) 之前 ----
# 檔頭「豁免」一節承諾「豁免範圍包含第 1、3 兩項，第 2 項的 blocked／
# 達上限升級不受影響，兩者可能同時成立，此時仍要升級」；上一版把豁免
# 檢查寫成一句涵蓋全部後續分支的無條件 `return`，擋在 2) 之前，等於把
# 這句承諾寫在檔頭、卻沒有寫進控制流程。後果：一個有未回覆 need-you
# 的 worker，若之後又撞上一個完全不相干的核准框（agent_status 變成
# blocked），會被豁免直接放行、blocked 升級整段不會執行——這正是設計
# 最想消滅的失效形狀（卡住、沒人知道、沒有任何訊息），已用審查回合的
# mutation 實測重現並修正，見任務報告。修法：blocked 與達上限這兩個
# 「2) 升級」的分支都挪到豁免檢查之前，豁免檢查本身只留在「1) 自動推
# 進」的實際送出動作前面，不再是一句擋住後面所有分支的早退。
hat_wd_process_worker() {
  local registry_root="$1" orchestrator_name="$2" worker="$3" whitelisted="$4"
  local stall_seconds="$5" auto_push_limit="$6" needyou_limit_seconds="$7"
  local worker_file pane_id line status stamp held needyou_pending
  local last_stamp last_changed_at now elapsed auto_push_count new_count rc
  local needyou_expired needyou_created_at needyou_created_epoch needyou_wait_elapsed

  worker_file="$registry_root/workers/$worker.json"
  [ -f "$worker_file" ] || return 0

  # ---- 入口守衛：跟 team-status.sh 同一個理由——一次要處理本 team 全
  #      部 worker，一筆記錄的座標對不上就不該讓 hat_assert_workspace
  #      的 hat_die 4 把整個看門狗行程帶走（`--once` 之外的長駐模式下
  #      那等於整個團隊都停止被照看），因此包在子殼裡捕捉失敗、只跳
  #      過這一筆，`hat_assert_workspace` 本身仍然被呼叫到；座標缺席
  #      時也視同守衛沒通過（見 team-status.sh 同名一節「最終審查修
  #      正」——缺座標比座標對不上更可疑，不當成通過），跳過該筆並記一
  #      行日誌到 watchdog.log ----
  pane_id="$(jq -r '.pane_id // empty' "$worker_file")"
  if [ -z "$pane_id" ]; then
    printf 'skip worker=%s reason=missing_pane_id at=%s\n' "$worker" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      >> "$registry_root/watchdog.log"
    return 0
  fi
  if ! ( hat_assert_workspace "$pane_id" ) 2>/dev/null; then
    return 0
  fi

  hat_wd_retry_pending_resend "$worker" "$worker_file" "$whitelisted"

  line="$(hat_wd_lookup "$whitelisted" "$worker")"
  if [ -z "$line" ]; then
    # 這一輪的 agent list 裡找不到這個已註冊的 worker（名稱可能被清
    # 空，或暫時性的列表落差），沒有觀測值可用，跳過這一輪的自動推
    # 進／升級／停滯評估，下一輪再看。
    return 0
  fi

  status="$(printf '%s' "$line" | cut -f3)"
  stamp="$(printf '%s' "$line" | cut -f4)"
  held="$(jq -r '.held // false' "$worker_file")"
  needyou_pending="$(hat_wd_needyou_pending "$registry_root" "$worker")"

  now="$(date +%s)"
  last_stamp="$(jq -r '.last_seq_stamp // empty' "$worker_file")"
  last_changed_at="$(jq -r '.last_seq_changed_at // empty' "$worker_file")"

  if [ -z "$last_stamp" ] || [ "$stamp" != "$last_stamp" ]; then
    hat_json_set "$worker_file" '.last_seq_stamp' "$(hat_json_string "$stamp")"
    hat_json_set "$worker_file" '.last_seq_changed_at' "$now"
    last_changed_at="$now"
  fi

  # ---- 豁免的時間上限（檔頭同名一節）：不看 status，從最早一筆仍未回
  #      覆的定案請求算起，超過 needyou_limit_seconds 就直接升級，不透
  #      過第 3 項的 state_change_seq 比對——等待中的 worker 可能持續轉
  #      換狀態，那套機制永遠不會判定它停滯 ----
  needyou_expired=0
  if [ "$needyou_pending" = "1" ]; then
    needyou_created_at="$(hat_wd_needyou_oldest_created_at "$registry_root" "$worker")"
    if [ -n "$needyou_created_at" ]; then
      needyou_created_epoch="$(date -d "$needyou_created_at" +%s 2>/dev/null)" || needyou_created_epoch=""
      if [ -n "$needyou_created_epoch" ]; then
        needyou_wait_elapsed=$((now - needyou_created_epoch))
        if [ "$needyou_wait_elapsed" -ge "$needyou_limit_seconds" ]; then
          needyou_expired=1
        fi
      fi
    fi
  fi
  if [ "$needyou_expired" -eq 1 ]; then
    hat_wd_escalate "$registry_root" "$orchestrator_name" "$worker" \
      "worker=$worker 有一則你還沒回的定案請求（need-you）已經等了 ${needyou_wait_elapsed}s（上限 ${needyou_limit_seconds}s），豁免到期，改為升級"
    return 0
  fi

  # ---- 3：停滯偵測（見檔頭同名一節；豁免見「豁免」一節）----
  case "$status" in
    idle | done | blocked | unknown)
      if [ -n "$last_changed_at" ]; then
        elapsed=$((now - last_changed_at))
        if [ "$elapsed" -ge "$stall_seconds" ] && [ "$needyou_pending" != "1" ]; then
          hat_wd_escalate "$registry_root" "$orchestrator_name" "$worker" \
            "worker=$worker 已停滯 ${elapsed}s（門檻 ${stall_seconds}s），狀態=$status，state_change_seq 沒有改變"
          return 0
        fi
      fi
      ;;
  esac

  # ---- 2a：blocked 一律升級，不受 need-you 豁免影響（見上方「修正迴
  #      圈第一輪」一節）；不送文字下行給這個 worker ----
  if [ "$status" = "blocked" ]; then
    hat_wd_escalate "$registry_root" "$orchestrator_name" "$worker" \
      "worker=$worker 卡在核准框（agent_status=blocked），文字下行會被拒絕，需要調查者讀畫面代按"
    return 0
  fi

  # ---- unknown：不得自動推進，停滯門檻由上面的停滯偵測負責 ----
  if [ "$status" != "idle" ] && [ "$status" != "done" ]; then
    return 0
  fi

  if [ "$held" = "true" ]; then
    return 0
  fi

  # ---- 2b：達上限升級，同樣不受 need-you 豁免影響，因此先套用計數重
  #      置、算出目前計數，再判斷是否已達上限——這一步排在豁免檢查之
  #      前（見上方「修正迴圈第一輪」一節）----
  hat_wd_apply_auto_push_reset "$registry_root" "$worker" "$worker_file"
  auto_push_count="$(jq -r '.auto_push_count // 0' "$worker_file")"

  if [ "$auto_push_count" -ge "$auto_push_limit" ]; then
    hat_wd_escalate "$registry_root" "$orchestrator_name" "$worker" \
      "worker=$worker 自動推進已達上限 ${auto_push_limit} 次仍是 $status，改為升級"
    return 0
  fi

  # ---- 豁免：等 need-you 回覆的 worker 不自動推進（只擋這一項，見上
  #      方「修正迴圈第一輪」一節）----
  if [ "$needyou_pending" = "1" ]; then
    return 0
  fi

  # ---- 1：自動推進 ----
  rc=0
  hat_herdr agent prompt "$worker" "繼續" >/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then
    new_count=$((auto_push_count + 1))
    hat_json_set "$worker_file" '.auto_push_count' "$new_count"
    printf 'auto-push worker=%s count=%s at=%s\n' "$worker" "$new_count" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      >> "$registry_root/watchdog.log"
  fi
}

# hat_wd_run_once
# 跑一輪：一次 agent list、4a) inbox 上行重投、逐一處理每個已知
# worker。逐筆處理包在子殼裡、失敗只跳過那一筆並記一行日誌，理由與
# `--once` 的語意見檔頭「單一 worker 的致命失敗不得帶走整個行程」與
# 「`--once` 與長駐模式一律同樣處理」兩節。
hat_wd_run_once() {
  local registry_root team_json orchestrator_name agents_json whitelisted worker rc

  registry_root="$(hat_registry_root)"
  team_json="$registry_root/team.json"
  orchestrator_name="$(jq -r '.orchestrator_name // empty' "$team_json" 2>/dev/null || true)"

  agents_json="$(hat_herdr agent list)"
  whitelisted="$(hat_whitelist_agents "$agents_json")"

  hat_wd_retry_blocked_inbox "$registry_root" "$orchestrator_name" "$whitelisted"

  while IFS= read -r worker; do
    [ -n "$worker" ] || continue
    # 整次呼叫包進子殼：`hat_wd_process_worker` 底下任何一個 hat_die
    # （最常見的是 worker 記錄被 shutdown-worker.sh 移除後，寫入函式撞
    # 上目標檔已不存在而以 5 結束）只結束這個子殼，不會把長駐迴圈帶
    # 走。`|| rc=$?` 而不是裸呼叫：errexit 之下裸呼叫失敗會直接終止本
    # 行程，結束碼根本讀不到。stderr 不攔截，hat_die 的原始訊息照樣外
    # 流（見檔頭同名一節）。
    rc=0
    ( hat_wd_process_worker "$registry_root" "$orchestrator_name" "$worker" "$whitelisted" \
        "$stall_seconds" "$auto_push_limit" "$needyou_limit_seconds" ) || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf 'skip worker=%s reason=process_failed rc=%s at=%s\n' \
        "$worker" "$rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        >> "$registry_root/watchdog.log"
    fi
  done < <(hat_worker_list)
}

if [ "$once" -eq 1 ]; then
  hat_wd_run_once
  exit 0
fi

while :; do
  hat_wd_run_once
  sleep "$poll_seconds"
done
