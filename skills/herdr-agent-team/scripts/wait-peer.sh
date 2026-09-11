#!/usr/bin/env bash
#
# skills/herdr-agent-team/scripts/wait-peer.sh
#
# 用法：
#   wait-peer.sh --peer <peer> [--timeout <秒>] [--poll <秒>] \
#     [--state-dir <路徑>]
#
# 職責（規格 §10、§12 的 `wait-peer` 動作）：worker 端腳本 loop 輪詢，
# 不花 context，取代「送出去之後在 context 裡乾等」。
#
# ---- worker 端環境約束：不得走任何會重算 registry 根目錄的路徑 ----
# 跟 send-peer.sh 同一個理由（見該腳本檔頭）：本腳本一律直接用
# `AGENT_TEAM_STATE_DIR`（缺席時接受 `--state-dir` 明給）當成 registry
# 根，完全不呼叫 `hat_registry_root` 或任何依賴 `AGENT_TEAM_HOME` 的函
# 式。
#
# ---- 死鎖防護的判準：對方還活著，且它的 state_change_seq 前後兩次觀
#      測到的值不同（規格 2.5、§12）----
# `state_change_seq` 是全域共用的遞增計數器，不是每個 agent 各自獨立的
# 計數——實測連續取樣時六個 agent 的值落在同一個共同區間、且跨兩個
# workspace 交錯出現。若把「有改變」理解成「數值有沒有增加」，這個全域
# 序號永遠在增加，條件會恆真，死鎖防護等於不存在；正確判法是比對**同一
# 個 agent** 前後兩次觀測到的 stamp 值有沒有改變。只看「還活著」同樣會
# 等到死鎖：對方可能一直存在、卻卡在原地不動（例如雙方互相等待對方先開
# 口）。因此本腳本先取一次基準觀測（不算數，只是起點），之後每隔
# `--poll` 秒再觀測一次，跟上一次觀測比對；一旦不同就成功結束，逾時仍
# 未改變就以 `7` 結束——這不是失敗，是「未取得憑據，呼叫端需要決定下一
# 步」（跟 report.sh 的 need-you 逾時、press-approval.sh 代按後仍
# blocked 是同一個結束碼語意）。
#
# ---- 對方在等待過程中從 agent list 徹底消失，視為本腳本自己的迴圈異
#      常，不是「還活著」的一種 ----
# `herdr agent list` 只列出目前存在的 agent；對方若被關閉或名稱被清
# 空，會從清單裡整個消失，不是換成某種「已死」狀態值。這種情形下本腳本
# 再也觀測不到任何 stamp，判斷不出「有沒有改變」，用 `1`（個別腳本自行
# 產生的部分失敗或迴圈異常）結束，跟「還活著但沒有變化」的逾時（`7`）
# 分開：前者是這支腳本的核心工作（觀測 stamp）已經做不下去，後者是核心
# 工作做得到、只是一直沒有等到想要的結果。
#
# ---- 入口守衛：對 --peer 的既有座標斷言屬於本 workspace，早於任何
#      herdr 呼叫 ----
# 跟 send-peer.sh／instruct.sh／press-approval.sh 對「既有 target」的既
# 有手法一致：從 registry 讀出 --peer 這個 worker 的 pane_id，斷言屬於
# 本 workspace，早於第一次 `agent list` 查詢。
#
# ---- 呼叫 agent list，不呼叫 agent get ----
# 一次 `agent list` 拿到全部 agent 再篩出 `--peer`，跟 `agent get` 只回
# 單一目標是兩種不同的回應形狀（`.result.agents[]` 陣列 vs
# `.result.agent` 物件）。這裡選 `agent list` 是因為 Task 1 已經有現成
# 的 `hat_whitelist_agents` 六欄白名單可以直接沿用，不必再對單一目標的
# 回應另外寫一次白名單投影。
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

hat_require_herdr_env

# 沒有實測依據，起點值可用 --timeout／--poll 覆寫（規格 §15 同一份未驗
# 清單的呼應：摘要長度上限、自動推進上限、空轉判定秒數都是估的，這裡的
# 逾時與輪詢間隔是同一類）。
readonly HAT_WAIT_PEER_DEFAULT_TIMEOUT_SECONDS=300
readonly HAT_WAIT_PEER_DEFAULT_POLL_SECONDS=5

# hat_peer_observation <peer>
# 呼叫一次 `herdr agent list`，經 `hat_whitelist_agents` 投影後篩出名稱
# 等於 <peer> 的那一行（六欄 TSV：name、workspace_id、agent_status、
# state_change_seq、pane_id、tab_id）。找不到就印空字串。herdr 呼叫本身
# 的失敗（拒絕、語法錯誤）刻意用裸賦值、不接 `|| rc=$?`：呼叫端的
# errexit 會直接帶著 hat_herdr 已經映射好的結束碼（6 或 2）終止整支腳
# 本，跟 press-approval.sh 對 `agent get` 的既有手法一致。
hat_peer_observation() {
  local peer="$1" agents_json
  agents_json="$(hat_herdr agent list)"
  hat_whitelist_agents "$agents_json" | awk -F'\t' -v n="$peer" '$1 == n'
}

peer="" timeout="$HAT_WAIT_PEER_DEFAULT_TIMEOUT_SECONDS" poll="$HAT_WAIT_PEER_DEFAULT_POLL_SECONDS"
state_dir_arg=""
have_peer=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --peer)
      [ "$#" -ge 2 ] || hat_die 2 "wait-peer.sh: --peer 缺值"
      peer="$2"; have_peer=1; shift 2 ;;
    --timeout)
      [ "$#" -ge 2 ] || hat_die 2 "wait-peer.sh: --timeout 缺值"
      timeout="$2"; shift 2 ;;
    --poll)
      [ "$#" -ge 2 ] || hat_die 2 "wait-peer.sh: --poll 缺值"
      poll="$2"; shift 2 ;;
    --state-dir)
      [ "$#" -ge 2 ] || hat_die 2 "wait-peer.sh: --state-dir 缺值"
      state_dir_arg="$2"; shift 2 ;;
    *)
      hat_die 2 "wait-peer.sh: 未知參數 '$1'" ;;
  esac
done

if [ "$have_peer" -ne 1 ]; then
  hat_die 2 "wait-peer.sh: --peer 為必填"
fi

case "$timeout" in
  '' | *[!0-9]*) hat_die 2 "wait-peer.sh: --timeout 必須是純數字秒數，收到：$timeout" ;;
esac
case "$poll" in
  '' | *[!0-9]*) hat_die 2 "wait-peer.sh: --poll 必須是純數字秒數，收到：$poll" ;;
esac

# ---- 環境變數（含 --state-dir 備援），見檔頭「worker 端環境約束」一
#      節 ----
state_dir="${state_dir_arg:-${AGENT_TEAM_STATE_DIR:-}}"
if [ -z "$state_dir" ]; then
  hat_die 4 "wait-peer.sh: AGENT_TEAM_STATE_DIR 未設，且未帶 --state-dir。啟動包裡已經寫著這個絕對路徑，可用 --state-dir 明給"
fi

# ---- 名稱格式驗證早於組 registry 路徑（全域約束）----
hat_assert_agent_name "$peer"

peer_file="$state_dir/workers/$peer.json"

# ---- 入口守衛：對既有 target 的座標斷言屬於本 workspace，早於任何
#      herdr 呼叫（見檔頭「入口守衛」一節）----
peer_pane_id="$(hat_json_get "$peer_file" '.pane_id')"
hat_assert_workspace "$peer_pane_id"

# ---- 基準觀測：不算數，只是後面比對的起點（見檔頭「死鎖防護的判準」
#      一節）----
observation="$(hat_peer_observation "$peer")"
if [ -z "$observation" ]; then
  hat_die 1 "wait-peer.sh: 對方 '$peer' 目前查無 agent 記錄，判斷不出狀態變化"
fi
prev_stamp="$(printf '%s' "$observation" | cut -f4)"

elapsed=0
while :; do
  if [ "$elapsed" -ge "$timeout" ]; then
    hat_die 7 "wait-peer.sh: 逾時 ${timeout}s，'$peer' 的 state_change_seq 一直沒有改變，可能死鎖或忙碌中，呼叫端需要決定下一步"
  fi

  sleep "$poll"
  elapsed=$((elapsed + poll))

  observation="$(hat_peer_observation "$peer")"
  if [ -z "$observation" ]; then
    hat_die 1 "wait-peer.sh: 對方 '$peer' 在等待過程中查無 agent 記錄，判斷不出狀態變化（見檔頭「對方在等待過程中徹底消失」一節）"
  fi

  cur_stamp="$(printf '%s' "$observation" | cut -f4)"
  if [ "$cur_stamp" != "$prev_stamp" ]; then
    cur_status="$(printf '%s' "$observation" | cut -f3)"
    printf 'peer=%s status=%s state_change_seq=%s\n' "$peer" "$cur_status" "$cur_stamp"
    exit 0
  fi
  prev_stamp="$cur_stamp"
done
