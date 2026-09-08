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

# Medium 11（修正輪次 2）：明確設定 HERDR_ENV，不依賴執行這份測試的
# 終端機本身剛好是 herdr 管理的環境（本機開發環境恰好是，但套件不
# 該因此變得只在那個環境下才 hermetic）。已實測：沒有這一行時，在
# 沒有 HERDR_ENV 的環境下跑這份套件，原本預期以 2 結束的斷言會得到
# 3（HERDR_ENV 前提不成立），不是真的在測參數檢查。
export HERDR_ENV=1

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

out="$(bash "$SCRIPTS/send-to-phase.sh" 201 '第一段 第二段 第三段')"
if [ "$(cat "$EO_TEST_CAPTURE")" = "第一段 第二段 第三段" ]; then
  pass "send-to-phase 把文字包成單一引數"
else
  bad "send-to-phase 送出的是 '$(cat "$EO_TEST_CAPTURE")'，文字被切開了"
fi

# 開放 finding 一：handshake=ok 是文件化的契約字串，呼叫端依它判斷，
# 必須有斷言直接比對，不能只間接靠外層 errexit 守成功結束碼。
if [ "$out" = "handshake=ok" ]; then
  pass "send-to-phase 取得憑據時輸出 handshake=ok"
else
  bad "send-to-phase 取得憑據時輸出 '$out'，預期 handshake=ok"
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

# 開放 finding 二：呼叫端用錯（結束碼 2）的三種情形，全部在觸碰狀態檔
# 或呼叫 herdr 之前就先結束，不需要 herdr 樁，也不依賴 phase 999 是否
# 存在於狀態檔——用 999 只是取一個明顯與其他斷言無關的號碼。
( bash "$SCRIPTS/send-to-phase.sh" ) >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "send-to-phase 完全未帶參數時以 2 結束"
else
  bad "send-to-phase 完全未帶參數時結束碼為 $rc，預期 2"
fi

( bash "$SCRIPTS/send-to-phase.sh" 999 ) >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "send-to-phase 缺少必填參數 <文字> 時以 2 結束"
else
  bad "send-to-phase 缺少 <文字> 時結束碼為 $rc，預期 2"
fi

( bash "$SCRIPTS/send-to-phase.sh" 999 '定案內容' --handshake-timeout ) \
  >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "send-to-phase --handshake-timeout 缺值時以 2 結束"
else
  bad "send-to-phase --handshake-timeout 缺值時結束碼為 $rc，預期 2"
fi

( bash "$SCRIPTS/send-to-phase.sh" 999 '定案內容' --unknown-flag ) \
  >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "send-to-phase 未知選項時以 2 結束"
else
  bad "send-to-phase 未知選項時結束碼為 $rc，預期 2"
fi
export PATH="$saved_path"

# ===== 任務五：press-approval.sh =====
# 開發期查證發現的落差：任務簡報 Step 1 原始測試樁把 agent get 的回應
# 寫成扁平結構 {"result":{"agent_status":...}}，與已查證事實衝突——
# 已對真實 herdr 0.8.2 執行 `herdr agent get <target>` 唯讀查證，回應
# 是巢狀的：欄位在 result 底下的 agent 底下。任務三 start-phase.sh 的
# 既有測試樁（見上方任務三段落）已經是巢狀結構，這裡的樁改用同樣的巢
# 狀結構，與腳本的巢狀解析對齊，避免「樁與實作共享同一個錯誤假設、綠
# 燈掩蓋真實環境失效」。既有測試用到 phase 101 到 107 與 201 到 202，
# 這裡改用 301／302 避免污染。
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "agent get")
    printf '%s' '{"result":{"agent":{"agent_status":"blocked"}}}'
    exit 0 ;;
  "agent send-keys") printf '{"result":{}}'; exit 0 ;;
  "agent wait")
    # 一般核准框必須正面帶到 --until working，且絕不能帶 --until
    # idle。只擋 idle（負面單向）測不出「兩條分支其實共用同一段邏
    # 輯、只是換個訊息」這種假分支：若實作永遠等某個第三個值（例如
    # done），這裡的舊寫法會誤判通過。改成正面要求看到 working、同
    # 時仍然禁止 idle，才與下面 --startup 那組的 saw_idle 正面判斷對
    # 稱，合起來才真的證明兩條分支各自送出不同的 --until 值。
    saw_working=0
    for a in "$@"; do
      [ "$a" = "idle" ] && { printf 'unexpected --until idle\n' >&2; exit 9; }
      [ "$a" = "working" ] && saw_working=1
    done
    if [ "$saw_working" -ne 1 ]; then
      printf '未見 --until working\n' >&2
      exit 9
    fi
    printf '%s' '{"result":{"agent":{"agent_status":"working"}}}'
    exit 0 ;;
esac
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
export PATH="$STUB_BIN:$saved_path"
assert_herdr_stub_only "$PATH" "$STUB_BIN"
eo_state_set 301 agent_name '"phase-301-abcd"'

# --allows 是必填。這是整支腳本存在的理由：把「按之前要指得出放行什麼」
# 從散文約束變成缺了就跑不動的參數。
( bash "$SCRIPTS/press-approval.sh" 301 enter ) >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "press-approval 缺 --allows 時以 2 結束"
else
  bad "press-approval 缺 --allows 時結束碼為 $rc，預期 2"
fi

# 開放落差：直接比對 handshake=ok 這個文件化的契約字串，不只間接靠外
# 層 errexit 守成功結束碼（沿用任務四對 send-to-phase.sh 的同一種強化）。
out="$(bash "$SCRIPTS/press-approval.sh" 301 enter \
     --allows '寫入 skills/epic-orchestration/scripts/start-phase.sh')" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "handshake=ok" ]; then
  pass "press-approval 帶 --allows 時放行並取得憑據"
else
  bad "press-approval 帶 --allows 時得到 rc=$rc out='$out'"
fi

# 執行前必須重查狀態仍為 blocked。畫面已經換掉時按下去會按在別的東西上。
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "agent get")
    printf '%s' '{"result":{"agent":{"agent_status":"working"}}}'
    exit 0 ;;
  "agent send-keys") printf 'send-keys 不該被呼叫\n' >&2; exit 9 ;;
esac
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
( bash "$SCRIPTS/press-approval.sh" 301 enter --allows '任意動作' ) \
  >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" -eq 6 ]; then
  pass "press-approval 在狀態已非 blocked 時拒絕代按"
else
  bad "press-approval 在狀態已非 blocked 時結束碼為 $rc，預期 6"
fi

# --startup：不等 working，改為確認狀態已離開 blocked 回到 idle。用獨
# 立的 phase 302，樁直接檢查 herdr agent wait 收到的是 --until idle 而
# 不是 --until working，正面驗證兩種取憑據方式真的走了不同分支，而不
# 只是靠回應內容湊巧對得上。跟上面 phase 301 那組（正面要求
# --until working、同時禁止 idle）合在一起看：兩邊都各自正面斷言自己
# 該送出的值、也各自禁止對方那個值，證明的是「兩條分支真的各自送出
# 不同的 --until」，不是「其中一條分支預設就會通過、另一條才有事後檢
# 查」這種不對稱、可能放過假分支的驗證。
eo_state_set 302 agent_name '"phase-302-abcd"'
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "agent get")
    printf '%s' '{"result":{"agent":{"agent_status":"blocked"}}}'
    exit 0 ;;
  "agent send-keys") printf '{"result":{}}'; exit 0 ;;
  "agent wait")
    saw_idle=0
    for a in "$@"; do
      [ "$a" = "working" ] && { printf 'unexpected --until working in --startup mode\n' >&2; exit 9; }
      [ "$a" = "idle" ] && saw_idle=1
    done
    if [ "$saw_idle" -ne 1 ]; then
      printf '未見 --until idle\n' >&2
      exit 9
    fi
    printf '%s' '{"result":{"agent":{"agent_status":"idle"}}}'
    exit 0 ;;
esac
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
out="$(bash "$SCRIPTS/press-approval.sh" 302 enter --allows '啟動階段信任對話框' --startup)" \
  && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "handshake=ok" ]; then
  pass "press-approval --startup 等的是 idle 而不是 working"
else
  bad "press-approval --startup 得到 rc=$rc out='$out'"
fi

# --startup 逾時（未離開 blocked 回到 idle）：未取得憑據，以 7 結束，
# 不當成失敗——跟一般核准框逾時同一類，交給呼叫端判斷。
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "agent get")
    printf '%s' '{"result":{"agent":{"agent_status":"blocked"}}}'
    exit 0 ;;
  "agent send-keys") printf '{"result":{}}'; exit 0 ;;
  "agent wait") printf '{"error":{"code":"timeout"}}' >&2; exit 1 ;;
esac
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
out="$( ( bash "$SCRIPTS/press-approval.sh" 302 enter --allows '啟動階段信任對話框' --startup ) 2>/dev/null )" \
  && rc=0 || rc=$?
if [ "$rc" -eq 7 ] && [ "$out" = "handshake=none" ]; then
  pass "press-approval 對逾時（未取得憑據）回 handshake=none 並以 7 結束"
else
  bad "press-approval 逾時得到 rc=$rc out='$out'，預期 rc=7 out=handshake=none"
fi

# 全案性的測試要求：呼叫端用錯（結束碼 2）——缺必填參數、選項缺值、
# 未知選項。這四種情形全部在觸碰狀態檔或呼叫 herdr 之前就先結束，不
# 需要 herdr 樁、也不依賴 phase 999 是否存在於狀態檔——用 999 只是取
# 一個明顯與其他斷言無關的號碼（沿用任務四 send-to-phase.sh 同一類測
# 試已用過的慣例）。
( bash "$SCRIPTS/press-approval.sh" ) >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "press-approval 完全未帶參數時以 2 結束"
else
  bad "press-approval 完全未帶參數時結束碼為 $rc，預期 2"
fi

( bash "$SCRIPTS/press-approval.sh" 999 ) >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "press-approval 缺少必填參數 <按鍵> 時以 2 結束"
else
  bad "press-approval 缺少 <按鍵> 時結束碼為 $rc，預期 2"
fi

( bash "$SCRIPTS/press-approval.sh" 999 enter --allows ) >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "press-approval --allows 缺值時以 2 結束"
else
  bad "press-approval --allows 缺值時結束碼為 $rc，預期 2"
fi

( bash "$SCRIPTS/press-approval.sh" 999 enter --allows '定案內容' --unknown-flag ) \
  >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "press-approval 未知選項時以 2 結束"
else
  bad "press-approval 未知選項時結束碼為 $rc，預期 2"
fi

export PATH="$saved_path"

# ===== 任務六：read-phase-pane.sh =====
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "tab list") printf '{"result":{"tabs":[{"tab_id":"tab_107"}]}}'; exit 0 ;;
  "pane read")
    cat <<'SCREEN'
[PHASE 107] seq=3 state=working-ok
一些中間輸出
[PHASE 107] seq=4 state=need-decision
SCREEN
    exit 0 ;;
esac
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
export PATH="$STUB_BIN:$saved_path"
assert_herdr_stub_only "$PATH" "$STUB_BIN"
eo_state_set 107 pane_id '"pane_107"'
eo_state_set 107 tab_id '"tab_107"'

# 畫面上會同時存在好幾個回合的標記（實測一屏內看到 seq=1,1,2,2,3,4,4），
# 所以要取最後一個，而且不得用出現次數判斷。
out="$(bash "$SCRIPTS/read-phase-pane.sh" 107 --marker-only)"
if [ "$out" = "[PHASE 107] seq=4 state=need-decision" ]; then
  pass "read-phase-pane --marker-only 取最後一個標記行"
else
  bad "read-phase-pane --marker-only 得到 '$out'"
fi

# 預設模式（不帶 --marker-only）：原樣輸出畫面文字。
out="$(bash "$SCRIPTS/read-phase-pane.sh" 107)"
expected_screen="$(printf '[PHASE 107] seq=3 state=working-ok\n一些中間輸出\n[PHASE 107] seq=4 state=need-decision')"
if [ "$out" = "$expected_screen" ]; then
  pass "read-phase-pane 預設模式原樣輸出畫面文字"
else
  bad "read-phase-pane 預設模式得到 '$out'"
fi

# 沒有標記行時回 marker=none，交由呼叫端派調查者。
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "tab list") printf '{"result":{"tabs":[{"tab_id":"tab_107"}]}}'; exit 0 ;;
  "pane read") printf '沒有任何標記行\n'; exit 0 ;;
esac
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
if [ "$(bash "$SCRIPTS/read-phase-pane.sh" 107 --marker-only)" = "marker=none" ]; then
  pass "read-phase-pane 無標記行時回 marker=none"
else
  bad "read-phase-pane 無標記行時未回 marker=none"
fi

# pane_not_found 代表這個 pane 已經不在了，歸 GONE 處置，
# 與「讀取失敗或回傳空白」是不同的兩件事，不能混在一起。
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "tab list") printf '{"result":{"tabs":[{"tab_id":"tab_107"}]}}'; exit 0 ;;
  "pane read") printf '{"error":{"code":"pane_not_found"}}' >&2; exit 1 ;;
esac
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
( bash "$SCRIPTS/read-phase-pane.sh" 107 ) >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" -eq 6 ]; then
  pass "read-phase-pane 對 pane_not_found 以 6 結束"
else
  bad "read-phase-pane 對 pane_not_found 結束碼為 $rc，預期 6"
fi
export PATH="$saved_path"

# 全案性的測試要求：呼叫端用錯（結束碼 2）——缺必填參數、未知選項。
# 這兩種情形都在觸碰狀態檔或呼叫 herdr 之前就先結束，不需要 herdr
# 樁、也不依賴 phase 999 是否存在於狀態檔——用 999 只是取一個明顯與
# 其他斷言無關的號碼（沿用任務四、任務五同一類測試已用過的慣例）。
( bash "$SCRIPTS/read-phase-pane.sh" ) >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "read-phase-pane 完全未帶參數時以 2 結束"
else
  bad "read-phase-pane 完全未帶參數時結束碼為 $rc，預期 2"
fi

( bash "$SCRIPTS/read-phase-pane.sh" 999 --unknown-flag ) >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "read-phase-pane 未知選項時以 2 結束"
else
  bad "read-phase-pane 未知選項時結束碼為 $rc，預期 2"
fi

# 開放 finding（Medium，修正輪次 1）：--marker-only 把 phase 原樣接進
# grep 的 basic regular expression 樣式，若 phase 帶有未跳脫的正規表
# 示式特殊字元（例如中括號），會被解讀成字元類別、吃掉後面字元，導致
# 明明畫面上逐字存在對應的標記行，卻靜默回報 marker=none——這個結果
# 跟「畫面上真的沒有標記行」完全無法區分，沒有任何錯誤訊息。以下重現
# 這個情境：狀態檔的 phase 鍵值故意設成含中括號的字串，畫面文字裡逐
# 字存在對應的標記行，驗證修正後的行為是在碰到 grep 之前就以呼叫端用
# 錯的 2 明確拒絕，不是放行到 grep 那一步再靜默回 marker=none。herdr
# 樁在此仍完整提供 tab list／pane read（且 pane read 回傳的畫面文字
# 真的逐字含有這個標記行），確保這條斷言測的是「明確拒絕」本身，而不
# 是湊巧在更早的步驟（狀態檔或 workspace 守衛）就失敗。
bad_phase='10[9'
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "tab list") printf '{"result":{"tabs":[{"tab_id":"tab_bad_phase"}]}}'; exit 0 ;;
  "pane read") printf '[PHASE 10[9] seq=7 state=working\n'; exit 0 ;;
esac
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
export PATH="$STUB_BIN:$saved_path"
assert_herdr_stub_only "$PATH" "$STUB_BIN"
eo_state_set "$bad_phase" pane_id '"pane_bad_phase"'
eo_state_set "$bad_phase" tab_id '"tab_bad_phase"'

out="$( ( bash "$SCRIPTS/read-phase-pane.sh" "$bad_phase" --marker-only ) 2>/dev/null )" && rc=0 || rc=$?
if [ "$rc" -eq 2 ] && [ "$out" != "marker=none" ]; then
  pass "read-phase-pane --marker-only 對含正規表示式特殊字元的 phase 編號明確拒絕，不是靜默回報 marker=none"
else
  bad "read-phase-pane --marker-only 對特殊字元 phase 編號得到 rc=$rc out='$out'，預期 rc=2 且不是 marker=none"
fi
export PATH="$saved_path"

# ===== 任務七：event-generator.sh =====
# shellcheck source=/dev/null
EO_GENERATOR_NO_MAIN=1 source "$SCRIPTS/event-generator.sh"

# 分流：working-ok 且 seq 變大 → 自動推進，不印任何一行。
eo_state_set 108 last_marker_seq 5
eo_state_set 108 auto_push_count 0
eo_state_set 108 held_by_orchestrator false
out="$(eo_classify_stop 108 "done" '[PHASE 108] seq=6 state=working-ok')"
if [ -z "$out" ]; then
  pass "working-ok 且 seq 變大時不產生事件行"
else
  bad "working-ok 不該印事件，卻印了 '$out'"
fi
if [ "$(eo_state_get 108 last_marker_seq)" = "6" ]; then
  pass "自動推進後更新 last_marker_seq"
else
  bad "自動推進後未更新 last_marker_seq"
fi

# seq 沒變大 ＝ 抓到的是上一回合殘留的舊標記，等同標記缺席。
# 這是整個機制的關鍵：危險方向是舊標記被當成新的，只有 seq 攔得住。
out="$(eo_classify_stop 108 "done" '[PHASE 108] seq=6 state=working-ok')"
if [ "$out" = "phase=108 stopped=done marker=none" ]; then
  pass "seq 沒變大時視同標記缺席"
else
  bad "seq 沒變大時得到 '$out'，預期 marker=none"
fi

# pr-ready 要進 orchestrator，不能被自動推掉。
out="$(eo_classify_stop 108 "done" '[PHASE 108] seq=7 state=pr-ready pr=456')"
if [ "$out" = "phase=108 stopped=done marker=pr-ready pr=456" ]; then
  pass "pr-ready 產生事件行"
else
  bad "pr-ready 得到 '$out'"
fi

# 互斥：orchestrator 持有中時，產生器不得自動推。
eo_state_set 108 held_by_orchestrator true
eo_state_set 108 last_marker_seq 7
out="$(eo_classify_stop 108 "done" '[PHASE 108] seq=8 state=working-ok')"
if [ -n "$out" ]; then
  pass "orchestrator 持有中時不自動推、改交回事件"
else
  bad "orchestrator 持有中時仍自動推了"
fi
eo_state_set 108 held_by_orchestrator false

# 自動推進上限 40 次：超過就交回 orchestrator。
eo_state_set 108 auto_push_count 40
eo_state_set 108 last_marker_seq 8
out="$(eo_classify_stop 108 "done" '[PHASE 108] seq=9 state=working-ok')"
if [ "$out" = "phase=108 AUTO-PUSH-LIMIT count=40" ]; then
  pass "自動推進達 40 次時印 AUTO-PUSH-LIMIT"
else
  bad "達上限時得到 '$out'"
fi

# 邊緣觸發：SPINNING 印過就靜音，直到 seq 變動才解除。
eo_state_set 109 spinning_muted false
first="$(eo_scan_spinning 109 3 "$(( $(date +%s) - 1600 ))")"
second="$(eo_scan_spinning 109 3 "$(( $(date +%s) - 1600 ))")"
if [ "$first" = "phase=109 SPINNING" ] && [ -z "$second" ]; then
  pass "SPINNING 邊緣觸發：第二次靜音"
else
  bad "SPINNING 邊緣觸發失效：first='$first' second='$second'"
fi
third="$(eo_scan_spinning 109 4 "$(date +%s)")"
fourth="$(eo_scan_spinning 109 4 "$(( $(date +%s) - 1600 ))")"
if [ -z "$third" ] && [ "$fourth" = "phase=109 SPINNING" ]; then
  pass "SPINNING 在 seq 變動後解除靜音"
else
  bad "SPINNING 靜音未解除：third='$third' fourth='$fourth'"
fi

# unknown 要連續 5 輪才印。少了這一條，落進 unknown 的 phase
# 兩條通道都抓不到，會從編排端的視野裡無聲消失。
eo_state_set 110 unknown_rounds 0
eo_state_set 110 unclassified_muted false
last=""
for _ in 1 2 3 4 5; do last="$(eo_scan_unknown 110 unknown)"; done
if [ "$last" = "phase=110 UNCLASSIFIED" ]; then
  pass "unknown 連續 5 輪後印 UNCLASSIFIED"
else
  bad "unknown 第 5 輪得到 '$last'"
fi
eo_state_set 110 unknown_rounds 0
eo_state_set 110 unclassified_muted false
early=""
for _ in 1 2 3 4; do early="$(eo_scan_unknown 110 unknown)"; done
if [ -z "$early" ]; then
  pass "unknown 未滿 5 輪不印"
else
  bad "unknown 第 4 輪就印了 '$early'"
fi

# ===== 修正輪次 2：獨立審查發現的 Critical／High／Medium／Low findings =====

# --- Critical 1：_eo_ensure_phase_defaults 面對「只有三個座標欄位」
# 的狀態檔（也就是 start-phase.sh 真正會寫的那三個：tab_id／
# pane_id／agent_name）時，必須真的把七個邊緣觸發欄位補齊，而不是讓
# 行程被 eo_state_get 的 exit 5（沒有包進命令替換就裸呼叫會直接終止
# 呼叫端）悄悄帶走。這是每個由 start-phase.sh 建立的 phase 的預設狀
# 態，修不好會讓事件產生器在真實流程下對每個 phase 都悄悄死掉。 ---
eo_state_set 111 tab_id '"tab_111"'
eo_state_set 111 pane_id '"pane_111"'
eo_state_set 111 agent_name '"phase-111-abcd"'
_eo_ensure_phase_defaults 111
if [ "$(eo_state_get 111 last_marker_seq)" = "0" ] \
   && [ "$(eo_state_get 111 held_by_orchestrator)" = "false" ] \
   && [ "$(eo_state_get 111 auto_push_count)" = "0" ] \
   && [ "$(eo_state_get 111 unknown_rounds)" = "0" ] \
   && [ "$(eo_state_get 111 spinning_muted)" = "false" ] \
   && [ "$(eo_state_get 111 gone_muted)" = "false" ] \
   && [ "$(eo_state_get 111 unclassified_muted)" = "false" ]; then
  pass "_eo_ensure_phase_defaults 補齊只有三個座標欄位的 phase（Critical 1 回歸測試）"
else
  bad "_eo_ensure_phase_defaults 未補齊全部七個欄位"
fi

# --- Critical 2：seq 追蹤本身（_eo_track_spin_seq）要能通過「同一個
# seq 連續兩輪，時間戳不得被重設」的驗證。舊版把追蹤寫在會被隔離子
# 殼呼叫的 _eo_low_freq_process_one 裡，子殼寫進行程內關聯陣列的值
# 離開子殼就消失，SPINNING 整條事件類型因此永遠不會觸發。這條測試
# 直接對著追蹤函式本身斷言（完全不需要 herdr 樁），才測得出「有沒
# 有真的留在同一個行程裡」這件事，不是像舊版測試那樣把時間戳直接餵
# 給決策函式、繞過了真正的追蹤邏輯。 ---
_EO_SPIN_SEQ=()
_EO_SPIN_EPOCH=()
_eo_track_spin_seq 120 working 7
first_epoch="${_EO_SPIN_EPOCH[120]}"
sleep 1.1
_eo_track_spin_seq 120 working 7
second_epoch="${_EO_SPIN_EPOCH[120]}"
if [ -n "$first_epoch" ] && [ "$first_epoch" = "$second_epoch" ]; then
  pass "_eo_track_spin_seq：同一個 seq 連續兩輪，時間戳不被重設（Critical 2 回歸測試）"
else
  bad "_eo_track_spin_seq 時間戳被重設：first='$first_epoch' second='$second_epoch'"
fi
sleep 1.1
_eo_track_spin_seq 120 working 8
third_epoch="${_EO_SPIN_EPOCH[120]}"
if [ -n "$third_epoch" ] && [ "$third_epoch" != "$second_epoch" ]; then
  pass "_eo_track_spin_seq：seq 變動後時間戳跟著更新到新的現在"
else
  bad "_eo_track_spin_seq 在 seq 變動時未更新時間戳：third='$third_epoch'"
fi

# --- Critical 4／Low 14 第 3 項：邊緣迴圈的 GONE 與低頻掃描的 GONE
# 共用同一個 gone_muted 欄位，同一次消失不論哪條通道先看到都只印一
# 次；phase 重新出現在低頻掃描的查詢結果裡（present=1）會解除靜音，
# 讓下一次真的消失還印得出來。_eo_low_freq_process_one 對
# status=ERROR 的處理就是低頻掃描版的 GONE 通道，不需要 herdr 樁就
# 測得起來。 ---
eo_state_set 114 gone_muted false
out_gone_edge="$(_eo_scan_gone 114 0)"
out_gone_lowfreq="$(_eo_low_freq_process_one 114 ERROR - 0)"
if [ "$out_gone_edge" = "phase=114 GONE" ] && [ -z "$out_gone_lowfreq" ]; then
  pass "GONE 兩條通道共用 gone_muted，同一次消失只印一次"
else
  bad "GONE 共用靜音失效：edge='$out_gone_edge' lowfreq='$out_gone_lowfreq'"
fi
out_gone_reappear="$(_eo_low_freq_process_one 114 "done" 5 0)"
out_gone_again="$(_eo_scan_gone 114 0)"
if [ -z "$out_gone_reappear" ] && [ "$out_gone_again" = "phase=114 GONE" ]; then
  pass "GONE 靜音在低頻掃描見到重新出現後解除，下一次消失會再印"
else
  bad "GONE 靜音解除失效：reappear='$out_gone_reappear' again='$out_gone_again'"
fi

# --- High 6：狀態檔的數值欄位在進算術展開前先驗證是純數字，防的是
# 已被獨立審查用真實 jq 1.8.2 重現過的注入——把 unknown_rounds 設成
# 一段含指令替換的字串，呼叫決策函式後真的建立了檔案。這裡對三個
# `$(( ))` 站點（eo_scan_unknown 的 unknown_rounds、eo_classify_stop
# 的 auto_push_count 與 last_marker_seq）分別驗證修正後會被明確拒
# 絕、不會被執行，不是只補審查者指出的那一個欄位。 ---
# shellcheck disable=SC2016 # 刻意寫法：單引號段落是要保持字面不展開的惡意 payload 文字本身（$(touch ...)），只有 "$T" 那一段是特意用雙引號接上的真實路徑，兩段拼接不是誤用單引號
malicious_unknown_rounds='"$(touch '"$T"'/pwned-unknown-rounds)"'
eo_state_set 115 unknown_rounds "$malicious_unknown_rounds"
eo_state_set 115 unclassified_muted false
( eo_scan_unknown 115 unknown ) 2>/dev/null && rc=0 || rc=$?
if [ "$rc" -eq 5 ] && [ ! -e "$T/pwned-unknown-rounds" ]; then
  pass "eo_scan_unknown 拒絕非純數字的 unknown_rounds，不執行內容（High 6 回歸測試）"
else
  bad "eo_scan_unknown 注入防護測試得到 rc=$rc，pwned 檔案存在＝$([ -e "$T/pwned-unknown-rounds" ] && echo yes || echo no)"
fi

# shellcheck disable=SC2016 # 刻意寫法，理由同上一段的 malicious_unknown_rounds
malicious_last_seq='"$(touch '"$T"'/pwned-last-seq)"'
eo_state_set 116 last_marker_seq "$malicious_last_seq"
( eo_classify_stop 116 "done" '[PHASE 116] seq=1 state=working-ok' ) 2>/dev/null && rc=0 || rc=$?
if [ "$rc" -eq 5 ] && [ ! -e "$T/pwned-last-seq" ]; then
  pass "eo_classify_stop 拒絕非純數字的 last_marker_seq，不執行內容（High 6 回歸測試）"
else
  bad "eo_classify_stop 對 last_marker_seq 注入防護測試得到 rc=$rc"
fi

# shellcheck disable=SC2016 # 刻意寫法，理由同上面 malicious_unknown_rounds 那一段
malicious_auto_count='"$(touch '"$T"'/pwned-auto-count)"'
eo_state_set 117 last_marker_seq 0
eo_state_set 117 held_by_orchestrator false
eo_state_set 117 auto_push_count "$malicious_auto_count"
( eo_classify_stop 117 "done" '[PHASE 117] seq=1 state=working-ok' ) 2>/dev/null && rc=0 || rc=$?
if [ "$rc" -eq 5 ] && [ ! -e "$T/pwned-auto-count" ]; then
  pass "eo_classify_stop 拒絕非純數字的 auto_push_count，不執行內容（High 6 回歸測試）"
else
  bad "eo_classify_stop 對 auto_push_count 注入防護測試得到 rc=$rc"
fi

# --- Low 14 第 1 項：eo_classify_stop 要核對標記行裡的 phase 編號與
# 參數一致，不能只信任呼叫端（例如 read-phase-pane.sh）已經用
# pane_id 對過號——那是函式契約外的依賴。標記行編號對不上時視同標
# 記缺席，這一步在碰到狀態檔之前就發生，不需要事先設定任何欄位。 ---
out="$(eo_classify_stop 118 "done" '[PHASE 999] seq=5 state=working-ok')"
if [ "$out" = "phase=118 stopped=done marker=none" ]; then
  pass "eo_classify_stop 核對標記行裡的 phase 編號，不符時視同缺席"
else
  bad "eo_classify_stop 標記編號不符時得到 '$out'"
fi

# --- Low 14 第 2 項：stopped_status 必須限制在 idle／done／blocked
# 三者之一，不能直接信任呼叫端傳來的字串——真實流程裡它是 herdr 回
# 報的 agent_status，理論上不該是別的值，但決策函式自己要有這道白
# 名單，不依賴呼叫端已經篩過。 ---
( eo_classify_stop 119 working '[PHASE 119] seq=1 state=working-ok' ) 2>/dev/null && rc=0 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "eo_classify_stop 拒絕不在 idle／done／blocked 之列的停下狀態"
else
  bad "eo_classify_stop 對非法停下狀態結束碼為 $rc，預期 2"
fi

# --- Medium 13：EO_GENERATOR_DRY_RUN 開關。這是這支腳本唯一會主動
# 對真實 agent 送下行的動作（_eo_do_auto_push），設定這個環境變數
# 時完全不呼叫 send-to-phase.sh、不觸及 herdr，改印一行可辨識的觀察
# 行——這個分支不需要任何 herdr 樁就測得起來，依規定必須有測試。 ---
out="$(EO_GENERATOR_DRY_RUN=1 _eo_do_auto_push 999 2>&1 1>/dev/null)"
if [ "$out" = "phase=999 DRY-RUN-AUTO-PUSH" ]; then
  pass "EO_GENERATOR_DRY_RUN 開啟時不呼叫 send-to-phase.sh，改印觀察行"
else
  bad "EO_GENERATOR_DRY_RUN 開啟時得到 '$out'"
fi

# --- High 7（上）：pidfile 單例守衛。不需要 herdr 樁：只操作 pidfile
# 與行程存活檢查。三種情況：pidfile 不存在（成功並寫入自己的 pid）、
# pidfile 裡的 pid 已死（視為可以接手）、pidfile 裡的 pid 還活著
# （用測試腳本自己的 $$，拒絕啟動第二個，以 9 結束）。 ---
pidfile_path="$(_eo_pidfile_path)"
rm -f "$pidfile_path"

_eo_acquire_singleton
if [ -f "$pidfile_path" ] && [ "$(cat "$pidfile_path")" = "$$" ]; then
  pass "_eo_acquire_singleton 在 pidfile 不存在時成功並寫入自己的 pid"
else
  bad "_eo_acquire_singleton 未正確寫入 pidfile"
fi

printf '999999999\n' > "$pidfile_path"
if _eo_acquire_singleton 2>/dev/null; then
  pass "_eo_acquire_singleton 對已死的舊 pid 視為可以接手"
else
  bad "_eo_acquire_singleton 對已死的舊 pid 誤判成仍在跑"
fi

printf '%s\n' "$$" > "$pidfile_path"
( _eo_acquire_singleton ) 2>/dev/null && rc=0 || rc=$?
if [ "$rc" -eq 9 ]; then
  pass "_eo_acquire_singleton 對仍在跑的舊 pid 以 9 結束"
else
  bad "_eo_acquire_singleton 對仍在跑的舊 pid 得到 $rc，預期 9"
fi
rm -f "$pidfile_path"

# --- Critical 3／High 7（下）：INT／TERM 必須真的能停掉常駐迴圈，
# 而且要連同背景子行程自己起的孫行程一起收掉，不留孤兒。不起真正的
# main()（那需要 herdr 樁跑低頻掃描），只驗證訊號處理與子行程清理本
# 身：把本檔 source 進一支獨立腳本、裝上跟 main() 相同的 trap 結
# 構、一個會一直跑的迴圈、以及一個模擬孫行程（herdr 呼叫）的背景
# sleep，用 setsid 把它整個放進一個跟本測試行程無關的新
# session／process group 再啟動——這一步是安全上的必要條件，不是隨
# 意的講究：_eo_cleanup 會對整個 process group 送 TERM，若不隔離，
# 送出的訊號會波及啟動這份測試套件的行程本身；已在獨立的重現腳本裡
# 用 `ps` 核對過 setsid 之後的 pgid 確實與外層測試行程不同、送出
# TERM 後外層行程確實不受影響，才把這個手法帶進正式測試。 ---
sig_test_dir="$T/sig-test"
mkdir -p "$sig_test_dir"
sig_test_script="$sig_test_dir/run.sh"
cat > "$sig_test_script" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$\$" > "$sig_test_dir/main.pid"
EO_GENERATOR_NO_MAIN=1 source "$SCRIPTS/event-generator.sh"
trap '_eo_cleanup' EXIT
trap '_eo_signal_exit' INT TERM
( sleep 300 ) &
printf '%s\n' "\$!" > "$sig_test_dir/grandchild.pid"
while true; do sleep 1; done
EOF
chmod +x "$sig_test_script"
sig_test_launcher="$sig_test_dir/launch.sh"
cat > "$sig_test_launcher" <<EOF
#!/usr/bin/env bash
setsid bash "$sig_test_script" </dev/null >"$sig_test_dir/out.log" 2>&1 &
disown
EOF
chmod +x "$sig_test_launcher"
"$sig_test_launcher"
sleep 0.6
sig_test_pid="$(cat "$sig_test_dir/main.pid" 2>/dev/null || true)"
sig_test_grandchild_pid="$(cat "$sig_test_dir/grandchild.pid" 2>/dev/null || true)"
if [ -n "$sig_test_pid" ]; then
  kill -TERM "$sig_test_pid"
  sleep 1.5
  main_dead=1
  kill -0 "$sig_test_pid" 2>/dev/null && main_dead=0
  grandchild_dead=1
  [ -n "$sig_test_grandchild_pid" ] && kill -0 "$sig_test_grandchild_pid" 2>/dev/null && grandchild_dead=0
  if [ "$main_dead" -eq 1 ] && [ "$grandchild_dead" -eq 1 ]; then
    pass "SIGTERM 停掉常駐迴圈，並連同其背景子行程自己起的孫行程一起收掉（Critical 3／High 7 回歸測試）"
  else
    bad "SIGTERM 後仍有殘留：main 存活=$([ "$main_dead" -eq 1 ] && echo no || echo yes)，grandchild 存活=$([ "$grandchild_dead" -eq 1 ] && echo no || echo yes)"
    kill -9 "$sig_test_pid" "$sig_test_grandchild_pid" 2>/dev/null || true
  fi
else
  bad "SIGTERM 回歸測試未能取得受測行程的 pid，測試環境本身有問題"
fi

# --- 新增：eo_state_remove_phase（狀態記錄的移除能力）。共用
# eo_state_set 同一把鎖檔，見 common.sh 的實作與註解。 ---
eo_state_set 112 pane_id '"pane_112"'
eo_state_remove_phase 112
if eo_state_phases | rg -qx '112'; then
  bad "eo_state_remove_phase 之後 112 仍出現在 eo_state_phases 的結果裡"
else
  pass "eo_state_remove_phase 移除後該 phase 不再出現在列舉結果中"
fi

if eo_state_remove_phase 999 2>/dev/null; then
  pass "eo_state_remove_phase 對不存在的 phase 是無操作，不報錯"
else
  bad "eo_state_remove_phase 對不存在的 phase 意外失敗"
fi

export PATH="$saved_path"

# ===== 新增：close-phase.sh 三道守衛全過、成功關閉 tab 之後呼叫
# eo_state_remove_phase 移除狀態記錄 =====
# 先前任務三的測試只涵蓋三道守衛各自擋下的失敗路徑，從未驗證過真正
# 成功的那條路徑——這裡順便補上這個既有缺口，而不只是驗證新加的移
# 除呼叫，否則新行為會是全案第一段完全沒有測試觸及的成功路徑。
eo_state_set 113 tab_id '"tab_113"'
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "tab list") printf '{"result":{"tabs":[{"tab_id":"tab_113"}]}}'; exit 0 ;;
  "tab close") printf '{"result":{"ok":true}}'; exit 0 ;;
esac
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
export PATH="$STUB_BIN:$saved_path"
assert_herdr_stub_only "$PATH" "$STUB_BIN"
if HERDR_TAB_ID=tab_orchestrator bash "$SCRIPTS/close-phase.sh" 113; then
  pass "close-phase 三道守衛全過時成功關閉 tab"
else
  bad "close-phase 三道守衛全過時仍然失敗"
fi
if eo_state_phases | rg -qx '113'; then
  bad "close-phase 成功關閉後，phase 113 仍留在狀態檔裡"
else
  pass "close-phase 成功關閉後，eo_state_remove_phase 移除了該筆記錄"
fi
export PATH="$saved_path"

# 全案性的測試要求：呼叫端用錯（結束碼 2）。event-generator.sh 不接
# 受任何參數，帶了參數就是呼叫端用錯；這條檢查在 eo_require_herdr_env
# 之後、main（含它的常駐迴圈）之前就先結束，不需要 herdr 樁、也不會
# 讓測試卡進常駐迴圈。
#
# Medium 11（修正輪次 2）：這條原本在還原後的真實 PATH 上執行，
# herdr 解析到真實二進位，安全性完全靠「參數檢查排在 main 之前」這
# 個順序——一旦有人把參數解析改成吃選項、或把檢查移進 main，這條測
# 試就會在測試套件裡起一支對真實 herdr session 動手的常駐產生器。
# 這裡改成掛上樁 PATH：樁本身若被呼叫就寫一個可辨識的標記檔並以非
# 零結束，讓「herdr 真的被呼叫過」這件事本身可以被斷言，不只是依賴
# 結束碼恰好對；套件開頭也已明確 export HERDR_ENV=1，不再依賴執行
# 這份測試的終端機本身剛好是 herdr 管理的環境。
cat > "$STUB_BIN/herdr" <<STUB
#!/usr/bin/env bash
printf 'unexpected herdr invocation: %s\n' "\$*" > "$T/event-generator-herdr-invoked"
exit 9
STUB
chmod +x "$STUB_BIN/herdr"
export PATH="$STUB_BIN:$saved_path"
assert_herdr_stub_only "$PATH" "$STUB_BIN"
rm -f "$T/event-generator-herdr-invoked"
( bash "$SCRIPTS/event-generator.sh" unexpected-arg ) >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$T/event-generator-herdr-invoked" ]; then
  pass "event-generator 帶任何參數時以 2 結束，且不曾呼叫 herdr"
else
  bad "event-generator 帶參數時結束碼為 $rc，herdr 是否被呼叫過＝$([ -e "$T/event-generator-herdr-invoked" ] && echo yes || echo no)"
fi
export PATH="$saved_path"

exit "$fail"
