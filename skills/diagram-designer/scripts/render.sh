#!/usr/bin/env bash
set -euo pipefail

# render.sh <diagram_type> [--docker]
# Reads DSL source from stdin. Renders a preview and prints ONE openable
# target to stdout:
#   - local render succeeded -> absolute path to a temp SVG file
#   - fell back to remote     -> https://kroki.io/<type>/svg/<encoded>
# stderr reports which tier produced the output.
# Exit non-zero only if every tier fails; exit 2 on argument error.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENCODER="$SCRIPT_DIR/kroki-encode.py"

use_docker=0
diagram_type=""
for arg in "$@"; do
  case "$arg" in
    --docker)
      use_docker=1
      ;;
    -*) echo "render.sh: unknown flag $arg" >&2; exit 2 ;;
    *)  diagram_type="$arg" ;;
  esac
done
[ -n "$diagram_type" ] || { echo "render.sh: missing <diagram_type>" >&2; exit 2; }

# Temp dir: main agent passes DIAGRAM_TMP_DIR resolved to the workspace .tmp
# (per tmp-file-usage rule); otherwise use a throwaway system temp dir.
tmp_dir="${DIAGRAM_TMP_DIR:-$(mktemp -d)}"
mkdir -p "$tmp_dir"
tmp_dir="$(cd "$tmp_dir" && pwd)"
src="$tmp_dir/diagram-src.$$"
out="$tmp_dir/diagram-preview.$$.svg"
cat > "$src"

# --- Tier 1: native local CLI (falls through on missing tool or render error) ---
native_render() {
  case "$diagram_type" in
    mermaid)  command -v mmdc >/dev/null 2>&1 && mmdc -i "$src" -o "$out"        >/dev/null 2>&1 ;;
    d2)       command -v d2   >/dev/null 2>&1 && d2 "$src" "$out"                >/dev/null 2>&1 ;;
    graphviz) command -v dot  >/dev/null 2>&1 && dot -Tsvg -o "$out" "$src"      >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}
if native_render && [ -s "$out" ]; then
  echo "render.sh: rendered locally via native CLI ($diagram_type)" >&2
  echo "$out"; exit 0
fi

# --- Tier 2: local docker kroki (opt-in; falls through if unreachable) ---
KROKI_LOCAL_URL="${KROKI_LOCAL_URL:-http://localhost:8000}"
if [ "$use_docker" -eq 1 ]; then
  if curl -sf -o /dev/null "$KROKI_LOCAL_URL/health" 2>/dev/null \
     && curl -sf -X POST "$KROKI_LOCAL_URL/$diagram_type/svg" --data-binary @"$src" -o "$out" 2>/dev/null \
     && [ -s "$out" ]; then
    echo "render.sh: rendered locally via docker kroki ($diagram_type)" >&2
    echo "$out"; exit 0
  fi
  echo "render.sh: docker kroki unavailable, falling back to remote" >&2
fi

# --- Tier 3: remote kroki.io ---
command -v python3 >/dev/null 2>&1 || { echo "render.sh: python3 unavailable for remote encoding" >&2; exit 1; }
encoded="$(python3 "$ENCODER" < "$src")" || { echo "render.sh: kroki-encode.py failed" >&2; exit 1; }
echo "render.sh: using remote kroki.io ($diagram_type)" >&2
echo "https://kroki.io/$diagram_type/svg/$encoded"
