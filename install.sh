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

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
count_created=0
count_ok=0
count_skipped=0

# settings.json merge outcome (populated later)
settings_result="not attempted"

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
# settings.json — merge notification hooks incrementally
# ---------------------------------------------------------------------------
merge_settings() {
  local settings_file="${CLAUDE_CONFIG_DIR}/settings.json"

  # Require jq; warn and skip gracefully if absent
  if ! command -v jq > /dev/null 2>&1; then
    printf '\nWARNING: jq not found — skipping settings.json hook merge.\n'
    settings_result="skipped (jq not available)"
    return
  fi

  # Bootstrap an empty JSON object when the file does not exist yet
  if [ ! -f "$settings_file" ]; then
    printf '{}' > "$settings_file"
    printf '  CREATED  %s (empty JSON object)\n' "$settings_file"
  fi

  # Validate the file is parseable JSON before touching it
  if ! jq empty "$settings_file" 2>/dev/null; then
    printf '\nWARNING: %s is not valid JSON — skipping hook merge.\n' "$settings_file"
    settings_result="skipped (invalid JSON)"
    return
  fi

  # shellcheck disable=SC2016  # intentional literal string: $HOME must NOT expand here;
  #   Claude Code expands it at hook-execution time, not at install time.
  local stop_cmd='$HOME/.claude/hooks/notify-cc.sh done'
  # shellcheck disable=SC2016  # same rationale as above
  local notif_cmd='$HOME/.claude/hooks/notify-cc.sh notify'

  # Check whether each hook is already present
  local has_stop has_notif
  # jq exits 0 even when the path is null, so test the actual string value
  has_stop="$(jq --arg cmd "$stop_cmd" \
    '[.hooks.Stop[]?.hooks[]? | select(.type=="command" and .command==$cmd)] | length' \
    "$settings_file" 2>/dev/null || printf '0')"
  has_notif="$(jq --arg cmd "$notif_cmd" \
    '[.hooks.Notification[]?.hooks[]? | select(.type=="command" and .command==$cmd)] | length' \
    "$settings_file" 2>/dev/null || printf '0')"

  local stop_status notif_status
  stop_status="already present"
  notif_status="already present"

  # Build the jq filter incrementally — only append missing hooks
  local jq_filter='.'

  if [ "$has_stop" -eq 0 ]; then
    # Append a new Stop hook entry; preserve any existing Stop entries
    jq_filter="${jq_filter}"' | .hooks.Stop = ((.hooks.Stop // []) + [{"hooks":[{"type":"command","command":"'"$stop_cmd"'"}]}])'
    stop_status="added"
  fi

  if [ "$has_notif" -eq 0 ]; then
    jq_filter="${jq_filter}"' | .hooks.Notification = ((.hooks.Notification // []) + [{"hooks":[{"type":"command","command":"'"$notif_cmd"'"}]}])'
    notif_status="added"
  fi

  # If nothing needs to change, skip the write entirely
  if [ "$has_stop" -gt 0 ] && [ "$has_notif" -gt 0 ]; then
    settings_result="Stop hook: already present | Notification hook: already present"
    return
  fi

  # Write atomically: jq to a temp file, then mv (same filesystem — atomic rename)
  local tmp_file
  tmp_file="$(mktemp "${settings_file}.tmp.XXXXXX")"
  # shellcheck disable=SC2064  # we want $tmp_file expanded now, not at trap time
  trap "rm -f '$tmp_file'" EXIT INT TERM

  if jq "$jq_filter" "$settings_file" > "$tmp_file" 2>/dev/null; then
    mv "$tmp_file" "$settings_file"
    settings_result="Stop hook: ${stop_status} | Notification hook: ${notif_status}"
  else
    rm -f "$tmp_file"
    printf '\nWARNING: jq transformation failed — settings.json was not modified.\n'
    settings_result="skipped (jq transform error)"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
printf 'Deploying Claude Code customisations\n'
printf '  repo:   %s\n' "$REPO_DIR"
printf '  target: %s\n\n' "$CLAUDE_CONFIG_DIR"

# Ensure the Claude config directory exists
if [ ! -d "$CLAUDE_CONFIG_DIR" ]; then
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf 'MKDIR %s\n\n' "$CLAUDE_CONFIG_DIR"
fi

# --- Mode A: whole-directory symlinks ---
printf '[Mode A] Directory-level symlinks\n'
for category in agents rules hooks; do
  printf ' %s:\n' "$category"
  link_directory "$category"
done

printf '\n'

# --- Mode B: per-item symlinks ---
printf '[Mode B] Per-item symlinks\n'
for category in skills commands; do
  printf ' %s:\n' "$category"
  link_items "$category"
done

printf '\n'

# --- settings.json hook merge ---
printf '[settings.json] Notification hook merge\n'
merge_settings
printf '  result: %s\n\n' "$settings_result"

# --- Summary ---
printf '=== Summary ===\n'
printf '  created:  %d\n' "$count_created"
printf '  ok:       %d\n' "$count_ok"
printf '  skipped:  %d\n' "$count_skipped"
printf '  settings: %s\n' "$settings_result"
