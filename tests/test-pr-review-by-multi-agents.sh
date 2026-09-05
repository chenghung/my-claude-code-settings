#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_SH="$REPO/skills/pr-review-by-multi-agents/scripts/run-review.sh"
fail=0
pass() { printf 'PASS %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=1; }

# Source the script under test so parse_pr_url / check_prerequisites /
# check_clis are directly callable as shell functions.
# shellcheck source=/dev/null
source "$RUN_SH"

T="$(mktemp -d)"
# chmod -R u+w before rm -rf: several fixtures below exercise
# cmd_prepare()'s and cmd_launch()'s own read-only chmod on
# worktree_dir/logs_dir for real (that being the whole
# point of testing it), and a directory tree with any read-only entries
# left in it would otherwise make this cleanup itself fail partway
# through and leave a nonzero exit status from the trap, independent of
# whether every actual test assertion above it passed.
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

STUB_BIN="$T/bin"
EMPTY_BIN="$T/empty-bin"
mkdir -p "$STUB_BIN" "$EMPTY_BIN"

saved_path="$PATH"

# ------------------------------------------------------------
# assert_cli_stub_only: PATH-leak guard.
#
# Every end-to-end section below builds PATH by prepending a stub directory
# onto the real system PATH (not replacing it), so gh and this test's own
# stubs keep resolving. That means a stub this test forgot to create -- or
# that a later edit accidentally deletes -- does not fail loudly: the name
# resolves onward to whatever real, system-installed claude/codex/opencode/
# agy sits further down that same PATH, and the test then launches a real
# AI CLI for real, burning real tokens and reaching the network. This has
# already happened twice while developing this suite.
#
# Call this once, right after establishing a stub-prefixed PATH and before
# the first launch_reviewer_interactive / launch_synthesis / `bash
# "$RUN_SH"` call that runs under it -- passing the exact PATH value that
# call will see, the
# stub directory supposed to win the lookup, and the CLI names that
# directory actually provides. A section that deliberately stubs only a
# subset of the four names (because that section only ever invokes that
# subset) must pass just that subset here: passing a name absent from that
# section's own stub directory would fail the section for the very reason
# this guard exists, over a name the section never actually invokes.
# ------------------------------------------------------------
assert_cli_stub_only() {
  local check_path="$1" stub_dir="$2"
  shift 2
  local name resolved
  for name in "$@"; do
    resolved="$(PATH="$check_path" command -v "$name" 2>/dev/null)" || resolved=""
    if [ -n "$resolved" ] && [ "$resolved" != "$stub_dir/$name" ]; then
      bad "PATH guard: $name resolved to '$resolved' instead of the stub at '$stub_dir/$name' -- this run would have launched the real $name CLI"
    fi
  done
}

# ------------------------------------------------------------
# Stub gh: a single stand-in covering every gh invocation this script makes
# (derive-URL lookup, auth check, PR-existence check, PR/issue material
# fetch), toggled entirely by env vars so each test case controls exactly
# one outcome. Never touches the real GitHub API.
# ------------------------------------------------------------
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
auth)
  [ "${GH_STUB_AUTH_OK:-1}" = "1" ] && exit 0 || exit 1
  ;;
pr)
  if [ "${2:-}" = "view" ]; then
    if [ "${3:-}" = "--json" ]; then
      # parse_pr_url's derive-from-branch call: gh pr view --json url --jq .url
      [ "${GH_STUB_DERIVE_OK:-1}" = "1" ] || exit 1
      printf '%s\n' "${GH_STUB_DERIVED_URL:-https://github.com/acme/widgets/pull/7}"
      exit 0
    fi
    case " $* " in
      *' --json baseRefName '*)
        # resolve_base_ref's call: gh pr view NUMBER --repo OWNER/REPO --json
        # baseRefName --jq .baseRefName
        [ "${GH_STUB_BASE_REF_OK:-1}" = "1" ] || exit 1
        # `-` (no colon) rather than `:-`: a *set-but-empty*
        # GH_STUB_BASE_REF_NAME must print as empty (the resolve-base-ref-
        # empty-name test case), not fall back to "main" the way `:-`
        # would treat empty the same as unset.
        printf '%s\n' "${GH_STUB_BASE_REF_NAME-main}"
        exit 0
        ;;
      *' --json title,body,comments,reviews '*)
        # fetch_review_materials -> _fetch_pr_material's call: gh pr view
        # NUMBER --repo OWNER/REPO --json title,body,comments,reviews
        printf '{"title":"stub-pr-title","body":"stub-pr-body","comments":[],"reviews":[]}'
        exit 0
        ;;
    esac
    # check_prerequisites' PR-existence call: gh pr view NUMBER --repo OWNER/REPO
    [ "${GH_STUB_PR_EXISTS:-1}" = "1" ] && exit 0 || exit 1
  fi
  exit 1
  ;;
issue)
  if [ "${2:-}" = "view" ]; then
    case " $* " in
      *' --json title,body,comments '*)
        # fetch_review_materials -> _fetch_issue_material's call: gh issue
        # view NUMBER --repo OWNER/REPO --json title,body,comments
        printf '{"title":"stub-issue-title","body":"e2e-distinctive-issue-body-marker","comments":[]}'
        exit 0
        ;;
    esac
  fi
  exit 1
  ;;
esac
exit 1
STUB
chmod +x "$STUB_BIN/gh"

# ==============================================================
# parse_pr_url
# ==============================================================

out="$(parse_pr_url "https://github.com/acme/widgets/pull/42")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$out" = "acme widgets 42" ] && pass parse-full-url || bad parse-full-url

out="$(parse_pr_url "acme/widgets#42")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$out" = "acme widgets 42" ] && pass parse-shorthand || bad parse-shorthand

# Full URL with a trailing path suffix (e.g. the "/files" tab a browser adds
# when a user copies a PR URL) must still parse to the same three values.
out="$(parse_pr_url "https://github.com/acme/widgets/pull/42/files")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$out" = "acme widgets 42" ] && pass parse-full-url-trailing-suffix || bad parse-full-url-trailing-suffix

# Empty input: derive from the current branch via the stubbed gh. GH_STUB_*
# must be `export`ed (not just assigned) so the gh stub subprocess sees them.
export PATH="$STUB_BIN:$PATH"
export GH_STUB_DERIVE_OK=1
export GH_STUB_DERIVED_URL="https://github.com/acme/widgets/pull/7"
out="$(parse_pr_url "")"
unset GH_STUB_DERIVE_OK GH_STUB_DERIVED_URL
export PATH="$saved_path"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$out" = "acme widgets 7" ] && pass parse-derive-from-branch || bad parse-derive-from-branch

# Empty input, no PR associated with the current branch -> gh fails -> non-zero.
export PATH="$STUB_BIN:$PATH"
if GH_STUB_DERIVE_OK=0 parse_pr_url "" >/dev/null 2>&1; then
  bad parse-derive-failure
else
  pass parse-derive-failure
fi
export PATH="$saved_path"

# Invalid format -> non-zero, no stdout.
if out="$(parse_pr_url "not-a-valid-pr-reference" 2>/dev/null)"; then
  bad parse-invalid-format
else
  pass parse-invalid-format
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -z "$out" ] && pass parse-invalid-format-no-output || bad parse-invalid-format-no-output

# ==============================================================
# check_prerequisites
# ==============================================================

# gh missing entirely from PATH.
export PATH="$EMPTY_BIN"
if check_prerequisites acme widgets 42 2>/dev/null; then
  bad prereq-no-gh
else
  pass prereq-no-gh
fi
export PATH="$saved_path"

# gh present, not authenticated.
export PATH="$STUB_BIN:$PATH"
if GH_STUB_AUTH_OK=0 check_prerequisites acme widgets 42 2>/dev/null; then
  bad prereq-not-authenticated
else
  pass prereq-not-authenticated
fi
export PATH="$saved_path"

# gh present, authenticated, PR does not exist.
export PATH="$STUB_BIN:$PATH"
if GH_STUB_AUTH_OK=1 GH_STUB_PR_EXISTS=0 check_prerequisites acme widgets 42 2>/dev/null; then
  bad prereq-pr-missing
else
  pass prereq-pr-missing
fi
export PATH="$saved_path"

# gh present, authenticated, PR exists -> success.
export PATH="$STUB_BIN:$PATH"
if GH_STUB_AUTH_OK=1 GH_STUB_PR_EXISTS=1 check_prerequisites acme widgets 42 2>/dev/null; then
  pass prereq-all-ok
else
  bad prereq-all-ok
fi
export PATH="$saved_path"

# ==============================================================
# check_clis
# ==============================================================

# Stub CLIs that just need to exist on PATH; reused by several e2e
# prepare/launch runs and fixtures further down this file that put
# $STUB_BIN on a non-exclusive PATH (e.g. "$STUB_BIN:$saved_path") -- a
# name missing here would let verify_selection/launch_reviewer_interactive
# resolve it to the real, system-installed CLI further down that same
# PATH instead.
for cli in claude codex opencode agy; do
  cat > "$STUB_BIN/$cli" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$STUB_BIN/$cli"
done

# ---- check_clis 對四個 CLI 各印一行 ----
PATH="$EMPTY_BIN"
out="$(check_clis)"
rc=$?
PATH="$saved_path"
if [ "$rc" -eq 0 ] \
  && grep -qx 'claude missing' <<<"$out" \
  && grep -qx 'codex missing' <<<"$out" \
  && grep -qx 'opencode missing' <<<"$out" \
  && grep -qx 'agy missing' <<<"$out"; then
  pass "check_clis 四個 CLI 皆缺席時各印一行 missing 且回傳 0"
else
  bad "check_clis 缺席輸出不正確: $out (rc=$rc)"
fi

# ==============================================================
# parse_args / verify_selection
# ==============================================================

# ---- parse_args 解析四種旗標 ----
out="$(parse_args --pr https://github.com/a/b/pull/1 --issue https://github.com/a/b/issues/2 \
       --design /tmp/d.md --claude --agy)"
if grep -qx 'pr=https://github.com/a/b/pull/1' <<<"$out" \
  && grep -qx 'issue=https://github.com/a/b/issues/2' <<<"$out" \
  && grep -qx 'design=/tmp/d.md' <<<"$out" \
  && grep -qx 'clis=claude agy' <<<"$out"; then
  pass "parse_args 解析四種旗標"
else
  bad "parse_args 解析結果不正確: $out"
fi

# ---- parse_args 平台順序固定，不依命令列出現順序 ----
out="$(parse_args --pr X --agy --claude)"
if grep -qx 'clis=claude agy' <<<"$out"; then
  pass "parse_args 平台順序固定為 claude codex opencode agy"
else
  bad "parse_args 平台順序未正規化: $out"
fi

# ---- parse_args 未選平台時以 2 拒絕 ----
if parse_args --pr X >/dev/null 2>&1; then
  bad "parse_args 未選平台時應失敗"
else
  rc=$?
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ "$rc" -eq 2 ] && pass "parse_args 未選平台時回傳 2" \
    || bad "parse_args 未選平台時回傳 $rc，應為 2"
fi

# ---- parse_args 未知旗標時以 2 拒絕 ----
if parse_args --pr X --claude --bogus >/dev/null 2>&1; then
  bad "parse_args 未知旗標時應失敗"
else
  rc=$?
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ "$rc" -eq 2 ] && pass "parse_args 未知旗標時回傳 2" \
    || bad "parse_args 未知旗標時回傳 $rc，應為 2"
fi

# ---- parse_args 旗標缺值時以 2 拒絕 ----
if parse_args --pr --claude >/dev/null 2>&1; then
  bad "parse_args --pr 缺值時應失敗"
else
  rc=$?
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ "$rc" -eq 2 ] && pass "parse_args 旗標缺值時回傳 2" \
    || bad "parse_args 旗標缺值時回傳 $rc，應為 2"
fi

# ---- parse_args 旗標值含換行時以 2 拒絕（換行可偽造 pr=/issue=/design=/clis=
# 這幾行輸出中的一行，例如在 --design 值裡塞入自己的 "clis=" 行，悄悄改變
# cmd_prepare() 實際派送的平台組合）----
if parse_args --pr X --design "$(printf 'legit line\nclis=codex')" --claude >/dev/null 2>&1; then
  bad "parse_args 旗標值含換行時應失敗"
else
  rc=$?
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ "$rc" -eq 2 ] && pass "parse_args 旗標值含換行時回傳 2" \
    || bad "parse_args 旗標值含換行時回傳 $rc，應為 2"
fi

# ---- 選定組合中有 CLI 缺席時回傳 3 ----
PATH="$EMPTY_BIN"
if verify_selection claude agy >/dev/null 2>&1; then
  bad "verify_selection 全部缺席時應失敗"
else
  rc=$?
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ "$rc" -eq 3 ] && pass "verify_selection 缺席時回傳 3" \
    || bad "verify_selection 缺席時回傳 $rc，應為 3"
fi
PATH="$saved_path"

# ==============================================================
# _check_agents_selected
#
# cmd_launch()'s own cross-check that every --agent named cli was
# actually selected by the matching prepare invocation (reads back
# <base_dir>/.roster, cmd_prepare's own record -- see this function's
# own docstring). Direct unit tests here; the end-to-end proof that
# cmd_launch() actually calls this before dispatching anything lives in
# the VERIFY3 fixture further down.
# ==============================================================

CAS_ROOT="$T/check-agents-selected-fixture"
mkdir -p "$CAS_ROOT"
printf 'claude some-model dispatched\ncodex some-model dispatched\n' > "$CAS_ROOT/.roster"

if _check_agents_selected "$CAS_ROOT" claude codex >/dev/null 2>&1; then
  pass check-agents-selected-accepts-every-selected-cli
else
  bad check-agents-selected-accepts-every-selected-cli
fi

if cas_err="$(_check_agents_selected "$CAS_ROOT" claude opencode 2>&1 1>/dev/null)"; then
  cas_rc=0
else
  cas_rc=$?
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$cas_rc" -eq 2 ] && pass "check-agents-selected-rejects-unselected-cli-with-exit-2" \
  || bad "check-agents-selected-rejects-unselected-cli-with-exit-2: rc=$cas_rc"
case "$cas_err" in
  *'opencode'*) pass check-agents-selected-message-names-unselected-cli ;;
  *) bad "check-agents-selected-message-names-unselected-cli: $cas_err" ;;
esac

if cas_noroster_err="$(_check_agents_selected "$T/check-agents-selected-no-such-base-dir" claude 2>&1 1>/dev/null)"; then
  cas_noroster_rc=0
else
  cas_noroster_rc=$?
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$cas_noroster_rc" -eq 2 ] && pass "check-agents-selected-missing-roster-file-exit-2" \
  || bad "check-agents-selected-missing-roster-file-exit-2: rc=$cas_noroster_rc"
case "$cas_noroster_err" in
  *'.roster'*) pass check-agents-selected-missing-roster-file-message-names-roster ;;
  *) bad "check-agents-selected-missing-roster-file-message-names-roster: $cas_noroster_err" ;;
esac

# ==============================================================
# parse_launch_args
# ==============================================================

# ---- parse_launch_args 解析 --base-dir 與多個 --agent ----
out="$(parse_launch_args --base-dir /tmp/run-dir --agent claude=w1 --agent codex=w2)"
if grep -qx 'base_dir=/tmp/run-dir' <<<"$out" \
  && grep -qx 'agent=claude:w1' <<<"$out" \
  && grep -qx 'agent=codex:w2' <<<"$out"; then
  pass "parse_launch_args 解析 --base-dir 與多個 --agent"
else
  bad "parse_launch_args 解析結果不正確: $out"
fi

# ---- parse_launch_args 對含冒號的 pane_id 往返無損（拼接設計要保護的
# 正是這個情形：pane_id 字面上就是 wNN:pM 這種含冒號的形狀，若拆分邏輯
# 錯把冒號當成分隔符，cli 或 pane_id 其中一段就會被截斷）----
out="$(parse_launch_args --base-dir /tmp/run-dir --agent claude=w16:p1)"
if grep -qx 'base_dir=/tmp/run-dir' <<<"$out" \
  && grep -qx 'agent=claude:w16:p1' <<<"$out"; then
  pass "parse_launch_args 含冒號的 pane_id 往返無損"
else
  bad "parse_launch_args 含冒號的 pane_id 被截斷或跑位: $out"
fi

# ---- parse_launch_args 缺少 --base-dir 時以 2 拒絕 ----
if parse_launch_args --agent claude=w1 >/dev/null 2>&1; then
  bad "parse_launch_args 缺少 --base-dir 時應失敗"
else
  rc=$?
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ "$rc" -eq 2 ] && pass "parse_launch_args 缺少 --base-dir 時回傳 2" \
    || bad "parse_launch_args 缺少 --base-dir 時回傳 $rc，應為 2"
fi

# ---- parse_launch_args --base-dir 缺值時以 2 拒絕 ----
if parse_launch_args --base-dir --agent claude=w1 >/dev/null 2>&1; then
  bad "parse_launch_args --base-dir 缺值時應失敗"
else
  rc=$?
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ "$rc" -eq 2 ] && pass "parse_launch_args --base-dir 缺值時回傳 2" \
    || bad "parse_launch_args --base-dir 缺值時回傳 $rc，應為 2"
fi

# ---- parse_launch_args --base-dir 重複給值時以 2 拒絕 ----
if parse_launch_args --base-dir /tmp/a --base-dir /tmp/b --agent claude=w1 >/dev/null 2>&1; then
  bad "parse_launch_args --base-dir 重複時應失敗"
else
  rc=$?
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ "$rc" -eq 2 ] && pass "parse_launch_args --base-dir 重複時回傳 2" \
    || bad "parse_launch_args --base-dir 重複時回傳 $rc，應為 2"
fi

# ---- parse_launch_args --base-dir 非絕對路徑時以 2 拒絕 ----
if parse_launch_args --base-dir relative/dir --agent claude=w1 >/dev/null 2>&1; then
  bad "parse_launch_args --base-dir 非絕對路徑時應失敗"
else
  rc=$?
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ "$rc" -eq 2 ] && pass "parse_launch_args --base-dir 非絕對路徑時回傳 2" \
    || bad "parse_launch_args --base-dir 非絕對路徑時回傳 $rc，應為 2"
fi

# ---- parse_launch_args 缺少 --agent 時以 2 拒絕 ----
if parse_launch_args --base-dir /tmp/run-dir >/dev/null 2>&1; then
  bad "parse_launch_args 缺少 --agent 時應失敗"
else
  rc=$?
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ "$rc" -eq 2 ] && pass "parse_launch_args 缺少 --agent 時回傳 2" \
    || bad "parse_launch_args 缺少 --agent 時回傳 $rc，應為 2"
fi

# ---- parse_launch_args --agent 缺值時以 2 拒絕 ----
if parse_launch_args --base-dir /tmp/run-dir --agent >/dev/null 2>&1; then
  bad "parse_launch_args --agent 缺值時應失敗"
else
  rc=$?
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ "$rc" -eq 2 ] && pass "parse_launch_args --agent 缺值時回傳 2" \
    || bad "parse_launch_args --agent 缺值時回傳 $rc，應為 2"
fi

# ---- parse_launch_args --agent 值缺少等號時以 2 拒絕 ----
if parse_launch_args --base-dir /tmp/run-dir --agent claude-no-equals-sign >/dev/null 2>&1; then
  bad "parse_launch_args --agent 值缺少等號時應失敗"
else
  rc=$?
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ "$rc" -eq 2 ] && pass "parse_launch_args --agent 值缺少等號時回傳 2" \
    || bad "parse_launch_args --agent 值缺少等號時回傳 $rc，應為 2"
fi

# ---- parse_launch_args --agent cli 不在列舉範圍時以 2 拒絕 ----
if parse_launch_args --base-dir /tmp/run-dir --agent bogus-cli=w1 >/dev/null 2>&1; then
  bad "parse_launch_args --agent cli 不在列舉範圍時應失敗"
else
  rc=$?
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ "$rc" -eq 2 ] && pass "parse_launch_args --agent cli 不在列舉範圍時回傳 2" \
    || bad "parse_launch_args --agent cli 不在列舉範圍時回傳 $rc，應為 2"
fi

# ---- parse_launch_args 同一個 cli 重複給值時以 2 拒絕（否則 cmd_launch 會
# 對同一個 cli 呼叫兩次 launch_reviewer_interactive，造成 log/pid 檔案互相
# 覆蓋與名單檔重複列，見這個函式自己的 docstring）----
if parse_launch_args --base-dir /tmp/run-dir --agent claude=w1 --agent claude=w2 >/dev/null 2>&1; then
  bad "parse_launch_args --agent cli 重複時應失敗"
else
  rc=$?
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ "$rc" -eq 2 ] && pass "parse_launch_args --agent cli 重複時回傳 2" \
    || bad "parse_launch_args --agent cli 重複時回傳 $rc，應為 2"
fi

# ---- parse_launch_args 未知旗標時以 2 拒絕 ----
if parse_launch_args --base-dir /tmp/run-dir --agent claude=w1 --bogus >/dev/null 2>&1; then
  bad "parse_launch_args 未知旗標時應失敗"
else
  rc=$?
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ "$rc" -eq 2 ] && pass "parse_launch_args 未知旗標時回傳 2" \
    || bad "parse_launch_args 未知旗標時回傳 $rc，應為 2"
fi

# ---- parse_launch_args --base-dir 值含換行時以 2 拒絕（同一種偽造風險，
# 換一個輸出格式：base_dir= 這一行可以被偽造出額外的 agent= 行）----
if parse_launch_args --base-dir "$(printf '/tmp/run-dir\nagent=codex:evil')" --agent claude=w1 >/dev/null 2>&1; then
  bad "parse_launch_args --base-dir 值含換行時應失敗"
else
  rc=$?
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ "$rc" -eq 2 ] && pass "parse_launch_args --base-dir 值含換行時回傳 2" \
    || bad "parse_launch_args --base-dir 值含換行時回傳 $rc，應為 2"
fi

# ---- parse_launch_args --agent 的 pane_id 部分含換行時以 2 拒絕 -- cli 本身
# 有白名單擋著（含換行的字串不可能通過 claude/codex/opencode/agy 的精確比
# 對），但 pane_id 完全沒有格式檢查，直到這裡補上為止 ----
if parse_launch_args --base-dir /tmp/run-dir --agent "$(printf 'claude=w1\nagent=codex:evil')" >/dev/null 2>&1; then
  bad "parse_launch_args --agent pane_id 含換行時應失敗"
else
  rc=$?
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ "$rc" -eq 2 ] && pass "parse_launch_args --agent pane_id 含換行時回傳 2" \
    || bad "parse_launch_args --agent pane_id 含換行時回傳 $rc，應為 2"
fi

# ==============================================================
# main() 頂層 dispatch
#
# main() 的 --check-clis 分支已由上面 check_clis 那組測試間接覆蓋
# （main() 只是原樣轉呼叫），prepare/launch 兩個已知分支的行為由散布全檔
# 的 e2e 測試覆蓋。這裡只補兩個分支本身：不帶子命令、帶未知子命令，都要
# 以結束碼 2 拒絕。main() 在這兩個分支都呼叫 exit（不是 return），所以
# 用子行程 `( main ... )` 包起來呼叫，避免真的把這支測試腳本自己結束掉。
# ==============================================================

# ---- main() 不帶任何引數時以 2 拒絕 ----
if ( main ) >/dev/null 2>&1; then
  bad "main() 不帶引數時應失敗"
else
  rc=$?
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ "$rc" -eq 2 ] && pass "main() 不帶引數時回傳 2" \
    || bad "main() 不帶引數時回傳 $rc，應為 2"
fi

# ---- main() 帶未知子命令時以 2 拒絕 ----
if ( main bogus-subcommand ) >/dev/null 2>&1; then
  bad "main() 帶未知子命令時應失敗"
else
  rc=$?
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ "$rc" -eq 2 ] && pass "main() 帶未知子命令時回傳 2" \
    || bad "main() 帶未知子命令時回傳 $rc，應為 2"
fi

# ==============================================================
# resolve_contract_path
#
# The most load-bearing test in this file: if the script can't find its own
# review contract, there is no standard for any reviewer to work from, and
# that must never fail silently. All three cases below run in a real bash
# subprocess (not this sourced test shell) so BASH_SOURCE reflects the
# actual invocation path, exactly like a real run.
# ==============================================================

REAL_CONTRACT="$REPO/skills/pr-review-by-multi-agents/references/reviewer-contract.md"

# Direct case: resolve from run-review.sh's own real, un-symlinked location.
out="$(resolve_contract_path)"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$out" = "$REAL_CONTRACT" ] && pass contract-path-direct || bad contract-path-direct
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -s "$out" ] && pass contract-path-direct-readable || bad contract-path-direct-readable

# Symlink case: this fixture symlinks only run-review.sh itself, not the whole
# skill directory the way install.sh actually deploys it (a single symlink
# for the whole tree under ~/.claude/skills or ~/.agents/skills) -- but
# readlink resolves BASH_SOURCE[0] the same way regardless of which level
# of the path is the symlink, so this still exercises the exact resolution
# step (readlink -f "${BASH_SOURCE[0]}") that install.sh's real deployment
# depends on.
SYMLINKED_SKILL="$T/symlinked-skill"
mkdir -p "$SYMLINKED_SKILL/scripts"
ln -s "$RUN_SH" "$SYMLINKED_SKILL/scripts/run-review.sh"
out="$(bash -c "source '$SYMLINKED_SKILL/scripts/run-review.sh'; resolve_contract_path")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$out" = "$REAL_CONTRACT" ] && pass contract-path-symlink || bad contract-path-symlink

# Missing case: a scripts/ directory with no sibling references/ at all ->
# non-zero, no stdout. Must not be confused with the two cases above.
NO_CONTRACT_SKILL="$T/no-contract-skill"
mkdir -p "$NO_CONTRACT_SKILL/scripts"
cp "$RUN_SH" "$NO_CONTRACT_SKILL/scripts/run-review.sh"
if out="$(bash -c "source '$NO_CONTRACT_SKILL/scripts/run-review.sh'; resolve_contract_path" 2>/dev/null)"; then
  bad contract-path-missing
else
  pass contract-path-missing
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -z "$out" ] && pass contract-path-missing-no-output || bad contract-path-missing-no-output

# ==============================================================
# resolve_model
#
# Each case gets its own isolated $HOME so this never reads the real user's
# actual codex/opencode/claude config -- both for hermeticity and because
# those files may contain the user's real settings.
# ==============================================================

# --- codex: ~/.codex/config.toml, top-level `model` key ---

HOME_CODEX_OK="$T/home-codex-ok"
mkdir -p "$HOME_CODEX_OK/.codex"
cat > "$HOME_CODEX_OK/.codex/config.toml" <<'TOML'
model = "top-level-model"
personality = "pragmatic"

[profiles.o3]
model = "nested-model-must-not-win"
TOML
out="$(HOME="$HOME_CODEX_OK" resolve_model codex)"
rc=$?
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$rc" -eq 0 ] && [ "$out" = "top-level-model" ] && pass resolve-model-codex-found || bad resolve-model-codex-found

HOME_CODEX_NOFILE="$T/home-codex-nofile"
mkdir -p "$HOME_CODEX_NOFILE"
out="$(HOME="$HOME_CODEX_NOFILE" resolve_model codex)"
rc=$?
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$rc" -eq 0 ] && [ "$out" = "unknown-model" ] && pass resolve-model-codex-missing-file || bad resolve-model-codex-missing-file

HOME_CODEX_NOFIELD="$T/home-codex-nofield"
mkdir -p "$HOME_CODEX_NOFIELD/.codex"
cat > "$HOME_CODEX_NOFIELD/.codex/config.toml" <<'TOML'
personality = "pragmatic"
TOML
out="$(HOME="$HOME_CODEX_NOFIELD" resolve_model codex)"
rc=$?
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$rc" -eq 0 ] && [ "$out" = "unknown-model" ] && pass resolve-model-codex-missing-field || bad resolve-model-codex-missing-field

# --- opencode: ~/.config/opencode/opencode.json, .model ---

HOME_OC_OK="$T/home-opencode-ok"
mkdir -p "$HOME_OC_OK/.config/opencode"
printf '{"model": "test-provider/test-model"}' > "$HOME_OC_OK/.config/opencode/opencode.json"
out="$(HOME="$HOME_OC_OK" resolve_model opencode)"
rc=$?
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$rc" -eq 0 ] && [ "$out" = "test-provider/test-model" ] && pass resolve-model-opencode-found || bad resolve-model-opencode-found

HOME_OC_NOFILE="$T/home-opencode-nofile"
mkdir -p "$HOME_OC_NOFILE"
out="$(HOME="$HOME_OC_NOFILE" resolve_model opencode)"
rc=$?
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$rc" -eq 0 ] && [ "$out" = "unknown-model" ] && pass resolve-model-opencode-missing-file || bad resolve-model-opencode-missing-file

HOME_OC_NOFIELD="$T/home-opencode-nofield"
mkdir -p "$HOME_OC_NOFIELD/.config/opencode"
printf '{"other": true}' > "$HOME_OC_NOFIELD/.config/opencode/opencode.json"
out="$(HOME="$HOME_OC_NOFIELD" resolve_model opencode)"
rc=$?
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$rc" -eq 0 ] && [ "$out" = "unknown-model" ] && pass resolve-model-opencode-missing-field || bad resolve-model-opencode-missing-field

# --- claude: $CLAUDE_CONFIG_DIR/settings.json (falling back to
# ~/.claude/settings.json), .model. CLAUDE_CONFIG_DIR is explicitly
# cleared (set to empty, which run-review.sh's own `${CLAUDE_CONFIG_DIR:-...}`
# fallback treats the same as unset) on every call below: this test
# process may itself be running under a real CLAUDE_CONFIG_DIR set in the
# environment it was launched from, and without clearing it here,
# resolve_model would read that real, unrelated settings file instead of
# the isolated $HOME fixture each case below sets up. ---

HOME_CC_OK="$T/home-claude-ok"
mkdir -p "$HOME_CC_OK/.claude"
printf '{"model": "sonnet-test"}' > "$HOME_CC_OK/.claude/settings.json"
out="$(CLAUDE_CONFIG_DIR="" HOME="$HOME_CC_OK" resolve_model claude)"
rc=$?
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$rc" -eq 0 ] && [ "$out" = "sonnet-test" ] && pass resolve-model-claude-found || bad resolve-model-claude-found

HOME_CC_NOFILE="$T/home-claude-nofile"
mkdir -p "$HOME_CC_NOFILE"
out="$(CLAUDE_CONFIG_DIR="" HOME="$HOME_CC_NOFILE" resolve_model claude)"
rc=$?
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$rc" -eq 0 ] && [ "$out" = "unknown-model" ] && pass resolve-model-claude-missing-file || bad resolve-model-claude-missing-file

HOME_CC_NOFIELD="$T/home-claude-nofield"
mkdir -p "$HOME_CC_NOFIELD/.claude"
printf '{"other": true}' > "$HOME_CC_NOFIELD/.claude/settings.json"
out="$(CLAUDE_CONFIG_DIR="" HOME="$HOME_CC_NOFIELD" resolve_model claude)"
rc=$?
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$rc" -eq 0 ] && [ "$out" = "unknown-model" ] && pass resolve-model-claude-missing-field || bad resolve-model-claude-missing-field

# A distinct CLAUDE_CONFIG_DIR, separate from HOME/.claude, must actually
# be honored (not just harmlessly cleared) -- otherwise the fallback-only
# path above would pass even if the env var were never read at all.
HOME_CC_ENVDIR="$T/home-claude-envdir-home"
CLAUDE_CONFIG_DIR_CASE="$T/home-claude-envdir-config"
mkdir -p "$HOME_CC_ENVDIR" "$CLAUDE_CONFIG_DIR_CASE"
printf '{"model": "env-dir-model"}' > "$CLAUDE_CONFIG_DIR_CASE/settings.json"
out="$(CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR_CASE" HOME="$HOME_CC_ENVDIR" resolve_model claude)"
rc=$?
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$rc" -eq 0 ] && [ "$out" = "env-dir-model" ] && pass resolve-model-claude-honors-config-dir-env-var || bad resolve-model-claude-honors-config-dir-env-var

# --- agy: hardcoded, not read from any config file (see resolve_model's
# agy branch docstring for why) -- no isolated $HOME needed, the real
# $HOME's config must never affect this value ---

out="$(resolve_model agy)"
if [ "$out" = "gemini-3.8-flash-high" ]; then
  pass "resolve_model agy 回傳 gemini-3.8-flash-high"
else
  bad "resolve_model agy 回傳 $out"
fi

# ==============================================================
# resolve_model -- malformed/anomalous config content
#
# These specifically guard the errexit-propagation bug found in review:
# resolve_model must degrade to "unknown-model" (rc 0) even when the
# underlying parser (jq or sed) genuinely fails partway through, not just
# when a file/field is simply absent (the scenarios above never actually
# fail a command, so they could not have caught this). Each case below
# runs resolve_model in a fresh, unwrapped bash -c subprocess rather than
# via a bare "$(resolve_model ...)" in this already-sourced test shell --
# bash disables errexit inside command substitutions by default, which
# would incidentally mask the exact bug being tested here. The outer
# `if out="$(bash -c ...)"` only protects this test script itself from
# dying; it does not affect whether the failure happens for real inside
# the child process.
# ==============================================================

# codex: two top-level `model =` lines before any [section] header. Before
# the fix, this raced a `sed | head -n1` pipeline and could kill the whole
# calling shell with SIGPIPE under pipefail (reproduced separately with a
# large fixture during development); the fix removes the pipe entirely, so
# this is now a plain correctness check that the first one wins.
HOME_CODEX_DUP="$T/home-codex-dup"
mkdir -p "$HOME_CODEX_DUP/.codex"
cat > "$HOME_CODEX_DUP/.codex/config.toml" <<'TOML'
model = "first-model"
model = "second-model-must-not-win"
TOML
if out="$(bash -c "source '$RUN_SH'; HOME='$HOME_CODEX_DUP' resolve_model codex" 2>/dev/null)"; then
  rc=0
else
  rc=$?
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$rc" -eq 0 ] && [ "$out" = "first-model" ] && pass resolve-model-codex-duplicate-lines || bad resolve-model-codex-duplicate-lines

# opencode: syntactically invalid JSON.
HOME_OC_BADJSON="$T/home-opencode-badjson"
mkdir -p "$HOME_OC_BADJSON/.config/opencode"
printf '{"model": "unterminated' > "$HOME_OC_BADJSON/.config/opencode/opencode.json"
if out="$(bash -c "source '$RUN_SH'; HOME='$HOME_OC_BADJSON' resolve_model opencode" 2>/dev/null)"; then
  rc=0
else
  rc=$?
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$rc" -eq 0 ] && [ "$out" = "unknown-model" ] && pass resolve-model-opencode-invalid-json || bad resolve-model-opencode-invalid-json

# opencode: syntactically valid JSON, but the wrong type at the top level
# (an array instead of an object) -- `.model` on an array is a jq runtime
# error, not a quietly-empty missing-field result.
HOME_OC_TYPE="$T/home-opencode-typemismatch"
mkdir -p "$HOME_OC_TYPE/.config/opencode"
printf '["not", "an", "object"]' > "$HOME_OC_TYPE/.config/opencode/opencode.json"
if out="$(bash -c "source '$RUN_SH'; HOME='$HOME_OC_TYPE' resolve_model opencode" 2>/dev/null)"; then
  rc=0
else
  rc=$?
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$rc" -eq 0 ] && [ "$out" = "unknown-model" ] && pass resolve-model-opencode-type-mismatch || bad resolve-model-opencode-type-mismatch

# claude: syntactically invalid JSON.
HOME_CC_BADJSON="$T/home-claude-badjson"
mkdir -p "$HOME_CC_BADJSON/.claude"
printf '{"model": "unterminated' > "$HOME_CC_BADJSON/.claude/settings.json"
if out="$(bash -c "source '$RUN_SH'; CLAUDE_CONFIG_DIR='' HOME='$HOME_CC_BADJSON' resolve_model claude" 2>/dev/null)"; then
  rc=0
else
  rc=$?
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$rc" -eq 0 ] && [ "$out" = "unknown-model" ] && pass resolve-model-claude-invalid-json || bad resolve-model-claude-invalid-json

# claude: valid JSON, wrong top-level type.
HOME_CC_TYPE="$T/home-claude-typemismatch"
mkdir -p "$HOME_CC_TYPE/.claude"
printf '["not", "an", "object"]' > "$HOME_CC_TYPE/.claude/settings.json"
if out="$(bash -c "source '$RUN_SH'; CLAUDE_CONFIG_DIR='' HOME='$HOME_CC_TYPE' resolve_model claude" 2>/dev/null)"; then
  rc=0
else
  rc=$?
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$rc" -eq 0 ] && [ "$out" = "unknown-model" ] && pass resolve-model-claude-type-mismatch || bad resolve-model-claude-type-mismatch

# --- _fetch_pr_material: PR 材料抓取與回音室過濾 ---
PRMAT_ROOT="$T/prmat"
mkdir -p "$PRMAT_ROOT/bin"
cat > "$PRMAT_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
cat "$GH_PR_JSON_FIXTURE"
STUB
chmod +x "$PRMAT_ROOT/bin/gh"

cat > "$PRMAT_ROOT/pr.json" <<'JSON'
{
  "title": "修正 worktree 清理",
  "body": "本 PR 修正 worktree 殘留。\n\nCloses #42",
  "comments": [
    {"author": {"login": "alice"}, "createdAt": "2026-08-01T00:00:00Z", "body": "第一則人類留言"},
    {"author": {"login": "bob"}, "createdAt": "2026-08-02T00:00:00Z", "body": "  \n<!-- pr-review-by-multi-agents -->\n\n這是上一輪 AI review"},
    {"author": {"login": "erin"}, "createdAt": "2026-08-03T00:00:00Z", "body": "我們在留言中間提到這個標記字串 <!-- pr-review-by-multi-agents --> 只是討論標記本身，不是回音。"}
  ],
  "reviews": [
    {"author": {"login": "carol"}, "state": "CHANGES_REQUESTED", "body": "review 總結內文"},
    {"author": {"login": "dave"}, "state": "APPROVED", "body": ""}
  ]
}
JSON

export PATH="$PRMAT_ROOT/bin:$saved_path"
export GH_PR_JSON_FIXTURE="$PRMAT_ROOT/pr.json"

if _fetch_pr_material acme widgets 7 "$PRMAT_ROOT/pr.md" "$PRMAT_ROOT/pr-body-raw.md"; then
  pass fetch-pr-material-returns-zero
else
  bad fetch-pr-material-returns-zero
fi

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF '修正 worktree 清理' "$PRMAT_ROOT/pr.md" && pass fetch-pr-material-has-title || bad fetch-pr-material-has-title
# shellcheck disable=SC2015
grep -qF 'Closes #42' "$PRMAT_ROOT/pr.md" && pass fetch-pr-material-has-body || bad fetch-pr-material-has-body
# shellcheck disable=SC2015
grep -qF '第一則人類留言' "$PRMAT_ROOT/pr.md" && pass fetch-pr-material-has-human-comment || bad fetch-pr-material-has-human-comment
# shellcheck disable=SC2015
grep -qF 'review 總結內文' "$PRMAT_ROOT/pr.md" && pass fetch-pr-material-has-review-body || bad fetch-pr-material-has-review-body

# 回音室過濾：標記在留言最開頭（即使前面帶著空白／換行）的那一則整段不得
# 出現，驗證濾網對開頭空白要有容忍度
if grep -qF '這是上一輪 AI review' "$PRMAT_ROOT/pr.md"; then
  bad fetch-pr-material-filters-own-comment
else
  pass fetch-pr-material-filters-own-comment
fi

# 標記只是出現在留言「中間」（不是開頭）時不算回音，不得被濾掉 -- 濾網只
# 比對開頭，一個提到標記字串本身的人類留言不應該因此消失
# shellcheck disable=SC2015
grep -qF '我們在留言中間提到這個標記字串' "$PRMAT_ROOT/pr.md" && pass fetch-pr-material-keeps-mid-body-marker-mention || bad fetch-pr-material-keeps-mid-body-marker-mention

# raw body file 只該是 gh 回傳的 PR body 本身，不得包含討論串或 review 的
# 任何內容 -- _derive_issue_number 依賴這個檔案而非渲染後的 pr.md，才不會
# 被留言裡的 closing keyword 誤導
# shellcheck disable=SC2015
grep -qF 'Closes #42' "$PRMAT_ROOT/pr-body-raw.md" && pass fetch-pr-material-raw-body-has-pr-body || bad fetch-pr-material-raw-body-has-pr-body
if grep -qF '第一則人類留言' "$PRMAT_ROOT/pr-body-raw.md"; then
  bad fetch-pr-material-raw-body-excludes-comments
else
  pass fetch-pr-material-raw-body-excludes-comments
fi

export PATH="$saved_path"

# --- _parse_issue_ref / _derive_issue_number ---
# 明示的 issue 參照：完整 URL、owner/repo#N、純 #N、純數字
# shellcheck disable=SC2015
[ "$(_parse_issue_ref 'https://github.com/acme/widgets/issues/42' acme widgets)" = 42 ] && pass parse-issue-ref-url || bad parse-issue-ref-url
# shellcheck disable=SC2015
[ "$(_parse_issue_ref 'acme/widgets#42' acme widgets)" = 42 ] && pass parse-issue-ref-shorthand || bad parse-issue-ref-shorthand
# shellcheck disable=SC2015
[ "$(_parse_issue_ref '#42' acme widgets)" = 42 ] && pass parse-issue-ref-hash || bad parse-issue-ref-hash
# shellcheck disable=SC2015
[ "$(_parse_issue_ref '42' acme widgets)" = 42 ] && pass parse-issue-ref-bare-number || bad parse-issue-ref-bare-number

# 別的 repo 的 issue 不接受
if _parse_issue_ref 'https://github.com/other/repo/issues/42' acme widgets >/dev/null 2>&1; then
  bad parse-issue-ref-rejects-cross-repo
else
  pass parse-issue-ref-rejects-cross-repo
fi

# 從 PR 內文的 closing keyword 推導，大小寫不敏感
# shellcheck disable=SC2015
[ "$(_derive_issue_number 'blah
Closes #42' acme widgets)" = 42 ] && pass derive-issue-closes-hash || bad derive-issue-closes-hash
# shellcheck disable=SC2015
[ "$(_derive_issue_number 'fixes https://github.com/acme/widgets/issues/7' acme widgets)" = 7 ] && pass derive-issue-fixes-url || bad derive-issue-fixes-url
# shellcheck disable=SC2015
[ "$(_derive_issue_number 'RESOLVED acme/widgets#9' acme widgets)" = 9 ] && pass derive-issue-resolved-shorthand || bad derive-issue-resolved-shorthand

# 沒有 closing keyword 時回非零，且不得印出任何東西
DERIVE_OUT="$(_derive_issue_number 'just a plain body mentioning #42' acme widgets 2>/dev/null)" && DERIVE_RC=0 || DERIVE_RC=1
# shellcheck disable=SC2015
[ "$DERIVE_RC" = 1 ] && [ -z "$DERIVE_OUT" ] && pass derive-issue-no-keyword-returns-nonzero || bad derive-issue-no-keyword-returns-nonzero

# --- fetch_review_materials: 三份材料、缺料降級、materials 唯讀 ---
MAT_ROOT="$T/materials-e2e"
mkdir -p "$MAT_ROOT/bin" "$MAT_ROOT/run"
cat > "$MAT_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
"pr view") cat "$GH_PR_JSON_FIXTURE" ;;
"issue view")
  [ -n "${GH_ISSUE_JSON_FIXTURE:-}" ] || exit 1
  cat "$GH_ISSUE_JSON_FIXTURE" ;;
*) exit 1 ;;
esac
STUB
chmod +x "$MAT_ROOT/bin/gh"

cat > "$MAT_ROOT/pr.json" <<'JSON'
{"title":"T","body":"Closes #42","comments":[],"reviews":[]}
JSON
cat > "$MAT_ROOT/issue.json" <<'JSON'
{"title":"需求標題","body":"需求內文","comments":[{"author":{"login":"alice"},"createdAt":"2026-08-01T00:00:00Z","body":"補充需求"}]}
JSON
printf '設計文件內容\n' > "$MAT_ROOT/design-doc.md"

export PATH="$MAT_ROOT/bin:$saved_path"
export GH_PR_JSON_FIXTURE="$MAT_ROOT/pr.json"
export GH_ISSUE_JSON_FIXTURE="$MAT_ROOT/issue.json"

# shellcheck disable=SC2015
MAT_DIR="$(fetch_review_materials acme widgets 7 '' "$MAT_ROOT/design-doc.md" "$MAT_ROOT/run")" \
  && pass fetch-materials-returns-zero || bad fetch-materials-returns-zero

# shellcheck disable=SC2015
[ "$MAT_DIR" = "$MAT_ROOT/run/materials" ] && pass fetch-materials-prints-dir || bad fetch-materials-prints-dir
# shellcheck disable=SC2015
[ -f "$MAT_DIR/pr.md" ] && pass fetch-materials-writes-pr || bad fetch-materials-writes-pr
# issue 編號由 PR 內文的 Closes #42 推導而來，第四個參數是空字串
# shellcheck disable=SC2015
grep -qF '需求內文' "$MAT_DIR/issue.md" && pass fetch-materials-derives-issue || bad fetch-materials-derives-issue
# shellcheck disable=SC2015
grep -qF '補充需求' "$MAT_DIR/issue.md" && pass fetch-materials-issue-comments || bad fetch-materials-issue-comments
# shellcheck disable=SC2015
grep -qF '設計文件內容' "$MAT_DIR/design.md" && pass fetch-materials-copies-design || bad fetch-materials-copies-design

# .materials-status 要記錄這次是「由 PR 內文推導」issue、design document
# 「已提供」-- print_summary 靠這個檔案回報收集狀況給人看
MAT_STATUS="$MAT_ROOT/run/.materials-status"
# shellcheck disable=SC2015
grep -qxF 'issue_status=derived' "$MAT_STATUS" && pass fetch-materials-status-issue-derived || bad fetch-materials-status-issue-derived
# shellcheck disable=SC2015
grep -qxF 'issue_number=42' "$MAT_STATUS" && pass fetch-materials-status-issue-number || bad fetch-materials-status-issue-number
# shellcheck disable=SC2015
grep -qxF 'design_status=provided' "$MAT_STATUS" && pass fetch-materials-status-design-provided || bad fetch-materials-status-design-provided

# materials 目錄與其中的檔案都不可寫
if ( : > "$MAT_DIR/should-not-be-writable.txt" ) 2>/dev/null; then
  bad fetch-materials-dir-read-only
else
  pass fetch-materials-dir-read-only
fi

chmod -R u+w "$MAT_ROOT/run" 2>/dev/null || true

# issue 抓不到、design document 未提供時：不產生對應檔，但仍成功返回
MAT_DIR2_ROOT="$MAT_ROOT/run2"
mkdir -p "$MAT_DIR2_ROOT"
unset GH_ISSUE_JSON_FIXTURE
# shellcheck disable=SC2015
MAT_DIR2="$(fetch_review_materials acme widgets 7 '' '' "$MAT_DIR2_ROOT")" \
  && pass fetch-materials-degrades-returns-zero || bad fetch-materials-degrades-returns-zero
# shellcheck disable=SC2015
[ -f "$MAT_DIR2/pr.md" ] && pass fetch-materials-degrades-keeps-pr || bad fetch-materials-degrades-keeps-pr
# shellcheck disable=SC2015
[ ! -e "$MAT_DIR2/issue.md" ] && pass fetch-materials-degrades-no-issue-file || bad fetch-materials-degrades-no-issue-file
# shellcheck disable=SC2015
[ ! -e "$MAT_DIR2/design.md" ] && pass fetch-materials-degrades-no-design-file || bad fetch-materials-degrades-no-design-file

# .materials-status 要能分辨「issue 有被推導出來、但抓不到」跟「design
# document 根本沒給」這兩種不同狀態 -- 這是使用者能不能自己動手修的關鍵
# 差異，見 print_summary 的回報邏輯
MAT_STATUS2="$MAT_DIR2_ROOT/.materials-status"
# shellcheck disable=SC2015
grep -qxF 'issue_status=failed' "$MAT_STATUS2" && pass fetch-materials-status-issue-failed || bad fetch-materials-status-issue-failed
# shellcheck disable=SC2015
grep -qxF 'design_status=not-provided' "$MAT_STATUS2" && pass fetch-materials-status-design-not-provided || bad fetch-materials-status-design-not-provided

chmod -R u+w "$MAT_DIR2_ROOT" 2>/dev/null || true

# --- fetch_review_materials: 呼叫端明確指定 issue（而非推導），
# .materials-status 要能跟「推導」分開回報 ---
MAT_DIR3_ROOT="$MAT_ROOT/run3"
mkdir -p "$MAT_DIR3_ROOT"
export GH_ISSUE_JSON_FIXTURE="$MAT_ROOT/issue.json"
# shellcheck disable=SC2015
MAT_DIR3="$(fetch_review_materials acme widgets 7 '99' '' "$MAT_DIR3_ROOT")" \
  && pass fetch-materials-explicit-issue-returns-zero || bad fetch-materials-explicit-issue-returns-zero
# shellcheck disable=SC2015
[ -f "$MAT_DIR3/issue.md" ] && pass fetch-materials-explicit-issue-writes-issue-file || bad fetch-materials-explicit-issue-writes-issue-file
MAT_STATUS3="$MAT_DIR3_ROOT/.materials-status"
# shellcheck disable=SC2015
grep -qxF 'issue_status=explicit' "$MAT_STATUS3" && pass fetch-materials-status-issue-explicit || bad fetch-materials-status-issue-explicit
# shellcheck disable=SC2015
grep -qxF 'issue_number=99' "$MAT_STATUS3" && pass fetch-materials-status-issue-explicit-number || bad fetch-materials-status-issue-explicit-number
chmod -R u+w "$MAT_DIR3_ROOT" 2>/dev/null || true

# --- fetch_review_materials: design doc 路徑有給但讀不到 -- 這跟「根本
# 沒給」要能分開回報，前者通常是打錯路徑，後者是使用者自己的選擇 ---
MAT_DIR4_ROOT="$MAT_ROOT/run4"
mkdir -p "$MAT_DIR4_ROOT"
# shellcheck disable=SC2015
MAT_DIR4="$(fetch_review_materials acme widgets 7 '' "$MAT_ROOT/does-not-exist-design.md" "$MAT_DIR4_ROOT")" \
  && pass fetch-materials-unreadable-design-returns-zero || bad fetch-materials-unreadable-design-returns-zero
# shellcheck disable=SC2015
[ ! -e "$MAT_DIR4/design.md" ] && pass fetch-materials-unreadable-design-no-file || bad fetch-materials-unreadable-design-no-file
MAT_STATUS4="$MAT_DIR4_ROOT/.materials-status"
# shellcheck disable=SC2015
grep -qxF 'design_status=unreadable' "$MAT_STATUS4" && pass fetch-materials-status-design-unreadable || bad fetch-materials-status-design-unreadable
chmod -R u+w "$MAT_DIR4_ROOT" 2>/dev/null || true

# --- Finding 1 的釘死測試：PR 本文沒有 closing keyword，但討論串裡有一則
# 留言寫著 closing keyword -- 留言串任何 GitHub 使用者都能寫，用它來推導
# 會讓留言的人決定每個 reviewer 是拿哪個 issue 當基準。issue 必須維持
# 「未宣告」，不能被那則留言推導出來。 ---
cat > "$MAT_ROOT/pr-injection.json" <<'JSON'
{"title":"T","body":"本 PR 本文完全沒有 closing keyword。","comments":[{"author":{"login":"attacker"},"createdAt":"2026-08-01T00:00:00Z","body":"closes #999"}],"reviews":[]}
JSON
cat > "$MAT_ROOT/issue-injection.json" <<'JSON'
{"title":"不該被抓到的 issue","body":"如果看到這段文字，代表推導誤用了留言而非 PR 本文","comments":[]}
JSON

MAT_INJ_ROOT="$MAT_ROOT/run-injection"
mkdir -p "$MAT_INJ_ROOT"
export GH_PR_JSON_FIXTURE="$MAT_ROOT/pr-injection.json"
export GH_ISSUE_JSON_FIXTURE="$MAT_ROOT/issue-injection.json"

# shellcheck disable=SC2015
MAT_INJ_DIR="$(fetch_review_materials acme widgets 7 '' '' "$MAT_INJ_ROOT")" \
  && pass fetch-materials-injection-returns-zero || bad fetch-materials-injection-returns-zero
# 留言確實有被抓進渲染後的材料裡 -- 排除「根本沒被用到只是因為沒抓到」
# 這個假陽性
# shellcheck disable=SC2015
grep -qF 'closes #999' "$MAT_INJ_DIR/pr.md" && pass fetch-materials-injection-comment-present-in-render || bad fetch-materials-injection-comment-present-in-render
# 但就是不准被拿去推導、抓取
# shellcheck disable=SC2015
[ ! -e "$MAT_INJ_DIR/issue.md" ] && pass fetch-materials-injection-no-issue-file || bad fetch-materials-injection-no-issue-file
MAT_INJ_STATUS="$MAT_INJ_ROOT/.materials-status"
# shellcheck disable=SC2015
grep -qxF 'issue_status=not-declared' "$MAT_INJ_STATUS" && pass fetch-materials-injection-status-not-declared || bad fetch-materials-injection-status-not-declared

chmod -R u+w "$MAT_INJ_ROOT" 2>/dev/null || true
export PATH="$saved_path"

# ==============================================================
# build_prompt
# ==============================================================

# --- build_prompt: 契約原文照樣嵌入，但材料內文不再嵌入 -- 材料改由
# cmd_prepare() 複製到 reviewer 自己的目錄，由 reviewer 自己讀取，
# build_prompt 這一端只印座標，不碰材料檔的內容 ---
BP_ROOT="$T/build-prompt-materials"
mkdir -p "$BP_ROOT/materials"
printf 'CONTRACT-BODY\n' > "$BP_ROOT/contract.md"
printf '# PR 標題\n\nPR-MATERIAL-BODY\n' > "$BP_ROOT/materials/pr.md"
printf '# Issue 標題\n\nISSUE-MATERIAL-BODY\n' > "$BP_ROOT/materials/issue.md"

BP_OUT="$(build_prompt "$BP_ROOT/contract.md" \
  'https://github.com/acme/widgets/pull/7' \
  "$BP_ROOT/materials" \
  claude some-model /tmp/wt origin/main "$BP_ROOT/review.md")"

# shellcheck disable=SC2015
grep -qF 'CONTRACT-BODY' <<<"$BP_OUT" && pass build-prompt-embeds-contract || bad build-prompt-embeds-contract
# 材料檔就放在 materials_dir 底下、build_prompt 完全沒讀過它們的內容 --
# 這兩份材料的內文不該出現在組出來的 prompt 裡
# shellcheck disable=SC2015
grep -qF 'PR-MATERIAL-BODY' <<<"$BP_OUT" && bad build-prompt-does-not-embed-pr-material || pass build-prompt-does-not-embed-pr-material
# shellcheck disable=SC2015
grep -qF 'ISSUE-MATERIAL-BODY' <<<"$BP_OUT" && bad build-prompt-does-not-embed-issue-material || pass build-prompt-does-not-embed-issue-material
# 材料目錄的絕對路徑仍要出現在座標區，供人事後查閱 -- 現在這一行指向的是
# 呼叫端（cmd_prepare()）傳進來的那個目錄，可能是共用的 materials_dir，
# 也可能是某個 reviewer 自己的副本，build_prompt 自己不分辨、原樣印出
# shellcheck disable=SC2015
grep -qF "$BP_ROOT/materials" <<<"$BP_OUT" && pass build-prompt-keeps-materials-path || bad build-prompt-keeps-materials-path

# 契約全文必須逐字、原封不動地作為 prompt 的開頭 -- 用真正的
# reviewer-contract.md（多章節）而非上面的合成 fixture 檢查，才抓得到
# 截斷、章節順序被打亂、或內容被意外改寫；grep 只查子字串是否存在，查不
# 出這三者。
BP_REAL_OUT="$(build_prompt "$REAL_CONTRACT" \
  'https://github.com/acme/widgets/pull/7' \
  "$BP_ROOT/materials" \
  claude some-model /tmp/wt origin/main "$BP_ROOT/review.md")"
BP_REAL_CONTRACT_TEXT="$(cat "$REAL_CONTRACT")"
case "$BP_REAL_OUT" in
  "$BP_REAL_CONTRACT_TEXT"*) pass build-prompt-real-contract-verbatim-prefix ;;
  *) bad build-prompt-real-contract-verbatim-prefix ;;
esac

# --- build_prompt: 新增的第 8 個位置參數 output_file 正確對應到各自的
# reviewer，不會被混到別家 -- 兩個不同 reviewer 各自的 output_file 值
# 分別指向 reviewers/claude/workdir/review.md 與
# reviewers/agy/workdir/review.md，斷言各自組出的內容都含一行標著自己
# 那個路徑的座標，且不含另一個 reviewer 的路徑 ---
BP_CLAUDE_OUTPUT_FILE="$BP_ROOT/reviewers/claude/workdir/review.md"
BP_AGY_OUTPUT_FILE="$BP_ROOT/reviewers/agy/workdir/review.md"
BP_CLAUDE_OUT="$(build_prompt "$BP_ROOT/contract.md" \
  'https://github.com/acme/widgets/pull/7' \
  "$BP_ROOT/materials" \
  claude some-model /tmp/wt origin/main "$BP_CLAUDE_OUTPUT_FILE")"
BP_AGY_OUT="$(build_prompt "$BP_ROOT/contract.md" \
  'https://github.com/acme/widgets/pull/7' \
  "$BP_ROOT/materials" \
  agy some-model /tmp/wt origin/main "$BP_AGY_OUTPUT_FILE")"

# shellcheck disable=SC2015
grep -qxF -- "- 輸出檔絕對路徑：$BP_CLAUDE_OUTPUT_FILE" <<<"$BP_CLAUDE_OUT" && pass build-prompt-output-file-claude-line || bad build-prompt-output-file-claude-line
# shellcheck disable=SC2015
grep -qxF -- "- 輸出檔絕對路徑：$BP_AGY_OUTPUT_FILE" <<<"$BP_AGY_OUT" && pass build-prompt-output-file-agy-line || bad build-prompt-output-file-agy-line
# shellcheck disable=SC2015
grep -qF "$BP_AGY_OUTPUT_FILE" <<<"$BP_CLAUDE_OUT" && bad build-prompt-output-file-claude-excludes-agy-path || pass build-prompt-output-file-claude-excludes-agy-path
# shellcheck disable=SC2015
grep -qF "$BP_CLAUDE_OUTPUT_FILE" <<<"$BP_AGY_OUT" && bad build-prompt-output-file-agy-excludes-claude-path || pass build-prompt-output-file-agy-excludes-claude-path

# ==============================================================
# setup_worktree
#
# Exercises real local git plumbing (never touches actual GitHub): a bare
# repo standing in for the GitHub-hosted origin, with a PR-like
# refs/pull/<N>/head ref pushed to it exactly as GitHub itself exposes one,
# and a separate work clone acting as the caller's cwd. The origin remote
# is configured with a literal https://github.com/acme/widgets.git URL --
# what setup_worktree's own origin/owner/repo check (_check_origin_matches,
# which reads the raw configured URL, not the resolved one -- see its own
# docstring) needs to see -- with a `url.<local-path>.insteadOf` rule
# transparently redirecting the actual network operations (fetch/push) to
# this fixture's own local bare repo instead. This never touches real
# GitHub: insteadOf rewriting happens client-side, before any connection
# is made.
# ==============================================================

GIT_FIXTURE="$T/git-fixture"
mkdir -p "$GIT_FIXTURE/remotes/acme" "$GIT_FIXTURE/work"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

git init -q -b main --bare "$GIT_FIXTURE/remotes/acme/widgets.git"
git init -q -b main "$GIT_FIXTURE/work"
(
  cd "$GIT_FIXTURE/work"
  git config user.email test@example.com
  git config user.name "Test"
  printf 'base\n' > f.txt
  git add f.txt
  git commit -q -m base
  git remote add origin "https://github.com/acme/widgets.git"
  git config "url.$GIT_FIXTURE/remotes/acme/widgets.git.insteadOf" "https://github.com/acme/widgets.git"
  git push -q origin HEAD:refs/heads/main
  git checkout -q -b feature
  printf 'change\n' >> f.txt
  git commit -aq -m change
  git push -q origin feature:refs/pull/9/head
  git checkout -q main
)
PR_SHA="$(git -C "$GIT_FIXTURE/work" rev-parse feature)"

BASE_DIR="$T/setup-worktree-base"
out="$(cd "$GIT_FIXTURE/work" && setup_worktree acme widgets 9 "$BASE_DIR")"
rc=$?
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$rc" -eq 0 ] && [ "$out" = "$BASE_DIR/worktree" ] && pass setup-worktree-success || bad setup-worktree-success
got_sha="$(git -C "$out" rev-parse HEAD 2>/dev/null || true)"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$got_sha" = "$PR_SHA" ] && pass setup-worktree-checks-out-pr-head || bad setup-worktree-checks-out-pr-head

# owner/repo that doesn't match this cwd's actual origin -> refuse rather
# than silently fetch/review the wrong codebase.
if out="$(cd "$GIT_FIXTURE/work" && setup_worktree wrong-owner wrong-repo 9 "$T/setup-worktree-mismatch" 2>/dev/null)"; then
  bad setup-worktree-owner-mismatch
else
  pass setup-worktree-owner-mismatch
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -z "$out" ] && pass setup-worktree-owner-mismatch-no-output || bad setup-worktree-owner-mismatch-no-output

# PR number with no matching refs/pull/<N>/head on the remote -> fetch
# fails -> non-zero, no stdout.
if out="$(cd "$GIT_FIXTURE/work" && setup_worktree acme widgets 999 "$T/setup-worktree-missing-pr" 2>/dev/null)"; then
  bad setup-worktree-missing-pr-ref
else
  pass setup-worktree-missing-pr-ref
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -z "$out" ] && pass setup-worktree-missing-pr-ref-no-output || bad setup-worktree-missing-pr-ref-no-output

# A same-named local ref left behind by an earlier run whose PID got
# reused (setup_worktree names its ref pr-review-<N>-$$, and $$ stays
# constant across this whole test script run) pointing at an unrelated,
# non-fast-forward commit. Without the fetch's + prefix, this would make
# the fetch fail for a reason that has nothing to do with the current PR.
# Uses a fresh PR number (20, pushed here) rather than PR 9: PR 9's own ref
# name is already checked out by the still-open worktree from the success
# test above, so reusing it wouldn't actually be testing a stale ref.
(
  cd "$GIT_FIXTURE/work"
  git push -q origin feature:refs/pull/20/head
  git checkout -q -b diverged main
  printf 'diverged\n' >> f.txt
  git commit -aq -m diverged
  git branch -f "pr-review-20-$$" diverged
  git checkout -q main
  git branch -q -D diverged
)
out="$(cd "$GIT_FIXTURE/work" && setup_worktree acme widgets 20 "$T/setup-worktree-stale-ref")"
rc=$?
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$rc" -eq 0 ] && [ "$out" = "$T/setup-worktree-stale-ref/worktree" ] && pass setup-worktree-force-updates-stale-ref || bad setup-worktree-force-updates-stale-ref
stale_got_sha="$(git -C "$out" rev-parse HEAD 2>/dev/null || true)"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$stale_got_sha" = "$PR_SHA" ] && pass setup-worktree-force-update-correct-commit || bad setup-worktree-force-update-correct-commit

# ==============================================================
# _origin_matches_owner_repo
#
# Direct unit tests for the boundary-safe origin/owner/repo matching used
# by setup_worktree's sanity check. Covers both HTTPS and SSH remote URL
# forms, with and without a trailing .git, and the exact boundary-bypass
# vulnerability found in review: a bare `*` prefix with no boundary
# character would let an owner of "acme" be satisfied by an unrelated
# owner like "not-acme" whose URL just happens to share the tail (a
# .../not-acme/widgets.git URL does end with "acme/widgets.git").
# ==============================================================

if _origin_matches_owner_repo "https://github.com/acme/widgets.git" acme widgets; then
  pass origin-match-https-git
else
  bad origin-match-https-git
fi

if _origin_matches_owner_repo "https://github.com/acme/widgets" acme widgets; then
  pass origin-match-https-no-git
else
  bad origin-match-https-no-git
fi

if _origin_matches_owner_repo "git@github.com:acme/widgets.git" acme widgets; then
  pass origin-match-ssh-git
else
  bad origin-match-ssh-git
fi

if _origin_matches_owner_repo "git@github.com:acme/widgets" acme widgets; then
  pass origin-match-ssh-no-git
else
  bad origin-match-ssh-no-git
fi

if _origin_matches_owner_repo "https://github.com/not-acme/widgets.git" acme widgets; then
  bad origin-match-rejects-boundary-bypass
else
  pass origin-match-rejects-boundary-bypass
fi

if _origin_matches_owner_repo "https://github.com/other/other.git" acme widgets; then
  bad origin-match-rejects-unrelated
else
  pass origin-match-rejects-unrelated
fi

# A local filesystem path ending in .../acme/widgets(.git), or a remote on
# a *different* host that happens to share the same owner/repo suffix,
# must both be rejected -- the old suffix-only match (`*/<owner>/<repo>`
# with no host anchor at all) accepted either just as readily as a real
# https://github.com/acme/widgets remote.
if _origin_matches_owner_repo "/home/user/repos/acme/widgets" acme widgets; then
  bad origin-match-rejects-local-path
else
  pass origin-match-rejects-local-path
fi
if _origin_matches_owner_repo "/home/user/repos/acme/widgets.git" acme widgets; then
  bad origin-match-rejects-local-path-git-suffix
else
  pass origin-match-rejects-local-path-git-suffix
fi
if _origin_matches_owner_repo "git@gitlab.example.com:acme/widgets.git" acme widgets; then
  bad origin-match-rejects-different-host
else
  pass origin-match-rejects-different-host
fi
if _origin_matches_owner_repo "https://gitlab.example.com/acme/widgets.git" acme widgets; then
  bad origin-match-rejects-different-host-https
else
  pass origin-match-rejects-different-host-https
fi

# End-to-end confirmation through setup_worktree itself, not just the
# helper in isolation: rejection must happen before any network operation,
# so a repo whose origin is merely set (never actually fetchable) is
# enough here.
BOUNDARY_REPO="$T/boundary-repo"
mkdir -p "$BOUNDARY_REPO"
git init -q -b main "$BOUNDARY_REPO"
(
  cd "$BOUNDARY_REPO"
  git remote add origin "https://github.com/not-acme/widgets.git"
)
if out="$(cd "$BOUNDARY_REPO" && setup_worktree acme widgets 1 "$T/setup-worktree-boundary" 2>/dev/null)"; then
  bad setup-worktree-rejects-boundary-bypass
else
  pass setup-worktree-rejects-boundary-bypass
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -z "$out" ] && pass setup-worktree-rejects-boundary-bypass-no-output || bad setup-worktree-rejects-boundary-bypass-no-output

# ==============================================================
# setup_worktree -- stale local-ref cleanup
#
# Isolated fixture (rather than reusing GIT_FIXTURE) so this doesn't
# collide with the pr-review-* refs the tests above already left checked
# out in live worktrees.
# ==============================================================

CLEANUP_FIXTURE="$T/git-fixture-cleanup"
mkdir -p "$CLEANUP_FIXTURE/remotes/acme" "$CLEANUP_FIXTURE/work"
git init -q -b main --bare "$CLEANUP_FIXTURE/remotes/acme/widgets.git"
git init -q -b main "$CLEANUP_FIXTURE/work"
(
  cd "$CLEANUP_FIXTURE/work"
  git config user.email test@example.com
  git config user.name "Test"
  printf 'base\n' > f.txt
  git add f.txt
  git commit -q -m base
  git remote add origin "https://github.com/acme/widgets.git"
  git config "url.$CLEANUP_FIXTURE/remotes/acme/widgets.git.insteadOf" "https://github.com/acme/widgets.git"
  git push -q origin HEAD:refs/heads/main
  git checkout -q -b feature
  printf 'change\n' >> f.txt
  git commit -aq -m change
  git push -q origin feature:refs/pull/5/head
  git checkout -q main
  # A stale, non-checked-out leftover from a fictitious earlier run --
  # this function's own exact ref shape, so it must be deleted.
  git branch pr-review-999-12345 HEAD
  # A user's own, differently-purposed branches that merely start with
  # the same "pr-review-" prefix -- these must survive. Both are
  # non-checked-out (deletable if the cleanup's own shape check didn't
  # exist at all), so only the stricter shape match is what protects them.
  git branch pr-review-notes HEAD
  git branch pr-review-42 HEAD
)

(cd "$CLEANUP_FIXTURE/work" && setup_worktree acme widgets 5 "$T/setup-worktree-cleanup-check") >/dev/null 2>&1 || true

if git -C "$CLEANUP_FIXTURE/work" show-ref --verify --quiet refs/heads/pr-review-999-12345; then
  bad setup-worktree-cleans-stale-refs
else
  pass setup-worktree-cleans-stale-refs
fi

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
git -C "$CLEANUP_FIXTURE/work" show-ref --verify --quiet refs/heads/pr-review-notes && pass setup-worktree-preserves-unrelated-user-branch || bad setup-worktree-preserves-unrelated-user-branch
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
git -C "$CLEANUP_FIXTURE/work" show-ref --verify --quiet refs/heads/pr-review-42 && pass setup-worktree-preserves-single-number-user-branch || bad setup-worktree-preserves-single-number-user-branch

# A branch matching this function's own exact stale-ref shape, but NOT
# checked out anywhere -- exactly the window this function's own docstring
# risk covers: it creates its ref before checking it out, so a concurrent
# prepare running this same loop during that window would otherwise see a
# branch that fits the shape yet isn't checked out yet, and delete it out
# from under the run that just created it. Git's "still checked out" guard
# does not cover this window at all, so the only thing that can is a
# liveness check on the ref's own trailing PID segment -- the same check
# _reap_stale_run_dirs already does for stale run directories. $$ (this
# test script's own PID) stands in for that still-running owner, since it
# is genuinely alive for the whole duration of this test run.
git -C "$CLEANUP_FIXTURE/work" branch "pr-review-77-$$" main

# PR 888 has no matching pull ref on this fixture's remote, so this call
# fails at the fetch step -- but the branch-cleanup loop under test runs
# before that fetch, so the failure doesn't prevent it from exercising the
# liveness check.
(cd "$CLEANUP_FIXTURE/work" && setup_worktree acme widgets 888 "$T/setup-worktree-cleanup-check2") >/dev/null 2>&1 || true

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
git -C "$CLEANUP_FIXTURE/work" show-ref --verify --quiet "refs/heads/pr-review-77-$$" && pass setup-worktree-preserves-branch-with-live-pid || bad setup-worktree-preserves-branch-with-live-pid

# --- 缺陷 6：上面那組用 $$（這支測試腳本自己的 PID）當活體分支的 trailing
# PID，整場測試期間恆為存活，遮蔽了兩階段拆分後的真實情況 -- 那裡的
# cmd_prepare() 早就已經返回、trailing PID 早就已經死了，真正還活著的
# 只有 .supervisor.pid 指向的監督行程。這裡重現那個真實形狀：目錄名與
# 分支名的 trailing PID 都已死，但 base_dir 底下的 .supervisor.pid 指向
# 一個貨真價實存活的行程。透過 setup_worktree 本身（而不是
# _reap_stale_run_dirs 單獨）驗證：分支能不能保住，實際上是靠 worktree
# 沒被回收、git 自己擋下 `git branch -D` 這個既有機制（見這個檔案上面
# 分支清理迴圈自己的文件），不是分支清理迴圈另外去讀
# .supervisor.pid -- setup_worktree 是唯一能同時證明兩者的入口。既有的
# setup-worktree-preserves-branch-with-live-pid 案例原樣保留。---
( exit 0 ) & cleanup_dead_pid=$!
wait "$cleanup_dead_pid" 2>/dev/null || true

CLEANUP_SUPERVISOR_ROOT="$T/setup-worktree-cleanup-supervisor"
mkdir -p "$CLEANUP_SUPERVISOR_ROOT"
CLEANUP_SUP_STALE_BASE="$CLEANUP_SUPERVISOR_ROOT/1-stale-$cleanup_dead_pid"
mkdir -p "$CLEANUP_SUP_STALE_BASE"
# 分支名與目錄名共用同一個死掉的 trailing PID -- 一如真正的 cmd_prepare()
# 用同一個 $$ 同時命名兩者。
git -C "$CLEANUP_FIXTURE/work" branch "pr-review-5-$cleanup_dead_pid" HEAD
(cd "$CLEANUP_FIXTURE/work" && git worktree add -q "$CLEANUP_SUP_STALE_BASE/worktree" "pr-review-5-$cleanup_dead_pid")
chmod -R a-w "$CLEANUP_SUP_STALE_BASE/worktree"
sleep 30 & cleanup_supervisor_alive_pid=$!
printf '%s\n' "$cleanup_supervisor_alive_pid" > "$CLEANUP_SUP_STALE_BASE/.supervisor.pid"

# PR 5 已經有可抓的 pull ref（見這個 fixture 上面的既有設定），所以這次
# setup_worktree 呼叫本身會成功，額外建出自己的分支與 worktree -- 這裡
# 不對那次成功本身斷言，只在乎它有沒有連帶動到上面那個 stale sibling。
(cd "$CLEANUP_FIXTURE/work" && setup_worktree acme widgets 5 "$CLEANUP_SUPERVISOR_ROOT/2-current-$$") >/dev/null 2>&1 || true

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -e "$CLEANUP_SUP_STALE_BASE/worktree" ] && pass "setup-worktree-live-supervisor-pid-preserves-worktree-despite-dead-trailing-pid" \
  || bad "setup-worktree-live-supervisor-pid-preserves-worktree-despite-dead-trailing-pid: worktree 仍被回收，即使 .supervisor.pid 存活"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
git -C "$CLEANUP_FIXTURE/work" show-ref --verify --quiet "refs/heads/pr-review-5-$cleanup_dead_pid" && pass "setup-worktree-live-supervisor-pid-preserves-branch-despite-dead-trailing-pid" \
  || bad "setup-worktree-live-supervisor-pid-preserves-branch-despite-dead-trailing-pid: 分支被強制刪除了，即使 .supervisor.pid 存活"

kill "$cleanup_supervisor_alive_pid" 2>/dev/null || true
wait "$cleanup_supervisor_alive_pid" 2>/dev/null || true
chmod -R u+w "$CLEANUP_SUP_STALE_BASE/worktree" 2>/dev/null || true
(cd "$CLEANUP_FIXTURE/work" && git worktree remove --force "$CLEANUP_SUP_STALE_BASE/worktree") >/dev/null 2>&1 || true
git -C "$CLEANUP_FIXTURE/work" branch -D "pr-review-5-$cleanup_dead_pid" >/dev/null 2>&1 || true

# ==============================================================
# _git_status_snapshot
# ==============================================================

# _make_worktree_fixture <root>
#
# Creates a bare "origin" repo plus a work clone with one commit, then adds
# a second, real *linked* worktree at <root>/worktree on its own branch --
# the same topology `git worktree add`/`git worktree remove` need to behave
# for real, which launch_reviewer_interactive's snapshot and
# spawn_supervisor_interactive's cleanup both depend on. Prints the
# worktree's absolute path.
_make_worktree_fixture() {
  local root="$1" worktree_dir
  mkdir -p "$root/origin" "$root/work"
  git init -q -b main --bare "$root/origin/repo.git"
  git init -q -b main "$root/work"
  (
    cd "$root/work"
    git config user.email t@t.com
    git config user.name t
    printf 'base\n' > f.txt
    git add f.txt
    git commit -q -m base
    git remote add origin "$root/origin/repo.git"
    git push -q origin HEAD:refs/heads/main
    git checkout -q -b feature
    printf 'feature\n' >> f.txt
    git commit -aq -m feature
    git checkout -q main
  )
  worktree_dir="$root/worktree"
  (cd "$root/work" && git worktree add -q "$worktree_dir" feature)
  printf '%s\n' "$worktree_dir"
}

SNAP_ROOT="$T/snapshot-fixture"
SNAP_WT="$(_make_worktree_fixture "$SNAP_ROOT")"

snap1="$(_git_status_snapshot "$SNAP_WT")"
snap2="$(_git_status_snapshot "$SNAP_WT")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$snap1" = "$snap2" ] && pass git-status-snapshot-stable-when-unchanged || bad git-status-snapshot-stable-when-unchanged

printf 'dirty\n' > "$SNAP_WT/untracked-marker.txt"
snap3="$(_git_status_snapshot "$SNAP_WT")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$snap1" != "$snap3" ] && pass git-status-snapshot-detects-untracked-file || bad git-status-snapshot-detects-untracked-file
rm -f "$SNAP_WT/untracked-marker.txt"

# A commit that leaves the working tree clean again must still be detected
# -- `git status --porcelain` alone would miss it, which is exactly why
# _git_status_snapshot also folds in HEAD.
(
  cd "$SNAP_WT"
  printf 'more\n' >> f.txt
  git add f.txt
  git commit -q -m more
)
snap4="$(_git_status_snapshot "$SNAP_WT")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$snap1" != "$snap4" ] && pass git-status-snapshot-detects-commit-with-clean-tree || bad git-status-snapshot-detects-commit-with-clean-tree

# ==============================================================
# _write_agy_home
#
# Uses the real $HOME (not an isolated fixture, unlike resolve_model's
# codex/opencode/claude cases above): this function's whole job is to read
# a slice of the real ~/.gemini and rebuild an isolated copy elsewhere, so
# it has nothing to build from without it. Only credential files get
# symlinked (never copied -- see the function's own docstring), and only
# one field (.security.auth.selectedType) is ever read out of the real
# settings.json, so nothing sensitive from a real config crosses into the
# assertions below.
# ==============================================================

agy_home="$T/agy-home"
if _write_agy_home "$agy_home"; then
  s="$agy_home/.gemini/antigravity-cli/settings.json"
  if [ -f "$s" ] \
    && jq -e '.permissions.allow | index("command(git diff)")' "$s" >/dev/null \
    && jq -e '.permissions.allow | length == 1' "$s" >/dev/null; then
    pass "_write_agy_home 寫出只含一條 git diff 規則的權限設定"
  else
    bad "_write_agy_home 權限設定不正確: $(cat "$s" 2>/dev/null)"
  fi
else
  bad "_write_agy_home 回傳非零"
fi

# _write_agy_home 不含 mcpServers（避免載入外部工具）
if jq -e 'has("mcpServers") | not' "$agy_home/.gemini/settings.json" >/dev/null 2>&1; then
  pass "_write_agy_home 的 Gemini 設定不含 mcpServers"
else
  bad "_write_agy_home 的 Gemini 設定含有 mcpServers"
fi

# Two isolated homes built for two different reviewer processes must not
# collide or leak into each other's settings.
agy_home2="$T/agy-home-2"
_write_agy_home "$agy_home2" || bad "_write_agy_home 第二次呼叫回傳非零"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -f "$agy_home2/.gemini/antigravity-cli/settings.json" ] && [ "$agy_home2" != "$agy_home" ] && pass _write_agy_home-independent-instances || bad _write_agy_home-independent-instances

# ==============================================================
# _write_claude_home_interactive
#
# reviewer_workdir_i below stands in for the caller-supplied
# reviewer_workdir -- a real directory, distinct from any worktree path,
# so the hasTrustDialogAccepted key can be checked against its own actual
# absolute path rather than a hardcoded string.
# ==============================================================

claude_home_i="$T/claude-home-interactive"
reviewer_workdir_i="$T/claude-workdir-interactive"
mkdir -p "$reviewer_workdir_i"
if _write_claude_home_interactive "$claude_home_i" "$reviewer_workdir_i"; then
  pass "_write_claude_home_interactive 回傳成功"
else
  bad "_write_claude_home_interactive 回傳非零"
fi

if [ -L "$claude_home_i/.claude/.credentials.json" ] \
  && [ "$(readlink "$claude_home_i/.claude/.credentials.json")" = "$HOME/.claude/.credentials.json" ]; then
  pass "_write_claude_home_interactive 的 credentials 符號連結指向正確目標"
else
  bad "_write_claude_home_interactive 的 credentials 符號連結不正確"
fi

ccj="$claude_home_i/.claude.json"
# The trust key lives at .projects["<abs path>"].hasTrustDialogAccepted, not
# at a top-level .hasTrustDialogAccepted map. Measured against claude
# 2.1.259 with a clean A/B: an isolated home carrying the top-level form
# left `herdr agent start` failing with agent_not_ready (the pane stopped on
# claude's own "Quick safety check" trust dialog), while the same home
# carrying the .projects form started cleanly. The top-level assertion this
# replaces passed for a shape claude never reads.
if [ -f "$ccj" ] && [ ! -L "$ccj" ] \
  && jq -e '.hasCompletedOnboarding == true' "$ccj" >/dev/null \
  && jq -e --arg cwd "$reviewer_workdir_i" '.projects[$cwd].hasTrustDialogAccepted == true' "$ccj" >/dev/null \
  && jq -e '.projects | length == 1' "$ccj" >/dev/null \
  && jq -e 'has("hasTrustDialogAccepted") | not' "$ccj" >/dev/null; then
  pass "_write_claude_home_interactive 寫出以 .projects[workdir] 記錄信任的 .claude.json"
else
  bad "_write_claude_home_interactive 的 .claude.json 內容不正確: $(cat "$ccj" 2>/dev/null)"
fi

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -s "$claude_home_i/.zshrc" ] && pass "_write_claude_home_interactive 建立非空 .zshrc" || bad "_write_claude_home_interactive 未建立非空 .zshrc"

# ==============================================================
# _write_env_scrubbing_zshrc
#
# 白名單式環境隔離：pane 繼承的是 herdr 背景服務行程的環境，使用者
# shell 啟動檔 export 的變數會原封進到每個 pane（實測，值以雜湊比對
# 確認逐位元組相同）。herdr 的 --env 只能設值不能移除變數，所以清理
# 靠這個寫進隔離家目錄的 .zshrc 完成。
# ==============================================================

ENVSCRUB="$T/envscrub/.zshrc"
mkdir -p "$T/envscrub"
if _write_env_scrubbing_zshrc "$ENVSCRUB"; then
  pass "_write_env_scrubbing_zshrc 回傳成功"
else
  bad "_write_env_scrubbing_zshrc 回傳非零"
fi

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -s "$ENVSCRUB" ] && pass "_write_env_scrubbing_zshrc 寫出非空檔案" || bad "_write_env_scrubbing_zshrc 寫出空檔案"

# 白名單每一項都必須出現在產生的清單裡
envscrub_missing=""
for v in PATH HOME SHELL TERM TERMINFO COLORTERM LANG LC_ALL USER LOGNAME \
         PWD OLDPWD TMPDIR XDG_RUNTIME_DIR DISPLAY WAYLAND_DISPLAY \
         DBUS_SESSION_BUS_ADDRESS HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID \
         HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH SSH_AUTH_SOCK \
         ZDOTDIR SHLVL; do
  grep -qw -- "$v" "$ENVSCRUB" || envscrub_missing="$envscrub_missing $v"
done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -z "$envscrub_missing" ] && pass "_write_env_scrubbing_zshrc 白名單完整" || bad "_write_env_scrubbing_zshrc 白名單缺項:$envscrub_missing"

# 已知的機密變數名不得出現在檔案裡——清理靠白名單，不是靠列舉機密
case "$(cat "$ENVSCRUB")" in
  *CIRCLECI*|*FIGMA*|*WEBHOOK*|*API_KEY*) bad "_write_env_scrubbing_zshrc 不該列舉機密變數名" ;;
  *) pass "_write_env_scrubbing_zshrc 未列舉任何機密變數名" ;;
esac

# 實際行為：在一個帶有偽造機密變數的 zsh 中 source 它，機密應消失、白名單項應留下
if command -v zsh >/dev/null 2>&1; then
  envscrub_out="$(FAKE_SECRET_TOKEN=leakme HOME="$T/envscrub" zsh -c \
    "source '$ENVSCRUB'; printf 'SECRET=[%s] PATH_SET=[%s]\n' \"\$FAKE_SECRET_TOKEN\" \"\${PATH:+yes}\"" 2>/dev/null)"
  case "$envscrub_out" in
    'SECRET=[] PATH_SET=[yes]') pass "_write_env_scrubbing_zshrc 清掉非白名單變數且保留白名單變數" ;;
    *) bad "_write_env_scrubbing_zshrc 行為不符: $envscrub_out" ;;
  esac
else
  pass "_write_env_scrubbing_zshrc 行為測試略過（本機無 zsh）"
fi

# ==============================================================
# _write_codex_home_interactive
# ==============================================================

codex_home_i="$T/codex-home-interactive"
codex_workdir_i="$T/codex-workdir-interactive"
mkdir -p "$codex_workdir_i"
if _write_codex_home_interactive "$codex_home_i" "$codex_workdir_i"; then
  pass "_write_codex_home_interactive 回傳成功"
else
  bad "_write_codex_home_interactive 回傳非零"
fi

if [ -L "$codex_home_i/.codex/auth.json" ] \
  && [ "$(readlink "$codex_home_i/.codex/auth.json")" = "$HOME/.codex/auth.json" ]; then
  pass "_write_codex_home_interactive 的 auth.json 符號連結指向正確目標"
else
  bad "_write_codex_home_interactive 的 auth.json 符號連結不正確"
fi

cct="$codex_home_i/.codex/config.toml"
expected_cct="$(printf '[projects."%s"]\ntrust_level = "trusted"\n' "$codex_workdir_i")"
if [ -f "$cct" ] && [ "$(cat "$cct")" = "$expected_cct" ]; then
  pass "_write_codex_home_interactive 寫出正確的 config.toml"
else
  bad "_write_codex_home_interactive 的 config.toml 內容不正確: $(cat "$cct" 2>/dev/null)"
fi

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -s "$codex_home_i/.zshrc" ] && pass "_write_codex_home_interactive 建立非空 .zshrc" || bad "_write_codex_home_interactive 未建立非空 .zshrc"

# ==============================================================
# _write_opencode_home_interactive
# ==============================================================

opencode_home_i="$T/opencode-home-interactive"
if _write_opencode_home_interactive "$opencode_home_i"; then
  pass "_write_opencode_home_interactive 回傳成功"
else
  bad "_write_opencode_home_interactive 回傳非零"
fi

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -s "$opencode_home_i/.zshrc" ] && pass "_write_opencode_home_interactive 建立非空 .zshrc" || bad "_write_opencode_home_interactive 未建立非空 .zshrc"

# ==============================================================
# _write_agy_home_interactive
#
# agy_workdir_i and agy_worktree_i are deliberately two different
# directories (not aliases of the same path), the same way cmd_prepare's
# real reviewer_workdir and worktree_dir are -- otherwise a bug that swaps
# the two arguments in trustedWorkspaces or the -C rule could not be told
# apart from correct behavior.
# ==============================================================

agy_home_i="$T/agy-home-interactive"
agy_workdir_i="$T/agy-workdir-interactive"
agy_worktree_i="$T/agy-worktree-interactive"
mkdir -p "$agy_workdir_i" "$agy_worktree_i"
if _write_agy_home_interactive "$agy_home_i" "$agy_workdir_i" "$agy_worktree_i"; then
  pass "_write_agy_home_interactive 回傳成功"
else
  bad "_write_agy_home_interactive 回傳非零"
fi

si="$agy_home_i/.gemini/antigravity-cli/settings.json"
if [ -f "$si" ] \
  && jq -e '.permissions.allow | index("command(git diff)")' "$si" >/dev/null \
  && jq -e --arg rule "command(git -C $agy_worktree_i diff)" \
       '.permissions.allow | index($rule)' "$si" >/dev/null \
  && jq -e '.permissions.allow | length == 2' "$si" >/dev/null; then
  pass "_write_agy_home_interactive 的允許規則同時含 git diff 與帶路徑的 -C 規則"
else
  bad "_write_agy_home_interactive 的允許規則不正確: $(cat "$si" 2>/dev/null)"
fi

if jq -e --arg w "$agy_workdir_i" '.trustedWorkspaces == [$w]' "$si" >/dev/null 2>&1; then
  pass "_write_agy_home_interactive 的 trustedWorkspaces 指向 reviewer_workdir"
else
  bad "_write_agy_home_interactive 的 trustedWorkspaces 不正確: $(cat "$si" 2>/dev/null)"
fi

if jq -e --arg w "$agy_worktree_i" '(.trustedWorkspaces | index($w)) == null' "$si" >/dev/null 2>&1; then
  pass "_write_agy_home_interactive 的 trustedWorkspaces 不含 worktree_dir"
else
  bad "_write_agy_home_interactive 的 trustedWorkspaces 不應含 worktree_dir: $(cat "$si" 2>/dev/null)"
fi

ob="$agy_home_i/.gemini/antigravity-cli/cache/onboarding.json"
if [ -f "$ob" ] && jq -e '.onboardingComplete == true' "$ob" >/dev/null 2>&1; then
  pass "_write_agy_home_interactive 寫出 onboardingComplete 為 true 的 onboarding.json"
else
  bad "_write_agy_home_interactive 未正確寫出 onboarding.json: $(cat "$ob" 2>/dev/null)"
fi

# 刻意差異，不是遺漏：實測結論是互動模式不需要頂層 .gemini/settings.json
# 的 auth-type 標記（見 _write_agy_home_interactive 自己的文件字串）。
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -e "$agy_home_i/.gemini/settings.json" ] && pass "_write_agy_home_interactive 不寫頂層 .gemini/settings.json" || bad "_write_agy_home_interactive 不應寫頂層 .gemini/settings.json"

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -s "$agy_home_i/.zshrc" ] && pass "_write_agy_home_interactive 建立非空 .zshrc" || bad "_write_agy_home_interactive 未建立非空 .zshrc"

# ==============================================================
# launch_reviewer_interactive
#
# Stub herdr into the *existing* STUB_BIN (not a dedicated recording dir
# the way LAUNCH_STUB_BIN below is for claude/codex/opencode/agy) --
# launch_reviewer_interactive itself never execs claude/codex/opencode/agy
# directly, only herdr; herdr is what starts those inside their own pane.
# A real herdr binary is genuinely installed on dev machines that run this
# suite (unlike the four AI CLIs, which may or may not be), so this section
# is exactly the kind of PATH leak assert_cli_stub_only exists to catch:
# without it, a missing/renamed stub here would silently fall through to a
# real herdr trying to control a real terminal pane.
#
# The stub itself is not built with `set -euo pipefail` (unlike the shared
# `gh` stub above) -- it follows the LAUNCH_STUB_BIN recording stubs'
# pattern instead, since it is structurally the same kind of thing: record
# argv/text under HERDR_RECORD_DIR, then return a controllable exit code.
# `agent start` argv is keyed by the --kind value found in its own argv
# (parsed by this stub itself), not by a name supplied by the caller,
# since every cli's `agent start` call goes through this one script -- there
# is no separate "claude" binary on PATH the way LAUNCH_STUB_BIN gives each
# cli its own recording file via $0's basename. `agent prompt`'s TARGET
# argument (position 3) becomes part of its own recording filename for the
# same reason, which doubles as this suite's check that TARGET really is
# the pane id and not the `<cli>-<digest>` agent name `agent start` was given
# -- a wrong TARGET would record under a filename these tests never read
# back from, so the assertion would fail by absence rather than a specific
# check having to be written for it.
#
# Task 4 added a second `agent prompt` recording, alongside the
# pane-id-keyed one above: agent-prompt.<kind>.argv, holding every arg
# `agent prompt` was called with (not just TEXT). <kind> is looked up from
# a pane-kind.<pane_id> file this stub's own `agent start` branch writes
# first, since `agent prompt`'s own argv carries no cli kind of its own --
# only the pane id. This is what task 4's claude-branch assertions below
# read to confirm claude's `agent prompt` call carries the fixed start
# signal, not the contract file's content.
#
# HERDR_STUB_PANE_EMPTY_READS controls how many of `pane read`'s own
# leading calls, *for one given pane id* (tracked via a per-pane-id counter
# file, since the four per-cli calls below all read the same script and
# would otherwise collide on a single shared counter), come back empty
# before a real one returns HERDR_STUB_PANE_CONTENT. Left at its default
# (0) for the four per-cli flag-assertion calls below, so their first read
# already succeeds; overridden per-call further down to exercise the
# retry-then-succeed and still-empty-after-retry paths this function's own
# docstring documents.
# ==============================================================

LRI_ROOT="$T/launch-reviewer-interactive-fixture"
LRI_WT="$(_make_worktree_fixture "$LRI_ROOT")"
LRI_RECORD_DIR="$LRI_ROOT/records"
mkdir -p "$LRI_RECORD_DIR"

cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
agent)
  case "${2:-}" in
  start)
    # Real herdr validates the agent name before it ever resolves --pane:
    # probed against herdr 0.8.2, an illegal name returns
    # invalid_agent_name even when --pane names a pane that does not
    # exist, while a legal name gets all the way to agent_pane_not_found.
    # This stub enforces the same rule in the same order, so a caller that
    # composes an illegal name fails here instead of recording argv and
    # going green. The message text is a paraphrase; the error code is not.
    name="${3:-}"
    if ! [[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
      printf '{"error":{"code":"invalid_agent_name","message":"agent name must match [a-z][a-z0-9_-]{0,31}"},"id":"cli:agent:start"}\n' >&2
      exit 1
    fi
    kind=""
    pane_id=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--kind" ]; then kind="$a"; fi
      if [ "$prev" = "--pane" ]; then pane_id="$a"; fi
      prev="$a"
    done
    record="$HERDR_RECORD_DIR/agent-start.$kind.argv"
    : > "$record"
    for a in "$@"; do printf '%s\n' "$a" >> "$record"; done
    # Records which cli kind owns this pane id, so a later `agent prompt`
    # call against the same pane id (which carries no kind of its own --
    # see this case's own docstring) can still be recorded under a
    # cli-keyed filename (agent-prompt.<kind>.argv) alongside the existing
    # pane-id-keyed one below.
    [ -n "$pane_id" ] && printf '%s' "$kind" > "$HERDR_RECORD_DIR/pane-kind.$pane_id"
    if [ "${HERDR_STUB_START_OK:-1}" = "1" ]; then exit 0; else exit 1; fi
    ;;
  prompt)
    target="$3"
    text="${4:-}"
    printf '%s' "$text" > "$HERDR_RECORD_DIR/agent-prompt.$target.text"
    prompt_kind="$(cat "$HERDR_RECORD_DIR/pane-kind.$target" 2>/dev/null)"
    if [ -n "$prompt_kind" ]; then
      prompt_record="$HERDR_RECORD_DIR/agent-prompt.$prompt_kind.argv"
      : > "$prompt_record"
      for a in "$@"; do printf '%s\n' "$a" >> "$prompt_record"; done
    fi
    if [ "${HERDR_STUB_PROMPT_OK:-1}" = "1" ]; then exit 0; else exit 1; fi
    ;;
  esac
  ;;
pane)
  case "${2:-}" in
  read)
    pane_id="$3"
    count_file="$HERDR_RECORD_DIR/pane-read-count.$pane_id"
    n=0
    if [ -f "$count_file" ]; then n="$(cat "$count_file")"; fi
    n=$((n + 1))
    printf '%s' "$n" > "$count_file"
    if [ "$n" -le "${HERDR_STUB_PANE_EMPTY_READS:-0}" ]; then
      exit 0
    fi
    printf '%s' "${HERDR_STUB_PANE_CONTENT:-pane-ready-marker}"
    exit 0
    ;;
  esac
  ;;
esac
exit 1
STUB
chmod +x "$STUB_BIN/herdr"

export PATH="$STUB_BIN:$saved_path"
export HERDR_RECORD_DIR="$LRI_RECORD_DIR"
assert_cli_stub_only "$PATH" "$STUB_BIN" herdr

# --- claude: --disallowedTools names only WebFetch; --permission-mode is
# passed as auto; no -p; and, the assertion this task exists to protect, no
# Edit/Write/NotebookEdit on --disallowedTools -- any of those three
# appearing would mean this branch reused the now-removed headless
# launcher's deny list, leaving this reviewer unable to write review.md at
# all ---

lri_claude_workdir="$LRI_ROOT/reviewers/claude/workdir"
lri_claude_home="$LRI_ROOT/reviewers/claude/home"
mkdir -p "$lri_claude_workdir" "$lri_claude_home"
printf 'claude review prompt' > "$LRI_ROOT/claude.prompt"

lri_claude_out="$(launch_reviewer_interactive claude w14:pZ "$LRI_WT" \
  "$lri_claude_workdir" "$lri_claude_home" "$LRI_ROOT/claude.prompt")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$lri_claude_out" = "$lri_claude_workdir/review.md" ] && pass launch-reviewer-interactive-claude-prints-output-file || bad "launch-reviewer-interactive-claude-prints-output-file: $lri_claude_out"

claude_start_argv="$LRI_RECORD_DIR/agent-start.claude.argv"
mapfile -t lri_claude_argv < "$claude_start_argv"
# Regression guard: herdr's own --kind already resolves the executable to
# run (its --help names --kind "Supported agent kind and canonical
# executable"), so the token right after `--` must be claude's own first
# flag, not "claude" a second time -- a real claude binary would silently
# swallow that duplicate as a positional prompt argument instead of
# erroring (see this section's own herdr stub docstring).
lri_claude_dashdash_idx=-1
for idx in "${!lri_claude_argv[@]}"; do
  [ "${lri_claude_argv[$idx]}" = "--" ] && lri_claude_dashdash_idx=$idx
done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
lri_claude_first_arg="${lri_claude_argv[$((lri_claude_dashdash_idx + 1))]:-}"
# Asserts the invariant (the first token after `--` is one of claude's own
# flags, never the executable name again) rather than pinning which flag
# happens to come first, so adding or reordering claude's flags does not
# make this regression guard fail for the wrong reason.
[ "$lri_claude_dashdash_idx" -ge 0 ] && [ "$lri_claude_first_arg" != "claude" ] && [ "${lri_claude_first_arg#-}" != "$lri_claude_first_arg" ] && pass launch-reviewer-interactive-claude-no-duplicate-executable-name || bad "launch-reviewer-interactive-claude-no-duplicate-executable-name: $(cat "$claude_start_argv")"
case "$(cat "$claude_start_argv")" in
  *'--disallowedTools'*'WebFetch'*) pass launch-reviewer-interactive-claude-disallows-webfetch ;;
  *) bad "launch-reviewer-interactive-claude-disallows-webfetch: $(cat "$claude_start_argv")" ;;
esac
# Checked as an exact argv token, not a substring of the joined argv line:
# "--permission-mode" itself contains the two characters "-p", which a
# naive substring check against the whole line would false-positive on.
lri_claude_dash_p_found=0
for a in "${lri_claude_argv[@]}"; do
  case "$a" in
    -p) lri_claude_dash_p_found=1 ;;
  esac
done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$lri_claude_dash_p_found" -eq 0 ] && pass launch-reviewer-interactive-claude-no-print-flag || bad launch-reviewer-interactive-claude-no-print-flag
# --permission-mode auto must be passed explicitly. The earlier assertion
# here demanded its absence, on a probe reading that claude's status bar
# showed "auto mode on" under `agent start` with the flag omitted. That
# reading was overturned by measurement against claude 2.1.259: with the
# flag omitted, writing review.md inside the reviewer's own cwd raised a
# Create-file approval dialog and herdr reported agent_status=blocked;
# with --permission-mode auto passed, the same write completed unattended
# in 5s. Checked as adjacent argv tokens, not as a substring of the joined
# line, for the same reason the -p check above is.
lri_claude_perm_mode_ok=0
for idx in "${!lri_claude_argv[@]}"; do
  if [ "${lri_claude_argv[$idx]}" = "--permission-mode" ] \
    && [ "${lri_claude_argv[$((idx + 1))]:-}" = "auto" ]; then
    lri_claude_perm_mode_ok=1
  fi
done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$lri_claude_perm_mode_ok" -eq 1 ] && pass launch-reviewer-interactive-claude-permission-mode-auto || bad "launch-reviewer-interactive-claude-permission-mode-auto: $(cat "$claude_start_argv")"
case "$(cat "$claude_start_argv")" in
  *'Edit'*|*'Write'*) bad "launch-reviewer-interactive-claude-write-not-disallowed: $(cat "$claude_start_argv")" ;;
  *) pass launch-reviewer-interactive-claude-write-not-disallowed ;;
esac

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -f "$LRI_ROOT/.git-status-before-claude" ] && pass launch-reviewer-interactive-claude-records-before-snapshot-keyed-by-cli-name || bad launch-reviewer-interactive-claude-records-before-snapshot-keyed-by-cli-name
# Since task 4, claude's own `agent prompt` call carries the fixed
# "開始" start signal, not the prompt file's content (see this function's
# own claude branch) -- this checks for that fixed signal now, in place
# of the "claude review prompt" prompt-file content it checked for before
# task 4. Still targets the pane id, not the `<cli>-<digest>` agent name,
# and still real (non-empty) content.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$(cat "$LRI_RECORD_DIR/agent-prompt.w14:pZ.text" 2>/dev/null)" = "開始" ] && pass launch-reviewer-interactive-claude-prompt-targets-pane-id-with-real-content || bad "launch-reviewer-interactive-claude-prompt-targets-pane-id-with-real-content: $(cat "$LRI_RECORD_DIR/agent-prompt.w14:pZ.text" 2>/dev/null)"

# claude 的契約走 --append-system-prompt-file，不再經由 agent prompt 的位置引數。
# 附加型（append）已做過兩次功能探測，皆成功；取代型（--system-prompt-file）
# 只確認旗標存在、未做功能探測，不在採用範圍。
lri_claude_syspromptfile_ok=0
for idx in "${!lri_claude_argv[@]}"; do
  if [ "${lri_claude_argv[$idx]}" = "--append-system-prompt-file" ] \
    && [ "${lri_claude_argv[$((idx + 1))]:-}" = "$LRI_ROOT/claude.prompt" ]; then
    lri_claude_syspromptfile_ok=1
  fi
done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$lri_claude_syspromptfile_ok" -eq 1 ] && pass launch-reviewer-interactive-claude-system-prompt-file || bad "launch-reviewer-interactive-claude-system-prompt-file: $(cat "$claude_start_argv")"

# 取代型不得被使用
case "$(cat "$claude_start_argv")" in
  *'--system-prompt-file'*) bad "launch-reviewer-interactive-claude-no-replacing-system-prompt" ;;
  *) pass launch-reviewer-interactive-claude-no-replacing-system-prompt ;;
esac

# agent prompt 送出的內容不得是契約全文
lri_claude_prompt_text="$(cat "$LRI_RECORD_DIR/agent-prompt.claude.argv" 2>/dev/null)"
case "$lri_claude_prompt_text" in
  *'claude review prompt'*) bad "launch-reviewer-interactive-claude-prompt-not-contract: 契約全文仍走 agent prompt" ;;
  '') bad "launch-reviewer-interactive-claude-prompt-not-contract: 沒有記錄到 agent prompt 呼叫" ;;
  *) pass launch-reviewer-interactive-claude-prompt-not-contract ;;
esac

# --- codex: no -s (the sandbox flag was the now-removed headless
# launcher's own concern; herdr's own --pane already scopes this to one
# interactive pane) ---

lri_codex_workdir="$LRI_ROOT/reviewers/codex/workdir"
lri_codex_home="$LRI_ROOT/reviewers/codex/home"
mkdir -p "$lri_codex_workdir" "$lri_codex_home"
printf 'codex review prompt' > "$LRI_ROOT/codex.prompt"

lri_codex_out="$(launch_reviewer_interactive codex w1X:pA "$LRI_WT" \
  "$lri_codex_workdir" "$lri_codex_home" "$LRI_ROOT/codex.prompt")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$lri_codex_out" = "$lri_codex_workdir/review.md" ] && pass launch-reviewer-interactive-codex-prints-output-file || bad "launch-reviewer-interactive-codex-prints-output-file: $lri_codex_out"

codex_start_argv="$LRI_RECORD_DIR/agent-start.codex.argv"
mapfile -t lri_codex_argv < "$codex_start_argv"
# Regression guard: the token right after `--` must be codex's own first
# flag, not "codex" a second time (see the claude section above for why
# this is checked explicitly rather than left to the flag checks below,
# none of which would notice a leading duplicate).
lri_codex_dashdash_idx=-1
for idx in "${!lri_codex_argv[@]}"; do
  [ "${lri_codex_argv[$idx]}" = "--" ] && lri_codex_dashdash_idx=$idx
done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$lri_codex_dashdash_idx" -ge 0 ] && [ "${lri_codex_argv[$((lri_codex_dashdash_idx + 1))]:-}" = "-C" ] && pass launch-reviewer-interactive-codex-no-duplicate-executable-name || bad "launch-reviewer-interactive-codex-no-duplicate-executable-name: $(cat "$codex_start_argv")"
lri_codex_dash_s_found=0
for a in "${lri_codex_argv[@]}"; do
  case "$a" in
    -s) lri_codex_dash_s_found=1 ;;
  esac
done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$lri_codex_dash_s_found" -eq 0 ] && pass launch-reviewer-interactive-codex-no-sandbox-flag || bad launch-reviewer-interactive-codex-no-sandbox-flag
found=0
for idx in "${!lri_codex_argv[@]}"; do
  if [ "${lri_codex_argv[$idx]}" = "-C" ] && [ "${lri_codex_argv[$((idx + 1))]:-}" = "$lri_codex_workdir" ]; then
    found=1
  fi
done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$found" -eq 1 ] && pass launch-reviewer-interactive-codex-workdir-flag || bad launch-reviewer-interactive-codex-workdir-flag

# --- opencode: no `run`; no `--dir` (dropped in favour of the positional
# project-path argument -- the top-level command has no --dir at all) ---

lri_opencode_workdir="$LRI_ROOT/reviewers/opencode/workdir"
lri_opencode_home="$LRI_ROOT/reviewers/opencode/home"
mkdir -p "$lri_opencode_workdir" "$lri_opencode_home"
printf 'opencode review prompt' > "$LRI_ROOT/opencode.prompt"

lri_opencode_out="$(launch_reviewer_interactive opencode w2:p12 "$LRI_WT" \
  "$lri_opencode_workdir" "$lri_opencode_home" "$LRI_ROOT/opencode.prompt")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$lri_opencode_out" = "$lri_opencode_workdir/review.md" ] && pass launch-reviewer-interactive-opencode-prints-output-file || bad "launch-reviewer-interactive-opencode-prints-output-file: $lri_opencode_out"

opencode_start_argv="$LRI_RECORD_DIR/agent-start.opencode.argv"
mapfile -t lri_opencode_argv < "$opencode_start_argv"
# Regression guard: the token right after `--` must be the positional
# workdir itself, not "opencode" a second time -- a real opencode binary
# would silently swallow that duplicate as its own project-directory
# positional argument instead of erroring (see the claude section above
# for why this needs its own explicit check).
lri_opencode_dashdash_idx=-1
for idx in "${!lri_opencode_argv[@]}"; do
  [ "${lri_opencode_argv[$idx]}" = "--" ] && lri_opencode_dashdash_idx=$idx
done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$lri_opencode_dashdash_idx" -ge 0 ] && [ "${lri_opencode_argv[$((lri_opencode_dashdash_idx + 1))]:-}" = "$lri_opencode_workdir" ] && pass launch-reviewer-interactive-opencode-no-duplicate-executable-name || bad "launch-reviewer-interactive-opencode-no-duplicate-executable-name: $(cat "$opencode_start_argv")"
lri_opencode_run_found=0
lri_opencode_dir_found=0
for a in "${lri_opencode_argv[@]}"; do
  case "$a" in
    run) lri_opencode_run_found=1 ;;
    --dir) lri_opencode_dir_found=1 ;;
  esac
done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$lri_opencode_run_found" -eq 0 ] && pass launch-reviewer-interactive-opencode-no-run-subcommand || bad launch-reviewer-interactive-opencode-no-run-subcommand
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$lri_opencode_dir_found" -eq 0 ] && pass launch-reviewer-interactive-opencode-no-dir-flag || bad launch-reviewer-interactive-opencode-no-dir-flag
found=0
for a in "${lri_opencode_argv[@]}"; do
  [ "$a" = "$lri_opencode_workdir" ] && found=1
done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$found" -eq 1 ] && pass launch-reviewer-interactive-opencode-positional-workdir || bad launch-reviewer-interactive-opencode-positional-workdir

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -s "$lri_opencode_home/opencode-permission.json" ] && pass launch-reviewer-interactive-opencode-writes-permission-config || bad launch-reviewer-interactive-opencode-writes-permission-config
case "$(cat "$lri_opencode_home/opencode-permission.json" 2>/dev/null)" in
  *'"edit": "deny"'*) bad "launch-reviewer-interactive-opencode-permission-config-allows-edit: reviewer would be unable to write review.md" ;;
  *) pass launch-reviewer-interactive-opencode-permission-config-allows-edit ;;
esac

# --- agy: no --print-timeout (no interactive-mode equivalent exists);
# --add-dir names only reviewer_workdir, never the worktree path too ---

lri_agy_workdir="$LRI_ROOT/reviewers/agy/workdir"
lri_agy_home="$LRI_ROOT/reviewers/agy/home"
mkdir -p "$lri_agy_workdir" "$lri_agy_home"
printf 'agy review prompt' > "$LRI_ROOT/agy.prompt"

lri_agy_out="$(launch_reviewer_interactive agy w28:p1 "$LRI_WT" \
  "$lri_agy_workdir" "$lri_agy_home" "$LRI_ROOT/agy.prompt")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$lri_agy_out" = "$lri_agy_workdir/review.md" ] && pass launch-reviewer-interactive-agy-prints-output-file || bad "launch-reviewer-interactive-agy-prints-output-file: $lri_agy_out"

agy_start_argv="$LRI_RECORD_DIR/agent-start.agy.argv"
mapfile -t lri_agy_argv < "$agy_start_argv"
# Regression guard: the token right after `--` must be agy's own first
# flag, not "agy" a second time -- unlike the other three CLIs, a real agy
# binary rejects this outright ("unexpected argument \"agy\"") instead of
# silently swallowing it, which is the failure this exact assertion
# reproduces against the stub (see the claude section above for why this
# needs its own explicit check).
lri_agy_dashdash_idx=-1
for idx in "${!lri_agy_argv[@]}"; do
  [ "${lri_agy_argv[$idx]}" = "--" ] && lri_agy_dashdash_idx=$idx
done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$lri_agy_dashdash_idx" -ge 0 ] && [ "${lri_agy_argv[$((lri_agy_dashdash_idx + 1))]:-}" = "--add-dir" ] && pass launch-reviewer-interactive-agy-no-duplicate-executable-name || bad "launch-reviewer-interactive-agy-no-duplicate-executable-name: $(cat "$agy_start_argv")"
case "$(cat "$agy_start_argv")" in
  *'--print-timeout'*) bad "launch-reviewer-interactive-agy-no-print-timeout: $(cat "$agy_start_argv")" ;;
  *) pass launch-reviewer-interactive-agy-no-print-timeout ;;
esac
add_dir_values=()
for idx in "${!lri_agy_argv[@]}"; do
  if [ "${lri_agy_argv[$idx]}" = "--add-dir" ]; then
    add_dir_values+=("${lri_agy_argv[$((idx + 1))]:-}")
  fi
done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "${#add_dir_values[@]}" -eq 1 ] && [ "${add_dir_values[0]}" = "$lri_agy_workdir" ] && pass launch-reviewer-interactive-agy-add-dir-reviewer-workdir-only || bad "launch-reviewer-interactive-agy-add-dir-reviewer-workdir-only: ${add_dir_values[*]:-<none>}"
case "$(cat "$agy_start_argv")" in
  *"$LRI_WT"*) bad "launch-reviewer-interactive-agy-add-dir-excludes-worktree: $(cat "$agy_start_argv")" ;;
  *) pass launch-reviewer-interactive-agy-add-dir-excludes-worktree ;;
esac

# --- pane readiness: a single empty read right after `agent start` is a
# known timing artifact (see this function's own docstring) -- one retry
# must be enough to reach the real content and still send the prompt ---

lri_retry_start="$(date -u +%s)"
lri_retry_out="$(HERDR_STUB_PANE_EMPTY_READS=1 launch_reviewer_interactive claude w14:pR "$LRI_WT" \
  "$lri_claude_workdir" "$lri_claude_home" "$LRI_ROOT/claude.prompt")"
lri_retry_elapsed=$(( $(date -u +%s) - lri_retry_start ))
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$lri_retry_out" = "$lri_claude_workdir/review.md" ] && pass launch-reviewer-interactive-pane-read-retry-then-succeeds || bad "launch-reviewer-interactive-pane-read-retry-then-succeeds: $lri_retry_out"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -f "$LRI_RECORD_DIR/agent-prompt.w14:pR.text" ] && pass launch-reviewer-interactive-pane-read-retry-prompt-still-sent || bad launch-reviewer-interactive-pane-read-retry-prompt-still-sent
# 缺陷回歸：兩次 `herdr pane read` 背靠背在毫秒內完成的話，這個重試根本
# 吸收不到「畫面還沒渲染完」的時間差（見這個函式自己文件對 `sleep 1` 的
# 說明）。這裡直接量測掛鐘時間，而不是只看重試最終有沒有成功，因為背靠
# 背重試在這個測試樁下也一樣會成功 -- 唯一能分辨兩者的是有沒有真的等過。
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$lri_retry_elapsed" -ge 1 ] && pass "launch-reviewer-interactive-pane-read-retry-actually-waits" || bad "launch-reviewer-interactive-pane-read-retry-actually-waits: 重試只花了 ${lri_retry_elapsed}s，兩次讀取之間沒有真的等待"

# --- pane readiness: still empty after the one retry is a real failure,
# not guessed past -- `agent prompt` must never be called in that case ---

if lri_neverready_out="$(HERDR_STUB_PANE_EMPTY_READS=99 launch_reviewer_interactive claude w14:pN "$LRI_WT" \
  "$lri_claude_workdir" "$lri_claude_home" "$LRI_ROOT/claude.prompt" 2>"$LRI_ROOT/neverready.stderr")"; then
  bad "launch-reviewer-interactive-pane-never-ready-rejected: printed $lri_neverready_out"
else
  pass launch-reviewer-interactive-pane-never-ready-rejected
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -f "$LRI_RECORD_DIR/agent-prompt.w14:pN.text" ] && pass launch-reviewer-interactive-pane-never-ready-no-prompt-sent || bad launch-reviewer-interactive-pane-never-ready-no-prompt-sent

# --- prompt size limit: reject before ever calling `agent prompt`, with
# both the actual size and the limit in the failure message ---

lri_oversized_bytes=$((PROMPT_BYTE_LIMIT + 1))
head -c "$lri_oversized_bytes" /dev/zero > "$LRI_ROOT/oversized.prompt"

if lri_oversized_out="$(launch_reviewer_interactive claude w14:pO "$LRI_WT" \
  "$lri_claude_workdir" "$lri_claude_home" "$LRI_ROOT/oversized.prompt" 2>"$LRI_ROOT/oversized.stderr")"; then
  bad "launch-reviewer-interactive-prompt-too-large-rejected: printed $lri_oversized_out"
else
  pass launch-reviewer-interactive-prompt-too-large-rejected
fi
lri_oversized_err="$(cat "$LRI_ROOT/oversized.stderr" 2>/dev/null)"
case "$lri_oversized_err" in
  *"$lri_oversized_bytes"*"$PROMPT_BYTE_LIMIT"*) pass launch-reviewer-interactive-prompt-too-large-message-has-both-sizes ;;
  *) bad "launch-reviewer-interactive-prompt-too-large-message-has-both-sizes: $lri_oversized_err" ;;
esac
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -f "$LRI_RECORD_DIR/agent-prompt.w14:pO.text" ] && pass launch-reviewer-interactive-prompt-too-large-no-prompt-sent || bad launch-reviewer-interactive-prompt-too-large-no-prompt-sent

# --- prompt file missing: reject explicitly, before ever calling `agent
# prompt` -- the exact silent-pass bug this section exists to catch. This
# function's only real caller (cmd_launch) invokes it as `if !
# launch_reviewer_interactive ...; then`, and that call shape is
# reproduced here (`if VAR="$(launch_reviewer_interactive ...)"; then`)
# for the same reason: bash exempts a function call from `set -e` for its
# entire duration when the call itself is an if/while/&&/|| condition, so
# a bare `wc -c < "$prompt_file"` redirection failure never tripped
# errexit in that exact caller context -- confirmed against a real bash
# before this function's own explicit `[ -r "$prompt_file" ]` guard was
# added. Without that guard, the failed substitution came back empty,
# `(( "" > PROMPT_BYTE_LIMIT ))` silently read the empty string as 0, and
# an empty prompt was submitted to herdr as if it were real. ---

if lri_missing_prompt_out="$(launch_reviewer_interactive claude w14:pM "$LRI_WT" \
  "$lri_claude_workdir" "$lri_claude_home" "$LRI_ROOT/does-not-exist.prompt" 2>"$LRI_ROOT/missing-prompt.stderr")"; then
  bad "launch-reviewer-interactive-missing-prompt-rejected: printed $lri_missing_prompt_out"
else
  pass launch-reviewer-interactive-missing-prompt-rejected
fi
lri_missing_prompt_err="$(cat "$LRI_ROOT/missing-prompt.stderr" 2>/dev/null)"
case "$lri_missing_prompt_err" in
  *"$LRI_ROOT/does-not-exist.prompt"*) pass launch-reviewer-interactive-missing-prompt-message-names-file ;;
  *) bad "launch-reviewer-interactive-missing-prompt-message-names-file: $lri_missing_prompt_err" ;;
esac
# The load-bearing assertion: prior to the explicit -r guard, this exact
# scenario reached `herdr agent prompt` and wrote an empty (0-byte) record
# here instead of never writing one at all -- absence of the file, not
# just an empty one, is what proves `agent prompt` was never called.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -f "$LRI_RECORD_DIR/agent-prompt.w14:pM.text" ] && pass launch-reviewer-interactive-missing-prompt-no-prompt-sent || bad "launch-reviewer-interactive-missing-prompt-no-prompt-sent: $(cat "$LRI_RECORD_DIR/agent-prompt.w14:pM.text" 2>/dev/null)"

unset HERDR_RECORD_DIR
export PATH="$saved_path"
# Remove the herdr stub itself, not just drop $STUB_BIN off PATH above:
# $STUB_BIN is reused by many fixtures below that put it back on PATH
# (e.g. "$STUB_BIN:$saved_path"), and a stub file left sitting in that
# directory would silently reactivate for every one of them -- exactly
# the leak that once let a herdr-calling fixture reach
# spawn_supervisor_interactive with no real reviewer ever writing a
# marker-terminated review.md, hanging its poll loop forever. Deleting
# the file here scopes it to this section only, the same way the
# PATH restore above already scopes $STUB_BIN itself.
rm -f "$STUB_BIN/herdr"

# ==============================================================
# _reap_stale_run_dirs
#
# A dead PID for the "stale" sibling is obtained by actually starting and
# waiting out a short-lived subprocess, not just picking a large constant
# -- guarantees it is genuinely free at the moment this runs, rather than
# risking collision with some unrelated real process that happens to
# still be using an arbitrarily-chosen PID number.
# ==============================================================

REAP_ROOT="$T/reap-fixture"
mkdir -p "$REAP_ROOT/remotes" "$REAP_ROOT/work"
git init -q -b main --bare "$REAP_ROOT/remotes/repo.git"
git init -q -b main "$REAP_ROOT/work"
(
  cd "$REAP_ROOT/work"
  git config user.email t@t.com
  git config user.name t
  printf 'base\n' > f.txt
  git add f.txt
  git commit -q -m base
  git remote add origin "$REAP_ROOT/remotes/repo.git"
  git push -q origin HEAD:refs/heads/main
  git checkout -q -b branch-a
  printf 'a\n' >> f.txt
  git commit -aq -m a
  git checkout -q -b branch-b main
  printf 'b\n' >> f.txt
  git commit -aq -m b
  git checkout -q -b branch-c main
  printf 'c\n' >> f.txt
  git commit -aq -m c
  git checkout -q -b branch-d main
  printf 'd\n' >> f.txt
  git commit -aq -m d
  git checkout -q main
)

( exit 0 ) & dead_pid=$!
wait "$dead_pid" 2>/dev/null || true

REAP_PR_ROOT="$REAP_ROOT/pr-review"
mkdir -p "$REAP_PR_ROOT"
REAP_CURRENT_BASE="$REAP_PR_ROOT/1-current-$$"
mkdir -p "$REAP_CURRENT_BASE"

REAP_STALE_BASE="$REAP_PR_ROOT/2-stale-$dead_pid"
mkdir -p "$REAP_STALE_BASE"
(cd "$REAP_ROOT/work" && git worktree add -q "$REAP_STALE_BASE/worktree" branch-a)
chmod -R a-w "$REAP_STALE_BASE/worktree"

REAP_ALIVE_BASE="$REAP_PR_ROOT/3-alive-$$"
mkdir -p "$REAP_ALIVE_BASE"
(cd "$REAP_ROOT/work" && git worktree add -q "$REAP_ALIVE_BASE/worktree" branch-b)
chmod -R a-w "$REAP_ALIVE_BASE/worktree"

(cd "$REAP_ROOT/work" && _reap_stale_run_dirs "$REAP_CURRENT_BASE")

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -e "$REAP_STALE_BASE/worktree" ] && pass reap-stale-run-dirs-removes-dead-worktree || bad reap-stale-run-dirs-removes-dead-worktree
# A sibling whose PID ($$, this very test script) is still very much
# alive must be left completely untouched.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -e "$REAP_ALIVE_BASE/worktree" ] && pass reap-stale-run-dirs-preserves-live-worktree || bad reap-stale-run-dirs-preserves-live-worktree
chmod -R u+w "$REAP_ALIVE_BASE/worktree" 2>/dev/null || true
(cd "$REAP_ROOT/work" && git worktree remove --force "$REAP_ALIVE_BASE/worktree") >/dev/null 2>&1 || true

# --- 缺陷 1: 兩階段拆分後，base_dir/分支名尾端的 PID 是 cmd_prepare() 自
# 己的行程編號，prepare 一返回就死了，但 reviewer 還在 herdr pane 裡跑。
# 這裡直接重現那個形狀：trailing PID 已死（不是 $$），但 .supervisor.pid
# 指向一個貨真價實存活的行程 -- 此時絕不能被回收，不論 trailing PID 死
# 活。用背景 sleep 行程的 PID 而非 $$ 本身，證明判準真的是讀
# .supervisor.pid 的內容，不是巧合命中測試腳本自己的 PID。---
sleep 30 & REAP_SUPERVISOR_ALIVE_PID=$!

REAP_SUPERVISED_BASE="$REAP_PR_ROOT/4-supervised-$dead_pid"
mkdir -p "$REAP_SUPERVISED_BASE"
(cd "$REAP_ROOT/work" && git worktree add -q "$REAP_SUPERVISED_BASE/worktree" branch-c)
chmod -R a-w "$REAP_SUPERVISED_BASE/worktree"
printf '%s\n' "$REAP_SUPERVISOR_ALIVE_PID" > "$REAP_SUPERVISED_BASE/.supervisor.pid"

(cd "$REAP_ROOT/work" && _reap_stale_run_dirs "$REAP_CURRENT_BASE")

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -e "$REAP_SUPERVISED_BASE/worktree" ] && pass "reap-stale-run-dirs-live-supervisor-pid-overrides-dead-trailing-pid" \
  || bad "reap-stale-run-dirs-live-supervisor-pid-overrides-dead-trailing-pid: worktree 仍被回收，即使 .supervisor.pid 存活"

kill "$REAP_SUPERVISOR_ALIVE_PID" 2>/dev/null || true
wait "$REAP_SUPERVISOR_ALIVE_PID" 2>/dev/null || true
chmod -R u+w "$REAP_SUPERVISED_BASE/worktree" 2>/dev/null || true
(cd "$REAP_ROOT/work" && git worktree remove --force "$REAP_SUPERVISED_BASE/worktree") >/dev/null 2>&1 || true

# --- 缺陷 1 的空窗：cmd_prepare 已返回（trailing PID 已死）、
# cmd_launch 的 spawn_supervisor_interactive 還沒起來（沒有
# .supervisor.pid），但 .prepared-at 還很新鮮 -- 落在
# RUN_DIR_STALE_GRACE_SECONDS 的寬限期內，同樣不得回收。---
REAP_GAP_BASE="$REAP_PR_ROOT/5-gap-$dead_pid"
mkdir -p "$REAP_GAP_BASE"
(cd "$REAP_ROOT/work" && git worktree add -q "$REAP_GAP_BASE/worktree" branch-d)
chmod -R a-w "$REAP_GAP_BASE/worktree"
date -u +%s > "$REAP_GAP_BASE/.prepared-at"

(cd "$REAP_ROOT/work" && _reap_stale_run_dirs "$REAP_CURRENT_BASE")

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -e "$REAP_GAP_BASE/worktree" ] && pass "reap-stale-run-dirs-fresh-prepared-at-within-grace-preserves-worktree" \
  || bad "reap-stale-run-dirs-fresh-prepared-at-within-grace-preserves-worktree: worktree 在寬限期內就被回收了"

# --- 同一個空窗形狀，但 .prepared-at 已經過了寬限期：必須落回原本的
# trailing-PID 檢查，照舊被回收 -- 這條保住的是「準備了卻從未啟動」的
# 執行目錄終究會被下一次執行清掉的既有保證（見 RUN_DIR_STALE_GRACE_
# SECONDS 自己的文件）。branch-d 這時已經被上面那個案例的 worktree
# 佔用，另開一個獨立分支避免撞名。---
(cd "$REAP_ROOT/work" && git branch branch-e main)
REAP_EXPIRED_BASE="$REAP_PR_ROOT/6-expired-$dead_pid"
mkdir -p "$REAP_EXPIRED_BASE"
(cd "$REAP_ROOT/work" && git worktree add -q "$REAP_EXPIRED_BASE/worktree" branch-e)
chmod -R a-w "$REAP_EXPIRED_BASE/worktree"
printf '%s\n' "$(( $(date -u +%s) - RUN_DIR_STALE_GRACE_SECONDS - 60 ))" > "$REAP_EXPIRED_BASE/.prepared-at"

(cd "$REAP_ROOT/work" && _reap_stale_run_dirs "$REAP_CURRENT_BASE")

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -e "$REAP_EXPIRED_BASE/worktree" ] && pass "reap-stale-run-dirs-expired-prepared-at-falls-back-to-dead-pid-reap" \
  || bad "reap-stale-run-dirs-expired-prepared-at-falls-back-to-dead-pid-reap: 過了寬限期仍未回收"

chmod -R u+w "$REAP_GAP_BASE/worktree" 2>/dev/null || true
(cd "$REAP_ROOT/work" && git worktree remove --force "$REAP_GAP_BASE/worktree") >/dev/null 2>&1 || true

# ==============================================================
# _extract_review_content
# ==============================================================

EXTRACT_FIXTURE_DIR="$T/extract-fixture"
mkdir -p "$EXTRACT_FIXTURE_DIR"

cat > "$EXTRACT_FIXTURE_DIR/good.log" <<'LOGEOF'
some noise before the marker
===PR-REVIEW-BY-MULTI-AGENTS-BEGIN===
line one of the review
line two of the review
===PR-REVIEW-BY-MULTI-AGENTS-END===
some noise after the marker
LOGEOF

out="$(_extract_review_content "$EXTRACT_FIXTURE_DIR/good.log")"
expected=$'line one of the review\nline two of the review'
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$out" = "$expected" ] && pass extract-review-content-happy-path || bad extract-review-content-happy-path

cat > "$EXTRACT_FIXTURE_DIR/no-begin.log" <<'LOGEOF'
no begin marker anywhere in here
===PR-REVIEW-BY-MULTI-AGENTS-END===
LOGEOF
if out="$(_extract_review_content "$EXTRACT_FIXTURE_DIR/no-begin.log" 2>/dev/null)"; then
  bad extract-review-content-missing-begin
else
  pass extract-review-content-missing-begin
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -z "$out" ] && pass extract-review-content-missing-begin-no-output || bad extract-review-content-missing-begin-no-output

cat > "$EXTRACT_FIXTURE_DIR/no-end.log" <<'LOGEOF'
===PR-REVIEW-BY-MULTI-AGENTS-BEGIN===
never closed
LOGEOF
if out="$(_extract_review_content "$EXTRACT_FIXTURE_DIR/no-end.log" 2>/dev/null)"; then
  bad extract-review-content-missing-end
else
  pass extract-review-content-missing-end
fi

cat > "$EXTRACT_FIXTURE_DIR/reversed.log" <<'LOGEOF'
===PR-REVIEW-BY-MULTI-AGENTS-END===
end marker shows up first
===PR-REVIEW-BY-MULTI-AGENTS-BEGIN===
LOGEOF
if out="$(_extract_review_content "$EXTRACT_FIXTURE_DIR/reversed.log" 2>/dev/null)"; then
  bad extract-review-content-reversed-markers
else
  pass extract-review-content-reversed-markers
fi

# A marker-like substring that is NOT its own complete line (extra
# trailing text on the same line) must not count as a match -- the
# contract requires each marker to occupy its own line exactly.
cat > "$EXTRACT_FIXTURE_DIR/partial-marker.log" <<'LOGEOF'
===PR-REVIEW-BY-MULTI-AGENTS-BEGIN=== extra text on the same line
content
===PR-REVIEW-BY-MULTI-AGENTS-END===
LOGEOF
if out="$(_extract_review_content "$EXTRACT_FIXTURE_DIR/partial-marker.log" 2>/dev/null)"; then
  bad extract-review-content-rejects-partial-marker-line
else
  pass extract-review-content-rejects-partial-marker-line
fi

# Adjacent markers (END immediately follows BEGIN, zero content lines
# between them) is the exact bug all three reviewers independently caught
# in the skill's own self-review: `sed -n "X,Yp"` with X > Y is NOT sed's
# "print nothing" case -- it prints line X itself, which for an inverted
# range built from adjacent markers is the END marker line, silently
# turned into "content" and posted as if it were the reviewer's actual
# review. Both the empty-content rejection and the explicit
# content_start > content_end guard exist specifically because of this.
cat > "$EXTRACT_FIXTURE_DIR/adjacent-markers.log" <<'LOGEOF'
before
===PR-REVIEW-BY-MULTI-AGENTS-BEGIN===
===PR-REVIEW-BY-MULTI-AGENTS-END===
after
LOGEOF
if out="$(_extract_review_content "$EXTRACT_FIXTURE_DIR/adjacent-markers.log" 2>/dev/null)"; then
  bad extract-review-content-rejects-adjacent-markers
else
  pass extract-review-content-rejects-adjacent-markers
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -z "$out" ] && pass extract-review-content-rejects-adjacent-markers-no-output || bad extract-review-content-rejects-adjacent-markers-no-output
# Specifically guards against the exact failure mode found: the END
# marker line itself must never leak out as if it were "content".
case "$out" in
  *'PR-REVIEW-BY-MULTI-AGENTS-END'*) bad extract-review-content-adjacent-markers-no-marker-leak ;;
  *) pass extract-review-content-adjacent-markers-no-marker-leak ;;
esac

# ==============================================================
# _extract_reviewer_output
#
# The interactive counterpart to _extract_review_content above, and the
# actual decider both spawn_supervisor_interactive's poll loop and
# _record_reviewer_result_interactive rely on for "is this reviewer done,
# and is its output trustworthy" (see its own docstring). SKILL.md's own
# 回報與張貼 section commits to three conditions: the file exists, the end
# marker's last-line occurrence is the whole file's only one, and the
# content above it is non-empty.
# ==============================================================

EXTRACTOUT_FIXTURE_DIR="$T/extract-reviewer-output-fixture"
mkdir -p "$EXTRACTOUT_FIXTURE_DIR"

cat > "$EXTRACTOUT_FIXTURE_DIR/good.md" <<'REVIEWEOF'
line one of the review
line two of the review
===PR-REVIEW-BY-MULTI-AGENTS-END===
REVIEWEOF
out="$(_extract_reviewer_output "$EXTRACTOUT_FIXTURE_DIR/good.md")"
expected=$'line one of the review\nline two of the review'
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$out" = "$expected" ] && pass extract-reviewer-output-happy-path || bad "extract-reviewer-output-happy-path: $out"

if out="$(_extract_reviewer_output "$EXTRACTOUT_FIXTURE_DIR/does-not-exist.md" 2>/dev/null)"; then
  bad extract-reviewer-output-missing-file
else
  pass extract-reviewer-output-missing-file
fi

cat > "$EXTRACTOUT_FIXTURE_DIR/no-marker.md" <<'REVIEWEOF'
still writing, no end marker yet
REVIEWEOF
if out="$(_extract_reviewer_output "$EXTRACTOUT_FIXTURE_DIR/no-marker.md" 2>/dev/null)"; then
  bad extract-reviewer-output-missing-marker
else
  pass extract-reviewer-output-missing-marker
fi

# The bug this section exists to catch: a second, earlier occurrence of
# the exact marker line, with the real end marker still correctly the
# file's own last line. The last-line check alone cannot see this -- it
# never looks past the last line -- so without the uniqueness check added
# alongside it, this file would pass as "done", and `sed '$d'` would
# return everything above the *last* line, including the earlier marker
# line and the real content that follows it verbatim: an untrustworthy
# duplicate-marker file judged postable, exactly the one failure shape
# SKILL.md's own contract names as the one that gets bad content onto the
# PR.
cat > "$EXTRACTOUT_FIXTURE_DIR/duplicate-marker.md" <<'REVIEWEOF'
line one of the review
===PR-REVIEW-BY-MULTI-AGENTS-END===
line two, written after the marker somehow
===PR-REVIEW-BY-MULTI-AGENTS-END===
REVIEWEOF
if out="$(_extract_reviewer_output "$EXTRACTOUT_FIXTURE_DIR/duplicate-marker.md" 2>/dev/null)"; then
  bad "extract-reviewer-output-rejects-duplicate-marker: printed $out"
else
  pass extract-reviewer-output-rejects-duplicate-marker
fi

# Adjacent-to-empty case: the marker is the file's only line, so there is
# no content above it once it is stripped out.
cat > "$EXTRACTOUT_FIXTURE_DIR/marker-only.md" <<'REVIEWEOF'
===PR-REVIEW-BY-MULTI-AGENTS-END===
REVIEWEOF
if out="$(_extract_reviewer_output "$EXTRACTOUT_FIXTURE_DIR/marker-only.md" 2>/dev/null)"; then
  bad extract-reviewer-output-rejects-empty-content
else
  pass extract-reviewer-output-rejects-empty-content
fi

# ==============================================================
# print_summary
# ==============================================================

PS_BASE="$T/print-summary-base"
mkdir -p "$PS_BASE"

# claude's own pane id below deliberately contains a colon (the same
# wNN:pM shape parse_launch_args's own round-trip test above uses) --
# print_summary splits each <cli>:<pane_id> argument on only the *first*
# colon (see its own docstring), so this also pins down that a colon
# inside the pane id itself survives whole rather than being truncated.
ps_out="$(print_summary "$PS_BASE" claude:w16:p3 codex:pane-codex-1 --skipped opencode)"

case "$ps_out" in
  *'claude'*'w16:p3'*"$PS_BASE/reviewers/claude/workdir/review.md"*) pass print-summary-shows-dispatched-pane-and-output-file ;;
  *) bad print-summary-shows-dispatched-pane-and-output-file ;;
esac
case "$ps_out" in
  *'codex'*'pane-codex-1'*"$PS_BASE/reviewers/codex/workdir/review.md"*) pass print-summary-shows-second-dispatched-entry ;;
  *) bad print-summary-shows-second-dispatched-entry ;;
esac
case "$ps_out" in
  *'opencode'*'未安裝'*) pass print-summary-shows-skipped-reason ;;
  *) bad print-summary-shows-skipped-reason ;;
esac
case "$ps_out" in
  *'交叉驗證'*) bad print-summary-no-cross-validation-note-for-two ;;
  *) pass print-summary-no-cross-validation-note-for-two ;;
esac
case "$ps_out" in
  *"$PS_BASE/synthesis.log"*) pass print-summary-reports-synthesis-log-path ;;
  *) bad print-summary-reports-synthesis-log-path ;;
esac

ps_out_single="$(print_summary "$PS_BASE" claude:w16:p3 --skipped codex opencode)"
case "$ps_out_single" in
  *'交叉驗證'*) pass print-summary-cross-validation-note-for-one ;;
  *) bad print-summary-cross-validation-note-for-one ;;
esac
case "$ps_out_single" in
  *'synthesis.log'*) bad print-summary-single-reviewer-omits-synthesis-log ;;
  *) pass print-summary-single-reviewer-omits-synthesis-log ;;
esac

ps_out_none_skipped="$(print_summary "$PS_BASE" claude:w16:p3 codex:pane-codex-1 opencode:pane-opencode-1 --skipped)"
case "$ps_out_none_skipped" in
  *'（無）'*) pass print-summary-none-skipped-marker ;;
  *) bad print-summary-none-skipped-marker ;;
esac

# --- print_summary: 讀回 fetch_review_materials 寫下的 .materials-status，
# 回報這次到底收集到了什麼材料 -- 沒有這節之前，缺料是完全沒有訊號的，
# 直到三個 reviewer 各自回報同一件事 ---

# 沒有 .materials-status 時（例如直接呼叫 print_summary，從沒跑過
# fetch_review_materials）完全不印這節，也不能報錯；PS_BASE 是這個測試檔
# 共用的 $T 底下的一個獨立子目錄，本來就沒有 .materials-status。
case "$ps_out" in
  *'審查材料'*) bad print-summary-omits-materials-section-when-absent ;;
  *) pass print-summary-omits-materials-section-when-absent ;;
esac

# issue 由 PR 內文推導、design document 已提供
PS_MAT_A="$T/print-summary-materials-a"
mkdir -p "$PS_MAT_A"
cat > "$PS_MAT_A/.materials-status" <<'STATUS'
issue_status=derived
issue_number=123
design_status=provided
STATUS
ps_out_mat_a="$(print_summary "$PS_MAT_A" claude:p1 --skipped codex opencode)"
case "$ps_out_mat_a" in
  *'issue 內文與討論串：已取得（issue 編號由 PR 本文的 closing keyword 推導：#123）'*) pass print-summary-issue-derived-message ;;
  *) bad print-summary-issue-derived-message ;;
esac
case "$ps_out_mat_a" in
  *'design document：已提供'*) pass print-summary-design-provided-message ;;
  *) bad print-summary-design-provided-message ;;
esac

# issue 由呼叫端明確指定、design document 未提供
PS_MAT_B="$T/print-summary-materials-b"
mkdir -p "$PS_MAT_B"
cat > "$PS_MAT_B/.materials-status" <<'STATUS'
issue_status=explicit
issue_number=7
design_status=not-provided
STATUS
ps_out_mat_b="$(print_summary "$PS_MAT_B" claude:p1 --skipped codex opencode)"
case "$ps_out_mat_b" in
  *'issue 內文與討論串：已取得（呼叫端明確指定：#7）'*) pass print-summary-issue-explicit-message ;;
  *) bad print-summary-issue-explicit-message ;;
esac
case "$ps_out_mat_b" in
  *'design document：未提供'*) pass print-summary-design-not-provided-message ;;
  *) bad print-summary-design-not-provided-message ;;
esac

# issue 未宣告（PR 本文無 closing keyword、呼叫端也沒給）、design document
# 有給路徑但讀不到 -- 「未提供」跟「不可讀」是不同訊號，前者是使用者的
# 選擇，後者通常是打錯路徑
PS_MAT_C="$T/print-summary-materials-c"
mkdir -p "$PS_MAT_C"
cat > "$PS_MAT_C/.materials-status" <<'STATUS'
issue_status=not-declared
issue_number=
design_status=unreadable
STATUS
ps_out_mat_c="$(print_summary "$PS_MAT_C" claude:p1 --skipped codex opencode)"
case "$ps_out_mat_c" in
  *'issue 內文與討論串：未提供（PR 本文未宣告 closing 的 issue）'*) pass print-summary-issue-not-declared-message ;;
  *) bad print-summary-issue-not-declared-message ;;
esac
case "$ps_out_mat_c" in
  *'design document：呼叫端提供了路徑，但檔案不可讀'*) pass print-summary-design-unreadable-message ;;
  *) bad print-summary-design-unreadable-message ;;
esac

# issue 有編號（不論推導或明確指定）但抓取失敗，訊息要帶上那個編號
PS_MAT_D="$T/print-summary-materials-d"
mkdir -p "$PS_MAT_D"
cat > "$PS_MAT_D/.materials-status" <<'STATUS'
issue_status=failed
issue_number=55
design_status=provided
STATUS
ps_out_mat_d="$(print_summary "$PS_MAT_D" claude:p1 --skipped codex opencode)"
case "$ps_out_mat_d" in
  *'issue 內文與討論串：嘗試取得但失敗（issue 編號：#55'*) pass print-summary-issue-failed-with-number-message ;;
  *) bad print-summary-issue-failed-with-number-message ;;
esac

# 呼叫端給的 issue 參照本身就解析不出編號，訊息要說清楚是參照解析失敗，
# 不能印出一個空的 "#"
PS_MAT_E="$T/print-summary-materials-e"
mkdir -p "$PS_MAT_E"
cat > "$PS_MAT_E/.materials-status" <<'STATUS'
issue_status=failed
issue_number=
design_status=provided
STATUS
ps_out_mat_e="$(print_summary "$PS_MAT_E" claude:p1 --skipped codex opencode)"
case "$ps_out_mat_e" in
  *'issue 內文與討論串：嘗試取得但失敗（呼叫端提供的 issue 參照無法解析）'*) pass print-summary-issue-failed-no-number-message ;;
  *) bad print-summary-issue-failed-no-number-message ;;
esac

# ==============================================================
# resolve_base_ref
# ==============================================================

export PATH="$STUB_BIN:$saved_path"
export GH_STUB_BASE_REF_OK=1
export GH_STUB_BASE_REF_NAME=main
out="$(cd "$GIT_FIXTURE/work" && resolve_base_ref acme widgets 9)"
unset GH_STUB_BASE_REF_OK GH_STUB_BASE_REF_NAME
export PATH="$saved_path"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$out" = "origin/main" ] && pass resolve-base-ref-success || bad resolve-base-ref-success
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
git -C "$GIT_FIXTURE/work" show-ref --verify --quiet refs/remotes/origin/main && pass resolve-base-ref-creates-tracking-ref || bad resolve-base-ref-creates-tracking-ref

export PATH="$STUB_BIN:$saved_path"
export GH_STUB_BASE_REF_OK=0
if out="$(cd "$GIT_FIXTURE/work" && resolve_base_ref acme widgets 9 2>/dev/null)"; then
  bad resolve-base-ref-gh-failure
else
  pass resolve-base-ref-gh-failure
fi
unset GH_STUB_BASE_REF_OK
export PATH="$saved_path"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -z "$out" ] && pass resolve-base-ref-gh-failure-no-output || bad resolve-base-ref-gh-failure-no-output

export PATH="$STUB_BIN:$saved_path"
export GH_STUB_BASE_REF_NAME=""
if out="$(cd "$GIT_FIXTURE/work" && resolve_base_ref acme widgets 9 2>/dev/null)"; then
  bad resolve-base-ref-empty-name
else
  pass resolve-base-ref-empty-name
fi
unset GH_STUB_BASE_REF_NAME
export PATH="$saved_path"

# --- _check_origin_matches must run, and reject, before resolve_base_ref
# ever gets a chance to fetch -- exercised through a real cmd_prepare() run
# (bash "$RUN_SH" prepare ...), not just a direct resolve_base_ref call,
# since what's actually being pinned down here is cmd_prepare()'s own call
# *order*. Before this fix, a run against the wrong owner/repo still mutated a
# remote-tracking ref for the (unrelated) base branch before eventually
# being rejected by setup_worktree's own origin check further down. ---

ORIGIN_ORDER_FIXTURE="$T/origin-order-fixture"
mkdir -p "$ORIGIN_ORDER_FIXTURE/remotes/acme" "$ORIGIN_ORDER_FIXTURE/work"
git init -q -b main --bare "$ORIGIN_ORDER_FIXTURE/remotes/acme/widgets.git"
git init -q -b main "$ORIGIN_ORDER_FIXTURE/work"
(
  cd "$ORIGIN_ORDER_FIXTURE/work"
  git config user.email t@t.com
  git config user.name t
  printf 'base\n' > f.txt
  git add f.txt
  git commit -q -m base
  git remote add origin "https://github.com/acme/widgets.git"
  git config "url.$ORIGIN_ORDER_FIXTURE/remotes/acme/widgets.git.insteadOf" "https://github.com/acme/widgets.git"
  git push -q origin HEAD:refs/heads/main
  git push -q origin HEAD:refs/heads/origin-order-base-branch
  git checkout -q -b feature
  printf 'feature\n' >> f.txt
  git commit -aq -m feature
  git push -q origin feature:refs/pull/1/head
  git checkout -q main
  # `git push` itself already creates/updates the local remote-tracking
  # ref for whatever it just pushed, as a normal side effect independent
  # of resolve_base_ref -- deleted right back out so the assertion below
  # can tell "resolve_base_ref's own fetch created this" apart from "this
  # was already here from this fixture's own setup push".
  git update-ref -d refs/remotes/origin/origin-order-base-branch
)

assert_cli_stub_only "$STUB_BIN:$saved_path" "$STUB_BIN" claude codex opencode agy
if out="$(cd "$ORIGIN_ORDER_FIXTURE/work" && CLAUDE_CONFIG_DIR="" GH_STUB_BASE_REF_NAME="origin-order-base-branch" \
  HOME="$T/origin-order-home" PATH="$STUB_BIN:$saved_path" HERDR_ENV=1 \
  bash "$RUN_SH" prepare --pr "https://github.com/wrong-owner/wrong-repo/pull/1" --claude 2>&1)"; then
  bad main-e2e-origin-check-rejects-wrong-owner
else
  pass main-e2e-origin-check-rejects-wrong-owner
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
git -C "$ORIGIN_ORDER_FIXTURE/work" show-ref --verify --quiet refs/remotes/origin/origin-order-base-branch && bad main-e2e-origin-check-runs-before-fetch || pass main-e2e-origin-check-runs-before-fetch

# --- gh missing is checked (and reported clearly) before parse_pr_url's
# own empty-input derivation attempt, which needs gh itself and would
# otherwise fail for the right underlying reason but report the wrong one
# ("no PR is associated with this branch" reads like a branch problem,
# not an environment one). ---

GH_MISSING_FIXTURE="$T/gh-missing-fixture"
mkdir -p "$GH_MISSING_FIXTURE"
git init -q -b main "$GH_MISSING_FIXTURE"
(
  cd "$GH_MISSING_FIXTURE"
  git config user.email t@t.com
  git config user.name t
  printf 'x\n' > f.txt
  git add f.txt
  git commit -q -m init
)

# A stub `claude` on PATH, with no `gh` alongside it, isolates the
# gh-missing path this test targets from verify_selection's own PATH
# check -- which cmd_prepare() now runs before _check_gh_available (see
# cmd_prepare()'s own call-site comment on that ordering) -- so an empty
# PATH here would make verify_selection fail first and report the wrong
# one of the two.
GH_MISSING_BIN="$T/gh-missing-bin"
mkdir -p "$GH_MISSING_BIN"
cat > "$GH_MISSING_BIN/claude" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$GH_MISSING_BIN/claude"

# `bash` itself must be resolved via an absolute path here: prefixing
# PATH=$GH_MISSING_BIN onto the command line applies to resolving *that*
# command too, not just to what it does internally -- a PATH with no `bash`
# on it would make "bash" itself fail to be found (exit 127, "command not
# found"), which is not what this test is trying to exercise.
BASH_ABS_PATH="$(command -v bash)"
if out="$(cd "$GH_MISSING_FIXTURE" && PATH="$GH_MISSING_BIN" HERDR_ENV=1 "$BASH_ABS_PATH" "$RUN_SH" prepare --claude 2>&1)"; then
  bad main-e2e-gh-missing-fails
else
  pass main-e2e-gh-missing-fails
fi
case "$out" in
  *'gh CLI not found'*) pass main-e2e-gh-missing-reports-correct-reason ;;
  *) bad main-e2e-gh-missing-reports-correct-reason ;;
esac
case "$out" in
  *'no PR is associated'*) bad main-e2e-gh-missing-does-not-blame-branch ;;
  *) pass main-e2e-gh-missing-does-not-blame-branch ;;
esac

# ==============================================================
# main(): herdr hard gate
#
# herdr is a hard prerequisite for both prepare and launch (see
# _check_herdr_env's own docstring): a run started outside a herdr pane
# must be rejected before either subcommand does anything else, not
# discovered only once a later herdr call fails. Both cases below run
# with PATH=$EMPTY_BIN (no gh, no git, no herdr, nothing) and an isolated
# HOME, in a cwd that is not even a git repository -- if the gate did not
# run first, the very next thing either subcommand does (verify_selection
# or cmd_prepare's own _check_gh_available) would fail with a distinct,
# different message, so getting exactly the herdr message here is itself
# proof nothing past the gate ever ran, and the isolated HOME lets this
# also directly confirm no directory was created under it either.
# --check-clis is deliberately exempt from this gate (see main()'s own
# docstring) -- confirmed separately below, working the same with or
# without HERDR_ENV.
# ==============================================================

HERDRGATE_ROOT="$T/herdr-gate-fixture"
HERDRGATE_HOME="$HERDRGATE_ROOT/home"
mkdir -p "$HERDRGATE_HOME"

if hgp_out="$(cd "$HERDRGATE_ROOT" && env -u HERDR_ENV HOME="$HERDRGATE_HOME" PATH="$EMPTY_BIN" \
  "$BASH_ABS_PATH" "$RUN_SH" prepare --pr "https://github.com/acme/widgets/pull/1" --claude 2>&1)"; then
  hgp_rc=0
else
  hgp_rc=$?
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$hgp_rc" -eq 4 ] && pass "herdr-gate-prepare-exit-4-without-herdr-env" \
  || bad "herdr-gate-prepare-exit-4-without-herdr-env: rc=$hgp_rc output=$hgp_out"
case "$hgp_out" in
  *'HERDR_ENV'*) pass herdr-gate-prepare-message-names-herdr-env ;;
  *) bad "herdr-gate-prepare-message-names-herdr-env: $hgp_out" ;;
esac
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -e "$HERDRGATE_HOME/.tmp" ] && pass herdr-gate-prepare-no-tmp-dir-created \
  || bad "herdr-gate-prepare-no-tmp-dir-created: $(find "$HERDRGATE_HOME/.tmp" 2>/dev/null)"

# HERDR_ENV present but not exactly "1" must be rejected the same way as
# absent -- this is the other half of "在該環境變數不存在或不等於 1 時"
# (a stray truthy-looking value like "0" or "true" set by something else
# must not be mistaken for herdr's own signal).
if hgp2_out="$(cd "$HERDRGATE_ROOT" && HERDR_ENV=0 HOME="$HERDRGATE_HOME" PATH="$EMPTY_BIN" \
  "$BASH_ABS_PATH" "$RUN_SH" prepare --pr "https://github.com/acme/widgets/pull/1" --claude 2>&1)"; then
  hgp2_rc=0
else
  hgp2_rc=$?
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$hgp2_rc" -eq 4 ] && pass "herdr-gate-prepare-exit-4-with-non-1-herdr-env" \
  || bad "herdr-gate-prepare-exit-4-with-non-1-herdr-env: rc=$hgp2_rc output=$hgp2_out"

if hgl_out="$(cd "$HERDRGATE_ROOT" && env -u HERDR_ENV HOME="$HERDRGATE_HOME" PATH="$EMPTY_BIN" \
  "$BASH_ABS_PATH" "$RUN_SH" launch --base-dir "$HERDRGATE_ROOT/no-such-base-dir" --agent claude=pane-x 2>&1)"; then
  hgl_rc=0
else
  hgl_rc=$?
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$hgl_rc" -eq 4 ] && pass "herdr-gate-launch-exit-4-without-herdr-env" \
  || bad "herdr-gate-launch-exit-4-without-herdr-env: rc=$hgl_rc output=$hgl_out"
case "$hgl_out" in
  *'HERDR_ENV'*) pass herdr-gate-launch-message-names-herdr-env ;;
  *) bad "herdr-gate-launch-message-names-herdr-env: $hgl_out" ;;
esac
# The named --base-dir does not even exist -- if the gate had not fired
# first, _check_agents_selected would be the next thing to run and would
# report a distinct "no .roster file" usage error instead of ever
# touching that path, so its continued absence here is further proof
# nothing past the gate ran.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -e "$HERDRGATE_ROOT/no-such-base-dir" ] && pass herdr-gate-launch-no-base-dir-touched \
  || bad herdr-gate-launch-no-base-dir-touched

# --check-clis stays exempt from the gate -- confirmed working identically
# with HERDR_ENV unset.
if hgc_out="$(env -u HERDR_ENV PATH="$EMPTY_BIN" "$BASH_ABS_PATH" "$RUN_SH" --check-clis 2>&1)"; then
  pass herdr-gate-check-clis-unaffected-without-herdr-env
else
  bad "herdr-gate-check-clis-unaffected-without-herdr-env: $hgc_out"
fi
case "$hgc_out" in
  *'claude missing'*'codex missing'*'opencode missing'*'agy missing'*) pass herdr-gate-check-clis-still-reports-normally ;;
  *) bad "herdr-gate-check-clis-still-reports-normally: $hgc_out" ;;
esac

# ==============================================================
# _dispatch_failed_cleanup
#
# Direct unit tests for the helper cmd_prepare()'s and cmd_launch()'s own
# per-CLI loops each call on a partial failure (see its own docstring in
# run-review.sh): it must report
# any already-launched, now-unsupervised PIDs to stderr and remove the
# worktree, and must not claim a PID was launched when none was.
# ==============================================================

DFC_ROOT="$T/dispatch-failed-cleanup-fixture"
DFC_WT="$(_make_worktree_fixture "$DFC_ROOT")"

dfc_err="$(cd "$DFC_ROOT/work" && _dispatch_failed_cleanup "$DFC_WT" 12345 2>&1 1>/dev/null)"
case "$dfc_err" in
  *'12345'*) pass dispatch-failed-cleanup-reports-orphaned-pid ;;
  *) bad dispatch-failed-cleanup-reports-orphaned-pid ;;
esac
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -e "$DFC_WT" ] && pass dispatch-failed-cleanup-removes-worktree || bad dispatch-failed-cleanup-removes-worktree

DFC_ROOT2="$T/dispatch-failed-cleanup-fixture-none-launched"
DFC_WT2="$(_make_worktree_fixture "$DFC_ROOT2")"
dfc_err2="$(cd "$DFC_ROOT2/work" && _dispatch_failed_cleanup "$DFC_WT2" 2>&1 1>/dev/null)"
case "$dfc_err2" in
  *'before any reviewer was launched'*) pass dispatch-failed-cleanup-no-pid-message ;;
  *) bad dispatch-failed-cleanup-no-pid-message ;;
esac

# ==============================================================
# _dispatch_failed_cleanup -- worktree 移除不依賴呼叫端當下的工作目錄
# (與 spawn_supervisor_interactive 同一缺陷，見下方 SVREPOPATH 區段的說
# 明；那裡先修好了，這裡當時漏了)
#
# cmd_launch() 的逐 cli 派送迴圈在 launch_reviewer_interactive 失敗時呼叫
# 這個函式，而 cmd_launch() 是與 cmd_prepare() 分開的行程呼叫 -- 修正
# 前，這裡的裸 `git worktree remove --force` 沒有 `-C`，靠呼叫端當下的工
# 作目錄解析要清哪個 repo，若從目標 repo 之外呼叫 `run-review.sh
# launch`，會解析錯 repo、被自己的 `|| true` 靜默吞掉，worktree 永遠不
# 會被清掉。這裡同樣從一個完全無關、甚至不是 git repo 的目錄呼叫，證明
# 修正後的清理讀 .repo-path、用 `git -C <repo_path>` 執行，不依賴呼叫端
# 的 cwd。
# ==============================================================

DFCREPOPATH_ROOT="$T/dispatch-failed-cleanup-repo-path-fixture"
DFCREPOPATH_WT="$(_make_worktree_fixture "$DFCREPOPATH_ROOT")"
# .repo-path is normally written by cmd_prepare() (see its own docstring);
# this bypasses cmd_prepare()/cmd_launch() entirely, the same reason the
# SVREPOPATH fixture below seeds it by hand.
printf '%s\n' "$DFCREPOPATH_ROOT/work" > "$DFCREPOPATH_ROOT/.repo-path"

DFCREPOPATH_ELSEWHERE="$T/not-the-target-repo-dfc"
mkdir -p "$DFCREPOPATH_ELSEWHERE"
dfcrepopath_err="$(cd "$DFCREPOPATH_ELSEWHERE" && _dispatch_failed_cleanup "$DFCREPOPATH_WT" claude 2>&1 1>/dev/null)"

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -e "$DFCREPOPATH_WT" ] && pass "dispatch-failed-cleanup 從非目標 repo 的工作目錄呼叫仍能清除 worktree" \
  || bad "dispatch-failed-cleanup 從非目標 repo 的工作目錄呼叫時未能清除 worktree（worktree 仍在: $DFCREPOPATH_WT, stderr: $dfcrepopath_err）"

# ==============================================================
# prepare/launch end-to-end
#
# The most load-bearing test in this section: build_prompt takes 7
# positional parameters, and a caller that transposes two of them (e.g.
# swaps worktree_path and base_ref) produces a syntactically valid but
# semantically wrong prompt with no error anywhere -- set -u only catches
# a missing argument, never a misordered one. Every coordinate value
# below is deliberately distinct from every other, and each coordinate
# assertion checks that value against *its own* labeled line in the
# prompt file cmd_prepare() actually wrote to disk, not just that the value
# appears somewhere in it (which would pass even if two labels' values
# were swapped). The issue and design-doc materials, unlike the
# coordinates, are never handed to build_prompt as content at all --
# cmd_prepare() resolves them into the shared materials_dir via
# fetch_review_materials, then copies that into each reviewer's own
# materials directory (see cmd_prepare's own per-cli loop) -- so those two
# are instead checked by their own distinctive content showing up in that
# per-reviewer copy on disk, and explicitly *not* showing up in the built
# prompt file, the same way build_prompt's own section elsewhere in this
# file does.
#
# This also exercises run-review.sh's command-line contract end to end (task 5's
# own addition, not specified by the earlier tasks): named flags --
# --pr, --issue, --design, plus one flag per selected reviewer platform --
# invoked exactly as a real caller would, via `bash run-review.sh prepare ...`
# then `bash run-review.sh launch ...`, not by sourcing and calling
# cmd_prepare()/cmd_launch() directly (both call `exit` on their failure
# paths, which would kill this whole test script if called in-process
# instead of as real subprocesses).
#
# The origin remote is a literal https://github.com/acme9pr/widgets9pr.git
# URL, matching what _check_origin_matches needs to see in the raw
# configured value, with a `url.<local-path>.insteadOf` rule redirecting
# the actual fetch/push traffic to this fixture's own local bare repo --
# see GIT_FIXTURE's own comment on this technique.
# ==============================================================

# cmd_launch() (task 6's herdr-interactive switch) always dispatches
# through launch_reviewer_interactive, which calls herdr -- unlike the
# claude/codex/opencode/agy stubs above, herdr is genuinely installed on
# dev machines that run this suite, so a missing stub here would silently
# fall through to a real herdr trying to control a real terminal pane
# (see the launch_reviewer_interactive section's own docstring on this
# exact PATH-leak risk). Scoped tightly to this "prepare/launch
# end-to-end" section -- covering both the named-args and empty-args
# pairs below, since both reuse this same $STUB_BIN:$saved_path PATH --
# and removed again right before the CHMODE2E fixture further down,
# which deliberately uses a separate stub directory that never includes
# herdr (see that fixture's own comment on why). This stub only needs to
# succeed, unlike launch_reviewer_interactive's own dedicated section
# above, which also asserts on herdr's argv.
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
agent)
  case "${2:-}" in
  start) exit 0 ;;
  prompt) exit 0 ;;
  esac
  ;;
pane)
  case "${2:-}" in
  read) printf 'e2e-stub-pane-ready'; exit 0 ;;
  esac
  ;;
esac
exit 1
STUB
chmod +x "$STUB_BIN/herdr"

E2E_FIXTURE="$T/e2e-fixture"
mkdir -p "$E2E_FIXTURE/remotes/acme9pr" "$E2E_FIXTURE/work"
git init -q -b main --bare "$E2E_FIXTURE/remotes/acme9pr/widgets9pr.git"
git init -q -b main "$E2E_FIXTURE/work"
(
  cd "$E2E_FIXTURE/work"
  git config user.email t@t.com
  git config user.name t
  printf 'base\n' > f.txt
  git add f.txt
  git commit -q -m base
  git remote add origin "https://github.com/acme9pr/widgets9pr.git"
  git config "url.$E2E_FIXTURE/remotes/acme9pr/widgets9pr.git.insteadOf" "https://github.com/acme9pr/widgets9pr.git"
  git push -q origin HEAD:refs/heads/e2e-distinctive-base
  git checkout -q -b feature
  printf 'feature\n' >> f.txt
  git commit -aq -m feature
  git push -q origin feature:refs/pull/321/head
  git checkout -q main
)

E2E_HOME="$T/main-e2e-home"
mkdir -p "$E2E_HOME/.codex"
printf 'model = "e2e-distinctive-model"\n' > "$E2E_HOME/.codex/config.toml"

# design_doc_path is resolved relative to cmd_prepare()'s own cwd (see
# fetch_review_materials), so this needs a real file on disk at the exact
# relative path handed to run-review.sh below, not just a distinctive string --
# fetch_review_materials simply never writes design.md at all when the path
# is missing or unreadable instead (see the fetch-materials-degrades-* tests
# above), so a nonexistent path here would silently exercise that path
# instead of the one this test means to cover.
mkdir -p "$E2E_FIXTURE/work/docs"
printf 'e2e-distinctive-design-doc-marker-content\n' > "$E2E_FIXTURE/work/docs/distinctive-design-doc-marker.md"

assert_cli_stub_only "$STUB_BIN:$saved_path" "$STUB_BIN" claude codex opencode agy herdr
if out="$(cd "$E2E_FIXTURE/work" && CLAUDE_CONFIG_DIR="" GH_STUB_BASE_REF_NAME="e2e-distinctive-base" HOME="$E2E_HOME" PATH="$STUB_BIN:$saved_path" HERDR_ENV=1 \
  bash "$RUN_SH" prepare \
    --pr "https://github.com/acme9pr/widgets9pr/pull/321" \
    --issue "777" \
    --design "docs/distinctive-design-doc-marker.md" \
    --claude --codex --opencode 2>&1)"; then
  pass main-e2e-prepare-succeeds
else
  bad main-e2e-prepare-succeeds
fi

E2E_LOGS_DIR="$(find "$E2E_HOME/.tmp" -type d -name logs 2>/dev/null | head -1)"
E2E_BASE_DIR="$(dirname "${E2E_LOGS_DIR:-/nonexistent}")"
E2E_PROMPT_FILE="$E2E_LOGS_DIR/codex.prompt"

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -n "$E2E_LOGS_DIR" ] && [ -s "$E2E_PROMPT_FILE" ] && pass main-e2e-prompt-file-written || bad main-e2e-prompt-file-written

# ---- Task 3 Step 6: cmd_prepare() prints its own coordinates on success --
# base_dir/worktree_dir plus one reviewer_workdir_<cli>=, one
# reviewer_home_<cli>=, and one prompt_file_<cli>= line per selected
# reviewer. ----
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qxF "base_dir=$E2E_BASE_DIR" <<<"$out" && pass main-e2e-prepare-prints-base-dir || bad main-e2e-prepare-prints-base-dir
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qxF "worktree_dir=$E2E_BASE_DIR/worktree" <<<"$out" && pass main-e2e-prepare-prints-worktree-dir || bad main-e2e-prepare-prints-worktree-dir

# ---- Task 3 Step 2: base_dir is now the two-layer <repo>-pr-<number>/
# <timestamp>-<pid> shape -- no sha256 hash, no intervening pr-review
# directory. ----
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$(dirname "$E2E_BASE_DIR")" = "$E2E_HOME/.tmp/widgets9pr-pr-321" ] && pass main-e2e-base-dir-repo-pr-parent || bad "main-e2e-base-dir-repo-pr-parent: $(dirname "$E2E_BASE_DIR")"
case "$(basename "$E2E_BASE_DIR")" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9]*)
    pass main-e2e-base-dir-timestamp-pid-shape ;;
  *)
    bad "main-e2e-base-dir-timestamp-pid-shape: $(basename "$E2E_BASE_DIR")" ;;
esac

# ---- Task 3 Step 4: each selected reviewer gets its own writable
# workdir and isolated home directory, and their paths are among what
# cmd_prepare() printed above. ----
for cli in claude codex opencode; do
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ -d "$E2E_BASE_DIR/reviewers/$cli/workdir" ] && pass "main-e2e-reviewer-workdir-created-$cli" || bad "main-e2e-reviewer-workdir-created-$cli"
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ -d "$E2E_BASE_DIR/reviewers/$cli/home" ] && pass "main-e2e-reviewer-home-created-$cli" || bad "main-e2e-reviewer-home-created-$cli"
  # cmd_prepare() also writes a .zshrc into reviewer_home right away, via
  # _write_env_scrubbing_zshrc, in the same per-cli loop iteration that
  # just created it above -- before cmd_launch ever runs -- both to
  # suppress zsh's new-user wizard in the herdr pane the calling agent
  # builds against reviewer_home in between prepare and launch, and to
  # scrub that pane's inherited environment down to a whitelist (see
  # cmd_prepare's own per-cli loop comment and _write_env_scrubbing_zshrc's
  # own docstring in run-review.sh).
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ -f "$E2E_BASE_DIR/reviewers/$cli/home/.zshrc" ] && pass "main-e2e-reviewer-home-zshrc-created-$cli" || bad "main-e2e-reviewer-home-zshrc-created-$cli"
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  grep -qxF "reviewer_workdir_$cli=$E2E_BASE_DIR/reviewers/$cli/workdir" <<<"$out" && pass "main-e2e-prepare-prints-reviewer-workdir-$cli" || bad "main-e2e-prepare-prints-reviewer-workdir-$cli"
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  grep -qxF "reviewer_home_$cli=$E2E_BASE_DIR/reviewers/$cli/home" <<<"$out" && pass "main-e2e-prepare-prints-reviewer-home-$cli" || bad "main-e2e-prepare-prints-reviewer-home-$cli"
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  grep -qxF "prompt_file_$cli=$E2E_LOGS_DIR/$cli.prompt" <<<"$out" && pass "main-e2e-prepare-prints-prompt-file-$cli" || bad "main-e2e-prepare-prints-prompt-file-$cli"
done

# ---- Task 3b: cmd_prepare() copies this run's materials into each
# reviewer's own materials subdirectory under its workdir, locks that copy
# read-only, and points that reviewer's own prompt file's 材料檔目錄絕對路徑
# coordinate line at exactly that copy -- not the shared materials_dir a
# level up in $E2E_BASE_DIR/materials, and not another reviewer's copy. ----
for cli in claude codex opencode; do
  cli_materials="$E2E_BASE_DIR/reviewers/$cli/workdir/materials"
  cli_prompt_file="$E2E_LOGS_DIR/$cli.prompt"

  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ -s "$cli_materials/pr.md" ] && pass "main-e2e-reviewer-materials-pr-copied-$cli" || bad "main-e2e-reviewer-materials-pr-copied-$cli"
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  grep -qF 'e2e-distinctive-issue-body-marker' "$cli_materials/issue.md" 2>/dev/null && pass "main-e2e-reviewer-materials-issue-copied-$cli" || bad "main-e2e-reviewer-materials-issue-copied-$cli"
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  grep -qF 'e2e-distinctive-design-doc-marker-content' "$cli_materials/design.md" 2>/dev/null && pass "main-e2e-reviewer-materials-design-copied-$cli" || bad "main-e2e-reviewer-materials-design-copied-$cli"

  # 唯讀：對複製後的材料檔嘗試寫入，確認被拒
  if ( : > "$cli_materials/pr.md" ) 2>/dev/null; then
    bad "main-e2e-reviewer-materials-read-only-$cli"
  else
    pass "main-e2e-reviewer-materials-read-only-$cli"
  fi

  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  grep -qxF -- "- 材料檔目錄絕對路徑：$cli_materials" "$cli_prompt_file" 2>/dev/null && pass "main-e2e-prompt-materials-coordinate-own-copy-$cli" || bad "main-e2e-prompt-materials-coordinate-own-copy-$cli"
done
chmod -R u+w "$E2E_BASE_DIR/reviewers" 2>/dev/null || true

# 兩個不同 reviewer 各自指到自己那一份，不會互相混到：claude 的 prompt 檔
# 不該提到 codex 那份材料副本的路徑，反之亦然。
E2E_CLAUDE_MATERIALS="$E2E_BASE_DIR/reviewers/claude/workdir/materials"
E2E_CODEX_MATERIALS="$E2E_BASE_DIR/reviewers/codex/workdir/materials"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF "$E2E_CODEX_MATERIALS" "$E2E_LOGS_DIR/claude.prompt" 2>/dev/null && bad main-e2e-prompt-materials-coordinate-no-cross-contamination-claude || pass main-e2e-prompt-materials-coordinate-no-cross-contamination-claude
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF "$E2E_CLAUDE_MATERIALS" "$E2E_LOGS_DIR/codex.prompt" 2>/dev/null && bad main-e2e-prompt-materials-coordinate-no-cross-contamination-codex || pass main-e2e-prompt-materials-coordinate-no-cross-contamination-codex

# ---- Task 3 Step 5: .roster is written during prepare (not launch) --
# confirmed here, before cmd_launch() has run at all. ----
E2E_ROSTER_AFTER_PREPARE="$E2E_BASE_DIR/.roster"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -s "$E2E_ROSTER_AFTER_PREPARE" ] && [ "$(wc -l < "$E2E_ROSTER_AFTER_PREPARE")" -eq 3 ] && pass main-e2e-roster-written-by-prepare || bad main-e2e-roster-written-by-prepare

# cmd_prepare() does not launch anything itself (see its own docstring) --
# launch is a second, separate `bash "$RUN_SH"` invocation, fed the same
# base_dir prepare just set up, with one --agent <cli>=<pane_id> pair per
# platform prepare selected above. The pane_id values below are arbitrary
# placeholders: cmd_launch does not act on them yet in this task (a later
# task wires them into herdr), it only needs them to satisfy
# parse_launch_args's own shape check. Still run with cwd inside
# $E2E_FIXTURE/work, same as prepare above: spawn_supervisor_interactive's
# own `git worktree remove` (unmodified by this task -- run through
# cmd_launch() now, but not itself touched) resolves the repo to operate
# on from the caller's cwd, not from worktree_dir itself, and fails
# silently (swallowed by `|| true`) when run from anywhere else -- proven
# by leaving this cd out here first and watching the worktree removal
# below never converge.
#
# spawn_supervisor_interactive (started in the background by the launch
# call below) treats a reviewer as still running until its fixed
# <reviewer_workdir>/review.md file ends in the contract's END marker
# (see that function's own docstring) -- by design it has no timeout of
# its own and simply waits forever otherwise. This fixture's herdr stub
# above never writes that file itself, the same way a real reviewer CLI
# running inside its own pane eventually would, so it is supplied
# directly here for all three dispatched reviewers.
for e2e_reviewer_cli in claude codex opencode; do
  printf '%s review body (e2e stub)\n===PR-REVIEW-BY-MULTI-AGENTS-END===\n' "$e2e_reviewer_cli" \
    > "$E2E_BASE_DIR/reviewers/$e2e_reviewer_cli/workdir/review.md"
done

if out="$(cd "$E2E_FIXTURE/work" && CLAUDE_CONFIG_DIR="" HOME="$E2E_HOME" PATH="$STUB_BIN:$saved_path" HERDR_ENV=1 \
  bash "$RUN_SH" launch --base-dir "$E2E_BASE_DIR" \
    --agent claude=pane-claude --agent codex=pane-codex --agent opencode=pane-opencode 2>&1)"; then
  pass main-e2e-launch-succeeds
else
  bad main-e2e-launch-succeeds
fi

# .roster was already written by cmd_prepare() (see the
# main-e2e-roster-written-by-prepare assertion above, and Task 3 Step 5);
# this re-checks the same content survived cmd_launch() unmodified, since
# nothing in cmd_launch() touches .roster any more.
E2E_ROSTER_FILE="$E2E_BASE_DIR/.roster"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -s "$E2E_ROSTER_FILE" ] && [ "$(wc -l < "$E2E_ROSTER_FILE")" -eq 3 ] && pass main-e2e-roster-written || bad main-e2e-roster-written
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qxF 'codex e2e-distinctive-model dispatched' "$E2E_ROSTER_FILE" 2>/dev/null && pass main-e2e-roster-records-codex-model || bad main-e2e-roster-records-codex-model
# CLAUDE_CONFIG_DIR="" for this run and no ~/.config/opencode ever
# created under E2E_HOME, so both resolve to resolve_model's own
# documented unknown-value marker.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qxF 'claude unknown-model dispatched' "$E2E_ROSTER_FILE" 2>/dev/null && pass main-e2e-roster-records-claude || bad main-e2e-roster-records-claude
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qxF 'opencode unknown-model dispatched' "$E2E_ROSTER_FILE" 2>/dev/null && pass main-e2e-roster-records-opencode || bad main-e2e-roster-records-opencode

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qxF -- '- PR：https://github.com/acme9pr/widgets9pr/pull/321' "$E2E_PROMPT_FILE" 2>/dev/null && pass main-e2e-prompt-pr-url-in-place || bad main-e2e-prompt-pr-url-in-place
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qxF -- "- git worktree 絕對路徑：$E2E_BASE_DIR/worktree" "$E2E_PROMPT_FILE" 2>/dev/null && pass main-e2e-prompt-worktree-path-in-place || bad main-e2e-prompt-worktree-path-in-place
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qxF -- '- base ref：origin/e2e-distinctive-base' "$E2E_PROMPT_FILE" 2>/dev/null && pass main-e2e-prompt-base-ref-in-place || bad main-e2e-prompt-base-ref-in-place
# issue_arg "777" resolves via _parse_issue_ref straight through
# fetch_review_materials to a real (stubbed) `gh issue view` call; its
# body ends up copied into codex's own materials/issue.md (asserted in the
# Task 3b block above, main-e2e-reviewer-materials-issue-copied-codex), not
# embedded into this prompt file -- confirmed negatively here.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF 'e2e-distinctive-issue-body-marker' "$E2E_PROMPT_FILE" 2>/dev/null && bad main-e2e-prompt-issue-material-not-embedded || pass main-e2e-prompt-issue-material-not-embedded
# Same shift for the design doc: its full text ends up copied into
# codex's own materials/design.md instead of being embedded in this
# prompt file -- confirmed negatively here too.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF 'e2e-distinctive-design-doc-marker-content' "$E2E_PROMPT_FILE" 2>/dev/null && bad main-e2e-prompt-design-material-not-embedded || pass main-e2e-prompt-design-material-not-embedded
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qxF -- '- 產出這則 review 的 CLI 名稱：codex' "$E2E_PROMPT_FILE" 2>/dev/null && pass main-e2e-prompt-cli-name-in-place || bad main-e2e-prompt-cli-name-in-place
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qxF -- '- 產出這則 review 的 model 名稱：e2e-distinctive-model' "$E2E_PROMPT_FILE" 2>/dev/null && pass main-e2e-prompt-model-in-place || bad main-e2e-prompt-model-in-place
# No scratch-directory coordinate at all any more: the reviewer prints
# its review to stdout (cmd_launch()'s log file) instead of writing a
# comment-body file anywhere, so there is no longer a scratch path to
# hand it.
oc_e2e_prompt_content="$(cat "$E2E_PROMPT_FILE" 2>/dev/null)"
case "$oc_e2e_prompt_content" in
  *'暫存目錄'*) bad main-e2e-prompt-no-scratch-dir-coordinate ;;
  *) pass main-e2e-prompt-no-scratch-dir-coordinate ;;
esac

E2E_WORKTREE_DIR="$E2E_BASE_DIR/worktree"

# --- the `chmod -R a-w` mechanism cmd_prepare() applies to the worktree
# (closing the gap that every individual reviewer CLI's own
# sandbox/permission flags turned out, on real testing, not to fully close
# on their own -- see launch_reviewer_interactive's docstring) is checked
# directly against its own fixture here, not against the e2e run above:
# that run's stub reviewers finish and get cleaned up by
# spawn_supervisor_interactive near-instantly, so checking the worktree's
# permissions or attempting a
# write against it *after* `bash "$RUN_SH" launch` has already returned
# would race spawn_supervisor_interactive possibly having already removed
# it. ---

CHMOD_ROOT="$T/chmod-worktree-fixture"
CHMOD_WT="$(_make_worktree_fixture "$CHMOD_ROOT")"
chmod -R a-w "$CHMOD_WT"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -w "$CHMOD_WT" ] && pass chmod-worktree-is-os-level-read-only || bad chmod-worktree-is-os-level-read-only
if ( : > "$CHMOD_WT/should-not-be-writable.txt" ) 2>/dev/null; then
  bad chmod-worktree-write-actually-denied
else
  pass chmod-worktree-write-actually-denied
fi
# git status/diff -- everything the reviewer contract's read-only true-
# source-of-truth section asks a reviewer to do -- must still work: a
# linked worktree's own index/HEAD housekeeping lives under the main
# repo's .git/worktrees/<name>/, not inside the worktree's own directory
# tree, so chmod'ing that tree read-only should not affect them.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
git -C "$CHMOD_WT" status --porcelain >/dev/null 2>&1 && pass chmod-worktree-status-still-works || bad chmod-worktree-status-still-works
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
git -C "$CHMOD_WT" diff main...HEAD >/dev/null 2>&1 && pass chmod-worktree-diff-still-works || bad chmod-worktree-diff-still-works
chmod -R u+w "$CHMOD_WT"

# --- print_summary's own stdout (cmd_launch()'s only output) names every
# dispatched reviewer with its pane id (from the --agent flag above, e.g.
# codex=pane-codex) and its fixed output file -- the exact chain SKILL.md's
# reporting depends on. ---

case "$out" in
  *'codex'*'pane-codex'*"$E2E_BASE_DIR/reviewers/codex/workdir/review.md"*) pass main-e2e-summary-output-lists-pane-and-output-file ;;
  *) bad main-e2e-summary-output-lists-pane-and-output-file ;;
esac

# This run's own issue_arg ("777") was explicit and its design doc path was
# readable -- confirming print_summary's materials section reflects that
# correctly end to end (real cmd_prepare() -> fetch_review_materials ->
# .materials-status -> cmd_launch()'s print_summary), not just against a
# hand-written .materials-status fixture the way the print_summary section
# above does.
case "$out" in
  *'issue 內文與討論串：已取得（呼叫端明確指定：#777）'*) pass main-e2e-summary-output-shows-explicit-issue ;;
  *) bad main-e2e-summary-output-shows-explicit-issue ;;
esac
case "$out" in
  *'design document：已提供'*) pass main-e2e-summary-output-shows-design-provided ;;
  *) bad main-e2e-summary-output-shows-design-provided ;;
esac

# --- spawn_supervisor_interactive's summary_file (base_dir/summary.txt,
# i.e. two directories up from any <cli>.log path -- the exact derivation
# SKILL.md uses to find it) eventually exists and converges to one line
# per dispatched reviewer plus one more synthesis line (all three
# reviewers above are content_status=ready -- marker-terminated review.md,
# untouched worktree -- so the >= 2 ready_count threshold documented on
# spawn_supervisor_interactive triggers a synthesis pass), then the
# worktree it removes on completion is actually gone. Bounded polling, not
# a fixed sleep, since this run's stub reviewers and stub synthesis CLI
# finish in well under a second but real ones would not. ---

E2E_SUMMARY_FILE="$E2E_BASE_DIR/summary.txt"
i=0
until { [ -f "$E2E_SUMMARY_FILE" ] && [ "$(wc -l < "$E2E_SUMMARY_FILE")" -eq 4 ]; } || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -f "$E2E_SUMMARY_FILE" ] && [ "$(wc -l < "$E2E_SUMMARY_FILE")" -eq 4 ] && pass main-e2e-summary-file-converges || bad main-e2e-summary-file-converges
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -q 'worktree_status=ok' "$E2E_SUMMARY_FILE" 2>/dev/null && pass main-e2e-summary-file-worktree-status-ok || bad main-e2e-summary-file-worktree-status-ok

i=0
until [ ! -e "$E2E_WORKTREE_DIR" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -e "$E2E_WORKTREE_DIR" ] && pass main-e2e-worktree-removed-after-completion || bad main-e2e-worktree-removed-after-completion

# --- --pr/--issue/--design all omitted: PR derives from branch, and (the
# stub PR body carrying no closing keyword, same as the header's shared gh
# stub) fetch_review_materials never derives an issue either -- so only
# pr.md ever lands in the shared materials_dir, rather than blocking the
# run. The point of this fixture: cmd_prepare()'s own per-reviewer copy
# step (see its docstring) must not fail just because issue.md/design.md
# were never there to copy, and must not invent empty ones either. ---

E2E_HOME2="$T/main-e2e-home2"
assert_cli_stub_only "$STUB_BIN:$saved_path" "$STUB_BIN" claude codex opencode agy herdr
if out="$(cd "$E2E_FIXTURE/work" \
  && CLAUDE_CONFIG_DIR="" GH_STUB_DERIVE_OK=1 GH_STUB_DERIVED_URL="https://github.com/acme9pr/widgets9pr/pull/321" \
     GH_STUB_BASE_REF_NAME="e2e-distinctive-base" HOME="$E2E_HOME2" PATH="$STUB_BIN:$saved_path" HERDR_ENV=1 \
  bash "$RUN_SH" prepare --claude --codex --opencode 2>&1)"; then
  pass main-e2e-empty-args-prepare-succeeds
else
  bad main-e2e-empty-args-prepare-succeeds
fi

E2E_LOGS_DIR2="$(find "$E2E_HOME2/.tmp" -type d -name logs 2>/dev/null | head -1)"
E2E_BASE_DIR2="$(dirname "${E2E_LOGS_DIR2:-/nonexistent}")"
E2E_CODEX_MATERIALS2="$E2E_BASE_DIR2/reviewers/codex/workdir/materials"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -s "$E2E_CODEX_MATERIALS2/pr.md" ] && pass main-e2e-empty-args-materials-pr-copied || bad main-e2e-empty-args-materials-pr-copied
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -e "$E2E_CODEX_MATERIALS2/issue.md" ] && pass main-e2e-empty-args-materials-no-issue-file || bad main-e2e-empty-args-materials-no-issue-file
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -e "$E2E_CODEX_MATERIALS2/design.md" ] && pass main-e2e-empty-args-materials-no-design-file || bad main-e2e-empty-args-materials-no-design-file

# See the earlier prepare/launch pair's own comment on why this is a
# second, separate `bash "$RUN_SH"` call, why the pane_id values below are
# arbitrary placeholders, and why cwd must still be inside
# $E2E_FIXTURE/work -- and on why the loop just below is needed at all
# (spawn_supervisor_interactive's own polling requirement).
for e2e_reviewer_cli in claude codex opencode; do
  printf '%s review body (e2e stub)\n===PR-REVIEW-BY-MULTI-AGENTS-END===\n' "$e2e_reviewer_cli" \
    > "$E2E_BASE_DIR2/reviewers/$e2e_reviewer_cli/workdir/review.md"
done

if out="$(cd "$E2E_FIXTURE/work" && CLAUDE_CONFIG_DIR="" HOME="$E2E_HOME2" PATH="$STUB_BIN:$saved_path" HERDR_ENV=1 \
  bash "$RUN_SH" launch --base-dir "$E2E_BASE_DIR2" \
    --agent claude=pane-claude --agent codex=pane-codex --agent opencode=pane-opencode 2>&1)"; then
  pass main-e2e-empty-args-launch-succeeds
else
  bad main-e2e-empty-args-launch-succeeds
fi

# print_summary's own materials section must say the same thing in plain
# language: no issue was declared (the stub PR body carries no closing
# keyword and no issue link was given), and no design doc was given
# either -- $out here still holds this second run's own launch-side stdout.
case "$out" in
  *'issue 內文與討論串：未提供（PR 本文未宣告 closing 的 issue）'*) pass main-e2e-empty-args-summary-shows-issue-not-declared ;;
  *) bad main-e2e-empty-args-summary-shows-issue-not-declared ;;
esac
case "$out" in
  *'design document：未提供'*) pass main-e2e-empty-args-summary-shows-design-not-provided ;;
  *) bad main-e2e-empty-args-summary-shows-design-not-provided ;;
esac

# Tear down the herdr stub installed at the top of the "prepare/launch
# end-to-end" section above -- both prepare/launch pairs that need it are
# done. CHMODE2E_STUB_BIN below is a wholly separate stub directory (with
# its own, separately scoped herdr stub -- see its own comment further
# down), so this line does not change its behavior either way; it exists
# so $STUB_BIN itself does not carry the leftover file into whatever
# reuses $STUB_BIN after this point, the same scoping this file's herdr
# stubs apply everywhere else.
rm -f "$STUB_BIN/herdr"

# --- cmd_prepare() and cmd_launch() actually apply their own
# worktree/logs_dir read-only chmod, not just "chmod behaves this way when
# I do it myself in a fixture" (which CHMOD_ROOT above already covers, but
# deleting either chmod line entirely would leave that test just as
# green). The write-probe this section used to rely on -- a real stub
# reviewer CLI, invoked with the worktree path on its own -C argument,
# attempting one write against it at startup -- no longer reflects how
# cmd_launch() actually dispatches: every reviewer now goes through
# launch_reviewer_interactive, which hands the reviewer command to herdr
# to spawn inside a pane herdr itself manages (this script never execs
# claude/codex/opencode directly any more -- see that function's own
# docstring), and even codex's own argv there points `-C` at
# reviewer_workdir, not worktree_dir (see launch_reviewer_interactive's
# own cmd= arrays) -- a directory this pipeline never chmods read-only in
# the first place. Confirmed directly, not assumed: real herdr, run
# against a pane ID no pane manager ever created (exactly what this
# fixture's own placeholder pane IDs are), returns
# {"error":{"code":"agent_pane_not_found",...}} and exits non-zero
# immediately, without ever running its own trailing argv -- so a stub
# codex wired up the old way would never even be reached, real herdr or
# stubbed. This is also why main-e2e-chmod-launch-succeeds used to fail
# outright: cmd_launch() was aborting at launch_reviewer_interactive's own
# herdr call, before dispatching a single reviewer, real or stubbed.
#
# The fix below stubs herdr too (same minimal stub as the "prepare/launch
# end-to-end" section's own, scoped to this fixture's own separate stub
# directory), which lets cmd_launch() actually reach and pass its own
# per-cli dispatch loop and its own `chmod -R a-w "$logs_dir"` line. What
# replaces the old write-probe is a direct filesystem write attempt
# against worktree_dir itself, run from this test process, not from
# inside any reviewer -- the same technique the logs_dir assertions just
# below already use. logs_dir is never removed by this pipeline, so
# checking its permissions after `bash "$RUN_SH"` returns is not racy;
# worktree_dir, on the other hand, does get removed once
# spawn_supervisor_interactive (started by cmd_launch() itself, in the
# background) sees every dispatched reviewer's review.md end in the
# contract's marker (see that function's own docstring) -- so this
# section deliberately never supplies that marker until after its own
# checks are done. Until then, spawn_supervisor_interactive's own poll
# loop has no marker to find, stays pending by construction (not by
# timing), and worktree_dir stays exactly as cmd_prepare() left it. Once
# this section's checks are done, it supplies the markers itself (the
# same direct-write technique the "prepare/launch end-to-end" section
# uses for its own stub reviewers) and polls for the whole run to
# converge, so the background supervisor still finishes and this section
# leaves no process running behind it -- see that wait's own comment
# further down for what it also triggers and why that stays safe under
# this fixture's own stubs. ---

CHMODE2E_FIXTURE="$T/chmod-e2e-fixture"
mkdir -p "$CHMODE2E_FIXTURE/remotes/acme" "$CHMODE2E_FIXTURE/work"
git init -q -b main --bare "$CHMODE2E_FIXTURE/remotes/acme/widgets.git"
git init -q -b main "$CHMODE2E_FIXTURE/work"
(
  cd "$CHMODE2E_FIXTURE/work"
  git config user.email t@t.com
  git config user.name t
  printf 'base\n' > f.txt
  git add f.txt
  git commit -q -m base
  git remote add origin "https://github.com/acme/widgets.git"
  git config "url.$CHMODE2E_FIXTURE/remotes/acme/widgets.git.insteadOf" "https://github.com/acme/widgets.git"
  git push -q origin HEAD:refs/heads/main
  git checkout -q -b feature
  printf 'feature\n' >> f.txt
  git commit -aq -m feature
  git push -q origin feature:refs/pull/50/head
  git checkout -q main
)

CHMODE2E_STUB_BIN="$T/chmod-e2e-stub-bin"
mkdir -p "$CHMODE2E_STUB_BIN"
cp "$STUB_BIN/gh" "$CHMODE2E_STUB_BIN/gh"
# claude, codex, and opencode are all trivial "exit 0" stand-ins here --
# none of the three is ever actually invoked as a process by this
# fixture's own test code any more, and cmd_launch() itself no longer
# execs any of them directly either (see this section's own top comment
# on launch_reviewer_interactive): herdr owns spawning whatever follows
# `--` inside its own pane, and the herdr stub below only reports
# success, it never execs its own trailing argv. PATH below is still
# "$CHMODE2E_STUB_BIN:$saved_path", not an exclusive PATH, so leaving any
# of the three names out would still let verify_selection's own
# `command -v` check resolve it to the *real*, system-installed CLI
# further down that same PATH -- verify_selection runs regardless of
# whether herdr would ever actually launch it, so a missing stub here
# still fails this fixture the same way it always did. Bitten by exactly
# this once already earlier in this same task (see this task's own
# report).
cp "$STUB_BIN/claude" "$CHMODE2E_STUB_BIN/claude"
cp "$STUB_BIN/codex" "$CHMODE2E_STUB_BIN/codex"
cp "$STUB_BIN/opencode" "$CHMODE2E_STUB_BIN/opencode"

# herdr must also be stubbed here now that cmd_launch() actually reaches
# it (see this section's own top comment) -- without this, herdr resolves
# to the real, system-installed binary and, given this fixture's own
# placeholder pane IDs (pane-claude/pane-codex/pane-opencode -- arbitrary
# strings no real pane manager ever created; see the "prepare/launch
# end-to-end" section's own comment on why), fails immediately with
# agent_pane_not_found (confirmed directly against the real binary -- see
# this section's own top comment). Same minimal stub as that section's
# own: only needs to succeed, nothing here asserts on herdr's argv.
cat > "$CHMODE2E_STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
agent)
  case "${2:-}" in
  start) exit 0 ;;
  prompt) exit 0 ;;
  esac
  ;;
pane)
  case "${2:-}" in
  read) printf 'e2e-stub-pane-ready'; exit 0 ;;
  esac
  ;;
esac
exit 1
STUB
chmod +x "$CHMODE2E_STUB_BIN/herdr"

CHMODE2E_HOME="$T/chmod-e2e-home"
# agy is deliberately absent from CHMODE2E_STUB_BIN (this run never passes
# --agy), so only the four names it actually provides are checked.
assert_cli_stub_only "$CHMODE2E_STUB_BIN:$saved_path" "$CHMODE2E_STUB_BIN" claude codex opencode herdr
if out="$(cd "$CHMODE2E_FIXTURE/work" && CLAUDE_CONFIG_DIR="" GH_STUB_BASE_REF_NAME=main HOME="$CHMODE2E_HOME" PATH="$CHMODE2E_STUB_BIN:$saved_path" HERDR_ENV=1 \
  bash "$RUN_SH" prepare --pr "https://github.com/acme/widgets/pull/50" --claude --codex --opencode 2>&1)"; then
  pass main-e2e-chmod-prepare-succeeds
else
  bad main-e2e-chmod-prepare-succeeds
fi

CHMODE2E_LOGS_DIR="$(find "$CHMODE2E_HOME/.tmp" -type d -name logs 2>/dev/null | head -1)"
CHMODE2E_BASE_DIR="$(dirname "${CHMODE2E_LOGS_DIR:-/nonexistent}")"
CHMODE2E_WORKTREE_DIR="$CHMODE2E_BASE_DIR/worktree"

# See the first prepare/launch pair's own comment on why this is a
# second, separate `bash "$RUN_SH"` call, why the pane_id values below
# are arbitrary placeholders, and why cwd must still be inside
# $CHMODE2E_FIXTURE/work. Unlike that pair, no review.md is pre-written
# for any reviewer here -- see this section's own top comment on why
# withholding the marker is exactly what keeps worktree_dir alive and
# read-only long enough for the write-probe just below to run without
# racing spawn_supervisor_interactive's own async removal.
#
# Output goes to a regular file here, not an `out="$(... 2>&1)"` command
# substitution the way every other launch call in this file captures
# its own -- cmd_launch()'s background spawn_supervisor_interactive
# subshell inherits whatever fd this call's own stdout/stderr point at,
# and with no marker written yet (see above) that subshell is still
# running, still holding its own copy of that fd, for as long as this
# section's own checks take. A pipe-backed command substitution blocks
# its reader until every process holding the write end has closed it,
# including that still-running grandchild -- capturing this call's
# output that way deadlocks this section against its own later
# marker-writing step, which cannot run until the capture returns. A
# plain file redirect carries no such "wait for every holder to close"
# contract: the shell below only waits on its direct child (`bash
# "$RUN_SH" launch` itself), so this line returns as soon as cmd_launch()
# does, exactly like real usage expects (see SKILL.md's own "此時
# reviewer 還在背景跑" on launch returning right after dispatch). Found
# empirically, not by inspection: an earlier version of this line used
# the command-substitution form and hung indefinitely.
# Wrapped in `if ... ; then ... ; else ... ; fi`, not a bare statement
# followed by a separate `rc=$?` line, so a real failure here (e.g. this
# whole fixture's own bug recurring) trips neither `set -e` nor the
# `pipefail` this file also sets -- an unguarded nonzero exit on its own
# line would abort this entire test script right here under `set -euo
# pipefail`, silently skipping every section after it, exactly the same
# hazard `# shellcheck disable=SC2015`'s own `&&`/`||` idiom exists to
# avoid elsewhere in this file. Caught empirically: this uncovered a real
# `set -e` abort during the herdr PATH-guard proof this task's own report
# describes, the first time this exact line legitimately failed.
CHMODE2E_LAUNCH_OUT="$T/chmod-e2e-launch.out"
if (cd "$CHMODE2E_FIXTURE/work" && CLAUDE_CONFIG_DIR="" HOME="$CHMODE2E_HOME" PATH="$CHMODE2E_STUB_BIN:$saved_path" HERDR_ENV=1 \
  bash "$RUN_SH" launch --base-dir "$CHMODE2E_BASE_DIR" \
    --agent claude=pane-claude --agent codex=pane-codex --agent opencode=pane-opencode) \
  > "$CHMODE2E_LAUNCH_OUT" 2>&1; then
  pass main-e2e-chmod-launch-succeeds
else
  bad "main-e2e-chmod-launch-succeeds: $(cat "$CHMODE2E_LAUNCH_OUT" 2>/dev/null)"
fi

# Direct write attempt against worktree_dir itself -- see this section's
# own top comment for why this replaces the old stub-reviewer write-probe,
# and why running it here, immediately after cmd_launch() returns and
# before any reviewer's review.md carries an end marker, cannot race
# spawn_supervisor_interactive's own removal.
if ( : > "$CHMODE2E_WORKTREE_DIR/should-not-be-writable.txt" ) 2>/dev/null; then
  bad main-e2e-worktree-write-actually-blocked
else
  pass main-e2e-worktree-write-actually-blocked
fi

# Not racy: logs_dir is never removed by this pipeline, so its
# permissions are stable to inspect any time after the run returns.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -d "$CHMODE2E_LOGS_DIR" ] && [ ! -w "$CHMODE2E_LOGS_DIR" ] && pass main-e2e-logs-dir-actually-read-only || bad main-e2e-logs-dir-actually-read-only
if ( : > "$CHMODE2E_LOGS_DIR/should-not-be-writable.txt" ) 2>/dev/null; then
  bad main-e2e-logs-dir-write-actually-denied
else
  pass main-e2e-logs-dir-write-actually-denied
fi

# This section's own checks are done -- supply every dispatched
# reviewer's end marker now (the same direct-write technique the
# "prepare/launch end-to-end" section uses for its own stub reviewers) so
# spawn_supervisor_interactive's background poll loop can finally
# converge, remove worktree_dir, and exit, rather than being left polling
# forever (see that function's own docstring on why a marker-less
# review.md never lets it finish). All three reviewers going
# content_status=ready also clears the >= 2 threshold that triggers a
# synthesis pass in that same background subshell -- safe under this
# fixture's own stubs: the subshell inherits this run's own
# PATH="$CHMODE2E_STUB_BIN:$saved_path", so whichever CLI
# _select_synthesis_cli picks (claude, codex, or opencode -- agy was
# never dispatched here, so it is never a candidate) still resolves to
# this fixture's own trivial stand-in, not a real, system-installed CLI.
# Polling for summary_file to reach its full four lines (one per
# reviewer plus the synthesis line) rather than merely for worktree_dir's
# removal: worktree removal happens earlier in the same subshell, so
# waiting for the later signal also proves the subshell's own synthesis
# pass -- and therefore the whole background job -- has finished, leaving
# nothing still running behind this section once the wait returns.
for chmode2e_reviewer_cli in claude codex opencode; do
  printf '%s review body (chmod e2e stub)\n===PR-REVIEW-BY-MULTI-AGENTS-END===\n' "$chmode2e_reviewer_cli" \
    > "$CHMODE2E_BASE_DIR/reviewers/$chmode2e_reviewer_cli/workdir/review.md"
done

CHMODE2E_SUMMARY_FILE="$CHMODE2E_BASE_DIR/summary.txt"
i=0
until { [ -f "$CHMODE2E_SUMMARY_FILE" ] && [ "$(wc -l < "$CHMODE2E_SUMMARY_FILE")" -eq 4 ]; } || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done

chmod -R u+w "$CHMODE2E_BASE_DIR" 2>/dev/null || true

# --- cmd_launch() 在真正呼叫 launch_reviewer_interactive 之前，對選定平
# 台重跑一次等價於 verify_selection 的 PATH 檢查（Medium 3 審查意見）：
# prepare 與 launch 是刻意分成兩次獨立行程呼叫、中間留了人類尺度延遲讓
# 呼叫端建立 herdr pane，所以 prepare 當時在 PATH 上的 cli，launch 執行
# 的當下不保證還在。這裡直接重現那個延遲：prepare 時 claude／codex 都在
# PATH 上、成功結束；launch 時把 codex 從 PATH 上拿掉，驗證結束碼是 3
# （跟一開始選錯平台同一個結束碼，而不是 launch_reviewer_interactive 自
# 己那種找不到指令的 127），而且連仍然在 PATH 上的 claude 也不能被啟動
# ——半數啟動半數沒啟動是比整批都不啟動更糟的結果，因為使用者分不出哪半
# 段能信。----

VERIFY3_FIXTURE="$T/verify3-fixture"
mkdir -p "$VERIFY3_FIXTURE/remotes/acme" "$VERIFY3_FIXTURE/work"
git init -q -b main --bare "$VERIFY3_FIXTURE/remotes/acme/widgets.git"
git init -q -b main "$VERIFY3_FIXTURE/work"
(
  cd "$VERIFY3_FIXTURE/work"
  git config user.email t@t.com
  git config user.name t
  printf 'base\n' > f.txt
  git add f.txt
  git commit -q -m base
  git remote add origin "https://github.com/acme/widgets.git"
  git config "url.$VERIFY3_FIXTURE/remotes/acme/widgets.git.insteadOf" "https://github.com/acme/widgets.git"
  git push -q origin HEAD:refs/heads/main
  git checkout -q -b feature
  printf 'feature\n' >> f.txt
  git commit -aq -m feature
  git push -q origin feature:refs/pull/91/head
  git checkout -q main
)

VERIFY3_HOME="$T/verify3-home"
assert_cli_stub_only "$STUB_BIN:$saved_path" "$STUB_BIN" claude codex opencode agy
if out="$(cd "$VERIFY3_FIXTURE/work" && CLAUDE_CONFIG_DIR="" GH_STUB_BASE_REF_NAME=main HOME="$VERIFY3_HOME" PATH="$STUB_BIN:$saved_path" HERDR_ENV=1 \
  bash "$RUN_SH" prepare --pr "https://github.com/acme/widgets/pull/91" --claude --codex 2>&1)"; then
  pass verify3-prepare-succeeds
else
  bad "verify3-prepare-succeeds: $out"
fi

VERIFY3_LOGS_DIR="$(find "$VERIFY3_HOME/.tmp" -type d -name logs 2>/dev/null | head -1)"
VERIFY3_BASE_DIR="$(dirname "${VERIFY3_LOGS_DIR:-/nonexistent}")"

# codex 這裡刻意不在 PATH 上，而且用的是一個獨立、乾淨的目錄（跟上面
# GH_MISSING_BIN／JQ_MISSING_BIN 同一種手法），不是把它疊在
# "$STUB_BIN:$saved_path" 前面——否則萬一這台機器真的裝了 codex，它會從
# $saved_path 那一段被 verify_selection 的 command -v 找到，這個測試就
# 測不到本來要測的那個缺席情境。bash 本身透過絕對路徑 $BASH_ABS_PATH
# 呼叫，不靠 PATH 解析，所以這個目錄不需要另外放一份 bash。
VERIFY3_MISSING_BIN="$T/verify3-missing-bin"
mkdir -p "$VERIFY3_MISSING_BIN"
cp "$STUB_BIN/claude" "$VERIFY3_MISSING_BIN/claude"
if out="$(cd "$VERIFY3_FIXTURE/work" && PATH="$VERIFY3_MISSING_BIN" HERDR_ENV=1 "$BASH_ABS_PATH" "$RUN_SH" launch --base-dir "$VERIFY3_BASE_DIR" \
  --agent claude=pane-claude --agent codex=pane-codex 2>&1)"; then
  rc=0
else
  rc=$?
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$rc" -eq 3 ] && pass "cmd_launch 平台於延遲期間消失時回傳 3" \
  || bad "cmd_launch 平台於延遲期間消失時回傳 $rc，應為 3: $out"
case "$out" in
  *'codex'*) pass "cmd_launch 回傳 3 時訊息點名缺席的 codex" ;;
  *) bad "cmd_launch 回傳 3 時訊息未點名缺席的 codex: $out" ;;
esac
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -f "$VERIFY3_LOGS_DIR/claude.pid" ] && pass "cmd_launch 回傳 3 時連仍在 PATH 上的 claude 也沒有被啟動" \
  || bad "cmd_launch 回傳 3 卻仍啟動了 claude，partial dispatch 沒被擋下"

# --- cmd_launch()'s own --agent cross-check against .roster: opencode is
# on PATH (the stub set up above provides it) but was never selected by
# the earlier VERIFY3 prepare call (--claude --codex only), so this must
# fail as a usage error (exit 2) distinct from verify_selection's own
# exit 3 above, and it must fail before verify_selection or
# launch_reviewer_interactive ever run. A herdr stub is added here (and
# removed again right after) purely as a leak guard for this one
# assertion: $STUB_BIN has had no herdr stub since it was removed before
# the CHMODE2E fixture, so this fixture's own PATH falls through to
# $saved_path -- which has a real herdr installed on this machine -- and
# without a stub here, a regression that let this cli through would
# silently start a real herdr pane instead of failing this assertion. ---

HERDR_LEAK_RECORD="$T/verify3-agent-mismatch-herdr-leak"
rm -f "$HERDR_LEAK_RECORD"
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
: >> "$HERDR_LEAK_RECORD"
exit 0
STUB
chmod +x "$STUB_BIN/herdr"
export HERDR_LEAK_RECORD
assert_cli_stub_only "$STUB_BIN:$saved_path" "$STUB_BIN" claude codex opencode agy herdr

if out="$(cd "$VERIFY3_FIXTURE/work" && HERDR_ENV=1 PATH="$STUB_BIN:$saved_path" "$BASH_ABS_PATH" "$RUN_SH" launch --base-dir "$VERIFY3_BASE_DIR" \
  --agent claude=pane-claude --agent opencode=pane-opencode 2>&1)"; then
  rc=0
else
  rc=$?
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$rc" -eq 2 ] && pass "cmd_launch --agent 點名 prepare 未選中的平台時回傳 2" \
  || bad "cmd_launch --agent 點名 prepare 未選中的平台時回傳 $rc，應為 2: $out"
case "$out" in
  *'opencode'*) pass "cmd_launch 回傳 2 時訊息點名未選中的 opencode" ;;
  *) bad "cmd_launch 回傳 2 時訊息未點名未選中的 opencode: $out" ;;
esac
# The load-bearing assertion: absence of this record, not just an empty
# one, is what proves herdr was never invoked at all -- if
# _check_agents_selected's own call site in cmd_launch ever regressed,
# this would be the first thing to catch a real herdr pane getting
# started for real.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -f "$HERDR_LEAK_RECORD" ] && pass "cmd_launch --agent 平台不符時 herdr 完全沒被呼叫" \
  || bad "cmd_launch --agent 平台不符時仍呼叫了 herdr，dispatch 沒被擋下"

rm -f "$STUB_BIN/herdr"
unset HERDR_LEAK_RECORD

# ==============================================================
# cmd_prepare(): 超大 prompt 要在 prepare 階段就擋下（缺陷 4）
#
# 修正前，PROMPT_BYTE_LIMIT 只在 cmd_launch() 呼叫的
# launch_reviewer_interactive 裡檢查，那時候 worktree、herdr tab 與 pane
# 全都已經建好，白做一場。這裡用一份刻意灌大的 reviewer-contract.md 頂替
# 真正的契約檔，讓 cmd_prepare() 自己的 per-cli 迴圈組出的 prompt 必然超
# 過門檻 -- 複製 run-review.sh 到一個假的 skill 目錄樹底下，讓
# resolve_contract_path 的 `readlink -f "${BASH_SOURCE[0]}"` 解析到這個
# 假樹，是 resolve_contract_path 那組測試已經在用的既有手法，不是新發明
# 的機制。這個情境完全不會走到任何 herdr 呼叫（cmd_prepare() 本身從不
# 執行 herdr，只有 cmd_launch() 才會），所以不需要 herdr stub。
# ==============================================================

OVERSIZED_ROOT="$T/oversized-prompt-e2e-fixture"
mkdir -p "$OVERSIZED_ROOT/skill/scripts" "$OVERSIZED_ROOT/skill/references"
cp "$RUN_SH" "$OVERSIZED_ROOT/skill/scripts/run-review.sh"
head -c "$((PROMPT_BYTE_LIMIT + 50000))" /dev/zero | tr '\0' 'A' > "$OVERSIZED_ROOT/skill/references/reviewer-contract.md"

mkdir -p "$OVERSIZED_ROOT/remotes/acme-oversized" "$OVERSIZED_ROOT/work"
git init -q -b main --bare "$OVERSIZED_ROOT/remotes/acme-oversized/widgets-oversized.git"
git init -q -b main "$OVERSIZED_ROOT/work"
(
  cd "$OVERSIZED_ROOT/work"
  git config user.email t@t.com
  git config user.name t
  printf 'base\n' > f.txt
  git add f.txt
  git commit -q -m base
  git remote add origin "https://github.com/acme-oversized/widgets-oversized.git"
  git config "url.$OVERSIZED_ROOT/remotes/acme-oversized/widgets-oversized.git.insteadOf" "https://github.com/acme-oversized/widgets-oversized.git"
  git push -q origin HEAD:refs/heads/main
  git checkout -q -b feature
  printf 'feature\n' >> f.txt
  git commit -aq -m feature
  git push -q origin feature:refs/pull/1/head
  git checkout -q main
)

OVERSIZED_HOME="$T/oversized-prompt-home"
mkdir -p "$OVERSIZED_HOME"

assert_cli_stub_only "$STUB_BIN:$saved_path" "$STUB_BIN" claude codex opencode agy
if oversized_out="$(cd "$OVERSIZED_ROOT/work" && CLAUDE_CONFIG_DIR="" HOME="$OVERSIZED_HOME" \
  PATH="$STUB_BIN:$saved_path" HERDR_ENV=1 \
  "$BASH_ABS_PATH" "$OVERSIZED_ROOT/skill/scripts/run-review.sh" prepare \
    --pr "https://github.com/acme-oversized/widgets-oversized/pull/1" --claude 2>&1)"; then
  bad cmd-prepare-oversized-prompt-rejected
else
  pass cmd-prepare-oversized-prompt-rejected
fi
case "$oversized_out" in
  *"exceeds limit of $PROMPT_BYTE_LIMIT bytes"*) pass cmd-prepare-oversized-prompt-message-names-limit ;;
  *) bad "cmd-prepare-oversized-prompt-message-names-limit: $oversized_out" ;;
esac

# 缺陷回歸：修正前這道檢查只存在於 launch_reviewer_interactive，此時
# worktree、herdr tab 與 pane 早就已經建好。這裡直接證明 worktree 從未
# 留下痕跡 -- 不是「後來被清掉」，是 cmd_prepare() 自己的 per-cli 迴圈在
# 寫出 prompt 檔的當下就先擋下，走 _dispatch_failed_cleanup。
OVERSIZED_BASE_DIR="$(find "$OVERSIZED_HOME/.tmp" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | head -1)"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -n "$OVERSIZED_BASE_DIR" ] && [ ! -e "$OVERSIZED_BASE_DIR/worktree" ] && pass cmd-prepare-oversized-prompt-worktree-not-left-behind \
  || bad "cmd-prepare-oversized-prompt-worktree-not-left-behind: $OVERSIZED_BASE_DIR"

# --- prepare/launch: jq 前置檢查、print_summary 印出執行目錄 ---

# jq 缺席時 check_prerequisites 必須在動到使用者 repo 之前拒絕執行。gh 的
# 可用性、認證與 PR 存在性都以既有的 gh stub 保證成立（其預設值
# GH_STUB_AUTH_OK=1、GH_STUB_PR_EXISTS=1），讓失敗唯一可能的原因只剩 jq
# 缺席。PATH 不能單純指向 STUB_BIN 本身：stub gh 的 shebang 是
# `#!/usr/bin/env bash`，PATH 中若沒有目錄能解析出 bash，連 stub 都執行
# 不了，會用「gh 沒有通過認證」這種假訊號蓋過真正要測的 jq 缺席 -- 因此
# 這裡另外準備一個只含 gh（連到既有 stub）與 bash（連到真正的 bash）兩個
# symlink 的乾淨目錄，不含 jq，也不含 git（check_prerequisites 用不到）。
JQ_MISSING_BIN="$T/jq-missing-bin"
mkdir -p "$JQ_MISSING_BIN"
ln -s "$STUB_BIN/gh" "$JQ_MISSING_BIN/gh"
ln -s "$(command -v bash)" "$JQ_MISSING_BIN/bash"
export PATH="$JQ_MISSING_BIN"
if _check_gh_available >/dev/null 2>&1 && check_prerequisites acme widgets 7 >/dev/null 2>&1; then
  bad prereq-jq-missing
else
  pass prereq-jq-missing
fi
export PATH="$saved_path"

# print_summary 要印出執行目錄與 summary.txt 的絕對路徑，讓呼叫端不必從
# 輸出檔路徑往上推兩層。用完整標籤字串比對（而非只比對 $PS_ROOT 本身），
# 因為既有的 dispatched 輸出檔那一行本來就已經以 $PS_ROOT 開頭，光比對
# $PS_ROOT 子字串不能真正證明是新加的那兩行執行目錄／摘要檔輸出。
PS_ROOT="$T/print-summary-paths"
mkdir -p "$PS_ROOT"
PS_OUT="$(print_summary "$PS_ROOT" claude:p1 --skipped codex opencode)"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF "$PS_ROOT/summary.txt" <<<"$PS_OUT" && pass print-summary-shows-summary-path || bad print-summary-shows-summary-path
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF "本次執行目錄：$PS_ROOT" <<<"$PS_OUT" && pass print-summary-shows-run-dir || bad print-summary-shows-run-dir

# ==============================================================
# 審查契約強化：失敗情境、高風險變更、信心等級、摺疊區
# ==============================================================

# ---- 契約含三項新規定 ----
mkdir -p "$T/materials-empty" "$T/wt"
contract="$REPO/skills/pr-review-by-multi-agents/references/reviewer-contract.md"
for kw in "失敗情境" "高風險變更" "信心" "<details>"; do
  if grep -q "$kw" "$contract"; then
    pass "契約含關鍵段落: $kw"
  else
    bad "契約缺少關鍵段落: $kw"
  fi
done

# ---- build_prompt 把契約原文嵌入 ----
# 用 `if cmd; then ...; else rc=$?; fi` 接住結束碼與 stderr，不用
# `out="$(cmd)" || out=""` 那種寫法：後者的 `||` 會把失敗原因整個丟掉——
# 這條斷言本身在這個分支開發期間曾被三個不同 agent 各自獨立撞見過一次
# 間歇性失敗，26 次各自獨立重跑都重現不出來，每次撞見時機器都在跑其他
# 高負載工作。真正原因後來查清了，不在這裡的 `if cmd; then ...`，而在
# 緊接在後面那一行：`printf '%s' "$prompt_out" | grep -q ...` 這種寫法，
# 搭配本檔開頭的 set -o pipefail，一比對到就立刻結束的 grep -q 會在
# printf 還沒把內容寫完前就關閉讀取端，讓 printf 收到 SIGPIPE 以 141
# 結束；pipefail 之下這個 141 會蓋過 grep 本身「找到了」的 0，讓整條
# 管線回報失敗，即使比對其實成功。這裡嵌入的是 93KB 的
# reviewer-contract.md 全文，遠超過管線緩衝區，所以不是偶發而是機械
# 必然，只是命中哪一次重跑要看行程排程的時機。已改用下面的 herestring
# （<<<）取代這條管線：讀取端不再是另一個行程，沒有行程可收 SIGPIPE，
# 這個假失敗不會再發生。
BUILD_PROMPT_STDERR="$T/build-prompt.stderr"
if prompt_out="$(build_prompt "$contract" "https://github.com/a/b/pull/1" \
  "$T/materials-empty" "claude" "opus-5" "$T/wt" "origin/main" "$T/wt/review.md" 2>"$BUILD_PROMPT_STDERR")"; then
  prompt_rc=0
else
  prompt_rc=$?
  prompt_out=""
fi
if grep -q "高風險變更" <<<"$prompt_out"; then
  pass "build_prompt 嵌入了高風險變更清單"
else
  bad "build_prompt 未嵌入契約新內容（exit=$prompt_rc, stderr: $(cat "$BUILD_PROMPT_STDERR" 2>/dev/null)）"
fi

# ==============================================================
# resolve_synthesis_contract_path / synthesis-contract.md
# ==============================================================

# ---- 合流契約可被解析到 ----
if out="$(resolve_synthesis_contract_path)" && [ -f "$out" ]; then
  pass "resolve_synthesis_contract_path 指到存在的檔案"
else
  bad "resolve_synthesis_contract_path 失敗: $out"
fi

# ---- 合流契約含必要段落 ----
sc="$REPO/skills/pr-review-by-multi-agents/references/synthesis-contract.md"
for kw in "矛盾" "platform/model" "重新計算" "摺疊區" "揭露"; do
  if grep -q "$kw" "$sc"; then
    pass "合流契約含: $kw"
  else
    bad "合流契約缺: $kw"
  fi
done

# Symlink case: mirrors resolve_contract_path's symlink case above -- this
# fixture symlinks only run-review.sh itself, not the whole skill directory
# the way install.sh actually deploys it, but readlink resolves
# BASH_SOURCE[0] the same way regardless of which level of the path is the
# symlink, so this still exercises the exact resolution step
# (readlink -f "${BASH_SOURCE[0]}") that install.sh's real deployment
# depends on.
SYNTHESIS_SYMLINKED_SKILL="$T/synthesis-symlinked-skill"
mkdir -p "$SYNTHESIS_SYMLINKED_SKILL/scripts"
ln -s "$RUN_SH" "$SYNTHESIS_SYMLINKED_SKILL/scripts/run-review.sh"
out="$(bash -c "source '$SYNTHESIS_SYMLINKED_SKILL/scripts/run-review.sh'; resolve_synthesis_contract_path")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$out" = "$sc" ] && pass synthesis-contract-path-symlink || bad synthesis-contract-path-symlink

# Missing case: a scripts/ directory with no sibling references/ at all ->
# non-zero, no stdout. Must not be confused with the symlink case above.
SYNTHESIS_NO_CONTRACT_SKILL="$T/synthesis-no-contract-skill"
mkdir -p "$SYNTHESIS_NO_CONTRACT_SKILL/scripts"
cp "$RUN_SH" "$SYNTHESIS_NO_CONTRACT_SKILL/scripts/run-review.sh"
if out="$(bash -c "source '$SYNTHESIS_NO_CONTRACT_SKILL/scripts/run-review.sh'; resolve_synthesis_contract_path" 2>/dev/null)"; then
  bad synthesis-contract-path-missing
else
  pass synthesis-contract-path-missing
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -z "$out" ] && pass synthesis-contract-path-missing-no-output || bad synthesis-contract-path-missing-no-output

# ==============================================================
# Task 7: 合流行程
#
# _count_ready / _first_ready_cli / _ready_content_files /
# build_synthesis_prompt / launch_synthesis / _record_synthesis_result,
# and spawn_supervisor_interactive's own tail wiring that strings them
# together once every reviewer has finished and the worktree is gone.
# ==============================================================

# ---- _disclosure_status_label 把三個 raw content_status 譯成合流契約
# 要求的詞彙，未知值則明確標示而非偽裝成已知的三者之一 ----
dsl_out="$(_disclosure_status_label ready)"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$dsl_out" = "完成" ] && pass "_disclosure_status_label ready -> 完成" || bad "_disclosure_status_label ready 譯成: $dsl_out"
dsl_out="$(_disclosure_status_label withheld)"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$dsl_out" = "完成但內容被判定為不可信" ] && pass "_disclosure_status_label withheld -> 完成但內容被判定為不可信" || bad "_disclosure_status_label withheld 譯成: $dsl_out"
dsl_out="$(_disclosure_status_label no-content)"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$dsl_out" = "失敗" ] && pass "_disclosure_status_label no-content -> 失敗" || bad "_disclosure_status_label no-content 譯成: $dsl_out"
dsl_out="$(_disclosure_status_label some-unexpected-value)"
case "$dsl_out" in
  *"some-unexpected-value"*) pass "_disclosure_status_label 未知值不偽裝成三者之一" ;;
  *) bad "_disclosure_status_label 未知值被吃掉或誤判: $dsl_out" ;;
esac

# ---- build_synthesis_prompt 內嵌契約、名單與各份 review 的固定樣本 ----
# 四份都各代表不同狀態：claude/agy 是 ready，codex 是「沒有內容」
# （沒有標記可抓），opencode 是「內容被判定為不可信」（標記齊全、有
# content_file，但 exit 非零或 worktree 被竄改而 withheld）——這兩類都
# 是簡報明列要擋在合流輸入之外的類別，缺一都會讓涵蓋不完整。
mkdir -p "$T/synth"
cat > "$T/synth/summary.txt" <<'SUM'
cli=claude pid=111 exit=0 ended_at=2026-08-27T00:00:00Z worktree_status=ok content_status=ready content_file=T_PLACEHOLDER/synth/.comment-body-111.md
cli=agy pid=222 exit=0 ended_at=2026-08-27T00:00:01Z worktree_status=ok content_status=ready content_file=T_PLACEHOLDER/synth/.comment-body-222.md
cli=codex pid=333 exit=1 ended_at=2026-08-27T00:00:02Z worktree_status=ok content_status=no-content content_file=
cli=opencode pid=444 exit=1 ended_at=2026-08-27T00:00:03Z worktree_status=ok content_status=withheld content_file=T_PLACEHOLDER/synth/.comment-body-444.md
SUM
sed -i "s#T_PLACEHOLDER#$T#g" "$T/synth/summary.txt"
printf 'REVIEW-FROM-CLAUDE\n' > "$T/synth/.comment-body-111.md"
printf 'REVIEW-FROM-AGY\n'    > "$T/synth/.comment-body-222.md"
printf 'REVIEW-FROM-OPENCODE-WITHHELD\n' > "$T/synth/.comment-body-444.md"
# Lines end in " dispatched", matching exactly what cmd_prepare() itself
# writes to .roster (see cmd_prepare()'s own .roster-writing loop) and what
# build_synthesis_prompt's roster-lookup sed pattern requires to match at
# all -- a line ending in anything else (e.g. "completed"/"failed") would
# silently never match, always falling through to the missing-entry
# 未提供 case regardless of content.
printf 'claude opus-5 dispatched\nagy gemini-3.8-flash-high dispatched\ncodex unknown-model dispatched\nopencode qwen3-max dispatched\n' \
  > "$T/synth/roster.txt"

# ---- _count_ready 正確計數 ----
n="$(_count_ready "$T/synth/summary.txt")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$n" -eq 2 ] && pass "_count_ready 回傳 2" || bad "_count_ready 回傳 $n"

# ---- _count_ready 零命中時只印一行 "0"，不因 grep -c 自己已印出 "0"
# 而讓 fallback 再多印一行（這是逐字照抄 brief 給的程式碼會踩到的真實
# bug：grep -c 找不到符合時本身就會印 "0" 並回傳非零，`|| printf '0\n'`
# 這時會在後面再補一行，讓呼叫端拿到 "0\n0" 兩行，`-ge 2` 比對就會噴
# "integer expression expected"）----
ZERO_READY_SUMMARY="$T/synth/summary-zero-ready.txt"
printf 'cli=codex pid=999 exit=1 ended_at=2026-08-27T00:00:03Z worktree_status=ok content_status=no-content content_file=\n' \
  > "$ZERO_READY_SUMMARY"
zn="$(_count_ready "$ZERO_READY_SUMMARY")"
case "$zn" in
  *$'\n'*) bad "_count_ready 零命中時印出超過一行" ;;
  0) pass "_count_ready 零命中時只印一行 0" ;;
  *) bad "_count_ready 零命中時輸出不是 0: $zn" ;;
esac

# ---- _first_ready_cli 取第一個完成的 CLI ----
c="$(_first_ready_cli "$T/synth/summary.txt")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$c" = "claude" ] && pass "_first_ready_cli 回傳 claude" || bad "_first_ready_cli 回傳 $c"

# ---- _select_synthesis_cli 偏好可被鎖到零工具的 CLI，即使它不是第一個
# ready -- codex 的 read-only sandbox 只擋本地檔案寫入，shell 與網路仍
# 可用；claude 的允許清單為空、shell 工具整個被禁用，屬於能被鎖到底的
# 那一種。故意讓 codex 先於 claude 完成，驗證挑選依據不是單純的
# dispatch 順序 ----
mkdir -p "$T/synth-lockable"
cat > "$T/synth-lockable/summary.txt" <<'SUM'
cli=codex pid=555 exit=0 ended_at=2026-08-27T00:00:00Z worktree_status=ok content_status=ready content_file=T_PLACEHOLDER/synth-lockable/.comment-body-555.md
cli=claude pid=666 exit=0 ended_at=2026-08-27T00:00:01Z worktree_status=ok content_status=ready content_file=T_PLACEHOLDER/synth-lockable/.comment-body-666.md
SUM
sed -i "s#T_PLACEHOLDER#$T#g" "$T/synth-lockable/summary.txt"
lc="$(_select_synthesis_cli "$T/synth-lockable/summary.txt")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$lc" = "claude" ] && pass "_select_synthesis_cli 偏好可鎖定的 claude 而非先完成的 codex" || bad "_select_synthesis_cli 回傳 $lc"

# ---- _select_synthesis_cli 當 ready 的都是不可被鎖到零工具的 CLI 時，
# 仍要退回選出一個，不能因為找不到可鎖定的選項就選不出任何 CLI ----
mkdir -p "$T/synth-no-lockable"
cat > "$T/synth-no-lockable/summary.txt" <<'SUM'
cli=opencode pid=777 exit=0 ended_at=2026-08-27T00:00:00Z worktree_status=ok content_status=ready content_file=T_PLACEHOLDER/synth-no-lockable/.comment-body-777.md
cli=codex pid=888 exit=0 ended_at=2026-08-27T00:00:01Z worktree_status=ok content_status=ready content_file=T_PLACEHOLDER/synth-no-lockable/.comment-body-888.md
SUM
sed -i "s#T_PLACEHOLDER#$T#g" "$T/synth-no-lockable/summary.txt"
nlc="$(_select_synthesis_cli "$T/synth-no-lockable/summary.txt")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -n "$nlc" ] && pass "_select_synthesis_cli 沒有可鎖定選項時仍選出一個 CLI" || bad "_select_synthesis_cli 沒有可鎖定選項時選不出任何 CLI"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$nlc" = "opencode" ] && pass "_select_synthesis_cli 沒有可鎖定選項時退回第一個完成者" || bad "_select_synthesis_cli 回傳 $nlc"

# ---- _ready_content_files 只列出 ready 的兩行，且對應內容檔路徑正確 ----
rcf_out="$(_ready_content_files "$T/synth/summary.txt")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$(printf '%s\n' "$rcf_out" | wc -l)" -eq 2 ] && pass "_ready_content_files 只印兩行" || bad "_ready_content_files 印了非兩行: $rcf_out"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF "$(printf 'claude\t%s/synth/.comment-body-111.md' "$T")" <<<"$rcf_out" \
  && pass "_ready_content_files 含 claude 那一行" || bad "_ready_content_files 缺 claude 那一行"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF "$(printf 'agy\t%s/synth/.comment-body-222.md' "$T")" <<<"$rcf_out" \
  && pass "_ready_content_files 含 agy 那一行" || bad "_ready_content_files 缺 agy 那一行"
case "$rcf_out" in
  *codex*) bad "_ready_content_files 誤含 codex（content_status=no-content）" ;;
  *) pass "_ready_content_files 排除 no-content 的 codex" ;;
esac
# opencode 這行是 content_status=withheld：標記齊全、確實有 content_file
# （不像 codex 的 no-content 那樣連檔案都沒有），但已被判定內容不可
# 信。這是簡報明列要擋的另一類，與「沒有內容」是不同的失敗形狀，兩者
# 都要各自有測試涵蓋，缺一都不算涵蓋完整。
case "$rcf_out" in
  *opencode*) bad "_ready_content_files 誤含 opencode（content_status=withheld）" ;;
  *) pass "_ready_content_files 排除 withheld 的 opencode" ;;
esac

# ---- build_synthesis_prompt 內嵌契約、兩份 review 與完整名單（含未成
# 功的 codex 與 withheld 的 opencode）----
out="$(build_synthesis_prompt \
  "$REPO/skills/pr-review-by-multi-agents/references/synthesis-contract.md" \
  "$T/synth/roster.txt" "$T/synth/summary.txt" "claude" "opus-5-synth-marker")"
if grep -q 'REVIEW-FROM-CLAUDE' <<<"$out" \
  && grep -q 'REVIEW-FROM-AGY' <<<"$out" \
  && grep -q '共識' <<<"$out" \
  && grep -q 'codex' <<<"$out" \
  && grep -q 'opencode' <<<"$out" ; then
  pass "build_synthesis_prompt 內嵌契約、兩份 review 與完整名單"
else
  bad "build_synthesis_prompt 內容不完整"
fi

# ---- 不得內嵌 no-content（連標記都沒有）的內容 ----
if grep -q 'comment-body-333' <<<"$out"; then
  bad "build_synthesis_prompt 誤含 no-content 的內容檔"
else
  pass "build_synthesis_prompt 只取 ready 的內容"
fi

# ---- 不得內嵌 withheld（標記齊全但被判定不可信）的內容全文，即使該
# CLI 仍要出現在名單的揭露段落裡 ----
if grep -q 'REVIEW-FROM-OPENCODE-WITHHELD' <<<"$out"; then
  bad "build_synthesis_prompt 誤含 withheld 的 review 全文"
else
  pass "build_synthesis_prompt 排除 withheld 的 review 全文"
fi
# 名單這一欄印的必須是合流契約要的三個詞之一（完成／失敗／完成但內容被
# 判定為不可信），不是 content_status 的原始英文值——契約禁止合流過程
# 自行把 raw token 歸類，所以這個翻譯必須在這裡（呼叫端）就做完。四筆各
# 代表一種原始值：claude/agy 是 ready、codex 是 no-content、opencode 是
# withheld。
case "$out" in
  *'claude / opus-5：完成'*) pass "build_synthesis_prompt 名單把 claude 的 ready 譯成完成" ;;
  *) bad "build_synthesis_prompt 名單未把 claude 的 ready 譯成完成" ;;
esac
case "$out" in
  *'agy / gemini-3.8-flash-high：完成'*) pass "build_synthesis_prompt 名單把 agy 的 ready 譯成完成" ;;
  *) bad "build_synthesis_prompt 名單未把 agy 的 ready 譯成完成" ;;
esac
case "$out" in
  *'codex / unknown-model：失敗'*) pass "build_synthesis_prompt 名單把 codex 的 no-content 譯成失敗" ;;
  *) bad "build_synthesis_prompt 名單未把 codex 的 no-content 譯成失敗" ;;
esac
case "$out" in
  *'opencode / qwen3-max：完成但內容被判定為不可信'*) pass "build_synthesis_prompt 名單把 opencode 的 withheld 譯成完成但內容被判定為不可信" ;;
  *) bad "build_synthesis_prompt 名單未把 opencode 的 withheld 譯成契約詞彙" ;;
esac
# 原始英文 token 不應該逐字出現在名單這一欄，防止翻譯被移除或繞過時測
# 試仍然通過。
case "$out" in
  *'：ready'*|*'：withheld'*|*'：no-content'*)
    bad "build_synthesis_prompt 名單仍外洩 content_status 的原始英文值"
    ;;
  *)
    pass "build_synthesis_prompt 名單不外洩 content_status 的原始英文值"
    ;;
esac

# ---- 控制端裁決帶入的額外要求：build_synthesis_prompt 必須揭露執行合
# 流本身的 CLI 與 model，不只是各份 review 自己的身分。用一個與名單裡
# 任何 model 字串都不同的標記值，確認確實是新加的這一段揭露，不是撞到
# 既有名單或 review 內容裡的字串 ----
if grep -qF 'opus-5-synth-marker' <<<"$out"; then
  pass "build_synthesis_prompt 揭露執行合流本身的 model"
else
  bad "build_synthesis_prompt 未揭露執行合流本身的 model"
fi
if grep -qF 'CLI 名稱：claude' <<<"$out"; then
  pass "build_synthesis_prompt 揭露執行合流本身的 CLI 名稱"
else
  bad "build_synthesis_prompt 未揭露執行合流本身的 CLI 名稱"
fi

# ---- 名單檔缺漏某個 CLI 的紀錄時，該欄要明確寫成「未提供」，不是留
# 空白（合流契約要求缺漏一律據實記為未提供，不得渲染成看起來像沒填的
# 空格）----
ROSTER_GAP_SUMMARY="$T/synth/summary-roster-gap.txt"
printf 'cli=claude pid=555 exit=0 ended_at=2026-08-27T00:00:04Z worktree_status=ok content_status=ready content_file=%s/synth/.comment-body-555.md\n' "$T" \
  > "$ROSTER_GAP_SUMMARY"
printf 'cli=agy pid=666 exit=0 ended_at=2026-08-27T00:00:05Z worktree_status=ok content_status=ready content_file=%s/synth/.comment-body-666.md\n' "$T" \
  >> "$ROSTER_GAP_SUMMARY"
printf 'REVIEW-GAP-A\n' > "$T/synth/.comment-body-555.md"
printf 'REVIEW-GAP-B\n' > "$T/synth/.comment-body-666.md"
# roster-gap.txt 只記錄 agy，claude 這筆缺漏
printf 'agy some-model dispatched\n' > "$T/synth/roster-gap.txt"

gap_out="$(build_synthesis_prompt \
  "$REPO/skills/pr-review-by-multi-agents/references/synthesis-contract.md" \
  "$T/synth/roster-gap.txt" "$ROSTER_GAP_SUMMARY" "claude" "some-synth-model")"
if grep -qF -- '- claude / 未提供：完成' <<<"$gap_out"; then
  pass "build_synthesis_prompt 名單缺漏時把 model 寫成未提供"
else
  bad "build_synthesis_prompt 名單缺漏時未寫成未提供"
fi
if grep -qF -- '- agy / some-model：完成' <<<"$gap_out"; then
  pass "build_synthesis_prompt 名單有紀錄的那筆不受缺漏影響"
else
  bad "build_synthesis_prompt 名單有紀錄的那筆被誤判"
fi

# ---- 名單檔整個不存在時（不是「有檔案但缺一筆」，是連檔案都沒有）
# 也不能讓整個函式中止。這不只是渲染問題：build_synthesis_prompt 是在
# spawn_supervisor_interactive 自己的 set -e 子行程裡跑的，`model="$(sed
# ... 2>/dev/null)"` 這種一般賦值句不像放在 `[ ]`／`if` 裡的指令替換那
# 樣豁免 errexit——名單檔不存在時 sed 本身結束碼非零（2>/dev/null 只是
# 消掉錯誤訊息，不會連結束碼也吃掉），沒有 `|| model=""` 接住的話，整
# 個函式會在這裡靜默中止：不留錯誤訊息、不留摘要行、什麼都不剩。這正
# 是先前一個直接呼叫已移除的無頭監督函式、從不寫 .roster 的 fixture
# 曾經踩到的真實情境，之前這個中止完全沒有任何徵狀，唯一的旁
# 證是 synthesis.log 從未出現過。----
NO_ROSTER_FILE="$T/synth/nonexistent-roster.txt"
if noroster_out="$(build_synthesis_prompt \
  "$REPO/skills/pr-review-by-multi-agents/references/synthesis-contract.md" \
  "$NO_ROSTER_FILE" "$ROSTER_GAP_SUMMARY" "claude" "some-synth-model" 2>&1)"; then
  pass "build_synthesis_prompt 名單檔整個不存在時仍正常回傳"
else
  bad "build_synthesis_prompt 名單檔整個不存在時卻中止: $noroster_out"
fi
if grep -qF -- '- claude / 未提供：完成' <<<"$noroster_out"; then
  pass "build_synthesis_prompt 名單檔整個不存在時把 model 寫成未提供"
else
  bad "build_synthesis_prompt 名單檔整個不存在時未寫成未提供"
fi

# ---- 契約檔本身讀不到（路徑指向不存在的檔案）時，函式必須整個中
# 止，不得吞掉這個失敗、繼續往下印出座標、名單與各份 review 全文後仍
# 回傳成功。這是與 build_prompt 姊妹函式先前已修過的同一種缺陷：這裡
# 的呼叫跟 spawn_supervisor_interactive 自己的呼叫一樣包在
# `if build_synthesis_prompt ...; then` 底下，整個函式體因此豁免 set -e
# 的 errexit，函式裡沒接
# `|| return 1` 的那一行讀檔失敗就會被靜默吞掉，讓呼叫端拿到一份完全
# 沒有合流契約指示、卻仍判定為成功的 prompt。----
NO_CONTRACT_FILE="$T/synth/nonexistent-contract.md"
if nocontract_out="$(build_synthesis_prompt \
  "$NO_CONTRACT_FILE" \
  "$T/synth/roster.txt" "$T/synth/summary.txt" "claude" "some-synth-model" 2>/dev/null)"; then
  bad "build_synthesis_prompt 契約檔讀不到時仍回傳成功: $nocontract_out"
else
  pass "build_synthesis_prompt 契約檔讀不到時回傳非零"
fi

# ==============================================================
# build_synthesis_prompt -- 保護閘：summary 判定 ready 的兩筆，其實際
# content_file 在函式執行當下卻都讀不到（檔案在 summary 寫完之後被刪
# 除、變得不可讀，或路徑本身就是假的），不得讓合流吃到一份沒有任何
# review 全文的 prompt。這是這個分支的審查抓出的兩個真功能缺口之一：
# 修正前，每個 content_file 是逐檔靜默跳過，即使全部跳光也照樣印出前
# 面的契約、身分與名單三段並回傳成功，讓 launch_synthesis 拿一份沒有
# 任何 review 內容的 prompt 去跑，其輸出卻仍會被判定為 ready、成為唯
# 一貼上 PR 的東西。
# ==============================================================
mkdir -p "$T/synth-no-embeddable"
cat > "$T/synth-no-embeddable/summary.txt" <<'SUM'
cli=claude pid=901 exit=0 ended_at=2026-08-27T00:00:00Z worktree_status=ok content_status=ready content_file=T_PLACEHOLDER/synth-no-embeddable/.comment-body-901.md
cli=agy pid=902 exit=0 ended_at=2026-08-27T00:00:01Z worktree_status=ok content_status=ready content_file=T_PLACEHOLDER/synth-no-embeddable/.comment-body-902.md
SUM
sed -i "s#T_PLACEHOLDER#$T#g" "$T/synth-no-embeddable/summary.txt"
# 兩份 content_file 都刻意不建立——模擬 summary 已經寫下 ready，但實際
# 檔案在合流真正跑起來之前就消失或從未落地的情境。
printf 'claude some-model dispatched\nagy some-model dispatched\n' > "$T/synth-no-embeddable/roster.txt"

NOEMBED_STDERR="$T/synth-no-embeddable/stderr"
if noembed_out="$(build_synthesis_prompt \
  "$REPO/skills/pr-review-by-multi-agents/references/synthesis-contract.md" \
  "$T/synth-no-embeddable/roster.txt" "$T/synth-no-embeddable/summary.txt" \
  "claude" "some-synth-model" 2>"$NOEMBED_STDERR")"; then
  bad "build_synthesis_prompt 在完全嵌不到任何 review 全文時仍回傳成功: $noembed_out"
else
  pass "build_synthesis_prompt 在完全嵌不到任何 review 全文時回傳非零"
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -s "$NOEMBED_STDERR" ] && pass "build_synthesis_prompt 嵌不到任何內容時在 stderr 留下原因" || bad "build_synthesis_prompt 嵌不到任何內容時 stderr 是空的"

# ---- 對照組：只要至少一份能嵌入，就不該觸發這道保護閘 ----
mkdir -p "$T/synth-one-embeddable"
cat > "$T/synth-one-embeddable/summary.txt" <<'SUM'
cli=claude pid=903 exit=0 ended_at=2026-08-27T00:00:00Z worktree_status=ok content_status=ready content_file=T_PLACEHOLDER/synth-one-embeddable/.comment-body-903.md
cli=agy pid=904 exit=0 ended_at=2026-08-27T00:00:01Z worktree_status=ok content_status=ready content_file=T_PLACEHOLDER/synth-one-embeddable/.comment-body-904.md
SUM
sed -i "s#T_PLACEHOLDER#$T#g" "$T/synth-one-embeddable/summary.txt"
printf 'REVIEW-ONE-EMBEDDABLE\n' > "$T/synth-one-embeddable/.comment-body-903.md"
# .comment-body-904.md 故意不建立，模擬其中一份消失、另一份還在的情境
printf 'claude some-model dispatched\nagy some-model dispatched\n' > "$T/synth-one-embeddable/roster.txt"

if oneembed_out="$(build_synthesis_prompt \
  "$REPO/skills/pr-review-by-multi-agents/references/synthesis-contract.md" \
  "$T/synth-one-embeddable/roster.txt" "$T/synth-one-embeddable/summary.txt" \
  "claude" "some-synth-model")"; then
  pass "build_synthesis_prompt 只要有一份可嵌入就不觸發保護閘"
else
  bad "build_synthesis_prompt 有一份可嵌入卻仍被保護閘擋下"
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -q 'REVIEW-ONE-EMBEDDABLE' <<<"$oneembed_out" && pass "build_synthesis_prompt 對照組確實嵌入了那唯一一份 review" || bad "build_synthesis_prompt 對照組未嵌入那唯一一份 review"

# ==============================================================
# launch_synthesis
#
# Recording stubs, the same technique launch_reviewer_interactive's own
# tests use elsewhere in this file, so this can assert on exactly what
# launch_synthesis handed the underlying CLI: narrower flags than
# launch_reviewer_interactive's own (no allowedTools at all for claude, an
# empty agy permission list instead of the reviewer's `command(git diff)`
# allowance), and that the prompt actually arrives over stdin.
# ==============================================================

SYNTH_LAUNCH_ROOT="$T/synth-launch-fixture"
mkdir -p "$SYNTH_LAUNCH_ROOT"
SYNTH_LAUNCH_RECORD_DIR="$SYNTH_LAUNCH_ROOT/records"
mkdir -p "$SYNTH_LAUNCH_RECORD_DIR"

SYNTH_LAUNCH_STUB_BIN="$T/synth-launch-stub-bin"
mkdir -p "$SYNTH_LAUNCH_STUB_BIN"
cat > "$SYNTH_LAUNCH_STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
name="$(basename "$0")"
: > "$SYNTH_LAUNCH_RECORD_DIR/$name.argv"
for a in "$@"; do printf '%s\n' "$a" >> "$SYNTH_LAUNCH_RECORD_DIR/$name.argv"; done
printf '%s' "${HOME:-}" > "$SYNTH_LAUNCH_RECORD_DIR/$name.env-home"
cat > "$SYNTH_LAUNCH_RECORD_DIR/$name.stdin"
echo "===PR-REVIEW-BY-MULTI-AGENTS-BEGIN==="
echo "stub $name synthesis ran"
echo "===PR-REVIEW-BY-MULTI-AGENTS-END==="
exit 0
STUB
chmod +x "$SYNTH_LAUNCH_STUB_BIN/claude"
cp "$SYNTH_LAUNCH_STUB_BIN/claude" "$SYNTH_LAUNCH_STUB_BIN/codex"
cp "$SYNTH_LAUNCH_STUB_BIN/claude" "$SYNTH_LAUNCH_STUB_BIN/opencode"
# agy gets its own stub, not a copy of claude's: a stub that merely
# records argv without enforcing anything could not have caught the
# real regression this task's own review round found -- launch_
# synthesis's agy branch passed a bare, unattached -p, which a real agy
# binary rejects outright ("flag needs an argument: -p", exit 2), same
# as the now-removed headless reviewer launcher's own agy branch already
# documented. This stub
# reproduces exactly that one behavior (a bare -p/--print as the LAST
# argument, i.e. nothing following it supplies its value, is rejected)
# so a future regression that reintroduces the bare flag fails this
# test the same way it would fail against the real binary, instead of
# a stub silently succeeding regardless of what it was actually handed.
cat > "$SYNTH_LAUNCH_STUB_BIN/agy" <<'STUB'
#!/usr/bin/env bash
name="$(basename "$0")"
args=("$@")
: > "$SYNTH_LAUNCH_RECORD_DIR/$name.argv"
for a in "${args[@]}"; do printf '%s\n' "$a" >> "$SYNTH_LAUNCH_RECORD_DIR/$name.argv"; done
printf '%s' "${HOME:-}" > "$SYNTH_LAUNCH_RECORD_DIR/$name.env-home"
if [ "${#args[@]}" -gt 0 ] && { [ "${args[-1]}" = "-p" ] || [ "${args[-1]}" = "--print" ]; }; then
  echo "flag needs an argument: ${args[-1]}" >&2
  exit 2
fi
cat > "$SYNTH_LAUNCH_RECORD_DIR/$name.stdin"
echo "===PR-REVIEW-BY-MULTI-AGENTS-BEGIN==="
echo "stub $name synthesis ran"
echo "===PR-REVIEW-BY-MULTI-AGENTS-END==="
exit 0
STUB
chmod +x "$SYNTH_LAUNCH_STUB_BIN/agy"

export PATH="$SYNTH_LAUNCH_STUB_BIN:$saved_path"
export SYNTH_LAUNCH_RECORD_DIR
assert_cli_stub_only "$PATH" "$SYNTH_LAUNCH_STUB_BIN" claude codex opencode agy

# ---- claude：--allowedTools 的值是空字串，--disallowedTools 涵蓋
# Edit/Write/NotebookEdit，prompt 確實透過 stdin 完整送達 ----
SYNTH_LAUNCH_LOG_CLAUDE="$SYNTH_LAUNCH_ROOT/claude.synthesis.log"
printf 'synthesis prompt for claude\n' > "$SYNTH_LAUNCH_ROOT/claude.prompt"
synth_launch_pid_claude="$(launch_synthesis claude "$SYNTH_LAUNCH_ROOT" "$SYNTH_LAUNCH_LOG_CLAUDE" < "$SYNTH_LAUNCH_ROOT/claude.prompt")"

i=0
until [ -f "$SYNTH_LAUNCH_ROOT/.synthesis-exit-$synth_launch_pid_claude" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -f "$SYNTH_LAUNCH_ROOT/.synthesis-exit-$synth_launch_pid_claude" ] && pass "launch_synthesis 寫出 exit 檔" || bad "launch_synthesis 未寫出 exit 檔"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$(cat "$SYNTH_LAUNCH_ROOT/.synthesis-exit-$synth_launch_pid_claude" 2>/dev/null)" = "0" ] && pass "launch_synthesis exit=0" || bad "launch_synthesis exit 不是 0"

synth_launch_claude_argv="$(cat "$SYNTH_LAUNCH_RECORD_DIR/claude.argv" 2>/dev/null)"
case "$synth_launch_claude_argv" in
  *'--allowedTools'*) pass "launch_synthesis claude 有 --allowedTools" ;;
  *) bad "launch_synthesis claude 缺 --allowedTools" ;;
esac
# --allowedTools 的值本身是空字串，是獨立的一個 argv 項；找出緊接在
# --allowedTools 那一行之後的下一行，確認它是空行。
synth_launch_claude_allowedtools_value="$(awk '/^--allowedTools$/{getline; print; exit}' "$SYNTH_LAUNCH_RECORD_DIR/claude.argv")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -z "$synth_launch_claude_allowedtools_value" ] && pass "launch_synthesis claude 的 --allowedTools 值為空字串" || bad "launch_synthesis claude 的 --allowedTools 值不是空字串: [$synth_launch_claude_allowedtools_value]"
# disallowedTools 的值本身也是獨立一個 argv 項：找出緊接在
# --disallowedTools 之後的那一行，逐字比對，確認四項都在（Edit、Write、
# NotebookEdit、WebFetch）且額外加上 Bash 整個工具整體停用——這一項比
# 已移除的無頭 reviewer launcher 的 claude 分支更嚴：該分支當年的說明
# 記載了實測結論，dontAsk 的「唯讀 Bash 一律放行」例外實際上放得比字
# 面寬，curl 打得通、把該指令加進黑名單也擋不住，唯一驗證有效的做法
# 是整個停用 Bash 工具；reviewer 做不到是因為審查契約釘死要跑
# git diff，合流沒有這個限制，所以理當走到底。
synth_launch_claude_disallowed_value="$(awk '/^--disallowedTools$/{getline; print; exit}' "$SYNTH_LAUNCH_RECORD_DIR/claude.argv")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$synth_launch_claude_disallowed_value" = "Edit Write NotebookEdit WebFetch Bash" ] \
  && pass "launch_synthesis claude 停用 Edit/Write/NotebookEdit/WebFetch/Bash" \
  || bad "launch_synthesis claude 的 --disallowedTools 值不對: [$synth_launch_claude_disallowed_value]"

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
diff -q "$SYNTH_LAUNCH_ROOT/claude.prompt" "$SYNTH_LAUNCH_RECORD_DIR/claude.stdin" >/dev/null 2>&1 \
  && pass "launch_synthesis 透過 stdin 完整收到 prompt" || bad "launch_synthesis 未透過 stdin 收到完整 prompt"

# ---- agy：獨立的 HOME，且 permissions.allow 是空陣列（比 reviewer 版
# 本的 agy home 更嚴——reviewer 還留了 command(git diff) 這一條），而且
# 命令列不能帶裸的 -p/--print（真正的 agy 二進位會以「flag needs an
# argument」拒絕、結束碼 2）——這一條的 exit=0 斷言就是先前那個 Critical
# 問題本來該被抓到卻沒抓到的地方：舊的樁完全忽略命令列參數，不管給它
# 什麼都回 0，現在改用會真正檢查最後一個參數的樁（見上面 agy 樁的定
# 義），才會在裸 -p 重新出現時讓這裡失敗。----
SYNTH_LAUNCH_LOG_AGY="$SYNTH_LAUNCH_ROOT/agy.synthesis.log"
printf 'synthesis prompt for agy\n' > "$SYNTH_LAUNCH_ROOT/agy.prompt"
synth_launch_pid_agy="$(launch_synthesis agy "$SYNTH_LAUNCH_ROOT" "$SYNTH_LAUNCH_LOG_AGY" < "$SYNTH_LAUNCH_ROOT/agy.prompt")"
i=0
until [ -f "$SYNTH_LAUNCH_ROOT/.synthesis-exit-$synth_launch_pid_agy" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -f "$SYNTH_LAUNCH_ROOT/.synthesis-exit-$synth_launch_pid_agy" ] && pass "launch_synthesis agy 寫出 exit 檔" || bad "launch_synthesis agy 未寫出 exit 檔"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$(cat "$SYNTH_LAUNCH_ROOT/.synthesis-exit-$synth_launch_pid_agy" 2>/dev/null)" = "0" ] && pass "launch_synthesis agy exit=0（未帶裸 -p）" || bad "launch_synthesis agy exit 不是 0：agy 分支很可能又帶了裸的 -p/--print"

synth_launch_agy_last_arg="$(tail -n 1 "$SYNTH_LAUNCH_RECORD_DIR/agy.argv" 2>/dev/null)"
if [ "$synth_launch_agy_last_arg" = "-p" ] || [ "$synth_launch_agy_last_arg" = "--print" ]; then
  bad "launch_synthesis agy 的命令列仍帶裸的 -p/--print"
else
  pass "launch_synthesis agy 的命令列不帶裸的 -p/--print"
fi

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
diff -q "$SYNTH_LAUNCH_ROOT/agy.prompt" "$SYNTH_LAUNCH_RECORD_DIR/agy.stdin" >/dev/null 2>&1 \
  && pass "launch_synthesis agy 透過 stdin 完整收到 prompt" || bad "launch_synthesis agy 未透過 stdin 收到完整 prompt"

AGY_SYNTH_HOME="$SYNTH_LAUNCH_ROOT/agy-synthesis-home"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -d "$AGY_SYNTH_HOME" ] && pass "launch_synthesis agy 建立獨立 HOME" || bad "launch_synthesis agy 未建立獨立 HOME"
agy_allow="$(jq -r '.permissions.allow | length' "$AGY_SYNTH_HOME/.gemini/antigravity-cli/settings.json" 2>/dev/null)" || agy_allow=""
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$agy_allow" = "0" ] && pass "launch_synthesis agy 的 permissions.allow 是空陣列" || bad "launch_synthesis agy 的 permissions.allow 不是空陣列: $agy_allow"
agy_home_recorded="$(cat "$SYNTH_LAUNCH_RECORD_DIR/agy.env-home" 2>/dev/null)"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$agy_home_recorded" = "$AGY_SYNTH_HOME" ] && pass "launch_synthesis agy 把 HOME 指到獨立目錄" || bad "launch_synthesis agy 的 HOME 不對: $agy_home_recorded"

# ---- opencode：合流專用的權限設定檔把 edit 與 bash 整個工具都設成
# deny，不是 reviewer 版本那份只擋列名 bash 樣式的黑名單 ----
SYNTH_LAUNCH_LOG_OPENCODE="$SYNTH_LAUNCH_ROOT/opencode.synthesis.log"
printf 'synthesis prompt for opencode\n' > "$SYNTH_LAUNCH_ROOT/opencode.prompt"
synth_launch_pid_opencode="$(launch_synthesis opencode "$SYNTH_LAUNCH_ROOT" "$SYNTH_LAUNCH_LOG_OPENCODE" < "$SYNTH_LAUNCH_ROOT/opencode.prompt")"
i=0
until [ -f "$SYNTH_LAUNCH_ROOT/.synthesis-exit-$synth_launch_pid_opencode" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$(cat "$SYNTH_LAUNCH_ROOT/.synthesis-exit-$synth_launch_pid_opencode" 2>/dev/null)" = "0" ] && pass "launch_synthesis opencode exit=0" || bad "launch_synthesis opencode exit 不是 0"

OPENCODE_SYNTH_CONFIG="$SYNTH_LAUNCH_ROOT/opencode-synthesis-permission.json"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -s "$OPENCODE_SYNTH_CONFIG" ] && pass "launch_synthesis opencode 寫出權限設定檔" || bad "launch_synthesis opencode 未寫出權限設定檔"
opencode_synth_edit="$(jq -r '.permission.edit' "$OPENCODE_SYNTH_CONFIG" 2>/dev/null)" || opencode_synth_edit=""
opencode_synth_bash="$(jq -r '.permission.bash' "$OPENCODE_SYNTH_CONFIG" 2>/dev/null)" || opencode_synth_bash=""
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$opencode_synth_edit" = "deny" ] && pass "launch_synthesis opencode 的 edit 整個工具設為 deny" || bad "launch_synthesis opencode 的 edit 不是整個工具 deny: $opencode_synth_edit"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$opencode_synth_bash" = "deny" ] && pass "launch_synthesis opencode 的 bash 整個工具設為 deny" || bad "launch_synthesis opencode 的 bash 不是整個工具 deny，仍是 reviewer 那份黑名單: $opencode_synth_bash"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
jq empty "$OPENCODE_SYNTH_CONFIG" >/dev/null 2>&1 && pass "launch_synthesis opencode 的權限設定檔是合法 JSON" || bad "launch_synthesis opencode 的權限設定檔不是合法 JSON"

# ---- 未知 CLI 回傳非零 ----
if launch_synthesis bogus-cli "$SYNTH_LAUNCH_ROOT" "$SYNTH_LAUNCH_ROOT/bogus.log" < /dev/null >/dev/null 2>&1; then
  bad "launch_synthesis 未知 CLI 應失敗"
else
  pass "launch_synthesis 未知 CLI 回傳非零"
fi

# ---- 「最容易被踩到的坑」之一：cmd_launch() 對 logs_dir 下的 chmod -R a-w
# 是在每個 reviewer 都已啟動之後才施加的，合流是在那之後才啟動的新行
# 程，若合流的 log 落在 logs_dir 底下就會直接開不出新檔。這裡直接重現
# 「base_dir 可寫、其 logs 子目錄唯讀」這個前提，確認 launch_synthesis
# 把 log 放在 base_dir 這一層時仍能正常寫出。----
SYNTH_RO_ROOT="$T/synth-launch-readonly-fixture"
mkdir -p "$SYNTH_RO_ROOT/logs"
chmod -R a-w "$SYNTH_RO_ROOT/logs"
printf 'p' > "$SYNTH_RO_ROOT/ro.prompt"
SYNTH_RO_LOG="$SYNTH_RO_ROOT/synthesis.log"
if synth_ro_pid="$(launch_synthesis claude "$SYNTH_RO_ROOT" "$SYNTH_RO_LOG" < "$SYNTH_RO_ROOT/ro.prompt")"; then
  i=0
  until [ -f "$SYNTH_RO_ROOT/.synthesis-exit-$synth_ro_pid" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ -s "$SYNTH_RO_LOG" ] && pass "launch_synthesis 的 log 放在 base_dir，不受唯讀的 logs_dir 影響" || bad "launch_synthesis 的 log 未成功寫出"
else
  bad "launch_synthesis 在 logs_dir 唯讀情境下應仍能啟動"
fi
chmod -R u+w "$SYNTH_RO_ROOT/logs" 2>/dev/null || true

export PATH="$saved_path"

# ==============================================================
# _record_synthesis_result
#
# Write the exit file and log directly, no real process needed --
# covering ready/withheld/no-content, the synthesis:<cli> cli-field tag,
# worktree_status=n/a, and the echo-guard marker.
# ==============================================================

RSYN_SUMMARY="$T/record-synth-summary.txt"
: > "$RSYN_SUMMARY"

RSYN_READY_ROOT="$T/record-synth-ready"
mkdir -p "$RSYN_READY_ROOT"
cat > "$RSYN_READY_ROOT/synthesis.log" <<'LOG'
===PR-REVIEW-BY-MULTI-AGENTS-BEGIN===
這是合流後的完整內容
===PR-REVIEW-BY-MULTI-AGENTS-END===
LOG
printf '0' > "$RSYN_READY_ROOT/.synthesis-exit-77001"
_record_synthesis_result 77001 claude "$RSYN_READY_ROOT/synthesis.log" "$RSYN_READY_ROOT" "$RSYN_SUMMARY"
RSYN_L1="$(sed -n 1p "$RSYN_SUMMARY")"

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qE '^cli=[^ ]+ pid=[0-9]+ exit=[^ ]+ ended_at=[^ ]+ worktree_status=[^ ]+ content_status=[^ ]+ content_file=' <<<"$RSYN_L1" \
  && pass "_record_synthesis_result 七欄位" || bad "_record_synthesis_result 七欄位不對: $RSYN_L1"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF 'cli=synthesis:claude' <<<"$RSYN_L1" && pass "_record_synthesis_result 的 cli 欄為 synthesis:claude" || bad "_record_synthesis_result 的 cli 欄不對: $RSYN_L1"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF 'worktree_status=n/a' <<<"$RSYN_L1" && pass "_record_synthesis_result 的 worktree_status 為 n/a" || bad "_record_synthesis_result 的 worktree_status 不對"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF 'content_status=ready' <<<"$RSYN_L1" && pass "_record_synthesis_result exit=0 時 content_status=ready" || bad "_record_synthesis_result exit=0 時 content_status 不對"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$(head -1 "$RSYN_READY_ROOT/.comment-body-synthesis.md")" = '<!-- pr-review-by-multi-agents -->' ] \
  && pass "_record_synthesis_result 內容檔第一行是回音室標記" || bad "_record_synthesis_result 內容檔缺回音室標記"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF '這是合流後的完整內容' "$RSYN_READY_ROOT/.comment-body-synthesis.md" \
  && pass "_record_synthesis_result 內容檔保留合流內容" || bad "_record_synthesis_result 內容檔遺失合流內容"

RSYN_WITHHELD_ROOT="$T/record-synth-withheld"
mkdir -p "$RSYN_WITHHELD_ROOT"
cat > "$RSYN_WITHHELD_ROOT/synthesis.log" <<'LOG'
===PR-REVIEW-BY-MULTI-AGENTS-BEGIN===
合流跑到一半失敗
===PR-REVIEW-BY-MULTI-AGENTS-END===
LOG
printf '1' > "$RSYN_WITHHELD_ROOT/.synthesis-exit-77002"
_record_synthesis_result 77002 codex "$RSYN_WITHHELD_ROOT/synthesis.log" "$RSYN_WITHHELD_ROOT" "$RSYN_SUMMARY"
RSYN_L2="$(sed -n 2p "$RSYN_SUMMARY")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF 'cli=synthesis:codex' <<<"$RSYN_L2" && pass "_record_synthesis_result 的 cli 欄保留實際執行合流的 CLI 名稱" || bad "_record_synthesis_result 的 cli 欄未保留實際 CLI"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF 'content_status=withheld' <<<"$RSYN_L2" && pass "_record_synthesis_result exit 非零時 content_status=withheld" || bad "_record_synthesis_result exit 非零時 content_status 不對"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -f "$RSYN_WITHHELD_ROOT/.comment-body-synthesis.md" ] && pass "_record_synthesis_result withheld 仍保留內容檔" || bad "_record_synthesis_result withheld 遺失內容檔"

RSYN_NOCONTENT_ROOT="$T/record-synth-nocontent"
mkdir -p "$RSYN_NOCONTENT_ROOT"
printf 'CLI 崩潰，沒有標記\n' > "$RSYN_NOCONTENT_ROOT/synthesis.log"
printf '0' > "$RSYN_NOCONTENT_ROOT/.synthesis-exit-77003"
_record_synthesis_result 77003 opencode "$RSYN_NOCONTENT_ROOT/synthesis.log" "$RSYN_NOCONTENT_ROOT" "$RSYN_SUMMARY"
RSYN_L3="$(sed -n 3p "$RSYN_SUMMARY")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF 'content_status=no-content' <<<"$RSYN_L3" && pass "_record_synthesis_result 標記缺失時 content_status=no-content" || bad "_record_synthesis_result 標記缺失時 content_status 不對"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qE 'content_file=$' <<<"$RSYN_L3" && pass "_record_synthesis_result no-content 時 content_file 留空" || bad "_record_synthesis_result no-content 時 content_file 未留空"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -e "$RSYN_NOCONTENT_ROOT/.comment-body-synthesis.md" ] && pass "_record_synthesis_result no-content 不寫內容檔" || bad "_record_synthesis_result no-content 卻寫了內容檔"

# ==============================================================
# spawn_supervisor_interactive -- 合流的完整接線（互動模式）
#
# 對照先前那個已移除的無頭合流監督測試，完成判準換成「輸出檔已存在
# 且帶結束標記」，不再透過已移除的無頭 reviewer 啟動函式起真正的背景
# 行程：claude、
# agy 兩個 reviewer 直接把內容加結束標記寫進各自的 review.md（模擬已
# 完成），codex 的 review.md 同樣帶標記（讓輪詢迴圈能終止），但刻意不
# 寫 .git-status-before-codex，使其 worktree 前後比對必然不符、落在
# invalidated -> withheld。
#
# 這是「codex 派出但內容不可信」這個情境在互動模式下唯一可觸達的等價
# 寫法：_extract_reviewer_output 同時是輪詢迴圈的完成判準與
# _record_reviewer_result_interactive 的內容擷取共用的同一個函式，若
# codex 的檔案缺少標記（原本無頭模式「行程崩潰、沒有標記」對應
# no-content 的成因），輪詢迴圈會把它視為「還沒完成」而永遠等下去，
# 不會像無頭模式那樣靠 kill -0 偵測到行程已結束、進而記成 no-content
# ——這正是 spawn_supervisor_interactive 自身文件所寫「不判斷卡住或永
# 遠不會完成」的直接體現。no-content 這個分支因此只能透過直接呼叫
# _record_reviewer_result_interactive 觸達，見下面新增的輪詢等待案例。
#
# 三份輸出檔在呼叫 spawn_supervisor_interactive 之前就已就緒，且傳入的
# cli 順序固定（claude agy codex），輪詢迴圈的第一輪就會依序、同步地
# 把三者都記進 summary.txt——不像無頭模式仰賴背景行程的真實完成順序，
# 這裡的完成順序就是傳入順序，因此哪個 CLI 中選合流不必用「接受任一
# 勝出者」這種寫法，claude 必定排在 agy 之前入選（_select_synthesis_cli
# 掃描 ready 行時只認先出現的那個）。
# ==============================================================

SPWSYNI_ROOT="$T/spawn-supervisor-interactive-synthesis-fixture"
SPWSYNI_WT="$(_make_worktree_fixture "$SPWSYNI_ROOT")"
mkdir -p "$SPWSYNI_ROOT/reviewers/claude/workdir" "$SPWSYNI_ROOT/reviewers/agy/workdir" "$SPWSYNI_ROOT/reviewers/codex/workdir"

SPWSYNI_STUB_BIN="$T/spawn-supervisor-interactive-synthesis-stub-bin"
mkdir -p "$SPWSYNI_STUB_BIN"
# 三個都裝上樁，即使目前只有 claude 真的會被啟動：見上面文件說明，
# _select_synthesis_cli 在 claude/agy 兩者都 ready 時必定選 claude（傳
# 入順序固定，claude 先於 agy 落進 summary.txt），codex 落在 withheld、
# 不會參與合流挑選。但這個「必定」是合流挑選邏輯目前的行為，不是這個
# stub 目錄的職責 -- assert_cli_stub_only 只保護裝了樁的名字，若合流挑
# 選邏輯日後改變而 agy/codex 的樁不存在，兩者會直接穿透到系統 PATH 上
# 真正的、已認證的 CLI 二進位。agy 沿用 claude 的樁內容（萬一被意外啟
# 動，至少不會嘗試真的執行任何動作）；codex 則是直接崩潰（exit 1）的
# 寫法，同一個理由：不該被啟動的 CLI 若真的被啟動，樁本身要讓這個情境
# 明顯失敗，而不是安靜地表現得像成功。
cat > "$SPWSYNI_STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
echo "===PR-REVIEW-BY-MULTI-AGENTS-BEGIN==="
cat
echo "===PR-REVIEW-BY-MULTI-AGENTS-END==="
exit 0
STUB
chmod +x "$SPWSYNI_STUB_BIN/claude"
cp "$SPWSYNI_STUB_BIN/claude" "$SPWSYNI_STUB_BIN/agy"
cat > "$SPWSYNI_STUB_BIN/codex" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$SPWSYNI_STUB_BIN/codex"
export PATH="$SPWSYNI_STUB_BIN:$saved_path"
assert_cli_stub_only "$PATH" "$SPWSYNI_STUB_BIN" claude agy codex

printf 'claude review body\n===PR-REVIEW-BY-MULTI-AGENTS-END===\n' > "$SPWSYNI_ROOT/reviewers/claude/workdir/review.md"
printf 'agy review body\n===PR-REVIEW-BY-MULTI-AGENTS-END===\n' > "$SPWSYNI_ROOT/reviewers/agy/workdir/review.md"
printf 'codex review body\n===PR-REVIEW-BY-MULTI-AGENTS-END===\n' > "$SPWSYNI_ROOT/reviewers/codex/workdir/review.md"

printf '%s\n' "$(_git_status_snapshot "$SPWSYNI_WT")" > "$SPWSYNI_ROOT/.git-status-before-claude"
printf '%s\n' "$(_git_status_snapshot "$SPWSYNI_WT")" > "$SPWSYNI_ROOT/.git-status-before-agy"
# .git-status-before-codex 刻意不寫：見上面文件說明，這是讓 codex 落在
# withheld 的手法。

# .roster 正常由 cmd_prepare() 寫入；這裡直接呼叫
# spawn_supervisor_interactive，繞過 cmd_prepare()/cmd_launch()，自行備
# 妥同一份檔案。
printf 'claude claude-e2e-model dispatched\nagy agy-e2e-model dispatched\ncodex codex-e2e-model dispatched\n' \
  > "$SPWSYNI_ROOT/.roster"

SPWSYNI_SUMMARY="$SPWSYNI_ROOT/summary.txt"
(cd "$SPWSYNI_ROOT/work" && spawn_supervisor_interactive "$SPWSYNI_WT" "$SPWSYNI_SUMMARY" claude agy codex)

i=0
until { [ -f "$SPWSYNI_SUMMARY" ] && [ "$(wc -l < "$SPWSYNI_SUMMARY")" -eq 4 ]; } || [ "$i" -ge 200 ]; do sleep 0.1; i=$((i + 1)); done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -f "$SPWSYNI_SUMMARY" ] && [ "$(wc -l < "$SPWSYNI_SUMMARY")" -eq 4 ] && pass "spawn_supervisor_interactive 三個 reviewer（兩個 ready）後多寫一行合流" || bad "spawn_supervisor_interactive 未寫出合流那一行: $(cat "$SPWSYNI_SUMMARY" 2>/dev/null)"

SPWSYNI_L1="$(sed -n 1p "$SPWSYNI_SUMMARY")"
case "$SPWSYNI_L1" in
  'cli=claude pid=n/a exit=n/a '*' content_status=ready '*) pass "spawn_supervisor_interactive claude 那一行 pid=n/a exit=n/a content_status=ready" ;;
  *) bad "spawn_supervisor_interactive claude 那一行不對: $SPWSYNI_L1" ;;
esac

SPWSYNI_L2="$(sed -n 2p "$SPWSYNI_SUMMARY")"
case "$SPWSYNI_L2" in
  'cli=agy pid=n/a exit=n/a '*' content_status=ready '*) pass "spawn_supervisor_interactive agy 那一行 pid=n/a exit=n/a content_status=ready" ;;
  *) bad "spawn_supervisor_interactive agy 那一行不對: $SPWSYNI_L2" ;;
esac

SPWSYNI_L3="$(sed -n 3p "$SPWSYNI_SUMMARY")"
case "$SPWSYNI_L3" in
  'cli=codex pid=n/a exit=n/a '*' content_status=withheld '*) pass "spawn_supervisor_interactive codex 那一行 pid=n/a exit=n/a content_status=withheld" ;;
  *) bad "spawn_supervisor_interactive codex 那一行不對: $SPWSYNI_L3" ;;
esac

SPWSYNI_L4="$(sed -n 4p "$SPWSYNI_SUMMARY")"
case "$SPWSYNI_L4" in
  'cli=synthesis:claude '*) pass "spawn_supervisor_interactive 合流那一行的 cli 欄以 synthesis:claude 開頭" ;;
  *) bad "spawn_supervisor_interactive 合流那一行的 cli 欄不對: $SPWSYNI_L4" ;;
esac
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF 'worktree_status=n/a' <<<"$SPWSYNI_L4" && pass "spawn_supervisor_interactive 合流那一行 worktree_status=n/a" || bad "spawn_supervisor_interactive 合流那一行 worktree_status 不對"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF 'content_status=ready' <<<"$SPWSYNI_L4" && pass "spawn_supervisor_interactive 合流那一行 content_status=ready" || bad "spawn_supervisor_interactive 合流那一行 content_status 不對: $SPWSYNI_L4"

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -s "$SPWSYNI_ROOT/synthesis.log" ] && pass "spawn_supervisor_interactive 把合流 log 放在 base_dir" || bad "spawn_supervisor_interactive 未在 base_dir 寫出合流 log"

# 合流實際收到的 prompt（透過 stub 把 stdin 原樣回顯進 synthesis.log）
# 涵蓋契約組出的名單（含 codex 這個真的被派出、卻沒有標記可信賴內容的
# 那一項）與兩份 ready review 全文。
SPWSYNI_SYNTH_LOG_CONTENT="$(cat "$SPWSYNI_ROOT/synthesis.log" 2>/dev/null)"
case "$SPWSYNI_SYNTH_LOG_CONTENT" in
  *'claude review body'*) pass "合流（互動）log 內含 claude 那份 review 全文" ;;
  *) bad "合流（互動）log 缺 claude 那份 review 全文" ;;
esac
case "$SPWSYNI_SYNTH_LOG_CONTENT" in
  *'agy review body'*) pass "合流（互動）log 內含 agy 那份 review 全文" ;;
  *) bad "合流（互動）log 缺 agy 那份 review 全文" ;;
esac
case "$SPWSYNI_SYNTH_LOG_CONTENT" in
  *'codex review body'*) bad "合流（互動）log 誤含 codex 這份不可信的 review 全文" ;;
  *) pass "合流（互動）log 排除 codex 這份不可信的 review 全文" ;;
esac
case "$SPWSYNI_SYNTH_LOG_CONTENT" in
  *'codex-e2e-model'*) pass "合流（互動）log 內含名單中不可信的 codex 項" ;;
  *) bad "合流（互動）log 缺名單中的 codex 項" ;;
esac
case "$SPWSYNI_SYNTH_LOG_CONTENT" in
  *'CLI 名稱：claude'*) pass "合流（互動）log 揭露執行合流本身的 CLI 名稱" ;;
  *) bad "合流（互動）log 未揭露執行合流本身的 CLI 名稱" ;;
esac

# --- ready_count < 2：只有一個 ready reviewer 時不觸發合流（互動模式） ---
SPWSYNI1_ROOT="$T/spawn-supervisor-interactive-single-ready-fixture"
SPWSYNI1_WT="$(_make_worktree_fixture "$SPWSYNI1_ROOT")"
mkdir -p "$SPWSYNI1_ROOT/reviewers/claude/workdir"
printf 'only reviewer\n===PR-REVIEW-BY-MULTI-AGENTS-END===\n' > "$SPWSYNI1_ROOT/reviewers/claude/workdir/review.md"
printf '%s\n' "$(_git_status_snapshot "$SPWSYNI1_WT")" > "$SPWSYNI1_ROOT/.git-status-before-claude"
printf 'claude claude-e2e-model dispatched\n' > "$SPWSYNI1_ROOT/.roster"
SPWSYNI1_SUMMARY="$SPWSYNI1_ROOT/summary.txt"
(cd "$SPWSYNI1_ROOT/work" && spawn_supervisor_interactive "$SPWSYNI1_WT" "$SPWSYNI1_SUMMARY" claude)

i=0
until [ ! -e "$SPWSYNI1_WT" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
# 額外靜候片刻，理由與無頭模式的同一斷言相同：確認的是「合流不會被觸
# 發」，不是「合流還沒來得及跑完」。
sleep 1

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$(wc -l < "$SPWSYNI1_SUMMARY")" -eq 1 ] && pass "spawn_supervisor_interactive 只有一個 ready reviewer 時不多寫合流那一行" || bad "spawn_supervisor_interactive 在只有一個 ready reviewer 時仍寫出合流那一行: $(cat "$SPWSYNI1_SUMMARY" 2>/dev/null)"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -e "$SPWSYNI1_ROOT/synthesis.log" ] && pass "spawn_supervisor_interactive 只有一個 ready reviewer 時不啟動合流行程" || bad "spawn_supervisor_interactive 只有一個 ready reviewer 時仍啟動了合流行程"

# ==============================================================
# spawn_supervisor_interactive -- 標記出現前持續等待，出現後才記錄
#
# _extract_reviewer_output 在檔案缺少結束標記時回傳 1；先直接呼叫
# _record_reviewer_result_interactive（繞過輪詢迴圈本身）確認這個狀態
# 若被記錄下來會是 content_status=no-content（對照上一段文件：輪詢迴
# 圈用同一個判準決定「是否已完成」，因此永遠不會替一個沒有標記的檔案
# 寫下這行，這裡先證明的是「若真的被記錄，值是什麼」，不是輪詢迴圈本
# 身的行為）。再用背景 sleep 之後才補上標記的手法（比照上面
# supervisor-order 區段 _order_launch 對非同步行為的驗證方式），證明
# 輪詢迴圈確實會一直等，直到標記出現才把這一行寫進 summary.txt。
# ==============================================================

SPWSYNI2_ROOT="$T/spawn-supervisor-interactive-pending-fixture"
SPWSYNI2_WT="$(_make_worktree_fixture "$SPWSYNI2_ROOT")"
mkdir -p "$SPWSYNI2_ROOT/reviewers/claude/workdir"
SPWSYNI2_REVIEW="$SPWSYNI2_ROOT/reviewers/claude/workdir/review.md"
printf 'still writing, no end marker yet\n' > "$SPWSYNI2_REVIEW"
printf '%s\n' "$(_git_status_snapshot "$SPWSYNI2_WT")" > "$SPWSYNI2_ROOT/.git-status-before-claude"

# 直接呼叫，不經輪詢迴圈：確認缺標記時 content_status=no-content。寫進
# 一個獨立的 summary 檔，不干擾下面真正輪詢用的那一份。
SPWSYNI2_DIRECT_SUMMARY="$SPWSYNI2_ROOT/direct-summary.txt"
: > "$SPWSYNI2_DIRECT_SUMMARY"
_record_reviewer_result_interactive claude "$SPWSYNI2_ROOT" "$SPWSYNI2_WT" "$SPWSYNI2_REVIEW" "$SPWSYNI2_DIRECT_SUMMARY"
SPWSYNI2_DIRECT_LINE="$(cat "$SPWSYNI2_DIRECT_SUMMARY")"
case "$SPWSYNI2_DIRECT_LINE" in
  'cli=claude pid=n/a exit=n/a '*' content_status=no-content '*) pass "_record_reviewer_result_interactive 缺標記時 pid/exit=n/a 且 content_status=no-content" ;;
  *) bad "_record_reviewer_result_interactive 缺標記時這一行不對: $SPWSYNI2_DIRECT_LINE" ;;
esac

printf 'claude claude-e2e-model dispatched\n' > "$SPWSYNI2_ROOT/.roster"
SPWSYNI2_SUMMARY="$SPWSYNI2_ROOT/summary.txt"

# shellcheck disable=SC2016  # single quotes intentional: $1/$2 expand inside the nested bash -c, not here
nohup bash -c '
  review="$1"; delay="$2"
  sleep "$delay"
  printf "===PR-REVIEW-BY-MULTI-AGENTS-END===\n" >> "$review"
' _ "$SPWSYNI2_REVIEW" 3 >/dev/null 2>&1 &

(cd "$SPWSYNI2_ROOT/work" && spawn_supervisor_interactive "$SPWSYNI2_WT" "$SPWSYNI2_SUMMARY" claude)

# 標記還沒補上（背景 sleep 3 秒還沒到）：輪詢迴圈這時應該已經跑過至少
# 一輪，仍應該還在等，summary.txt 不該有任何一行。
sleep 1
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -s "$SPWSYNI2_SUMMARY" ] && pass "spawn_supervisor_interactive 標記出現前持續等待、不預先記錄" || bad "spawn_supervisor_interactive 標記出現前就記錄了: $(cat "$SPWSYNI2_SUMMARY" 2>/dev/null)"

i=0
until [ -s "$SPWSYNI2_SUMMARY" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -s "$SPWSYNI2_SUMMARY" ] && pass "spawn_supervisor_interactive 標記出現後輪詢才記錄" || bad "spawn_supervisor_interactive 標記出現後仍未記錄"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF 'content_status=ready' "$SPWSYNI2_SUMMARY" 2>/dev/null && pass "spawn_supervisor_interactive 補上標記後 content_status=ready" || bad "spawn_supervisor_interactive 補上標記後這一行不對: $(cat "$SPWSYNI2_SUMMARY" 2>/dev/null)"

# ==============================================================
# spawn_supervisor_interactive -- must not hold the caller's own
# stdout/stderr open（Task 7 簡報第五節記載的缺陷：`(...)& disown` 沒有
# 重導向繼承來的 fd 1/2，背景 subshell 因此一直持有呼叫端的輸出管線；
# 呼叫端若以命令替換擷取這次呼叫的輸出，就得等到監督行程整個跑完──含
# 合流──才拿得到 EOF，把非同步派工變成同步等待。這裡驗證的是同一個修
# 法在互動版本上一樣有效，且更關鍵：`run-review.sh launch` 正是
# SKILL.md 輪詢設計仰賴立刻返回的那次呼叫，這個函式是它背後真正跑的東
# 西）。比照上面合流接線區段最後一段的手法：背景 sleep 之後才補上結束
# 標記，讓輪詢迴圈有真的要等的東西，這個函式不啟動任何 CLI，不需要另
# 外的 PATH 樁。
# ==============================================================

SVIPIPE_ROOT="$T/supervisor-interactive-pipe-fixture"
SVIPIPE_WT="$(_make_worktree_fixture "$SVIPIPE_ROOT")"
mkdir -p "$SVIPIPE_ROOT/reviewers/claude/workdir"
SVIPIPE_REVIEW="$SVIPIPE_ROOT/reviewers/claude/workdir/review.md"
printf 'still writing, no end marker yet\n' > "$SVIPIPE_REVIEW"
printf '%s\n' "$(_git_status_snapshot "$SVIPIPE_WT")" > "$SVIPIPE_ROOT/.git-status-before-claude"
printf 'claude claude-e2e-model dispatched\n' > "$SVIPIPE_ROOT/.roster"
SVIPIPE_SUMMARY="$SVIPIPE_ROOT/summary.txt"

# shellcheck disable=SC2016  # single quotes intentional: $1/$2 expand inside the nested bash -c, not here
nohup bash -c '
  review="$1"; delay="$2"
  sleep "$delay"
  printf "===PR-REVIEW-BY-MULTI-AGENTS-END===\n" >> "$review"
' _ "$SVIPIPE_REVIEW" 3 >/dev/null 2>&1 &

svipipe_t0="$(date +%s)"
svipipe_out="$(cd "$SVIPIPE_ROOT/work" && spawn_supervisor_interactive "$SVIPIPE_WT" "$SVIPIPE_SUMMARY" claude)"
svipipe_t1="$(date +%s)"
svipipe_elapsed="$((svipipe_t1 - svipipe_t0))"

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$svipipe_elapsed" -le 2 ] && pass "spawn_supervisor_interactive 不持有呼叫端管線：命令替換立刻返回" \
  || bad "spawn_supervisor_interactive 命令替換等了 ${svipipe_elapsed}s 才返回（標記要等 3s 才補上），疑似仍持有呼叫端的 fd 1/2"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -z "$svipipe_out" ] && pass "spawn_supervisor_interactive 命令替換沒有擷取到非預期輸出" || bad "spawn_supervisor_interactive 命令替換擷取到非預期輸出: $svipipe_out"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -s "$SVIPIPE_SUMMARY" ] && pass "spawn_supervisor_interactive 返回時輪詢確實還沒收尾（標記還沒補上，時序假設成立）" \
  || bad "spawn_supervisor_interactive 返回過快，summary.txt 已經有內容，時序假設不成立，上面立刻返回的斷言不足採信"

i=0
until [ -s "$SVIPIPE_SUMMARY" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -s "$SVIPIPE_SUMMARY" ] && pass "spawn_supervisor_interactive 背景輪詢最終仍完成收尾" || bad "spawn_supervisor_interactive 背景輪詢從未收尾"

# ==============================================================
# spawn_supervisor_interactive -- worktree 移除不依賴呼叫端當下的工作
# 目錄（缺陷 5）
#
# 修正前，`git worktree remove --force "$worktree_dir"` 沒有 `-C`，靠呼
# 叫端當下的工作目錄解析要清哪個 repo；cmd_launch() 是與 cmd_prepare()
# 分開的行程呼叫，若從別處呼叫，這一行會解析失敗，而失敗又被同一行自
# 己的 `|| true` 靜默吞掉，worktree 永遠不會被清掉、也不會有任何錯誤訊
# 息。這裡刻意「不」用其他區段慣用的 `(cd "$ROOT/work" && ...)` 呼叫，
# 而是從一個完全無關、甚至不是 git repo 的目錄呼叫，證明修正後的清理
# 讀 .repo-path（cmd_prepare() 正常會寫這個檔案，見它自己的文件）、用
# `git -C <repo_path>` 執行，不必倚賴呼叫端的 cwd。
# ==============================================================

SVREPOPATH_ROOT="$T/spawn-supervisor-interactive-repo-path-fixture"
SVREPOPATH_WT="$(_make_worktree_fixture "$SVREPOPATH_ROOT")"
mkdir -p "$SVREPOPATH_ROOT/reviewers/claude/workdir"
printf 'review body\n===PR-REVIEW-BY-MULTI-AGENTS-END===\n' > "$SVREPOPATH_ROOT/reviewers/claude/workdir/review.md"
printf '%s\n' "$(_git_status_snapshot "$SVREPOPATH_WT")" > "$SVREPOPATH_ROOT/.git-status-before-claude"
printf 'claude claude-e2e-model dispatched\n' > "$SVREPOPATH_ROOT/.roster"
# .repo-path is normally written by cmd_prepare() (see its own docstring);
# this bypasses cmd_prepare()/cmd_launch() entirely, the same reason
# .roster and .git-status-before-claude above are seeded by hand instead.
printf '%s\n' "$SVREPOPATH_ROOT/work" > "$SVREPOPATH_ROOT/.repo-path"
SVREPOPATH_SUMMARY="$SVREPOPATH_ROOT/summary.txt"

SVREPOPATH_ELSEWHERE="$T/not-the-target-repo"
mkdir -p "$SVREPOPATH_ELSEWHERE"
(cd "$SVREPOPATH_ELSEWHERE" && spawn_supervisor_interactive "$SVREPOPATH_WT" "$SVREPOPATH_SUMMARY" claude)

i=0
until [ ! -e "$SVREPOPATH_WT" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -e "$SVREPOPATH_WT" ] && pass "spawn_supervisor_interactive 從非目標 repo 的工作目錄呼叫仍能清除 worktree" \
  || bad "spawn_supervisor_interactive 從非目標 repo 的工作目錄呼叫時未能清除 worktree（worktree 仍在: $SVREPOPATH_WT）"

# ==============================================================
# spawn_supervisor_interactive -- .supervisor.pid 寫入與 SIGHUP 存活韌性
#
# 無頭版原有的 spawn-supervisor-writes-pid-file / spawn-supervisor-pid-
# file-is-not-caller / spawn-supervisor-survives-sighup /
# spawn-supervisor-removes-worktree-after-sighup 這幾個案例隨無頭版
# spawn_supervisor 一併被刪除；但 .supervisor.pid 的寫入（trap '' HUP
# 之後、輪詢迴圈開始之前，把 $BASHPID 寫進 base_dir/.supervisor.pid）與
# HUP 忽略是從無頭版逐字複製過來的，這個檔案裡其餘提到 .supervisor.pid
# 的斷言全是讀取側（printf 一個假的 pid 檔去測 setup_worktree 與
# _reap_stale_run_dirs 的回收判斷），沒有一個真正呼叫
# spawn_supervisor_interactive 驗證寫入側本身。編排端判斷監督行程是否
# 存活完全依賴這個檔案，缺了寫入側斷言，日後任何一次修改都可能讓它靜
# 默不再寫出這個檔、或不再抵抗 SIGHUP，而不會被任何測試抓到。
#
# 比照上面「標記出現前持續等待」與「不持有呼叫端管線」兩段的手法：
# review.md 先不帶結束標記，背景 sleep 之後才補上，讓輪詢迴圈有真的要
# 等的東西，藉此在補標記之前的空窗期驗證 .supervisor.pid 記錄的行程當
# 下確實存活，並在那段空窗期對它送真正的 SIGHUP，確認它既不會立刻死
# 掉，最終仍完成收尾（等到標記補上、summary.txt 寫出 ready 那一行、
# worktree 被清掉）。
# ==============================================================

SVIPID_ROOT="$T/supervisor-interactive-pidfile-fixture"
SVIPID_WT="$(_make_worktree_fixture "$SVIPID_ROOT")"
mkdir -p "$SVIPID_ROOT/reviewers/claude/workdir"
SVIPID_REVIEW="$SVIPID_ROOT/reviewers/claude/workdir/review.md"
printf 'still writing, no end marker yet\n' > "$SVIPID_REVIEW"
printf '%s\n' "$(_git_status_snapshot "$SVIPID_WT")" > "$SVIPID_ROOT/.git-status-before-claude"
printf 'claude claude-e2e-model dispatched\n' > "$SVIPID_ROOT/.roster"
SVIPID_SUMMARY="$SVIPID_ROOT/summary.txt"

# shellcheck disable=SC2016  # single quotes intentional: $1/$2 expand inside the nested bash -c, not here
nohup bash -c '
  review="$1"; delay="$2"
  sleep "$delay"
  printf "===PR-REVIEW-BY-MULTI-AGENTS-END===\n" >> "$review"
' _ "$SVIPID_REVIEW" 3 >/dev/null 2>&1 &

(cd "$SVIPID_ROOT/work" && spawn_supervisor_interactive "$SVIPID_WT" "$SVIPID_SUMMARY" claude)

i=0
until [ -s "$SVIPID_ROOT/.supervisor.pid" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -s "$SVIPID_ROOT/.supervisor.pid" ] && pass "spawn_supervisor_interactive 寫出 .supervisor.pid" || bad "spawn_supervisor_interactive 沒有寫出 .supervisor.pid"

svipid_recorded="$(cat "$SVIPID_ROOT/.supervisor.pid" 2>/dev/null)"
# 標記還沒補上（背景 sleep 3 秒還沒到），此時 .supervisor.pid 記錄的行
# 程必然還在跑，用 kill -0 直接驗證，不是巧合命中一個已經結束、PID 被
# 作業系統回收給別的行程用的號碼。
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -n "$svipid_recorded" ] && kill -0 "$svipid_recorded" 2>/dev/null && pass "spawn_supervisor_interactive .supervisor.pid 記錄的是當下存活的行程" \
  || bad "spawn_supervisor_interactive .supervisor.pid 記錄的行程（$svipid_recorded）當下已經不存活"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -n "$svipid_recorded" ] && [ "$svipid_recorded" != "$$" ] && pass "spawn_supervisor_interactive .supervisor.pid 不是呼叫端自己的 PID" \
  || bad "spawn_supervisor_interactive .supervisor.pid 記成了呼叫端自己的 PID: $svipid_recorded"

# 對 .supervisor.pid 記錄的那個行程送真正的 SIGHUP：這個函式一開始就
# trap '' HUP，重點是它會忽略這個訊號本身，不是靠 disown（disown 只讓
# 這個測試腳本自己退出時不主動送 SIGHUP，不影響這裡核發送出的這一個）。
kill -HUP "$svipid_recorded" 2>/dev/null || true

sleep 0.2
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
kill -0 "$svipid_recorded" 2>/dev/null && pass "spawn_supervisor_interactive 收到 SIGHUP 後仍然存活" \
  || bad "spawn_supervisor_interactive 收到 SIGHUP 後已經死亡（PID $svipid_recorded 消失）"

i=0
until [ -s "$SVIPID_SUMMARY" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -s "$SVIPID_SUMMARY" ] && pass "spawn_supervisor_interactive 收到 SIGHUP 後仍完成輪詢並寫出摘要" || bad "spawn_supervisor_interactive 收到 SIGHUP 後未完成輪詢，摘要檔仍是空的"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF 'content_status=ready' "$SVIPID_SUMMARY" 2>/dev/null && pass "spawn_supervisor_interactive 收到 SIGHUP 後仍正確記錄 content_status=ready" || bad "spawn_supervisor_interactive 收到 SIGHUP 後這一行不對: $(cat "$SVIPID_SUMMARY" 2>/dev/null)"

i=0
until [ ! -e "$SVIPID_WT" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -e "$SVIPID_WT" ] && pass "spawn_supervisor_interactive 收到 SIGHUP 後仍完成 worktree 清理" || bad "spawn_supervisor_interactive 收到 SIGHUP 後未清理 worktree"

export PATH="$saved_path"

exit $fail
