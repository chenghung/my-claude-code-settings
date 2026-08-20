#!/usr/bin/env bash
# Orchestrates parallel PR code review by claude, codex, and opencode CLIs.
#
# This script is built up across several tasks. So far it defines: whether to
# run at all and how many reviewer CLIs are available (input parsing and
# preflight checks); and the code workspace and full prompt each reviewer CLI
# needs (worktree setup and prompt assembly). Process launch and supervision
# are added by a later task further down this same file.
set -euo pipefail

# IFS is intentionally left at its bash default here. Nothing in this file
# currently iterates over multi-line/multi-word command output, and this
# file is `source`d directly into tests/test-pr-review-by-multi-agents.sh's
# own shell process -- a global IFS override here would silently leak into
# that test script (and into whatever later tasks append below). When a
# future addition actually needs to split on newlines, scope it locally
# instead of overriding IFS at file scope, e.g. `while IFS= read -r line;
# do ...; done < <(cmd)` or `local IFS=$'\n\t'` inside just that function.

# parse_pr_url <input>
#
# Accepts a full PR URL (https://github.com/<owner>/<repo>/pull/<N>), the
# shorthand "<owner>/<repo>#<N>", or an empty string. An empty string derives
# the PR from the current branch via `gh pr view`, then falls through to the
# same URL parser used for the explicit-URL case.
#
# On success, prints "<owner> <repo> <number>" to stdout and returns 0.
# On any parse failure, returns non-zero and prints nothing to stdout.
parse_pr_url() {
  local input="${1:-}"
  local owner repo number

  if [ -z "$input" ]; then
    # No input given: ask gh for the URL of the PR belonging to the current
    # branch, then parse that URL below like any other explicit input.
    input="$(gh pr view --json url --jq .url 2>/dev/null)" || return 1
    [ -n "$input" ] || return 1
  fi

  if [[ "$input" =~ ^https://github\.com/([^/[:space:]]+)/([^/[:space:]]+)/pull/([0-9]+)([/?#].*)?$ ]]; then
    owner="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
    number="${BASH_REMATCH[3]}"
  elif [[ "$input" =~ ^([^/[:space:]]+)/([^/#[:space:]]+)#([0-9]+)$ ]]; then
    owner="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
    number="${BASH_REMATCH[3]}"
  else
    return 1
  fi

  printf '%s %s %s\n' "$owner" "$repo" "$number"
}

# check_prerequisites <owner> <repo> <number>
#
# Verifies gh is installed, gh is authenticated, and the target PR exists.
# Returns 0 when all three hold. On the first failure, prints the reason to
# stderr and returns non-zero.
check_prerequisites() {
  local owner="$1" repo="$2" number="$3"

  if ! command -v gh >/dev/null 2>&1; then
    printf 'check_prerequisites: gh CLI not found in PATH\n' >&2
    return 1
  fi

  if ! gh auth status >/dev/null 2>&1; then
    printf 'check_prerequisites: gh is not authenticated (run: gh auth login)\n' >&2
    return 1
  fi

  if ! gh pr view "$number" --repo "$owner/$repo" >/dev/null 2>&1; then
    printf 'check_prerequisites: PR %s/%s#%s not found\n' "$owner" "$repo" "$number" >&2
    return 1
  fi

  return 0
}

# detect_reviewers
#
# Prints the installed reviewer CLI names to stdout, one per line, in the
# fixed order claude, codex, opencode. A CLI that is not on PATH is silently
# skipped (graceful degradation) rather than treated as an error. Returns
# non-zero only when none of the three are installed.
detect_reviewers() {
  local cli found=0

  for cli in claude codex opencode; do
    if command -v "$cli" >/dev/null 2>&1; then
      printf '%s\n' "$cli"
      found=1
    fi
  done

  [ "$found" -eq 1 ] || return 1
}

# resolve_contract_path
#
# Locates references/reviewer-contract.md relative to this script's own
# file, resolving any symlinks the skill was installed through (e.g.
# install.sh deploys the whole skill directory as a single symlink under
# ~/.claude/skills or ~/.agents/skills). Prints the absolute contract path
# to stdout on success. A missing contract file is a hard failure -- it
# means this run has no review standard to hand any reviewer -- so this
# returns non-zero and prints nothing rather than falling back to anything.
resolve_contract_path() {
  local script_path script_dir skill_root contract_path

  script_path="$(readlink -f "${BASH_SOURCE[0]}")" || return 1
  script_dir="$(cd "$(dirname "$script_path")" && pwd)" || return 1
  skill_root="$(cd "$script_dir/.." && pwd)" || return 1
  contract_path="$skill_root/references/reviewer-contract.md"

  if [ ! -f "$contract_path" ]; then
    printf 'resolve_contract_path: contract file not found at %s\n' "$contract_path" >&2
    return 1
  fi

  printf '%s\n' "$contract_path"
}

# _origin_matches_owner_repo <origin_url> <owner> <repo>
#
# True (exit 0) when origin_url is a github-style HTTPS or SSH remote URL
# for exactly <owner>/<repo>, with or without a trailing .git. Requires an
# explicit / or : boundary immediately before <owner> -- a bare `*` prefix
# is not enough, because e.g. an owner of "acme" would then also match a
# same-suffixed but different owner like "not-acme" (.../not-acme/widgets.git
# ends with "acme/widgets.git" too). owner/repo are quoted inside the case
# pattern, so any glob metacharacters that happened to be in their values
# are matched literally rather than interpreted as wildcards.
_origin_matches_owner_repo() {
  local origin_url="$1" owner="$2" repo="$3"

  case "$origin_url" in
    */"$owner/$repo" | */"$owner/$repo".git | *:"$owner/$repo" | *:"$owner/$repo".git) return 0 ;;
    *) return 1 ;;
  esac
}

# setup_worktree <owner> <repo> <number> <base_dir>
#
# Prunes stale worktree registrations, then checks the PR's head commit out
# into a new worktree at <base_dir>/worktree, leaving the caller's current
# branch and working tree untouched. Prints the worktree's absolute path to
# stdout on success. Returns non-zero, printing nothing, on any failure --
# spec section 6 treats a worktree that didn't actually get created as a
# hard-stop precondition, same tier as gh being missing.
setup_worktree() {
  local owner="$1" repo="$2" number="$3" base_dir="$4"
  local origin_url worktree_path pr_ref stale_ref

  # Fail fast if the cwd's origin doesn't actually point at this PR's own
  # repo, rather than silently fetching/reviewing the wrong codebase.
  origin_url="$(git remote get-url origin 2>/dev/null)" || return 1
  if ! _origin_matches_owner_repo "$origin_url" "$owner" "$repo"; then
    printf 'setup_worktree: origin remote (%s) does not match %s/%s\n' "$origin_url" "$owner" "$repo" >&2
    return 1
  fi

  git worktree prune >/dev/null 2>&1 || true

  # Best-effort cleanup of this function's own local refs left behind by
  # earlier runs whose worktree has since been removed -- otherwise every
  # run adds one more branch that never goes away. git refuses to delete a
  # branch that is still checked out in a live worktree, so this only ever
  # removes ones that are genuinely stale.
  while IFS= read -r stale_ref; do
    git branch -D "$stale_ref" >/dev/null 2>&1 || true
  done < <(git for-each-ref --format='%(refname:short)' 'refs/heads/pr-review-*' 2>/dev/null)

  worktree_path="$base_dir/worktree"
  # $$ keeps this local ref name unique across concurrent runs that happen
  # to target the same PR number.
  pr_ref="pr-review-$number-$$"

  # The leading + force-updates the local ref even when it isn't a
  # fast-forward. Without it, a PID reused from an earlier run whose
  # same-named ref was left pointing somewhere unrelated would make this
  # fetch fail for a reason that has nothing to do with the current PR.
  #
  # GitHub always exposes this pull-ref on the base repo, regardless of
  # whether the PR's source branch lives there or in a fork.
  git fetch origin "+pull/$number/head:$pr_ref" >/dev/null 2>&1 || return 1
  git worktree add "$worktree_path" "$pr_ref" >/dev/null 2>&1 || return 1

  printf '%s\n' "$worktree_path"
}

# resolve_model <cli_name>
#
# Reads the given reviewer CLI's own config file for its default model and
# prints the model name to stdout. Sources: codex reads the top-level
# `model` key from ~/.codex/config.toml (a `model =` line living under a
# later [profile] table is a different model, not the default one, so
# parsing stops at the first section header); opencode reads .model from
# ~/.config/opencode/opencode.json; claude reads .model from
# ~/.claude/settings.json. Failing to resolve a value -- missing config
# file, missing field, malformed content (invalid JSON, or a value of the
# wrong type), or jq unavailable for the JSON sources -- is not an error:
# it prints the fixed "unknown-model" marker and still returns 0, because
# an honestly-reported unknown is exactly what the reviewer contract's
# disclosure section needs, not a reason to abort.
#
# Every value-producing command below is guarded with `|| value=""`. Under
# set -euo pipefail, a bare `value="$(cmd)"` whose cmd fails (jq on
# malformed JSON, or a pipeline killed by SIGPIPE) does NOT reliably abort
# just this function -- whether it aborts the whole calling shell depends
# on how the caller happens to invoke resolve_model (a plain call or output
# redirection propagates the failure via errexit; wrapping the call in
# $(...) happens to mask it, since bash disables errexit inside command
# substitutions by default). This function's contract is "never abort,
# always degrade to unknown-model", so it does not rely on the caller
# invoking it in one particular way to get that behavior.
resolve_model() {
  local cli="$1" unknown="unknown-model"
  local config_file value=""

  case "$cli" in
    codex)
      config_file="$HOME/.codex/config.toml"
      if [ -f "$config_file" ]; then
        # Quits right after the first match instead of piping through
        # `head -n1`: a separate `head` closing its read end early, while
        # sed is still writing further lines, can deliver SIGPIPE to sed
        # and (under pipefail) fail this whole assignment -- which happens
        # for real once a config has two or more top-level `model =` lines
        # before any [section] header. Matching and quitting inside the
        # same sed invocation removes the second process, and therefore
        # the race, entirely.
        value="$(sed -n '/^\[/q; /^[[:space:]]*model[[:space:]]*=/{s/^[[:space:]]*model[[:space:]]*=[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p;q}' "$config_file")" || value=""
      fi
      ;;
    opencode)
      config_file="$HOME/.config/opencode/opencode.json"
      if [ -f "$config_file" ] && command -v jq >/dev/null 2>&1; then
        value="$(jq -r '.model // empty' "$config_file" 2>/dev/null)" || value=""
      fi
      ;;
    claude)
      config_file="$HOME/.claude/settings.json"
      if [ -f "$config_file" ] && command -v jq >/dev/null 2>&1; then
        value="$(jq -r '.model // empty' "$config_file" 2>/dev/null)" || value=""
      fi
      ;;
    *)
      ;;
  esac

  printf '%s\n' "${value:-$unknown}"
}

# build_prompt <contract_path> <pr_url> <issue_url> <design_doc_path> \
#              <cli_name> <model> <worktree_path> <base_ref> <scratch_dir>
#
# Prints the complete prompt for one reviewer CLI to stdout: the reviewer
# contract's full text, verbatim and unabridged, followed by this run's
# coordinates -- the PR and issue links, the design doc path, this
# worktree's absolute path, the base ref the contract's pinned diff command
# needs, this reviewer's own CLI/model identity, and a scratch directory
# outside the worktree for the comment-body file the contract requires.
# issue_url and design_doc_path may be empty strings; the contract's own
# input-list section requires an explicit "not provided" statement rather
# than a blank field for those two, so an empty value is rendered as such
# here instead of being left out.
build_prompt() {
  local contract_path="$1" pr_url="$2" issue_url="$3" design_doc_path="$4"
  local cli_name="$5" model="$6" worktree_path="$7" base_ref="$8" scratch_dir="$9"
  local contract issue_display design_display

  contract="$(cat "$contract_path")" || return 1

  issue_display="${issue_url:-（未提供，明確視為不存在）}"
  design_display="${design_doc_path:-（未提供，明確視為不存在）}"

  # Printed via a sequence of printf calls rather than interpolated into a
  # heredoc: the contract is external content that a separate task keeps
  # revising, and a heredoc here would make correctness depend on none of
  # its lines ever colliding with the terminator. printf's %s never
  # rescans its argument for shell syntax or a delimiter, so this stays
  # correct regardless of what that content contains. (Each coordinate
  # line's format string starts with "- ", which the plain bash builtin
  # would otherwise try to parse as an option; `--` stops that.)
  printf '%s\n' "$contract"
  printf '\n## 本次審查的座標資訊\n\n'
  printf -- '- PR：%s\n' "$pr_url"
  printf -- '- git worktree 絕對路徑：%s\n' "$worktree_path"
  printf -- '- base ref：%s\n' "$base_ref"
  printf -- '- issue：%s\n' "$issue_display"
  printf -- '- design document 路徑：%s\n' "$design_display"
  printf -- '- 產出這則 review 的 CLI 名稱：%s\n' "$cli_name"
  printf -- '- 產出這則 review 的 model 名稱：%s\n' "$model"
  printf -- '- 暫存目錄（worktree 之外，張貼 comment 前把內文寫入此處的檔案）：%s\n' "$scratch_dir"
}

# ---------------------------------------------------------------------------
# A later task adds the rest of the pipeline here: reviewer process launch
# and supervision.
# ---------------------------------------------------------------------------
