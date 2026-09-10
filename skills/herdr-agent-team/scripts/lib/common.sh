#!/usr/bin/env bash
#
# skills/herdr-agent-team/scripts/lib/common.sh
#
# 職責：herdr-agent-team 底層共用函式庫。所有腳本都會 `source` 本檔，
# 取得：
#   - 環境前提檢查（HERDR_ENV）與 workspace 歸屬守衛
#   - agent 名稱正規化
#   - 對 herdr 呼叫的結束碼映射與 stderr 淨化
#   - registry 暫存目錄的推導
#   - registry 的建立、加鎖讀寫與欄位白名單
#
# 命名慣例：函式一律 `hat_` 前綴，本檔自己匯出／使用的環境變數一律
# `AGENT_TEAM_` 前綴。刻意不用 `HERDR_` 前綴：herdr 本身已經注入
# HERDR_ENV、HERDR_PANE_ID、HERDR_TAB_ID、HERDR_WORKSPACE_ID、
# HERDR_SOCKET_PATH、HERDR_BIN_PATH 六個變數，混進同一個命名空間會讓
# 讀腳本的人分不出一個變數究竟是 herdr 自己注入的、還是本專案自訂的。
#
# 刻意偏離慣例：本檔不下 `set -euo pipefail`。它會被腳本與測試
# `source` 進呼叫端自己的 shell；若在這裡設定全域選項，會覆寫呼叫端
# 原本的選項狀態。全域安全選項一律由每一支「使用」本檔的腳本自行在
# 檔頭設定，本檔只提供函式（此偏離沿用 skills/epic-orchestration/
# scripts/lib/common.sh 已有的先例與理由）。
#
# ---- 絕對禁止：不帶子指令的裸 herdr ----
# `herdr` 不帶任何子指令時會啟動或附接終端介面（互動式 TUI），在腳本
# 或本函式庫的任何呼叫路徑裡都絕對不可以這樣呼叫。本檔的 hat_herdr 不
# 會替呼叫端補全子指令，所有呼叫端都必須自己帶子指令。
#
# ---- 結束碼對照表（所有腳本共用）----
#   0  成功
#   1  由個別腳本自行產生的部分失敗或迴圈異常，本檔不產生
#   2  呼叫端用錯：缺必填參數、參數格式不對
#   3  環境前提不成立：HERDR_ENV 不等於 "1"
#   4  守衛不通過，涵蓋六類：workspace 邊界、provider 白名單、開工閘
#      門、關閉閘門、代按前的狀態重查、grant——本檔的 hat_assert_workspace
#      只負責 workspace 邊界這一類，其餘五類由後續任務的函式各自產生
#   5  registry 缺漏或內容不合法：本檔的 hat_json_get（欄位缺漏）與
#      hat_json_set（mktemp／jq／mv 三步任一步失敗）會產生此碼
#   6  herdr 拒絕（herdr 自身結束碼 1 一律映射成本碼）
#   7  握手未取得憑據，含逾時與 agent_prompt_stalled，本檔不產生
#   8  啟動未就緒，本檔不產生

# hat_die <exit_code> <message>
# 把 <message> 印到 stderr，並以 <exit_code> 結束目前的 shell。
hat_die() {
  local exit_code="$1" message="${2:-}"
  printf '%s\n' "$message" >&2
  exit "$exit_code"
}

# hat_require_herdr_env
# HERDR_ENV 不等於字串 "1" 時以 3 結束：代表目前不在 herdr 管理的環境
# 中，任何腳本都必須拒絕執行。
hat_require_herdr_env() {
  if [ "${HERDR_ENV:-}" != "1" ]; then
    hat_die 3 "HERDR_ENV 不是 \"1\"：目前不在 herdr 管理的環境中，拒絕執行"
  fi
}

# hat_normalize_name <workspace_id> <role>
# 印出符合 herdr agent 名稱正規表示式 `^[a-z][a-z0-9_-]{0,31}$` 的名
# 稱。正規化順序（依任務簡報明訂，不可調整）：
#   1. 先轉小寫
#   2. 再把不在 [a-z0-9_-] 的字元整段換成單一連字號（不是每個壞字元
#      各自變成一個連字號）
#   3. 再確保開頭是小寫字母；不是就前綴一個 a
#   4. 最後截斷到 32 字元；截斷後尾端若是連字號要一併去掉
hat_normalize_name() {
  local workspace_id="$1" role="$2" combined

  combined="$(printf '%s-%s' "$workspace_id" "$role" | tr '[:upper:]' '[:lower:]')"
  # tr -c 把「不在 a-z0-9_- 集合裡」的每個字元都換成連字號，再用
  # tr -s '-' 把因此產生的連續連字號壓成一個。
  combined="$(printf '%s' "$combined" | tr -c 'a-z0-9_-' '-' | tr -s '-')"

  case "$combined" in
    [a-z]*) : ;;
    *) combined="a$combined" ;;
  esac

  combined="${combined:0:32}"
  # 前一步已把連續連字號壓成一個，字串裡任何位置都不會有兩個以上連續
  # 的連字號，因此截斷後最多只會多出一個尾端連字號，去一次就夠。
  combined="${combined%-}"

  printf '%s\n' "$combined"
}

# hat_assert_workspace <target>
# <target> 是 pane_id 或 tab_id（已實測 herdr 0.8.2 兩者皆為
# `<workspace_id>:<local>` 格式），或直接就是 workspace id 本身。是否
# 屬於本 workspace 的唯一判定依據是 HERDR_WORKSPACE_ID（herdr 注入受管
# 窗格的執行期變數）；不屬於時以 4 結束。HERDR_WORKSPACE_ID 未設時視
# 同守衛不通過，同樣以 4 結束。
hat_assert_workspace() {
  local target="$1" workspace_id="${HERDR_WORKSPACE_ID:-}"

  if [ -z "$workspace_id" ]; then
    hat_die 4 "HERDR_WORKSPACE_ID 未設，無法確認本 workspace"
  fi

  case "$target" in
    "$workspace_id" | "$workspace_id":*) return 0 ;;
  esac

  hat_die 4 "目標 '$target' 不屬於 workspace '$workspace_id'"
}

# hat_herdr <args...>
# 呼叫 herdr。成功（結束碼 0）時 stdout 原樣輸出。herdr 結束碼 1（伺服
# 器拒絕）映射成 6；結束碼 2（呼叫語法錯誤）原樣保留。
#
# stderr 一律先擷取到暫存檔，絕不原樣繼承給呼叫端：呼叫端的 stderr 直
# 接就是 AI agent 的 context，而 herdr 的錯誤酬載可能整包帶著終端標題
# 這類使用者或模型原文（已實測 `agent list` 的正常回應即含
# terminal_title／terminal_title_stripped）。失敗時只用 jq 取出
# error.code 與 error.message 兩個純字串欄位重組成一行訊息印到本函式
# 呼叫端的 stderr；任一欄位取不到（含結束碼 2 印出的純文字用法說明，
# 非合法 JSON——已實測 herdr 0.8.2 正是如此）就用明確的替代字串，不得
# 因此退回轉發原始內容。
hat_herdr() {
  local err_file rc code message

  err_file="$(mktemp)"

  # 呼叫必須包在 if 的條件裡，不能寫成裸陳述句再讀 $?：呼叫端的腳本一
  # 律有 set -e，裸陳述句一旦失敗，errexit 會在到達下一行讀取 $? 之前
  # 就終止整個呼叫端的 shell，本函式的結束碼映射邏輯永遠執行不到。
  if herdr "$@" 2>"$err_file"; then
    rc=0
  else
    rc=$?
  fi

  if [ "$rc" -eq 0 ]; then
    rm -f "$err_file"
    return 0
  fi

  # `|| true` 讓這兩行賦值本身不會因為 jq 解析失敗（stderr 不是合法
  # JSON，例如上面提到的用法說明）而觸發呼叫端的 errexit：子指令替代
  # 的結束碼因此恆為 0，取到的欄位是空字串再由下面的替代字串接手。
  code="$(jq -r '.error.code // empty' "$err_file" 2>/dev/null || true)"
  message="$(jq -r '.error.message // empty' "$err_file" 2>/dev/null || true)"
  rm -f "$err_file"
  [ -n "$code" ] || code="unknown_error"
  [ -n "$message" ] || message="(herdr 未提供可解析的錯誤訊息)"
  printf 'herdr %s: %s\n' "$code" "$message" >&2

  if [ "$rc" -eq 1 ]; then
    return 6
  fi
  return "$rc"
}

# hat_project_tmp <team_home>
# 依暫存檔存放規則，確保 <team_home>/.tmp 是可用路徑並印出來；必要時
# 建立為指向使用者家目錄 ~/.tmp 下、team home 專屬資料夾的 symlink（目
# 標為絕對路徑）。<team_home>/.tmp 只能是 symlink，本函式不會在
# <team_home> 下直接建立實體 .tmp 目錄；若該處已存在可用的實體目錄或
# 有效 symlink，直接沿用不替換；若是指向不存在目標的失效 symlink，先
# 移除再重建。
#
# 行為驗證安排在後續任務（見任務簡報），本任務只負責實作。
hat_project_tmp() {
  local team_home="$1" tmp_path project_name project_hash home_project_dir

  tmp_path="$team_home/.tmp"

  if [ -d "$tmp_path" ] && [ ! -L "$tmp_path" ]; then
    # 既有實體目錄，直接沿用。
    printf '%s\n' "$tmp_path"
    return 0
  fi

  if [ -L "$tmp_path" ] && [ ! -e "$tmp_path" ]; then
    # 失效 symlink（目標不存在），先移除再重建。
    rm -f "$tmp_path"
  fi

  if [ ! -e "$tmp_path" ]; then
    project_name="$(basename "$team_home")"
    project_hash="$(printf '%s' "$team_home" | sha256sum | cut -c1-8)"
    home_project_dir="$HOME/.tmp/${project_name}-${project_hash}"
    mkdir -p "$home_project_dir"
    ln -s "$home_project_dir" "$tmp_path"
  fi

  printf '%s\n' "$tmp_path"
}

# hat_registry_root
# 印出 `<team home>/.tmp/herdr-agent-team/<workspace_id>`。team home 取
# 環境變數 AGENT_TEAM_HOME，未設時取當前工作目錄；workspace id 取
# HERDR_WORKSPACE_ID。
#
# 行為驗證安排在後續任務（見任務簡報），本任務只負責實作。
hat_registry_root() {
  local team_home
  team_home="${AGENT_TEAM_HOME:-$PWD}"
  printf '%s/herdr-agent-team/%s\n' "$(hat_project_tmp "$team_home")" "${HERDR_WORKSPACE_ID:-}"
}

# hat_whitelist_agents <json>
# 從 `agent list` 回應（形如 {"result":{"agents":[...]}})只取六個白名
# 單欄位印出，每個 agent 一行 TSV：
#   name  workspace_id  agent_status  state_change_seq  pane_id  tab_id
#
# 用 jq 明確列出六個欄位建構輸出，不是「剝掉幾個具名欄位」：已實測
# `agent list` 的真實回應還帶 agent、agent_session、cwd、focused、
# foreground_cwd、revision、terminal_id、terminal_title、
# terminal_title_stripped、tokens 等欄位，herdr 未來再新增欄位時，剝除
# 式寫法會靜默把新欄位一起帶出去，明確列舉不會。
#
# 六個欄位裡任一個在來源缺席都印空字串（`// empty`），不印字面
# "null"：已實測 `agent list` 對尚未 rename 過的 agent，`name` 欄位整
# 個不存在。
hat_whitelist_agents() {
  local json="$1"
  printf '%s' "$json" | jq -r '
    .result.agents[]? |
    [
      (.name // empty),
      (.workspace_id // empty),
      (.agent_status // empty),
      (.state_change_seq // empty),
      (.pane_id // empty),
      (.tab_id // empty)
    ] | @tsv
  '
}

# ---- registry 寫入的失敗必須由寫入端自己接住：errexit 不在，而回傳碼
#      還可能被關檔案描述符的動作遮住 ----
# `hat_json_set` 是「mktemp → jq 產生新內容 → mv 置換」三步。這三步的
# 失敗（磁碟滿、目錄變唯讀、配額用盡、jq 對一份被截斷的檔案解析失敗）
# 原本兩層保護同時不存在：
#
#   一、errexit 不在。這個函式的呼叫鏈上一定有一層命令替換或子殼（呼
#       叫端多半用 `( hat_json_set ... ) || rc=$?` 這種寫法安全擷取結
#       束碼），而命令替換的子殼裡 errexit 根本不生效：非最後一個指令
#       失敗既不中止替換、呼叫端也看不到（已對 bash 5.3.15 實測：mktemp
#       樁成失敗、jq 樁成失敗兩種情形下，若函式內部沒有自己檢查結束
#       碼，呼叫端只會看到 rc=0）。此結論沿用
#       skills/epic-orchestration/scripts/lib/common.sh 已有的先例。
#   二、回傳碼可能被遮住。若函式最後一句是關閉鎖用的檔案描述符，函式
#       的結束碼就會是「關檔案描述符成功」，不是「寫入成功」。
#
# 姊妹 skill 已經實測過這個形狀的真實後果：`mktemp` 被樁成失敗之後，函
# 式照樣回 0、呼叫端照樣判定要自動推進，但計數與標記兩個欄位一個都沒
# 動——累計上限永不觸發、同一則標記每輪都被判成新的，全程沒有訊息也沒
# 有非 0 結束碼。修法是把三步串起來、失敗就 `hat_die 5`，且 `mv` 不得
# 無條件執行；失敗時先 `rm` 暫存檔，因為它沒置換成功會留在原地。

# ---- 欄位白名單（規格 §13）----
# 檔案鎖擋得住同一次呼叫內的讀-改-寫競態，擋不住「兩個都以為自己是某
# 欄位唯一寫入者的行程互相覆蓋」——擋住後者的是「寫入端欄位集合不重
# 疊」這個約定，白名單把約定變成程式碼保證。三份清單在本任務就全部釘
# 死，涵蓋後續每個任務要寫的欄位，避免每個任務都要回頭改這裡。不要因
# 為「寫入都有鎖」就推論放行更多欄位也安全：
#
# 寫入端分邊，欄位集合刻意不重疊——座標類欄位由 launch-worker.sh 寫；
# 整筆記錄由 shutdown-worker.sh 移除；計數類欄位（.auto_push_count、
# .last_seq_stamp、.last_seq_changed_at）由 watchdog.sh 維護；.stage 與
# .held 由 orchestrator 端腳本寫。
_HAT_TEAM_JSON_FIELDS=(
  '.orchestrator_name' '.orchestrator_pane' '.team_home'
  '.thin_command_source' '.next_seq' '.goal_version' '.goal_confirmed'
  '.goal.achieve' '.goal.success' '.goal.not_doing' '.goal.assumptions'
  '.goal_history'
)
_HAT_WORKER_JSON_FIELDS=(
  '.role' '.kind' '.args' '.tab_id' '.pane_id' '.agent_name' '.cwd'
  '.completion_criteria' '.delivery_point' '.end_point' '.stage' '.held'
  '.auto_push_count' '.last_seq_stamp' '.last_seq_changed_at'
  '.ack_reconciliation' '.grants' '.pending_resend'
)
_HAT_INBOX_JSON_FIELDS=(
  '.token' '.worker' '.summary' '.detail_path' '.locator' '.created_at'
  '.delivery' '.processed_at'
)

# hat_registry_init
# 幂等建立 registry 根與六個子目錄（workers／inbox／details／replies／
# peer-log／handoff），以及空的 team.json。team.json 只在不存在時建
# 立，重跑不得清空已經寫入的狀態；六個子目錄用 mkdir -p，對「已存在」
# 與「兩個行程同時建」都是安全的。
hat_registry_init() {
  local root
  root="$(hat_registry_root)"

  mkdir -p \
    "$root/workers" "$root/inbox" "$root/details" \
    "$root/replies" "$root/peer-log" "$root/handoff"

  if [ ! -e "$root/team.json" ]; then
    printf '{}' > "$root/team.json"
  fi
}

# hat_json_get <file> <jq_path>
# 印出 <file> 裡 <jq_path> 指向的值。欄位缺漏（含檔案不存在、值是 JSON
# null、jq 求值本身失敗）一律以 5 結束：對呼叫端而言「這個欄位還沒被
# 任何人寫過」與「registry 本身有問題」是同一件事，後續邏輯都沒有可用
# 的資料可以往下走。
hat_json_get() {
  local file="$1" jq_path="$2" value

  if ! value="$(jq -r "${jq_path} // empty" "$file" 2>/dev/null)"; then
    hat_die 5 "hat_json_get: 讀取失敗：'$file' 的 '$jq_path'"
  fi

  if [ -z "$value" ]; then
    hat_die 5 "hat_json_get: 欄位缺漏：'$file' 的 '$jq_path'"
  fi

  printf '%s\n' "$value"
}

# hat_json_set <file> <jq_path> <json_value>
# 加鎖的讀-改-寫：mktemp → jq 算新內容 → mv 置換，三步串起來，任一步失
# 敗都以 5 結束；mv 不得無條件執行，否則 jq 解析失敗時 mv 照跑，會把原
# 檔換成暫存檔裡的半成品內容。鎖是 registry 根底下一個固定的鎖檔
# （`<registry root>/.lock`），把單次呼叫內的讀-改-寫序列化；不是逐檔
# 各自的鎖，理由是同一次呼叫本來就只碰一個檔案，用單一固定鎖檔換來的
# 是實作簡單，代價是不同檔案之間的寫入也會互相排隊，但這些寫入本來就
# 稀疏，可接受。
#
# <jq_path> 只接受三份白名單裡列舉的欄位，白名單外一律以 2 結束（呼叫
# 端用錯，不是 registry 壞了，見上方欄位白名單一節）；<json_value> 是
# JSON 值而非字串，字串由呼叫端自帶引號（例如 '"x"'），這樣數字、布林
# 與物件都不必另開函式。
#
# 函式最後一句刻意不是關閉鎖用的檔案描述符：關閉動作之後再接一句
# `return 0`，讓函式的結束碼由這句明確給出，不依賴「關 fd 這個動作恰
# 好也回 0」這件事本身——已對 bash 5.3.15 實測 mktemp／jq 各自失敗與
# 正常成功三種路徑，結束碼與訊息均如預期（記錄見任務報告）。
hat_json_set() {
  local file="$1" path="$2" json_value="$3"
  local -a fields
  local lock_file lock_fd tmp allowed candidate

  case "$file" in
    */team.json)      fields=("${_HAT_TEAM_JSON_FIELDS[@]}") ;;
    */workers/*.json) fields=("${_HAT_WORKER_JSON_FIELDS[@]}") ;;
    */inbox/*.json)   fields=("${_HAT_INBOX_JSON_FIELDS[@]}") ;;
    *) hat_die 2 "hat_json_set: 無法辨識的 registry 檔案：$file" ;;
  esac

  allowed=0
  for candidate in "${fields[@]}"; do
    if [ "$candidate" = "$path" ]; then
      allowed=1
      break
    fi
  done
  if [ "$allowed" -ne 1 ]; then
    hat_die 2 "hat_json_set: 欄位 '$path' 不在白名單內，拒絕寫入：$file"
  fi

  lock_file="$(hat_registry_root)/.lock"
  exec {lock_fd}>"$lock_file"
  flock -x "$lock_fd"

  tmp="$(mktemp "${file}.XXXXXX")" || hat_die 5 "hat_json_set: 無法建立暫存檔，'$path' 未寫入：$file"

  if ! { jq --argjson v "$json_value" "${path} = \$v" "$file" > "$tmp" && mv "$tmp" "$file"; }; then
    rm -f "$tmp"
    hat_die 5 "hat_json_set: 寫入失敗（jq 解析或置換未成功），'$path' 未寫入：$file"
  fi

  exec {lock_fd}>&-
  return 0
}

# hat_worker_list
# 印出 workers/ 底下所有 worker 名稱（去掉 .json 副檔名），一行一個。
# 還沒有任何 worker（新建的 team）不算錯誤，什麼都不印。用 find
# -print0 搭配 while read -d '' 走訪，不靠萬用字元展開：目錄是空的時
# 候，沒展開的萬用字元會被當成字面上的檔名去 basename。
hat_worker_list() {
  local dir file

  dir="$(hat_registry_root)/workers"

  while IFS= read -r -d '' file; do
    basename "$file" .json
  done < <(find "$dir" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)

  return 0
}
