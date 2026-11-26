#!/usr/bin/env bash
# graphiti-memory-context.sh - Claude Code SessionStart hook.
#
# When the local Graphiti MCP server (services/graphiti/) answers its health
# check, print the long-term-memory instructions: Claude Code adds a
# SessionStart hook's plain stdout (exit 0) to the session context. When the
# server is down, print nothing, so the agent is never told to use tools that
# are not reachable.
#
# stdin: the hook's JSON input; only `cwd` is read (falls back to $PWD).
# Project group: basename of the repo's main worktree, so every worktree of a
# repo shares one group, with each byte outside A-Za-z0-9_- replaced by '-'
# (graphiti-core accepts only ^[a-zA-Z0-9_-]+$). Outside a git repo only the
# shared `personal` group is offered.
# Always exits 0: a memory hint must never block a session.
set -uo pipefail

input="$(cat 2>/dev/null || true)"

curl -fsS --max-time 1 http://127.0.0.1:8000/health > /dev/null 2>&1 || exit 0

cwd=""
if command -v jq > /dev/null 2>&1; then
  cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
fi
[ -n "$cwd" ] || cwd="$PWD"

project_group=""
main_worktree="$(git -C "$cwd" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
if [ -n "$main_worktree" ]; then
  project_group="$(printf '%s' "${main_worktree##*/}" | LC_ALL=C tr -c 'A-Za-z0-9_-' '-')"
fi

if [ -n "$project_group" ]; then
  groups="- project: \`${project_group}\`
- cross-project: \`personal\`"
  search_groups="both groups above"
  group_rule="facts that hold only for this project go to the project group;
cross-project personal preferences, working habits and tool knowledge go to \`personal\`."
else
  groups="- cross-project: \`personal\`"
  search_groups="\`personal\`"
  group_rule="cross-project personal preferences, working habits and tool knowledge go to \`personal\`."
fi

cat <<EOF
## Graphiti long-term memory

The graphiti MCP tools are available. Groups for this session:
${groups}

**Search**: when starting a task where past decisions, preferences or conventions
could change the approach, call \`search_memory_facts\` / \`search_nodes\` with
\`group_ids\` set to ${search_groups}. Memory can be stale: when it conflicts with
the current code or files, the files win.

**Write** with \`add_memory\` when:
- the user makes or confirms a decision, or states a preference
- you establish a non-obvious fact (environment quirk, root cause, actual behavior of an external tool)
- a task finishes: record its conclusion and open questions

**Confirm each write**: \`add_memory\` only queues the episode, and a failed write
(e.g. exhausted API credits) shows up only in the server log. After writing, and
before finishing the task, call \`get_episodes\` for that group to confirm the new
episode is listed (processing takes a few seconds). If it is missing,
tell the user the memory was not saved.

**Do not write**: code content readable from the repo, rules already in CLAUDE.md or
rules files, transient state, any key, token, password or other people's personal data.

**Group**: ${group_rule}

**Format**: \`name\` is a one-line title; \`group_id\` is one of the groups above;
\`episode_body\` is written in English, readable on its own, and states the subject
and the date; \`source\` is \`text\`.
EOF
exit 0
