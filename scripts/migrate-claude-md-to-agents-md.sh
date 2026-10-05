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

# ---- 5. discovery: directories that hold a tracked CLAUDE.md or AGENTS.md ----
# A path ending in .claude/CLAUDE.md maps to the parent of that .claude directory.
# The root is the key "." (always processed first, so no sort-order surprises).
declare -A seen_dir=() TRACKED=() # TRACKED: every git-tracked path; only these are ever read or changed
while IFS= read -r -d '' tracked; do
  TRACKED["$tracked"]=1
  base="$(basename "$tracked")"
  case "$base" in
    CLAUDE.md | AGENTS.md) ;;
    *) continue ;;
  esac
  d="$(dirname "$tracked")"
  if [ "$base" = "CLAUDE.md" ] && [ "$(basename "$d")" = ".claude" ]; then
    d="$(dirname "$d")"
  fi
  seen_dir["$d"]=1
done < <(git -C "$PROJECT_DIR" ls-files -z)

DIRS=()
[ -z "${seen_dir[.]+x}" ] || DIRS+=(".")
unset 'seen_dir[.]'
if [ "${#seen_dir[@]}" -gt 0 ]; then
  while IFS= read -r -d '' d; do DIRS+=("$d"); done \
    < <(printf '%s\0' "${!seen_dir[@]}" | LC_ALL=C sort -z)
fi

# ---- 6. classification and the per-directory planned-action list ----
# The plan is computed once here; Task 3 executes these same tables.
# All are keyed by directory (relative to the project root, "." = root):
#   PLAN_CASE[d]     1-5, or "conflict"
#   PLAN_ACTIONS[d]  newline-separated action lines, e.g. "write AGENTS.md",
#                    in execution order, paths relative to the project root
#   PLAN_PARTS[d]    newline-separated merge parts in merge order (paths relative
#                    to the project root); AGENTS.md is listed only in case 3
#   PLAN_WARNINGS[d] newline-separated path-scoped rule paths kept in place
#   PLAN_REASON[d]   conflict reason (conflict only)
# Paths containing newlines are not supported by this encoding.
declare -A PLAN_CASE=() PLAN_ACTIONS=() PLAN_PARTS=() PLAN_WARNINGS=() PLAN_REASON=()

# has_import_line <file>: true if a line equals @AGENTS.md or @./AGENTS.md after trimming.
has_import_line() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [ "$line" = "@AGENTS.md" ] || [ "$line" = "@./AGENTS.md" ]; then return 0; fi
  done < "$1"
  return 1
}

# is_path_scoped <file>: true if the file has frontmatter (first line ---, closed by a
# later --- line) containing a line starting with "paths:" at column 0.
is_path_scoped() {
  local line first=1 found=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$first" -eq 1 ]; then
      first=0
      [ "$line" = "---" ] || return 1
      continue
    fi
    if [ "$line" = "---" ]; then
      [ "$found" -eq 1 ]
      return
    fi
    if [[ "$line" == paths:* ]]; then found=1; fi
  done < "$1"
  return 1 # no closing line: no frontmatter
}

# plan_dir <rel-dir>: classify one directory and fill the PLAN_* tables.
plan_dir() {
  local rel="$1" abs claude agents dotclaude rules_dir pre
  if [ "$rel" = "." ]; then
    abs="$PROJECT_DIR"
    pre=""
  else
    abs="$PROJECT_DIR/$rel"
    pre="$rel/" # prefix for report paths
  fi
  claude="$abs/CLAUDE.md"
  agents="$abs/AGENTS.md"
  dotclaude="$abs/.claude/CLAUDE.md"
  rules_dir="$abs/.claude/rules"

  # Only git-tracked files count as existing. A file on disk that is not tracked
  # (gitignored, given the clean-tree check) cannot be restored by git: CONFLICT.
  local name has_claude=0 has_dot=0
  for name in CLAUDE.md .claude/CLAUDE.md AGENTS.md; do
    if { [ -e "$abs/$name" ] || [ -L "$abs/$name" ]; } && [ -z "${TRACKED[${pre}$name]+x}" ]; then
      PLAN_CASE[$rel]=conflict
      PLAN_REASON[$rel]="$name exists but is not tracked by git"
      return 0
    fi
  done
  [ -z "${TRACKED[${pre}CLAUDE.md]+x}" ] || has_claude=1
  [ -z "${TRACKED[${pre}.claude/CLAUDE.md]+x}" ] || has_dot=1

  if [ -L "$claude" ]; then
    PLAN_CASE[$rel]=conflict
    PLAN_REASON[$rel]="CLAUDE.md is a symlink"
    return 0
  fi
  if [ -L "$dotclaude" ]; then
    PLAN_CASE[$rel]=conflict
    PLAN_REASON[$rel]=".claude/CLAUDE.md is a symlink"
    return 0
  fi
  local agents_is_link=0
  if [ -L "$agents" ]; then
    agents_is_link=1
    if [ "$(realpath -m "$agents")" != "$(realpath -m "$claude")" ]; then
      PLAN_CASE[$rel]=conflict
      PLAN_REASON[$rel]="AGENTS.md is a symlink not pointing to sibling CLAUDE.md"
      return 0
    fi
  fi

  if [ -f "$claude" ] && has_import_line "$claude"; then
    PLAN_CASE[$rel]=1
    return 0
  fi
  local kind
  if [ "$agents_is_link" -eq 1 ]; then
    kind=2
  elif [ -f "$agents" ] && [ "$has_claude" -eq 0 ] && [ "$has_dot" -eq 0 ]; then
    PLAN_CASE[$rel]=4
    return 0
  elif [ -f "$agents" ]; then
    kind=3
  else
    kind=5
  fi
  PLAN_CASE[$rel]="$kind"

  # Merge parts, in merge order.
  local parts="" actions="" warnings="" merged_rules="" f relf
  [ "$kind" -ne 3 ] || parts+="${pre}AGENTS.md"$'\n'
  [ "$has_claude" -eq 0 ] || parts+="${pre}CLAUDE.md"$'\n'
  [ "$has_dot" -eq 0 ] || parts+="${pre}.claude/CLAUDE.md"$'\n'

  # Rules: recursive, LC_ALL=C sorted; path-scoped ones are kept and warned about.
  local -a rule_files=() rule_dirs=()
  # Only tracked rule files are rule candidates; untracked ones stay and keep their dir non-empty.
  if [ -d "$rules_dir" ]; then
    local tp
    while IFS= read -r -d '' f; do rule_files+=("$f"); done < <(
      for tp in "${!TRACKED[@]}"; do
        case "$tp" in
          "${pre}.claude/rules/"*.md) printf '%s\0' "$PROJECT_DIR/$tp" ;;
        esac
      done | LC_ALL=C sort -z
    )
    # reverse C order lists every directory deeper-first
    while IFS= read -r -d '' f; do rule_dirs+=("$f"); done \
      < <(find "$rules_dir" -type d -print0 | LC_ALL=C sort -z -r)
  fi
  local -A gone=()
  for f in "${rule_files[@]+"${rule_files[@]}"}"; do
    relf="${f#"$PROJECT_DIR"/}"
    if is_path_scoped "$f"; then
      warnings+="$relf"$'\n'
    else
      parts+="$relf"$'\n'
      merged_rules+="delete $relf"$'\n'
      gone["$f"]=1
    fi
  done

  [ "$kind" -ne 2 ] || actions+="remove-symlink ${pre}AGENTS.md"$'\n'
  actions+="write ${pre}AGENTS.md"$'\n'
  if [ "$has_claude" -eq 1 ]; then
    actions+="rewrite ${pre}CLAUDE.md"$'\n'
  else
    actions+="create ${pre}CLAUDE.md"$'\n'
  fi
  [ "$has_dot" -eq 0 ] || actions+="delete ${pre}.claude/CLAUDE.md"$'\n'
  actions+="$merged_rules"

  # rmdir every rules directory left empty, deepest first.
  local d entry empty
  for d in "${rule_dirs[@]+"${rule_dirs[@]}"}"; do
    empty=1
    while IFS= read -r -d '' entry; do
      if [ -z "${gone[$entry]+x}" ]; then
        empty=0
        break
      fi
    done < <(find "$d" -mindepth 1 -maxdepth 1 -print0)
    if [ "$empty" -eq 1 ]; then
      gone["$d"]=1
      actions+="rmdir ${d#"$PROJECT_DIR"/}"$'\n'
    fi
  done

  PLAN_PARTS[$rel]="${parts%$'\n'}"
  PLAN_ACTIONS[$rel]="${actions%$'\n'}"
  PLAN_WARNINGS[$rel]="${warnings%$'\n'}"
}

conflicts=0
for d in "${DIRS[@]+"${DIRS[@]}"}"; do
  plan_dir "$d"
  if [ "${PLAN_CASE[$d]}" = conflict ]; then conflicts=$((conflicts + 1)); fi
done

# ---- 7. report (stdout) ----
for d in "${DIRS[@]+"${DIRS[@]}"}"; do
  shown="$d"
  c="${PLAN_CASE[$d]}"
  if [ "$c" = conflict ]; then
    printf 'CONFLICT %s: %s\n' "$shown" "${PLAN_REASON[$d]}"
    continue
  fi
  printf '[case %s] %s\n' "$c" "$shown"
  case "$c" in
    1) printf '  skip (already migrated)\n' ;;
    4) printf '  skip (nothing to migrate)\n' ;;
    *)
      printf '%s\n' "${PLAN_ACTIONS[$d]}" | sed 's/^/  /'
      if [ -n "${PLAN_WARNINGS[$d]}" ]; then
        printf '%s\n' "${PLAN_WARNINGS[$d]}" | sed 's/^/  WARNING path-scoped rule kept: /'
      fi
      ;;
  esac
done

# ---- 8. apply: execute exactly the planned actions, in order ----
TMP_AGENTS="" # temp file awaiting mv; removed on any exit so no stray file is left behind
trap '[ -z "$TMP_AGENTS" ] || rm -f "$TMP_AGENTS"' EXIT INT TERM

# read_part <rel-path>: print one merge part with frontmatter removed (rules only) and
# leading/trailing blank lines dropped. Command substitution drops trailing newlines.
read_part() {
  local rel="$1" i start=0 end line
  local -a lines=()
  mapfile -t lines < "$PROJECT_DIR/$rel"
  end=${#lines[@]}
  case "$rel" in
    *.claude/rules/*)
      if [ "$end" -gt 0 ] && [ "${lines[0]}" = "---" ]; then
        for ((i = 1; i < end; i++)); do
          if [ "${lines[i]}" = "---" ]; then
            start=$((i + 1))
            break
          fi
        done
      fi
      ;;
  esac
  # blank = empty or whitespace only
  while [ "$start" -lt "$end" ]; do
    line="${lines[start]}"
    [ -z "${line//[[:space:]]/}" ] || break
    start=$((start + 1))
  done
  while [ "$end" -gt "$start" ]; do
    line="${lines[end - 1]}"
    [ -z "${line//[[:space:]]/}" ] || break
    end=$((end - 1))
  done
  for ((i = start; i < end; i++)); do
    printf '%s\n' "${lines[i]}"
  done
}

# apply_dir <rel-dir>: build AGENTS.md from PLAN_PARTS, then run PLAN_ACTIONS in order.
apply_dir() {
  local rel="$1" abs part content merged="" first=1 mode action target
  if [ "$rel" = "." ]; then abs="$PROJECT_DIR"; else abs="$PROJECT_DIR/$rel"; fi
  # Read every part before touching any file (CLAUDE.md is rewritten later).
  while IFS= read -r part; do
    content="$(read_part "$part")"
    if [ "$first" -eq 1 ]; then first=0; else merged+=$'\n\n---\n\n'; fi
    merged+="$content"
  done <<< "${PLAN_PARTS[$rel]}"
  # Temp file in the same directory, then mv: a failed write never leaves a truncated AGENTS.md.
  TMP_AGENTS="$(mktemp "$abs/.AGENTS.md.XXXXXX")"
  printf '%s\n' "$merged" > "$TMP_AGENTS"
  mode="$(printf '%04o' $((0666 & ~$(umask))))"
  chmod "$mode" "$TMP_AGENTS"
  while IFS= read -r action; do
    target="$PROJECT_DIR/${action#* }"
    case "$action" in
      "remove-symlink "*) rm -f "$target" ;;
      "write "*)
        mv -f "$TMP_AGENTS" "$target"
        TMP_AGENTS=""
        ;;
      "rewrite "* | "create "*) printf '@AGENTS.md\n' > "$target" ;;
      "delete "*) rm -f "$target" ;;
      "rmdir "*) rmdir "$target" ;;
    esac
  done <<< "${PLAN_ACTIONS[$rel]}"
}

if [ "$APPLY" -eq 1 ]; then
  for d in "${DIRS[@]+"${DIRS[@]}"}"; do
    case "${PLAN_CASE[$d]}" in
      2 | 3 | 5) apply_dir "$d" ;;
    esac
  done
  printf 'applied\n'
else
  printf 'dry-run: no files changed; re-run with --apply to write\n'
fi
if [ "$conflicts" -ne 0 ]; then exit 1; fi
exit 0

