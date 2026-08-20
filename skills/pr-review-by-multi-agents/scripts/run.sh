#!/usr/bin/env bash
# Orchestrates parallel PR code review by claude, codex, and opencode CLIs.
#
# This script is built up across several tasks. This task (input parsing and
# preflight checks) only defines the functions that decide whether to run at
# all and how many reviewer CLIs are available. Worktree creation, prompt
# assembly, and process launch/supervision are added by later tasks further
# down this same file.
set -euo pipefail
IFS=$'\n\t'

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

# ---------------------------------------------------------------------------
# Later tasks add the rest of the pipeline here: worktree creation, prompt
# assembly, and reviewer process launch/supervision.
# ---------------------------------------------------------------------------
