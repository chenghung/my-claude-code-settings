#!/usr/bin/env bash
#
# skills/herdr-agent-team/scripts/launch-worker.sh
#
# 用法：
#   launch-worker.sh --role <名稱> --kind <kind> --cwd <路徑> \
#     --briefing-file <路徑> [--arg <原生引數>]... [--ack-timeout <秒>]
#
# 成功時 stdout 印出一行：`worker=<名稱> pane=<id> tab=<id> ack=ok`。
#
# ---- 這是整個 skill 風險最高的一支：規格 §2.3 量到啟動路徑上有兩個訊
#      號會說謊 ----
# 第一，`agent start` 回報成功（rc=0）不是就緒憑據——已實測 codex 與
# agy 都在 3.9 秒以 rc=0 回報就緒，但那時 CLI 的介面根本還沒起來。第
# 二，送出啟動包之後的握手成功也不代表送達——已實測在 codex 上得到握
# 手成功，但那則訊息永遠不會執行：codex 自己的版本更新提示框吃掉了送
# 出的 Enter，並讓輸入框永久髒掉，而握手依然回報 rc=0 成功。
#
# 這兩件事合起來的後果是：呼叫端以為指令已送達，而那則指令永遠不會執
# 行，也沒有任何錯誤訊息。唯一可信的就緒訊號是 worker 自己回的第一則
# `ack`（規格 §6 第 7 步）。因此本腳本結構上分兩層：
#   - 「這次啟動嘗試成功了嗎」只由等到 ACK 決定，前面幾步（tab
#     create、agent start、agent get、agent prompt 的握手）全部只是取
#     得座標與觸發動作的手段，它們的成功／失敗都不能單獨拿來宣告就緒。
#   - 但 agent start 失敗（含逾時）與撞到 blocked，兩者都必須在送出啟
#     動包「之前」攔下來，否則會踩上 §2.3 那個致命發現：第一則訊息被
#     啟動框吃掉，而握手還回報成功。
#
# ---- 八步序列（規格 §6，順序不得調換）----
#   1. 自我命名已由 team-init.sh 完成；本腳本只確認 team.json 有
#      orchestrator_name（沒有以 5 結束——這代表 team 根本還沒初始化，
#      不是「初始化過但條件不成立」），並呼叫 hat_require_goal_confirmed
#      （人類確認之前派不出任何一個 worker，未確認以 4 結束）。
#   2. 建 tab：`herdr tab create --workspace ... --cwd ... --label
#      <role> --no-focus --env` 五次注入五個變數。取不到 tab_id 與
#      pane_id 任一個就立刻以 6 結束，不寫 registry。
#   3. 寫 registry：座標、agent 名稱、kind、role、cwd、原生引數、持有
#      旗標初值，在啟動之前就寫齊；同一步把 --briefing-file 的內容複
#      製進 briefings/<worker>.md。複製失敗即以 5 結束，不繼續啟動。
#   4. `agent start`：成功不是就緒憑據，只代表 herdr 認為那個 pane 裡
#      有一個它認得的 agent。失敗（含逾時）判定本次嘗試失敗。
#   5. 確認不在 blocked：送任何東西之前先查一次狀態。落在 blocked 就
#      是撞上 CLI 自己的啟動框，判定本次嘗試失敗；本腳本不呼叫代按腳
#      本，代按需要調查者先讀畫面判讀那個框放行什麼，那是 orchestrator
#      的判斷。
#   6. 送啟動包：握手仍然做，但結果只用來分辨「送不出去」與「可能送到
#      了」，不用來宣告就緒，握手失敗也不判定本次嘗試失敗。
#   7. 等 ACK：輪詢 inbox/ 直到出現這個 worker 的 ack，或逾時。逾時判
#      定本次嘗試失敗，不論前面幾步回報什麼。
#   8. 對帳：ACK 帶回的 worker-id、實際工作目錄、實際 model 三項與啟
#      動時指定的比對，結果寫進 workers/<name>.json 的
#      ack_reconciliation。權威是 orchestrator 傳出去的參數，不是
#      worker 說的。
#
# ---- 啟動失敗的處置：關掉那個 tab 重來一次，第二次仍失敗才以 8 結束
#      ----
# 只有第 4／5／7 步判定的「啟動失敗」會觸發這個重試（第 2 步識別碼取
# 不到以 6 結束、第 3 步複製失敗以 5 結束，兩者都是更根本的問題，不重
# 試、立刻結束）。絕對不重用一個沒有回 ACK 的 agent——它的輸入框可能
# 已經髒了，而那個狀態從外面看不出來，唯一乾淨的作法是換一個 pane。
# 這也是為什麼第 3 步要把座標先寫進 registry：關得掉，才重得來。
#
# ---- .held 初值必須在建立 worker 記錄的同一步寫入，不可缺席 ----
# team-init.sh --recover 逐一讀取每個 worker 的 .held 決定要不要收回；
# 若這個欄位整個缺席，hat_json_get 會以 5 終止整支 --recover，可能留
# 下部分收旗標、部分未收的狀態（Task 3 審查時已標註這個風險，留給本任
# 務緩解）。本腳本因此在第 3 步無條件把 .held 寫成 false，讓這個欄位
# 對任何一個由本腳本建立的 worker 記錄永不缺席。
#
# ---- 入口守衛：hat_assert_workspace 用在新建的座標上 ----
# 本腳本不像 instruct.sh／press-approval.sh 等腳本那樣「接受呼叫端傳
# 入的既有 target」，它自己建立座標。三道 workspace 守衛裡唯一擋得住
# 「誤觸別的 team」的一道，套用在這裡就是：tab create 一回來，立刻對
# 剛拿到的 pane_id 斷言它確實屬於本 workspace，早於任何 registry 寫
# 入。日常情況下這裡幾乎不會真的觸發（因為 tab create 本來就是帶著
# --workspace "$HERDR_WORKSPACE_ID" 呼叫的），但它擋的是 herdr 回應與
# 呼叫不一致的情形，而不是使用者輸入錯誤。
#
# ---- ACK 摘要格式：本腳本定義的介面，Task 7（report.sh）與 Task 13
#      （briefing-template.md）必須遵守 ----
# 規格只說 ack 要「帶自己的 worker-id、實際工作目錄與實際 model」，沒
# 有規定這三項怎麼從 report.sh 的 --summary（唯一保證會被送達的欄
# 位，--detail-file 是選填的）搭載過來。本腳本認定的格式是空白分隔的
# `worker_id=<id> cwd=<路徑> model=<名稱>`（三個值本身都不得含空白）。
# 這個假設沒有任何測試涵蓋（不影響啟動成功與否，純粹是對帳欄位的內
# 容），也還沒有寫回 Task 7／Task 13 的任務簡報——回報這個落差是本次
# 實作的職責，回頭修簡報是編排端的職責，見任務報告。
#
# ---- 摘要解析失敗不影響啟動結果 ----
# ack_reconciliation 只負責記錄與比對，本身從不改變結束碼：ACK 有沒有
# 抵達才是啟動成功與否的唯一判準（規格 §6 第 7 步）。

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

hat_require_herdr_env

# ---- herdr agent start 逾時：已用當前這台機器上真實 herdr 0.8.2 的
#      `herdr agent start --help` 查證，預設 30000、上限 300000。這裡
#      明確帶入而不是依賴隱含預設，日後 herdr 改了預設值也不會讓本腳
#      本的行為跟著意外改變（沿用 skills/epic-orchestration/scripts/
#      start-phase.sh 對同一個常數的既有做法與理由）。
readonly HAT_AGENT_START_TIMEOUT_MS=30000

# ---- ACK 輪詢間隔與預設逾時：兩者都沒有實測依據（規格 §15 未驗清單
#      「回報靜默逾時的門檻要設多少」是同一種校準缺口在啟動路徑上的對
#      應版本）。呼叫端可用 --ack-timeout 覆寫預設值；輪詢間隔不開放
#      覆寫，因為它只影響偵測延遲，不影響正確性。
readonly HAT_ACK_POLL_INTERVAL_SECONDS=1
readonly HAT_DEFAULT_ACK_TIMEOUT_SECONDS=120

# hat_json_string <text>
# 把任意文字安全地轉成一個 JSON 字串字面並印出來。role／cwd 等值理論
# 上可能含引號或反斜線，不能像正規化過的 agent 名稱那樣手工拼引號；改
# 用 jq -Rn --arg 讓 jq 自己處理跳脫（與 set-goal.sh 的同名局部函式做
# 法相同，兩支腳本各自獨立定義，不共用，理由見 set-goal.sh 檔頭）。
hat_json_string() {
  jq -Rn --arg v "$1" '$v'
}

role="" kind="" work_cwd="" briefing_file=""
ack_timeout="$HAT_DEFAULT_ACK_TIMEOUT_SECONDS"
declare -a native_args=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --role)
      [ "$#" -ge 2 ] || hat_die 2 "launch-worker.sh: --role 缺值"
      role="$2"; shift 2 ;;
    --kind)
      [ "$#" -ge 2 ] || hat_die 2 "launch-worker.sh: --kind 缺值"
      kind="$2"; shift 2 ;;
    --cwd)
      [ "$#" -ge 2 ] || hat_die 2 "launch-worker.sh: --cwd 缺值"
      work_cwd="$2"; shift 2 ;;
    --briefing-file)
      [ "$#" -ge 2 ] || hat_die 2 "launch-worker.sh: --briefing-file 缺值"
      briefing_file="$2"; shift 2 ;;
    --arg)
      [ "$#" -ge 2 ] || hat_die 2 "launch-worker.sh: --arg 缺值"
      native_args+=("$2"); shift 2 ;;
    --ack-timeout)
      [ "$#" -ge 2 ] || hat_die 2 "launch-worker.sh: --ack-timeout 缺值"
      ack_timeout="$2"; shift 2 ;;
    *)
      hat_die 2 "launch-worker.sh: 未知參數 '$1'" ;;
  esac
done

if [ -z "$role" ] || [ -z "$kind" ] || [ -z "$work_cwd" ] || [ -z "$briefing_file" ]; then
  hat_die 2 "launch-worker.sh: --role／--kind／--cwd／--briefing-file 四項全部必填"
fi

case "$ack_timeout" in
  ''|*[!0-9]*)
    hat_die 2 "launch-worker.sh: --ack-timeout 必須是純數字秒數，收到：$ack_timeout" ;;
esac

if [ ! -f "$briefing_file" ]; then
  hat_die 2 "launch-worker.sh: --briefing-file 指向的檔案不存在：$briefing_file"
fi

# provider 白名單：清單外的 kind 在啟動之前就拒絕（規格 §5），不是啟
# 動之後才發現偵測不出來。
hat_assert_supported_kind "$kind"

workspace_id="${HERDR_WORKSPACE_ID:-}"
if [ -z "$workspace_id" ]; then
  hat_die 4 "launch-worker.sh: HERDR_WORKSPACE_ID 未設，無法建立 tab"
fi

registry_root="$(hat_registry_root)"
team_json="$registry_root/team.json"

# ---- 第 1 步：自我命名已由 team-init.sh 完成；開工閘門 ----
# team.json 沒有 orchestrator_name 代表 team-init.sh 根本還沒跑過；
# hat_json_get 對缺漏欄位本來就以 5 結束，這裡不需要另外分支處理。
orchestrator_name="$(hat_json_get "$team_json" '.orchestrator_name')"

# 人類確認之前派不出任何一個 worker（規格 §9 開工閘門）。
hat_require_goal_confirmed

name="$(hat_normalize_name "$workspace_id" "$role")"
worker_file="$registry_root/workers/$name.json"

# 原生引數只在這裡序列化一次（跟嘗試次數無關）。空陣列時不能直接展開
# `"${native_args[@]}"`——bash 4.3 對 `set -u` 下的空陣列展開會報
# unbound variable（4.4 才修掉這個行為），因此先用長度判斷再決定要不
# 要展開／要不要建構陣列（沿用 skills/pr-review-by-multi-agents/
# scripts/run-review.sh 已有的 `"${arr[@]+"${arr[@]}"}"` 慣例）。
if [ "${#native_args[@]}" -eq 0 ]; then
  args_json='[]'
else
  args_json="$(printf '%s\n' "${native_args[@]}" | jq -R . | jq -s -c .)"
fi

attempt=1
launch_ok=0
last_failure_reason=""
tab_id="" pane_id="" ack_summary=""

while [ "$attempt" -le 2 ]; do
  attempt_failed=0
  failure_reason=""

  # ---- 第 2 步：建 tab ----
  # 裸賦值（不接 `|| rc=$?`）刻意讓 hat_herdr 對這通呼叫本身的失敗（herdr
  # 拒絕、語法錯誤）直接透過 errexit 帶著它自己已經映射好的結束碼（6
  # 或 2）終止整支腳本；這與 team-init.sh 對 `agent get` 的既有寫法同
  # 一個理由——這一類失敗是「呼叫本身不成立」，不屬於下面「啟動失敗可
  # 重試一次」的範疇。
  tab_json="$(hat_herdr tab create --workspace "$workspace_id" --cwd "$work_cwd" \
    --label "$role" --no-focus \
    --env "AGENT_TEAM_STATE_DIR=$registry_root" \
    --env "AGENT_TEAM_ORCHESTRATOR=$orchestrator_name" \
    --env "AGENT_TEAM_SELF=$name" \
    --env "AGENT_TEAM_ROLE=$role" \
    --env "AGENT_TEAM_SCRIPTS=$SCRIPT_DIR")"

  tab_id="$(printf '%s' "$tab_json" | jq -r '.result.tab.tab_id // empty')"
  pane_id="$(printf '%s' "$tab_json" | jq -r '.result.root_pane.pane_id // empty')"

  # jq 帶 `// empty` 之後：路徑缺席或值真的是 JSON null 都會印出空字
  # 串；但若酬載裡的值本身就是「字串型別的 null」（例如 `"tab_id":
  # "null"`），`// empty` 不會攔下它——空字串與非 null 值對 `//` 而言
  # 都是真值，只有 JSON null／false 才會被換成 empty（已用真實 jq
  # 1.8.2 對三種資料形狀各自實測：字串 "null"、JSON null、路徑缺席，
  # 前者印出 "null" 文字、後兩者印出空字串）。所以要同時擋空字串與字
  # 面字串 "null"，兩者都代表「這個識別碼不可信」；取不到就立刻結
  # 束，正常情況下（第一次嘗試）不寫 registry——寫進去會留下一筆座標
  # 指不到任何東西、而且再也關不掉的孤兒記錄。
  if [ -z "$tab_id" ] || [ "$tab_id" = "null" ] || [ -z "$pane_id" ] || [ "$pane_id" = "null" ]; then
    # ---- 重試路徑上的孤兒記錄：上一次嘗試留下的座標已經隨重試關閉，
    #      這裡不能讓它繼續躺在 registry 裡假裝是正常在途的 worker ----
    # `attempt > 1` 在這個迴圈的控制流程下等價於「上一次嘗試已經走過
    # 第 2 步（拿到合法識別碼）與第 3 步（把座標寫進 worker_file）」：
    # 唯一能讓 `attempt` 增加的路徑是第 4／5／7 步判定啟動失敗，而那三
    # 步全部排在第 2／3 步之後才會執行到。因此走到這裡且 `attempt` 大
    # 於 1 時，`worker_file` 必然存在、且其座標就是剛剛被關掉的那個
    # tab——繼續留著它會被恢復模式／狀態查詢當成合法的在途 worker，而
    # 它其實什麼都不是。必須把這筆記錄一併移除，訊息也要照實說「這是
    # 重試路徑，上一筆記錄已清除」，不能沿用第一次嘗試那句「未寫入
    # registry」——那句話在這裡是假的，會讓讀訊息的人以為 registry 一
    # 直是乾淨的。
    if [ "$attempt" -gt 1 ]; then
      rm -f "$worker_file"
      hat_die 6 "launch-worker.sh: 重試時 tab create 回報成功，但回應裡取不到可用的識別碼（tab_id='$tab_id' pane_id='$pane_id'）。第 $((attempt - 1)) 次嘗試留下的 registry 記錄（座標已隨重試關閉，指向一個已死的 tab）已一併移除，不留下孤兒記錄。這次的 tab 可能已經真的建立，請以 workspace $workspace_id、label $role 人工確認並關閉"
    fi
    hat_die 6 "launch-worker.sh: tab create 回報成功，但回應裡取不到可用的識別碼（tab_id='$tab_id' pane_id='$pane_id'），未寫入 registry。tab 可能已經真的建立，請以 workspace $workspace_id、label $role 人工確認並關閉"
  fi

  # 入口守衛：剛拿到的座標必須真的屬於本 workspace，見檔頭「入口守
  # 衛」一節。hat_assert_workspace 不成立時會直接 hat_die 4，終止整支
  # 腳本，此處不需要另外處理回傳值。
  hat_assert_workspace "$pane_id"

  # ---- 第 3 步：寫 registry（在啟動之前寫齊，讓失敗時關得掉這個
  #      tab），同一步把啟動包內容複製進 briefings/ ----
  if [ ! -e "$worker_file" ]; then
    printf '{}' > "$worker_file"
  fi
  hat_json_set "$worker_file" '.role' "$(hat_json_string "$role")"
  hat_json_set "$worker_file" '.kind' "$(hat_json_string "$kind")"
  hat_json_set "$worker_file" '.cwd' "$(hat_json_string "$work_cwd")"
  hat_json_set "$worker_file" '.args' "$args_json"
  hat_json_set "$worker_file" '.agent_name' "$(hat_json_string "$name")"
  hat_json_set "$worker_file" '.tab_id' "$(hat_json_string "$tab_id")"
  hat_json_set "$worker_file" '.pane_id' "$(hat_json_string "$pane_id")"
  hat_json_set "$worker_file" '.held' 'false'

  briefing_dest="$registry_root/briefings/$name.md"
  if ! cp "$briefing_file" "$briefing_dest"; then
    hat_die 5 "launch-worker.sh: 啟動包複製失敗，不繼續啟動（worker=$name role=$role src=$briefing_file dest=$briefing_dest）"
  fi

  # ---- 第 4 步：agent start ----
  # 不透過 hat_herdr：失敗（含逾時）要映射成本腳本專屬的「啟動未就
  # 緒」語意（本次嘗試失敗，可能被重試一次），不是 hat_herdr 通用的
  # 「herdr 拒絕」6；語法錯誤（rc=2）仍然是呼叫端用錯，不重試。手法沿
  # 用 skills/epic-orchestration/scripts/start-phase.sh 對同一個呼叫的
  # 既有做法：stderr 先擷取到變數，只取 error.code／error.message 兩
  # 個純字串欄位重組，不讓 herdr 的原始酬載（可能整包帶著終端標題）進
  # 入本腳本呼叫端的 context。
  rc=0
  if err_output="$(herdr agent start "$name" --kind "$kind" --pane "$pane_id" \
      --timeout "$HAT_AGENT_START_TIMEOUT_MS" \
      -- "${native_args[@]+"${native_args[@]}"}" 2>&1 >/dev/null)"; then
    :
  else
    rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    error_code="$(printf '%s' "$err_output" | jq -r '.error.code // empty' 2>/dev/null || true)"
    error_message="$(printf '%s' "$err_output" | jq -r '.error.message // empty' 2>/dev/null || true)"
    [ -n "$error_code" ] || error_code="(無法取得 error.code)"
    [ -n "$error_message" ] || error_message="(無法取得 error.message)"
    if [ "$rc" -eq 2 ]; then
      hat_die 2 "launch-worker.sh: herdr 以結束碼 2 拒絕 agent start，疑似腳本呼叫語法錯誤（agent=$name, pane=$pane_id）：code=$error_code message=$error_message"
    fi
    attempt_failed=1
    failure_reason="agent start 未回報就緒（結束碼 $rc）：code=$error_code message=$error_message。$name 仍可用於 herdr agent read／herdr agent send-keys 人工介入"
  fi

  # ---- 第 5 步：確認不在 blocked（僅在第 4 步未判失敗時才查）----
  # 送任何東西之前先查一次狀態；少了這一步，第一則訊息會被啟動框吃
  # 掉，而握手還會回報成功（規格 §2.3）。裸賦值同第 2 步的理由：查詢
  # 本身的 herdr 層失敗（非「查到 blocked」這個業務結果）直接讓
  # hat_herdr 已映射好的結束碼透過 errexit 終止整支腳本。
  if [ "$attempt_failed" -eq 0 ]; then
    agent_get_json="$(hat_herdr agent get "$name")"
    agent_status="$(printf '%s' "$agent_get_json" | jq -r '.result.agent.agent_status // empty')"
    if [ "$agent_status" = "blocked" ]; then
      attempt_failed=1
      failure_reason="$name 卡在啟動框（agent_status=blocked）：該名稱仍可用於 herdr agent read／herdr agent send-keys 讀畫面與送按鍵，處理完之後重跑本腳本。本腳本不代按——代按需要先讀畫面判讀那個框放行什麼，那是 orchestrator 的判斷"
    fi
  fi

  # ---- 第 6 步：送啟動包 ----
  # 握手仍然做，但握手失敗不等於啟動失敗（規格 §6 第 6 步），因此不影
  # 響 attempt_failed；不透過 hat_herdr（其失敗訊息與映射碼在這裡都用
  # 不到）。結束碼留到第 7 步 ACK 逾時的診斷訊息裡才用得上：等不到
  # ACK 時，握手當時到底回報成功還是失敗，是人判斷「送不出去」與「可
  # 能送到了但沒人回」的第一條線索。
  handshake_rc=""
  if [ "$attempt_failed" -eq 0 ]; then
    briefing_text="$(cat "$briefing_dest")"
    handshake_rc=0
    herdr agent prompt "$name" "$briefing_text" >/dev/null 2>&1 || handshake_rc=$?
  fi

  # ---- 第 7 步：等 ACK ----
  # ACK 沒到就是啟動失敗，不論前面幾步回報什麼（規格 §6 第 7 步）。
  # inbox 檔名格式為 `<seq>-<worker>.json`（沿用 team-init.sh／
  # report.sh 既有慣例），逐一讀取比對 .token 與 .worker 兩個欄位，不
  # 假設「檔名符合這個 pattern」本身就代表是這個 worker 的 ack。
  if [ "$attempt_failed" -eq 0 ]; then
    ack_found=0
    ack_summary=""
    elapsed=0
    while :; do
      while IFS= read -r -d '' inbox_file; do
        tok="$(jq -r '.token // empty' "$inbox_file" 2>/dev/null || true)"
        wk="$(jq -r '.worker // empty' "$inbox_file" 2>/dev/null || true)"
        if [ "$tok" = "ack" ] && [ "$wk" = "$name" ]; then
          ack_summary="$(jq -r '.summary // empty' "$inbox_file" 2>/dev/null || true)"
          ack_found=1
          break
        fi
      done < <(find "$registry_root/inbox" -maxdepth 1 -type f -name "*-$name.json" -print0 2>/dev/null)

      if [ "$ack_found" -eq 1 ]; then
        break
      fi
      if [ "$elapsed" -ge "$ack_timeout" ]; then
        break
      fi
      sleep "$HAT_ACK_POLL_INTERVAL_SECONDS"
      elapsed=$((elapsed + HAT_ACK_POLL_INTERVAL_SECONDS))
    done

    if [ "$ack_found" -ne 1 ]; then
      attempt_failed=1
      failure_reason="等待 ACK 逾時（${ack_timeout} 秒）：worker $name 沒有回報就緒，不論前面幾步回報什麼，這次啟動判定失敗（送出啟動包當時的握手結束碼：${handshake_rc}，僅供診斷，握手失敗不等於啟動失敗）"
    fi
  fi

  if [ "$attempt_failed" -eq 0 ]; then
    launch_ok=1
    break
  fi

  last_failure_reason="$failure_reason"

  # 關掉這次嘗試建立的 tab，讓下一次重試換一個乾淨的 pane；不重用一
  # 個沒有回 ACK 的 agent，它的輸入框可能已經髒了，而那個狀態從外面看
  # 不出來。這裡的失敗是盡力而為，不再往上冒——已經在回報「啟動失
  # 敗」的路上，tab 關不掉不該蓋掉真正的失敗原因。
  hat_herdr tab close "$tab_id" >/dev/null 2>&1 || true

  if [ "$attempt" -ge 2 ]; then
    # ---- 兩次都失敗，終局升級給人：不留下這筆狀態記錄 ----
    # 「記錄存在」這件事對下游（恢復模式、狀態查詢腳本）的語意就是
    # 「這個 worker 是活的、或曾經是活的」，而一次失敗的啟動根本沒有
    # 產生過活的 worker；剛才那一行已經把最後一次嘗試的 tab 關掉了。
    # 留著這筆記錄，恢復模式與狀態查詢腳本會把一個 tab 已經不存在的
    # 東西當成在途 worker 處理，而且沒有任何機制會自動修正——與上面
    # 「重試疊加識別碼取不到」那條路徑是同一個語意（見第 2 步識別碼檢
    # 查那段的既有處理），這裡採一致的做法。追查脈絡的需求不必靠這筆
    # 記錄：啟動包全文已經在第 3 步複製進 briefings/<worker>.md，那份
    # 副本留著就夠回答「當初到底想派什麼」。
    rm -f "$worker_file"
    hat_die 8 "launch-worker.sh: 啟動失敗，已重試一次仍未成功（worker=$name role=$role），升級給人處理。狀態記錄已移除，不留下指向已死 tab 的孤兒記錄；$name 這個名稱仍可用於 herdr agent read／herdr agent send-keys 讀畫面與送按鍵，處理完之後重跑本腳本。最後一次失敗原因：$last_failure_reason"
  fi

  attempt=$((attempt + 1))
done

# 內部一致性檢查：迴圈只能透過「第 8 步之前的 break」（launch_ok=1）
# 或「達到重試上限的 hat_die 8」離開，不應該有第三條路徑。這裡不應該
# 被跑到；若真的跑到，代表迴圈邏輯本身有異常，不得放行到下面的對帳與
# 成功輸出（結束碼 1：由個別腳本自行產生的迴圈異常）。
if [ "$launch_ok" -ne 1 ]; then
  hat_die 1 "launch-worker.sh: 內部錯誤：重試迴圈結束但既未成功也未終止（worker=$name），這是本腳本自身的邏輯異常，不是啟動失敗"
fi

# ---- 第 8 步：對帳 ----
# ack_summary 的格式與解析方式見檔頭「ACK 摘要格式」一節；解析結果只
# 影響這個欄位的內容，不影響本腳本的結束碼。用 tr 把空白換成換行再逐
# 行讀，不動全域 IFS（本腳本開頭已設成 $'\n\t'，不含空白）。
#
# `printf '%s\n'`（而非 `%s`）在轉換前先補一個結尾換行：`while read`
# 對「沒有結尾換行的最後一行」會把內容讀進變數、但迴圈條件本身回報失
# 敗，導致迴圈主體對最後一個 token 完全不執行（已實測：拿掉這個 `\n`
# 會讓字面上排在字串最後面的 model 這個欄位永遠讀不到，即使字串裡明
# 明有這個 token）。三個欄位裡任一個排在最後都會中這個坑，補這個換行
# 讓三者都能被讀到，不只是修一個看起來會中獎的欄位。
reported_worker_id="" reported_cwd="" reported_model=""
while IFS= read -r tok; do
  case "$tok" in
    worker_id=*) reported_worker_id="${tok#worker_id=}" ;;
    cwd=*) reported_cwd="${tok#cwd=}" ;;
    model=*) reported_model="${tok#model=}" ;;
  esac
done < <(printf '%s\n' "$ack_summary" | tr ' ' '\n')

worker_id_match=false
if [ "$reported_worker_id" = "$name" ]; then
  worker_id_match=true
fi
cwd_match=false
if [ "$reported_cwd" = "$work_cwd" ]; then
  cwd_match=true
fi

# model 沒有「啟動時指定的」authoritative 值可比對：原生引數直通不解
# 讀（規格 §5），本腳本不去解析 --arg 清單裡有沒有 --model 之類的旗
# 標，只記錄 worker 回報的值。cwd 出錯是靜默的，CLI 也可能因 quota 或
# 設定覆寫而 fallback 到別的 model——記錄本身就有診斷價值，即使沒有基
# 準可比。
reconciled_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ack_reconciliation_json="$(jq -cn \
  --arg worker_id_expected "$name" \
  --arg worker_id_reported "$reported_worker_id" \
  --argjson worker_id_match "$worker_id_match" \
  --arg cwd_expected "$work_cwd" \
  --arg cwd_reported "$reported_cwd" \
  --argjson cwd_match "$cwd_match" \
  --arg model_reported "$reported_model" \
  --arg reconciled_at "$reconciled_at" \
  '{
    worker_id_expected: $worker_id_expected,
    worker_id_reported: $worker_id_reported,
    worker_id_match: $worker_id_match,
    cwd_expected: $cwd_expected,
    cwd_reported: $cwd_reported,
    cwd_match: $cwd_match,
    model_reported: $model_reported,
    reconciled_at: $reconciled_at
  }')"
hat_json_set "$worker_file" '.ack_reconciliation' "$ack_reconciliation_json"

printf 'worker=%s pane=%s tab=%s ack=ok\n' "$name" "$pane_id" "$tab_id"
