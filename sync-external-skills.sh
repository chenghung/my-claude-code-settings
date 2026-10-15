#!/usr/bin/env bash
# sync-external-skills.sh - install, update and remove the external skills
# listed in external-skills.jsonc, via the skills CLI (`npx skills`).
#
# Target shell: bash 4.3+ - needs associative arrays and arrays; no feature
# newer than bash 4.3 is used.
#
# DESTRUCTIVE OPERATIONS: `npx skills remove` deletes skills that the CLI's
# lock file records but the manifest no longer lists, on ALL platforms. Every
# run prints a preview and asks `[y/N]` (default No) on /dev/tty before any
# install or remove; --no-confirm skips the question. Preview-and-confirm is
# the dry-run here: answering No changes nothing.
#
# Exit codes: 0 success, or cancelled at the prompt; 1 any failure (precheck,
# npx, verification, no terminal to ask on); 2 usage error.

set -euo pipefail
IFS=$'\n\t'

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

# ---------------------------------------------------------------------------
# Problems are collected and printed together at the end. Each entry is one
# message line, optionally followed by detail lines (newline separated).
# ---------------------------------------------------------------------------
PROBLEMS=()

add_problem() {
  PROBLEMS+=("$1")
}

# add_problems_from <file>: one problem per line of the file.
add_problems_from() {
  local line
  while IFS= read -r line; do add_problem "$line"; done < "$1"
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
# or a name is empty or contains '*' or whitespace - such a name must never
# reach `skills remove`.
read_lock() {
  python3 - "$LOCK" <<'PY'
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
bad = [n for n in skills if not n or "*" in n or re.search(r"\s", n)]
for n in bad:
    print(f"lock file {path}: unsafe skill name {json.dumps(n)} "
          "(empty, or contains '*' or whitespace)", file=sys.stderr)
if bad:
    sys.exit(1)
for n in skills:
    print(n)
PY
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
    python3 "$PLAN_SCRIPT" "$MANIFEST" "$REPO_DIR" "${SELECTED[@]}" \
      > "$WORK_DIR/plan.tsv" 2> "$WORK_DIR/plan.err" || rc=$?
    if ((rc != 0)); then
      add_problem "plan script failed (exit $rc) for $MANIFEST:"$'\n'"$(cat "$WORK_DIR/plan.err")"
    fi
  fi
  local lock_names=()
  if ((have_python)); then
    rc=0
    read_lock > "$WORK_DIR/lock.txt" 2> "$WORK_DIR/lock.err" || rc=$?
    if ((rc != 0)); then
      add_problems_from "$WORK_DIR/lock.err"
    else
      mapfile -t lock_names < "$WORK_DIR/lock.txt"
    fi
  fi
  if ((${#PROBLEMS[@]})); then
    print_summary
    exit 1
  fi

  # ---- parse the plan ----
  local kind f1 f2 f3
  local g_repo=() g_agents=() g_skills=()
  declare -A want=() known=()
  while IFS=$'\t' read -r kind f1 f2 f3; do
    case "$kind" in
      group) g_repo+=("$f1"); g_agents+=("$f2"); g_skills+=("$f3") ;;
      want) want[$f1]+="${want[$f1]+ }$f2" ;;
      known) known[$f1]=1 ;;
    esac
  done < "$WORK_DIR/plan.tsv"

  # ---- step 2: compute changes ----
  # wanted_list: selected platforms' want names, de-duplicated, in order.
  local names=() dir use_claude=0 use_agents=0 wanted_list=()
  declare -A install=() installing=() wanted=()
  for p in "${SELECTED[@]}"; do
    if [[ "$p" == claude ]]; then use_claude=1; else use_agents=1; fi
    [[ -n "${want[$p]+x}" ]] || continue
    dir="$(location "$p")"
    IFS=' ' read -ra names <<< "${want[$p]}"
    for name in "${names[@]}"; do
      [[ -n "${wanted[$name]+x}" ]] || wanted_list+=("$name")
      wanted[$name]=1
      if [[ ! -e "$dir/$name" ]]; then
        install[$p]+="${install[$p]+ }$name"
        installing[$name]=1
      fi
    done
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
  printf '將更新 %d 個既有 skill\n' "$updates"

  if { ((${#installing[@]})) || ((${#remove[@]})); } && ((!no_confirm)); then
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
  if ((${#remove[@]})); then
    for name in "${remove[@]}"; do
      for dir in "$CLAUDE_SKILLS" "$AGENTS_SKILLS"; do
        if [[ -e "$dir/$name" || -L "$dir/$name" ]]; then
          add_problem "verify: $name still present in $(display_path "$dir") after remove"
        fi
      done
    done
    rc=0
    read_lock > "$WORK_DIR/lock.txt" 2> "$WORK_DIR/lock.err" || rc=$?
    if ((rc != 0)); then
      add_problems_from "$WORK_DIR/lock.err"
    else
      declare -A still_locked=()
      while IFS= read -r name; do still_locked[$name]=1; done < "$WORK_DIR/lock.txt"
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
