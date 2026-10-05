#!/usr/bin/env bash
# Migrate one project's CLAUDE.md, .claude/CLAUDE.md and .claude/rules/*.md into AGENTS.md.
# Shell: bash (4.3+ floor) -- uses [[ ]] and arrays, which POSIX sh lacks.
#
# Usage: migrate-claude-md-to-agents-md.sh <project-dir> [--apply]
#
# Default is dry-run. Never runs any git write command.
# Exit codes: 0 success; 1 one or more directories were CONFLICT;
#             2 usage error or preflight failure (nothing changed).
set -euo pipefail

USAGE='usage: migrate-claude-md-to-agents-md.sh <project-dir> [--apply]'

# die <message>: print a diagnostic to stderr and exit 2 (usage/preflight failure).
die() {
  printf '%s\n' "$1" >&2
  exit 2
}

# ---- 1. argument parsing: exactly one positional plus optional --apply ----
APPLY=0
project_arg=""
have_project=0
# shellcheck disable=SC2034  # APPLY is consumed by apply mode (Task 3), not yet written
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -*) die "$USAGE" ;;
    *)
      [ "$have_project" -eq 0 ] || die "$USAGE"
      project_arg="$arg"
      have_project=1
      ;;
  esac
done
[ "$have_project" -eq 1 ] || die "$USAGE"

# ---- 2. project-dir must be the git repository root ----
[ -d "$project_arg" ] || die "not a git repository root: $project_arg"
PROJECT_DIR="$(realpath "$project_arg")"
toplevel="$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2> /dev/null)" \
  || die "not a git repository root: $PROJECT_DIR"
[ "$(realpath "$toplevel")" = "$PROJECT_DIR" ] \
  || die "not a git repository root: $PROJECT_DIR"

# ---- 3. settings repo guard (covers the main checkout and all its worktrees) ----
# abs_common_dir <dir>: absolute git common dir of <dir>; empty if not a repo.
abs_common_dir() {
  local common
  common="$(git -C "$1" rev-parse --git-common-dir 2> /dev/null)" || return 0
  # --git-common-dir may be relative to <dir>.
  (cd "$1" && realpath "$common")
}
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_common="$(abs_common_dir "$PROJECT_DIR")"
script_common="$(abs_common_dir "$script_dir")"
if [ -n "$script_common" ] && [ "$project_common" = "$script_common" ]; then
  die "refusing to migrate the settings repository: $PROJECT_DIR"
fi

# ---- 4. working tree must be clean (includes untracked files) ----
status="$(git -C "$PROJECT_DIR" status --porcelain)"
[ -z "$status" ] || die "working tree is not clean: $PROJECT_DIR"

# Task 1 stops here: PROJECT_DIR and APPLY are set for later tasks.
printf 'dry-run: no files changed; re-run with --apply to write\n'
exit 0
