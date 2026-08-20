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

# Symlink case: mirrors how install.sh actually deploys this skill (the
# whole skill directory symlinked under ~/.claude/skills or ~/.agents/skills).
# readlink must resolve through that symlink to the real references/ dir.
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

# --- claude: ~/.claude/settings.json, .model ---

HOME_CC_OK="$T/home-claude-ok"
mkdir -p "$HOME_CC_OK/.claude"
printf '{"model": "sonnet-test"}' > "$HOME_CC_OK/.claude/settings.json"
out="$(HOME="$HOME_CC_OK" resolve_model claude)"
rc=$?
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$rc" -eq 0 ] && [ "$out" = "sonnet-test" ] && pass resolve-model-claude-found || bad resolve-model-claude-found

HOME_CC_NOFILE="$T/home-claude-nofile"
mkdir -p "$HOME_CC_NOFILE"
out="$(HOME="$HOME_CC_NOFILE" resolve_model claude)"
rc=$?
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$rc" -eq 0 ] && [ "$out" = "unknown-model" ] && pass resolve-model-claude-missing-file || bad resolve-model-claude-missing-file

HOME_CC_NOFIELD="$T/home-claude-nofield"
mkdir -p "$HOME_CC_NOFIELD/.claude"
printf '{"other": true}' > "$HOME_CC_NOFIELD/.claude/settings.json"
out="$(HOME="$HOME_CC_NOFIELD" resolve_model claude)"
rc=$?
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$rc" -eq 0 ] && [ "$out" = "unknown-model" ] && pass resolve-model-claude-missing-field || bad resolve-model-claude-missing-field

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

exit $fail
