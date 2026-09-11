#!/usr/bin/env bash
# herdr-agent-team-investigator-guard.sh — Claude Code PreToolUse hook (Bash
# matcher). Enforces, at the permission layer, the herdr-agent-team-
# investigator subagent's own declared boundary: it is read-only and
# dispose-after-use, dispatched by the herdr-agent-team orchestrator
# specifically so screen/detail material never enters the orchestrator's own
# context. The subagent's definition
# (agents/herdr-agent-team-investigator.md) states this boundary in its Out
# of Scope section and says outright that nothing technical enforces it
# ("以上邊界沒有任何技術機制在背後強制執行... 邊界完全靠這份定義檔的文字
# 對模型的約束力生效") — its `tools` field grants full Bash, and
# permissions.deny is empty. This hook is that enforcement point.
#
# ---- Enumeration always goes through team-status.sh; only point-reads use
#      the raw herdr command ----
# `herdr agent list` and `herdr api snapshot` are deliberately NOT on the
# allowlist below, even though both are read-only. Their raw response
# carries the terminal_title/terminal_title_stripped fields (verbatim
# model/user output) that this whole design exists to keep out of the
# investigator's own context, and both are server-wide — they return every
# team's agents, not just this workspace's. team-status.sh already exists
# specifically to close this hole: it projects the response down to a fixed
# field whitelist and filters to this workspace before the investigator
# ever sees it, and it is already on the allowlist below. Any enumeration
# need should go through team-status.sh; the raw `herdr agent get`/`herdr
# agent read`/`herdr pane read` stay allowed only because they are
# point-reads of a single target the main agent already named and
# authorized — seeing that one target's title is not an escalation, seeing
# the whole server's is. Do not re-add `agent list`/`api snapshot` to the
# allowlist for convenience without re-deriving this boundary.
# Must never exit non-zero (a failing hook would stall Claude Code).
# Target shell: bash 4.3+ (persistent script, repo compatibility floor).
set -euo pipefail

# Shown to the model whenever a call is denied for lack of a more specific
# reason (subcommand_deny_reason below covers the nameable cases): every
# such denial shares one root cause — the call didn't match any of the
# allowed read-only shapes — so this text leads with that mechanism.
# shellcheck disable=SC2016 # single quotes are intentional: the literal
# $(...) shown to the model is illustrative text, not meant to expand.
SHAPE_MISMATCH_REASON='herdr-agent-team-investigator 的 Bash 呼叫只放行唯讀查詢：herdr 的 agent get／agent read／pane read（列舉性查詢一律改用 team-status.sh，不直接放行 herdr agent list／herdr api snapshot——原始回應帶著終端標題等原文欄位，且涵蓋整台伺服器其他團隊），gh 的 issue view／pr view／pr diff，以及這個 skill 自己腳本裡的 team-status.sh／fetch-detail.sh 兩支唯讀腳本；且必須是單一、未串接其他指令的呼叫。這次呼叫不符合上述任何一種允許的形狀，因此被擋下。判斷依據是整條指令的形狀與指令名稱，管線、分號、&&、||、指令替換（$(...) 或反引號）、輸出或輸入重導向都會讓呼叫被視為不符合「單一未串接指令」而一律拒絕，不論夾帶在其中的是否原本合法。任何形式的寫檔、對外網路呼叫（curl、wget）、以及會改變 herdr 或這個 skill 狀態的操作（例如 agent prompt、agent send-keys、tab close、tab create、agent start、agent rename，或 instruct.sh／press-approval.sh／shutdown-worker.sh／send-peer.sh／grant-peer.sh／launch-worker.sh／set-worker-field.sh／report.sh 這幾支腳本）一律不在允許範圍內。需要執行被禁止的操作時，請回報 main agent（orchestrator），由其決定後續處理，不得自行執行。'

# Emits the PreToolUse deny decision as JSON on stdout. $1 is the reason
# shown to the model.
deny() {
  local reason="$1"
  jq -n --arg reason "$reason" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
}

# Set by is_allowed_command when it denies a call for a specific, nameable
# reason (a recognized-but-forbidden herdr subcommand, skill script, or
# network tool) rather than a bare shape mismatch, so main() can surface
# that instead of the generic SHAPE_MISMATCH_REASON. Reset at the top of
# every is_allowed_command call; empty means "no override, caller should use
# the generic reason".
subcommand_deny_reason=""

# Strips one layer of fully-wrapping matching quotes (both single or both
# double) from $1, so a quoted token is recognized the same as its unquoted
# form by the checks below. Does not reconstruct full shell quote/escape
# parsing — out of scope for this allowlist-style matcher, which targets
# shapes a model would plausibly produce, not deliberate obfuscation (same
# scope note as hooks/trello-manager-cli-guard.sh's copy of this helper).
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

# hat_guard_script_shape <basename>
# True (exit 0) when <basename> is one of this skill's two read-only
# scripts. Sets subcommand_deny_reason and returns 1 for a recognized write-
# capable script from this skill's own scripts/ directory; returns 1 with no
# reason set for anything else (bare shape mismatch — e.g. a script from
# outside this skill entirely).
hat_guard_script_shape() {
  local base="$1"
  case "$base" in
    team-status.sh | fetch-detail.sh)
      return 0 ;;
    instruct.sh | press-approval.sh | shutdown-worker.sh | send-peer.sh | \
      grant-peer.sh | launch-worker.sh | set-worker-field.sh | report.sh)
      subcommand_deny_reason="herdr-agent-team-investigator 不得執行 $base：這支腳本會下行、代按、關閉資源或改變 registry 狀態，只有唯讀的 team-status.sh／fetch-detail.sh 在允許範圍內。"
      return 1 ;;
    *)
      return 1 ;;
  esac
}

# True (exit 0) when $1 is exactly one of the read-only shapes
# herdr-agent-team-investigator is allowed to run. This is an allowlist, not
# a blacklist: anything that doesn't confidently match one of these shapes
# is rejected, including compound commands, pipelines, command/process
# substitution, redirection, or a command that merely mentions one of the
# allowed names as an argument rather than being one.
is_allowed_command() {
  local cmd="$1"
  subcommand_deny_reason=""

  # A literal newline would let a second line run as a separate statement
  # when Claude Code executes this string via `bash -c`. No allowed shape
  # legitimately spans lines, so reject outright before shape-matching.
  [[ "$cmd" == *$'\n'* ]] && return 1

  # The whole string (not just a substring) must be a single, unchained
  # command: any of these metacharacters would let a second command ride
  # along inside an otherwise-legitimate-looking call, smuggle input via
  # substitution, or write output to a file via redirection.
  local disallowed_re='[;&|`<>$]'
  [[ "$cmd" =~ $disallowed_re ]] && return 1

  local -a words
  read -ra words <<< "$cmd"
  local first second third
  first="$(strip_wrapping_quotes "${words[0]:-}")"
  second="$(strip_wrapping_quotes "${words[1]:-}")"
  third="$(strip_wrapping_quotes "${words[2]:-}")"

  case "$first" in
    herdr)
      # Matched by *position* (the two tokens immediately after "herdr"),
      # not by scanning the whole string, so an argument that happens to
      # contain one of these words elsewhere is unaffected.
      case "$second $third" in
        "agent get" | "agent read" | "pane read")
          return 0 ;;
        "agent list" | "api snapshot")
          # Deliberately excluded even though read-only — see header
          # "Enumeration always goes through team-status.sh" note.
          subcommand_deny_reason="herdr-agent-team-investigator 不得執行 herdr $second $third：這兩個列舉性子指令的原始回應帶著終端標題等模型／使用者原文欄位，且涵蓋整台伺服器其他團隊的 agent，會讓調查者自己的 context 重建本該被過濾掉的材料。列舉需求請改用已經過白名單欄位投影與 workspace 過濾的 team-status.sh（已在允許清單上）；只有針對 main agent 指名目標的定點讀取（agent get／agent read／pane read）留在允許範圍內。"
          return 1 ;;
        "agent prompt" | "agent send-keys" | "tab close" | "tab create" | \
          "agent start" | "agent rename")
          subcommand_deny_reason="herdr-agent-team-investigator 不得執行 herdr $second $third：這是會改變 agent、pane 或 tab 狀態的操作，只有查狀態、讀畫面這類唯讀子指令在允許範圍內。"
          return 1 ;;
        *)
          return 1 ;;
      esac
      ;;
    gh)
      case "$second $third" in
        "issue view" | "pr view" | "pr diff")
          return 0 ;;
        *)
          return 1 ;;
      esac
      ;;
    curl | wget)
      subcommand_deny_reason="herdr-agent-team-investigator 不得執行 $first：對外網路呼叫可以把讀到的內容外送到任意端點，繞過只回傳結論的出口約束。"
      return 1 ;;
    bash | sh)
      hat_guard_script_shape "${second##*/}"
      return $?
      ;;
    *)
      hat_guard_script_shape "${first##*/}"
      return $?
      ;;
  esac
}

main() {
  local raw agent_id agent_type command

  # This hook is entirely jq-driven. If jq isn't available we cannot parse
  # the payload at all, so we cannot even tell whether this call belongs to
  # herdr-agent-team-investigator; fail open rather than block every Bash
  # call system-wide for an unrelated missing dependency (same precedent as
  # hooks/trello-manager-cli-guard.sh and hooks/prompt-file-guard.sh).
  command -v jq >/dev/null 2>&1 || return 0

  raw="$(cat)"

  # This hook is registered via agents/herdr-agent-team-investigator.md's
  # own frontmatter `hooks` field rather than a global settings.json Bash
  # matcher, so in the common case every invocation already belongs to this
  # subagent. The agent_id/agent_type identity check below is kept anyway:
  # there is no confirmed guarantee that frontmatter-scoped hook
  # registration limits firing to that one agent, so this check remains
  # cheap defense-in-depth against that unverified assumption — and it is
  # what would still protect other agents/the main thread if this hook is
  # ever wired back into a global Bash matcher.
  #
  # Unparseable/missing identity fields mean we cannot tell whether this
  # Bash call belongs to herdr-agent-team-investigator at all. This hook's
  # matcher is Bash, so it fires for every agent and the main thread too;
  # failing closed here would stall all of that on any parse hiccup, not
  # just this subagent. Fail OPEN in this branch only — the policy flips
  # once identity below is actually confirmed.
  local identity
  if ! identity=$(jq -r '[(.agent_id // ""), (.agent_type // "")] | @tsv' <<< "$raw" 2>/dev/null); then
    return 0
  fi
  IFS=$'\t' read -r agent_id agent_type <<< "$identity"

  # Only intervene for a confirmed herdr-agent-team-investigator subagent
  # call (agent_id present AND agent_type is exactly
  # "herdr-agent-team-investigator"). Main-thread calls (no agent_id) and
  # other subagents pass through silently, per contract.
  [[ -n "$agent_id" ]] || return 0
  [[ "$agent_type" == "herdr-agent-team-investigator" ]] || return 0

  # From here on the call is confirmed to be this subagent's. Unlike above,
  # any further uncertainty must now resolve to deny, not silence: this
  # subagent's entire legitimate workload fits in the shapes checked by
  # is_allowed_command, so a false deny only costs it one stop-and-report,
  # far cheaper than a false allow of a write, a network call, or a leak.
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
  # specific, actionable reason (a recognized-but-forbidden herdr
  # subcommand, skill script, or network tool); fall back to the generic
  # reason otherwise.
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
