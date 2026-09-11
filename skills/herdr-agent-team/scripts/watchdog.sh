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
# ---- 三個門檻值都能覆寫，而且都沒有實測依據 ----
# AGENT_TEAM_POLL_SECONDS（預設 20）、AGENT_TEAM_STALL_SECONDS（預設
# 1800）、AGENT_TEAM_AUTO_PUSH_LIMIT（預設 10）三者皆可用同名環境變數
# 覆寫；三個數字都是私用階段的起點，沒有任何實測依據（規格 §15 未驗清
# 單「摘要長度上限、自動推進上限、空轉判定秒數都是估的」）。
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
#       呼叫 hat_remove_pending_resend 移除該筆；佇列清空後才放掉持
#       有旗標（沒清空代表還有訊息沒補投出去，orchestrator 仍在跟它
#       對話中，不該放行別的下行插隊）。
#
# ---- 豁免：等待 need-you 回覆的 worker 一律豁免自動推進與停滯升級 ----
# 有未回覆 need-you 的 worker 停著是正常的——它在等 orchestrator 決
# 定，不是卡住。豁免範圍包含第 1、3 兩項（第 2 項的 blocked／達上限升
# 級不受影響：核准框與達上限本身就是需要人介入的訊號，跟等 need-you
# 回覆是兩件不同的事，兩者可能同時成立，此時仍要升級）。
#
# ---- 白名單欄位：任何要投遞給 orchestrator 的內容只能是本腳本自己組
#      出來的摘要文字 ----
# hat_whitelist_agents 六個欄位裡沒有 terminal_title／terminal_title_
# stripped（帶的是模型與使用者原文），本腳本組摘要時也只用 worker 名
# 稱、agent_status、門檻數字這些已知安全的值，不會把任何 herdr 原始回
# 應轉發出去。
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
# 留給下一輪。佇列清空後才放掉持有旗標。
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

  if [ "$(jq -r '(.pending_resend // []) | length' "$worker_file")" -eq 0 ]; then
    hat_json_set "$worker_file" '.held' 'false'
  fi
}

# hat_wd_process_worker <registry_root> <orchestrator_name> <worker> \
#   <whitelisted> <stall_seconds> <auto_push_limit>
# 對單一 worker 依序執行：4b) 待補送補投 → 讀取這一輪觀測值 → 更新
# stamp 追蹤 → 3) 停滯偵測 → 豁免檢查 → 2) blocked／unknown 升級 →
# 1) 自動推進。先做補投，讓後面的自動推進評估用到的是補投後的最新持
# 有旗標狀態（見檔頭「四個職責」b) 一節）。
hat_wd_process_worker() {
  local registry_root="$1" orchestrator_name="$2" worker="$3" whitelisted="$4"
  local stall_seconds="$5" auto_push_limit="$6"
  local worker_file pane_id line status stamp held needyou_pending
  local last_stamp last_changed_at now elapsed auto_push_count new_count rc

  worker_file="$registry_root/workers/$worker.json"
  [ -f "$worker_file" ] || return 0

  # ---- 入口守衛：跟 team-status.sh 同一個理由——一次要處理本 team 全
  #      部 worker，一筆記錄的座標對不上就不該讓 hat_assert_workspace
  #      的 hat_die 4 把整個看門狗行程帶走（`--once` 之外的長駐模式下
  #      那等於整個團隊都停止被照看），因此包在子殼裡捕捉失敗、只跳
  #      過這一筆，`hat_assert_workspace` 本身仍然被呼叫到 ----
  pane_id="$(jq -r '.pane_id // empty' "$worker_file")"
  if [ -n "$pane_id" ] && ! ( hat_assert_workspace "$pane_id" ) 2>/dev/null; then
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

  # ---- 豁免：等 need-you 回覆的 worker 不評估自動推進 ----
  if [ "$needyou_pending" = "1" ]; then
    return 0
  fi

  # ---- 2：blocked 一律升級，不送文字下行給這個 worker ----
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

  # ---- 1：自動推進，先套用計數重置（見檔頭同名一節）----
  hat_wd_apply_auto_push_reset "$registry_root" "$worker" "$worker_file"
  auto_push_count="$(jq -r '.auto_push_count // 0' "$worker_file")"

  if [ "$auto_push_count" -ge "$auto_push_limit" ]; then
    hat_wd_escalate "$registry_root" "$orchestrator_name" "$worker" \
      "worker=$worker 自動推進已達上限 ${auto_push_limit} 次仍是 $status，改為升級"
    return 0
  fi

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
# worker。
hat_wd_run_once() {
  local registry_root team_json orchestrator_name agents_json whitelisted worker

  registry_root="$(hat_registry_root)"
  team_json="$registry_root/team.json"
  orchestrator_name="$(jq -r '.orchestrator_name // empty' "$team_json" 2>/dev/null || true)"

  agents_json="$(hat_herdr agent list)"
  whitelisted="$(hat_whitelist_agents "$agents_json")"

  hat_wd_retry_blocked_inbox "$registry_root" "$orchestrator_name" "$whitelisted"

  while IFS= read -r worker; do
    [ -n "$worker" ] || continue
    hat_wd_process_worker "$registry_root" "$orchestrator_name" "$worker" "$whitelisted" \
      "$stall_seconds" "$auto_push_limit"
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
