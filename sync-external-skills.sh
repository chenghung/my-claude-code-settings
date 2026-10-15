#!/usr/bin/env bash
# sync-external-skills.sh - install, update and remove the external skills
# listed in external-skills.jsonc, via the skills CLI (`npx skills`).
#
# Target shell: bash 4.3+ - needs associative arrays and arrays; no feature
# newer than bash 4.3 is used.
#
# DESTRUCTIVE OPERATIONS: `npx skills remove` deletes skills that the CLI's
# lock file records but the manifest no longer lists, on ALL platforms; the
# script also deletes symlinks (stale aliases, dangling repo symlinks it then
# replaces, outdated Antigravity bridge links). Real directories and live
# symlinks into this repo are never deleted by the script itself. Every run
# prints a preview and asks `[y/N]` (default No) on /dev/tty before any
# install, remove, replacement or symlink cleanup; --no-confirm skips the
# question. Preview-and-confirm is the dry-run here: answering No changes
# nothing.
#
# Exit codes: 0 success, or cancelled at the prompt; 1 any failure (precheck,
# npx, verification, no terminal to ask on); 2 usage error.

set -euo pipefail
IFS=$'\n\t'
# Directory scans use "$dir"/*; an empty or missing directory yields nothing.
shopt -s nullglob

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${REPO_DIR}/external-skills.jsonc"
PLAN_SCRIPT="${REPO_DIR}/scripts/external-skills-plan.py"

PLATFORMS=(claude codex opencode antigravity)

usage() {
  cat <<'EOF'
Usage: sync-external-skills.sh [--claude] [--codex] [--opencode] [--antigravity] [--all] [--no-confirm] [-h|--help]
  Installs/updates the skills listed in external-skills.jsonc on the selected
  platforms and removes lock-recorded skills no longer listed (all platforms).
  At least one platform flag is required; --all selects all four.
  --no-confirm  do not ask before installing or removing.
EOF
}

# ---------------------------------------------------------------------------
# Path helpers (shared with the symlink cleanup and bridge steps)
# ---------------------------------------------------------------------------

# link_target <symlink>: the link text made absolute against the link's own
# directory, then normalised lexically (no symlink following, the target
# need not exist).
link_target() {
  local text
  text="$(readlink -- "$1")"
  [[ "$text" == /* ]] || text="$(dirname -- "$1")/$text"
  realpath -m -s -- "$text"
}

# is_dangling_link <symlink>: true when the normalised target does not exist.
is_dangling_link() {
  local target
  target="$(link_target "$1")"
  [[ ! -e "$target" ]]
}

# path_under <normalised path> <dir>: true when path equals dir or lies below
# it; dir is normalised the same way first.
path_under() {
  local dir
  dir="$(realpath -m -s -- "$2")"
  [[ "$1" == "$dir" || "$1" == "$dir"/* ]]
}

# display_path <path>: path with a leading $HOME shown as ~.
display_path() {
  case "$1" in
    "$HOME") printf '~' ;;
    "$HOME"/*) printf '%s/%s' '~' "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# load_repo_copies: REPO_COPIES = REPO_DIR plus every checkout listed by
# `git worktree list --porcelain` (main checkout and worktrees). If git fails,
# REPO_DIR alone.
REPO_COPIES=()
load_repo_copies() {
  local out line
  REPO_COPIES=("$REPO_DIR")
  out="$(git -C "$REPO_DIR" worktree list --porcelain 2> /dev/null)" || return 0
  while IFS= read -r line; do
    if [[ "$line" == "worktree "* ]]; then REPO_COPIES+=("${line#worktree }"); fi
  done <<< "$out"
}

# points_to_repo <normalised path>: true when the path lies in a repo copy.
points_to_repo() {
  local copy
  for copy in "${REPO_COPIES[@]}"; do
    if path_under "$1" "$copy"; then return 0; fi
  done
  return 1
}

# is_repo_link <path>: a symlink whose normalised target lies in a repo copy.
is_repo_link() {
  [[ -L "$1" ]] && points_to_repo "$(link_target "$1")"
}

# under_skill_dirs <normalised path>: below ~/.agents/skills or the claude dir.
under_skill_dirs() {
  path_under "$1" "$AGENTS_SKILLS" || path_under "$1" "$CLAUDE_SKILLS"
}

# present <path>: exists, or is a (possibly dangling) symlink.
present() {
  [[ -e "$1" || -L "$1" ]]
}

# ---------------------------------------------------------------------------
# Problems are collected and printed together at the end. Each entry is one
# message line, optionally followed by detail lines (newline separated).
# ---------------------------------------------------------------------------
PROBLEMS=()

add_problem() {
  PROBLEMS+=("$1")
}

print_summary() {
  local p first line
  printf 'ERROR  external skills sync failed (%d problems):\n' "${#PROBLEMS[@]}" >&2
  for p in "${PROBLEMS[@]}"; do
    first=1
    while IFS= read -r line; do
      if ((first)); then
        printf '  - %s\n' "$line" >&2
        first=0
      else
        printf '      %s\n' "$line" >&2
      fi
    done <<< "$p"
  done
}

# read_lock: print the lock's skill names, one per line. A missing lock file
# means no records. Fails (message on stderr) when the file cannot be parsed
# or a name does not match ^[A-Za-z0-9][A-Za-z0-9._-]*$ - such a name must
# never reach `skills remove`, where e.g. --all or -a would be read as a flag
# (the CLI does not honour a -- separator). -I keeps a json.py or similar in
# the working directory from being imported.
read_lock() {
  python3 -I - "$LOCK" <<'PY'
import json, re, sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except FileNotFoundError:
    sys.exit(0)
except (OSError, ValueError) as exc:
    print(f"cannot parse lock file {path}: {exc}", file=sys.stderr)
    sys.exit(1)
skills = data.get("skills", {}) if isinstance(data, dict) else None
if not isinstance(skills, dict):
    print(f"cannot parse lock file {path}: 'skills' is not an object", file=sys.stderr)
    sys.exit(1)
valid = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
bad = [n for n in skills if not valid.fullmatch(n)]
for n in bad:
    print(f"lock file {path}: unsafe skill name {json.dumps(n)} "
          "(must match ^[A-Za-z0-9][A-Za-z0-9._-]*$)", file=sys.stderr)
if bad:
    sys.exit(1)
for n in skills:
    print(n)
PY
}

# load_lock: read the lock into LOCK_NAMES. On failure record one fixed
# problem (with read_lock's stderr, if any, as detail lines) and return 1.
LOCK_NAMES=()
load_lock() {
  local rc=0
  LOCK_NAMES=()
  read_lock > "$WORK_DIR/lock.txt" 2> "$WORK_DIR/lock.err" || rc=$?
  if ((rc != 0)); then
    add_problem "cannot read lock file $LOCK (python3 exited $rc)"$'\n'"$(cat "$WORK_DIR/lock.err")"
    return 1
  fi
  mapfile -t LOCK_NAMES < "$WORK_DIR/lock.txt"
}

# location <platform>: the directory a platform's skills live in.
location() {
  if [[ "$1" == claude ]]; then
    printf '%s' "$CLAUDE_SKILLS"
  else
    printf '%s' "$AGENTS_SKILLS"
  fi
}

# run_npx <label> <args...>: run npx with its output kept in a temp file and a
# single progress line on the terminal; on failure record a problem with the
# last 20 output lines.
run_npx() {
  local label="$1" log rc=0
  shift
  log="$(mktemp "$WORK_DIR/npx.XXXXXX")"
  printf '  ... %s\n' "$label"
  npx "$@" < /dev/null > "$log" 2>&1 || rc=$?
  if ((rc != 0)); then
    add_problem "$label: npx exited $rc"$'\n'"$(tail -n 20 "$log")"
  fi
}

main() {
  local arg p name want_all=0 no_confirm=0
  declare -A selected=()
  for arg in "$@"; do
    case "$arg" in
      --claude | --codex | --opencode | --antigravity) selected[${arg#--}]=1 ;;
      --all) want_all=1 ;;
      --no-confirm) no_confirm=1 ;;
      -h | --help) usage; exit 0 ;;
      *)
        printf 'Unknown option: %s\n' "$arg" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
  SELECTED=()
  for p in "${PLATFORMS[@]}"; do
    if ((want_all)) || [[ -n "${selected[$p]+x}" ]]; then SELECTED+=("$p"); fi
  done
  if ((${#SELECTED[@]} == 0)); then
    printf 'Error: no platform selected.\n' >&2
    usage >&2
    exit 2
  fi

  CLAUDE_SKILLS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"
  AGENTS_SKILLS="$HOME/.agents/skills"
  if [[ -n "${XDG_STATE_HOME:-}" ]]; then
    LOCK="$XDG_STATE_HOME/skills/.skill-lock.json"
  else
    LOCK="$HOME/.agents/.skill-lock.json"
  fi

  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "$WORK_DIR"' EXIT
  trap 'exit 1' INT TERM

  # ---- step 1: prechecks, before any change ----
  local have_python=1 rc
  if ! command -v python3 > /dev/null 2>&1; then
    add_problem 'python3 not found in PATH (needed to read external-skills.jsonc and the skills lock file)'
    have_python=0
  fi
  if ! command -v npx > /dev/null 2>&1; then
    add_problem 'npx not found in PATH (install Node.js and npm)'
  fi
  if [[ ! -f "$MANIFEST" ]]; then
    add_problem "manifest not found: $MANIFEST"
  elif ((have_python)); then
    rc=0
    python3 -I "$PLAN_SCRIPT" "$MANIFEST" "$REPO_DIR" "${SELECTED[@]}" \
      > "$WORK_DIR/plan.tsv" 2> "$WORK_DIR/plan.err" || rc=$?
    if ((rc != 0)); then
      add_problem "plan script failed (exit $rc) for $MANIFEST:"$'\n'"$(cat "$WORK_DIR/plan.err")"
    fi
  fi
  local lock_names=()
  if ((have_python)) && load_lock; then
    lock_names=(${LOCK_NAMES[@]+"${LOCK_NAMES[@]}"})
  fi
  if ((${#PROBLEMS[@]})); then
    print_summary
    exit 1
  fi

  # ---- parse the plan ----
  local kind f1 f2 f3
  local g_repo=() g_agents=() g_skills=() known_list=()
  declare -A want=() known=()
  while IFS=$'\t' read -r kind f1 f2 f3; do
    case "$kind" in
      group) g_repo+=("$f1"); g_agents+=("$f2"); g_skills+=("$f3") ;;
      want) want[$f1]+="${want[$f1]+ }$f2" ;;
      known) known[$f1]="$f2"; known_list+=("$f1") ;;
    esac
  done < "$WORK_DIR/plan.tsv"

  # ---- selection, want sets, lock set, scan locations ----
  local gemini_root="${GEMINI_HOME:-$HOME/.gemini}"
  local bridge="$gemini_root/config/skills"
  local old_bridge_src="$gemini_root/antigravity-cli/skills"
  local old_codex="$HOME/.codex/skills" old_opencode="$HOME/.config/opencode/skills"
  local names=() dir path target use_claude=0 use_agents=0 wanted_list=() ag_wants=()
  declare -A on=() wants=() in_lock=()
  for p in "${SELECTED[@]}"; do
    on[$p]=1
    if [[ "$p" == claude ]]; then use_claude=1; else use_agents=1; fi
    [[ -n "${want[$p]+x}" ]] || continue
    IFS=' ' read -ra names <<< "${want[$p]}"
    for name in "${names[@]}"; do wants[$p/$name]=1; done
  done
  [[ -z "${on[antigravity]+x}" || -z "${want[antigravity]+x}" ]] \
    || IFS=' ' read -ra ag_wants <<< "${want[antigravity]}"
  for name in ${lock_names[@]+"${lock_names[@]}"}; do in_lock[$name]=1; done
  local scan_dirs=()
  ((!use_claude)) || scan_dirs+=("$CLAUDE_SKILLS")
  ((!use_agents)) || scan_dirs+=("$AGENTS_SKILLS")
  [[ -z "${on[codex]+x}" ]] || scan_dirs+=("$old_codex")
  [[ -z "${on[opencode]+x}" ]] || scan_dirs+=("$old_opencode")
  [[ -z "${on[antigravity]+x}" ]] || scan_dirs+=("$bridge")
  load_repo_copies

  # ---- step 1 (cont.): link prechecks - conflict, drift, bridge conflict ----
  for name in ${lock_names[@]+"${lock_names[@]}"}; do
    for dir in "${scan_dirs[@]}"; do
      path="$dir/$name"
      if is_repo_link "$path" && ! is_dangling_link "$path"; then
        add_problem "conflict: $name is recorded in the skills lock file, but $path is a live symlink into this repo"$'\n'"(decide by hand which one to keep, then re-run sync)"
      fi
    done
  done
  local plats
  for name in ${known_list[@]+"${known_list[@]}"}; do
    plats=" ${known[$name]} "
    dir=""
    if ((use_claude)) && [[ "$plats" != *" claude "* ]] && present "$CLAUDE_SKILLS/$name"; then
      dir="$CLAUDE_SKILLS"
    elif ((use_agents)) && [[ "$plats" != *" codex "* && "$plats" != *" opencode "* && "$plats" != *" antigravity "* ]] \
      && present "$AGENTS_SKILLS/$name"; then
      dir="$AGENTS_SKILLS"
    fi
    if [[ -n "$dir" ]]; then
      add_problem "drift: $name is in $(display_path "$dir"), but external-skills.jsonc does not list it for that location"$'\n'"(run \`npx skills remove $name -g -y\` by hand, then re-run sync)"
    fi
  done
  for name in ${ag_wants[@]+"${ag_wants[@]}"}; do
    path="$bridge/$name"
    if [[ -e "$path" && ! -L "$path" ]]; then
      add_problem "bridge conflict: $path is not a symlink and will not be overwritten"$'\n'"(move it away by hand, then re-run sync)"
    elif is_repo_link "$path" && ! is_dangling_link "$path"; then
      add_problem "bridge conflict: $path is a live symlink into this repo and will not be overwritten"$'\n'"(remove it by hand if the external skill should win, then re-run sync)"
    fi
  done
  if ((${#PROBLEMS[@]})); then
    print_summary
    exit 1
  fi

  # ---- step 2: compute changes ----
  # Install: wanted skill missing; antigravity also needs its bridge symlink to
  # read exactly ~/.agents/skills/<name>.
  declare -A install=() installing=() wanted=()
  for p in "${SELECTED[@]}"; do
    [[ -n "${want[$p]+x}" ]] || continue
    dir="$(location "$p")"
    IFS=' ' read -ra names <<< "${want[$p]}"
    for name in "${names[@]}"; do
      [[ -n "${wanted[$name]+x}" ]] || wanted_list+=("$name")
      wanted[$name]=1
      if [[ ! -e "$dir/$name" ]] || { [[ "$p" == antigravity ]] \
        && ! [[ -L "$bridge/$name" && "$(readlink -- "$bridge/$name")" == "$AGENTS_SKILLS/$name" ]]; }; then
        install[$p]+="${install[$p]+ }$name"
        installing[$name]=1
      fi
    done
  done

  # Replace: a dangling repo symlink where a selected platform wants the name.
  local replace=()
  for path in "$CLAUDE_SKILLS"/* "$AGENTS_SKILLS"/* "$bridge"/*; do
    name="${path##*/}"
    case "$path" in
      "$CLAUDE_SKILLS"/*) [[ -n "${wants[claude/$name]+x}" ]] || continue ;;
      "$AGENTS_SKILLS"/*)
        [[ -n "${wants[codex/$name]+x}${wants[opencode/$name]+x}${wants[antigravity/$name]+x}" ]] || continue ;;
      *) [[ -n "${wants[antigravity/$name]+x}" ]] || continue ;;
    esac
    if is_repo_link "$path" && is_dangling_link "$path"; then replace+=("$path"); fi
  done

  # Remove: in the lock, not in the manifest, present on a selected location.
  local remove=()
  for name in ${lock_names[@]+"${lock_names[@]}"}; do
    [[ -z "${known[$name]+x}" ]] || continue
    if { ((use_claude)) && [[ -e "$CLAUDE_SKILLS/$name" || -L "$CLAUDE_SKILLS/$name" ]]; } \
      || { ((use_agents)) && [[ -e "$AGENTS_SKILLS/$name" || -L "$AGENTS_SKILLS/$name" ]]; }; then
      remove+=("$name")
    fi
  done

  # Symlink cleanup, de-duplicated in first-seen order.
  local cleanup=()
  declare -A cleaning=()
  add_cleanup() {
    [[ -n "${cleaning[$1]+x}" ]] || { cleaning[$1]=1; cleanup+=("$1"); }
  }
  # General locations: unlisted, unlocked symlink into a skill dir, not repo.
  for dir in "${scan_dirs[@]}"; do
    [[ "$dir" == "$CLAUDE_SKILLS" || "$dir" == "$AGENTS_SKILLS" ]] || continue
    for path in "$dir"/*; do
      name="${path##*/}"
      [[ -L "$path" && -z "${known[$name]+x}" && -z "${in_lock[$name]+x}" ]] || continue
      target="$(link_target "$path")"
      if under_skill_dirs "$target" && ! points_to_repo "$target"; then add_cleanup "$path"; fi
    done
  done
  # Legacy dirs: link into ~/.agents/skills that is dangling or not wanted.
  for p in codex opencode; do
    [[ -n "${on[$p]+x}" ]] || continue
    if [[ "$p" == codex ]]; then dir="$old_codex"; else dir="$old_opencode"; fi
    for path in "$dir"/*; do
      name="${path##*/}"
      [[ -L "$path" ]] || continue
      target="$(link_target "$path")"
      path_under "$target" "$AGENTS_SKILLS" || continue
      if [[ ! -e "$target" || -z "${wants[$p/$name]+x}" ]]; then add_cleanup "$path"; fi
    done
  done
  # Bridge: link into ~/.agents/skills or the old bridge source, not repo;
  # cleaned when dangling, from the old source, or not wanted.
  if [[ -n "${on[antigravity]+x}" ]]; then
    for path in "$bridge"/*; do
      name="${path##*/}"
      [[ -L "$path" ]] || continue
      target="$(link_target "$path")"
      { path_under "$target" "$AGENTS_SKILLS" || path_under "$target" "$old_bridge_src"; } || continue
      ! points_to_repo "$target" || continue
      if [[ ! -e "$target" ]] || path_under "$target" "$old_bridge_src" \
        || [[ -z "${wants[antigravity/$name]+x}" ]]; then
        add_cleanup "$path"
      fi
    done
  fi
  # Same-name symlinks of removed skills, in all five locations.
  for name in ${remove[@]+"${remove[@]}"}; do
    for dir in "$CLAUDE_SKILLS" "$AGENTS_SKILLS" "$old_codex" "$old_opencode" "$bridge"; do
      path="$dir/$name"
      [[ -L "$path" ]] || continue
      target="$(link_target "$path")"
      if under_skill_dirs "$target" && ! points_to_repo "$target"; then add_cleanup "$path"; fi
    done
  done

  local updates=0
  for name in ${wanted_list[@]+"${wanted_list[@]}"}; do
    [[ -n "${installing[$name]+x}" ]] || updates=$((updates + 1))
  done

  # ---- step 3: preview and confirm ----
  for p in "${SELECTED[@]}"; do
    [[ -z "${install[$p]+x}" ]] || printf '將安裝 [%s]: %s\n' "$p" "${install[$p]}"
  done
  if ((${#remove[@]})); then
    printf '將移除（所有平台）: %s\n' "$(IFS=' '; printf '%s' "${remove[*]}")"
  fi
  for path in ${replace[@]+"${replace[@]}"}; do printf '將替換失效的 repo symlink: %s\n' "$path"; done
  for path in ${cleanup[@]+"${cleanup[@]}"}; do printf '將清除的 symlink: %s\n' "$path"; done
  printf '將更新 %d 個既有 skill\n' "$updates"

  if ((${#installing[@]} + ${#remove[@]} + ${#replace[@]} + ${#cleanup[@]})) && ((!no_confirm)); then
    if ! { : > /dev/tty; } 2> /dev/null; then
      printf 'Error: changes need confirmation but /dev/tty cannot be opened; re-run with --no-confirm to proceed without asking.\n' >&2
      exit 1
    fi
    local reply=""
    printf '確定要執行嗎？[y/N] ' > /dev/tty
    read -r reply < /dev/tty || reply=""
    case "$reply" in
      [yY]*) ;;
      *) printf '已取消，未做任何變更。\n'; exit 0 ;;
    esac
  fi

  # ---- step 4: execute ----
  local i skills=() agents=()
  for path in ${replace[@]+"${replace[@]}"}; do
    if [[ -L "$path" ]] && ! rm -f -- "$path"; then
      add_problem "replace $path: cannot remove the dangling symlink"
    fi
  done
  if ((${#remove[@]})); then
    run_npx "remove $(IFS=' '; printf '%s' "${remove[*]}")" \
      --yes skills remove "${remove[@]}" -g -y
  fi
  for ((i = 0; i < ${#g_repo[@]}; i++)); do
    IFS=' ' read -ra skills <<< "${g_skills[$i]}"
    IFS=' ' read -ra agents <<< "${g_agents[$i]}"
    run_npx "add ${g_repo[$i]} -> ${g_agents[$i]}" \
      --yes skills add "${g_repo[$i]}" -s "${skills[@]}" -a "${agents[@]}" -g -y
  done
  for path in ${cleanup[@]+"${cleanup[@]}"}; do
    if [[ -L "$path" ]] && ! rm -f -- "$path"; then
      add_problem "cleanup $path: cannot remove the symlink"
    fi
  done
  # Bridge rebuild: absolute symlink to ~/.agents/skills/<name> for every
  # antigravity skill that exists there; missing ones are left to verify.
  if ((${#ag_wants[@]})); then
    if ! mkdir -p -- "$bridge"; then
      add_problem "bridge $bridge: cannot create the directory"
    else
      for name in "${ag_wants[@]}"; do
        target="$AGENTS_SKILLS/$name"
        path="$bridge/$name"
        [[ -e "$target" ]] || continue
        if [[ -L "$path" ]]; then
          [[ "$(readlink -- "$path")" != "$target" ]] || continue
          rm -f -- "$path" || true
        fi
        if ! present "$path" && ! ln -s -- "$target" "$path"; then
          add_problem "bridge $path: cannot create the symlink"
        fi
      done
    fi
  fi

  # ---- verify: wanted skills present (once per location), removed ones gone ----
  declare -A checked=()
  for p in "${SELECTED[@]}"; do
    [[ -n "${want[$p]+x}" ]] || continue
    dir="$(location "$p")"
    IFS=' ' read -ra names <<< "${want[$p]}"
    for name in "${names[@]}"; do
      [[ -z "${checked[$dir/$name]+x}" ]] || continue
      checked[$dir/$name]=1
      if [[ ! -e "$dir/$name" ]]; then
        add_problem "verify: $name not found in $(display_path "$dir") after install"$'\n'"(name misspelled in external-skills.jsonc, or removed upstream?)"
      fi
    done
  done
  for name in ${ag_wants[@]+"${ag_wants[@]}"}; do
    if [[ ! -e "$bridge/$name" ]]; then
      add_problem "verify: bridge $(display_path "$bridge/$name") missing or unresolvable"
    fi
  done
  if ((${#remove[@]})); then
    for name in "${remove[@]}"; do
      for dir in "$CLAUDE_SKILLS" "$AGENTS_SKILLS"; do
        if [[ -e "$dir/$name" || -L "$dir/$name" ]]; then
          add_problem "verify: $name still present in $(display_path "$dir") after remove"
        fi
      done
    done
    if load_lock; then
      declare -A still_locked=()
      for name in ${LOCK_NAMES[@]+"${LOCK_NAMES[@]}"}; do still_locked[$name]=1; done
      for name in "${remove[@]}"; do
        if [[ -n "${still_locked[$name]+x}" ]]; then
          add_problem "verify: $name still recorded in $(display_path "$LOCK") after remove"
        fi
      done
    fi
  fi

  if ((${#PROBLEMS[@]})); then
    print_summary
    exit 1
  fi
  printf 'OK  external skills sync complete.\n'
  exit 0
}

# Entry point guarded so tests can source the helpers.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
