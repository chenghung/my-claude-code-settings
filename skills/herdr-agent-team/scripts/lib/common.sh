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
#   5  registry 缺漏或內容不合法，本檔不產生
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
