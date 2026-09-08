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
export PATH="$saved_path"

exit "$fail"
