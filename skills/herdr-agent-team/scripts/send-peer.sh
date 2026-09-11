#!/usr/bin/env bash
#
# skills/herdr-agent-team/scripts/send-peer.sh
#
# 用法：
#   send-peer.sh --to <peer> --text <文字> [--state-dir <路徑>]
#
# 職責（規格 §10、§12 的 `send-peer` 動作）：worker 端橫向送訊息的唯一
# 入口，從環境讀自己的身分。
#
# ---- worker 端環境約束：不得走任何會重算 registry 根目錄的路徑 ----
# 本腳本跑在 worker 那一端，那裡只有 launch-worker.sh 注入的五個
# `AGENT_TEAM_*` 變數（`STATE_DIR`／`ORCHESTRATOR`／`SELF`／`ROLE`／
# `SCRIPTS`），沒有 `AGENT_TEAM_HOME`；common.sh 的 `hat_registry_root`
# 依賴它、缺席時退回 `$PWD`，在 worker 端會算出一個跟真正 registry 無關
# 的路徑（report.sh 檔頭「序號配發」一節記載的既有教訓）。因此本腳本一
# 律直接用 `AGENT_TEAM_STATE_DIR`（缺席時接受 `--state-dir` 明給）當成
# registry 根，自己組 `workers/`、`peer-log/` 底下的路徑，完全不呼叫
# `hat_registry_root`／`hat_worker_list`／`hat_require_goal_confirmed`／
# `hat_registry_init` 這類依賴 `AGENT_TEAM_HOME` 的函式；也用不到它們：
# 本腳本只需要讀寫兩個已知路徑，不需要列舉 worker、不需要開工閘門、不
# 需要初始化 registry 骨架。
#
# ---- 預設不通：送出前檢查 --to 在不在自己的 grants 清單裡 ----
# grant 是這個 skill 唯一的存取控制機制——用位址隱藏取代規則約束，寫在
# 契約裡的「你只能找 B」是文字，模型不遵守也沒有錯誤訊息。判斷依據是自
# 己（`AGENT_TEAM_SELF`）這份 worker 記錄的 `.grants` 陣列，欄位或整份
# 記錄不存在一律視為空陣列／未授權，不得因此讓腳本以非預期的方式失敗：
# 跟 `shutdown-worker.sh` 讀同一欄位的既有處理方式一致，不合格一律是
# `4`（規格 §12：grant 本身就是六類「守衛不通過」之一）。
#
# ---- 入口守衛：對 --to 的既有座標斷言屬於本 workspace，早於任何 herdr
#      呼叫、也早於 grants 檢查 ----
# 跟 instruct.sh／press-approval.sh 對「既有 target」的既有手法一致：從
# registry 讀出 --to 這個 worker 的 pane_id，斷言屬於本 workspace。
#
# ---- 橫向是直接的：完整內容直達對方 pane，不經 orchestrator、不拆信
#      ----
# 跟 instruct.sh 一樣不帶任何握手選項（`--wait`／`--until`／
# `--timeout`）：對方多半在做事，短握手只會逾時誤判。落檔（peer-log 紀
# 錄）在先、投遞在後：落檔失敗即失敗；投遞失敗（含 `agent_blocked`）只
# 記在該筆紀錄的 `.delivery` 欄位，本腳本仍以 0 結束，並在 stdout 印一
# 行提示——完全靜默會讓呼叫端誤判成「對方已經看到了」，跟 report.sh 檔
# 頭「投遞失敗不是本腳本的失敗，但不能完全靜默」是同一個理由。橫向沒有
# 像 orchestrator 下行那樣的待補送重試機制：規格 §10 明講落檔的目的是
# 給調查者事後查，不是保證送達的基礎設施；需要保證對方讀到，呼叫端應該
# 接著呼叫 `wait-peer.sh`，逾時本身就是死鎖／未送達的訊號。
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

hat_require_herdr_env

to="" text="" state_dir_arg=""
have_to=0 have_text=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --to)
      [ "$#" -ge 2 ] || hat_die 2 "send-peer.sh: --to 缺值"
      to="$2"; have_to=1; shift 2 ;;
    --text)
      [ "$#" -ge 2 ] || hat_die 2 "send-peer.sh: --text 缺值"
      text="$2"; have_text=1; shift 2 ;;
    --state-dir)
      [ "$#" -ge 2 ] || hat_die 2 "send-peer.sh: --state-dir 缺值"
      state_dir_arg="$2"; shift 2 ;;
    *)
      hat_die 2 "send-peer.sh: 未知參數 '$1'" ;;
  esac
done

if [ "$have_to" -ne 1 ] || [ "$have_text" -ne 1 ]; then
  hat_die 2 "send-peer.sh: --to／--text 兩項全部必填"
fi

# ---- 環境變數（含 --state-dir 備援），見檔頭「worker 端環境約束」一
#      節 ----
state_dir="${state_dir_arg:-${AGENT_TEAM_STATE_DIR:-}}"
if [ -z "$state_dir" ]; then
  hat_die 4 "send-peer.sh: AGENT_TEAM_STATE_DIR 未設，且未帶 --state-dir。啟動包裡已經寫著這個絕對路徑，可用 --state-dir 明給"
fi

self_name="${AGENT_TEAM_SELF:-}"
if [ -z "$self_name" ]; then
  hat_die 4 "send-peer.sh: AGENT_TEAM_SELF 未設，不知道自己是誰"
fi

# ---- 名稱格式驗證：--to 與 AGENT_TEAM_SELF 都要拿去組 registry 路徑，
#      從環境讀來的值一樣是外部輸入，同樣要驗（全域約束）----
hat_assert_agent_name "$to"
hat_assert_agent_name "$self_name"

to_file="$state_dir/workers/$to.json"
self_file="$state_dir/workers/$self_name.json"

# ---- 入口守衛：對既有 target 的座標斷言屬於本 workspace，早於任何
#      herdr 呼叫、也早於 grants 檢查（見檔頭「入口守衛」一節）----
peer_pane_id="$(hat_json_get "$to_file" '.pane_id')"
hat_assert_workspace "$peer_pane_id"

# ---- 預設不通：--to 必須出現在自己的 grants 清單裡（見檔頭同名一
#      節）----
granted="false"
if [ -f "$self_file" ]; then
  granted="$(jq -r --arg t "$to" '(.grants // []) | any(. == $t)' "$self_file")"
fi
if [ "$granted" != "true" ]; then
  hat_die 4 "send-peer.sh: '$to' 不在自己的 grants 清單裡，拒絕送出（需要先由 orchestrator 呼叫 grant-peer.sh 授權）"
fi

# ---- 落檔在先、投遞在後（見檔頭「橫向是直接的」一節）----
mkdir -p "$state_dir/peer-log"
created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

rc=0
hat_herdr agent prompt "$to" "$text" >/dev/null || rc=$?
if [ "$rc" -eq 0 ]; then
  delivery="delivered"
else
  delivery="blocked"
fi

log_file="$(mktemp "$state_dir/peer-log/${self_name}-to-${to}-XXXXXX.json")" || hat_die 5 "send-peer.sh: 無法建立 peer-log 紀錄檔"
if ! jq -n --arg from "$self_name" --arg to "$to" --arg text "$text" \
    --arg created_at "$created_at" --arg delivery "$delivery" \
    '{from: $from, to: $to, text: $text, created_at: $created_at, delivery: $delivery}' \
    > "$log_file"; then
  hat_die 5 "send-peer.sh: peer-log 紀錄檔寫入失敗：$log_file"
fi

if [ "$delivery" = "blocked" ]; then
  printf '已記錄、投遞失敗：%s 目前收不到（可能忙碌中）。橫向沒有待補送機制，需要確認對方讀到請改呼叫 wait-peer.sh，或回報 orchestrator\n' "$to"
fi

exit 0
