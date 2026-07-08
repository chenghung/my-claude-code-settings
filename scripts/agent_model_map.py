#!/usr/bin/env python3
"""Single source of truth mapping Claude subagent `model` tiers to the model
each target platform should run. Imported by the Codex (TOML) and opencode
(markdown) converters; run directly (`python3 scripts/agent_model_map.py`) to
print the mapping table for quick reference.
"""
import sys

# tier -> (model, model_reasoning_effort)
CODEX = {
    "opus": ("gpt-5.5", "high"),
    "sonnet": ("gpt-5.4", "medium"),
    "haiku": ("gpt-5.4-mini", "low"),
}
# tier -> opencode model id (provider is prepended by resolve_opencode)
OPENCODE = {
    "opus": "glm-5.2",
    "sonnet": "deepseek-v4-pro",
    "haiku": "deepseek-v4-flash",
}
OPENCODE_PROVIDER = "opencode-go"

# Tiers that mean "inherit the platform default" -> emit no model field.
INHERIT_TIERS = frozenset({None, "", "inherit"})
TIERS = ("opus", "sonnet", "haiku")


def resolve_codex(tier):
    """Return (model, effort) for a known capability tier, else None. None
    means 'emit nothing' — true for inherit/absent AND for unknown tiers
    (callers use is_unknown_tier to decide whether to warn)."""
    return CODEX.get(tier)


def resolve_opencode(tier):
    """Return 'opencode-go/<model>' for a known tier, else None (see
    resolve_codex for the None semantics)."""
    model = OPENCODE.get(tier)
    return None if model is None else "%s/%s" % (OPENCODE_PROVIDER, model)


def is_unknown_tier(tier):
    """True when tier is neither a known capability tier nor an
    inherit-the-default sentinel — i.e. a value we cannot map and should
    warn about."""
    return tier not in INHERIT_TIERS and tier not in CODEX


def format_table():
    rows = ["Claude tier | codex | opencode",
            "----------- | ----- | --------"]
    for t in TIERS:
        cm, ce = CODEX[t]
        rows.append("%s | %s (%s) | %s" % (t, cm, ce, resolve_opencode(t)))
    rows.append("inherit/absent | (omit) | (omit)")
    return "\n".join(rows)


if __name__ == "__main__":
    sys.stdout.write(format_table() + "\n")
