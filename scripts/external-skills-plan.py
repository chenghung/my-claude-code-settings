#!/usr/bin/env python3
"""Turn the external-skills.jsonc manifest into a TSV install plan.

Usage: external-skills-plan.py <jsonc path> <repo path> <platform>...
Platforms are claude, codex, opencode and antigravity; repeat or reorder them
freely. Only the standard library is used.

On success the plan goes to stdout, one tab-separated record per line (values
inside a field are joined by a single space), in this order:

  group <repo> <agent ids> <skill names>
      skills of one repo that share the same set of selected agents; one
      `npx skills add` call per group
  want  <platform> <skill name>
      a skill expected on a selected platform
  known <skill name> <platforms>
      every skill in the manifest with its full platform list, selected or
      not; lets the caller recognise manifest skills when cleaning up

On a malformed manifest nothing is written to stdout, each problem is printed
to stderr as one `error: ...` line and the exit status is 1. A usage error
exits with 2.

The manifest is JSON with `//` and `/* */` comments (no trailing commas).
Comments are replaced by spaces and newlines are kept, so the line and column
that json reports for a syntax error match the original file.

A skill name must not equal a directory under <repo path>/skills/ or the
flattened name of a file under <repo path>/commands/ (install.sh's rule:
path relative to commands/, `/` -> `-`, trailing `.md` dropped), because
install.sh would link both into the same place.
"""
import json
import re
import sys
from pathlib import Path
from typing import Any

PLATFORMS = ("claude", "codex", "opencode", "antigravity")
AGENT_IDS = {
    "claude": "claude-code",
    "codex": "codex",
    "opencode": "opencode",
    "antigravity": "antigravity-cli",
}
USAGE = (
    "usage: external-skills-plan.py <jsonc path> <repo path> <platform>...\n"
    "platforms: " + " ".join(PLATFORMS)
)
WHITESPACE = re.compile(r"\s")


class ManifestError(Exception):
    """A manifest problem that is reported as a single `error:` line."""


def strip_comments(text: str) -> str:
    """Replace // and /* */ comments with spaces, keeping newlines and string
    contents (including // inside strings and escaped quotes) untouched."""
    out: list[str] = []
    i = 0
    n = len(text)
    in_string = False
    while i < n:
        c = text[i]
        if in_string:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 1
            elif c == '"':
                in_string = False
            i += 1
        elif c == '"':
            in_string = True
            out.append(c)
            i += 1
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                out.append(" ")
                i += 1
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            if end == -1:
                line = text.count("\n", 0, i) + 1
                column = i - (text.rfind("\n", 0, i) + 1) + 1
                raise ManifestError(
                    f"unterminated /* comment starting at line {line}, column {column}"
                )
            for ch in text[i:end + 2]:
                out.append("\n" if ch == "\n" else " ")
            i = end + 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def flattened_command_names(commands_dir: Path) -> set[str]:
    """Names install.sh gives to the files under commands/."""
    if not commands_dir.is_dir():
        return set()
    return {
        "-".join(p.relative_to(commands_dir).with_suffix("").parts)
        for p in commands_dir.rglob("*.md")
        if p.is_file()
    }


def skill_dir_names(skills_dir: Path) -> set[str]:
    if not skills_dir.is_dir():
        return set()
    return {p.name for p in skills_dir.iterdir() if p.is_dir()}


def validate(
    data: Any, repo_path: Path
) -> tuple[list[tuple[str, str, tuple[str, ...]]], list[str]]:
    """Return (entries, errors). Each entry is
    (name, repo, platforms tuple in fixed order)."""
    if not isinstance(data, list):
        return [], ["top level must be an array of skill objects"]

    local_names = skill_dir_names(repo_path / "skills") | flattened_command_names(
        repo_path / "commands"
    )
    errors: list[str] = []
    entries: list[tuple[str, str, tuple[str, ...]]] = []
    seen: set[str] = set()
    for index, item in enumerate(data, start=1):
        if not isinstance(item, dict):
            errors.append(f"entry {index}: must be an object")
            continue
        name = item.get("name")
        label = f"entry {index}" + (
            f' ("{name}")' if isinstance(name, str) and name.strip() else ""
        )
        texts: dict[str, str] = {}
        for field in ("name", "repo", "description"):
            value = item.get(field)
            if not isinstance(value, str) or not value.strip():
                errors.append(f"{label}: '{field}' is required and must be a non-empty string")
            else:
                texts[field] = value
        for field in ("name", "repo"):
            if field in texts and WHITESPACE.search(texts[field]):
                errors.append(f"{label}: '{field}' must not contain whitespace")
        if "name" in texts:
            if texts["name"] in seen:
                errors.append(f'{label}: duplicate name "{texts["name"]}"')
            seen.add(texts["name"])
            if texts["name"] in local_names:
                errors.append(
                    f'{label}: name "{texts["name"]}" collides with a local '
                    "skills/ directory or flattened commands/ name"
                )

        platforms = list(PLATFORMS)
        if "platforms" in item:
            raw = item["platforms"]
            if not isinstance(raw, list) or not raw:
                errors.append(f"{label}: 'platforms' must be a non-empty array")
            else:
                bad = [p for p in raw if not isinstance(p, str) or p not in PLATFORMS]
                for p in bad:
                    errors.append(
                        f"{label}: unknown platform {json.dumps(p)} in 'platforms' "
                        f"(expected one of: {' '.join(PLATFORMS)})"
                    )
                if not bad:
                    platforms = [p for p in PLATFORMS if p in raw]
        if "name" in texts and "repo" in texts:
            entries.append((texts["name"], texts["repo"], tuple(platforms)))
    return entries, errors


def build_plan(
    entries: list[tuple[str, str, tuple[str, ...]]], selected: set[str]
) -> list[str]:
    """Return the TSV lines: group, want, then known records."""
    groups: dict[tuple[str, tuple[str, ...]], list[str]] = {}
    want: list[str] = []
    known: list[str] = []
    for name, repo, platforms in entries:
        known.append(f"known\t{name}\t{' '.join(platforms)}")
        chosen = tuple(p for p in PLATFORMS if p in platforms and p in selected)
        if not chosen:
            continue
        groups.setdefault((repo, chosen), []).append(name)
        want.extend(f"want\t{p}\t{name}" for p in chosen)
    group_lines = [
        f"group\t{repo}\t{' '.join(AGENT_IDS[p] for p in chosen)}\t{' '.join(names)}"
        for (repo, chosen), names in groups.items()
    ]
    return group_lines + want + known


def main(argv: list[str]) -> int:
    if len(argv) < 4 or any(p not in PLATFORMS for p in argv[3:]):
        print(USAGE, file=sys.stderr)
        return 2
    jsonc_path = Path(argv[1])
    repo_path = Path(argv[2])
    selected = set(argv[3:])

    try:
        try:
            text = jsonc_path.read_text(encoding="utf-8")
        except OSError as exc:
            raise ManifestError(f"cannot read {jsonc_path}: {exc.strerror}") from exc
        try:
            data = json.loads(strip_comments(text))
        except json.JSONDecodeError as exc:
            raise ManifestError(
                f"{jsonc_path.name}: invalid JSON at line {exc.lineno}, "
                f"column {exc.colno}: {exc.msg}"
            ) from exc
    except ManifestError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    entries, errors = validate(data, repo_path)
    if errors:
        for message in errors:
            print(f"error: {jsonc_path.name}: {message}", file=sys.stderr)
        return 1

    for line in build_plan(entries, selected):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
