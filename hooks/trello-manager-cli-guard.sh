#!/usr/bin/env bash
# trello-manager-cli-guard.sh — Claude Code PreToolUse hook (Bash matcher).
# Enforces, at the permission layer, the trello-manager subagent's own
# declared boundary: it may only reach Trello through the trello CLI, never
# by calling the REST API directly or reading its credential file. The
# subagent's definition (agents/trello-manager.md) states this as its
# highest-priority rule, but permissions.deny is empty and Bash(curl:*) /
# Read(///**) are both allowed, so nothing upstream of this hook actually
# stops it. This hook is that enforcement point.
# Internal errors always end with exit 0 and no output, i.e. the call is
# allowed (the same fail-open stance as a missing jq). A non-zero/non-2 exit
# is only a non-blocking error for a PreToolUse hook by default, and with
# `onFailure: block` (set in agents/trello-manager.md) it would block the
# call, so this script never relies on that path. Timeouts and failures to
# start are what that frontmatter `onFailure: block` turns into a block.
# Target shell: bash 4.3+ (persistent script, repo compatibility floor).
set -euo pipefail

# Shown to the model whenever a call is denied for lack of a more specific
# reason (deny_reason_override below covers the nameable cases): every
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
SHAPE_MISMATCH_REASON='trello-manager 的 Bash 呼叫只有兩種形狀會被放行：(a) 單一、未串接其他指令的 trello CLI 呼叫（trello <子指令> ...；引號外不得出現 ; & | ` < > $ ( ) # 或換行，單引號內可含任何字元，自由文字請整段用單引號包住，內容裡的單引號寫成 '"'\\''"'），或 (b) 定義檔 Setup 段落規定的 cache-check 慣用寫法（test -f ~/.trello-cli/default/trello.db && echo "..." || trello sync）。這次呼叫不符合這兩種形狀中的任何一種，因此被擋下；判斷依據是整條指令的形狀，與指令名稱本身無關——即使是 command -v trello、which trello 這類單純查詢，只要不是以 trello 開頭的單一呼叫，一樣會被擋下，並不是這些指令名稱被列入黑名單。繞過 CLI 直接呼叫外部 API（如 curl、wget）、改用其他直譯器（python3、node、sh -c 等）達成同樣效果，或讀取 ~/.trello-cli/default/config.json 等憑證檔，同樣屬於這個規則會擋下的範圍。請改用對應的 trello 子指令完成這項操作。'

# Emits the PreToolUse deny decision as JSON on stdout. $1 is the reason
# shown to the model.
deny() {
  local reason="$1"
  jq -n --arg reason "$reason" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
}

# Upper bound, in bytes, on a trello-manager Bash command (see main()).
# Note the limit is enforced only after main() has read the whole payload
# with `raw="$(cat)"` and run it through jq, so an extremely large payload
# can still exhaust the hook's time budget before the check is reached; that
# case is turned into a block by `onFailure: block` in the agent frontmatter
# (agents/trello-manager.md), not by this script.
MAX_COMMAND_BYTES=65536

# True (exit 0) when $1 is longer than MAX_COMMAND_BYTES bytes. LC_ALL=C makes
# ${#1} count bytes rather than characters (CJK text is 3 bytes per char).
command_too_long() {
  local LC_ALL=C
  [[ ${#1} -gt $MAX_COMMAND_BYTES ]]
}

# Set by is_allowed_command (and the helpers it calls) when it denies a call
# for a specific, nameable reason (a special character outside quotes, an
# unclosed quote, an illegal or forbidden subcommand token) rather than a
# bare shape mismatch, so main() can surface that instead of the generic
# SHAPE_MISMATCH_REASON. Reset at the top of every is_allowed_command call;
# empty means "no override, caller should use the generic reason".
deny_reason_override=""

# Strips one layer of fully-wrapping matching quotes (both single or both
# double) from $1, so a quoted subcommand token (e.g. a double-quoted
# "interactive") is recognized the same as its unquoted form by the
# subcommand checks below. It deliberately strips only a *fully* wrapping
# pair: spliced or escaped spellings such as int"eractive" or inter\active
# are not reconstructed here — instead the subcommand check below only
# accepts a token made of [A-Za-z0-9:_-] after this strip, so any such
# spelling is rejected outright.
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

# Scans $1 left to right, tracking shell quoting state, and returns 1 (with
# deny_reason_override set) if it finds anything that could chain, pipe,
# substitute, or redirect. A plain regex over the whole string cannot tell a
# harmless backtick inside '...' from a live one, and stripping '...'
# fragments with a regex is bypassable (trello x \'; pwned; \' and
# trello x "it's" ; pwned ; echo '), so this is a real state machine:
#   outside quotes:  \ skips the next char (literal, even a newline);
#                    ' / " enter a quote state; ; & | ` < > $ ( ) # and a
#                    newline are rejected; anything else is fine.
#   inside '...':    only ' leaves the state; everything is literal.
#   inside "...":    \ skips the next char; " leaves the state; $ and `
#                    are rejected (they would still expand).
# Ending anywhere but outside quotes means an unclosed quote: rejected.
# An unquoted # is rejected because shells treat it as a comment up to the
# end of the line: a ' or " (or a \ before the newline) inside the comment
# would flip this scanner's quote state while the shell ignores it, letting
# a second line run as a separate command. Rejecting every unquoted #
# (not only at the start of a word) removes that whole class of desync.
# Parentheses outside quotes are rejected too: bash treats them as a syntax
# error after a plain trello call, but zsh gives them meaning (glob
# qualifiers *(e:...:), =(...), <(...); Claude Code's setopts neutralize
# only some of these), so they are refused instead of deciding case by case.
#
# Performance: bash's ${var:i:1} copies the whole value on every call, so a
# naive per-character loop is O(n^2) (30KB took ~10s in a UTF-8 locale, and
# even in the C locale 64KB takes seconds; the hook's timeout is 10s). So
# the string is cut into small chunks (cheap to index), and inside a chunk
# the scan jumps straight to the next character that matters for the
# current state with a pattern match instead of visiting every byte; a long
# single-quoted description is therefore skipped in a few steps. State
# carries across chunk boundaries, including a trailing backslash (skip).
# Runs with LC_ALL=C so chunk cuts are bytewise: every character this scan
# cares about is ASCII, and in UTF-8 no byte of a multibyte character is
# ever an ASCII byte, so a bytewise scan sees the same quote and special
# characters as a character-wise one.
scan_quoting() {
  local LC_ALL=C
  local cmd="$1" state=out skip=0 off=0 chunk_size=512 n len pos chunk rest pre c shown
  # Patterns (not regexes) of the characters that matter in each state.
  local out_special=$'[\\\\\'"#;&|`<>$()\n]'
  local dq_special='[\\"$`]'
  n=${#cmd}
  while [[ $off -lt $n ]]; do
    chunk="${cmd:off:chunk_size}"
    off=$((off + chunk_size))
    len=${#chunk}
    pos=0
    # A backslash that ended the previous chunk escapes this chunk's first byte.
    if [[ $skip -eq 1 ]]; then
      skip=0
      pos=1
    fi
    while [[ $pos -lt $len ]]; do
      rest="${chunk:pos}"
      case "$state" in
        out)
          # shellcheck disable=SC2295 # out_special is deliberately a glob pattern, not a literal
          pre="${rest%%$out_special*}"
          ;;
        single) pre="${rest%%\'*}" ;;
        double)
          # shellcheck disable=SC2295 # dq_special is deliberately a glob pattern, not a literal
          pre="${rest%%$dq_special*}"
          ;;
      esac
      # Nothing that matters in the rest of this chunk: on to the next chunk.
      [[ ${#pre} -lt ${#rest} ]] || break
      pos=$((pos + ${#pre}))
      c="${chunk:pos:1}"
      pos=$((pos + 1))
      # A backslash below advances pos once more; running past the chunk end
      # means the escaped byte is the next chunk's first one.
      case "$state" in
      out)
        case "$c" in
          \\) pos=$((pos + 1)) ;;
          "'") state=single ;;
          '"') state=double ;;
          '#')
            deny_reason_override="trello-manager 的 trello 呼叫在引號外出現了「#」，被擋下：引號外的 # 在詞首會被 shell 當成註解（直到該行結尾），讓後面的內容與實際執行的指令不一致；為避免判斷錯誤，引號外的 # 一律不放行。含 # 的文字（例如網址片段、Markdown 標題）請整段用單引號包住，單引號內的任何字元都會原樣當成字面值；內容裡若有單引號，寫成 '\\'' 。"
            return 1
            ;;
          ';' | '&' | '|' | '`' | '<' | '>' | '$' | '(' | ')' | $'\n')
            if [[ "$c" == $'\n' ]]; then shown="換行"; else shown="$c"; fi
            deny_reason_override="trello-manager 的 trello 呼叫在引號外出現了「${shown}」，被擋下：引號外的 ; & | \` < > \$ ( ) 與換行可用來串接指令、管線、重導向或做指令／變數替換，這條規則一律不放行。正確寫法：自由文字（描述、留言、名稱）整段用單引號包住，單引號內的任何字元（含換行、反引號、\$、|、;）都會原樣當成字面值；內容裡若有單引號，寫成 '\\'' 。每次只送一條 trello 指令，不要串接其他指令。"
            return 1
            ;;
        esac
        ;;
      single)
        # pre was cut at a quote, so c is the closing '.
        state=out
        ;;
      double)
        case "$c" in
          \\) pos=$((pos + 1)) ;;
          '"') state=out ;;
          '$' | '`')
            deny_reason_override="trello-manager 的 trello 呼叫在雙引號內出現了「${c}」，被擋下：雙引號內的 \$ 與反引號仍會被 shell 展開成指令或變數替換。請改用單引號把整段文字包住（單引號內任何字元都是字面值）；內容裡若有單引號，寫成 '\\'' 。"
            return 1
            ;;
        esac
        ;;
      esac
      [[ $pos -le $len ]] || skip=1
    done
  done
  if [[ "$state" != out ]]; then
    deny_reason_override="trello-manager 的 trello 呼叫有未閉合的引號，被擋下。請確認每個引號都成對；自由文字整段用單引號包住，內容裡的單引號寫成 '\\'' 。"
    return 1
  fi
  return 0
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
  deny_reason_override=""

  # (b) The exact cache-check idiom. This is the only shape allowed to
  # contain && / || literally, because everything except the echo message
  # is fixed. The message may vary in content but is restricted to a bare
  # double-quoted string with no ", \, $, or ` inside it, so it can neither
  # break out of the quotes nor smuggle in command substitution (e.g.
  # echo "$(curl ...)" is rejected because of the $). A command containing
  # a newline never takes this branch (the idiom is a one-liner), so (b)
  # behaves exactly as it did before the quote-aware scan below existed.
  local idiom_re='^test -f ~/\.trello-cli/default/trello\.db && echo "[^"\$`]*" \|\| trello sync$'
  if [[ "$cmd" != *$'\n'* && "$cmd" =~ $idiom_re ]]; then
    return 0
  fi

  # (a) A single "trello <args>" invocation. The whole string (not just a
  # substring) must start with the literal "trello" command, and must pass
  # the quote-aware scan: no unquoted shell metacharacter that could chain,
  # pipe, substitute, or redirect — that is what would let a second,
  # non-trello command ride along inside an otherwise-legitimate-looking
  # call. Inside single quotes anything goes (including newlines), which is
  # how free text such as a Markdown card description is passed, since
  # trello-cli only accepts it as a --description=<value> argument.
  # Claude Code runs the string via `zsh -c '... eval <command>'` with
  # NO_EXTENDED_GLOB and NO_BARE_GLOB_QUAL set, so zsh glob qualifiers such
  # as *(e:...:) cannot execute code (and their parentheses are rejected
  # by the scan anyway, along with # which both shells read as a comment).
  if [[ "$cmd" =~ ^trello([[:space:]].*)?$ ]]; then
    scan_quoting "$cmd" || return 1

    # Reject specific trello subcommands that pass the shape check above
    # but must never run from this hook regardless (confirmed against real
    # trello-cli 2.0.0):
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
    #     string, and a boolean. Re-checked against the 2.0.0 source.)
    #   - plugins and every plugins:* subcommand come from the bundled
    #     oclif plugin-plugins: plugins:install fetches an arbitrary package
    #     from npm and plugins:link loads a local directory, so either lets
    #     the CLI run arbitrary code — a way around the "only through the
    #     CLI" boundary.
    # Matched by *position* — the token immediately after "trello" — not by
    # scanning the whole string, so a card title or comment body that just
    # happens to contain the word "interactive" or "auth" elsewhere in the
    # command is unaffected.
    # Backslashes and quote splicing are legal outside quotes, so
    # plu\gins:install, int"eractive" or au\th:token would expand to a
    # forbidden subcommand in the shell. Hence that token (after stripping
    # one wrapping quote pair) may only consist of [A-Za-z0-9:_-]; a token
    # that is present but empty after the strip, or has any other
    # character, is rejected. A bare "trello" (no token) is fine.
    # A leading flag is NOT treated specially: `trello -- plugins` and
    # `trello --format json plugins` pass the whitelist above (the token is
    # `--` / `--format`) and are allowed. That is safe only because
    # trello-cli (oclif) takes the first token as the command name and
    # answers "command --format not found" (verified), so the later
    # `plugins` is never dispatched. If trello-cli ever skipped leading
    # flags to find the subcommand, this would become a bypass and the
    # position check here would need to skip flags too.
    # `read -ra` only sees the first line of $cmd. That is safe only
    # because (1) scan_quoting above already rejected every unquoted
    # newline, so a newline can only sit inside quotes, and (2) the
    # [A-Za-z0-9:_-] whitelist rejects any token starting with a quote or
    # containing a backslash, so a token cut off at the end of the first
    # line is denied rather than misread. Keep both premises if this
    # section or its order is ever changed.
    local words=()
    read -ra words <<< "$cmd"
    local subcmd=""
    if [[ ${#words[@]} -ge 2 ]]; then
      subcmd="$(strip_wrapping_quotes "${words[1]}")"
      local illegal_re='[^A-Za-z0-9:_-]'
      if [[ -z "$subcmd" || "$subcmd" =~ $illegal_re ]]; then
        # %q makes invisible characters (CR, tab, ...) visible in the reason.
        local shown_tok
        printf -v shown_tok '%q' "${words[1]}"
        deny_reason_override="trello-manager 的 trello 子指令位置（trello 後的第一個字）只能由英數字、:、_、- 組成，而且不能是空字串，這次的「${shown_tok}」不符，被擋下：用反斜線、引號拼接或夾帶其他字元的寫法（例如 plu\\gins、int\"eractive\"）在 shell 展開後可能變成被禁止的子指令，這條規則一律不放行。請直接寫出完整、未加跳脫的子指令名稱，例如 trello card:list。"
        return 1
      fi
    fi
    case "$subcmd" in
      interactive)
        deny_reason_override='trello-manager 不得執行 trello interactive：這會啟動完整的互動式終端 UI（TUI），在 Bash 呼叫中叫起它會卡住整個呼叫，且互動介面本來就不是這個 agent 該進入的操作方式。請改用對應操作的非互動子指令完成同樣的事。'
        return 1
        ;;
      auth:api-key | auth:token)
        deny_reason_override='trello-manager 不得執行 trello auth:api-key 或 trello auth:token：這兩個是 setter，會覆寫使用者已存放的 Trello 憑證，屬於對使用者資料的破壞性寫入，不在這個 agent 的職責範圍內。'
        return 1
        ;;
      plugins | plugins:*)
        deny_reason_override='trello-manager 不得執行 trello plugins 或任何 trello plugins:* 子指令（plugins:install、plugins:link 等）：這些會從 npm 安裝或連結外掛，讓 CLI 執行任意程式碼，等於繞過「只透過 trello CLI 操作 Trello」的邊界，不在這個 agent 的職責範圍內。請改用對應操作的內建 trello 子指令。'
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
  # would block all of that on any parse hiccup, not just trello-manager.
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

  # Cap the command size before any scanning so a huge command cannot eat
  # the hook's time budget (10s, see agents/trello-manager.md frontmatter).
  # Trello descriptions are at most 16384 characters, about 49152 bytes when
  # all CJK, so 65536 bytes leaves headroom for a legitimate call.
  if command_too_long "$command"; then
    deny "trello-manager 的 trello 指令過長（超過 ${MAX_COMMAND_BYTES} bytes），被擋下。Trello 描述上限為 16384 字元，請縮短內容，或把內容拆成多次 trello 呼叫（例如分段寫入留言）。"
    return
  fi

  is_allowed_command "$command" && return 0

  # is_allowed_command sets deny_reason_override when the denial has a
  # specific, actionable reason (a special character outside quotes, an
  # unclosed quote, a forbidden or malformed trello subcommand); fall back
  # to the generic reason otherwise.
  if [[ -n "$deny_reason_override" ]]; then
    deny "$deny_reason_override"
  else
    deny "$SHAPE_MISMATCH_REASON"
  fi
}

# Any unexpected failure inside main() must not surface as a non-zero exit:
# it ends as exit 0 with no output (allow), see the header comment.
main || true
exit 0
