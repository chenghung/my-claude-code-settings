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
# .last_seq_stamp、.last_seq_changed_at、.auto_push_reset_seq）由
# watchdog.sh 維護；.stage 與 .held 由 orchestrator 端腳本寫。
#
# .auto_push_reset_seq（Task 12 新增，task-1 訂這份清單時沒有預見到）：
# 記錄「自動推進計數上一次歸零檢查已經看過的最高 inbox seq」，watchdog.sh
# 自己讀寫，見該腳本檔頭「計數重置」一節。task-1 當時的目標是「涵蓋後續
# 每個任務要寫的欄位，避免每個任務都要回頭改這裡」，但自動推進計數的歸
# 零時機（.pending_resend 移除時放掉 .held 不算數，「收到 delivered 或
# orchestrator 送出定案回覆才歸零、fyi 不歸零」才是規格原文）需要一個能
# 分辨「這次 delivered／回覆是不是新的」的水位線，否則同一則 delivered
# 記錄會在每一輪都把計數重新歸零，讓上限形同虛設（原地繞圈永遠推不到上
# 限）——這正是這份清單原本想避免、但沒有涵蓋到的一個欄位需求，回報見任
# 務報告。
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
  '.auto_push_reset_seq' '.ack_reconciliation' '.grants' '.pending_resend'
)
_HAT_INBOX_JSON_FIELDS=(
  '.token' '.worker' '.summary' '.detail_path' '.locator' '.created_at'
  '.delivery' '.processed_at'
)

# hat_registry_init
# 幂等建立 registry 根與七個子目錄（workers／inbox／details／replies／
# briefings／peer-log／handoff），以及空的 team.json。team.json 只在不
# 存在時建立，重跑不得清空已經寫入的狀態；七個子目錄用 mkdir -p，對
# 「已存在」與「兩個行程同時建」都是安全的。briefings/ 由 launch-
# worker.sh 在寫 registry 的同一步把啟動包內容複製進去（規格 §13：中
# 斷恢復之後，那是唯一能重建「當初到底派了什麼」的東西——呼叫端傳入的
# --briefing-file 路徑可能是暫存檔，也可能已經被改掉）。
hat_registry_init() {
  local root
  root="$(hat_registry_root)"

  mkdir -p \
    "$root/workers" "$root/inbox" "$root/details" "$root/replies" \
    "$root/briefings" "$root/peer-log" "$root/handoff"

  if [ ! -e "$root/team.json" ]; then
    printf '{}' > "$root/team.json"
  fi
}

# hat_json_get <file> <jq_path>
# 印出 <file> 裡 <jq_path> 指向的值。欄位缺漏（含檔案不存在、值是 JSON
# null、jq 求值本身失敗）一律以 5 結束：對呼叫端而言「這個欄位還沒被
# 任何人寫過」與「registry 本身有問題」是同一件事，後續邏輯都沒有可用
# 的資料可以往下走。
#
# 判斷缺漏刻意不用 `// empty` 加上「輸出是不是空字串」：`// empty` 把
# JSON `false` 也當成假值換成空字串，於是合法的布林 `false`（例如
# team.json 的 `.goal_confirmed`、workers/<name>.json 的 `.held`，兩者
# 初值都是 `false`，是完全正常的狀態，不是缺漏）會被誤判成缺漏而觸發
# `hat_die 5`——那是真正的 exit，會把整個呼叫端帶走，不是能讓呼叫端自
# 己分支處理的回傳值；同一個判斷方式也會把合法的空字串值一併誤判成缺
# 漏。已用真實 jq 1.8.2 實測：`echo '{"x":false}' | jq -r '.x'` 印出
# 字面 `false`、`{"x":""}` 印出空字串、`{}` 對不存在的路徑印出字面
# `null`（巢狀路徑一樣，例如 `.goal.achieve`）——三者在原始輸出的層次
# 是可以分開的，只有「輸出等於字面 `null`」才代表路徑不存在或值真的
# 是 JSON null，因此改成直接比對這一點，不看輸出是否為空字串。
hat_json_get() {
  local file="$1" jq_path="$2" value

  if ! value="$(jq -r "$jq_path" "$file" 2>/dev/null)"; then
    hat_die 5 "hat_json_get: 讀取失敗：'$file' 的 '$jq_path'"
  fi

  if [ "$value" = "null" ]; then
    hat_die 5 "hat_json_get: 欄位缺漏：'$file' 的 '$jq_path'"
  fi

  printf '%s\n' "$value"
}

# hat_json_set <file> <jq_path> <json_value>
# 加鎖的讀-改-寫：mktemp → jq 算新內容 → mv 置換，三步串起來，任一步失
# 敗都以 5 結束；mv 不得無條件執行，否則 jq 解析失敗時 mv 照跑，會把原
# 檔換成暫存檔裡的半成品內容。
#
# ---- 鎖檔路徑改版：從呼叫端傳入的 <file> 自己的路徑推導，不再呼叫
#      hat_registry_root ----
# 修正迴圈第二輪：原本鎖檔是 registry 根底下一個固定路徑
# （`<registry root>/.lock`），而 `hat_registry_root` 內部依賴
# `AGENT_TEAM_HOME`（未設時退回 `$PWD`）與 `HERDR_WORKSPACE_ID` 重算根
# 目錄。這在 orchestrator 端（cwd 穩定、且通常就是 team home）沒問題，
# 但 worker 端呼叫 `hat_json_set`（例如 report.sh）時踩了兩個洞：一、
# worker 環境只由 `launch-worker.sh` 注入五個 `AGENT_TEAM_*` 變數
# （`STATE_DIR`／`ORCHESTRATOR`／`SELF`／`ROLE`／`SCRIPTS`），`HOME` 從
# 來不在其中，於是 `$PWD` 變成唯一依據；二、worker 的 cwd 本來就是它
# 自己的工作起點，跟 orchestrator 當初建立 registry 時的 cwd不同是多
# worker 團隊的常態，不是邊界情境。兩者疊加，`hat_registry_root` 在
# worker 端算出的是一個跟真正 registry 無關的路徑，鎖檔的父目錄不存
# 在，`exec {fd}>"$lock_file"` 直接以「沒有此一檔案或目錄」失敗，整支
# 呼叫端腳本以不受控的方式中止——已實測重現：只設定 launch-worker.sh
# 真的會注入的那五個變數、cwd 換成跟 registry 根不同的目錄，`hat_
# json_set` 寫 inbox 記錄時在第一次呼叫就以結束碼 1 中止，留下一個裸
# 的空物件，六個欄位一個都沒寫進去。
#
# 修法：鎖檔改成 `<file>.lock`——跟目標檔案同一層、同名加副檔名，不呼
# 叫 `hat_registry_root`，也不需要任何 `AGENT_TEAM_*`／`HERDR_*` 環境
# 變數，純粹由參數決定。這同時修正了一個本來就存在、只是還沒被撞到的
# 過度序列化：鎖的粒度從「整個 registry 共用一把鎖」收斂成「同一個檔
# 案的讀-改-寫互相排隊，不同檔案的寫入不會互相等待」——單一檔案的讀改
# 寫本來就只需要那一個檔案的鎖，全域鎖比需要的更嚴，只是原本用來換實
# 作簡單；現在兩者都要，不需要取捨。呼叫端若自己還需要「同一個欄位跨
# 呼叫端取號並遞增」這類全域序列化語意（例如 report.sh 的
# `hat_allocate_seq`），必須自己對同一個目標檔案走同一個 `<file>.lock`
# 路徑，不能另外發明一把鎖，否則兩把鎖各自序列化、彼此不排隊，等於沒
# 鎖（report.sh 已對齊此約定，見該檔 `hat_allocate_seq` 的說明）。
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
#
# ---- 前置整理之二（Task 12）：置換前重新確認目標檔仍存在，絕不置換
#      ----
# `shutdown-worker.sh` 會在關閉成功後移除 `workers/<name>.json`（不可逆
# 動作的收尾，見該腳本檔頭「參與檔案鎖協定」一節，它與本函式走同一把
# `<file>.lock`）。把 jq 這一步拆成獨立指令（不再跟 `mv` 用 `&&` 串成同
# 一個複合指令）之後，在 jq 已經成功算出新內容、`mv` 還沒執行的這個空
# 檔，明確重新確認一次 `$file` 是否還在：不在就直接以 5 結束、絕不
# `mv`。理由是若目標檔此時已經不在，代表它已經被別的持鎖者（例如
# `shutdown-worker.sh`）在本函式取得鎖之前就完整跑完並移除，本函式手上
# 這份是依據舊內容算出來的新內容，若照樣置換回去，等於讓一筆已經永久
# 關閉的記錄原地復活——大聲失敗遠比安靜復活好。
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

  lock_file="${file}.lock"
  exec {lock_fd}>"$lock_file"
  flock -x "$lock_fd"

  tmp="$(mktemp "${file}.XXXXXX")" || hat_die 5 "hat_json_set: 無法建立暫存檔，'$path' 未寫入：$file"

  if ! jq --argjson v "$json_value" "${path} = \$v" "$file" > "$tmp"; then
    rm -f "$tmp"
    hat_die 5 "hat_json_set: 寫入失敗（jq 解析未成功），'$path' 未寫入：$file"
  fi

  if [ ! -e "$file" ]; then
    rm -f "$tmp"
    hat_die 5 "hat_json_set: 置換前重新確認，目標檔已不存在（可能已被 shutdown-worker.sh 等不可逆動作移除），拒絕置換，'$path' 未寫入：$file"
  fi

  if ! mv "$tmp" "$file"; then
    rm -f "$tmp"
    hat_die 5 "hat_json_set: 寫入失敗（置換未成功），'$path' 未寫入：$file"
  fi

  exec {lock_fd}>&-
  return 0
}

# ---- 前置整理之一（Task 12）：.pending_resend 的兩個寫入端共用同一條
#      「單一加鎖 jq 轉換」實作 ----
# 這個欄位原本只有加入端（instruct.sh 的 hat_append_pending_resend）；
# Task 12 的看門狗是移除端。兩者若各自在自己的腳本裡獨立實作一份
# mktemp／jq／mv，各自對「什麼算一次原子變動」的理解只要有一點點落
# 差，就可能重演 instruct.sh 檔頭「.pending_resend 有兩個寫入端」一節
# 描述的競態：一次遲到的寫入把另一邊剛做的變動整個蓋掉，而外部世界查
# 不到那一則「該送而還沒送到的下行」，後果完全靜默。因此兩者移到這裡共
# 用同一個底層函式 `_hat_pending_resend_apply`，只有 jq 轉換式與引數不
# 同；不透過 `hat_json_set`（它的介面是「設成呼叫端已經算好的字面
# 值」，不是「對現有內容做轉換」，理由見 `hat_json_set` 上方「函式最後
# 一句」說明前的整段檔頭），鎖檔路徑仍是 `<file>.lock`，跟 `hat_json_
# set` 用的同一條——兩者若用不同鎖檔會各自序列化、彼此不排隊，等於沒
# 鎖，同一個成因見 report.sh `hat_allocate_seq` 檔頭「序號配發」一節。
#
# _hat_pending_resend_apply <file> <jq_filter> [jq 選項與引數...]
# 加鎖執行一次 jq 轉換並置換回 <file>；<jq_filter> 與其後的引數原樣轉
# 給 jq（選項在前、filter 由本函式自己接在引數之後、file 放最後，符合
# jq 的呼叫慣例）。前置整理之二（見 hat_json_set 同名一節）同樣套用在
# 這裡：mv 前重新確認 <file> 是否還存在，不在就以 5 結束、絕不置換。
_hat_pending_resend_apply() {
  local file="$1" filter="$2"
  shift 2
  local lock_fd tmp

  lock_fd=""
  exec {lock_fd}>"${file}.lock"
  flock -x "$lock_fd"

  tmp="$(mktemp "${file}.XXXXXX")" || hat_die 5 "_hat_pending_resend_apply: 無法建立暫存檔，pending_resend 未變動：$file"

  if ! jq "$@" "$filter" "$file" > "$tmp"; then
    rm -f "$tmp"
    hat_die 5 "_hat_pending_resend_apply: 寫入失敗（jq 解析未成功），pending_resend 未變動：$file"
  fi

  if [ ! -e "$file" ]; then
    rm -f "$tmp"
    hat_die 5 "_hat_pending_resend_apply: 置換前重新確認，目標檔已不存在，拒絕置換，pending_resend 未變動：$file"
  fi

  if ! mv "$tmp" "$file"; then
    rm -f "$tmp"
    hat_die 5 "_hat_pending_resend_apply: 寫入失敗（置換未成功），pending_resend 未變動：$file"
  fi

  exec {lock_fd}>&-
  return 0
}

# hat_append_pending_resend <file> <text> <kind>
# 在 <file>.lock 的鎖保護下，把 {text, kind} 追加進 <file> 的
# .pending_resend 陣列。呼叫端：instruct.sh（下行被 herdr 判定
# agent_blocked 時排進待補送清單）。
hat_append_pending_resend() {
  local file="$1" text="$2" kind="$3"
  # $text／$kind 是 jq 自己的 --arg 變數，故意留給 jq 展開，不是本函式
  # 的 shell 變數；直接傳給 jq 的舊寫法不會觸發 SC2016，改成先傳進
  # _hat_pending_resend_apply 再轉給 jq 之後，shellcheck 看不到下游是
  # jq 呼叫，才需要下面這行抑制。
  # shellcheck disable=SC2016
  _hat_pending_resend_apply "$file" \
    '.pending_resend = ((.pending_resend // []) + [{text: $text, kind: $kind}])' \
    --arg text "$text" --arg kind "$kind"
}

# hat_remove_pending_resend <file>
# 移除 <file> 的 .pending_resend 陣列第一筆（索引 0）。呼叫端：
# watchdog.sh，補投成功一筆就呼叫一次，讓移除順序跟「先加入的先補投」
# 一致。不接受索引參數：多寫入端環境下，索引由呼叫端自己在 shell 裡算
# 好、卻讓中間插進來的一次加入動作改變陣列長度，會讓算好的索引指到錯
# 誤的位置；本函式只認「目前的第一筆」，永遠是同一次 jq 求值裡看到的
# 陣列決定要移除誰，沒有這個落差。
hat_remove_pending_resend() {
  local file="$1"
  _hat_pending_resend_apply "$file" \
    '.pending_resend = ((.pending_resend // [])[1:])'
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

# hat_require_goal_confirmed
# team.json 的 .goal_confirmed 不是字面 "true" 時（欄位整個缺席、值是
# false、或任何其他值）以 4 結束：規格 §9 的開工閘門，人類確認之前派
# 不出任何 worker，這一關無條件，不論素材多明確。
#
# 內部讀取刻意用 hat_json_get，不繞過去自己呼叫 jq；但本函式要把
# hat_json_get 的兩種結果都收斂成同一個結束碼 4：
#   - 欄位缺漏（人類還沒確認過，goal 甚至可能還沒設過）：hat_json_get
#     本身會以 5 結束，那是它對「讀取這件事本身失敗」的判斷，不是本函
#     式要的語意——對呼叫端而言，「還沒確認」與「欄位還沒被寫過」是同
#     一件事，都該是 4，不是讓 5 把整支呼叫端腳本直接帶走。
#   - 值合法地是 false（已對真實情境確認這是正常狀態）：hat_json_get
#     正常回傳該值，本函式再自己比對是否等於 "true"。
# 因此呼叫必須包在 `|| rc=$?` 裡讀結束碼，不能用裸陳述句：這裡的
# hat_json_get 本身也可能 exit 5（命令替換的子殼吸收掉這個 exit，只留
# 下結束碼），裸陳述句會在呼叫端的 errexit 之下於讀到 rc 之前就把本函
# 式所在的 shell 帶走（與本檔 hat_herdr 開頭說明的成因相同）。
hat_require_goal_confirmed() {
  local team_json rc value

  team_json="$(hat_registry_root)/team.json"

  rc=0
  value="$(hat_json_get "$team_json" '.goal_confirmed')" || rc=$?
  if [ "$rc" -ne 0 ] || [ "$value" != "true" ]; then
    hat_die 4 "goal_confirmed 不是 true：人類確認之前派不出任何 worker"
  fi
}

# ---- provider 驅動表（規格 §5、2.1、2.5，逐字內容見 references/
#      provider-drivers.md）----
# herdr 自己認得二十二種 agent kind，但本 skill 只支援四種：claude、
# codex、agy、opencode。清單外的至少兩種 kind herdr 收得下、卻連狀態
# 偵測規則檔都沒有——它們的 worker 會永遠顯示閒置，watchdog 會持續對一
# 個其實卡住的 worker 送出「繼續」，而使用者只看得到一個一直被推卻沒
# 有進展的東西，完全不知道原因。所以寫錯 kind 必須在啟動之前就被拒
# 絕，而不是啟動之後才發現；錯誤訊息點名支援清單，讓寫錯的人立刻知道
# 有哪些選擇。

# hat_assert_supported_kind <kind>
# <kind> 不在支援清單內時以 4 結束，訊息依序點名 claude、codex、agy、
# opencode 四個名字。
hat_assert_supported_kind() {
  local kind="$1"

  case "$kind" in
    claude | codex | agy | opencode) return 0 ;;
  esac

  hat_die 4 "不支援的 agent kind '$kind'：herdr-agent-team 只支援 claude、codex、agy、opencode"
}

# hat_kind_fidelity <kind>
# 印出 <kind> 的狀態偵測保真度：high（claude、codex）或 low（agy、
# opencode）。已對真實 herdr 規則檔量測：claude 十六條規則、三條正向
# idle 規則；codex 九條規則、一條正向 idle 規則；agy 與 opencode 各只
# 有三條規則，且沒有任何正向 idle 規則——它們的「閒置」字面意思是「所
# 有規則都沒命中」的預設值，不是正向證據。low 保真不改變角色與
# provider 的自由組合，只影響呼叫端要不要對這個 worker 額外開一道回報
# 靜默逾時，接住「違約沒回報就停下」與「原地繞圈」這兩種只有 low 保真
# 才會漏接的失效。
#
# 呼叫端必須先過 hat_assert_supported_kind；<kind> 不在支援清單內時本
# 函式以 2 結束（呼叫端用錯，沿用本檔 hat_json_set 對無法辨識輸入的既
# 有處理方式），不會靜默印出空字串或恆為 0 的結束碼。
hat_kind_fidelity() {
  local kind="$1"

  case "$kind" in
    claude | codex) printf '%s\n' high ;;
    agy | opencode) printf '%s\n' low ;;
    *) hat_die 2 "hat_kind_fidelity: 未知的 kind '$kind'" ;;
  esac
}

# hat_approval_allowlist <rule_name>
# 啟動框按鍵允許清單，射程封閉：命中清單才印出要按的鍵並以 0 結束；沒
# 命中一律印空字串並以非 0 結束，讓呼叫端一律把框升級給人確認、絕不代
# 按沒見過的框。目前清單只有一筆：startup_update（codex 的版本更新提
# 示），按 2（Skip）。它可以自決代按的理由是不放行任何會改變世界的動
# 作，而不按掉的話那個 worker 從一開始就廢了。清單短不是安全問題，只
# 是會比較常停下來問人；清單絕不能改成「擋掉已知的壞的、其餘放行」，
# 那會對沒見過的框照按不誤，正是這個函式要防的事。遇到新的啟動框時，
# 把規則名與鍵值加進下面的 case，並同步更新
# references/provider-drivers.md。
hat_approval_allowlist() {
  local rule_name="$1"

  case "$rule_name" in
    startup_update)
      printf '%s\n' 2
      return 0
      ;;
  esac

  printf '%s\n' ''
  return 1
}

# ---- 名稱格式驗證（全域約束，press-approval.sh 任務追加）----
# 任何要拿去組 registry 路徑的名稱都必須先驗過格式：含斜線或上層目錄記
# 號（`/`、`..`）的值可以組出跳脫 registry 根目錄的路徑（例如
# `workers/../../etc/passwd.json`）。從環境變數讀來的名稱（例如
# report.sh 的 AGENT_TEAM_SELF）跟從參數讀來的名稱一樣是外部輸入，必須
# 一視同仁地驗證；本函式不分辨來源，只認格式。

# hat_assert_agent_name <name>
# <name> 不符合 herdr agent 名稱正規表示式 `^[a-z][a-z0-9_-]{0,31}$` 時
# 以 2 結束：這是呼叫端用錯（給了一個從未被 hat_normalize_name 正規化
# 過、或被竄改過的名稱），不是守衛不通過，沿用本檔對「已知集合外的輸
# 入」一貫採用的 2（hat_json_set 對無法辨識的 registry 檔案、
# hat_kind_fidelity 對未知 kind 皆是同一碼）。
hat_assert_agent_name() {
  local name="$1"

  if ! printf '%s' "$name" | grep -Eq '^[a-z][a-z0-9_-]{0,31}$'; then
    hat_die 2 "hat_assert_agent_name: 名稱不符合 agent 名稱格式（需以小寫字母開頭，其後只能是小寫字母、數字、底線或連字號，長度上限 32 字元）：'$name'"
  fi
}

# ---- 上行前綴（report.sh 轉發給 orchestrator 的訊息，缺口二）----
# report.sh 轉發給 orchestrator 的訊息（`hat_herdr agent prompt` 那一
# 通呼叫）原本只有摘要文字本身：orchestrator 需要某一則的 inbox 序號
# 時（例如要用 `instruct.sh --reply-to <序號>` 回覆一則 need-you），只
# 能自己去掃 inbox 目錄猜。本節提供的兩個函式讓 report.sh 在轉發前把
# 序號、token、發訊 worker 三項釘進訊息最前面，且集中定義在這裡（不像
# `hat_json_string` 那樣各腳本各自獨立定義一份）：建構端（report.sh）
# 與解析端（launch-worker.sh 第 8 步的 ACK 對帳，見該檔檔頭「ACK 摘要
# 格式」一節）分屬兩支腳本，格式是兩邊都要遵守的契約，各自獨立實作只
# 會製造格式漂移的風險，跟 `hat_json_set` 的欄位白名單、
# `hat_normalize_name` 是同一類「正確性依賴兩邊一致」的函式，理由同它
# 們一樣集中在這裡。
#
# 格式固定為 `[[HAT seq=<seq> token=<token> worker=<worker>]] <summary>`。
# `seq` 是十進位整數、`token` 是六個 token 之一、`worker` 是已經過
# `hat_normalize_name` 正規化的名稱，三者依規則都不含空白字元，因此前
# 綴本身保證是一段不含空白的文字，跟後面可能含空白的摘要正文之間，用
# `]] `（兩個右中括號加一個空白）當固定的分界，肉眼就能在第一個
# `]] ` 處切開兩段，不會混在一起分不出邊界。
#
# 這個前綴只加在「轉發給 orchestrator 的訊息」上，不是另開一個新欄
# 位：report.sh 把組好前綴的整串內容同時當成 `.summary` 存進 inbox 記
# 錄、也當成投遞內容送出，這樣 `watchdog.sh` 的
# `hat_wd_retry_blocked_inbox`（補投當初被 `agent_blocked` 擋下的訊
# 息）讀的正是同一個 `.summary` 欄位，補投出去的內容自然也帶著同一個
# 前綴，不需要另外處理重試路徑。

# hat_build_uplink_message <seq> <token> <worker> <summary>
# 印出組好前綴的完整訊息（不含結尾換行以外的多餘字元）。
hat_build_uplink_message() {
  local seq="$1" token="$2" worker="$3" summary="$4"
  printf '[[HAT seq=%s token=%s worker=%s]] %s\n' "$seq" "$token" "$worker" "$summary"
}

# hat_strip_uplink_prefix <text>
# <text> 符合上面那個前綴格式時，印出去掉前綴之後剩下的部分；不符合格
# 式（例如根本沒有前綴）就原樣印出，不動它。`${text#*]] }` 用 `#`（最
# 短匹配、從左邊算）去掉「開頭到第一個 `]] ` 為止」的內容——本函式庫
# 自己組出來的前綴保證是字串裡第一個出現的 `]] `（`seq`／`token`／
# `worker` 三個欄位值都不含 `]` 字元），所以就算後面的摘要正文本身也
# 剛好含有 `]] ` 這個子字串，也不影響切點落在正確的位置。
#
# 呼叫端：launch-worker.sh 第 8 步解析 ACK 摘要（`worker_id=`／
# `cwd=`／`model=` 三個欄位）之前，先呼叫本函式去掉前綴——目前選用的
# 前綴欄位名稱（`seq=`／`token=`／`worker=`）不會跟那三個欄位撞名，但
# 明確去除仍然比依賴「這次剛好沒撞名」更可靠，格式未來若調整也不必回
# 頭檢查這個巧合還成不成立。
hat_strip_uplink_prefix() {
  local text="$1"
  case "$text" in
    '[[HAT '*']] '*)
      text="${text#*]] }"
      ;;
  esac
  printf '%s\n' "$text"
}
