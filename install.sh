#!/usr/bin/env bash
# install.sh — Deploy Claude Code customisations from this repo to ~/.claude
#              via symbolic links. Safe to run repeatedly (idempotent).
#
# Target shell: bash — requires arrays, process substitution, and bash-specific
#               string ops that are not available in POSIX sh.
#
# DESTRUCTIVE OPERATIONS: one exception. The script never deletes or overwrites
# any existing file, directory, or symlink outright — conflicts are reported
# and skipped. The sole exception is backup_migrate_link, which renames a
# pre-existing real file to a "<path>.pre-symlink.bak" path before replacing
# it with a symlink, as a one-time migration.

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Paths — derived from the script's own location so the repo can live anywhere
# ---------------------------------------------------------------------------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
CODEX_HOME="${CODEX_HOME:-${HOME}/.codex}"
AGENTS_HOME="${AGENTS_HOME:-${HOME}/.agents}"
EXTERNAL_SKILLS_MANIFEST="${REPO_DIR}/external-skills.txt"

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

# Per-item symlink from an arbitrary source dir into an arbitrary dest dir.
link_items_into() {
  local src_dir="$1" dest_dir="$2"
  [ -d "$src_dir" ] || return 0
  mkdir -p "$dest_dir"
  while IFS= read -r -d '' item_path; do
    local name
    name="$(basename "$item_path")"
    link_one "${dest_dir}/${name}" "$item_path"
  done < <(find "$src_dir" -maxdepth 1 -mindepth 1 -print0 | sort -z)
}

# Symlink every *.md under a commands dir into a flat prompts dir, flattening
# nested paths with a hyphenated prefix:
#   commands/vf/trello-board-sprint-review.md -> vf-trello-board-sprint-review.md
link_commands_flat() {
  local src_dir="$1" dest_dir="$2"
  [ -d "$src_dir" ] || return 0
  mkdir -p "$dest_dir"
  while IFS= read -r -d '' md_path; do
    local rel flat
    rel="${md_path#"$src_dir"/}"
    flat="${rel//\//-}"
    link_one "${dest_dir}/${flat}" "$md_path"
  done < <(find "$src_dir" -type f -name '*.md' -print0 | sort -z)
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

  install_external_skills "claude-code"
}

GEN_BANNER_MD='<!-- GENERATED by install.sh - do not edit. Source: CLAUDE.md + rules/*.md -->'

# Concatenate CLAUDE.md then rules/*.md (alphabetical) into ~/.codex/AGENTS.md.
generate_codex_agents_md() {
  local out="${CODEX_HOME}/AGENTS.md"
  [ -L "$out" ] && rm -f "$out"

  {
    printf '%s\n\n' "$GEN_BANNER_MD"
    cat "${REPO_DIR}/CLAUDE.md"
    while IFS= read -r -d '' rule; do
      printf '\n\n---\n\n'
      cat "$rule"
    done < <(find "${REPO_DIR}/rules" -maxdepth 1 -type f -name '*.md' -print0 | sort -z)
    printf '\n'
  } > "$out"

  printf '  GENERATED %s\n' "$out"

  local size
  size="$(wc -c < "$out")"
  if [ "$size" -gt 32768 ]; then
    printf '  WARNING  %s is %d bytes (> 32 KiB project_doc_max_bytes); Codex will truncate.\n' "$out" "$size"
  fi
}

# Generate one TOML per agents/*.md into ~/.codex/agents, then prune orphaned
# generated TOMLs (only files that carry our generated banner are removed).
generate_codex_subagents() {
  if ! command -v python3 > /dev/null 2>&1; then
    printf '  WARNING  python3 not found - skipping Codex subagent generation.\n'
    return
  fi

  local agents_src="${REPO_DIR}/agents"
  local agents_dst="${CODEX_HOME}/agents"
  local converter="${REPO_DIR}/scripts/md-agent-to-toml.py"
  mkdir -p "$agents_dst"

  local -A wanted=()
  while IFS= read -r -d '' md_path; do
    local base
    base="$(basename "$md_path" .md)"
    wanted["$base"]=1
    local toml_path="${agents_dst}/${base}.toml"
    if python3 "$converter" "$md_path" > "${toml_path}.tmp" 2>/dev/null; then
      if [ -e "$toml_path" ] && ! head -1 "$toml_path" | grep -q 'GENERATED by install.sh'; then
        rm -f "${toml_path}.tmp"
        printf '  WARNING  %s already exists and is hand-authored (no GENERATED banner) - skipping to avoid destroying it.\n' "$toml_path"
      else
        mv "${toml_path}.tmp" "$toml_path"
        printf '  GENERATED %s\n' "$toml_path"
      fi
    else
      rm -f "${toml_path}.tmp"
      printf '  WARNING  failed to convert %s - skipping.\n' "$md_path"
    fi
  done < <(find "$agents_src" -maxdepth 1 -type f -name '*.md' -print0 | sort -z)

  while IFS= read -r -d '' toml_path; do
    local base
    base="$(basename "$toml_path" .toml)"
    if [ -z "${wanted[$base]:-}" ] && head -1 "$toml_path" | grep -q 'GENERATED by install.sh'; then
      rm -f "$toml_path"
      printf '  PRUNED   %s (no repo source)\n' "$toml_path"
    fi
  done < <(find "$agents_dst" -maxdepth 1 -type f -name '*.toml' -print0 | sort -z)
}

deploy_codex() {
  printf 'Deploying to Codex\n  target: %s\n\n' "$CODEX_HOME"
  mkdir -p "$CODEX_HOME" "${CODEX_HOME}/agents" "${CODEX_HOME}/prompts" "${AGENTS_HOME}/skills"

  link_items_into "${REPO_DIR}/skills" "${AGENTS_HOME}/skills"
  link_commands_flat "${REPO_DIR}/commands" "${CODEX_HOME}/prompts"
  backup_migrate_link "${CODEX_HOME}/config.toml" "${REPO_DIR}/platforms/codex/config.toml"

  generate_codex_agents_md
  generate_codex_subagents

  if [ -L "${CODEX_HOME}/agents.md" ]; then
    rm -f "${CODEX_HOME}/agents.md"
    printf '  REMOVED  %s (legacy lowercase symlink)\n' "${CODEX_HOME}/agents.md"
  fi

  install_external_skills "codex"
}

# ---------------------------------------------------------------------------
# External skills (open agent skills ecosystem) — installed via the `skills`
# CLI (run through npx), scoped to one agent identifier so each entry lands
# in that platform's own global skills directory (e.g. claude-code installs
# to ~/.claude/skills, codex installs to ~/.codex/skills). Manifest lines are
# read from EXTERNAL_SKILLS_MANIFEST; blank lines and lines starting with #
# are ignored. Every install attempt is independent: one bad or unreachable
# entry is reported and skipped, it never aborts the rest of the deploy.
#   $1 = skills CLI agent identifier (e.g. "claude-code", "codex")
# ---------------------------------------------------------------------------
install_external_skills() {
  local agent_id="$1"

  [ -n "$skip_external" ] && return

  if [ ! -f "$EXTERNAL_SKILLS_MANIFEST" ]; then
    printf '  SKIP     %s not found — no external skills to install for %s\n' \
      "$EXTERNAL_SKILLS_MANIFEST" "$agent_id"
    return
  fi

  if ! command -v npx > /dev/null 2>&1; then
    printf '  WARNING  npx not found - skipping external skills install for %s.\n' "$agent_id"
    return
  fi

  local entry
  while IFS= read -r entry || [ -n "$entry" ]; do
    # Trim leading/trailing whitespace so a whitespace-only line counts as blank
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    case "$entry" in
      ''|'#'*) continue ;;
    esac

    # `skills add` is idempotent (a no-op if already installed), so any exit-0
    # run is counted as handled; we cannot cheaply tell "new" from "already
    # present" apart from the CLI's own interactive-style output.
    if npx --yes skills add "$entry" -g -a "$agent_id" -y; then
      printf '  INSTALLED %s (%s)\n' "$entry" "$agent_id"
      count_created=$(( count_created + 1 ))
    else
      printf '  WARNING  failed to install %s for %s - skipping.\n' "$entry" "$agent_id"
      count_skipped=$(( count_skipped + 1 ))
    fi
  done < "$EXTERNAL_SKILLS_MANIFEST"
}

# ---------------------------------------------------------------------------
# OpenSpec CLI (Fission-AI) — a plain npm-global tool, not part of the skills
# ecosystem, so it is installed with `npm install -g` rather than `skills`.
# Idempotent: skipped entirely if the `openspec` binary is already on PATH.
# ---------------------------------------------------------------------------
install_openspec() {
  [ -n "$skip_external" ] && return

  if command -v openspec > /dev/null 2>&1; then
    printf '  OK       openspec already installed — skipping\n'
    count_ok=$(( count_ok + 1 ))
    return
  fi

  if ! command -v npm > /dev/null 2>&1; then
    printf '  WARNING  npm not found - skipping openspec install.\n'
    return
  fi

  if npm install --global @fission-ai/openspec; then
    printf '  INSTALLED @fission-ai/openspec (openspec)\n'
    count_created=$(( count_created + 1 ))
  else
    printf '  WARNING  failed to install @fission-ai/openspec - skipping.\n'
    count_skipped=$(( count_skipped + 1 ))
  fi
}

# ---------------------------------------------------------------------------
# Platform selection: flags win; otherwise ask interactively (reads /dev/tty
# so it still works when stdin is piped).
# ---------------------------------------------------------------------------
want_claude=""
want_codex=""
skip_external=""

for arg in "$@"; do
  case "$arg" in
    --claude) want_claude=1 ;;
    --codex)  want_codex=1 ;;
    --all)    want_claude=1; want_codex=1 ;;
    --no-external) skip_external=1 ;;
    -h|--help) printf 'Usage: install.sh [--claude] [--codex] [--all] [--no-external]\n'; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

if [ -z "$want_claude" ] && [ -z "$want_codex" ]; then
  if ! { : > /dev/tty; } 2>/dev/null; then
    printf 'Error: no controlling terminal available for interactive prompts.\n' >&2
    printf 'Re-run with an explicit platform flag: --claude, --codex, or --all.\n' >&2
    exit 2
  fi

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
[ -n "$want_codex" ] && deploy_codex

# OpenSpec is a plain dev CLI tool with no per-platform install target, so it
# runs once regardless of which platform(s) were selected above.
install_openspec

printf '\n=== Summary ===\n'
printf '  created:  %d\n' "$count_created"
printf '  ok:       %d\n' "$count_ok"
printf '  skipped:  %d\n' "$count_skipped"
