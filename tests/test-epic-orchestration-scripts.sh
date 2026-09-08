#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPTS="$REPO/skills/epic-orchestration/scripts"
fail=0
pass() { printf 'PASS %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
STUB_BIN="$T/bin"
mkdir -p "$STUB_BIN"
saved_path="$PATH"

# PATH 洩漏守衛：確認樁目錄確實遮蔽了真實 herdr。少了這道，
# 忘了建的樁會靜默解析到真實二進位，測試就在對真實 session 動手。
assert_herdr_stub_only() {
  local check_path="$1" stub_dir="$2" resolved
  resolved="$(PATH="$check_path" command -v herdr 2>/dev/null)" || resolved=""
  if [ "$resolved" != "$stub_dir/herdr" ]; then
    bad "PATH guard: herdr 解析到 '$resolved'，不是樁 '$stub_dir/herdr'"
    return 1
  fi
  return 0
}

# shellcheck source=/dev/null
source "$SCRIPTS/lib/common.sh"

export EO_MAIN_REPO="$T/repo"
mkdir -p "$EO_MAIN_REPO/.tmp/epic-orchestration"

# --- eo_agent_name：格式與雜湊 ---
expected_hash="$(printf '%s' "$EO_MAIN_REPO" | sha256sum | cut -c1-4)"
got="$(eo_agent_name 101)"
if [ "$got" = "phase-101-$expected_hash" ]; then
  pass "eo_agent_name 產生 phase-101-<sha256前4>"
else
  bad "eo_agent_name 得到 '$got'，預期 'phase-101-$expected_hash'"
fi

# --- eo_agent_name：herdr 名稱規則 [a-z][a-z0-9_-]{0,31} ---
if printf '%s' "$got" | rg -q '^[a-z][a-z0-9_-]{0,31}$'; then
  pass "eo_agent_name 符合 herdr 名稱規則"
else
  bad "eo_agent_name 產生的 '$got' 不符 herdr 名稱規則"
fi

# --- eo_require_herdr_env：非 1 時以 3 結束 ---
( HERDR_ENV=0 eo_require_herdr_env ) 2>/dev/null && rc=0 || rc=$?
if [ "$rc" -eq 3 ]; then
  pass "eo_require_herdr_env 對 HERDR_ENV=0 以 3 結束"
else
  bad "eo_require_herdr_env 對 HERDR_ENV=0 結束碼為 $rc，預期 3"
fi

# --- 狀態檔：不存在時 eo_state_get 以 5 結束 ---
( eo_state_get 101 stage ) 2>/dev/null && rc=0 || rc=$?
if [ "$rc" -eq 5 ]; then
  pass "eo_state_get 對不存在的狀態檔以 5 結束"
else
  bad "eo_state_get 對不存在的狀態檔結束碼為 $rc，預期 5"
fi

# --- 狀態檔：寫入後讀得回來 ---
printf '%s' '{"main_repo":"","phases":{}}' > "$(eo_state_file)"
eo_state_set 101 stage '"running"'
eo_state_set 101 last_marker_seq 17
if [ "$(eo_state_get 101 stage)" = "running" ] \
   && [ "$(eo_state_get 101 last_marker_seq)" = "17" ]; then
  pass "eo_state_set 與 eo_state_get 往返一致"
else
  bad "狀態檔往返不一致"
fi

# --- 狀態檔：eo_state_phases 列出所有 phase ---
eo_state_set 102 stage '"pending"'
if [ "$(eo_state_phases | sort | tr '\n' ' ')" = "101 102 " ]; then
  pass "eo_state_phases 列出全部 phase"
else
  bad "eo_state_phases 得到 '$(eo_state_phases | tr '\n' ' ')'，預期 '101 102 '"
fi

# --- eo_state_set／eo_state_get：JSON false／null 往返（開放 finding 一）---
# 舊版合法性檢查用 `jq -e .`，結束碼是依「最後輸出值的真假」判定，
# 不是依語法——合法的 JSON false／null 的輸出值本身是假，會被 -e
# 誤判成不合法。狀態檔 schema 裡 held_by_orchestrator／spinning_muted／
# gone_muted／unclassified_muted 四個欄位都是布林、預設 false，這裡
# 直接驗證這個真實會被寫入的值。
eo_state_set 101 held_by_orchestrator false
eo_state_set 101 some_null_field null
if [ "$(eo_state_get 101 held_by_orchestrator)" = "false" ] \
   && [ "$(eo_state_get 101 some_null_field)" = "null" ]; then
  pass "eo_state_set 接受合法的 JSON false／null，往返一致"
else
  bad "eo_state_set 對 false／null 的往返不一致"
fi

# --- eo_state_set：第三參數是空字串時仍要以 2 結束 ---
# 這條不是審查點名的三項之一，是修 finding 一時另外驗證到的邊界：
# 若直接改用最單純的 `jq empty` 判斷合法性，空字串會被誤判成合法
# （`empty` 篩選器本來就不輸出任何東西，「沒輸出」跟「合法但空」在
# 它底下分不出來），因此改用 `jq -e '. as $x | true'` 而不是
# `jq empty`。這裡驗證這個邊界沒有被新寫法帶回來。
( eo_state_set 101 some_field "" ) 2>/dev/null && rc=0 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "eo_state_set 對空字串第三參數以 2 結束（不是合法 JSON）"
else
  bad "eo_state_set 對空字串第三參數結束碼為 $rc，預期 2"
fi

# --- eo_state_set：讀-改-寫由 flock 序列化，不遺失並行寫入（開放 finding 三）---
# 手法：外部搶下與 eo_state_set 相同的鎖檔並握住 1.5 秒，驗證
# eo_state_set 真的會等待（花費時間），而不是繞過鎖直接寫、蓋掉別人
# 稍早的變更。
LOCK_FILE="$(eo_state_file).lock"
(
  exec 8>"$LOCK_FILE"
  flock -x 8
  sleep 1.5
) &
holder_pid=$!
sleep 0.3
start_ms=$(date +%s%3N)
eo_state_set 101 concurrent_probe '"done"'
end_ms=$(date +%s%3N)
wait "$holder_pid"
elapsed_ms=$((end_ms - start_ms))
if [ "$(eo_state_get 101 concurrent_probe)" = "done" ] && [ "$elapsed_ms" -ge 800 ]; then
  pass "eo_state_set 在鎖被外部持有時會等待，讀-改-寫序列化、沒有遺失更新"
else
  bad "eo_state_set 併發防護測試失敗：elapsed_ms=$elapsed_ms"
fi

# --- eo_main_repo：EO_MAIN_REPO 未設時由 git common directory 推導 ---
# 這條涵蓋的是環境變數未設時的推導路徑，而它必須從 worktree 內執行也對得回主倉庫。
got="$(unset EO_MAIN_REPO && eo_main_repo)"
expected="$(dirname "$(/usr/bin/git rev-parse --path-format=absolute --git-common-dir)")"
if [ "$got" = "$expected" ]; then
  pass "eo_main_repo 在 EO_MAIN_REPO 未設時由 git common directory 推導出主倉庫"
else
  bad "eo_main_repo 得到 '$got'，預期 '$expected'"
fi

# --- eo_main_repo：EO_MAIN_REPO 未設且不在任何 git 倉庫時以 5 結束 ---
# 失敗方向是安全的，寧可停下也不要猜一個路徑，因為猜錯會讓狀態檔寫到別的地方去。
NO_GIT_DIR="$T/no-git"
mkdir -p "$NO_GIT_DIR"
( cd "$NO_GIT_DIR" && unset EO_MAIN_REPO && eo_main_repo ) 2>/dev/null && rc=0 || rc=$?
if [ "$rc" -eq 5 ]; then
  pass "eo_main_repo 在無 git 倉庫且 EO_MAIN_REPO 未設時以 5 結束"
else
  bad "eo_main_repo 在無 git 倉庫情境下結束碼為 $rc，預期 5"
fi

# --- workspace 守衛：tab 不在本 workspace 時以 4 結束 ---
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "tab" ] && [ "$2" = "list" ]; then
  printf '{"result":{"tabs":[{"tab_id":"tab_mine"}]}}'
  exit 0
fi
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
export PATH="$STUB_BIN:$saved_path"
assert_herdr_stub_only "$PATH" "$STUB_BIN"
( eo_assert_workspace tab_other ) 2>/dev/null && rc=0 || rc=$?
if [ "$rc" -eq 4 ]; then
  pass "eo_assert_workspace 對外部 workspace 的 tab 以 4 結束"
else
  bad "eo_assert_workspace 對外部 tab 結束碼為 $rc，預期 4"
fi
if eo_assert_workspace tab_mine 2>/dev/null; then
  pass "eo_assert_workspace 放行本 workspace 的 tab"
else
  bad "eo_assert_workspace 誤擋本 workspace 的 tab"
fi

# --- eo_herdr：herdr 結束碼 1 映射成 6 ---
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '{"error":{"code":"agent_not_found"}}' >&2
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
( eo_herdr agent get phase-101 ) 2>/dev/null && rc=0 || rc=$?
if [ "$rc" -eq 6 ]; then
  pass "eo_herdr 把 herdr 結束碼 1 映射成 6"
else
  bad "eo_herdr 映射得到 $rc，預期 6"
fi

# --- eo_herdr：裸呼叫（未被 if／&&／|| 保護）仍要映射成 6（開放 finding 二）---
# 上面那條測試把 eo_herdr 包在子殼＋&&/|| 左側，剛好命中 bash 對
# errexit 的豁免情境，測不到真實會發生的裸呼叫用法。這裡在一支獨立、
# 也設了 set -euo pipefail 的子行程裡把 eo_herdr 當一般陳述句呼叫，
# 重現審查描述的用法：豁免必須發生在 eo_herdr 函式自己身上，不能靠
# 呼叫端怎麼寫。
BARE_SCRIPT="$T/bare-eo-herdr.sh"
cat > "$BARE_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$SCRIPTS/lib/common.sh"
eo_herdr agent get phase-101
EOF
chmod +x "$BARE_SCRIPT"
( bash "$BARE_SCRIPT" ) >/dev/null 2>/dev/null && rc=0 || rc=$?
if [ "$rc" -eq 6 ]; then
  pass "eo_herdr 裸呼叫（不受 if/&&/|| 保護）仍把 herdr 結束碼 1 映射成 6"
else
  bad "eo_herdr 裸呼叫得到 $rc，預期 6"
fi
export PATH="$saved_path"

# ===== 任務二：phase-status.sh =====
# 以下回應形狀已對真實 herdr 0.8.2 執行 api snapshot 查證：
# agents 在 result 底下的 snapshot 底下；直接取 result 底下的 agents 會得到 null。
# 另外多加了 agent explain 分支，回應裡塞一個可辨識字串到 evidence，
# 供下面 --explain 那一段斷言它沒有洩漏（開放 finding 二）。
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [ "$2" = "snapshot" ]; then
  printf '%s' '{"result":{"snapshot":{"agents":[
    {"pane_id":"pane_101","tab_id":"tab_101","workspace_id":"ws_mine",
     "agent_status":"done","state_change_seq":9,
     "terminal_title":"模型自己寫的中文標題"},
    {"pane_id":"pane_103","tab_id":"tab_103","workspace_id":"ws_mine",
     "agent_status":"working","state_change_seq":42,
     "terminal_title":"另一個模型標題"}]}}}'
  exit 0
fi
if [ "$1" = "tab" ] && [ "$2" = "list" ]; then
  printf '{"result":{"tabs":[{"tab_id":"tab_101"},{"tab_id":"tab_103"}]}}'; exit 0
fi
if [ "$1" = "agent" ] && [ "$2" = "explain" ]; then
  # pane_103 刻意讓 agent explain 失敗（herdr 結束碼 1），用來驗證
  # process_phase 的隔離子殼會在指令替換巢狀失敗時正確提早中止，不會
  # 吞掉失敗後繼續印出一行內容是空字串的 rule=（開放 finding 四，見下
  # 面「巢狀指令替換」那一段斷言）。
  if [ "$5" = "pane_103" ]; then
    exit 1
  fi
  printf '%s' '{"matched_rule":{"id":"stub_explain_rule"},"evaluated_rules":[{"evidence":{"region_preview":"審查用可辨識explain洩漏字串"}}]}'
  exit 0
fi
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
export PATH="$STUB_BIN:$saved_path"
assert_herdr_stub_only "$PATH" "$STUB_BIN"
eo_state_set 101 pane_id '"pane_101"'
eo_state_set 101 tab_id '"tab_101"'

out="$(bash "$SCRIPTS/phase-status.sh" 101)"
if [ "$out" = "phase=101 status=done seq=9" ]; then
  pass "phase-status 回傳最小結果"
else
  bad "phase-status 得到 '$out'"
fi

# 這是本腳本最重要的一條：任何模型產出文字都不得出現在輸出裡。
# 做法是只回自己組出來的欄位，不是從原始回應剝掉幾個具名欄位——
# 承載模型文字的出口至少三處，列舉必漏。
if printf '%s' "$out" | rg -q '模型自己寫的中文標題'; then
  bad "phase-status 把 terminal_title 洩漏進輸出"
else
  pass "phase-status 未洩漏 terminal_title"
fi

# --- 開放 finding 二：--explain 模式沒有進版控的回歸測試 ---
# 樁在 agent explain 的 evidence 裡塞了可辨識字串，斷言它不出現在
# stdout；同時確認 rule= 那一行有正常印出規則名（不是空字串）。
explain_out="$(bash "$SCRIPTS/phase-status.sh" 101 --explain)"
if printf '%s' "$explain_out" | rg -q '審查用可辨識explain洩漏字串'; then
  bad "phase-status --explain 把 evidence 洩漏進輸出"
else
  pass "phase-status --explain 未洩漏 evidence"
fi
if printf '%s' "$explain_out" | rg -q '^rule=stub_explain_rule$'; then
  pass "phase-status --explain 印出規則名"
else
  bad "phase-status --explain 得到 '$explain_out'，未見預期的 rule= 行"
fi

# --- 開放 finding 四：查全部模式對每個 phase 隔離失敗 ---
# phase 102 的 tab_id 刻意設成不在樁回傳的 tab 清單裡（樁的 tab list
# 只有 tab_101），讓它在 workspace 守衛就失敗，重現審查者用真實跨
# workspace 資料重現的那個場景。查全部模式底下，102 的失敗不得讓 101
# 的正常輸出消失，且必須以可辨識的錯誤標記呈現、整體以非零結束碼結束。
eo_state_set 102 pane_id '"pane_102"'
eo_state_set 102 tab_id '"tab_202"'

out_all="$(bash "$SCRIPTS/phase-status.sh" 2>/dev/null)" && rc_all=0 || rc_all=$?
if printf '%s' "$out_all" | rg -q '^phase=101 status=done seq=9$'; then
  pass "查全部模式：phase 101 仍正常輸出"
else
  bad "查全部模式：未見 phase 101 的正常輸出，得到 '$out_all'"
fi
if printf '%s' "$out_all" | rg -q '^phase=102 status=ERROR'; then
  pass "查全部模式：phase 102 workspace 不符時印出可辨識錯誤標記並繼續"
else
  bad "查全部模式：未見 phase 102 的錯誤標記，得到 '$out_all'"
fi
if [ "$rc_all" -ne 0 ]; then
  pass "查全部模式：任一 phase 失敗時整體以非零結束碼結束"
else
  bad "查全部模式：有 phase 失敗但結束碼為 0"
fi

# 查單一 phase 模式不受 finding 四影響：同一個 workspace 不符的 phase，
# 單獨查詢時仍是失敗即結束（結束碼 4），不會印錯誤標記後繼續。
( bash "$SCRIPTS/phase-status.sh" 102 ) >/dev/null 2>/dev/null && rc_single=0 || rc_single=$?
if [ "$rc_single" -eq 4 ]; then
  pass "查單一 phase 模式：workspace 不符時仍是失敗即結束（結束碼 4）"
else
  bad "查單一 phase 模式結束碼為 $rc_single，預期 4"
fi

# --- 開放 finding 四（補強）：巢狀指令替換的失敗也要被隔離子殼攔下 ---
# phase 102 的失敗（workspace 不符）是 eo_assert_workspace 內部直接
# 裸呼叫 eo_die，這種失敗不管有沒有正確隔離都會終止當下的行程，測不出
# 「隔離手法選對了沒有」。真正測得出來的是失敗發生在指令替換裡面的情
# 形，例如 `explain_json="$(eo_herdr agent explain …)"`：如果隔離子殼
# 是包成 `if ( process_phase "$p" ); then …`，bash 會把整個子殼執行期
# 間的 errexit 都當成「正在被測試而暫停」，這一步的失敗會被吞掉、繼續
# 執行到 `rule="$(… // "none")"`，因為輸入是空字串，jq 對這個 filter
# 印出空字串又以 0 結束，最後印出一行看起來合法但完全是假資料的
# `rule=`（用真實 jq 1.8.2 驗證過）。phase 103 就是設計成先讓狀態行成
# 功印出、再讓 agent explain 失敗，藉此把這個巢狀失敗攤開來檢查。
eo_state_set 103 pane_id '"pane_103"'
eo_state_set 103 tab_id '"tab_103"'

out_explain_all="$(bash "$SCRIPTS/phase-status.sh" --explain 2>/dev/null)" && rc_explain_all=0 || rc_explain_all=$?
if printf '%s' "$out_explain_all" | rg -q '^phase=103 status=working seq=42$'; then
  pass "查全部＋--explain：phase 103 的狀態行仍先正常印出"
else
  bad "查全部＋--explain：未見 phase 103 的狀態行，得到 '$out_explain_all'"
fi
if printf '%s' "$out_explain_all" | rg -q '^phase=103 status=ERROR seq=- rc=6$'; then
  pass "查全部＋--explain：phase 103 的 agent explain 失敗被隔離子殼攔下，映射成 6"
else
  bad "查全部＋--explain：未見 phase 103 的錯誤標記（結束碼 6），得到 '$out_explain_all'"
fi
rule_line_count="$(printf '%s' "$out_explain_all" | rg -c '^rule=' || true)"
if [ "$rule_line_count" = "1" ]; then
  pass "查全部＋--explain：只有真的成功的 phase 101 印出 rule= 行，103 沒有假資料的 rule= 行"
else
  bad "查全部＋--explain：rule= 行數是 $rule_line_count，預期只有 1（來自 phase 101）"
fi
if [ "$rc_explain_all" -ne 0 ]; then
  pass "查全部＋--explain：agent explain 失敗也計入整體非零結束碼"
else
  bad "查全部＋--explain：有 phase 失敗但結束碼為 0"
fi

export PATH="$saved_path"

# ===== 任務三：start-phase.sh 與 close-phase.sh =====
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "tab create")
    printf '%s' '{"result":{"tab":{"tab_id":"tab_new"},
                  "root_pane":{"pane_id":"pane_new"}}}'; exit 0 ;;
  "agent start") printf '{"result":{"ok":true}}'; exit 0 ;;
  "agent get")
    printf '%s' '{"result":{"agent":{"agent_status":"idle"}}}'
    exit 0 ;;
  "tab list") printf '{"result":{"tabs":[{"tab_id":"tab_new"}]}}'; exit 0 ;;
  "tab close") printf '{"result":{"ok":true}}'; exit 0 ;;
esac
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
export PATH="$STUB_BIN:$saved_path"
assert_herdr_stub_only "$PATH" "$STUB_BIN"

out="$(bash "$SCRIPTS/start-phase.sh" 103)"
if printf '%s' "$out" | rg -q '^tab_id=tab_new pane_id=pane_new agent=phase-103-'; then
  pass "start-phase 輸出三項座標"
else
  bad "start-phase 得到 '$out'"
fi
if [ "$(eo_state_get 103 pane_id)" = "pane_new" ]; then
  pass "start-phase 把座標寫進狀態檔"
else
  bad "start-phase 未寫入狀態檔"
fi

# 啟動未就緒時必須以 8 結束，且不得繼續。
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "tab create")
    printf '%s' '{"result":{"tab":{"tab_id":"tab_bad"},
                  "root_pane":{"pane_id":"pane_bad"}}}'; exit 0 ;;
  "agent start") exit 1 ;;
esac
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
( bash "$SCRIPTS/start-phase.sh" 104 ) >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" -eq 8 ]; then
  pass "start-phase 對啟動未就緒以 8 結束"
else
  bad "start-phase 啟動未就緒時結束碼為 $rc，預期 8"
fi

# close-phase 守衛三：不得關掉 orchestrator 自己所在的 tab。
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "tab list") printf '{"result":{"tabs":[{"tab_id":"tab_new"}]}}'; exit 0 ;;
  "tab close") printf '{"result":{"ok":true}}'; exit 0 ;;
esac
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
( HERDR_TAB_ID=tab_new bash "$SCRIPTS/close-phase.sh" 103 ) >/dev/null 2>&1 \
  && rc=0 || rc=$?
if [ "$rc" -eq 4 ]; then
  pass "close-phase 拒絕關掉 HERDR_TAB_ID 指向的 tab"
else
  bad "close-phase 對自己的 tab 結束碼為 $rc，預期 4"
fi

# HERDR_TAB_ID 為空時，守衛三視為不成立——不能因為變數沒設就放行。
# shellcheck disable=SC1007 # 刻意寫法：HERDR_TAB_ID= 後接空白再接 bash，是「只為這次呼叫把該變數設為空字串」的合法慣用語法，不是漏打等號右值
( HERDR_TAB_ID= bash "$SCRIPTS/close-phase.sh" 103 ) >/dev/null 2>&1 \
  && rc=0 || rc=$?
if [ "$rc" -eq 4 ]; then
  pass "close-phase 在 HERDR_TAB_ID 為空時視為守衛不成立"
else
  bad "close-phase 在 HERDR_TAB_ID 為空時結束碼為 $rc，預期 4"
fi

# 開放 finding 四：完全不設 HERDR_TAB_ID（而不是賦值為空字串）時，守衛
# 三一樣要視為不成立——這比空字串賦值更貼近真實部署（呼叫端忘了透
# 傳、或腳本被非 herdr 管理的環境誤呼叫）。子殼內明確 unset，不能只是
# 不覆寫：執行這份測試的終端機本身就是一個真實 herdr 管理的 pane，
# ambient HERDR_TAB_ID 一開始就有值，不 unset 就測不到「完全沒有這個
# 變數」這件事。
( unset HERDR_TAB_ID; bash "$SCRIPTS/close-phase.sh" 103 ) >/dev/null 2>&1 \
  && rc=0 || rc=$?
if [ "$rc" -eq 4 ]; then
  pass "close-phase 在 HERDR_TAB_ID 完全未設時視為守衛不成立"
else
  bad "close-phase 在 HERDR_TAB_ID 完全未設時結束碼為 $rc，預期 4"
fi

# 狀態檔記的識別碼與實際不符時也要擋下。
( HERDR_TAB_ID=tab_orchestrator bash "$SCRIPTS/close-phase.sh" 999 ) \
  >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" -eq 5 ]; then
  pass "close-phase 對不在狀態檔的 phase 以 5 結束"
else
  bad "close-phase 對未知 phase 結束碼為 $rc，預期 5"
fi

# 開放 finding 二：守衛二必須真的鎖得住「守衛一與守衛二之間 tab_id 被
# 併發改寫」這個情境，不能只靠靜態樁。前面六條斷言用的三個樁的
# tab list 分支全部回傳固定 JSON，從不會在守衛一與守衛二之間真的改寫
# 狀態檔，測不到守衛二的重讀有沒有真的在守衛。這裡改用一個會有副作用
# 的樁：tab list 分支在回傳前，先把狀態檔裡這個 phase 的 tab_id 改成
# 別的值，模擬另一個行程（例如常駐的 event-generator.sh）在守衛一那
# 次 herdr round trip 期間把它併發改寫掉。用獨立的 phase 105，避免
# 污染前面幾條斷言仍在用的 phase 103／104 狀態。
eo_state_set 105 tab_id '"tab_105"'
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "tab list")
    state_file="$EO_MAIN_REPO/.tmp/epic-orchestration/state.json"
    tmp="$(mktemp "${state_file}.XXXXXX")"
    jq '.phases["105"].tab_id = "tab_105_hijacked"' "$state_file" > "$tmp"
    mv "$tmp" "$state_file"
    printf '{"result":{"tabs":[{"tab_id":"tab_105"}]}}'
    exit 0 ;;
  "tab close") printf '{"result":{"ok":true}}'; exit 0 ;;
esac
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
close_phase_guard2_err="$T/close-phase-guard2.err"
( HERDR_TAB_ID=tab_orchestrator bash "$SCRIPTS/close-phase.sh" 105 ) \
  >/dev/null 2>"$close_phase_guard2_err" && rc=0 || rc=$?
if [ "$rc" -eq 4 ] && rg -q '守衛二' "$close_phase_guard2_err"; then
  pass "close-phase 守衛二擋下守衛一與守衛二之間的併發改寫"
else
  bad "close-phase 守衛二測試結束碼為 $rc，stderr='$(cat "$close_phase_guard2_err")'"
fi

export PATH="$saved_path"

# ===== 任務四：send-to-phase.sh =====
# 既有測試用 phase 101 到 107，這裡改用 201 避免污染。
# 文字必須包成單一引數。不包起來 shell 會在第一個空白處切開，
# 可能整條失敗，也可能只送出第一段而握手照樣回報成功。
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "agent" ] && [ "$2" = "prompt" ]; then
  printf '%s\n' "$4" > "$EO_TEST_CAPTURE"
  printf '{"result":{"agent_status":"working"}}'
  exit 0
fi
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
export PATH="$STUB_BIN:$saved_path"
assert_herdr_stub_only "$PATH" "$STUB_BIN"
export EO_TEST_CAPTURE="$T/captured-text"
eo_state_set 201 agent_name '"phase-201-abcd"'

bash "$SCRIPTS/send-to-phase.sh" 201 '第一段 第二段 第三段' >/dev/null
if [ "$(cat "$EO_TEST_CAPTURE")" = "第一段 第二段 第三段" ]; then
  pass "send-to-phase 把文字包成單一引數"
else
  bad "send-to-phase 送出的是 '$(cat "$EO_TEST_CAPTURE")'，文字被切開了"
fi

# 對方 blocked 時 herdr 以 agent_blocked 拒絕，文字完全不會送達。
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '{"error":{"code":"agent_blocked"}}' >&2
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
( bash "$SCRIPTS/send-to-phase.sh" 201 '定案內容' ) >/dev/null 2>&1 \
  && rc=0 || rc=$?
if [ "$rc" -eq 6 ]; then
  pass "send-to-phase 對 blocked 對象以 6 結束"
else
  bad "send-to-phase 對 blocked 對象結束碼為 $rc，預期 6"
fi

# 握手逾時不是失敗，是「未取得憑據」——出口是 7，交給呼叫端派調查者。
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '{"error":{"code":"timeout"}}' >&2
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
out="$( ( bash "$SCRIPTS/send-to-phase.sh" 201 '定案內容' ) 2>/dev/null )" \
  && rc=0 || rc=$?
if [ "$rc" -eq 7 ] && [ "$out" = "handshake=none" ]; then
  pass "send-to-phase 對逾時回 handshake=none 並以 7 結束"
else
  bad "send-to-phase 逾時得到 rc=$rc out='$out'，預期 rc=7 out=handshake=none"
fi

# agent_prompt_stalled 與逾時同一類：未取得憑據，出口同樣是 7。
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '{"error":{"code":"agent_prompt_stalled"}}' >&2
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
out="$( ( bash "$SCRIPTS/send-to-phase.sh" 201 '定案內容' ) 2>/dev/null )" \
  && rc=0 || rc=$?
if [ "$rc" -eq 7 ] && [ "$out" = "handshake=none" ]; then
  pass "send-to-phase 對 agent_prompt_stalled 回 handshake=none 並以 7 結束"
else
  bad "send-to-phase 對 agent_prompt_stalled 得到 rc=$rc out='$out'，預期 rc=7 out=handshake=none"
fi

# --no-handshake：合併後廣播 main 動了走這條，收件的每個 phase 都還在 working。
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "agent" ] && [ "$2" = "prompt" ]; then
  # 沒有 --wait 就不該出現 --until
  for a in "$@"; do
    [ "$a" = "--until" ] && { printf 'unexpected --until\n' >&2; exit 9; }
  done
  printf '{"result":{}}'; exit 0
fi
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
out="$(bash "$SCRIPTS/send-to-phase.sh" 201 'main 動了' --no-handshake)"
if [ "$out" = "handshake=skipped" ]; then
  pass "send-to-phase --no-handshake 不帶 --until 且回 skipped"
else
  bad "send-to-phase --no-handshake 得到 '$out'"
fi

# --no-handshake 不吞送出當下的拒絕：agent_blocked 仍以 6 結束。
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '{"error":{"code":"agent_blocked"}}' >&2
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
( bash "$SCRIPTS/send-to-phase.sh" 201 '定案內容' --no-handshake ) \
  >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" -eq 6 ]; then
  pass "send-to-phase --no-handshake 對送出當下的 blocked 仍以 6 結束"
else
  bad "send-to-phase --no-handshake 對 blocked 結束碼為 $rc，預期 6"
fi

# --handshake-timeout 覆寫預設值：把值原樣轉給 herdr 的 --timeout。
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "agent" ] && [ "$2" = "prompt" ]; then
  for i in "$@"; do
    if [ "$prev" = "--timeout" ]; then
      printf '%s' "$i" > "$EO_TEST_CAPTURE"
    fi
    prev="$i"
  done
  printf '{"result":{"agent_status":"working"}}'; exit 0
fi
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
bash "$SCRIPTS/send-to-phase.sh" 201 '定案內容' --handshake-timeout 3000 >/dev/null
if [ "$(cat "$EO_TEST_CAPTURE")" = "3000" ]; then
  pass "send-to-phase --handshake-timeout 覆寫預設逾時值"
else
  bad "send-to-phase --handshake-timeout 得到 '$(cat "$EO_TEST_CAPTURE")'，預期 3000"
fi
export PATH="$saved_path"

exit "$fail"
