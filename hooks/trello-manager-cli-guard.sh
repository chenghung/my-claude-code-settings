#!/usr/bin/env bash
# trello-manager-cli-guard.sh — Claude Code PreToolUse hook (Bash matcher).
# Enforces, at the permission layer, the trello-manager subagent's own
# declared boundary: it may only reach Trello through the trello CLI, never
# by calling the REST API directly or reading its credential file. The
# subagent's definition (agents/trello-manager.md) states this as its
# highest-priority rule, but permissions.deny is empty and Bash(curl:*) /
# Read(///**) are both allowed, so nothing upstream of this hook actually
# stops it. This hook is that enforcement point.
# Must never exit non-zero (a failing hook would stall Claude Code).
# Target shell: bash 4.3+ (persistent script, repo compatibility floor).
set -euo pipefail

# Shown to the model whenever a call is denied for lack of a more specific
# reason (subcommand_deny_reason below covers the nameable cases): every
# such denial shares one root cause — the call didn't match either of the
# two allowed shapes — so this text leads with that mechanism rather than
# guessing at what the caller was attempting. Confirmed necessary by a real
# end-to-end run: trello-manager sent `command -v trello` (a harmless
# diagnostic, not an API bypass or a credential read), got denied here, and
# an earlier version of this text — which described only the bypass/
# credential-read examples now folded in below — led the model to wrongly
# conclude that `command`/`which` were blacklisted by name. The mechanism
# statement and the explicit `command -v`/`which` example exist specifically
# to close off that wrong inference; the bypass/credential-read examples are
# kept as illustrative context (they are still denied here too), not as a
# claim about what this particular call did.
SHAPE_MISMATCH_REASON='trello-manager 的 Bash 呼叫只有兩種形狀會被放行：(a) 單一、未串接其他指令的 trello CLI 呼叫（trello <子指令> ...），或 (b) 定義檔 Setup 段落規定的 cache-check 慣用寫法（test -f ~/.trello-cli/default/trello.db && echo "..." || trello sync）。這次呼叫不符合這兩種形狀中的任何一種，因此被擋下；判斷依據是整條指令的形狀，與指令名稱本身無關——即使是 command -v trello、which trello 這類單純查詢，只要不是以 trello 開頭的單一呼叫，一樣會被擋下，並不是這些指令名稱被列入黑名單。繞過 CLI 直接呼叫外部 API（如 curl、wget）、改用其他直譯器（python3、node、sh -c 等）達成同樣效果，或讀取 ~/.trello-cli/default/config.json 等憑證檔，同樣屬於這個規則會擋下的範圍。請改用對應的 trello 子指令完成這項操作。'

# Emits the PreToolUse deny decision as JSON on stdout. $1 is the reason
# shown to the model.
deny() {
  local reason="$1"
  jq -n --arg reason "$reason" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
}

# Set by is_allowed_command when it denies a call for a specific, nameable
# reason (a recognized-but-forbidden trello subcommand) rather than a bare
# shape mismatch, so main() can surface that instead of the generic
# SHAPE_MISMATCH_REASON. Reset at the top of every is_allowed_command call;
# empty means "no override, caller should use the generic reason".
subcommand_deny_reason=""

# Strips one layer of fully-wrapping matching quotes (both single or both
# double) from $1, so a quoted subcommand token (e.g. a double-quoted
# "interactive") is recognized the same as its unquoted form by the
# subcommand checks below. This does not reconstruct full shell
# quote/escape parsing (e.g. adjacent quote-splicing like int"eractive" or
# backslash-escaping like inter\active would still evade it) — out of
# scope for this allowlist-style matcher, which targets shapes a model
# would plausibly produce, not deliberate obfuscation.
strip_wrapping_quotes() {
  local tok="$1"
  if [[ ${#tok} -ge 2 ]]; then
    if [[ "${tok:0:1}" == '"' && "${tok: -1}" == '"' ]]; then
      tok="${tok:1:${#tok}-2}"
    elif [[ "${tok:0:1}" == "'" && "${tok: -1}" == "'" ]]; then
      tok="${tok:1:${#tok}-2}"
    fi
  fi
  printf '%s' "$tok"
}

# True (exit 0) when $1 is exactly one of the two shapes trello-manager is
# allowed to run:
#   (a) a single, unchained "trello <args>" invocation whose subcommand is
#       not on the forbidden list below, or
#   (b) the cache-check idiom from the subagent's own Setup section
#       (test -f ~/.trello-cli/default/trello.db && echo "..." || trello sync)
# This is an allowlist, not a blacklist: anything that doesn't confidently
# match one of these two shapes is rejected, including compound commands,
# pipelines, command/process substitution, redirection, or a command that
# merely mentions the word "trello" as an argument rather than being one.
is_allowed_command() {
  local cmd="$1"
  subcommand_deny_reason=""

  # A literal newline would let a second line run as a separate statement
  # when Claude Code executes this string via `bash -c`. Neither allowed
  # shape legitimately spans lines, so reject outright before shape-matching.
  [[ "$cmd" == *$'\n'* ]] && return 1

  # (b) The exact cache-check idiom. This is the only shape allowed to
  # contain && / || literally, because everything except the echo message
  # is fixed. The message may vary in content but is restricted to a bare
  # double-quoted string with no ", \, $, or ` inside it, so it can neither
  # break out of the quotes nor smuggle in command substitution (e.g.
  # echo "$(curl ...)" is rejected because of the $).
  local idiom_re='^test -f ~/\.trello-cli/default/trello\.db && echo "[^"\$`]*" \|\| trello sync$'
  if [[ "$cmd" =~ $idiom_re ]]; then
    return 0
  fi

  # (a) A single "trello <args>" invocation. The whole string (not just a
  # substring) must start with the literal "trello" command, and must not
  # contain any shell metacharacter that could chain, pipe, substitute, or
  # redirect — that is what would let a second, non-trello command ride
  # along inside an otherwise-legitimate-looking call.
  if [[ "$cmd" =~ ^trello([[:space:]].*)?$ ]]; then
    local disallowed_re='[;&|`<>$]'
    [[ "$cmd" =~ $disallowed_re ]] && return 1

    # Reject specific trello subcommands that pass the shape check above
    # but must never run from this hook regardless (confirmed against real
    # trello-cli 1.8.0):
    #   - interactive launches a full-screen TUI; calling it from a Bash
    #     tool call would hang that call, and it isn't a surface this
    #     subagent should be driving anyway.
    #   - auth:api-key / auth:token are setters that overwrite the user's
    #     stored Trello credentials — a destructive write this agent has
    #     no legitimate reason to perform. (No other subcommand prints
    #     stored credentials, so no further denylisting is needed there:
    #     the only credential readers in trello-cli are BaseCommand, which
    #     builds the API client, and interactive, and neither prints them;
    #     `trello debug` only emits the config dir, profile name, authType
    #     string, and a boolean.)
    # Matched by *position* — the token immediately after "trello" — not by
    # scanning the whole string, so a card title or comment body that just
    # happens to contain the word "interactive" or "auth" elsewhere in the
    # command is unaffected.
    local words=()
    read -ra words <<< "$cmd"
    local subcmd
    subcmd="$(strip_wrapping_quotes "${words[1]:-}")"
    case "$subcmd" in
      interactive)
        subcommand_deny_reason='trello-manager 不得執行 trello interactive：這會啟動完整的互動式終端 UI（TUI），在 Bash 呼叫中叫起它會卡住整個呼叫，且互動介面本來就不是這個 agent 該進入的操作方式。請改用對應操作的非互動子指令完成同樣的事。'
        return 1
        ;;
      auth:api-key | auth:token)
        subcommand_deny_reason='trello-manager 不得執行 trello auth:api-key 或 trello auth:token：這兩個是 setter，會覆寫使用者已存放的 Trello 憑證，屬於對使用者資料的破壞性寫入，不在這個 agent 的職責範圍內。'
        return 1
        ;;
    esac

    return 0
  fi

  return 1
}

main() {
  local raw agent_id agent_type command

  # This hook is entirely jq-driven. If jq isn't available we cannot parse
  # the payload at all, so we cannot even tell whether this call belongs to
  # trello-manager; fail open rather than block every Bash call system-wide
  # for an unrelated missing dependency (same precedent as prompt-file-guard.sh).
  command -v jq >/dev/null 2>&1 || return 0

  raw="$(cat)"

  # This hook is now registered via agents/trello-manager.md's own
  # frontmatter `hooks` field rather than a global settings.json Bash
  # matcher, so in the common case every invocation already belongs to
  # this subagent. The agent_id/agent_type identity check below is kept
  # anyway: there is no confirmed guarantee that frontmatter-scoped hook
  # registration limits firing to that one agent, so this check remains
  # cheap defense-in-depth against that unverified assumption — and it is
  # what would still protect other agents/the main thread if this hook is
  # ever wired back into a global Bash matcher.
  #
  # Unparseable/missing identity fields mean we cannot tell whether this
  # Bash call belongs to trello-manager at all. This hook's matcher is Bash,
  # so it fires for every agent and the main thread too; failing closed here
  # would stall all of that on any parse hiccup, not just trello-manager.
  # Fail OPEN in this branch only — the policy flips once identity below is
  # actually confirmed.
  #
  # agent_id and agent_type are read in a single jq call (was two separate
  # invocations) to avoid spawning jq twice per hook trigger. @tsv escapes
  # any embedded tab/newline within a field as a literal backslash
  # sequence rather than a raw byte, so splitting the result on a literal
  # tab below always yields exactly two fields regardless of field content.
  local identity
  if ! identity=$(jq -r '[(.agent_id // ""), (.agent_type // "")] | @tsv' <<< "$raw" 2>/dev/null); then
    return 0
  fi
  IFS=$'\t' read -r agent_id agent_type <<< "$identity"

  # Only intervene for a confirmed trello-manager subagent call (agent_id
  # present AND agent_type is exactly "trello-manager"). Main-thread calls
  # (no agent_id) and other subagents pass through silently, per contract.
  [[ -n "$agent_id" ]] || return 0
  [[ "$agent_type" == "trello-manager" ]] || return 0

  # From here on the call is confirmed to be trello-manager's. Unlike above,
  # any further uncertainty must now resolve to deny, not silence: this
  # subagent's entire legitimate workload fits in the two shapes checked by
  # is_allowed_command, so a false deny only costs it one stop-and-report,
  # far cheaper than a false allow of a credential or API bypass.
  if ! command=$(jq -r '.tool_input.command // empty' <<< "$raw" 2>/dev/null); then
    deny "$SHAPE_MISMATCH_REASON"
    return
  fi
  if [[ -z "$command" ]]; then
    deny "$SHAPE_MISMATCH_REASON"
    return
  fi

  is_allowed_command "$command" && return 0

  # is_allowed_command sets subcommand_deny_reason when the denial has a
  # specific, actionable reason (a recognized-but-forbidden trello
  # subcommand); fall back to the generic reason otherwise.
  if [[ -n "$subcommand_deny_reason" ]]; then
    deny "$subcommand_deny_reason"
  else
    deny "$SHAPE_MISMATCH_REASON"
  fi
}

# Any unexpected failure inside main() must not surface as a non-zero exit;
# this hook must never stall or block Claude Code.
main || true
exit 0
