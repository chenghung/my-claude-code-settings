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
# 只是在主流程之外，另外多做三件事：
#
#   - 把所有 workers/*.json 裡留在 true 的持有旗標收回成 false：這面
#     旗標卡在 true 的 worker 會被 watchdog 永久跳過自動推進，且不會
#     有任何錯誤訊息（規格 §13）。
#   - 把所有 worker 記錄的升級閂鎖一併收回：見下方「升級閂鎖收回」一
#     節。
#   - 在 stdout 逐行印出還有待補送的 worker
#     （pending-resend worker=<名稱> count=<筆數>），純粹告知積壓量。
#
# ---- --recover 只收回旗標與閂鎖，絕對不自行補送 ----
# instruct.sh 對 .pending_resend 只會追加、從不移除；移除的唯一呼叫端
# 是 watchdog.sh 的補投（見該檔「投遞重試與待補送補投」一節 b)）。排空
# 完全交給看門狗自己做：worker 離開 blocked 之後，看門狗逐筆補投，成
# 功一筆就移除一筆，不需要 orchestrator 手動介入——若在這裡或呼叫端手
# 動呼叫 instruct.sh 補送，看門狗掛上之後還會再補投同一筆，收件方會收
# 到重複下行；收件方若還卡在 blocked，手動補送反而會再追加一筆重複進
# 佇列，讓積壓變多。本腳本因此只讀 pending_resend 算筆數、印出清單告
# 知積壓量，不呼叫任何會送出訊息的 herdr 指令，也不清空或改寫
# pending_resend 本身。
#
# 排空的前提是收件方要先離開 blocked，而沒有任何機制會讓它自己離開：
# 核准框要有人去處理（讀畫面判讀、呼叫 press-approval.sh），不去處理
# 那個框，積壓就會一直卡著、全程靜默。
#
# ---- 升級閂鎖收回：跨 orchestrator 重啟不得殘留（線上故障修正新增）
#      ----
# .escalation_active／.escalation_last_at（見 lib/common.sh 欄位白名單
# 一節、watchdog.sh「升級去重」一節）讓同一個升級條件只在剛成立的那一
# 輪送出一次，之後最多每隔 AGENT_TEAM_ESCALATION_REPEAT_SECONDS 秒重
# 提一次；它保護的是 orchestrator 的 context 不被同一句話洗版。但
# orchestrator session 重啟正好就是 context 被清空的那一刻——閂鎖記的
# 東西在那一刻已經沒有保護對象了：一個在重啟前就卡著、條件仍然成立的
# worker，會因為閂鎖還記著「剛發過」，最長要再等一個重提間隔（預設
# 1800 秒）才會重新提醒，新的 session 對一個仍卡住的 worker 最長沉默
# 半小時。
#
# 修法：--recover 一併把所有 worker 記錄的 .escalation_active 清成
# null（跟 watchdog.sh 的 hat_wd_escalation_clear 同一種清法，但不能
# 直接呼叫那個函式——watchdog.sh 檔尾是無界輪詢迴圈的頂層程式碼，被
# source 進來會立刻執行，不能把它當函式庫用），讓重掛看門狗之後，仍
# 然成立的條件能立刻重新升級一次，不被上一個 session 留下的閂鎖壓
# 抑。不動 .escalation_last_at：一旦 .escalation_active 被清空，
# hat_wd_escalate_once 比對「目前條件跟閂鎖記的是否相同」這一步就已
# 經是假，後面看 .escalation_last_at 算經過時間的分支根本不會執行
# 到，不需要一併清。
#
# 這是 .escalation_active／.escalation_last_at 欄位白名單分配表的例
# 外：正常運作時只有 watchdog.sh 寫，本腳本的 --recover 是唯一的例
# 外。理由跟 .held 已有的先例相同——中斷恢復的當下，上一個 session 的
# watchdog.sh 行程已經不在，不存在兩個寫入端同時活著互相覆蓋的競態。
# 已同步更新 lib/common.sh 欄位白名單一節的分配表註解。

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
  # ---- 收回殘留持有旗標＋升級閂鎖，回報待補送清單，不自行補送 ----
  # .held 的正常值就包含 false（不是缺漏的訊號）；hat_json_get 已能正
  # 確區分「欄位缺漏」（5 結束）與「值合法地是 false」（正常回傳該
  # 值），直接用它讀取即可，不必繞去自己呼叫 jq。
  while IFS= read -r worker; do
    worker_file="$registry_root/workers/$worker.json"

    held="$(hat_json_get "$worker_file" '.held')"
    if [ "$held" = "true" ]; then
      hat_json_set "$worker_file" '.held' 'false'
    fi

    # ---- 升級閂鎖收回（見檔頭「升級閂鎖收回」一節）----
    # .escalation_active 缺席（從未升級過，或上一輪已經清過）時是安全
    # 的無動作，不多寫一次；用 jq 直接讀（不是 hat_json_get）是因為缺
    # 席在這裡是正常狀態，不是 registry 壞了。
    escalation_active="$(jq -r '.escalation_active // empty' "$worker_file")"
    if [ -n "$escalation_active" ]; then
      hat_json_set "$worker_file" '.escalation_active' 'null'
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
