#!/usr/bin/env bash
# notify-cc.sh — Claude Code hook: send desktop notification via notify-send.
# Called by Claude Code hook system; receives JSON on stdin, mode string as $1.
# Target shell: bash (Claude Code hooks run under bash).
#
# Usage: echo '<json>' | notify-cc.sh <done|notify>
#
# IMPORTANT: This script must never exit non-zero; a failing hook would stall
# Claude Code. All error paths end with "exit 0".

set -euo pipefail

# ---------------------------------------------------------------------------
# Dependency check — silently exit if jq or notify-send are unavailable.
# ---------------------------------------------------------------------------
if ! command -v jq > /dev/null 2>&1 || ! command -v notify-send > /dev/null 2>&1; then
    exit 0
fi

# ---------------------------------------------------------------------------
# Read full stdin into a variable before any processing.
# ---------------------------------------------------------------------------
json_input="$(cat)"

# ---------------------------------------------------------------------------
# Extract cwd for use in git-branch and folder-name fallbacks.
# ---------------------------------------------------------------------------
cwd="$(printf '%s' "$json_input" | jq -r '.cwd // empty' 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# Determine label via three-tier priority:
#   1. /rename session name  (looked up from ~/.claude/sessions/*.json)
#   2. git branch of cwd
#   3. basename of cwd  (final fallback → "unknown")
# ---------------------------------------------------------------------------

# --- Priority 1: session rename name ---
label=""

# Obtain the session UUID: prefer session_id field, fall back to transcript_path basename.
session_uuid="$(printf '%s' "$json_input" | jq -r '.session_id // empty' 2>/dev/null || true)"
if [ -z "$session_uuid" ]; then
    transcript_path="$(printf '%s' "$json_input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
    if [ -n "$transcript_path" ]; then
        # Strip directory and .jsonl suffix to recover the UUID.
        session_uuid="$(basename "$transcript_path" .jsonl)"
    fi
fi

sessions_dir="${HOME}/.claude/sessions"

if [ -n "$session_uuid" ] && [ -d "$sessions_dir" ]; then
    # Scan every *.json in the sessions directory with a single jq invocation.
    # For each file whose .sessionId matches the target UUID, emit .name (skip nulls).
    # The glob may produce no matches; use nullglob-safe approach: iterate and check.
    rename_name=""
    for f in "$sessions_dir"/*.json; do
        # If glob finds nothing, the literal pattern string is passed — skip it.
        [ -f "$f" ] || continue
        # jq: select the file whose sessionId matches, then emit .name only if non-null.
        candidate="$(jq -r --arg uuid "$session_uuid" \
            'select(.sessionId == $uuid) | .name // empty' \
            "$f" 2>/dev/null || true)"
        if [ -n "$candidate" ]; then
            rename_name="$candidate"
            break
        fi
    done
    label="$rename_name"
fi

# --- Priority 2: git branch ---
if [ -z "$label" ] && [ -n "$cwd" ]; then
    branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    # Detached HEAD yields "HEAD" — treat that as no result.
    if [ -n "$branch" ] && [ "$branch" != "HEAD" ]; then
        label="$branch"
    fi
fi

# --- Priority 3: cwd basename (final fallback) ---
if [ -z "$label" ]; then
    if [ -n "$cwd" ]; then
        label="$(basename "$cwd")"
        # basename on an empty or root-like string may return "." — guard that.
        if [ "$label" = "." ] || [ -z "$label" ]; then
            label="unknown"
        fi
    else
        label="unknown"
    fi
fi

# ---------------------------------------------------------------------------
# Resolve mode; default to "notify" for any unrecognised value.
# ---------------------------------------------------------------------------
mode="${1:-notify}"

case "$mode" in
    done)
        title="✅ 執行完畢：${label}"
        body="Claude Code 已完成並等待你的下一步"
        ;;
    notify)
        raw_message="$(printf '%s' "$json_input" | jq -r '.message // empty' 2>/dev/null || true)"
        body="${raw_message:-需要你的注意}"
        title="🔔 ${label}"
        ;;
    *)
        # Unknown mode: treat as notify with a generic body.
        raw_message="$(printf '%s' "$json_input" | jq -r '.message // empty' 2>/dev/null || true)"
        body="${raw_message:-需要你的注意}"
        title="🔔 ${label}"
        ;;
esac

# ---------------------------------------------------------------------------
# Send the notification; suppress any error so the hook never blocks CC.
# ---------------------------------------------------------------------------
notify-send \
    --app-name "Claude Code" \
    --urgency normal \
    --expire-time 5000 \
    -- "$title" "$body" 2>/dev/null || true

exit 0
