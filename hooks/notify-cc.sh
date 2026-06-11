#!/usr/bin/env bash
# notify-cc.sh — Claude Code hook: desktop notification via notify-send.
# Receives JSON on stdin, mode string ($1: done|notify).
# Must never exit non-zero (a failing hook would stall Claude Code).
# Target shell: bash 4.4+ (uses arrays under set -u and ${var: -N}).

# Tunable constants
APP_NAME="Claude Code"
AUTH_SECS=60
INPUT_SECS=30
DONE_SECS=8
AUTH_PATTERN='permission'

classify() {
  local mode="$1" message="$2"
  case "$mode" in
    done)
      printf '%s\t%s\t%s' '✅' '完成待命' "$DONE_SECS" ;;
    notify)
      if printf '%s' "$message" | grep -qi "$AUTH_PATTERN"; then
        printf '%s\t%s\t%s' '🔒' '等待授權' "$AUTH_SECS"
      else
        printf '%s\t%s\t%s' '⌨️' '需要你' "$INPUT_SECS"
      fi ;;
    *)
      printf '%s\t%s\t%s' '⌨️' '需要你' "$INPUT_SECS" ;;
  esac
}

format_label() {
  local name="$1" pid="$2" uuid="$3" project="$4" id_part
  if [ -n "$name" ]; then
    printf '%s — %s' "$name" "$project"
  else
    if [ -n "$pid" ]; then id_part="${pid: -4}"
    elif [ -n "$uuid" ]; then id_part="${uuid: -4}"
    else id_part="????"
    fi
    printf 'unnamed-%s — %s' "$id_part" "$project"
  fi
}

resolve_uuid() {
  local json="$1" uuid tp
  uuid="$(printf '%s' "$json" | jq -r '.session_id // empty' 2>/dev/null || true)"
  if [ -z "$uuid" ]; then
    tp="$(printf '%s' "$json" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
    [ -n "$tp" ] && uuid="$(basename "$tp" .jsonl)"
  fi
  printf '%s' "$uuid"
}

session_name_and_pid() {
  local uuid="$1" sessions_dir="${HOME}/.claude/sessions" f out
  if [ -z "$uuid" ] || [ ! -d "$sessions_dir" ]; then printf '\t'; return; fi
  for f in "$sessions_dir"/*.json; do
    [ -f "$f" ] || continue
    out="$(jq -r --arg uuid "$uuid" 'select(.sessionId == $uuid) | "\(.name // "")\t\(.pid // "")"' "$f" 2>/dev/null || true)"
    if [ -n "$out" ]; then printf '%s' "$out"; return; fi
  done
  printf '\t'
}

project_name() {
  local cwd="$1" branch="" base
  if [ -n "$cwd" ]; then
    branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  fi
  if [ -n "$branch" ] && [ "$branch" != "HEAD" ]; then printf '%s' "$branch"; return; fi
  if [ -n "$cwd" ]; then
    base="$(basename "$cwd")"
    if [ -n "$base" ] && [ "$base" != "." ]; then printf '%s' "$base"; return; fi
  fi
  printf 'unknown'
}

send_and_schedule() {
  local title="$1" body="$2" uuid="$3" delay="$4"
  local state_dir="${XDG_RUNTIME_DIR:-/tmp}/claude-notify" state_file="" old_id="" new_id
  if [ -n "$uuid" ]; then
    state_file="${state_dir}/${uuid}.id"
    [ -f "$state_file" ] && old_id="$(cat "$state_file" 2>/dev/null || true)"
  fi
  local -a replace_args=()
  [ -n "$old_id" ] && replace_args=(--replace-id "$old_id")
  new_id="$(notify-send -p --app-name "$APP_NAME" --urgency normal "${replace_args[@]}" -- "$title" "$body" 2>/dev/null || true)"
  if [ -n "$state_file" ] && [ -n "$new_id" ]; then
    mkdir -p "$state_dir" 2>/dev/null || true
    printf '%s' "$new_id" > "$state_file" 2>/dev/null || true
  fi
  if [ -n "$new_id" ] && [[ "$new_id" =~ ^[0-9]+$ ]] && command -v gdbus >/dev/null 2>&1; then
    setsid bash -c "sleep ${delay}; gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications --method org.freedesktop.Notifications.CloseNotification ${new_id}" </dev/null >/dev/null 2>&1 &
  fi
}

main() {
  set -euo pipefail
  local mode="${1:-notify}"
  command -v jq >/dev/null 2>&1 && command -v notify-send >/dev/null 2>&1 || exit 0
  local json_input cwd uuid np name pid project label message c icon word delay title body
  json_input="$(cat)"
  cwd="$(printf '%s' "$json_input" | jq -r '.cwd // empty' 2>/dev/null || true)"
  uuid="$(resolve_uuid "$json_input")"
  np="$(session_name_and_pid "$uuid")"
  name="${np%%$'\t'*}"
  pid="${np#*$'\t'}"
  project="$(project_name "$cwd")"
  label="$(format_label "$name" "$pid" "$uuid" "$project")"
  message=""
  if [ "$mode" != "done" ]; then
    message="$(printf '%s' "$json_input" | jq -r '.message // empty' 2>/dev/null || true)"
  fi
  c="$(classify "$mode" "$message")"
  icon="$(printf '%s' "$c" | cut -f1)"
  word="$(printf '%s' "$c" | cut -f2)"
  delay="$(printf '%s' "$c" | cut -f3)"
  title="${icon} ${word}：${label}"
  if [ "$mode" = "done" ]; then
    body="Claude Code 已完成並等待你的下一步"
  else
    body="${message:-需要你的注意}"
  fi
  send_and_schedule "$title" "$body" "$uuid" "$delay"
  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
