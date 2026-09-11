#!/usr/bin/env bash
#
# skills/herdr-agent-team/scripts/report.sh
#
# 用法：
#   report.sh --token <ack|working|fyi|need-you|delivered|done> \
#     --summary <一行> [--detail-file <路徑>] [--locator <字串>] \
#     [--state-dir <路徑>] [--wait-timeout <秒>]
#
# 職責（規格 §8、2.5）：worker 上行唯一入口。
#
# ---- 這支腳本在整個設計裡的位置：它是收斂閥，不是轉發環節 ----
# orchestrator 的 context 是固定的，worker 的產出量沒有上限。本腳本把
# 一則回報拆成「一行摘要」與「無界的細節」，只把摘要往上送，細節落在
# 磁碟上等調查者來取——**拆信發生在這支腳本裡**，不是另外一個「看門狗
# 讀 inbox 再轉發」的環節：那一跳不會帶來對應的價值，卻多一個必須活著
# 的環節，而它死掉時是靜默的。看門狗（Task 12）只在投遞失敗
# （agent_blocked）時介入重試，不負責轉發摘要本身。
#
# `working` 這個 token 只落檔、絕不投遞：它的量體是其餘五個（ack、
# fyi、need-you、delivered、done）加起來的百倍，擋掉它是整個設計成立
# 的前提，不是效能優化。
#
# ---- 投遞不帶任何握手選項 ----
# 已實測（規格 2.5）：`agent prompt` 若帶 `--wait`／`--until`／
# `--timeout` 這類握手選項，從一個非 working 狀態送出時必須在 5 秒內
# 產生可觀測的狀態變化，否則 herdr 回 `agent_prompt_stalled` 而非無限
# 等待。上行不需要任何握手憑據——我們不在乎 orchestrator 什麼時候讀
# 到，只在乎訊息有沒有被接受——不帶這些選項就完全沒有 `agent_prompt_
# stalled` 這個歧義狀態要處理，唯一要判別的失敗是「對方卡在核准框而以
# `agent_blocked` 拒絕」。因此本腳本的投遞呼叫絕對不加這三個選項。
#
# ---- 投遞失敗（agent_blocked）不是本腳本的失敗，但不能完全靜默 ----
# 編排端已裁決採納本次實作原本的判斷：落檔成功之後，投遞是
# best-effort——失敗（不論是 agent_blocked 還是任何其他 herdr 拒絕）只
# 記在該筆 inbox 記錄的 `.delivery` 欄位（"blocked"），本腳本仍以 0 結
# 束。理由：規格明講「看門狗只在投遞失敗時介入重試」，重試責任已經明
# 確歸給看門狗，不歸呼叫端（worker）；若本腳本此時回報失敗，worker 很
# 可能誤判成「這則回報整個沒有送出」而重新呼叫一次，造成 inbox 出現重
# 複記錄、`next_seq` 被多耗用一個號碼；而且那則回報已經 durable 地落
# 在磁碟上，從 worker 的角度它確實已經被系統接受了。落檔本身（寫
# inbox／details）才是本腳本自己要對呼叫端負責的部分：那個失敗才真的
# 以非 0 結束（見下方各步驟）。
#
# 修正迴圈第一輪新增的要求：投遞被判定 blocked 時，必須在 stdout 印一
# 行明講「已記錄、投遞延後」。單純把結束碼留在 0、卻什麼都不印，會讓
# worker 誤以為 orchestrator 已經看到這則回報了，而它其實還躺在佇列裡
# 等看門狗補投——結束碼的沉默和這裡要擋的其中一種「完全靜默的錯誤」是
# 同一種類，只是換了個位置。
#
# ---- ACK 的固定摘要格式：本腳本不產生，但 ack 這個 token 一律豁免長
#      度上限 ----
# `worker_id=<id> cwd=<絕對路徑> model=<名稱>`（Global Constraints、
# launch-worker.sh 檔頭「ACK 摘要格式」一節）是 worker 依啟動包自己組
# 出來的，本腳本只是把它當成一般摘要處理。
#
# 修正迴圈第二輪：這裡原本以為「500 字元的上限對這個格式綽綽有餘，不
# 需要特殊分支」，但那個估計只算了 32 字元封頂的 worker id 與簡短的
# model 名稱，沒有把 cwd 這個變數算進去——已實測一個合法的 575 字元
# ack 格式字串（worktree 慣例下的深路徑就會產生這種長度）被原本無豁免
# 的版本直接以結束碼 2 拒絕、完全不落檔，比截斷更嚴重：launch-worker.sh
# 第 8 步的對帳會找不到任何一行可解析的內容。裁決是 `ack` 這個 token
# 一律豁免摘要長度上限，不是把上限調高——它是機器產生的固定三欄格
# 式，長度由 cwd 路徑決定，不是 worker 自由發揮的散文，上限存在的理由
# （擋住 worker 把無界內容塞進摘要）在它身上根本不成立，調高上限只是
# 換一個更大的、遲早還是會被更深路徑撞到的數字。
#
# ---- 摘要長度上限：拒絕，不截斷 ----
# 上限預設 500 字元，可用 AGENT_TEAM_SUMMARY_MAX 覆寫；**這個數字沒有
# 任何實測依據**，是私用階段的起點（規格 §15 未驗清單「摘要長度上限、
# 自動推進上限、空轉判定秒數都是估的」）。字元數而非位元組數：本環境
# 預設 locale 是 zh_TW.UTF-8，已實測 bash 的 `${#var}` 在這個 locale
# 下對多位元組字元正確地數字元（而非位元組），符合規格文字「500 字
# 元」的字面意思；換算方式依賴呼叫端所在 shell 的 locale 設定為
# UTF-8，本腳本不強制切換 locale。
#
# ---- need-you 阻塞等待：逾時不是失敗 ----
# 每 2 秒看一次那個固定檔名的回覆檔案是否出現，上限預設 540000 毫秒
# （9 分鐘）。9 分鐘的依據
# 是 Claude Code 的工具逾時上限是 600000 毫秒，留一分鐘餘裕；其餘三家
# CLI 的上限沒有查證，不能假設更寬（見背景說明，規格 §15 同一份未驗清
# 單的呼應）。逾時以 7 結束並印出提示：已上報、未在時限內收到回覆、請
# 結束回合等下行——worker 退回一般的停等模式，由看門狗接手升級，不是
# 這支腳本的失敗。
#
# ---- need-you 的等待對象：只看這一次呼叫自己配到的 seq ----
# 修正迴圈第一輪：本檔曾經改成「看 replies/<self>/ 整個目錄，找到任何
# 一個檔案就算數」，理由是誤以為這樣才能接住「上一輪逾時、下一輪換了
# 新 seq 再問」的情境。編排端已裁決這是錯的，散文原本的字面讀法（只看
# 自己這次配到的 seq）才對，理由是這個「整個目錄」讀法會製造一個完全
# 靜默的錯誤答案來源：worker 問完第一個問題（seq=N）沒等到回覆就逾時退
# 場；下一輪換了新問題（seq=N+1）再呼叫一次，這次呼叫的等待邏輯若掃整
# 個目錄、逮到誰就算誰，會把「orchestrator 之後才回覆給第一題（存在
# replies/<self>/N.json 底下）」的內容，誤當成第二題（N+1）的答案讀
# 走——而且沒有任何錯誤訊息，orchestrator 也不會知道自己對第二題的定
# 案其實從來沒被 worker 讀到。序號全域唯一且單調（規格、Global
# Constraints「inbox 序號配發」一節），這正是用來擋住這件事的機制：只
# 認自己這次配到的 seq，舊序號的回覆檔案在數學上不可能匹配到新序號，
# 不需要另外判斷「這則回覆是不是屬於我這次問的」。
#
# 因此等待對象是單一個固定路徑 `replies/<self>/<seq>.json`（<seq> 是本
# 次呼叫在上面「落檔在先」那一步已經配到的號碼），不是整個目錄；讀完
# 也不必刪除該檔——序號不會重複使用，同一個檔案不會被下一次呼叫誤讀
# 到。下面 Step 5 新增的回歸測試直接驗證這一點：先在某個序號底下放一份
# 回覆，連問兩題，斷言第二題必須逾時（拿不到那份屬於第一題的舊回覆），
# 而不是把它當成自己的答案印出來。
#
# ---- 序號配發：在 registry 鎖內做「讀舊值＋算新值＋寫回」，不透過
#      hat_json_set ----
# `next_seq` 要做的是「取號並遞增」（fetch-and-increment），不是「把某
# 個欄位設成呼叫端已經算好的值」——後者才是 hat_json_set 的介面。若拆
# 成兩次呼叫（先讀、再呼叫 hat_json_set 寫回遞增後的值），兩次呼叫之
# 間鎖會被放掉，兩個 worker 同時取號可能讀到同一個舊值、算出同一個新
# 號碼，序號就不再是「跨 worker 全域唯一」。
#
# 也不能讓這個取號動作自己內部呼叫 hat_json_set：兩者若各自對同一個目
# 標檔案開一次新的檔案描述符再 `flock -x`，同一個行程對同一個鎖檔用兩
# 個不同描述符會卡住等不到（不是失敗、是永遠等——已用這台機器上的真實
# bash 5.3.15 實測：flock 的鎖是綁在「開檔的檔案描述符」上，不是綁在
# 「行程」上，同一個行程用不同描述符開兩次，彼此仍視為互斥的鎖持有
# 者）。因此 hat_allocate_seq 自己重做一次 hat_json_set 內部同樣在用的
# mktemp／jq／mv 三步，全程只鎖一次，不假手 hat_json_set。
#
# 鎖檔路徑必須跟 hat_json_set 用的是同一條：`<team_json>.lock`（見
# common.sh 的 hat_json_set 說明，修正迴圈第二輪已把它從呼叫
# `hat_registry_root` 重算根目錄改成純粹從目標檔案自己的路徑推導）。
# 兩者若用不同的鎖檔，會各自序列化、彼此不排隊，等於沒鎖：hat_
# allocate_seq 握著自己的鎖改 `.next_seq` 的同時，其他呼叫端（例如
# set-goal.sh）若透過 hat_json_set 寫 team.json 的其他欄位，兩者不會
# 互相等待，team.json 就可能在讀-改-寫的空檔被另一邊置換掉。
#
# 這個函式不透過 `hat_registry_root` 推導路徑，理由與 hat_json_set 這
# 次改版相同：本腳本收到的 `AGENT_TEAM_STATE_DIR` 已經是完全展開好的
# registry 根絕對路徑（由 `launch-worker.sh` 在建立這個 worker 的 tab
# 時直接注入），worker 環境裡沒有 `AGENT_TEAM_HOME`，`hat_registry_
# root` 退回去用的 `$PWD` 又是 worker 自己的工作起點，跟 orchestrator
# 建立 registry 時的 cwd 不同是多 worker 團隊的常態；透過它重算只會算
# 出一個跟真正 registry 無關的路徑。
#
# ---- 環境變數缺席時的備援 ----
# 本腳本靠 AGENT_TEAM_STATE_DIR／AGENT_TEAM_SELF／AGENT_TEAM_ORCHESTRATOR
# 三個環境變數知道「狀態目錄在哪」「自己是誰」「要送給誰」，三者都由
# `herdr tab create --env` 在建立這個 worker 的 tab 時一次性注入（規格
# 2.5）。四家 provider 裡，opencode 與 agy 已實測子行程也能繼承這些注
# 入的變數，codex 只驗到 CLI 行程本身、子行程這一層尚未查證（規格
# §15 未驗清單），而 report.sh 實際執行的位置正是子行程那一層。備援因
# 此只對 AGENT_TEAM_STATE_DIR 開一個 `--state-dir` 參數：啟動包裡本來
# 就寫著這個絕對路徑，worker 讀不到環境變數時仍然讀得到啟動包內容。
# AGENT_TEAM_SELF／AGENT_TEAM_ORCHESTRATOR 沒有對應的參數（Produces 介
# 面沒有列 `--self`／`--orchestrator`），缺席時直接以明確訊息失敗，不
# 提供備援參數。三者缺席都以結束碼 4 結束（守衛不通過），沿用
# `team-init.sh`／`launch-worker.sh` 對 `HERDR_WORKSPACE_ID`／
# `HERDR_PANE_ID` 缺席的既有處理方式——這類「herdr 或啟動流程本該注入
# 卻沒注入的座標／身分變數缺席」在這個 skill 裡一律歸類成守衛不通過，
# 不是呼叫端用錯（呼叫端只是正常呼叫報告動作，沒有做錯任何事）。
#
# ---- 上行前綴：轉發給 orchestrator 的訊息帶序號／token／發訊 worker
#      ----
# 修法見 lib/common.sh「上行前綴」一節（`hat_build_uplink_message`／
# `hat_strip_uplink_prefix` 兩個函式集中定義在那裡，理由也寫在那
# 裡）。這裡只記本腳本這一側的取捨：`working` 這個 token 從不投遞（見
# 上方同名一節），orchestrator 永遠看不到它，加前綴沒有對象可服務，維
# 持原文不動；其餘五個 token 一律加。`.summary` 這個欄位存的就是加了
# 前綴之後的完整內容，不是另開一個新欄位存前綴——這是刻意的：
# `watchdog.sh` 的 `hat_wd_retry_blocked_inbox` 補投當初被
# `agent_blocked` 擋下的訊息時，讀的正是 `.summary`，若前綴只存在另一
# 個欄位、`.summary` 保持原文，補投出去的內容就會漏掉前綴，造成「第一
# 次就送達的訊息有前綴、被擋過又補投成功的訊息沒有」這種不一致。

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

hat_require_herdr_env

readonly HAT_SUMMARY_MAX_DEFAULT=500
readonly HAT_NEEDYOU_POLL_INTERVAL_SECONDS=2
readonly HAT_NEEDYOU_DEFAULT_WAIT_SECONDS=540

# hat_json_string <text>
# 把任意文字安全地轉成一個 JSON 字串字面並印出來。摘要／細節路徑／
# locator 都是可能含引號或反斜線的自由文字，改用 jq -Rn --arg 讓 jq 自
# 己處理跳脫（與 set-goal.sh、launch-worker.sh 的同名局部函式做法相
# 同，理由與位置皆同：各腳本各自獨立定義，不共用）。
hat_json_string() {
  jq -Rn --arg v "$1" '$v'
}

# hat_allocate_seq <registry_root>
# 在 <registry_root>/team.json.lock 的鎖保護下，從 <registry_root>/
# team.json 的 next_seq 取號並遞增，印出取到的號碼（十進位整數）。缺
# 席視為 1（第一個號碼）。鎖檔路徑必須與 hat_json_set 對同一個檔案用
# 的路徑一致（`<file>.lock`），理由見檔頭「序號配發」一節。
hat_allocate_seq() {
  local registry_root="$1" team_json lock_file lock_fd tmp seq new_seq

  team_json="$registry_root/team.json"
  lock_file="${team_json}.lock"

  lock_fd=""
  exec {lock_fd}>"$lock_file"
  flock -x "$lock_fd"

  seq="$(jq -r '.next_seq // 1' "$team_json" 2>/dev/null)" || seq=""
  case "$seq" in
    '' | *[!0-9]*)
      hat_die 5 "report.sh: team.json 的 next_seq 不是合法的十進位整數：'$seq'" ;;
  esac
  new_seq=$((seq + 1))

  tmp="$(mktemp "${team_json}.XXXXXX")" || hat_die 5 "report.sh: 無法建立暫存檔，取號失敗：$team_json"
  if ! { jq --argjson v "$new_seq" '.next_seq = $v' "$team_json" > "$tmp" && mv "$tmp" "$team_json"; }; then
    rm -f "$tmp"
    hat_die 5 "report.sh: 寫入失敗（jq 解析或置換未成功），next_seq 未遞增：$team_json"
  fi

  exec {lock_fd}>&-
  printf '%s\n' "$seq"
}

token="" summary="" detail_file="" locator="" state_dir_arg="" wait_timeout_seconds="$HAT_NEEDYOU_DEFAULT_WAIT_SECONDS"
have_token=0 have_summary=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --token)
      [ "$#" -ge 2 ] || hat_die 2 "report.sh: --token 缺值"
      token="$2"; have_token=1; shift 2 ;;
    --summary)
      [ "$#" -ge 2 ] || hat_die 2 "report.sh: --summary 缺值"
      summary="$2"; have_summary=1; shift 2 ;;
    --detail-file)
      [ "$#" -ge 2 ] || hat_die 2 "report.sh: --detail-file 缺值"
      detail_file="$2"; shift 2 ;;
    --locator)
      [ "$#" -ge 2 ] || hat_die 2 "report.sh: --locator 缺值"
      locator="$2"; shift 2 ;;
    --state-dir)
      [ "$#" -ge 2 ] || hat_die 2 "report.sh: --state-dir 缺值"
      state_dir_arg="$2"; shift 2 ;;
    --wait-timeout)
      [ "$#" -ge 2 ] || hat_die 2 "report.sh: --wait-timeout 缺值"
      wait_timeout_seconds="$2"; shift 2 ;;
    *)
      hat_die 2 "report.sh: 未知參數 '$1'" ;;
  esac
done

if [ "$have_token" -ne 1 ] || [ "$have_summary" -ne 1 ]; then
  hat_die 2 "report.sh: --token／--summary 兩項全部必填"
fi

case "$wait_timeout_seconds" in
  '' | *[!0-9]*)
    hat_die 2 "report.sh: --wait-timeout 必須是純數字秒數，收到：$wait_timeout_seconds" ;;
esac

# ---- 環境變數（含 --state-dir 備援），見檔頭「環境變數缺席時的備
#      援」一節 ----
state_dir="${state_dir_arg:-${AGENT_TEAM_STATE_DIR:-}}"
if [ -z "$state_dir" ]; then
  hat_die 4 "report.sh: AGENT_TEAM_STATE_DIR 未設，且未帶 --state-dir。啟動包裡已經寫著這個絕對路徑，可用 --state-dir 明給（codex 的子行程繼承尚未查證，規格 §15）"
fi

self_name="${AGENT_TEAM_SELF:-}"
if [ -z "$self_name" ]; then
  hat_die 4 "report.sh: AGENT_TEAM_SELF 未設，不知道自己是誰、回報要記在哪個 worker 名下"
fi

orchestrator_name="${AGENT_TEAM_ORCHESTRATOR:-}"
if [ -z "$orchestrator_name" ]; then
  hat_die 4 "report.sh: AGENT_TEAM_ORCHESTRATOR 未設，不知道要投遞給誰"
fi

# ---- token 白名單（規格 §8）----
case "$token" in
  ack | working | fyi | need-you | delivered | done) : ;;
  *)
    hat_die 2 "report.sh: 不支援的 token '$token'：只接受 ack、working、fyi、need-you、delivered、done 六個" ;;
esac

# ---- 摘要長度上限：拒絕，不截斷（規格 §15、本任務行為要求 4）----
# ack 一律豁免，見檔頭「ACK 的固定摘要格式」一節：不是調高上限，是這
# 個 token 完全不套用長度檢查。
if [ "$token" != "ack" ]; then
  summary_max="${AGENT_TEAM_SUMMARY_MAX:-$HAT_SUMMARY_MAX_DEFAULT}"
  if [ "${#summary}" -gt "$summary_max" ]; then
    hat_die 2 "report.sh: --summary 超過長度上限 $summary_max 字元（收到 ${#summary} 字元；這個上限沒有實測依據，可用 AGENT_TEAM_SUMMARY_MAX 覆寫）。請把完整內容改放進 --detail-file，--summary 只留一行摘要"
  fi
fi

if [ -n "$detail_file" ] && [ ! -f "$detail_file" ]; then
  hat_die 2 "report.sh: --detail-file 指向的檔案不存在：$detail_file"
fi

# ---- 落檔在先，投遞在後：落檔失敗即失敗，不嘗試投遞 ----
seq="$(hat_allocate_seq "$state_dir")"
inbox_file="$state_dir/inbox/${seq}-${self_name}.json"

# ---- 上行前綴（見 lib/common.sh「上行前綴」一節）：working 不投遞，
#      也不需要讓 orchestrator 一眼取出序號，維持原文不加前綴；其餘五
#      個 token 把序號／token／發訊 worker 釘進 .summary 最前面，同一
#      份內容既落檔也拿去投遞，補投（watchdog.sh）讀的是同一個欄位，
#      自然也帶著前綴 ----
if [ "$token" != "working" ]; then
  summary="$(hat_build_uplink_message "$seq" "$token" "$self_name" "$summary")"
fi

detail_path_json='null'
if [ -n "$detail_file" ]; then
  details_dest="$state_dir/details/${seq}-${self_name}.txt"
  if ! cp "$detail_file" "$details_dest"; then
    hat_die 5 "report.sh: 細節檔複製失敗，不繼續回報（worker=$self_name seq=$seq src=$detail_file dest=$details_dest）"
  fi
  detail_path_json="$(hat_json_string "$details_dest")"
fi

locator_json='null'
if [ -n "$locator" ]; then
  locator_json="$(hat_json_string "$locator")"
fi

created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

printf '{}' > "$inbox_file"
hat_json_set "$inbox_file" '.token' "$(hat_json_string "$token")"
hat_json_set "$inbox_file" '.worker' "$(hat_json_string "$self_name")"
hat_json_set "$inbox_file" '.summary' "$(hat_json_string "$summary")"
hat_json_set "$inbox_file" '.detail_path' "$detail_path_json"
hat_json_set "$inbox_file" '.locator' "$locator_json"
hat_json_set "$inbox_file" '.created_at' "$(hat_json_string "$created_at")"

# ---- 投遞：working 不投遞，只落檔；其餘五個一律嘗試（規格 §8、本任
#      務行為要求 6、7）----
# 不透過 `--wait`／`--until`／`--timeout`：見檔頭「投遞不帶任何握手選
# 項」一節。投遞失敗（含 agent_blocked）只記在 `.delivery`，不讓本腳本
# 以非 0 結束：見檔頭「投遞失敗不是本腳本的失敗」一節。
if [ "$token" = "working" ]; then
  hat_json_set "$inbox_file" '.delivery' '"skipped"'
else
  rc=0
  hat_herdr agent prompt "$orchestrator_name" "$summary" >/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then
    hat_json_set "$inbox_file" '.delivery' '"delivered"'
  else
    hat_json_set "$inbox_file" '.delivery' '"blocked"'
    # 不能只把結束碼留在 0：完全靜默會讓 worker 以為 orchestrator 已經
    # 看到了，見檔頭「投遞失敗不是本腳本的失敗，但不能完全靜默」一節。
    printf '已記錄、投遞延後：orchestrator 目前收不到，看門狗會另行重試投遞\n'
  fi
fi

# ---- need-you：阻塞等回覆，逾時不算失敗（規格 §8、本任務行為要求
#      8）----
# 等待對象只有這次呼叫自己配到的 seq 那一個固定檔名，不是整個目錄；理
# 由見檔頭「need-you 的等待對象」一節。讀完不刪除該檔：seq 全域唯一且
# 單調，同一個檔案不會被下一次呼叫誤讀到。
if [ "$token" = "need-you" ]; then
  reply_file="$state_dir/replies/$self_name/${seq}.json"
  elapsed=0
  while [ ! -f "$reply_file" ]; do
    if [ "$elapsed" -ge "$wait_timeout_seconds" ]; then
      printf '已上報，未在時限內收到回覆，請結束回合等下行\n'
      exit 7
    fi
    sleep "$HAT_NEEDYOU_POLL_INTERVAL_SECONDS"
    elapsed=$((elapsed + HAT_NEEDYOU_POLL_INTERVAL_SECONDS))
  done

  cat "$reply_file"
  exit 0
fi

exit 0
