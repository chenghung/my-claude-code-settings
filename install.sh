#!/usr/bin/env bash
# install.sh — Deploy Claude Code customisations from this repo to ~/.claude
#              via symbolic links. Safe to run repeatedly (idempotent).
#
# Target shell: bash — requires arrays, process substitution, and bash-specific
#               string ops that are not available in POSIX sh.
#
# DESTRUCTIVE OPERATIONS: two exceptions. The script never deletes or
# overwrites any existing file, directory, or symlink outright — conflicts
# are reported and skipped. The exceptions are:
#   - backup_migrate_link: renames a pre-existing real file to a
#     "<path>.pre-symlink.bak" path before replacing it with a symlink, as a
#     one-time migration. Used for CLAUDE.md, settings.json, and
#     opencode.json — all three are repo-owned files, so there is no
#     hand-written version that should ever win over the repo's.
#   - seed_managed_file: when called with its force flag set (only from
#     --force-config), backs up a pre-existing Codex-owned real file to a
#     "<path>.pre-force-config.bak" path before overwriting it with a fresh
#     copy of the repo template.

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Paths — derived from the script's own location so the repo can live anywhere
# ---------------------------------------------------------------------------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
CLAUDE_PERSONAL_CONFIG_DIR="${CLAUDE_PERSONAL_CONFIG_DIR:-${HOME}/.claude-personal}"
CODEX_HOME="${CODEX_HOME:-${HOME}/.codex}"
AGENTS_HOME="${AGENTS_HOME:-${HOME}/.agents}"
OPENCODE_CONFIG_DIR="${OPENCODE_CONFIG_DIR:-${HOME}/.config/opencode}"
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

# ---------------------------------------------------------------------------
# One-time seed of a platform-owned real file from a repo template — for
# config files that the platform itself rewrites at runtime (e.g. Codex
# writes plugin/marketplace snapshot fields and TUI state back into
# config.toml). Symlinking such a file into the repo would let the platform's
# runtime writes corrupt the version-controlled template, so this always
# leaves a real, standalone file at $link_path.
#   $1 = target path (the platform-owned real file)
#   $2 = repo template path to seed it from
#   $3 = force flag (non-empty = overwrite an existing real file)
# Semantics:
#   - missing             -> copy from template (created)
#   - existing symlink    -> one-time migration: remove the symlink, copy the
#                            template in as a real file (created)
#   - existing real file  -> left untouched unless force is set, in which
#                            case it is backed up (same backup scheme as
#                            backup_migrate_link) then overwritten
# ---------------------------------------------------------------------------
seed_managed_file() {
  local link_path="$1"
  local template_path="$2"
  local force="${3:-}"

  if [ -L "$link_path" ]; then
    rm -f "$link_path"
    cp "$template_path" "$link_path"
    printf '  MIGRATED %s\n           was a repo symlink; now seeded as a real file owned by the platform\n' "$link_path"
    count_created=$(( count_created + 1 ))
    return
  fi

  if [ -e "$link_path" ]; then
    if [ -n "$force" ]; then
      local backup="${link_path}.pre-force-config.bak"
      [ -e "$backup" ] && backup="${backup}.$(date +%s)"
      mv "$link_path" "$backup"
      cp "$template_path" "$link_path"
      printf '  REWRITTEN %s\n            backed up existing file to: %s\n            re-seeded from repo template (--force-config)\n' \
        "$link_path" "$backup"
      count_created=$(( count_created + 1 ))
    else
      printf '  OK       %s\n           already seeded and owned by the platform - not overwriting (use --force-config to re-seed)\n' "$link_path"
      count_ok=$(( count_ok + 1 ))
    fi
    return
  fi

  cp "$template_path" "$link_path"
  printf '  CREATED  %s (seeded from %s)\n' "$link_path" "$template_path"
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

  backup_migrate_link "${CLAUDE_CONFIG_DIR}/CLAUDE.md" "${REPO_DIR}/CLAUDE.md"
  backup_migrate_link "${CLAUDE_CONFIG_DIR}/settings.json" "${REPO_DIR}/platforms/claude/settings.json"

  install_external_skills "claude-code"
  # superpowers for Claude Code is declared in settings.json (enabledPlugins),
  # so it installs/updates through Claude Code itself, not via the CLI here.
  register_codegraph_mcp
}

# ---------------------------------------------------------------------------
# Claude Code, personal subscription. A second, fully separate config dir is
# the only way to keep two subscriptions logged in at once: the credentials
# file (and .claude.json, which carries oauthAccount) both live inside
# CLAUDE_CONFIG_DIR, so isolating the dir isolates the token quota.
# ---------------------------------------------------------------------------
deploy_claude_personal() {
  # Captured now, before CLAUDE_CONFIG_DIR is temporarily overridden below.
  # `CLAUDE_CONFIG_DIR="$personal_dir" deploy_claude` is a prefix assignment,
  # so bash auto-restores CLAUDE_CONFIG_DIR to its prior value the moment
  # deploy_claude returns — meaning this copy is only defensive today, not
  # strictly required. Keep it anyway, and never rewrite the prefix
  # assignment below into a plain `CLAUDE_CONFIG_DIR="$personal_dir"`
  # statement: a plain assignment is NOT auto-restored, so the override
  # would persist, default_dir would end up equal to personal_dir, and every
  # link_one call below would link a path to itself — session sharing would
  # break silently (links still get created, just useless), surfacing only
  # when a switched subscription can't resume a prior conversation.
  local default_dir="$CLAUDE_CONFIG_DIR"
  local personal_dir="$CLAUDE_PERSONAL_CONFIG_DIR"

  printf 'Deploying to Claude Code (personal subscription)\n  target: %s\n\n' "$personal_dir"
  CLAUDE_CONFIG_DIR="$personal_dir" deploy_claude

  # Share chat sessions with the default subscription. These four dirs are
  # keyed by session UUID, so two subscriptions running side by side write to
  # disjoint paths; linking them is what lets one subscription resume a
  # conversation the other one started.
  local d
  for d in projects session-env file-history tasks; do
    mkdir -p "${default_dir}/${d}"
    link_one "${personal_dir}/${d}" "${default_dir}/${d}"
  done
}

# ---------------------------------------------------------------------------
# codegraph MCP server (Claude Code, user scope). This cannot be deployed via
# symlink like the rest of this function: user-scope MCP servers can only be
# declared in the top-level mcpServers field of ~/.claude.json, and
# settings.json has no field for it. ~/.claude.json also stores per-project
# local state, so the whole file is unsuitable for version control — the CLI
# is the only way to register this idempotently.
# `claude mcp get <name>` is the idempotency check: exit 0 = already
# registered, exit 1 = not registered (both behaviours confirmed by hand).
# `--scope user` must be passed explicitly; `claude mcp add` defaults to
# `local` scope.
# ---------------------------------------------------------------------------
register_codegraph_mcp() {
  if ! command -v claude > /dev/null 2>&1; then
    printf '  WARNING  claude CLI not found - skipping codegraph MCP server registration.\n'
    return
  fi

  if claude mcp get codegraph > /dev/null 2>&1; then
    printf '  OK       codegraph MCP server already registered (user scope)\n'
    count_ok=$(( count_ok + 1 ))
  elif claude mcp add codegraph --scope user -- codegraph serve --mcp; then
    printf '  CREATED  codegraph MCP server registered (user scope)\n'
    count_created=$(( count_created + 1 ))
  else
    printf '  WARNING  failed to register codegraph MCP server - skipping.\n'
    count_skipped=$(( count_skipped + 1 ))
  fi
}

GEN_BANNER_MD='<!-- GENERATED by install.sh - do not edit. Source: CLAUDE.md + rules/*.md -->'

# Concatenate CLAUDE.md then rules/*.md (alphabetical) into <out>. The 32 KiB
# truncation warning is Codex-specific (project_doc_max_bytes), so it is gated
# on the second argument being "codex".
generate_agents_md() {
  local out="$1"
  local platform="${2:-}"
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

  if [ "$platform" = "codex" ]; then
    local size
    size="$(wc -c < "$out")"
    if [ "$size" -gt 32768 ]; then
      printf '  WARNING  %s is %d bytes (> 32 KiB project_doc_max_bytes); Codex will truncate.\n' "$out" "$size"
    fi
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

# Generate one opencode agent .md per agents/*.md into
# ${OPENCODE_CONFIG_DIR}/agents, then prune orphaned generated files. The
# GENERATED banner lives on the SECOND line (inside the YAML frontmatter,
# whose '---' fence must be line 1), so banner detection scans the first few
# lines rather than only line 1. Hand-authored files without the banner are
# preserved.
generate_opencode_subagents() {
  if ! command -v python3 > /dev/null 2>&1; then
    printf '  WARNING  python3 not found - skipping opencode subagent generation.\n'
    return
  fi

  local agents_src="${REPO_DIR}/agents"
  local agents_dst="${OPENCODE_CONFIG_DIR}/agents"
  local converter="${REPO_DIR}/scripts/md-agent-to-opencode.py"
  mkdir -p "$agents_dst"

  local -A wanted=()
  while IFS= read -r -d '' md_path; do
    local base
    base="$(basename "$md_path" .md)"
    wanted["$base"]=1
    local out_path="${agents_dst}/${base}.md"
    if python3 "$converter" "$md_path" > "${out_path}.tmp" 2>/dev/null; then
      if [ -e "$out_path" ] && ! head -3 "$out_path" | grep -q 'GENERATED by install.sh'; then
        rm -f "${out_path}.tmp"
        printf '  WARNING  %s already exists and is hand-authored (no GENERATED banner) - skipping to avoid destroying it.\n' "$out_path"
      else
        mv "${out_path}.tmp" "$out_path"
        printf '  GENERATED %s\n' "$out_path"
      fi
    else
      rm -f "${out_path}.tmp"
      printf '  WARNING  failed to convert %s - skipping.\n' "$md_path"
    fi
  done < <(find "$agents_src" -maxdepth 1 -type f -name '*.md' -print0 | sort -z)

  while IFS= read -r -d '' md_path; do
    local base
    base="$(basename "$md_path" .md)"
    if [ -z "${wanted[$base]:-}" ] && head -3 "$md_path" | grep -q 'GENERATED by install.sh'; then
      rm -f "$md_path"
      printf '  PRUNED   %s (no repo source)\n' "$md_path"
    fi
  done < <(find "$agents_dst" -maxdepth 1 -type f -name '*.md' -print0 | sort -z)
}

deploy_codex() {
  printf 'Deploying to Codex\n  target: %s\n\n' "$CODEX_HOME"
  mkdir -p "$CODEX_HOME" "${CODEX_HOME}/agents" "${CODEX_HOME}/prompts" "${AGENTS_HOME}/skills"

  link_items_into "${REPO_DIR}/skills" "${AGENTS_HOME}/skills"
  link_commands_flat "${REPO_DIR}/commands" "${CODEX_HOME}/prompts"
  seed_managed_file "${CODEX_HOME}/config.toml" "${REPO_DIR}/platforms/codex/config.toml" "$force_config"

  generate_agents_md "${CODEX_HOME}/AGENTS.md" codex
  generate_codex_subagents

  if [ -L "${CODEX_HOME}/agents.md" ]; then
    rm -f "${CODEX_HOME}/agents.md"
    printf '  REMOVED  %s (legacy lowercase symlink)\n' "${CODEX_HOME}/agents.md"
  fi

  install_external_skills "codex"
  install_superpowers "codex"
}

deploy_opencode() {
  printf 'Deploying to opencode\n  target: %s\n\n' "$OPENCODE_CONFIG_DIR"
  mkdir -p "$OPENCODE_CONFIG_DIR" "${OPENCODE_CONFIG_DIR}/agents" "${OPENCODE_CONFIG_DIR}/commands" "${AGENTS_HOME}/skills"

  link_items_into "${REPO_DIR}/skills" "${AGENTS_HOME}/skills"
  link_commands_flat "${REPO_DIR}/commands" "${OPENCODE_CONFIG_DIR}/commands"
  backup_migrate_link "${OPENCODE_CONFIG_DIR}/opencode.json" "${REPO_DIR}/platforms/opencode/opencode.json"

  generate_agents_md "${OPENCODE_CONFIG_DIR}/AGENTS.md"
  generate_opencode_subagents

  install_external_skills "opencode"
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
# Platform-independent: all three platforms share the same global install, so
# this runs once regardless of which platforms were selected.
# Re-run every time to install or update to latest: `npm install -g <pkg>@latest`
# is idempotent and refreshes an existing global install in place.
# ---------------------------------------------------------------------------
install_openspec() {
  [ -n "$skip_external" ] && return

  if ! command -v npm > /dev/null 2>&1; then
    printf '  WARNING  npm not found - skipping openspec install.\n'
    return
  fi

  if npm install --global @fission-ai/openspec@latest; then
    printf '  INSTALLED @fission-ai/openspec@latest (openspec)\n'
    count_created=$(( count_created + 1 ))
  else
    printf '  WARNING  failed to install @fission-ai/openspec - skipping.\n'
    count_skipped=$(( count_skipped + 1 ))
  fi
}

# ---------------------------------------------------------------------------
# Superpowers plugin — installed/updated via each platform's native plugin
# manager. Re-run every time so the plugin tracks the latest version.
#   - Codex: superpowers is declared declaratively inside the seeded
#     config.toml itself ([plugins."superpowers@superpowers-dev"] +
#     [marketplaces.superpowers-dev], pointing at the obra/superpowers Git
#     repo). `codex plugin marketplace upgrade` alone reads that declaration,
#     fetches the marketplace, and installs/enables the plugin — idempotent
#     and exit-0 on repeat runs. There is no separate `codex plugin add` step:
#     the marketplace name it would require was never registered under that
#     identifier, so that call always failed.
# Claude Code and opencode are intentionally not handled here; both declare
# superpowers declaratively in their own config (settings.json enabledPlugins
# and opencode.json plugin array respectively) so each harness installs and
# updates it itself.
# ---------------------------------------------------------------------------
install_superpowers() {
  local platform="$1"

  [ -n "$skip_external" ] && return

  case "$platform" in
    codex)
      if ! command -v codex > /dev/null 2>&1; then
        printf '  WARNING  codex CLI not found - skipping superpowers plugin install.\n'
        return
      fi
      # This single command both fetches the declared marketplace and
      # installs/enables the plugin it declares; any exit-0 run is counted
      # as handled — we cannot cheaply tell "new" apart from "updated" here.
      if codex plugin marketplace upgrade; then
        printf '  INSTALLED superpowers plugin (codex)\n'
        count_created=$(( count_created + 1 ))
      else
        printf '  WARNING  failed to run codex plugin marketplace upgrade - skipping.\n'
        count_skipped=$(( count_skipped + 1 ))
      fi
      ;;
    *)
      printf '  WARNING  unknown platform %s for superpowers install - skipping.\n' "$platform"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Platform selection: flags win; otherwise ask interactively (reads /dev/tty
# so it still works when stdin is piped).
# ---------------------------------------------------------------------------
want_claude=""
want_claude_personal=""
want_codex=""
want_opencode=""
skip_external=""
force_config=""

for arg in "$@"; do
  case "$arg" in
    --claude) want_claude=1 ;;
    --claude-personal) want_claude_personal=1 ;;
    --codex)  want_codex=1 ;;
    --opencode) want_opencode=1 ;;
    --all)    want_claude=1; want_codex=1; want_opencode=1 ;;
    --no-external) skip_external=1 ;;
    --force-config) force_config=1 ;;
    -h|--help)
      printf 'Usage: install.sh [--claude] [--claude-personal] [--codex] [--opencode] [--all] [--no-external] [--force-config]\n'
      printf '  --claude-personal  deploy the full repo config to a second, personal-\n'
      printf '                     subscription-only Claude Code config dir (shares\n'
      printf '                     session state with --claude).\n'
      printf '  --force-config  re-seed an already-seeded Codex config.toml from the repo\n'
      printf '                  template (backs up the existing file first). Codex-only;\n'
      printf '                  no effect on Claude Code or opencode.\n'
      exit 0
      ;;
    *) printf 'Unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

if [ -z "$want_claude" ] && [ -z "$want_claude_personal" ] && [ -z "$want_codex" ] && [ -z "$want_opencode" ]; then
  if ! { : > /dev/tty; } 2>/dev/null; then
    printf 'Error: no controlling terminal available for interactive prompts.\n' >&2
    printf 'Re-run with an explicit platform flag: --claude, --codex, --opencode, or --all.\n' >&2
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
  ask_yn "Install for opencode?" && want_opencode=1
fi

if [ -z "$want_claude" ] && [ -z "$want_claude_personal" ] && [ -z "$want_codex" ] && [ -z "$want_opencode" ]; then
  printf 'No platform selected - nothing to do.\n'
  exit 0
fi

# ---------------------------------------------------------------------------
# CLI tools bootstrap — runs before any platform deploy because deploy_codex
# needs the codex CLI (to install the superpowers plugin) and deploy_claude
# needs the claude CLI (to register the codegraph MCP server), and both
# binaries come from install-cli-tools.sh. A failure here is fatal: the
# script's own `set -euo pipefail` is enough to abort (no `|| true` or other
# fallback is added on purpose), because the later deploy steps depend on
# these CLIs and would otherwise silently no-op or behave unpredictably.
# INSTALL_CLI_TOOLS is a test-only escape hatch (default: run unconditionally)
# so the test suite can skip real sudo pacman/yay installs and ~/.zshrc
# rewrites; it is intentionally left out of --help and has no matching
# command-line flag, since users should have no convenient way to skip it.
if [ "${INSTALL_CLI_TOOLS:-1}" != "0" ]; then
  "${REPO_DIR}/install-cli-tools.sh"
fi

[ -n "$want_claude" ] && deploy_claude
[ -n "$want_codex" ] && deploy_codex
[ -n "$want_opencode" ] && deploy_opencode
[ -n "$want_claude_personal" ] && deploy_claude_personal

# OpenSpec is a plain dev CLI tool with no per-platform install target, so it
# runs once regardless of which platform(s) were selected above.
install_openspec

printf '\n=== Summary ===\n'
printf '  created:  %d\n' "$count_created"
printf '  ok:       %d\n' "$count_ok"
printf '  skipped:  %d\n' "$count_skipped"

# codegraph 的索引是逐專案的，install.sh 只負責幫本次選取的平台接上 codegraph
# 的 MCP server，不會替任何專案建立索引，故在此提醒使用者後續自行執行。
printf '\n提示：本次已為你選取的平台接上 codegraph 的 MCP server，但索引是逐專案\n'
printf '      進行的，並不包含在這次安裝內。想在某個專案使用 codegraph，請到該\n'
printf '      專案根目錄執行一次「codegraph init」；已經有 .codegraph/ 目錄的專案\n'
printf '      不需要重跑。\n'
