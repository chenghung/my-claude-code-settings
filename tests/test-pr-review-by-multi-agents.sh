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
trap 'rm -rf "$T"' EXIT

STUB_BIN="$T/bin"
EMPTY_BIN="$T/empty-bin"
mkdir -p "$STUB_BIN" "$EMPTY_BIN"

saved_path="$PATH"

# ------------------------------------------------------------
# Stub gh: a single stand-in covering every gh invocation this script makes
# (derive-URL lookup, auth check, PR-existence check), toggled entirely by
# env vars so each test case controls exactly one outcome. Never touches
# the real GitHub API.
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
    esac
    # check_prerequisites' PR-existence call: gh pr view NUMBER --repo OWNER/REPO
    [ "${GH_STUB_PR_EXISTS:-1}" = "1" ] && exit 0 || exit 1
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

# ==============================================================
# build_prompt
# ==============================================================

BP_PR_URL="https://github.com/acme/widgets/pull/42"
BP_ISSUE_URL="https://github.com/acme/widgets/issues/7"
BP_DESIGN_DOC="docs/design/foo-design.md"
BP_CLI="codex"
BP_MODEL="gpt-codex-test"
BP_WORKTREE="/fake/worktree/path"
BP_BASE_REF="origin/main"
BP_SCRATCH="/fake/scratch/dir"

prompt="$(build_prompt "$REAL_CONTRACT" "$BP_PR_URL" "$BP_ISSUE_URL" "$BP_DESIGN_DOC" "$BP_CLI" "$BP_MODEL" "$BP_WORKTREE" "$BP_BASE_REF" "$BP_SCRATCH")"
contract_text="$(cat "$REAL_CONTRACT")"

# Contract full text must appear verbatim and unabridged -- checked as an
# exact prefix match against the file's own content, so any rewriting or
# truncation of the contract would fail this.
case "$prompt" in
  "$contract_text"*) pass build-prompt-contract-verbatim ;;
  *) bad build-prompt-contract-verbatim ;;
esac

# Every one of the contract's required inputs must show up somewhere in the
# assembled prompt: PR link, issue link, design doc path, this reviewer's
# own CLI/model identity, the worktree it should read code from, the base
# ref its pinned diff command needs, and a scratch dir outside the worktree.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
printf '%s' "$prompt" | grep -qF "$BP_PR_URL" && pass build-prompt-pr-url || bad build-prompt-pr-url
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
printf '%s' "$prompt" | grep -qF "$BP_ISSUE_URL" && pass build-prompt-issue-url || bad build-prompt-issue-url
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
printf '%s' "$prompt" | grep -qF "$BP_DESIGN_DOC" && pass build-prompt-design-doc || bad build-prompt-design-doc
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
printf '%s' "$prompt" | grep -qF "$BP_CLI" && pass build-prompt-cli-name || bad build-prompt-cli-name
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
printf '%s' "$prompt" | grep -qF "$BP_MODEL" && pass build-prompt-model || bad build-prompt-model
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
printf '%s' "$prompt" | grep -qF "$BP_WORKTREE" && pass build-prompt-worktree-path || bad build-prompt-worktree-path
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
printf '%s' "$prompt" | grep -qF "$BP_BASE_REF" && pass build-prompt-base-ref || bad build-prompt-base-ref
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
printf '%s' "$prompt" | grep -qF "$BP_SCRATCH" && pass build-prompt-scratch-dir || bad build-prompt-scratch-dir

# Each of the three SKILL.md-gathered coordinates (PR link, issue link,
# design doc path) may individually come in as an empty string -- must
# still produce a non-empty, well-formed prompt rather than aborting.
out="$(build_prompt "$REAL_CONTRACT" "" "$BP_ISSUE_URL" "$BP_DESIGN_DOC" "$BP_CLI" "$BP_MODEL" "$BP_WORKTREE" "$BP_BASE_REF" "$BP_SCRATCH")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -n "$out" ] && pass build-prompt-empty-pr-url || bad build-prompt-empty-pr-url

out="$(build_prompt "$REAL_CONTRACT" "$BP_PR_URL" "" "$BP_DESIGN_DOC" "$BP_CLI" "$BP_MODEL" "$BP_WORKTREE" "$BP_BASE_REF" "$BP_SCRATCH")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -n "$out" ] && printf '%s' "$out" | grep -qF '未提供' && pass build-prompt-empty-issue-url || bad build-prompt-empty-issue-url

out="$(build_prompt "$REAL_CONTRACT" "$BP_PR_URL" "$BP_ISSUE_URL" "" "$BP_CLI" "$BP_MODEL" "$BP_WORKTREE" "$BP_BASE_REF" "$BP_SCRATCH")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -n "$out" ] && printf '%s' "$out" | grep -qF '未提供' && pass build-prompt-empty-design-doc || bad build-prompt-empty-design-doc

# ==============================================================
# setup_worktree
#
# Exercises real local git plumbing (never touches actual GitHub): a bare
# repo standing in for the GitHub-hosted origin, with a PR-like
# refs/pull/<N>/head ref pushed to it exactly as GitHub itself exposes one,
# and a separate work clone acting as the caller's cwd. The origin's path
# is placed under a directory literally named acme/widgets so it satisfies
# setup_worktree's own owner/repo sanity check the same way a real
# https://github.com/acme/widgets(.git) origin URL would.
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
  git remote add origin "$GIT_FIXTURE/remotes/acme/widgets.git"
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
  git remote add origin "$CLEANUP_FIXTURE/remotes/acme/widgets.git"
  git push -q origin HEAD:refs/heads/main
  git checkout -q -b feature
  printf 'change\n' >> f.txt
  git commit -aq -m change
  git push -q origin feature:refs/pull/5/head
  git checkout -q main
  # A stale, non-checked-out leftover from a fictitious earlier run.
  git branch pr-review-999-12345 HEAD
)

(cd "$CLEANUP_FIXTURE/work" && setup_worktree acme widgets 5 "$T/setup-worktree-cleanup-check") >/dev/null 2>&1 || true

if git -C "$CLEANUP_FIXTURE/work" show-ref --verify --quiet refs/heads/pr-review-999-12345; then
  bad setup-worktree-cleans-stale-refs
else
  pass setup-worktree-cleans-stale-refs
fi

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
case "$oc_config_content" in
  *'"gh pr comment*": "allow"'*) pass opencode-permission-config-allows-pr-comment ;;
  *) bad opencode-permission-config-allows-pr-comment ;;
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

bp_direct_prompt="$(build_prompt "$REAL_CONTRACT" "https://github.com/acme/widgets/pull/1" "" "" \
  codex "direct-pairing-model-marker" "$LAUNCH_WT" "origin/main" "$LAUNCH_ROOT/scratch")"
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
case "$(cat "$LAUNCH_RECORD_DIR/claude.argv")" in
  *'Bash(gh pr comment:*)'*) pass launch-reviewer-claude-allows-pr-comment ;;
  *) bad launch-reviewer-claude-allows-pr-comment ;;
esac

# Write must be on --allowedTools (needed for the contract's required
# comment-body file -- a real claude binary confirmed it cannot write
# anywhere at all, including its own scratch directory, without this; see
# launch_reviewer's docstring) and must NOT also be on --disallowedTools
# (disallowedTools always wins, so that would silently cancel it back out)
# -- checked as the argument immediately following each flag, not just
# "Write appears somewhere", so this can't be fooled by Write showing up
# in the wrong flag's value.
mapfile -t claude_argv < "$LAUNCH_RECORD_DIR/claude.argv"
write_allowed=0
edit_notebookedit_disallowed=0
write_wrongly_disallowed=0
for idx in "${!claude_argv[@]}"; do
  case "${claude_argv[$idx]}" in
    --allowedTools)
      case "${claude_argv[$((idx + 1))]:-}" in
        *Write*) write_allowed=1 ;;
      esac
      ;;
    --disallowedTools)
      case "${claude_argv[$((idx + 1))]:-}" in
        *Edit*NotebookEdit*) edit_notebookedit_disallowed=1 ;;
      esac
      case "${claude_argv[$((idx + 1))]:-}" in
        *Write*) write_wrongly_disallowed=1 ;;
      esac
      ;;
  esac
done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$write_allowed" -eq 1 ] && pass launch-reviewer-claude-allows-write || bad launch-reviewer-claude-allows-write
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$edit_notebookedit_disallowed" -eq 1 ] && pass launch-reviewer-claude-disallows-edit-notebookedit || bad launch-reviewer-claude-disallows-edit-notebookedit
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$write_wrongly_disallowed" -eq 0 ] && pass launch-reviewer-claude-write-not-also-disallowed || bad launch-reviewer-claude-write-not-also-disallowed

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
(cd "$SV1_ROOT/work" && spawn_supervisor "$SV1_WT" "$SV1_SUMMARY" "$sv1_pid")

i=0
until [ -s "$SV1_SUMMARY" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done

sv1_line="$(cat "$SV1_SUMMARY" 2>/dev/null)"
case "$sv1_line" in
  "pid=$sv1_pid exit=5"*'worktree_status=invalidated') pass spawn-supervisor-records-exit-code-and-invalidation ;;
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
(cd "$SV2_ROOT/work" && spawn_supervisor "$SV2_WT" "$SV2_SUMMARY" "$sv2_pid")

i=0
until [ -s "$SV2_SUMMARY" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done

case "$(cat "$SV2_SUMMARY" 2>/dev/null)" in
  "pid=$sv2_pid exit=0"*'worktree_status=ok') pass spawn-supervisor-ok-when-unmodified ;;
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
(cd "$SV3_ROOT/work" && spawn_supervisor "$SV3_WT" "$SV3_SUMMARY" "$sv3_pid_a" "$sv3_pid_b")

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
  spawn_supervisor "$SV4_WT" "$SV4_SUMMARY" "$sv4_pid"
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
# The most load-bearing test in this section: Task 4's build_prompt takes
# 9 positional parameters, and a caller that transposes two of them (e.g.
# swaps issue_url and design_doc_path, or worktree_path and base_ref)
# produces a syntactically valid but semantically wrong prompt with no
# error anywhere -- set -u only catches a missing argument, never a
# misordered one. Every value below is deliberately distinct from every
# other, and each assertion below checks that value against *its own*
# labeled line in the prompt file main() actually wrote to disk, not just
# that the value appears somewhere in it (which would pass even if two
# labels' values were swapped).
#
# This also exercises run.sh's command-line contract end to end (task 5's
# own addition, not specified by the earlier tasks): three positional
# arguments -- PR link, issue link, design doc path -- invoked exactly as
# a real caller would, via `bash run.sh ...`, not by sourcing and calling
# main() directly (main() calls `exit` on its failure paths, which would
# kill this whole test script if called in-process instead of as a real
# subprocess).
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
  git remote add origin "$E2E_FIXTURE/remotes/acme9pr/widgets9pr.git"
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

if out="$(cd "$E2E_FIXTURE/work" && CLAUDE_CONFIG_DIR="" GH_STUB_BASE_REF_NAME="e2e-distinctive-base" HOME="$E2E_HOME" PATH="$STUB_BIN:$saved_path" \
  bash "$RUN_SH" \
    "https://github.com/acme9pr/widgets9pr/pull/321" \
    "https://example.com/distinctive-issue-marker" \
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
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qxF -- '- issue：https://example.com/distinctive-issue-marker' "$E2E_PROMPT_FILE" 2>/dev/null && pass main-e2e-prompt-issue-url-in-place || bad main-e2e-prompt-issue-url-in-place
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qxF -- '- design document 路徑：docs/distinctive-design-doc-marker.md' "$E2E_PROMPT_FILE" 2>/dev/null && pass main-e2e-prompt-design-doc-in-place || bad main-e2e-prompt-design-doc-in-place
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qxF -- '- 產出這則 review 的 CLI 名稱：codex' "$E2E_PROMPT_FILE" 2>/dev/null && pass main-e2e-prompt-cli-name-in-place || bad main-e2e-prompt-cli-name-in-place
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qxF -- '- 產出這則 review 的 model 名稱：e2e-distinctive-model' "$E2E_PROMPT_FILE" 2>/dev/null && pass main-e2e-prompt-model-in-place || bad main-e2e-prompt-model-in-place
# scratch_dir is per-CLI (a subdirectory named after the reviewer, e.g.
# .../scratch/codex), not the shared top-level scratch_dir -- see main()'s
# own comment on why the three reviewers can't safely share one scratch
# directory for their comment-body files.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qxF -- "- 暫存目錄（worktree 之外，張貼 comment 前把內文寫入此處的檔案）：$E2E_BASE_DIR/scratch/codex" "$E2E_PROMPT_FILE" 2>/dev/null && pass main-e2e-prompt-scratch-dir-in-place || bad main-e2e-prompt-scratch-dir-in-place

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

exit $fail
