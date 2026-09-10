#!/usr/bin/env bash
# tools/epic-smoke/check.sh - Directory statistics script for epic-smoke
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

count_files() {
  local target_dir="$1"
  local full_path="$REPO_ROOT/$target_dir"
  local count=0

  if [[ -d "$full_path" ]]; then
    count=$(( $(find "$full_path" -type f -print0 | tr -cd '\0' | wc -c) ))
  fi

  echo "$count"
}

main() {
  local agents_count
  local skills_count
  local rules_count

  agents_count=$(count_files "agents")
  skills_count=$(count_files "skills")
  rules_count=$(count_files "rules")

  log_msg "agents: $agents_count"
  log_msg "skills: $skills_count"
  log_msg "rules: $rules_count"
}

main "$@"
