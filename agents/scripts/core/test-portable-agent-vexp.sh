#!/usr/bin/env bash
# test-portable-agent-vexp.sh — fail when a PORTABLE agent prompt
# (agents/core/*.md or agents/project/*.md), a shared skill
# (agents/_shared/skills/**/*.md) or an on-demand rule doc
# (docs/agent-rules/*.md) carries a vexp-specific tool literal.
#
# vexp is a Claude-Code-only MCP tool. Its installer re-injects vexp calls into
# the reviewer/architect prompts (replacing the harness-neutral wording + even
# reverting a version bump). The SessionStart strip-hook only cleans AGENTS.md,
# so the agents/*.md re-injection was unguarded — a portability regression that
# only surfaced by chance `git status` (tooling self-improvement 2026-06-10 P2).
# This full-scan catches it at gate time. The agent prompts are vexp-clean today,
# so a plain scan (no grandfathering) is correct; the fix for a hit is to restore
# the harness-neutral wording ("your harness's semantic codebase search" /
# "file-skeleton view").
#
# Banned literals (unambiguously vexp; harness-neutral phrasing is fine):
#   mcp__vexp__   run_pipeline(   get_skeleton(
#
# Skills and rule docs are scanned too: procedure text moves out of agent prompts
# into them (AGENT-VS-SKILL.md), and a literal there reaches every harness the
# same way. AGENTS.md is left to the SessionStart strip-hook named above.
#
# Roots: agents/core/, agents/_shared/skills/ and docs/agent-rules/ are LAYER
# content, read from this script's own tree; agents/project/ is HOST content, read
# from PROJECT_ROOT (scripts/dev/project-config.sh — the superproject once the
# layer is a submodule). Before the flip both are this checkout.
#
# Override scan root (testing): SMATCHET_VEXP_SCAN_ROOT — one tree for both.
#
# Usage:
#   bash agents/scripts/core/test-portable-agent-vexp.sh            # scan the tree
#   bash agents/scripts/core/test-portable-agent-vexp.sh --selftest
#
# Exit: 0 — no portable agent file carries a vexp literal · 1 — a hit (or
#       --selftest failure) · 2 — infra error.
#
# selftest: asserts-failure

set -uo pipefail

VEXP_RE='mcp__vexp__|run_pipeline\(|get_skeleton\('

# _scan_vexp <layer_root> [<project_root>] — scan <layer_root>/agents/core,
# <layer_root>/agents/_shared/skills, <layer_root>/docs/agent-rules and
# <project_root>/agents/project markdown; echo offending files; 0 clean / 1 a hit.
# A root that does not exist is skipped.
_scan_vexp() {
    local root="$1" project="${2:-$1}" hits
    hits="$(grep -rlE "$VEXP_RE" "$root/agents/core" "$root/agents/_shared/skills" \
        "$root/docs/agent-rules" "$project/agents/project" \
        --include='*.md' 2>/dev/null || true)"
    if [ -n "$hits" ]; then
        echo "$hits"
        return 1
    fi
    return 0
}

if [ "${1:-}" = "--selftest" ]; then
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/agents/core" "$tmp/agents/project"
    # Clean file -> scan passes.
    printf '# Reviewer\nUse your harness semantic codebase search first.\n' > "$tmp/agents/core/code-review.md"
    if ! _scan_vexp "$tmp" >/dev/null; then
        echo "test-portable-agent-vexp --selftest: FAIL — clean tree flagged"; exit 1
    fi
    # Inject a vexp literal -> scan MUST fail (the asserted-failure case).
    printf 'Call run_pipeline({task}) first.\n' >> "$tmp/agents/core/code-review.md"
    if _scan_vexp "$tmp" >/dev/null; then
        echo "test-portable-agent-vexp --selftest: FAIL — vexp literal not caught"; exit 1
    fi
    # Split roots (post-flip): a hit in the HOST's agents/project/ MUST be caught
    # when the layer tree holding agents/core/ is clean.
    mkdir -p "$tmp/L/agents/core" "$tmp/H/agents/project"
    printf '# Reviewer\n' > "$tmp/L/agents/core/code-review.md"
    printf 'Call mcp__vexp__run.\n' > "$tmp/H/agents/project/ui-host.md"
    if _scan_vexp "$tmp/L" "$tmp/H" >/dev/null; then
        echo "test-portable-agent-vexp --selftest: FAIL — a host project-agent hit not caught"; exit 1
    fi
    # A hit in a shared skill and in a rule doc MUST each be caught.
    mkdir -p "$tmp/S/agents/core" "$tmp/S/agents/_shared/skills/demo" "$tmp/S/docs/agent-rules"
    printf '# Reviewer\n' > "$tmp/S/agents/core/code-review.md"
    printf 'Call get_skeleton(file) first.\n' > "$tmp/S/agents/_shared/skills/demo/SKILL.md"
    if _scan_vexp "$tmp/S" >/dev/null; then
        echo "test-portable-agent-vexp --selftest: FAIL — a vexp literal in a shared skill not caught"; exit 1
    fi
    rm "$tmp/S/agents/_shared/skills/demo/SKILL.md"
    printf 'Use mcp__vexp__run_pipeline.\n' > "$tmp/S/docs/agent-rules/build.md"
    if _scan_vexp "$tmp/S" >/dev/null; then
        echo "test-portable-agent-vexp --selftest: FAIL — a vexp literal in a rule doc not caught"; exit 1
    fi
    echo "test-portable-agent-vexp --selftest: PASS — clean passes, a vexp literal fails (agents, skills, rule docs), split roots read each tree."
    exit 0
fi

ROOT="${SMATCHET_VEXP_SCAN_ROOT:-}"
PROJECT="$ROOT"
if [ -z "$ROOT" ]; then
    ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
    if [ -f "$ROOT/scripts/dev/project-config.sh" ]; then
        # shellcheck source=scripts/dev/project-config.sh
        PC_ROOTS_ONLY=1 . "$ROOT/scripts/dev/project-config.sh" || true
    else
        unset PROJECT_ROOT AGENT_LAYER_ROOT  # no config beside this script (a fixture copy): its own tree, never an inherited root
    fi
    PROJECT="${PROJECT_ROOT:-$ROOT}"
fi

if hits="$(_scan_vexp "$ROOT" "$PROJECT")"; then
    echo "test-portable-agent-vexp: PASS — no vexp literal in portable agent prompts, skills or rule docs."
    exit 0
fi
echo "test-portable-agent-vexp: FAIL — portable agent prompt(s), skill(s) or rule doc(s) carry a vexp-specific literal" >&2
echo "  (mcp__vexp__ / run_pipeline( / get_skeleton() — re-injected by the vexp installer):" >&2
printf '%s\n' "$hits" | while IFS= read -r h; do [ -n "$h" ] && echo "  - $h" >&2; done
echo "  Restore harness-neutral wording (your harness's semantic search / file-skeleton view)." >&2
exit 1
