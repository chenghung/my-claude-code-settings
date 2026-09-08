#!/usr/bin/env bash
#
# skills/epic-orchestration/scripts/lib/common.sh
#
# 職責：epic-orchestration 事件驅動機制層的共用函式庫。六支操作腳本與
# event-generator.sh 常駐迴圈都會 `source` 本檔，取得：
#   - 環境前提檢查（HERDR_ENV）與 workspace 歸屬守衛
#   - 狀態檔（state.json）的讀寫，一律經 jq，寫入用「暫存檔＋mv」做到
#     原子性
#   - agent 名稱推導、統一的結束碼與最小化錯誤輸出
#   - 對 herdr 呼叫的結束碼映射（1→6，2 原樣拋出並註明來源）
#
# 刻意偏離慣例：本檔不下 `set -euo pipefail`。它會被腳本與測試
# `source` 進呼叫端自己的 shell；若在這裡設定全域選項，會覆寫呼叫端
# 原本的選項狀態。全域安全選項一律由每一支「使用」本檔的腳本自行在
# 檔頭設定，本檔只提供函式。
#
# 機制層的權威文件就是這份檔案本身的說明與註解，不另外維護一份
# markdown 副本（規格第十五節）。
#
# ---- 結束碼對照表（所有腳本共用）----
#   0  成功
#   2  呼叫端用錯：缺必填參數、參數格式不對
#   3  環境前提不成立：HERDR_ENV 不等於 1
#   4  workspace 守衛不通過
#   5  狀態檔缺漏：檔案不存在，或該 phase 不在檔內
#   6  herdr 拒絕：agent_blocked、agent_not_found、pane_not_found、
#      tab_not_found 等（herdr 自身結束碼 1 一律映射成本碼）
#   7  握手未取得憑據（逾時或 agent_prompt_stalled）——由呼叫
#      eo_herdr 的後續腳本自行判斷後使用，本檔不產生
#   8  啟動三項不齊備——同上，由呼叫端使用，本檔不產生
#
# herdr 自身結束碼 2（語法錯誤）視為腳本呼叫 herdr 的方式有 bug，由
# eo_herdr 原樣往上拋（仍是 2）並在 stderr 註明是哪一次呼叫。

# ---- 未查證推估門檻 ----
# 來源：規格附錄 B。首次真實跑 epic 為校準回合，數值逐字照抄、不得
# 自行調整；供後續腳本（尤其 event-generator.sh）直接引用，避免各處
# 各自硬寫數字。

# 未查證推估，首次真實跑 epic 為校準回合：自動推進（自動按核准框）
# 上限，單位：次。
# shellcheck disable=SC2034 # 本檔不使用，供後續腳本（event-generator.sh 等）source 後引用
readonly EO_AUTO_PUSH_LIMIT=40

# 未查證推估，首次真實跑 epic 為校準回合：state_change_seq 連續無
# 變化達此秒數才印 SPINNING（原始門檻為 25 分鐘）。
# shellcheck disable=SC2034 # 本檔不使用，供後續腳本（event-generator.sh 等）source 後引用
readonly EO_SPINNING_SECONDS=$((25 * 60))

# 未查證推估，首次真實跑 epic 為校準回合：低頻掃描每
# EO_UNCLASSIFIED_SCAN_INTERVAL_SECONDS 秒一輪，連續
# EO_UNCLASSIFIED_ROUNDS 輪都判為 unknown 才印 UNCLASSIFIED。
# shellcheck disable=SC2034 # 本檔不使用，供後續腳本（event-generator.sh 等）source 後引用
readonly EO_UNCLASSIFIED_ROUNDS=5
# shellcheck disable=SC2034 # 本檔不使用，供後續腳本（event-generator.sh 等）source 後引用
readonly EO_UNCLASSIFIED_SCAN_INTERVAL_SECONDS=60

# eo_die <exit_code> <message>
# 把 <message> 印到 stderr，並以 <exit_code> 結束呼叫端的 shell。
eo_die() {
  local exit_code="$1"
  local message="${2:-}"
  printf '%s\n' "$message" >&2
  exit "$exit_code"
}

# eo_require_herdr_env
# HERDR_ENV 不等於字串 "1" 時以 3 結束；供腳本一開頭做前提檢查。
eo_require_herdr_env() {
  if [ "${HERDR_ENV:-}" != "1" ]; then
    eo_die 3 "HERDR_ENV 不是 \"1\"：目前不在 herdr 管理的環境中，拒絕執行"
  fi
}

# eo_main_repo
# 印出主倉庫絕對路徑。優先取環境變數 EO_MAIN_REPO；未設時改由 git 的
# common directory 推導：`git rev-parse --path-format=absolute
# --git-common-dir` 在主倉庫內回傳自己的 .git，在任一 worktree 內也
# 回傳同一個主倉庫的 .git（而不是 worktree 自己的 .git 檔案），取其
# 上層目錄即為主倉庫路徑，因此不論從主倉庫或任一 worktree 執行都得到
# 同一個答案。這條路徑不讀狀態檔的 main_repo 欄位：狀態檔路徑（見
# eo_state_file）本身就是由本函式推出來的，若又反過來讀狀態檔會構成
# 循環依賴，故該欄位保留給已經拿到檔案路徑的讀者，不在此處使用。
# 環境變數與 git common directory 兩者皆不可得時以 5 結束——寧可停
# 下，也不要用猜的路徑讓狀態檔寫到錯的地方。
eo_main_repo() {
  if [ -n "${EO_MAIN_REPO:-}" ]; then
    printf '%s\n' "$EO_MAIN_REPO"
    return 0
  fi

  local git_common_dir
  if git_common_dir="$(/usr/bin/git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
    dirname "$git_common_dir"
    return 0
  fi

  eo_die 5 "EO_MAIN_REPO 未設，且目前不在任何 git 倉庫內，無法推導主倉庫路徑"
}

# eo_agent_name <phase>
# 印出 phase-<phase>-<主倉庫絕對路徑 sha256 前 4 碼>。
eo_agent_name() {
  if [ "$#" -lt 1 ]; then
    eo_die 2 "eo_agent_name 缺少必填參數 <phase>"
  fi
  local phase="$1"
  local main_repo hash
  main_repo="$(eo_main_repo)"
  hash="$(printf '%s' "$main_repo" | sha256sum | cut -c1-4)"
  printf 'phase-%s-%s\n' "$phase" "$hash"
}

# eo_state_file
# 印出狀態檔絕對路徑：<主倉庫>/.tmp/epic-orchestration/state.json。
eo_state_file() {
  printf '%s/.tmp/epic-orchestration/state.json\n' "$(eo_main_repo)"
}

# _eo_state_file_or_die（內部輔助函式，非公開介面）
# 回傳狀態檔路徑；檔案不存在時以 5 結束。供 eo_state_get／
# eo_state_set／eo_state_phases 共用，避免三處重複同一段檢查。
_eo_state_file_or_die() {
  local file
  file="$(eo_state_file)"
  if [ ! -f "$file" ]; then
    eo_die 5 "狀態檔不存在：$file"
  fi
  printf '%s\n' "$file"
}

# eo_state_get <phase> <field>
# 印出該欄位的值；檔案不存在、phase 不存在或欄位不存在時以 5 結束。
eo_state_get() {
  if [ "$#" -lt 2 ]; then
    eo_die 2 "eo_state_get 缺少必填參數 <phase> <field>"
  fi
  local phase="$1" field="$2" file has
  file="$(_eo_state_file_or_die)"

  # 先判斷 phase／欄位是否存在，避免布林 false 這種「JSON 假值但確實
  # 存在」的欄位被 jq -e 的真假值語意誤判成不存在。
  has="$(jq -r --arg p "$phase" --arg f "$field" \
    'if (.phases[$p] // null) == null then "missing"
     elif (.phases[$p] | has($f)) then "present"
     else "missing" end' "$file")"
  if [ "$has" != "present" ]; then
    eo_die 5 "phase $phase 或欄位 $field 不存在於狀態檔"
  fi

  jq -r --arg p "$phase" --arg f "$field" '.phases[$p][$f]' "$file"
}

# eo_state_set <phase> <field> <json_value>
# 以暫存檔加 mv 原子寫入。<json_value> 是 JSON 值而非字串，字串要由
# 呼叫端自帶引號（例如 '"running"'），這樣數字與布林不必另開函式。
# 暫存檔與目的檔同一目錄，確保 mv 落在同一個檔案系統上、是真的原子
# 置換。
#
# 合法性檢查刻意不用 `jq -e .`：`-e` 的結束碼是依「最後輸出值的真假」
# 決定，不是依「語法是否合法」——輸入合法的 JSON `false` 或 `null`
# 時，`-e` 一樣回傳非 0，會被誤判成不合法（獨立審查用真實 jq 1.8.2
# 重現過）。這裡改用 `. as $x | true`：不管 `$x`（也就是輸入值）本身
# 真假，永遠輸出字面上的 `true`，所以 `-e` 判的是「有沒有解析出東
# 西」而不是「解析出來的東西是不是真值」。也不能直接換成單純的
# `jq empty`：`empty` 對完全空字串或純空白輸入一樣回傳 0（因為它本來
# 就不輸出任何東西，`empty` 篩選器的『沒輸出』跟『合法但空』分不出
# 來），會把呼叫端漏帶引號、傳出空字串這種明確錯誤放行，這一點已用
# 真實 jq 驗證過（`jq empty <<<''` 回 0）。
eo_state_set() {
  if [ "$#" -lt 3 ]; then
    eo_die 2 "eo_state_set 缺少必填參數 <phase> <field> <json_value>"
  fi
  local phase="$1" field="$2" json_value="$3" file tmp lock_file lock_fd
  file="$(_eo_state_file_or_die)"

  if ! jq -e '. as $x | true' >/dev/null 2>&1 <<<"$json_value"; then
    eo_die 2 "eo_state_set 的第三個參數不是合法 JSON：$json_value"
  fi

  # 讀-改-寫（讀舊檔→算新內容→mv 換檔）整段用 flock 序列化，不只是
  # mv 那一刻：mv 本身雖然原子，但擋不住「兩個行程都讀到同一份舊內容
  # 後各自算出新內容、後寫入者蓋掉先寫入者變更」這種遺失更新。鎖檔用
  # `<狀態檔>.lock`，鎖只在本函式呼叫期間持有，函式結束就明確關閉
  # 對應的檔案描述符、釋放鎖。
  lock_file="${file}.lock"
  exec {lock_fd}>"$lock_file"
  flock -x "$lock_fd"

  tmp="$(mktemp "${file}.XXXXXX")"
  jq --arg p "$phase" --arg f "$field" --argjson v "$json_value" \
    '.phases[$p] //= {} | .phases[$p][$f] = $v' "$file" > "$tmp"
  mv "$tmp" "$file"

  exec {lock_fd}>&-
}

# eo_state_phases
# 每行印一個 phase 編號。
eo_state_phases() {
  local file
  file="$(_eo_state_file_or_die)"
  jq -r '.phases | keys[]' "$file"
}

# eo_assert_workspace <tab_id>
# 以 `herdr tab list --workspace` 確認該 tab 屬於本 workspace，不符
# 時以 4 結束。
#
# 「本 workspace」怎麼推導：取自 herdr 注入每個受管窗格的環境變數
# HERDR_WORKSPACE_ID（與 HERDR_TAB_ID、HERDR_PANE_ID 同一類、由 herdr
# 執行期自動設定，非本腳本自己匯出）。這是本檔唯一推導「本 workspace
# 為何」的地方；之後的腳本一律呼叫本函式取得判定結果，不得自行重新
# 推導或另讀 HERDR_WORKSPACE_ID。HERDR_WORKSPACE_ID 未設時視同守衛
# 不通過，一律以 4 結束。
eo_assert_workspace() {
  if [ "$#" -lt 1 ]; then
    eo_die 2 "eo_assert_workspace 缺少必填參數 <tab_id>"
  fi
  local tab_id="$1" workspace_id tabs_json match
  workspace_id="${HERDR_WORKSPACE_ID:-}"
  if [ -z "$workspace_id" ]; then
    eo_die 4 "HERDR_WORKSPACE_ID 未設，無法確認本 workspace"
  fi

  tabs_json="$(eo_herdr tab list --workspace "$workspace_id")"
  match="$(printf '%s' "$tabs_json" | jq -r --arg t "$tab_id" \
    '[.result.tabs[]?.tab_id] | index($t) // empty')"
  if [ -z "$match" ]; then
    eo_die 4 "tab $tab_id 不屬於本 workspace（$workspace_id）"
  fi
}

# eo_herdr <args...>
# 呼叫 `herdr <args...>`；stdout 原樣轉發給呼叫端（可用命令替換擷
# 取）。herdr 結束碼 1（伺服器錯誤，錯誤 JSON 印在 stderr）映射成
# 6；herdr 結束碼 2（語法錯誤，視為腳本呼叫方式有 bug）原樣拋出，並
# 在 stderr 額外註明是哪一次呼叫。herdr 自身印出的訊息不受影響、照
# 常出現在 stderr 上，只有結束碼被攔截改寫。
#
# `herdr "$@"` 這一句刻意包在 `if` 的條件裡，不是寫成後面接一行
# `rc=$?` 的裸陳述句：bash 的 errexit 只在「一個指令的失敗正在被
# if／while／until 的條件、或 &&／|| 左側測試」時才豁免，其餘情況失
# 敗當下就終止整個 shell。呼叫端的腳本一律有 `set -e`，若 herdr 在
# 這裡是裸陳述句，一旦失敗，errexit 會在到達下面 `rc=$?` 與 case 之
# 前就先把整個呼叫端腳本終止，本函式的結束碼映射邏輯永遠執行不到
# ——這正是獨立審查用真實樁重現出的問題：外層腳本收到的是 herdr 原始
# 的 1，而不是約定的 6。把測試點放在 `if` 內部，讓豁免發生在本函式
# 自己身上，不必依賴呼叫端怎麼寫（是否包在子殼、邏輯運算子裡）。
eo_herdr() {
  local rc=0
  # 刻意用 if／else 兩個分支各自處理，不是「if 判斷完再看 $?」：
  # `if cmd; then ...; fi`（沒有 else）在條件為假、又沒有 else 時，
  # 整個 if 陳述句本身的結束碼固定是 0，不是 cmd 失敗當下的原始結束
  # 碼——`$?` 要在 else 分支裡、緊接著失敗的那個當下取，才會是 herdr
  # 真正的結束碼。
  if herdr "$@"; then
    return 0
  else
    rc=$?
  fi
  case "$rc" in
    1) eo_die 6 "eo_herdr: herdr 以結束碼 1 拒絕（見上方 herdr 錯誤訊息）：herdr $*" ;;
    2) eo_die 2 "eo_herdr: herdr 以結束碼 2 拒絕，疑似腳本呼叫語法錯誤：herdr $*" ;;
    *) exit "$rc" ;;
  esac
}
