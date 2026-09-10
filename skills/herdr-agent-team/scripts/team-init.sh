#!/usr/bin/env bash
#
# skills/herdr-agent-team/scripts/team-init.sh
#
# 用法：team-init.sh [--recover]
#
# 主流程（規格 §6 第 1 步、2.5；--recover 與否都會跑，見下方）：
#   1. 驗 HERDR_ENV。
#   2. 確保 team home（AGENT_TEAM_HOME，未設時取 PWD）底下的 .tmp 可
#      用——經由 hat_registry_init → hat_registry_root → hat_project_tmp
#      間接呼叫，三者皆幂等。
#   3. hat_registry_init：幂等建立 registry 根與七個子目錄、空
#      team.json。
#   4-6. 自我命名：由人類直接啟動的 session，在 herdr 的 agent 清單裡
#      沒有 name 欄位（已對真實 herdr 實測確認）；worker 因此沒有位址
#      可以把訊息送回 orchestrator，除非 orchestrator 先替自己命名。用
#      HERDR_PANE_ID 當 rename 的目標，因為命名之前還沒有名字可用。名
#      稱與 pane id 一起寫進 team.json——pane id 是名稱被清空時的備援
#      位址（herdr 官方文件：名稱會在該 agent 結束、被釋放、或被取代
#      時清空）。
#
# ---- 幂等：讀後判斷，不假設 herdr 對「rename 到同一個名稱」本身安全 ----
# 是否已經命名過，靠先呼叫 `agent get` 讀目前的 .result.agent.name，
# 跟目標名稱比對；已經相同就跳過 rename 呼叫。這樣完全不需要知道「對
# 一個已經叫這個名字的 agent 再 rename 成同一個名字」在 herdr 端是否安
# 全——那件事未經查證，也沒有無副作用的方式可以查證（要製造這個狀態本
# 身就得先真的 rename 一次）。
#
# 這一步不是只做一次：herdr 文件明講名稱會在 agent 結束、被釋放、或被
# 取代時清空，所以中斷恢復時可能要重新命名。因此整支腳本（含自我命
# 名）在有沒有帶 --recover 的兩種情況下走的是同一套主流程，--recover
# 只是在主流程之外，另外多做兩件事：
#
#   - 把所有 workers/*.json 裡留在 true 的持有旗標收回成 false：這面
#     旗標卡在 true 的 worker 會被 watchdog 永久跳過自動推進，且不會
#     有任何錯誤訊息（規格 §13）。
#   - 在 stdout 逐行印出還有待補送的 worker
#     （pending-resend worker=<名稱> count=<筆數>）。
#
# ---- 順序警告：--recover 只收回旗標，絕對不自行補送 ----
# 補送必須排在重掛 watchdog 之前、收回旗標之後，由 orchestrator 依這裡
# 印出的清單逐一呼叫 instruct.sh。順序顛倒的話，補送設下的新旗標會被
# watchdog 補發事件的處理流程當成「上一輪沒收回的殘留」而收掉。本腳本
# 因此只讀 pending_resend 算筆數、只印出清單，不呼叫任何會送出訊息的
# herdr 指令，也不清空或改寫 pending_resend 本身——那份清單要留給呼叫
# 端逐一消化。

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

hat_require_herdr_env

recover=0
if [ "$#" -gt 1 ]; then
  hat_die 2 "team-init.sh: 用法：team-init.sh [--recover]"
fi
if [ "$#" -eq 1 ]; then
  if [ "$1" = "--recover" ]; then
    recover=1
  else
    hat_die 2 "team-init.sh: 未知參數 '$1'（用法：team-init.sh [--recover]）"
  fi
fi

workspace_id="${HERDR_WORKSPACE_ID:-}"
if [ -z "$workspace_id" ]; then
  hat_die 4 "team-init.sh: HERDR_WORKSPACE_ID 未設，無法命名或推導 registry 路徑"
fi

pane_id="${HERDR_PANE_ID:-}"
if [ -z "$pane_id" ]; then
  hat_die 4 "team-init.sh: HERDR_PANE_ID 未設，無法自我命名"
fi

team_home="${AGENT_TEAM_HOME:-$PWD}"

# hat_registry_init 內部經由 hat_registry_root 呼叫 hat_project_tmp，
# 確保 team_home/.tmp 可用；三者皆幂等，重跑不清空既有狀態。
hat_registry_init
registry_root="$(hat_registry_root)"

name="$(hat_normalize_name "$workspace_id" orchestrator)"

current_json="$(hat_herdr agent get "$pane_id")"
current_name="$(printf '%s' "$current_json" | jq -r '.result.agent.name // empty')"
if [ "$current_name" != "$name" ]; then
  hat_herdr agent rename "$pane_id" "$name" >/dev/null
fi

hat_json_set "$registry_root/team.json" '.orchestrator_name' "\"$name\""
hat_json_set "$registry_root/team.json" '.orchestrator_pane' "\"$pane_id\""
hat_json_set "$registry_root/team.json" '.team_home' "\"$team_home\""

if [ "$recover" -eq 1 ]; then
  # ---- 收回殘留持有旗標＋回報待補送清單，不自行補送 ----
  # .held 的正常值就包含 false（不是缺漏的訊號）；hat_json_get 已能正
  # 確區分「欄位缺漏」（5 結束）與「值合法地是 false」（正常回傳該
  # 值），直接用它讀取即可，不必繞去自己呼叫 jq。
  while IFS= read -r worker; do
    worker_file="$registry_root/workers/$worker.json"

    held="$(hat_json_get "$worker_file" '.held')"
    if [ "$held" = "true" ]; then
      hat_json_set "$worker_file" '.held' 'false'
    fi

    # pending_resend 的筆數用純 jq 算：hat_json_get 只回傳單一純量或
    # 判斷缺漏，不提供「陣列長度」這種衍生值；欄位整個缺席時
    # `null | length` 在 jq 裡本來就是 0，不需要另外防呆。
    pending_count="$(jq '.pending_resend | length' "$worker_file")"
    if [ "$pending_count" -gt 0 ]; then
      printf 'pending-resend worker=%s count=%s\n' "$worker" "$pending_count"
    fi
  done < <(hat_worker_list)
fi

printf 'orchestrator=%s registry=%s\n' "$name" "$registry_root"
