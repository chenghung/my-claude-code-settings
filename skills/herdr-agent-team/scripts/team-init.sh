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

# hat_json_string <text>
# 把任意文字安全地轉成一個 JSON 字串字面，印出來。tab 的 label 是
# herdr／使用者可自由輸入的文字，可能含引號、反斜線或本身就帶方括號
# （已實測形如 `[1] Orchestrator`），不能像下面對 hat_normalize_name
# 輸出那樣手工拼 `"\"$text\""`——那樣做安全是因為輸出字元集受限，這裡
# 沒有那層保證。改用 jq -Rn --arg 讓 jq 自己處理跳脫（與 set-goal.sh
# 等腳本同名的局部函式做法一致，見那裡的說明）。
hat_json_string() {
  jq -Rn --arg v "$1" '$v'
}

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

# ---- worker 環境守衛：拒絕竊取 orchestrator 名稱與 registry 座標 ----
# launch-worker.sh 建 worker tab 時用 `herdr tab create --env` 一次性
# 注入 AGENT_TEAM_SELF（worker 自己的名字）與 AGENT_TEAM_ROLE（worker
# 的 role）；這兩個變數只在 worker tab 才會出現——orchestrator 是人類
# 直接啟動、跑在自己的終端機/pane 裡的 session，herdr 從來不會替它注
# 入這兩個變數（已讀過 launch-worker.sh 確認：只有建 worker tab 那一
# 步的 `--env` 會設它們）。本腳本只靠 HERDR_WORKSPACE_ID 算名稱，而
# launch-worker.sh 建 worker tab 用的是同一個 HERDR_WORKSPACE_ID，任何
# worker 呼叫到這裡都會算出跟 orchestrator 完全相同的名字：worker 會
# 把自己的 pane rename 成那個名字（herdr 的 agent 名稱同一時間只能屬
# 於一個 pane，這一步等於把名字從 orchestrator pane 搶走），並無條件
# 覆寫 team.json 的 .orchestrator_name／.orchestrator_pane，讓這兩個
# 欄位從此指向那個 worker 的 pane——且不會觸發任何警報：看門狗只在名
# 字整個查不到時才會響，名字被搶走時仍查得到，只是掛在錯的 pane 上。
# 因此偵測到任一變數存在就必須整個拒絕，且要在讀 $name、呼叫任何
# herdr 指令、寫入 team.json 任何欄位之前就擋下，不能有一步先做了才回
# 頭失敗——跟上面 HERDR_ENV／HERDR_WORKSPACE_ID／HERDR_PANE_ID 三道既
# 有守衛同一種寫法。用的結束碼是 9：team-init.sh 目前用過的 2／3／4
# 分別代表呼叫端用錯參數／HERDR_ENV 不成立／缺必要座標，這裡的性質不
# 一樣（呼叫端身分本身就不該呼叫這支腳本），不沿用既有語意；本檔頭沒
# 有正式的結束碼列表，因此直接把語意寫在這則錯誤訊息裡。
if [ -n "${AGENT_TEAM_SELF:-}" ] || [ -n "${AGENT_TEAM_ROLE:-}" ]; then
  hat_die 9 "team-init.sh: 偵測到 AGENT_TEAM_SELF 或 AGENT_TEAM_ROLE 已設定，判斷目前是 worker 環境（這兩個變數只由 launch-worker.sh 建立 worker tab 時注入，orchestrator 自己的 session 不會有）。team-init.sh 是 orchestrator 專用的自我命名工具，worker 不得呼叫：呼叫下去會把 worker 自己的 pane 改名成 orchestrator 的名字，並覆寫 team.json 的 .orchestrator_name／.orchestrator_pane，等於竊取 orchestrator 的名稱與 registry 座標。拒絕執行，未呼叫任何 herdr 指令，也未寫入任何 registry 欄位"
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

# ---- 記錄 tab id 與原始 label（規格「設計項目三」的前置資料）----
# tab id 直接從上面已經拿到的 `agent get` 回應取（已實測 herdr 0.9.1
# `.result.agent.tab_id` 即為此值，不需要另外呼叫）；label 沒有現成回
# 應可用，另外查一次 `herdr tab get`（已實測 `.result.tab.label` 即為
# 此值，例如 `[1] Orchestrator`）。tab_id 在回應裡缺席時整段跳過、不
# 算失敗——目前沒有已知會讓它缺席的情境，但寫法上不假設它一定存在。
#
# ---- .orchestrator_tab 只在還沒記錄過時才寫、不是每次都覆寫；
#      .orchestrator_tab_label 只要還缺席就有機會補上，即使
#      .orchestrator_tab 已經記錄過（獨立審查 Critical 修正）----
# .orchestrator_tab_label 記的是「原始」label，是 --recover 還原時的
# 比對基準與還原目標。report.sh（第二批）會用 `herdr tab rename` 把這
# 個 tab 的 label 改成警示字樣；若本段對已經有值的 .orchestrator_tab_
# label 無條件覆寫，遇到「警報還沒被 --recover 處理掉、卻又跑了一次不
# 帶 --recover 的 team-init.sh」這種情況，會把警示字樣錯當成「原始」值
# 存起來，往後 --recover 比對「目前 label 與記錄值」會判定兩者相同而不
# 還原，警示字樣就永久回不去了——因此保護對象只限「已經有值」的
# .orchestrator_tab_label，不是這整個重入判斷式。
#
# 舊版把 .orchestrator_tab 存不存在當成唯一的重入守衛，兩個欄位綁在同
# 一個判斷式下：若第一次執行時 `agent get` 成功、但緊接著的 `tab get`
# 遇到暫態失敗，.orchestrator_tab 已經無條件寫入、.orchestrator_tab_
# label 卻因為 tab_label 是空字串而被跳過——之後任何一次重跑（含
# --recover）都會因為 .orchestrator_tab 已經非空而整段跳過，
# .orchestrator_tab_label 永遠沒有機會被補上，讓依賴這兩個欄位皆存在
# 才會拉警報的 `hat_alert_orchestrator_tab` 對這個 team 永久靜默失能。
# 修法：兩個欄位分別判斷是否需要補寫——.orchestrator_tab 缺席時才用這
# 次 `agent get` 拿到的 tab_id 寫入且僅寫一次；.orchestrator_tab_label
# 只要缺席，不論 .orchestrator_tab 是否已經記錄過，都嘗試查一次
# `tab get` 補上。orchestrator_pane／orchestrator_name 不受這個風險影
# 響（沒有其他腳本會把它們改寫成需要保護的臨時狀態），可以放心每次都
# 覆寫。
#
# ---- 盡力而為：這裡的 `tab get` 失敗不得讓整支腳本被 errexit 帶走
#      （獨立審查修正）----
# 上面的自我命名（`agent rename`）這時已經成功執行過；這段查 tab id／
# label 純粹是裝飾性的記錄，失敗只代表「這次記不到 label」，不代表自我
# 命名失敗。裸賦值在本檔 `set -euo pipefail` 之下會讓 herdr 任何一次失
# 敗直接以 errexit 終止整支腳本、印不出檔尾 `orchestrator=... registry=
# ...` 那行成功訊息，讓呼叫端誤判成自我命名失敗——手法同 lib/common.sh
# `hat_alert_orchestrator_tab` 對同類 `tab get` 呼叫的既有做法：`|| rc=$?`
# 接住失敗，只在 stderr 留一行說明，tab_label 留空；`.orchestrator_tab`
# 已經記錄過時本來就不需要這次呼叫（來自上面的 `agent get` 回應或既有
# 記錄），不受這次失敗影響；只有依賴這次呼叫結果的 `.orchestrator_tab_
# label` 略過。
existing_tab="$(jq -r '.orchestrator_tab // empty' "$registry_root/team.json")"
existing_tab_label="$(jq -r '.orchestrator_tab_label // empty' "$registry_root/team.json")"
if [ -z "$existing_tab" ] || [ -z "$existing_tab_label" ]; then
  if [ -n "$existing_tab" ]; then
    tab_id="$existing_tab"
  else
    tab_id="$(printf '%s' "$current_json" | jq -r '.result.agent.tab_id // empty')"
  fi
  if [ -n "$tab_id" ]; then
    rc=0
    tab_json="$(hat_herdr tab get "$tab_id")" || rc=$?
    tab_label=""
    if [ "$rc" -ne 0 ]; then
      printf 'team-init.sh: 無法讀取 tab %s 的 label，這次不補上 label\n' "$tab_id" >&2
    else
      tab_label="$(printf '%s' "$tab_json" | jq -r '.result.tab.label // empty')"
    fi

    if [ -z "$existing_tab" ]; then
      hat_json_set "$registry_root/team.json" '.orchestrator_tab' "\"$tab_id\""
    fi
    if [ -z "$existing_tab_label" ] && [ -n "$tab_label" ]; then
      hat_json_set "$registry_root/team.json" '.orchestrator_tab_label' "$(hat_json_string "$tab_label")"
    fi
  fi
fi

if [ "$recover" -eq 1 ]; then
  # ---- 警報還原：把 tab label 改回 .orchestrator_tab_label 記錄的原
  #      始值（規格「設計項目三」指定的還原時機）----
  # report.sh（第二批）偵測到投遞對象是 agent_not_found 時，會用
  # `herdr tab rename` 把這個 tab 的 label 改成警示字樣，讓人在 herdr
  # 的 tab 列上直接看得到；警報本身不會自動清除，因為「orchestrator
  # 名稱消失」這件事只有等人真的回來跑 --recover，才代表有人已經處理
  # 過。兩個欄位任一缺席（含尚未走過上面「記錄 tab id 與原始 label」
  # 那段的舊 registry）都跳過，不算失敗。目前 label 已經等於記錄值時
  # 不呼叫 `herdr tab rename`，避免每次 --recover 都多打一次寫入型呼
  # 叫（沒有警報要清時，這是常態）。
  #
  # ---- 盡力而為：這兩次 herdr 呼叫失敗都不得讓整支 --recover 被
  #      errexit 中止（獨立審查修正）----
  # 這兩行原本是裸賦值／裸陳述句，任一次 herdr 失敗都會在本檔
  # `set -euo pipefail` 之下讓 errexit 直接終止整支腳本——而這兩行排
  # 在下面「收回持有旗標與升級閂鎖」那段之前，中斷恢復真正的安全網會
  # 因此完全沒有機會執行。手法同上面「記錄 tab id 與原始 label」一
  # 節、也同 lib/common.sh `hat_alert_orchestrator_tab` 對同類呼叫的
  # 既有做法：`|| rc=$?` 接住失敗，只在 stderr 留一行說明，警報還原
  # 這一步盡力而為地放棄，不影響下面收回旗標與閂鎖繼續執行。
  recorded_tab="$(jq -r '.orchestrator_tab // empty' "$registry_root/team.json")"
  recorded_tab_label="$(jq -r '.orchestrator_tab_label // empty' "$registry_root/team.json")"
  if [ -n "$recorded_tab" ] && [ -n "$recorded_tab_label" ]; then
    rc=0
    current_tab_json="$(hat_herdr tab get "$recorded_tab")" || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf 'team-init.sh --recover: 無法讀取 tab %s 目前的 label，跳過警報還原（不影響下面收回持有旗標與升級閂鎖）\n' "$recorded_tab" >&2
    else
      current_tab_label="$(printf '%s' "$current_tab_json" | jq -r '.result.tab.label // empty')"
      if [ "$current_tab_label" != "$recorded_tab_label" ]; then
        rc=0
        hat_herdr tab rename "$recorded_tab" "$recorded_tab_label" >/dev/null || rc=$?
        if [ "$rc" -ne 0 ]; then
          printf 'team-init.sh --recover: tab rename %s 失敗，警報字樣可能仍未還原（不影響下面收回持有旗標與升級閂鎖）\n' "$recorded_tab" >&2
        fi
      fi
    fi
  fi

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
