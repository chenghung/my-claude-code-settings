#!/usr/bin/env bash
#
# skills/herdr-agent-team/scripts/team-status.sh
#
# 用法：team-status.sh
#
# 職責（規格 §5、Task 12）：唯讀，orchestrator 端事件層的狀態查詢入
# 口。對本 workspace 已知的每個 worker（registry 的 workers/*.json）印
# 出一行：
#   worker=<名稱> stage=<關卡> status=<herdr 狀態> seq=<stamp> \
#     held=<true|false> pending_resend=<筆數> unprocessed=<筆數>
#
# ---- 只呼叫一次 herdr agent list，跟 watchdog.sh 同一個理由 ----
# 一次呼叫拿到全部 agent，經 hat_whitelist_agents 投影後才使用，不逐一
# 對每個 worker 呼叫 agent get——team 有幾個 worker 就要幾次往返，而
# agent list 一次就夠。
#
# ---- 白名單欄位：只轉發六個已投影欄位，不轉發終端標題 ----
# hat_whitelist_agents 已經把 agent_status／state_change_seq 之外的欄
# 位（尤其是 terminal_title／terminal_title_stripped，帶的是模型與使
# 用者原文）全部濾掉；本腳本再從這六欄裡只取 agent_status／
# state_change_seq 兩欄組進輸出，不會把任何未經投影的欄位轉發給
# orchestrator 的 context。
#
# ---- stage／held／pending_resend 沒有即時資料時的預設值 ----
# `.stage` 目前沒有任何腳本會在建立 worker 記錄的同一步寫入它（見
# lib/common.sh 欄位白名單一節：`.stage` 由 orchestrator 端腳本寫，時
# 機是收到 worker 回報之後），一個剛啟動、還沒被回報過的 worker 完全可
# 能沒有這個欄位；`.held`／`.pending_resend` 也一樣可能整個缺席（尚未
# 被 launch-worker.sh 之外的任何寫入端動過）。三者一律用 jq 的
# `// 預設值` 取代，不用 hat_json_get（它對缺漏欄位以 5 結束整個呼叫
# 端，而「這個 worker 還沒有 stage」是正常狀態，不是 registry 壞了）。
#
# ---- unprocessed：這個 worker 名下還有多少筆 inbox 記錄的
#      .processed_at 仍是 JSON null ----
# 這是給人／orchestrator 看的一般性積壓指標，跟 watchdog.sh／
# shutdown-worker.sh 各自需要的「有沒有未回覆的 need-you」是不同用
# 途、不同判準的計數（那兩支腳本只關心 need-you 這一種 token，本腳本
# 這裡不篩 token，任何尚未被 orchestrator 處理過的上行都算）。
#
# ---- 入口守衛：對每個已知 worker 的既有座標斷言屬於本 workspace，命
#      中就跳過那一筆，不是讓整支腳本連其餘 worker 的狀態都印不出來 ----
# registry 裡的每一筆 workers/<name>.json 都是由 launch-worker.sh 建立
# 時就已經驗過屬於本 workspace 的座標，正常情況下這裡不會真的觸發；套
# 用 hat_assert_workspace 是防禦性的一致性檢查（跟 launch-worker.sh 對
# 剛拿到的座標做的事同一個精神）。但跟 instruct.sh／press-approval.sh
# 那類「呼叫端指定單一 target」的腳本不同，本腳本一次要看過本 team 全
# 部 worker：若因為其中一筆記錄的座標對不上就讓 hat_assert_workspace
# 的 hat_die 4 把整支腳本帶走，後果是操作者原本想看全隊狀態、卻因為一
# 筆壞記錄連其餘健康的 worker 都看不到——對一個唯讀的健檢工具而言，這
# 個代價比「跳過這一筆、其餘照印」大得多。因此呼叫包在子殼裡，命中就
# `continue` 跳過這一筆，不是讓 hat_die 往外傳播；`hat_assert_workspace`
# 本身仍然被呼叫到，行為只是「捕捉它的失敗」，不是繞過它。
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

hat_require_herdr_env

if [ "$#" -gt 0 ]; then
  hat_die 2 "team-status.sh: 不接受任何參數"
fi

# hat_status_unprocessed_count <registry_root> <worker>
# 印出 <worker> 在 inbox/ 裡 .processed_at 仍是 JSON null 的記錄筆數
# （見檔頭「unprocessed」一節）。掃過去比對 .worker 欄位，不解析檔名
# 裡的 worker 名稱：worker 名稱本身可能含連字號，從檔名
# `<seq>-<worker>.json` 反推容易切錯（沿用 shutdown-worker.sh
# hat_need_you_pending 的既有手法）。
hat_status_unprocessed_count() {
  local registry_root="$1" worker="$2" f who processed count=0

  while IFS= read -r -d '' f; do
    who="$(jq -r '.worker // empty' "$f")"
    processed="$(jq -r '.processed_at' "$f")"
    if [ "$who" = "$worker" ] && [ "$processed" = "null" ]; then
      count=$((count + 1))
    fi
  done < <(find "$registry_root/inbox" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)

  printf '%s\n' "$count"
}

registry_root="$(hat_registry_root)"

agents_json="$(hat_herdr agent list)"
whitelisted="$(hat_whitelist_agents "$agents_json")"

while IFS= read -r worker; do
  [ -n "$worker" ] || continue
  worker_file="$registry_root/workers/$worker.json"
  [ -f "$worker_file" ] || continue

  pane_id="$(jq -r '.pane_id // empty' "$worker_file")"
  if [ -n "$pane_id" ] && ! ( hat_assert_workspace "$pane_id" ) 2>/dev/null; then
    continue
  fi

  line="$(printf '%s\n' "$whitelisted" | awk -F'\t' -v n="$worker" '$1 == n')"
  status="" seq=""
  if [ -n "$line" ]; then
    status="$(printf '%s' "$line" | cut -f3)"
    seq="$(printf '%s' "$line" | cut -f4)"
  fi

  stage="$(jq -r '.stage // empty' "$worker_file")"
  held="$(jq -r '.held // false' "$worker_file")"
  pending_resend_count="$(jq -r '(.pending_resend // []) | length' "$worker_file")"
  unprocessed_count="$(hat_status_unprocessed_count "$registry_root" "$worker")"

  printf 'worker=%s stage=%s status=%s seq=%s held=%s pending_resend=%s unprocessed=%s\n' \
    "$worker" "$stage" "$status" "$seq" "$held" "$pending_resend_count" "$unprocessed_count"
done < <(hat_worker_list)

exit 0
