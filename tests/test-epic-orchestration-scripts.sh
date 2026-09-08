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

exit "$fail"
