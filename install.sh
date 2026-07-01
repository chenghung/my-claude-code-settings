#!/usr/bin/env bash
# install.sh — Deploy Claude Code customisations from this repo to ~/.claude
#              via symbolic links. Safe to run repeatedly (idempotent).
#
# Target shell: bash — requires arrays, process substitution, and bash-specific
#               string ops that are not available in POSIX sh.
#
# DESTRUCTIVE OPERATIONS: none. The script never deletes or overwrites any
# existing file, directory, or symlink. Conflicts are reported and skipped.

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Paths — derived from the script's own location so the repo can live anywhere
# ---------------------------------------------------------------------------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
CODEX_HOME="${CODEX_HOME:-${HOME}/.codex}"
AGENTS_HOME="${AGENTS_HOME:-${HOME}/.agents}"

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
count_created=0
count_ok=0
count_skipped=0

# ---------------------------------------------------------------------------
# Helper: create one symlink, enforcing idempotency and non-destructiveness.
#   $1 = absolute path of the link to create
#   $2 = absolute path the link should point to
# ---------------------------------------------------------------------------
link_one() {
  local link_path="$1"
  local target_path="$2"

  if [ -L "$link_path" ]; then
    # Resolve the existing link destination (readlink is POSIX-safe here)
    local existing_target
    existing_target="$(readlink "$link_path")"
    if [ "$existing_target" = "$target_path" ]; then
      printf '  OK       %s\n' "$link_path"
      count_ok=$(( count_ok + 1 ))
    else
      printf '  CONFLICT %s\n           already links to: %s\n           expected:          %s — skipping\n' \
        "$link_path" "$existing_target" "$target_path"
      count_skipped=$(( count_skipped + 1 ))
    fi
  elif [ -e "$link_path" ]; then
    # A real file or directory occupies this path — never touch it
    local kind="file"
    [ -d "$link_path" ] && kind="directory"
    printf '  CONFLICT %s\n           exists as a real %s (not a symlink) — skipping\n' \
      "$link_path" "$kind"
    count_skipped=$(( count_skipped + 1 ))
  else
    ln -s "$target_path" "$link_path"
    printf '  CREATED  %s -> %s\n' "$link_path" "$target_path"
    count_created=$(( count_created + 1 ))
  fi
}

# ---------------------------------------------------------------------------
# Mode A — whole-directory symlink
#   $1 = category name (e.g. "agents")
# ---------------------------------------------------------------------------
link_directory() {
  local category="$1"
  local repo_dir_path="${REPO_DIR}/${category}"
  local link_path="${CLAUDE_CONFIG_DIR}/${category}"

  # Only link directories that actually exist in the repo
  if [ ! -d "$repo_dir_path" ]; then
    printf '  SKIP     %s not found in repo — skipping\n' "$repo_dir_path"
    count_skipped=$(( count_skipped + 1 ))
    return
  fi

  link_one "$link_path" "$repo_dir_path"
}

# ---------------------------------------------------------------------------
# Mode B — per-item symlinks inside a mixed directory
#   $1 = category name (e.g. "skills")
# ---------------------------------------------------------------------------
link_items() {
  local category="$1"
  local repo_cat_dir="${REPO_DIR}/${category}"
  local claude_cat_dir="${CLAUDE_CONFIG_DIR}/${category}"

  if [ ! -d "$repo_cat_dir" ]; then
    printf '  SKIP     %s not found in repo — nothing to link\n' "$repo_cat_dir"
    return
  fi

  # Ensure the target category directory exists (create if absent)
  if [ ! -d "$claude_cat_dir" ]; then
    mkdir -p "$claude_cat_dir"
    printf '  MKDIR    %s\n' "$claude_cat_dir"
  fi

  # Iterate over every direct child of the repo category directory
  # Using find -maxdepth 1 with -print0 to handle any filename safely
  while IFS= read -r -d '' item_path; do
    local item_name
    item_name="$(basename "$item_path")"
    local link_path="${claude_cat_dir}/${item_name}"
    link_one "$link_path" "$item_path"
  done < <(find "$repo_cat_dir" -maxdepth 1 -mindepth 1 -print0 | sort -z)
}

# ---------------------------------------------------------------------------
# Whole-file symlink with one-time backup migration.
#   $1 = link path (where the symlink should live)
#   $2 = repo source the link points to
# If the link path is already the correct symlink, defer to link_one. If it is
# a real (non-symlink) file, back it up to <path>.pre-symlink.bak first, then
# replace it with the symlink and tell the user it is now symlink-managed.
# ---------------------------------------------------------------------------
backup_migrate_link() {
  local link_path="$1"
  local target_path="$2"

  if [ -L "$link_path" ]; then
    link_one "$link_path" "$target_path"
    return
  fi

  if [ -e "$link_path" ]; then
    local backup="${link_path}.pre-symlink.bak"
    [ -e "$backup" ] && backup="${backup}.$(date +%s)"
    mv "$link_path" "$backup"
    ln -s "$target_path" "$link_path"
    printf '  MIGRATED %s\n           backed up existing file to: %s\n           this file is now symlink-managed by install.sh\n' \
      "$link_path" "$backup"
    count_created=$(( count_created + 1 ))
    return
  fi

  ln -s "$target_path" "$link_path"
  printf '  CREATED  %s -> %s\n' "$link_path" "$target_path"
  count_created=$(( count_created + 1 ))
}

deploy_claude() {
  printf 'Deploying to Claude Code\n  target: %s\n\n' "$CLAUDE_CONFIG_DIR"
  [ -d "$CLAUDE_CONFIG_DIR" ] || mkdir -p "$CLAUDE_CONFIG_DIR"

  for category in agents rules hooks; do
    link_directory "$category"
  done

  for category in skills commands; do
    link_items "$category"
  done

  link_one "${CLAUDE_CONFIG_DIR}/CLAUDE.md" "${REPO_DIR}/CLAUDE.md"
  backup_migrate_link "${CLAUDE_CONFIG_DIR}/settings.json" "${REPO_DIR}/platforms/claude/settings.json"
}

# ---------------------------------------------------------------------------
# Platform selection: flags win; otherwise ask interactively (reads /dev/tty
# so it still works when stdin is piped).
# ---------------------------------------------------------------------------
want_claude=""
want_codex=""

for arg in "$@"; do
  case "$arg" in
    --claude) want_claude=1 ;;
    --codex)  want_codex=1 ;;
    --all)    want_claude=1; want_codex=1 ;;
    -h|--help) printf 'Usage: install.sh [--claude] [--codex] [--all]\n'; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

if [ -z "$want_claude" ] && [ -z "$want_codex" ]; then
  ask_yn() {
    local reply
    printf '%s [Y/n] ' "$1" > /dev/tty
    read -r reply < /dev/tty || reply=""
    case "$reply" in [nN]*) return 1 ;; *) return 0 ;; esac
  }
  ask_yn "Install for Claude Code?" && want_claude=1
  ask_yn "Install for Codex?" && want_codex=1
fi

if [ -z "$want_claude" ] && [ -z "$want_codex" ]; then
  printf 'No platform selected - nothing to do.\n'
  exit 0
fi

[ -n "$want_claude" ] && deploy_claude

printf '\n=== Summary ===\n'
printf '  created:  %d\n' "$count_created"
printf '  ok:       %d\n' "$count_ok"
printf '  skipped:  %d\n' "$count_skipped"
