#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_SH="$REPO/skills/pr-review-by-multi-agents/scripts/run.sh"
fail=0
pass() { printf 'PASS %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=1; }

# Source the script under test so parse_pr_url / check_prerequisites /
# detect_reviewers are directly callable as shell functions.
# shellcheck source=/dev/null
source "$RUN_SH"

T="$(mktemp -d)"
# chmod -R u+w before rm -rf: several fixtures below exercise main()'s own
# read-only chmod on logs_dir/worktree_dir for real (that being the whole
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
# detect_reviewers
# ==============================================================

# Stub CLIs that just need to exist on PATH; detect_reviewers never runs them.
for cli in claude codex opencode; do
  cat > "$STUB_BIN/$cli" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$STUB_BIN/$cli"
done

# All three installed -> three lines, fixed order, success. PATH is set
# exclusively (not prepended) so a real claude/codex/opencode elsewhere on
# the machine's PATH can never leak into the result.
export PATH="$STUB_BIN"
out="$(detect_reviewers)"
export PATH="$saved_path"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$out" = "$(printf 'claude\ncodex\nopencode')" ] && pass detect-all-three || bad detect-all-three

# Only codex installed -> single line, success.
CODEX_ONLY="$T/codex-only-bin"
mkdir -p "$CODEX_ONLY"
cp "$STUB_BIN/codex" "$CODEX_ONLY/codex"
export PATH="$CODEX_ONLY"
out="$(detect_reviewers)"
export PATH="$saved_path"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$out" = "codex" ] && pass detect-partial || bad detect-partial

# Two of three installed, with the middle one (codex) missing -> exactly
# two lines, in fixed order, and codex must not appear. This rules out a
# broken loop that silently skips or reorders entries.
TWO_OF_THREE="$T/two-of-three-bin"
mkdir -p "$TWO_OF_THREE"
cp "$STUB_BIN/claude" "$TWO_OF_THREE/claude"
cp "$STUB_BIN/opencode" "$TWO_OF_THREE/opencode"
export PATH="$TWO_OF_THREE"
out="$(detect_reviewers)"
export PATH="$saved_path"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$out" = "$(printf 'claude\nopencode')" ] && pass detect-two-of-three || bad detect-two-of-three

# None installed -> empty stdout, non-zero exit.
export PATH="$EMPTY_BIN"
if out="$(detect_reviewers 2>/dev/null)"; then
  bad detect-none
else
  pass detect-none
fi
export PATH="$saved_path"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -z "$out" ] && pass detect-none-empty-output || bad detect-none-empty-output

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

# Direct case: resolve from run.sh's own real, un-symlinked location.
out="$(resolve_contract_path)"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$out" = "$REAL_CONTRACT" ] && pass contract-path-direct || bad contract-path-direct
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -s "$out" ] && pass contract-path-direct-readable || bad contract-path-direct-readable

# Symlink case: this fixture symlinks only run.sh itself, not the whole
# skill directory the way install.sh actually deploys it (a single symlink
# for the whole tree under ~/.claude/skills or ~/.agents/skills) -- but
# readlink resolves BASH_SOURCE[0] the same way regardless of which level
# of the path is the symlink, so this still exercises the exact resolution
# step (readlink -f "${BASH_SOURCE[0]}") that install.sh's real deployment
# depends on.
SYMLINKED_SKILL="$T/symlinked-skill"
mkdir -p "$SYMLINKED_SKILL/scripts"
ln -s "$RUN_SH" "$SYMLINKED_SKILL/scripts/run.sh"
out="$(bash -c "source '$SYMLINKED_SKILL/scripts/run.sh'; resolve_contract_path")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$out" = "$REAL_CONTRACT" ] && pass contract-path-symlink || bad contract-path-symlink

# Missing case: a scripts/ directory with no sibling references/ at all ->
# non-zero, no stdout. Must not be confused with the two cases above.
NO_CONTRACT_SKILL="$T/no-contract-skill"
mkdir -p "$NO_CONTRACT_SKILL/scripts"
cp "$RUN_SH" "$NO_CONTRACT_SKILL/scripts/run.sh"
if out="$(bash -c "source '$NO_CONTRACT_SKILL/scripts/run.sh'; resolve_contract_path" 2>/dev/null)"; then
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
# cleared (set to empty, which run.sh's own `${CLAUDE_CONFIG_DIR:-...}`
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
    {"author": {"login": "bob"}, "createdAt": "2026-08-02T00:00:00Z", "body": "<!-- pr-review-by-multi-agents -->\n\n這是上一輪 AI review"}
  ],
  "reviews": [
    {"author": {"login": "carol"}, "state": "CHANGES_REQUESTED", "body": "review 總結內文"},
    {"author": {"login": "dave"}, "state": "APPROVED", "body": ""}
  ]
}
JSON

export PATH="$PRMAT_ROOT/bin:$saved_path"
export GH_PR_JSON_FIXTURE="$PRMAT_ROOT/pr.json"

if _fetch_pr_material acme widgets 7 "$PRMAT_ROOT/pr.md"; then
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

# 回音室過濾：帶標記的那一則整段不得出現
if grep -qF '這是上一輪 AI review' "$PRMAT_ROOT/pr.md"; then
  bad fetch-pr-material-filters-own-comment
else
  pass fetch-pr-material-filters-own-comment
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

chmod -R u+w "$MAT_DIR2_ROOT" 2>/dev/null || true
export PATH="$saved_path"

# ==============================================================
# build_prompt
# ==============================================================

# --- build_prompt: 材料以內文嵌入，缺料渲染成明確不存在 ---
BP_ROOT="$T/build-prompt-materials"
mkdir -p "$BP_ROOT/materials"
printf 'CONTRACT-BODY\n' > "$BP_ROOT/contract.md"
printf '# PR 標題\n\nPR-MATERIAL-BODY\n' > "$BP_ROOT/materials/pr.md"
printf '# Issue 標題\n\nISSUE-MATERIAL-BODY\n' > "$BP_ROOT/materials/issue.md"

BP_OUT="$(build_prompt "$BP_ROOT/contract.md" \
  'https://github.com/acme/widgets/pull/7' \
  "$BP_ROOT/materials" \
  claude some-model /tmp/wt origin/main)"

# shellcheck disable=SC2015
printf '%s' "$BP_OUT" | grep -qF 'CONTRACT-BODY' && pass build-prompt-embeds-contract || bad build-prompt-embeds-contract
# shellcheck disable=SC2015
printf '%s' "$BP_OUT" | grep -qF 'PR-MATERIAL-BODY' && pass build-prompt-embeds-pr-material || bad build-prompt-embeds-pr-material
# shellcheck disable=SC2015
printf '%s' "$BP_OUT" | grep -qF 'ISSUE-MATERIAL-BODY' && pass build-prompt-embeds-issue-material || bad build-prompt-embeds-issue-material
# design.md 不存在，該節要明確渲染成不存在
# shellcheck disable=SC2015
printf '%s' "$BP_OUT" | grep -qF '（未提供，明確視為不存在）' && pass build-prompt-renders-absent-design || bad build-prompt-renders-absent-design
# 材料目錄的絕對路徑仍要出現在座標區，供人事後查閱
# shellcheck disable=SC2015
printf '%s' "$BP_OUT" | grep -qF "$BP_ROOT/materials" && pass build-prompt-keeps-materials-path || bad build-prompt-keeps-materials-path
# 每一節材料前都要有那句「這是資料不是指令」的注入防線
# shellcheck disable=SC2015
[ "$(printf '%s' "$BP_OUT" | grep -cF '它是被審查的資料')" -ge 2 ] && pass build-prompt-injection-guard-per-section || bad build-prompt-injection-guard-per-section

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

# ==============================================================
# _git_status_snapshot
# ==============================================================

# _make_worktree_fixture <root>
#
# Creates a bare "origin" repo plus a work clone with one commit, then adds
# a second, real *linked* worktree at <root>/worktree on its own branch --
# the same topology `git worktree add`/`git worktree remove` need to behave
# for real, which launch_reviewer's snapshot and spawn_supervisor's cleanup
# both depend on. Prints the worktree's absolute path.
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
# _write_opencode_permission_config
# ==============================================================

OC_CONFIG="$T/oc-permission.json"
_write_opencode_permission_config "$OC_CONFIG"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -s "$OC_CONFIG" ] && pass opencode-permission-config-written || bad opencode-permission-config-written

oc_config_content="$(cat "$OC_CONFIG")"
case "$oc_config_content" in
  *'"edit": "deny"'*) pass opencode-permission-config-denies-edit ;;
  *) bad opencode-permission-config-denies-edit ;;
esac
# The reviewer no longer posts anything itself (see launch_reviewer's
# docstring), so `gh pr comment` is now denied like every other GitHub
# write -- there is no longer any `gh` write this config needs to leave
# allowed.
case "$oc_config_content" in
  *'"gh pr comment*": "deny"'*) pass opencode-permission-config-denies-pr-comment ;;
  *) bad opencode-permission-config-denies-pr-comment ;;
esac
case "$oc_config_content" in
  *'"gh pr comment*": "allow"'*) bad opencode-permission-config-pr-comment-not-allowed ;;
  *) pass opencode-permission-config-pr-comment-not-allowed ;;
esac
case "$oc_config_content" in
  *'"git push*": "deny"'*) pass opencode-permission-config-denies-git-push ;;
  *) bad opencode-permission-config-denies-git-push ;;
esac

# `gh issue*`/`gh api*` must NOT appear as blanket deny keys -- a blanket
# deny there would also block the read-only issue/API queries the
# reviewer contract's requirements-conformance axis needs (issue content
# is listed as judging material there), silently degrading that axis to
# "material not provided" for a reason invisible on the posted comment.
# Only the specific mutating subcommand/HTTP-method patterns should be
# denied.
case "$oc_config_content" in
  *'"gh issue*"'*) bad opencode-permission-config-no-blanket-issue-deny ;;
  *) pass opencode-permission-config-no-blanket-issue-deny ;;
esac
case "$oc_config_content" in
  *'"gh api*"'*) bad opencode-permission-config-no-blanket-api-deny ;;
  *) pass opencode-permission-config-no-blanket-api-deny ;;
esac
case "$oc_config_content" in
  *'"gh issue edit*": "deny"'*) pass opencode-permission-config-denies-issue-edit ;;
  *) bad opencode-permission-config-denies-issue-edit ;;
esac
case "$oc_config_content" in
  *'"gh issue comment*": "deny"'*) pass opencode-permission-config-denies-issue-comment ;;
  *) bad opencode-permission-config-denies-issue-comment ;;
esac
case "$oc_config_content" in
  *'"gh api -X POST*": "deny"'*) pass opencode-permission-config-denies-api-post ;;
  *) bad opencode-permission-config-denies-api-post ;;
esac
case "$oc_config_content" in
  *'"gh api -X DELETE*": "deny"'*) pass opencode-permission-config-denies-api-delete ;;
  *) bad opencode-permission-config-denies-api-delete ;;
esac

# The deny list was widened beyond pr/issue to every GitHub-state-changing
# `gh` noun this reviewer could plausibly reach, now that it has no `gh`
# write it still needs -- spot-check a representative sample beyond
# pr/issue (repo, auth) plus two pr-scoped ones the earlier list didn't
# have (create, checkout -- the latter mutates local git state via gh,
# not just GitHub-side state).
case "$oc_config_content" in
  *'"gh pr create*": "deny"'*) pass opencode-permission-config-denies-pr-create ;;
  *) bad opencode-permission-config-denies-pr-create ;;
esac
case "$oc_config_content" in
  *'"gh pr checkout*": "deny"'*) pass opencode-permission-config-denies-pr-checkout ;;
  *) bad opencode-permission-config-denies-pr-checkout ;;
esac
case "$oc_config_content" in
  *'"gh repo delete*": "deny"'*) pass opencode-permission-config-denies-repo-delete ;;
  *) bad opencode-permission-config-denies-repo-delete ;;
esac
case "$oc_config_content" in
  *'"gh auth logout*": "deny"'*) pass opencode-permission-config-denies-auth-logout ;;
  *) bad opencode-permission-config-denies-auth-logout ;;
esac

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
jq empty "$OC_CONFIG" >/dev/null 2>&1 && pass opencode-permission-config-valid-json || bad opencode-permission-config-valid-json

# ==============================================================
# launch_reviewer
#
# Recording stubs (distinct from the plain "exit 0" claude/codex/opencode
# stubs used for detect_reviewers above) that capture their own argv,
# stdin, cwd, and the OPENCODE_CONFIG env var into files under
# LAUNCH_RECORD_DIR, so this can assert on exactly what launch_reviewer
# handed the underlying CLI -- not just that something ran.
# ==============================================================

LAUNCH_ROOT="$T/launch-fixture"
LAUNCH_WT="$(_make_worktree_fixture "$LAUNCH_ROOT")"
LAUNCH_LOGS="$LAUNCH_ROOT/logs"
mkdir -p "$LAUNCH_LOGS"
LAUNCH_RECORD_DIR="$LAUNCH_ROOT/records"
mkdir -p "$LAUNCH_RECORD_DIR"

LAUNCH_STUB_BIN="$T/launch-stub-bin"
mkdir -p "$LAUNCH_STUB_BIN"
cat > "$LAUNCH_STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
name="$(basename "$0")"
: > "$LAUNCH_RECORD_DIR/$name.argv"
for a in "$@"; do printf '%s\n' "$a" >> "$LAUNCH_RECORD_DIR/$name.argv"; done
pwd > "$LAUNCH_RECORD_DIR/$name.pwd"
cat > "$LAUNCH_RECORD_DIR/$name.stdin"
printf '%s' "${OPENCODE_CONFIG:-}" > "$LAUNCH_RECORD_DIR/$name.env-opencode-config"
echo "stub $name ran"
sleep 0.1
exit "${LAUNCH_STUB_EXIT_CODE:-0}"
STUB
chmod +x "$LAUNCH_STUB_BIN/claude"
cp "$LAUNCH_STUB_BIN/claude" "$LAUNCH_STUB_BIN/codex"
cp "$LAUNCH_STUB_BIN/claude" "$LAUNCH_STUB_BIN/opencode"

export PATH="$LAUNCH_STUB_BIN:$saved_path"
export LAUNCH_RECORD_DIR

printf 'codex-prompt-content' > "$LAUNCH_LOGS/codex.prompt"
pid_codex="$(launch_reviewer codex "$LAUNCH_WT" "$LAUNCH_LOGS/codex.log" < "$LAUNCH_LOGS/codex.prompt")"

# Bounded poll for the backgrounded stub to actually finish (its exit-code
# file only appears once it does) instead of guessing a sleep duration.
i=0
until [ -f "$LAUNCH_ROOT/.exit-$pid_codex" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$pid_codex" -gt 0 ] 2>/dev/null && pass launch-reviewer-codex-pid-is-numeric || bad launch-reviewer-codex-pid-is-numeric

# codex must receive `-C <worktree>` as adjacent argv entries, not just
# have both tokens appear somewhere.
mapfile -t codex_argv < "$LAUNCH_RECORD_DIR/codex.argv"
found=0
for idx in "${!codex_argv[@]}"; do
  if [ "${codex_argv[$idx]}" = "-C" ] && [ "${codex_argv[$((idx + 1))]:-}" = "$LAUNCH_WT" ]; then
    found=1
  fi
done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$found" -eq 1 ] && pass launch-reviewer-codex-workdir-flag || bad launch-reviewer-codex-workdir-flag

case "$(cat "$LAUNCH_RECORD_DIR/codex.argv")" in
  *'read-only'*) pass launch-reviewer-codex-sandbox-flag ;;
  *) bad launch-reviewer-codex-sandbox-flag ;;
esac

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$(cat "$LAUNCH_RECORD_DIR/codex.stdin")" = "codex-prompt-content" ] && pass launch-reviewer-codex-stdin-matches-prompt || bad launch-reviewer-codex-stdin-matches-prompt

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -s "$LAUNCH_LOGS/codex.log" ] && grep -qF 'stub codex ran' "$LAUNCH_LOGS/codex.log" && pass launch-reviewer-codex-log-created-and-written || bad launch-reviewer-codex-log-created-and-written

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -f "$LAUNCH_ROOT/.git-status-before-$pid_codex" ] && pass launch-reviewer-codex-records-before-snapshot || bad launch-reviewer-codex-records-before-snapshot

# --- direct pairing: build_prompt's real output fed straight into
# launch_reviewer, then compared byte-for-byte against what the stub
# actually received on stdin. The stdin-matches-a-canned-string case above
# and the build_prompt-output tests elsewhere in this file only establish
# this property by combining two separate tests; this one exercises the
# real handoff between the two functions directly. ---

bp_direct_prompt="$(build_prompt "$REAL_CONTRACT" "https://github.com/acme/widgets/pull/1" "$LAUNCH_ROOT" \
  codex "direct-pairing-model-marker" "$LAUNCH_WT" "origin/main")"
printf '%s' "$bp_direct_prompt" > "$LAUNCH_LOGS/codex-direct.prompt"
pid_codex_direct="$(launch_reviewer codex "$LAUNCH_WT" "$LAUNCH_LOGS/codex-direct.log" < "$LAUNCH_LOGS/codex-direct.prompt")"
i=0
until [ -f "$LAUNCH_ROOT/.exit-$pid_codex_direct" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$(cat "$LAUNCH_RECORD_DIR/codex.stdin")" = "$bp_direct_prompt" ] && pass launch-reviewer-receives-real-build-prompt-output || bad launch-reviewer-receives-real-build-prompt-output

# --- opencode: --dir flag, OPENCODE_CONFIG env var wired to a real config file ---

printf 'opencode-prompt-content' > "$LAUNCH_LOGS/opencode.prompt"
pid_opencode="$(launch_reviewer opencode "$LAUNCH_WT" "$LAUNCH_LOGS/opencode.log" < "$LAUNCH_LOGS/opencode.prompt")"
i=0
until [ -f "$LAUNCH_ROOT/.exit-$pid_opencode" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done

mapfile -t opencode_argv < "$LAUNCH_RECORD_DIR/opencode.argv"
found=0
for idx in "${!opencode_argv[@]}"; do
  if [ "${opencode_argv[$idx]}" = "--dir" ] && [ "${opencode_argv[$((idx + 1))]:-}" = "$LAUNCH_WT" ]; then
    found=1
  fi
done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$found" -eq 1 ] && pass launch-reviewer-opencode-workdir-flag || bad launch-reviewer-opencode-workdir-flag

# --auto is required alongside the permission config (see launch_reviewer's
# docstring): without it, any permission this run's config leaves unset
# would block waiting for a human who, in this headless run, never
# answers -- the same class of gap the claude dontAsk/codex read-only
# flag assertions elsewhere in this section already cover for their own
# CLIs, so this closes the one CLI that didn't have an equivalent check.
case "$(cat "$LAUNCH_RECORD_DIR/opencode.argv")" in
  *'--auto'*) pass launch-reviewer-opencode-auto-flag ;;
  *) bad launch-reviewer-opencode-auto-flag ;;
esac

oc_env_config_path="$(cat "$LAUNCH_RECORD_DIR/opencode.env-opencode-config")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -n "$oc_env_config_path" ] && [ -s "$oc_env_config_path" ] && pass launch-reviewer-opencode-config-env-set || bad launch-reviewer-opencode-config-env-set
case "$(cat "$oc_env_config_path" 2>/dev/null)" in
  *'"edit": "deny"'*) pass launch-reviewer-opencode-config-content ;;
  *) bad launch-reviewer-opencode-config-content ;;
esac

# --- claude: no -C/--dir flag; instead the process's own cwd is the worktree ---

printf 'claude-prompt-content' > "$LAUNCH_LOGS/claude.prompt"
pid_claude="$(launch_reviewer claude "$LAUNCH_WT" "$LAUNCH_LOGS/claude.log" < "$LAUNCH_LOGS/claude.prompt")"
i=0
until [ -f "$LAUNCH_ROOT/.exit-$pid_claude" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$(cat "$LAUNCH_RECORD_DIR/claude.pwd")" = "$LAUNCH_WT" ] && pass launch-reviewer-claude-cwd-is-worktree || bad launch-reviewer-claude-cwd-is-worktree
case "$(cat "$LAUNCH_RECORD_DIR/claude.argv")" in
  *'-C'*|*'--dir'*) bad launch-reviewer-claude-no-workdir-flag ;;
  *) pass launch-reviewer-claude-no-workdir-flag ;;
esac
case "$(cat "$LAUNCH_RECORD_DIR/claude.argv")" in
  *'dontAsk'*) pass launch-reviewer-claude-permission-mode ;;
  *) bad launch-reviewer-claude-permission-mode ;;
esac
# The reviewer no longer executes any `gh` command at all (it prints its
# review to stdout instead of posting anything itself -- see
# launch_reviewer's docstring), so there must be no Bash pattern for `gh
# pr comment` anywhere in --allowedTools.
case "$(cat "$LAUNCH_RECORD_DIR/claude.argv")" in
  *'Bash(gh pr comment:*)'*) bad launch-reviewer-claude-no-gh-comment-bash-pattern ;;
  *) pass launch-reviewer-claude-no-gh-comment-bash-pattern ;;
esac

# Write must be on --disallowedTools and must NOT be on --allowedTools:
# this reviewer has no write capability of any kind any more (a real
# claude binary confirmed dontAsk mode makes the Write tool entirely
# unavailable under this exact flag pair -- "Write tool 在本 session 不存
# 在" -- while the same flag pair still let a real `git diff` run; see
# launch_reviewer's docstring) -- checked as the argument immediately
# following each flag, not just "Write appears somewhere", so this can't
# be fooled by Write showing up in the wrong flag's value.
mapfile -t claude_argv < "$LAUNCH_RECORD_DIR/claude.argv"
write_wrongly_allowed=0
write_disallowed=0
edit_notebookedit_disallowed=0
for idx in "${!claude_argv[@]}"; do
  case "${claude_argv[$idx]}" in
    --allowedTools)
      case "${claude_argv[$((idx + 1))]:-}" in
        *Write*) write_wrongly_allowed=1 ;;
      esac
      ;;
    --disallowedTools)
      case "${claude_argv[$((idx + 1))]:-}" in
        *Write*) write_disallowed=1 ;;
      esac
      case "${claude_argv[$((idx + 1))]:-}" in
        *Edit*NotebookEdit*) edit_notebookedit_disallowed=1 ;;
      esac
      ;;
  esac
done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$write_wrongly_allowed" -eq 0 ] && pass launch-reviewer-claude-write-not-allowed || bad launch-reviewer-claude-write-not-allowed
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$write_disallowed" -eq 1 ] && pass launch-reviewer-claude-disallows-write || bad launch-reviewer-claude-disallows-write
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$edit_notebookedit_disallowed" -eq 1 ] && pass launch-reviewer-claude-disallows-edit-notebookedit || bad launch-reviewer-claude-disallows-edit-notebookedit

# --- unknown CLI name -> non-zero, no PID printed ---

if out="$(launch_reviewer bogus-cli "$LAUNCH_WT" "$LAUNCH_LOGS/bogus.log" < /dev/null 2>/dev/null)"; then
  bad launch-reviewer-unknown-cli
else
  pass launch-reviewer-unknown-cli
fi
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -z "$out" ] && pass launch-reviewer-unknown-cli-no-output || bad launch-reviewer-unknown-cli-no-output

unset LAUNCH_RECORD_DIR
export PATH="$saved_path"

# ==============================================================
# launch_reviewer -- stdout and stderr are captured to separate files
#
# The reviewer's full review (wrapped in the contract's BEGIN/END markers)
# is what SKILL.md parses back out of <cli>.log, so this confirms directly
# -- against a stub that actually interleaves stdout and stderr writes,
# not just a stub that happens to only use one stream -- that <cli>.log
# ends up as exactly the stdout content, complete, in order, with both
# marker lines intact, and that stderr never lands in it at all.
# ==============================================================

LOGSPLIT_ROOT="$T/logsplit-fixture"
LOGSPLIT_WT="$(_make_worktree_fixture "$LOGSPLIT_ROOT")"
LOGSPLIT_LOGS="$LOGSPLIT_ROOT/logs"
mkdir -p "$LOGSPLIT_LOGS"

LOGSPLIT_STUB_BIN="$T/logsplit-stub-bin"
mkdir -p "$LOGSPLIT_STUB_BIN"
cat > "$LOGSPLIT_STUB_BIN/codex" <<'STUB'
#!/usr/bin/env bash
echo "===PR-REVIEW-BY-MULTI-AGENTS-BEGIN==="
echo "line one of the review"
echo "diagnostic noise one" >&2
echo "line two of the review"
echo "diagnostic noise two" >&2
echo "===PR-REVIEW-BY-MULTI-AGENTS-END==="
exit 0
STUB
chmod +x "$LOGSPLIT_STUB_BIN/codex"

export PATH="$LOGSPLIT_STUB_BIN:$saved_path"
printf 'p' > "$LOGSPLIT_LOGS/codex.prompt"
logsplit_pid="$(launch_reviewer codex "$LOGSPLIT_WT" "$LOGSPLIT_LOGS/codex.log" < "$LOGSPLIT_LOGS/codex.prompt")"
i=0
until [ -f "$LOGSPLIT_ROOT/.exit-$logsplit_pid" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
export PATH="$saved_path"

logsplit_log_content="$(cat "$LOGSPLIT_LOGS/codex.log" 2>/dev/null)"
logsplit_expected=$'===PR-REVIEW-BY-MULTI-AGENTS-BEGIN===\nline one of the review\nline two of the review\n===PR-REVIEW-BY-MULTI-AGENTS-END==='
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$logsplit_log_content" = "$logsplit_expected" ] && pass launch-reviewer-log-file-is-stdout-only-and-complete || bad launch-reviewer-log-file-is-stdout-only-and-complete

case "$logsplit_log_content" in
  *'diagnostic noise'*) bad launch-reviewer-log-file-excludes-stderr ;;
  *) pass launch-reviewer-log-file-excludes-stderr ;;
esac

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -s "$LOGSPLIT_LOGS/codex.log.stderr" ] && grep -qF 'diagnostic noise one' "$LOGSPLIT_LOGS/codex.log.stderr" 2>/dev/null && pass launch-reviewer-stderr-captured-separately || bad launch-reviewer-stderr-captured-separately

# ==============================================================
# spawn_supervisor
#
# Each scenario below gets its own fresh worktree fixture, so the
# git-status invalidation checks stay unambiguous rather than depending on
# how a shared worktree happened to interleave across concurrently
# launched reviewers. spawn_supervisor's own docstring documents that
# interleaving as a known, accepted limitation of processing PIDs
# sequentially against one shared worktree (conservative: it can only
# false-flag an innocent reviewer as invalidated, never miss a real
# tamper) -- these tests isolate around it entirely rather than exercising
# it, so they stay deterministic instead of depending on a particular
# ordering of concurrently launched reviewers.
#
# None of the stub reviewers below print the contract's BEGIN/END
# markers, so every posting outcome in this section is "no-content" --
# that is expected and correct here (these tests are about exit-code
# capture, invalidation detection, PID convergence, and SIGHUP survival,
# not about the extract-and-post mechanism itself, which gets its own
# dedicated section below with stubs that do print markers). No `gh` stub
# is needed on PATH for any of this section either: _post_review_comment
# never calls `gh` at all when extraction fails first.
# ==============================================================

SV_STUB_BIN="$T/supervisor-stub-bin"
mkdir -p "$SV_STUB_BIN"

# A "dirty" reviewer: writes a file into the worktree it's given via -C,
# then exits with a distinct non-zero code so both the exit-code capture
# and the invalidation detection can be asserted in the same run.
cat > "$SV_STUB_BIN/codex" <<'STUB'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  if [ "$prev" = "-C" ]; then
    printf 'dirty\n' > "$a/INJECTED-BY-TEST.txt"
  fi
  prev="$a"
done
exit "${LAUNCH_STUB_EXIT_CODE:-5}"
STUB
chmod +x "$SV_STUB_BIN/codex"

# A "clean" reviewer: touches nothing, exits 0.
cat > "$SV_STUB_BIN/opencode" <<'STUB'
#!/usr/bin/env bash
sleep 0.1
exit 0
STUB
chmod +x "$SV_STUB_BIN/opencode"

export PATH="$SV_STUB_BIN:$saved_path"

# --- single PID, dirty: worktree_status=invalidated, worktree still removed ---

SV1_ROOT="$T/supervisor-fixture-invalidated"
SV1_WT="$(_make_worktree_fixture "$SV1_ROOT")"
mkdir -p "$SV1_ROOT/logs"
printf 'p' > "$SV1_ROOT/logs/codex.prompt"
sv1_pid="$(launch_reviewer codex "$SV1_WT" "$SV1_ROOT/logs/codex.log" < "$SV1_ROOT/logs/codex.prompt")"
SV1_SUMMARY="$SV1_ROOT/summary.txt"
# `git worktree remove` (which spawn_supervisor's background subshell runs
# at the end) needs a cwd inside the repo it's removing a worktree from --
# same precondition setup_worktree's own tests rely on cwd for. Running
# the call itself inside a `(cd ... && ...)` subshell scopes that cd to
# just this call, including the backgrounded subshell it forks internally
# (which inherits whatever cwd was active when spawn_supervisor was
# invoked), without disturbing this test script's own cwd afterward.
(cd "$SV1_ROOT/work" && spawn_supervisor "$SV1_WT" "$SV1_SUMMARY" acme widgets 1 "$sv1_pid")

i=0
until [ -s "$SV1_SUMMARY" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done

sv1_line="$(cat "$SV1_SUMMARY" 2>/dev/null)"
case "$sv1_line" in
  "pid=$sv1_pid exit=5"*'worktree_status=invalidated'*'post_status=no-content') pass spawn-supervisor-records-exit-code-and-invalidation ;;
  *) bad spawn-supervisor-records-exit-code-and-invalidation ;;
esac

i=0
until [ ! -e "$SV1_WT" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -e "$SV1_WT" ] && pass spawn-supervisor-removes-worktree || bad spawn-supervisor-removes-worktree
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -d "$SV1_ROOT/logs" ] && pass spawn-supervisor-preserves-logs-dir || bad spawn-supervisor-preserves-logs-dir

# --- single PID, clean: worktree_status=ok ---

SV2_ROOT="$T/supervisor-fixture-ok"
SV2_WT="$(_make_worktree_fixture "$SV2_ROOT")"
mkdir -p "$SV2_ROOT/logs"
printf 'p' > "$SV2_ROOT/logs/opencode.prompt"
sv2_pid="$(launch_reviewer opencode "$SV2_WT" "$SV2_ROOT/logs/opencode.log" < "$SV2_ROOT/logs/opencode.prompt")"
SV2_SUMMARY="$SV2_ROOT/summary.txt"
(cd "$SV2_ROOT/work" && spawn_supervisor "$SV2_WT" "$SV2_SUMMARY" acme widgets 2 "$sv2_pid")

i=0
until [ -s "$SV2_SUMMARY" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done

case "$(cat "$SV2_SUMMARY" 2>/dev/null)" in
  "pid=$sv2_pid exit=0"*'worktree_status=ok'*'post_status=no-content') pass spawn-supervisor-ok-when-unmodified ;;
  *) bad spawn-supervisor-ok-when-unmodified ;;
esac

# --- multiple PIDs converge without being hardcoded to three ---

SV3_ROOT="$T/supervisor-fixture-multi"
SV3_WT="$(_make_worktree_fixture "$SV3_ROOT")"
mkdir -p "$SV3_ROOT/logs"
printf 'p' > "$SV3_ROOT/logs/opencode-a.prompt"
printf 'p' > "$SV3_ROOT/logs/opencode-b.prompt"
sv3_pid_a="$(launch_reviewer opencode "$SV3_WT" "$SV3_ROOT/logs/opencode-a.log" < "$SV3_ROOT/logs/opencode-a.prompt")"
sv3_pid_b="$(launch_reviewer opencode "$SV3_WT" "$SV3_ROOT/logs/opencode-b.log" < "$SV3_ROOT/logs/opencode-b.prompt")"
SV3_SUMMARY="$SV3_ROOT/summary.txt"
(cd "$SV3_ROOT/work" && spawn_supervisor "$SV3_WT" "$SV3_SUMMARY" acme widgets 3 "$sv3_pid_a" "$sv3_pid_b")

i=0
until { [ -f "$SV3_SUMMARY" ] && [ "$(wc -l < "$SV3_SUMMARY")" -eq 2 ]; } || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$(wc -l < "$SV3_SUMMARY")" -eq 2 ] && pass spawn-supervisor-converges-on-actual-pid-count || bad spawn-supervisor-converges-on-actual-pid-count
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -q "^pid=$sv3_pid_a " "$SV3_SUMMARY" && grep -q "^pid=$sv3_pid_b " "$SV3_SUMMARY" && pass spawn-supervisor-records-every-given-pid || bad spawn-supervisor-records-every-given-pid

# --- the backgrounded subshell survives a real SIGHUP delivered directly
# to it, not just `disown` (which only stops *this shell* from sending
# SIGHUP on its own exit -- it does nothing about the kernel delivering
# one some other way, e.g. a closed controlling terminal). $! is captured
# from *inside* the same subshell that calls spawn_supervisor (into a
# file, since $! itself does not survive that subshell exiting) --
# spawn_supervisor's own internal `(...)&` is what $! refers to right
# after the call, per bash's normal $!-after-a-backgrounded-job semantics,
# even though that job gets disowned immediately after. ---

SV4_ROOT="$T/supervisor-fixture-sighup"
SV4_WT="$(_make_worktree_fixture "$SV4_ROOT")"
mkdir -p "$SV4_ROOT/logs"
printf 'p' > "$SV4_ROOT/logs/opencode.prompt"
sv4_pid="$(launch_reviewer opencode "$SV4_WT" "$SV4_ROOT/logs/opencode.log" < "$SV4_ROOT/logs/opencode.prompt")"
SV4_SUMMARY="$SV4_ROOT/summary.txt"
SV4_PID_FILE="$T/sv4-supervisor-pid.txt"
(
  cd "$SV4_ROOT/work" || exit 1
  spawn_supervisor "$SV4_WT" "$SV4_SUMMARY" acme widgets 4 "$sv4_pid"
  printf '%s' "$!" > "$SV4_PID_FILE"
)
sv4_supervisor_pid="$(cat "$SV4_PID_FILE" 2>/dev/null)"
# A real, unignored SIGHUP would kill a plain backgrounded subshell
# instantly; giving it a moment first makes sure this is actually
# targeting a live process, not racing its own already-fast completion.
sleep 0.2
kill -HUP "$sv4_supervisor_pid" 2>/dev/null || true

i=0
until [ -s "$SV4_SUMMARY" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -s "$SV4_SUMMARY" ] && pass spawn-supervisor-survives-sighup || bad spawn-supervisor-survives-sighup
i=0
until [ ! -e "$SV4_WT" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -e "$SV4_WT" ] && pass spawn-supervisor-removes-worktree-after-sighup || bad spawn-supervisor-removes-worktree-after-sighup

export PATH="$saved_path"

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
# _post_review_comment
#
# A stub gh that records every invocation to a call-count file, so
# "gh was never even attempted" (the no-content case) can be told apart
# from "gh was attempted and failed".
# ==============================================================

POST_STUB_BIN="$T/post-stub-bin"
mkdir -p "$POST_STUB_BIN"
cat > "$POST_STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALL_LOG"
exit "${GH_STUB_EXIT:-0}"
STUB
chmod +x "$POST_STUB_BIN/gh"

export PATH="$POST_STUB_BIN:$saved_path"

# _post_review_comment no longer does extraction itself (spawn_supervisor
# now decides whether to call it *after* checking exit code/worktree
# status, which needs the extracted content either way -- see its own
# docstring on "withheld"), so these tests extract via
# _extract_review_content directly first, exactly like spawn_supervisor's
# own loop now does, then call _post_review_comment with the already-
# written content file.

# --- success: gh called once with the right args, the content file it
# was pointed at contains exactly the extracted text ---

POST_ROOT="$T/post-fixture"
mkdir -p "$POST_ROOT"
export GH_CALL_LOG="$POST_ROOT/gh-calls-success.log"
: > "$GH_CALL_LOG"
export GH_STUB_EXIT=0
post_content="$(_extract_review_content "$EXTRACT_FIXTURE_DIR/good.log")"
printf '%s' "$post_content" > "$POST_ROOT/content-success.md"
post_status="$(_post_review_comment acme widgets 42 "$POST_ROOT/content-success.md")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$post_status" = "posted" ] && pass post-review-comment-success-status || bad post-review-comment-success-status
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$(wc -l < "$GH_CALL_LOG")" -eq 1 ] && pass post-review-comment-success-calls-gh-once || bad post-review-comment-success-calls-gh-once
case "$(cat "$GH_CALL_LOG")" in
  'pr comment 42 --repo acme/widgets --body-file '*) pass post-review-comment-success-correct-args ;;
  *) bad post-review-comment-success-correct-args ;;
esac
out="$(cat "$POST_ROOT/content-success.md" 2>/dev/null)"
expected=$'line one of the review\nline two of the review'
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$out" = "$expected" ] && pass post-review-comment-content-file-correct || bad post-review-comment-content-file-correct

# --- failure: retried exactly once (two attempts total), status recorded
# as post-failed, content file kept (not deleted) so the review isn't lost ---

: > "$GH_CALL_LOG"
export GH_STUB_EXIT=1
printf '%s' "$post_content" > "$POST_ROOT/content-failed.md"
post_status="$(_post_review_comment acme widgets 42 "$POST_ROOT/content-failed.md")"
export GH_STUB_EXIT=0
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$post_status" = "post-failed" ] && pass post-review-comment-failure-status || bad post-review-comment-failure-status
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$(wc -l < "$GH_CALL_LOG")" -eq 2 ] && pass post-review-comment-failure-retries-once || bad post-review-comment-failure-retries-once
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -s "$POST_ROOT/content-failed.md" ] && pass post-review-comment-failure-keeps-content-file || bad post-review-comment-failure-keeps-content-file

unset GH_CALL_LOG GH_STUB_EXIT
export PATH="$saved_path"

# ==============================================================
# spawn_supervisor -- end-to-end posting through a real reviewer process
#
# A stub codex that actually prints the BEGIN/END markers (unlike the
# stubs in the spawn_supervisor section above, which exist to test
# exit-code/invalidation/PID-convergence and never print any markers) and
# a stub gh that records calls, wired through launch_reviewer and
# spawn_supervisor together end to end -- not just calling
# _post_review_comment directly -- confirming the summary_file's new
# post_status field reflects a real posting outcome for a real reviewer
# run, and that spawn_supervisor picks the right log file for the right
# PID via the .log-<pid> file launch_reviewer writes.
# ==============================================================

POSTE2E_ROOT="$T/post-e2e-fixture"
POSTE2E_WT="$(_make_worktree_fixture "$POSTE2E_ROOT")"
mkdir -p "$POSTE2E_ROOT/logs"

POSTE2E_STUB_BIN="$T/post-e2e-stub-bin"
mkdir -p "$POSTE2E_STUB_BIN"
cat > "$POSTE2E_STUB_BIN/codex" <<'STUB'
#!/usr/bin/env bash
echo "===PR-REVIEW-BY-MULTI-AGENTS-BEGIN==="
echo "nothing critical found"
echo "===PR-REVIEW-BY-MULTI-AGENTS-END==="
exit 0
STUB
chmod +x "$POSTE2E_STUB_BIN/codex"
cp "$POST_STUB_BIN/gh" "$POSTE2E_STUB_BIN/gh"

export PATH="$POSTE2E_STUB_BIN:$saved_path"
export GH_CALL_LOG="$POSTE2E_ROOT/gh-calls.log"
: > "$GH_CALL_LOG"
export GH_STUB_EXIT=0

printf 'p' > "$POSTE2E_ROOT/logs/codex.prompt"
poste2e_pid="$(launch_reviewer codex "$POSTE2E_WT" "$POSTE2E_ROOT/logs/codex.log" < "$POSTE2E_ROOT/logs/codex.prompt")"
POSTE2E_SUMMARY="$POSTE2E_ROOT/summary.txt"
(cd "$POSTE2E_ROOT/work" && spawn_supervisor "$POSTE2E_WT" "$POSTE2E_SUMMARY" acme widgets 99 "$poste2e_pid")

i=0
until [ -s "$POSTE2E_SUMMARY" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done

case "$(cat "$POSTE2E_SUMMARY" 2>/dev/null)" in
  "pid=$poste2e_pid exit=0"*'post_status=posted') pass spawn-supervisor-e2e-posts-successfully ;;
  *) bad spawn-supervisor-e2e-posts-successfully ;;
esac
case "$(cat "$GH_CALL_LOG" 2>/dev/null)" in
  'pr comment 99 --repo acme/widgets --body-file '*) pass spawn-supervisor-e2e-gh-called-with-correct-pr ;;
  *) bad spawn-supervisor-e2e-gh-called-with-correct-pr ;;
esac

unset GH_CALL_LOG GH_STUB_EXIT
export PATH="$saved_path"

# --- same real reviewer + spawn_supervisor pipeline, but gh always fails
# -- summary_file must show post_status=post-failed (not just tested at
# the _post_review_comment function level above, but end to end through
# a real spawn_supervisor run) ---

POSTFAIL_ROOT="$T/post-e2e-fail-fixture"
POSTFAIL_WT="$(_make_worktree_fixture "$POSTFAIL_ROOT")"
mkdir -p "$POSTFAIL_ROOT/logs"

export PATH="$POSTE2E_STUB_BIN:$saved_path"
export GH_CALL_LOG="$POSTFAIL_ROOT/gh-calls.log"
: > "$GH_CALL_LOG"
export GH_STUB_EXIT=1

printf 'p' > "$POSTFAIL_ROOT/logs/codex.prompt"
postfail_pid="$(launch_reviewer codex "$POSTFAIL_WT" "$POSTFAIL_ROOT/logs/codex.log" < "$POSTFAIL_ROOT/logs/codex.prompt")"
POSTFAIL_SUMMARY="$POSTFAIL_ROOT/summary.txt"
(cd "$POSTFAIL_ROOT/work" && spawn_supervisor "$POSTFAIL_WT" "$POSTFAIL_SUMMARY" acme widgets 100 "$postfail_pid")

i=0
until [ -s "$POSTFAIL_SUMMARY" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done

case "$(cat "$POSTFAIL_SUMMARY" 2>/dev/null)" in
  "pid=$postfail_pid exit=0"*'post_status=post-failed') pass spawn-supervisor-e2e-records-post-failure ;;
  *) bad spawn-supervisor-e2e-records-post-failure ;;
esac
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$(wc -l < "$GH_CALL_LOG")" -eq 2 ] && pass spawn-supervisor-e2e-post-failure-retried-once || bad spawn-supervisor-e2e-post-failure-retried-once

unset GH_CALL_LOG GH_STUB_EXIT
export PATH="$saved_path"

# --- posting is gated on exit code 0 AND worktree_status=ok -- a reviewer
# that produces a perfectly valid, marker-wrapped review but exits
# non-zero, or one whose worktree got tampered with during its run, must
# never be posted (post_status=withheld), while the extracted content is
# still saved to the same content_file a successful post would have used,
# so a human can still look at it. Both scenarios use a real marker-
# printing stub through the full launch_reviewer + spawn_supervisor
# pipeline, not a direct call to the lower-level helpers, since what's
# being pinned down here is spawn_supervisor's own gating decision. ---

WITHHOLD_STUB_BIN="$T/withhold-stub-bin"
mkdir -p "$WITHHOLD_STUB_BIN"
cp "$POST_STUB_BIN/gh" "$WITHHOLD_STUB_BIN/gh"

# Non-zero exit, otherwise a perfectly valid review.
cat > "$WITHHOLD_STUB_BIN/codex" <<'STUB'
#!/usr/bin/env bash
echo "===PR-REVIEW-BY-MULTI-AGENTS-BEGIN==="
echo "found a real issue, but then the process crashed"
echo "===PR-REVIEW-BY-MULTI-AGENTS-END==="
exit 3
STUB
chmod +x "$WITHHOLD_STUB_BIN/codex"

WITHHOLD_EXIT_ROOT="$T/withhold-exit-fixture"
WITHHOLD_EXIT_WT="$(_make_worktree_fixture "$WITHHOLD_EXIT_ROOT")"
mkdir -p "$WITHHOLD_EXIT_ROOT/logs"
export PATH="$WITHHOLD_STUB_BIN:$saved_path"
export GH_CALL_LOG="$WITHHOLD_EXIT_ROOT/gh-calls.log"
: > "$GH_CALL_LOG"
export GH_STUB_EXIT=0
printf 'p' > "$WITHHOLD_EXIT_ROOT/logs/codex.prompt"
withhold_exit_pid="$(launch_reviewer codex "$WITHHOLD_EXIT_WT" "$WITHHOLD_EXIT_ROOT/logs/codex.log" < "$WITHHOLD_EXIT_ROOT/logs/codex.prompt")"
WITHHOLD_EXIT_SUMMARY="$WITHHOLD_EXIT_ROOT/summary.txt"
(cd "$WITHHOLD_EXIT_ROOT/work" && spawn_supervisor "$WITHHOLD_EXIT_WT" "$WITHHOLD_EXIT_SUMMARY" acme widgets 200 "$withhold_exit_pid")

i=0
until [ -s "$WITHHOLD_EXIT_SUMMARY" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done

case "$(cat "$WITHHOLD_EXIT_SUMMARY" 2>/dev/null)" in
  "pid=$withhold_exit_pid exit=3"*'post_status=withheld') pass spawn-supervisor-withholds-on-nonzero-exit ;;
  *) bad spawn-supervisor-withholds-on-nonzero-exit ;;
esac
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -s "$GH_CALL_LOG" ] && pass spawn-supervisor-withheld-never-calls-gh-nonzero-exit || bad spawn-supervisor-withheld-never-calls-gh-nonzero-exit
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF 'found a real issue' "$WITHHOLD_EXIT_ROOT/.comment-body-$withhold_exit_pid.md" 2>/dev/null && pass spawn-supervisor-withheld-still-saves-content-nonzero-exit || bad spawn-supervisor-withheld-still-saves-content-nonzero-exit

unset GH_CALL_LOG GH_STUB_EXIT
export PATH="$saved_path"

# Exit 0, but the reviewer also wrote into the worktree it was given via
# -C (a contract violation the git-status comparison is specifically
# there to catch), producing a real invalidated result, not a contrived
# one.
cat > "$WITHHOLD_STUB_BIN/codex" <<'STUB'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  if [ "$prev" = "-C" ]; then
    printf 'dirty\n' > "$a/INJECTED-BY-WITHHOLD-TEST.txt"
  fi
  prev="$a"
done
echo "===PR-REVIEW-BY-MULTI-AGENTS-BEGIN==="
echo "a review the worktree tampering means we can no longer trust"
echo "===PR-REVIEW-BY-MULTI-AGENTS-END==="
exit 0
STUB
chmod +x "$WITHHOLD_STUB_BIN/codex"

WITHHOLD_INVALID_ROOT="$T/withhold-invalidated-fixture"
WITHHOLD_INVALID_WT="$(_make_worktree_fixture "$WITHHOLD_INVALID_ROOT")"
mkdir -p "$WITHHOLD_INVALID_ROOT/logs"
export PATH="$WITHHOLD_STUB_BIN:$saved_path"
export GH_CALL_LOG="$WITHHOLD_INVALID_ROOT/gh-calls.log"
: > "$GH_CALL_LOG"
printf 'p' > "$WITHHOLD_INVALID_ROOT/logs/codex.prompt"
withhold_invalid_pid="$(launch_reviewer codex "$WITHHOLD_INVALID_WT" "$WITHHOLD_INVALID_ROOT/logs/codex.log" < "$WITHHOLD_INVALID_ROOT/logs/codex.prompt")"
WITHHOLD_INVALID_SUMMARY="$WITHHOLD_INVALID_ROOT/summary.txt"
(cd "$WITHHOLD_INVALID_ROOT/work" && spawn_supervisor "$WITHHOLD_INVALID_WT" "$WITHHOLD_INVALID_SUMMARY" acme widgets 201 "$withhold_invalid_pid")

i=0
until [ -s "$WITHHOLD_INVALID_SUMMARY" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done

case "$(cat "$WITHHOLD_INVALID_SUMMARY" 2>/dev/null)" in
  "pid=$withhold_invalid_pid exit=0"*'worktree_status=invalidated'*'post_status=withheld') pass spawn-supervisor-withholds-on-invalidated-worktree ;;
  *) bad spawn-supervisor-withholds-on-invalidated-worktree ;;
esac
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -s "$GH_CALL_LOG" ] && pass spawn-supervisor-withheld-never-calls-gh-invalidated || bad spawn-supervisor-withheld-never-calls-gh-invalidated
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF 'tampering means' "$WITHHOLD_INVALID_ROOT/.comment-body-$withhold_invalid_pid.md" 2>/dev/null && pass spawn-supervisor-withheld-still-saves-content-invalidated || bad spawn-supervisor-withheld-still-saves-content-invalidated

unset GH_CALL_LOG
export PATH="$saved_path"

# ==============================================================
# print_summary
# ==============================================================

PS_LOGS="$T/print-summary-logs"
mkdir -p "$PS_LOGS"
printf '11111\n' > "$PS_LOGS/claude.pid"
printf '22222\n' > "$PS_LOGS/codex.pid"

ps_out="$(print_summary "$PS_LOGS" claude codex --skipped opencode)"

case "$ps_out" in
  *'claude'*'11111'*"$PS_LOGS/claude.log"*) pass print-summary-shows-dispatched-pid-and-log ;;
  *) bad print-summary-shows-dispatched-pid-and-log ;;
esac
case "$ps_out" in
  *'codex'*'22222'*"$PS_LOGS/codex.log"*) pass print-summary-shows-second-dispatched-entry ;;
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

ps_out_single="$(print_summary "$PS_LOGS" claude --skipped codex opencode)"
case "$ps_out_single" in
  *'交叉驗證'*) pass print-summary-cross-validation-note-for-one ;;
  *) bad print-summary-cross-validation-note-for-one ;;
esac

ps_out_none_skipped="$(print_summary "$PS_LOGS" claude codex opencode --skipped)"
case "$ps_out_none_skipped" in
  *'（無）'*) pass print-summary-none-skipped-marker ;;
  *) bad print-summary-none-skipped-marker ;;
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
# ever gets a chance to fetch -- exercised through a real main() run
# (bash "$RUN_SH" ...), not just a direct resolve_base_ref call, since
# what's actually being pinned down here is main()'s own call *order*.
# Before this fix, a run against the wrong owner/repo still mutated a
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

if out="$(cd "$ORIGIN_ORDER_FIXTURE/work" && CLAUDE_CONFIG_DIR="" GH_STUB_BASE_REF_NAME="origin-order-base-branch" \
  HOME="$T/origin-order-home" PATH="$STUB_BIN:$saved_path" \
  bash "$RUN_SH" "https://github.com/wrong-owner/wrong-repo/pull/1" "" "" 2>&1)"; then
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

# `bash` itself must be resolved via an absolute path here: prefixing
# PATH=$EMPTY_BIN onto the command line applies to resolving *that*
# command too, not just to what it does internally -- an empty PATH would
# make "bash" itself fail to be found (exit 127, "command not found"),
# which is not what this test is trying to exercise.
BASH_ABS_PATH="$(command -v bash)"
if out="$(cd "$GH_MISSING_FIXTURE" && PATH="$EMPTY_BIN" "$BASH_ABS_PATH" "$RUN_SH" "" "" "" 2>&1)"; then
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
# _dispatch_failed_cleanup
#
# Direct unit tests for the helper main()'s reviewer-dispatch loop calls
# on a partial failure (see its own docstring in run.sh): it must report
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
# main() end-to-end
#
# The most load-bearing test in this section: build_prompt takes 7
# positional parameters, and a caller that transposes two of them (e.g.
# swaps worktree_path and base_ref) produces a syntactically valid but
# semantically wrong prompt with no error anywhere -- set -u only catches
# a missing argument, never a misordered one. Every coordinate value
# below is deliberately distinct from every other, and each coordinate
# assertion checks that value against *its own* labeled line in the
# prompt file main() actually wrote to disk, not just that the value
# appears somewhere in it (which would pass even if two labels' values
# were swapped). The issue and design-doc materials, unlike the
# coordinates, are no longer handed to build_prompt directly -- main()
# resolves them into materials_dir via fetch_review_materials first -- so
# those two are instead checked by their own distinctive embedded
# content, the same way build_prompt's own section elsewhere in this file
# does.
#
# This also exercises run.sh's command-line contract end to end (task 5's
# own addition, not specified by the earlier tasks): three positional
# arguments -- PR link, issue link, design doc path -- invoked exactly as
# a real caller would, via `bash run.sh ...`, not by sourcing and calling
# main() directly (main() calls `exit` on its failure paths, which would
# kill this whole test script if called in-process instead of as a real
# subprocess).
#
# The origin remote is a literal https://github.com/acme9pr/widgets9pr.git
# URL, matching what _check_origin_matches needs to see in the raw
# configured value, with a `url.<local-path>.insteadOf` rule redirecting
# the actual fetch/push traffic to this fixture's own local bare repo --
# see GIT_FIXTURE's own comment on this technique.
# ==============================================================

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

# design_doc_path is resolved relative to main()'s own cwd (see
# fetch_review_materials), so this needs a real file on disk at the exact
# relative path handed to run.sh below, not just a distinctive string --
# an empty issue/design section renders as explicitly absent instead
# (see the fetch-materials-degrades-* tests above), so a nonexistent path
# here would silently exercise that path instead of the one this test
# means to cover.
mkdir -p "$E2E_FIXTURE/work/docs"
printf 'e2e-distinctive-design-doc-marker-content\n' > "$E2E_FIXTURE/work/docs/distinctive-design-doc-marker.md"

if out="$(cd "$E2E_FIXTURE/work" && CLAUDE_CONFIG_DIR="" GH_STUB_BASE_REF_NAME="e2e-distinctive-base" HOME="$E2E_HOME" PATH="$STUB_BIN:$saved_path" \
  bash "$RUN_SH" \
    "https://github.com/acme9pr/widgets9pr/pull/321" \
    "777" \
    "docs/distinctive-design-doc-marker.md" 2>&1)"; then
  pass main-e2e-succeeds
else
  bad main-e2e-succeeds
fi

E2E_LOGS_DIR="$(find "$E2E_HOME/.tmp" -type d -name logs 2>/dev/null | head -1)"
E2E_BASE_DIR="$(dirname "${E2E_LOGS_DIR:-/nonexistent}")"
E2E_PROMPT_FILE="$E2E_LOGS_DIR/codex.prompt"

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -n "$E2E_LOGS_DIR" ] && [ -s "$E2E_PROMPT_FILE" ] && pass main-e2e-prompt-file-written || bad main-e2e-prompt-file-written

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qxF -- '- PR：https://github.com/acme9pr/widgets9pr/pull/321' "$E2E_PROMPT_FILE" 2>/dev/null && pass main-e2e-prompt-pr-url-in-place || bad main-e2e-prompt-pr-url-in-place
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qxF -- "- git worktree 絕對路徑：$E2E_BASE_DIR/worktree" "$E2E_PROMPT_FILE" 2>/dev/null && pass main-e2e-prompt-worktree-path-in-place || bad main-e2e-prompt-worktree-path-in-place
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qxF -- '- base ref：origin/e2e-distinctive-base' "$E2E_PROMPT_FILE" 2>/dev/null && pass main-e2e-prompt-base-ref-in-place || bad main-e2e-prompt-base-ref-in-place
# issue_arg "777" resolves via _parse_issue_ref straight through
# fetch_review_materials to a real (stubbed) `gh issue view` call; its
# body is embedded into the prompt as material, not placed on its own
# coordinate line the way it was before build_prompt took materials_dir
# instead of issue_url.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF 'e2e-distinctive-issue-body-marker' "$E2E_PROMPT_FILE" 2>/dev/null && pass main-e2e-prompt-issue-material-embedded || bad main-e2e-prompt-issue-material-embedded
# Same shift for the design doc: its full text is embedded as material
# instead of its path being placed on its own coordinate line.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF 'e2e-distinctive-design-doc-marker-content' "$E2E_PROMPT_FILE" 2>/dev/null && pass main-e2e-prompt-design-material-embedded || bad main-e2e-prompt-design-material-embedded
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qxF -- '- 產出這則 review 的 CLI 名稱：codex' "$E2E_PROMPT_FILE" 2>/dev/null && pass main-e2e-prompt-cli-name-in-place || bad main-e2e-prompt-cli-name-in-place
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qxF -- '- 產出這則 review 的 model 名稱：e2e-distinctive-model' "$E2E_PROMPT_FILE" 2>/dev/null && pass main-e2e-prompt-model-in-place || bad main-e2e-prompt-model-in-place
# No scratch-directory coordinate at all any more: the reviewer prints
# its review to stdout (main()'s log file) instead of writing a comment-
# body file anywhere, so there is no longer a scratch path to hand it.
oc_e2e_prompt_content="$(cat "$E2E_PROMPT_FILE" 2>/dev/null)"
case "$oc_e2e_prompt_content" in
  *'暫存目錄'*) bad main-e2e-prompt-no-scratch-dir-coordinate ;;
  *) pass main-e2e-prompt-no-scratch-dir-coordinate ;;
esac

E2E_WORKTREE_DIR="$E2E_BASE_DIR/worktree"

# --- the `chmod -R a-w` mechanism main() applies to the worktree (closing
# the gap that every individual reviewer CLI's own sandbox/permission
# flags turned out, on real testing, not to fully close on their own --
# see launch_reviewer's docstring) is checked directly against its own
# fixture here, not against the e2e run above: that run's stub reviewers
# finish and get cleaned up by spawn_supervisor near-instantly, so
# checking the worktree's permissions or attempting a write against it
# *after* `bash "$RUN_SH"` has already returned would race spawn_supervisor
# possibly having already removed it. ---

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

# --- print_summary's own stdout (main()'s only output) names every
# dispatched reviewer with its PID and log path -- the exact chain
# SKILL.md's reporting depends on. ---

case "$out" in
  *'codex'*"$E2E_LOGS_DIR/codex.log"*) pass main-e2e-summary-output-lists-log-path ;;
  *) bad main-e2e-summary-output-lists-log-path ;;
esac

# --- spawn_supervisor's summary_file (base_dir/summary.txt, i.e. two
# directories up from any <cli>.log path -- the exact derivation SKILL.md
# uses to find it) eventually exists and converges to exactly one line per
# dispatched reviewer, then the worktree it removes on completion is
# actually gone. Bounded polling, not a fixed sleep, since this run's
# stub reviewers finish in well under a second but real ones would not. ---

E2E_SUMMARY_FILE="$E2E_BASE_DIR/summary.txt"
i=0
until { [ -f "$E2E_SUMMARY_FILE" ] && [ "$(wc -l < "$E2E_SUMMARY_FILE")" -eq 3 ]; } || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -f "$E2E_SUMMARY_FILE" ] && [ "$(wc -l < "$E2E_SUMMARY_FILE")" -eq 3 ] && pass main-e2e-summary-file-converges || bad main-e2e-summary-file-converges
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -q 'worktree_status=ok' "$E2E_SUMMARY_FILE" 2>/dev/null && pass main-e2e-summary-file-worktree-status-ok || bad main-e2e-summary-file-worktree-status-ok

i=0
until [ ! -e "$E2E_WORKTREE_DIR" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -e "$E2E_WORKTREE_DIR" ] && pass main-e2e-worktree-removed-after-completion || bad main-e2e-worktree-removed-after-completion

# --- all three positional args empty: PR derives from branch, issue/design
# render as "not provided" rather than blocking the run ---

E2E_HOME2="$T/main-e2e-home2"
if out="$(cd "$E2E_FIXTURE/work" \
  && CLAUDE_CONFIG_DIR="" GH_STUB_DERIVE_OK=1 GH_STUB_DERIVED_URL="https://github.com/acme9pr/widgets9pr/pull/321" \
     GH_STUB_BASE_REF_NAME="e2e-distinctive-base" HOME="$E2E_HOME2" PATH="$STUB_BIN:$saved_path" \
  bash "$RUN_SH" "" "" "" 2>&1)"; then
  pass main-e2e-empty-args-accepted
else
  bad main-e2e-empty-args-accepted
fi

E2E_LOGS_DIR2="$(find "$E2E_HOME2/.tmp" -type d -name logs 2>/dev/null | head -1)"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -n "$E2E_LOGS_DIR2" ] && grep -qF '未提供' "$E2E_LOGS_DIR2/codex.prompt" 2>/dev/null && pass main-e2e-empty-args-render-not-provided || bad main-e2e-empty-args-render-not-provided

# --- main() actually applies its own worktree/logs_dir read-only chmod,
# not just "chmod behaves this way when I do it myself in a fixture"
# (which CHMOD_ROOT above already covers, but deleting main()'s own
# chmod line entirely would leave that test just as green). logs_dir is
# never removed by this pipeline, so checking its permissions after
# `bash "$RUN_SH"` returns is not racy; the worktree, on the other hand,
# gets removed asynchronously by spawn_supervisor, so checking *its*
# permissions the same way would race that removal -- instead, a real
# stub reviewer attempts one write against the worktree path it was
# actually launched against (via its own -C argument) at startup, and
# records whether that write succeeded or was blocked into its own
# stdout (captured in <cli>.log, outside the worktree, so it survives
# the worktree's later removal) -- avoiding both the race and having to
# inspect permissions after the fact at all. ---

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
# claude and opencode are also stubbed here (as trivial "exit 0" stand-ins
# that never actually run for this test's own purpose) even though this
# test only cares about codex's own write-attempt probe: PATH below is
# "$CHMODE2E_STUB_BIN:$saved_path", not an exclusive PATH, so leaving
# either name out would let detect_reviewers resolve it to the *real*,
# system-installed claude/opencode further down that same PATH -- which
# main() would then actually launch, for real, burning real tokens. Bitten
# by exactly this once already earlier in this same task (see this task's
# own report).
cp "$STUB_BIN/claude" "$CHMODE2E_STUB_BIN/claude"
cp "$STUB_BIN/opencode" "$CHMODE2E_STUB_BIN/opencode"
cat > "$CHMODE2E_STUB_BIN/codex" <<'STUB'
#!/usr/bin/env bash
prev=""
worktree_arg=""
for a in "$@"; do
  [ "$prev" = "-C" ] && worktree_arg="$a"
  prev="$a"
done
if : > "$worktree_arg/WRITE-ATTEMPT-PROBE.txt" 2>/dev/null; then
  echo "WRITE_ATTEMPT_RESULT: succeeded"
else
  echo "WRITE_ATTEMPT_RESULT: blocked"
fi
echo "===PR-REVIEW-BY-MULTI-AGENTS-BEGIN==="
echo "probe review"
echo "===PR-REVIEW-BY-MULTI-AGENTS-END==="
exit 0
STUB
chmod +x "$CHMODE2E_STUB_BIN/codex"

CHMODE2E_HOME="$T/chmod-e2e-home"
if out="$(cd "$CHMODE2E_FIXTURE/work" && CLAUDE_CONFIG_DIR="" GH_STUB_BASE_REF_NAME=main HOME="$CHMODE2E_HOME" PATH="$CHMODE2E_STUB_BIN:$saved_path" \
  bash "$RUN_SH" "https://github.com/acme/widgets/pull/50" "" "" 2>&1)"; then
  pass main-e2e-chmod-run-succeeds
else
  bad main-e2e-chmod-run-succeeds
fi

CHMODE2E_LOGS_DIR="$(find "$CHMODE2E_HOME/.tmp" -type d -name logs 2>/dev/null | head -1)"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -n "$CHMODE2E_LOGS_DIR" ] && grep -qF 'WRITE_ATTEMPT_RESULT: blocked' "$CHMODE2E_LOGS_DIR/codex.log" 2>/dev/null && pass main-e2e-worktree-write-actually-blocked || bad main-e2e-worktree-write-actually-blocked

CHMODE2E_BASE_DIR="$(dirname "${CHMODE2E_LOGS_DIR:-/nonexistent}")"
# Not racy: logs_dir is never removed by this pipeline, so its
# permissions are stable to inspect any time after the run returns.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -d "$CHMODE2E_LOGS_DIR" ] && [ ! -w "$CHMODE2E_LOGS_DIR" ] && pass main-e2e-logs-dir-actually-read-only || bad main-e2e-logs-dir-actually-read-only
if ( : > "$CHMODE2E_LOGS_DIR/should-not-be-writable.txt" ) 2>/dev/null; then
  bad main-e2e-logs-dir-write-actually-denied
else
  pass main-e2e-logs-dir-write-actually-denied
fi
chmod -R u+w "$CHMODE2E_BASE_DIR" 2>/dev/null || true

exit $fail
