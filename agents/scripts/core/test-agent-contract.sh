#!/usr/bin/env bash
# test-agent-contract.sh — verify agent prompts conform to AGENTS.md § Agent output contract.
#
# The roster is the agent files present: agents/core/*.md (layer) plus
# agents/project/*.md (host). `architect` is the design agent; `code-review` and
# `security-review` are the review agents.
#
# Covers:
#   1. Every agent prompt contains the `## Outcome:` mandate text.
#   2. The debug report shape: agents/_shared/skills/debug-instrument/SKILL.md carries the 6 required report headings.
#   3. architect.md does NOT contain a `git commit` self-directive.
#   4. docs/agent-rules/delegation.md § Agent output contract names the one contract
#      (`## Outcome:`, `## Session context append`, `## Self-improvement`).
#   5. architect.md emits the plan sections (Goal / Affected components / Interface contracts /
#      Risks / Implementation handoff / Open questions).
#   6. agents/_shared/token-tracking/tests/test_infer_outcome.py passes (Python unit cases for the telemetry classifier).
#   7. agent-token-log.py canonical and .claude/hooks/ copy are byte-identical (link_file drift check).
#   8. Every skill SKILL.md carries a frontmatter `version:` field (telemetry).
#   9. The debug-instrument skill contains the literal "reproducer-first contract".
#  10. Every agent prompt references the `## Self-improvement` output-contract section
#      (mention counts — not a literal trailing heading).
#  11. Top-level `model:` frontmatter key exists and equals harness-hints.claude-code.model
#      (the Claude Code native model-routing wire; delegation.md § Model tiering).
#  12. Every agent has a `tools:` frontmatter line; a `read-only: true` agent lists no
#      Edit tool, and only code-review (the review-artifact writer) lists Write.
#
# Bucket A (CLI) per AGENTS.md § Verification automation. Zero manual steps.
# Auto-enrolled by scripts/dev/test-all.sh via the test-*.sh glob.
#
# HOST COUPLING. This gate also runs in the agent-layer repo's own
# agentic-selftests lane, from a standalone layer checkout. Two inputs are
# host-side and both degrade without a skip:
#
#   [7/12]   .claude/hooks/agent-token-log.py — the host-side adapter copy; the
#            check passes when the copy is absent.
#   roster   agents/project/*.md — host-tier agents, read from $PROJECT_ROOT; an
#            absent directory contributes no agents.
#
# Every other check reads layer content only, so a host run and a standalone
# layer run report the same 12 checks. Any check added later that names a host
# path MUST be added to this list and must degrade the same way, or be skipped
# explicitly when the host tree is absent.
#
# Modes:
#   (no args) | --check   run all 12 checks against the tree.
#   --selftest            dogfood the frontmatter readers and verdicts on fixtures.

set -euo pipefail

# claude_code_hint <file> <key> — read `harness-hints.claude-code.<key>`.
#
# Scoped to the `claude-code:` SUB-BLOCK, not to `harness-hints:` as a whole.
# A harness-hints-wide read takes the FIRST 4-space-indented key under
# harness-hints regardless of which harness owns it. `.coderabbit.yaml`
# documents `harness-hints.<harness>:` blocks (e.g. `harness-hints.claude:`) as
# intentional, so the moment any agent lists a second harness BEFORE
# `claude-code:`, check 11 would compare the wrong harness's value — a false
# PASS or a false FAIL with no way to tell which.
#
# Defined ABOVE the --selftest dispatch on purpose: bash executes function
# definitions in order, so a helper defined further down does not exist yet when
# `--selftest` runs and exits.
claude_code_hint() {  # <file> <key>
  awk -v k="    $2:" '
    # FRONTMATTER-SCOPED. Neither a 0-space top-level key (`version:`) nor the
    # closing `---` may let the scan run on into the document body, or an
    # indented `model:` in a body example would invent a value for a partial
    # block (fixture (g) below pins it).
    NR == 1 && /^---[[:space:]]*$/ { fm = 1; next }
    !fm { exit }                                  # no frontmatter -> no hints
    fm && /^---[[:space:]]*$/ { exit }            # closing --- ends the search
    /^  claude-code:/ { inblk = 1; next }
    # Any NON-BLANK line that is not one of the block s 4-space children ends the
    # block. Covers 2-space siblings, 0-space top-level keys, and `---` alike.
    inblk && !/^    / && /[^[:space:]]/ { inblk = 0 }
    inblk && index($0, k) == 1 { sub(/^[^:]*: */, ""); gsub(/[[:space:]]/, ""); print; exit }
  ' "$1"
}

# has_claude_code_block <file> — true when the agent declares a claude-code hint
# block at all. This is the ONLY legitimate reason to skip the model check; a
# block that exists but is partial is a finding, not a skip.
has_claude_code_block() {  # <file>
  # Frontmatter-scoped for the same reason as claude_code_hint: a whole-file grep
  # would count a `  claude-code:` line quoted in the agent s prose as a real
  # hint block, turning a legitimate no-block skip into a spurious finding.
  awk '
    NR == 1 && /^---[[:space:]]*$/ { fm = 1; next }
    !fm { exit 1 }
    fm && /^---[[:space:]]*$/ { exit 1 }
    /^  claude-code:/ { exit 0 }
  ' "$1"
}

# fm_tools <file> — print the frontmatter `tools:` entries, one per line, and
# exit 1 when the frontmatter declares no `tools:` key. Accepts the inline form
# (`tools: Read, Grep`) and the YAML list form (`tools:` + `  - Read` lines).
fm_tools() {  # <file>
  awk '
    NR == 1 && /^---[[:space:]]*$/ { fm = 1; next }
    !fm { exit }
    fm && /^---[[:space:]]*$/ { exit }
    inlist && /^[[:space:]]+-[[:space:]]*/ { v = $0; sub(/^[[:space:]]+-[[:space:]]*/, "", v); gsub(/[[:space:]]/, "", v); if (v != "") print v; next }
    inlist { inlist = 0 }
    /^tools:/ {
      found = 1
      v = $0; sub(/^tools:[[:space:]]*/, "", v); gsub(/[][]/, "", v)
      if (v == "") { inlist = 1; next }
      n = split(v, parts, ",")
      for (i = 1; i <= n; i++) { t = parts[i]; gsub(/[[:space:]]/, "", t); if (t != "") print t }
    }
    END { exit(found ? 0 : 1) }
  ' "$1"
}

# tools_verdict <file> — print each check-12 violation, or nothing when the
# agent's tool list matches its write scope. A `read-only: true` agent lists no
# Edit-family tool; Write is reserved for code-review, which writes the review
# artifact (.review-findings.json) and edits no source.
tools_verdict() {  # <file>
  local f="$1" base name ro tools t
  base=$(basename "$f")
  if ! tools="$(fm_tools "$f")"; then
    printf '%s: no tools: frontmatter line\n' "$base"
    return 0
  fi
  name=$(grep -m1 -E "^name:" "$f" | awk -F': *' '{print $2}' | tr -d '[:space:]' || true)
  ro=$(grep -m1 -E "^read-only:" "$f" | awk -F': *' '{print $2}' | tr -d '[:space:]' || true)
  while IFS= read -r t; do
    case "$t" in
      Edit|MultiEdit|NotebookEdit)
        [[ "$ro" == "true" ]] && printf '%s: read-only agent lists %s\n' "$base" "$t" ;;
      Write)
        [[ "$name" == "code-review" ]] || printf '%s: lists Write (only code-review, the review-artifact writer, may)\n' "$base" ;;
    esac
  done <<< "$tools"
  return 0
}

# model_verdict <file> — print the check-11 mismatch reason, or nothing when the
# agent is compliant (or legitimately exempt). Extracted from the check loop so
# the DECISION is testable, not just the extractors it calls.
model_verdict() {  # <file>
  local f="$1" base hint top
  base=$(basename "$f")
  hint=$(claude_code_hint "$f" model)
  top=$(grep -m1 -E "^model:" "$f" | awk -F': *' '{print $2}' | tr -d '[:space:]' || true)
  if ! has_claude_code_block "$f"; then
    # No hint block is the ONLY legitimate skip — and only when a top-level key
    # still pins the model. With neither, the agent silently inherits the
    # session model, which is the regression this check exists to prevent.
    [[ -n "$top" ]] && return 0
    printf '%s: no model: key and no claude-code hint block — agent will inherit the session model\n' "$base"
    return 0
  fi
  if [[ -z "$hint" && -z "$top" ]]; then
    printf '%s: claude-code block present but neither model: key set — agent will inherit the session model\n' "$base"
  elif [[ -z "$hint" ]]; then
    printf '%s: has top-level model '\''%s'\'' but no harness-hints.claude-code.model\n' "$base" "$top"
  elif [[ -z "$top" ]]; then
    printf '%s: has harness-hints model '\''%s'\'' but no top-level model: key\n' "$base" "$hint"
  elif [[ "$top" != "$hint" ]]; then
    printf '%s: top-level model '\''%s'\'' != harness-hints model '\''%s'\''\n' "$base" "$top" "$hint"
  fi
  return 0
}

# selftest: asserts-failure — every `report` case below must produce a non-empty
# verdict, so a model_verdict or tools_verdict stubbed to `return 0` fails.
run_selftest() {
  local rc=0
  # The real tree has 0 violations, so nothing in-repo exercises the failure
  # paths. Without fixtures a regression would be invisible — the same
  # "verified nothing, reported PASS" shape these checks exist to close.
  local tmpd; tmpd="$(mktemp -d)"

  # (a) Multi-harness ordering: a NON-claude-code harness listed FIRST must not
  #     be the value compared.
  cat > "$tmpd/multi.md" <<'FIX'
---
name: multi
model: opus
tools: Read, Grep
read-only: true
harness-hints:
  claude:
    model: sonnet
    effort: low
  claude-code:
    model: opus
    effort: high
---
FIX
  if [[ "$(claude_code_hint "$tmpd/multi.md" model)" != "opus" ]]; then
    echo "selftest: FAIL — claude_code_hint read the wrong harness's model (got '$(claude_code_hint "$tmpd/multi.md" model)', want 'opus')" >&2
    rc=1
  fi
  if [[ "$(claude_code_hint "$tmpd/multi.md" effort)" != "high" ]]; then
    echo "selftest: FAIL — claude_code_hint read the wrong harness's effort" >&2
    rc=1
  fi

  vcase() {  # <verdict-fn> <fixture-file> <want: report|silent> <label>
    local got; got="$("$1" "$2")"
    if [[ "$3" == "report" && -z "$got" ]]; then
      echo "selftest: FAIL — $4: expected a report, got silence (fail-open)" >&2; rc=1
    elif [[ "$3" == "silent" && -n "$got" ]]; then
      echo "selftest: FAIL — $4: expected no finding, got '$got'" >&2; rc=1
    fi
  }

  # (b) NO model key anywhere: the agent silently inherits the session model.
  printf -- '---\nname: bare\n---\n' > "$tmpd/bare.md"
  vcase model_verdict "$tmpd/bare.md" report "no model key at all"

  # (c) claude-code block present but partial — a finding, not a skip.
  printf -- '---\nname: partial\nharness-hints:\n  claude-code:\n    effort: high\n---\n' > "$tmpd/partial.md"
  vcase model_verdict "$tmpd/partial.md" report "partial claude-code block"

  # (d) genuine drift between the two keys must still be caught.
  printf -- '---\nname: drift\nmodel: opus\nharness-hints:\n  claude-code:\n    model: sonnet\n---\n' > "$tmpd/drift.md"
  vcase model_verdict "$tmpd/drift.md" report "top-level vs hint drift"

  # (e) multi-harness fixture from (a) is COMPLIANT — the wrong-harness read
  #     would make it look like drift, so this pins the false-positive side.
  vcase model_verdict "$tmpd/multi.md" silent "multi-harness, keys agree"

  # (f) legitimate exemption: no hint block, but a top-level key still pins the
  #     model. Must stay silent, or the check becomes noise on valid agents.
  printf -- '---\nname: toponly\nmodel: opus\n---\n' > "$tmpd/toponly.md"
  vcase model_verdict "$tmpd/toponly.md" silent "top-level only, no hint block"

  # (g) A PARTIAL claude-code block, then a 0-space top-level key and the
  #     closing `---`, then a 4-space `model:` in the document body. The scan
  #     must stop at the frontmatter and report the missing key.
  cat > "$tmpd/leak.md" <<'LEAKFIX'
---
name: leak
harness-hints:
  claude-code:
    effort: high
version: 3
---

Example config:

    model: sonnet
LEAKFIX
  if [[ -n "$(claude_code_hint "$tmpd/leak.md" model)" ]]; then
    echo "selftest: FAIL — claude_code_hint leaked past the frontmatter and read '$(claude_code_hint "$tmpd/leak.md" model)' from the body" >&2
    rc=1
  fi
  vcase model_verdict "$tmpd/leak.md" report "partial block with a body model: line"

  # (h) prose mentioning a hint block must NOT count as declaring one, or a
  #     legitimate no-block skip becomes a spurious finding.
  printf -- '---\nname: prose\nmodel: opus\n---\n\nAgents declare:\n\n  claude-code:\n    model: sonnet\n' > "$tmpd/prose.md"
  if has_claude_code_block "$tmpd/prose.md"; then
    echo "selftest: FAIL — has_claude_code_block counted a block quoted in prose" >&2
    rc=1
  fi
  vcase model_verdict "$tmpd/prose.md" silent "prose mentioning claude-code, real top-level model"

  # (i) tools: — the compliant shapes stay silent.
  vcase tools_verdict "$tmpd/multi.md" silent "read-only agent with read tools"
  printf -- '---\nname: code-review\nread-only: true\ntools: Read, Grep, Bash, Write\n---\n' > "$tmpd/cr.md"
  vcase tools_verdict "$tmpd/cr.md" silent "code-review may list Write"
  printf -- '---\nname: listform\nread-only: true\ntools:\n  - Read\n  - Grep\n---\n' > "$tmpd/listform.md"
  vcase tools_verdict "$tmpd/listform.md" silent "YAML list form, read tools only"

  # (j) tools: — every violation shape reports.
  printf -- '---\nname: notools\nread-only: true\n---\n\ntools: Read\n' > "$tmpd/notools.md"
  vcase tools_verdict "$tmpd/notools.md" report "no tools: key (a body line does not count)"
  printf -- '---\nname: architect\nread-only: true\ntools: Read, Edit\n---\n' > "$tmpd/roedit.md"
  vcase tools_verdict "$tmpd/roedit.md" report "read-only agent lists Edit"
  printf -- '---\nname: code-review\nread-only: true\ntools: [Read, Edit]\n---\n' > "$tmpd/credit.md"
  vcase tools_verdict "$tmpd/credit.md" report "code-review lists Edit (bracket form)"
  printf -- '---\nname: security-review\nread-only: true\ntools:\n  - Read\n  - Write\n---\n' > "$tmpd/srwrite.md"
  vcase tools_verdict "$tmpd/srwrite.md" report "security-review lists Write (list form)"
  rm -rf "$tmpd"

  if [[ $rc -eq 0 ]]; then echo "test-agent-contract --selftest: PASS"; fi
  return "$rc"
}

case "${1:---check}" in
  --check)    : ;;
  --selftest) run_selftest; exit $? ;;
  -h|--help)  echo "usage: test-agent-contract.sh [--check|--selftest]"; exit 0 ;;
  *)          echo "usage: test-agent-contract.sh [--check|--selftest]" >&2; exit 2 ;;
esac

# shellcheck source=agents/scripts/core/lib/resolve-py.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/resolve-py.sh"
PY="$(resolve_py)" || { echo "python required (no working interpreter on PATH)" >&2; exit 2; }

# Dual-root bootstrap: a location-relative climb, correct whether this script
# runs from the layer repo or from the host's agent-layer submodule (where
# `git rev-parse --show-toplevel` names the submodule, not the host).
# Best-effort with explicit fallbacks to the git toplevel for both roots, so a
# reduced tree carrying agents/ but no scripts/dev/ keeps running the contract
# instead of failing to start.
_tac_pc="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/scripts/dev/project-config.sh"
if [ -f "$_tac_pc" ]; then
    # shellcheck source=scripts/dev/project-config.sh
    . "$_tac_pc" 2>/dev/null || true
else
    unset PROJECT_ROOT AGENT_LAYER_ROOT  # no config beside this script (a fixture copy): its own tree, never an inherited root
fi
_tac_top="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
: "${AGENT_LAYER_ROOT:=$_tac_top}"
: "${PROJECT_ROOT:=$_tac_top}"

# The bulk of this gate reads LAYER content (agents/, docs/agent-rules/), so cwd
# is the layer root and those paths stay bare relative literals. Host-side paths
# are anchored on $PROJECT_ROOT explicitly.
cd "$AGENT_LAYER_ROOT"

# The project tier of agents is HOST content, read from $PROJECT_ROOT, never from
# the layer cwd. In a single-repo tree that is the same directory.
PROJECT_AGENTS_DIR="$PROJECT_ROOT/agents/project"

DESIGN_AGENT=architect
DEBUG_SKILL="agents/_shared/skills/debug-instrument/SKILL.md"

PASS=0
FAIL=0
FAILED_CHECKS=()

check_pass() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
check_fail() { FAIL=$((FAIL+1)); FAILED_CHECKS+=("$1"); printf '  FAIL  %s\n' "$1"; }

# Agents live under agents/core/ (layer) and agents/project/ (host) — resolve by
# name so this contract is location-agnostic. Excludes agents/_shared/; the layer's
# own agents/project/ is pruned so a single-repo tree, where it is the same
# directory as $PROJECT_AGENTS_DIR, is not searched twice.
agent_path() {
  local f
  f="$(find agents -path 'agents/_shared' -prune -o -path 'agents/project' -prune \
         -o -name "$1.md" -print 2>/dev/null | head -1)"
  [[ -n "$f" ]] || f="$(find "$PROJECT_AGENTS_DIR" -maxdepth 1 -name "$1.md" -print 2>/dev/null | head -1)"
  printf '%s\n' "$f"
}
# All agent prompt files (both tiers, excluding _shared + any README), one per
# line; loaded once into AGENT_FILES below so a path with spaces stays one word.
agent_files() {
  { find agents/core -maxdepth 1 -name '*.md' ! -name 'README.md' 2>/dev/null
    find "$PROJECT_AGENTS_DIR" -maxdepth 1 -name '*.md' ! -name 'README.md' 2>/dev/null
  } | sort
}
mapfile -t AGENT_FILES < <(agent_files)
DESIGN_MD="$(agent_path "$DESIGN_AGENT")"

# -------------------------------------------------------------------------
# 1. Every agent has ## Outcome: mandate text.
# -------------------------------------------------------------------------
echo "[1/12] ## Outcome: mandate present in every agent prompt"
miss_outcome=()
for f in "${AGENT_FILES[@]}"; do
  if ! grep -qF "## Outcome:" "$f"; then miss_outcome+=("$(basename "$f")"); fi
done
if [[ ${#AGENT_FILES[@]} -eq 0 ]]; then
  check_fail "no agent prompts found under agents/core/ or $PROJECT_AGENTS_DIR"
elif [[ ${#miss_outcome[@]} -eq 0 ]]; then
  check_pass "${#AGENT_FILES[@]}/${#AGENT_FILES[@]} agents have ## Outcome: mandate"
else
  for m in "${miss_outcome[@]}"; do echo "    missing: $m"; done
  check_fail "${#miss_outcome[@]} agents missing ## Outcome: mandate"
fi

# -------------------------------------------------------------------------
# 2. Debug report shape — the 6 required report headings live in the
#    debug-instrument skill.
# -------------------------------------------------------------------------
echo
echo "[2/12] Debug report-shape headings (debug-instrument skill)"
DD_REQUIRED=("## Hypotheses" "## Evidence" "## Cause" "## Files changed (temp-debug)" "## Cleanup" "## Handoff")
miss=0
for h in "${DD_REQUIRED[@]}"; do
  if ! { [[ -f "$DEBUG_SKILL" ]] && grep -qF "$h" "$DEBUG_SKILL"; }; then
    miss=$((miss+1))
    echo "    missing (debug-instrument skill): $h"
  fi
done
if [[ $miss -eq 0 ]]; then check_pass "debug-instrument 6/6"; else check_fail "debug-instrument missing $miss/6 report headings"; fi

# -------------------------------------------------------------------------
# 3. The design agent does NOT contain a git commit self-directive.
# -------------------------------------------------------------------------
echo
echo "[3/12] $DESIGN_AGENT.md emit-only (no self-commit directive)"
if [[ -z "$DESIGN_MD" ]]; then
  check_fail "$DESIGN_AGENT.md not found under agents/"
elif grep -qE '^[^>`]*Commit immediately with ' "$DESIGN_MD"; then
  check_fail "$DESIGN_AGENT.md still instructs the agent to commit"
else
  check_pass "$DESIGN_AGENT.md is emit-only"
fi

# -------------------------------------------------------------------------
# 4. delegation.md § Agent output contract names the one contract every
#    report ends with.
# -------------------------------------------------------------------------
echo
echo "[4/12] docs/agent-rules/delegation.md § Agent output contract names ## Outcome: / ## Session context append / ## Self-improvement"
contract_sec=$(awk '/^## Agent output contract/{p=1; print; next} p && /^## /{exit} p' docs/agent-rules/delegation.md 2>/dev/null || true)
contract_miss=0
if [[ -z "$contract_sec" ]]; then
  check_fail "delegation.md has no ## Agent output contract section"
else
  for h in "## Outcome:" "## Session context append" "## Self-improvement"; do
    if ! grep -qF -- "$h" <<< "$contract_sec"; then
      contract_miss=$((contract_miss+1))
      echo "    missing: $h"
    fi
  done
  if [[ $contract_miss -eq 0 ]]; then
    check_pass "output contract names all 3 sections"
  else
    check_fail "delegation.md § Agent output contract missing $contract_miss/3 sections"
  fi
fi

# -------------------------------------------------------------------------
# 5. The design agent emits the plan sections. They may be numbered list items
#    (`1. **Goal** — ...`) or literal `## Goal` headings.
# -------------------------------------------------------------------------
echo
echo "[5/12] $DESIGN_AGENT.md emits the plan sections (Goal / Affected components / Interface contracts / Risks / Implementation handoff / Open questions)"
DESIGN_SECTIONS=("Goal" "Affected components" "Interface contracts" "Risks" "Implementation handoff" "Open questions")
design_miss=0
for h in "${DESIGN_SECTIONS[@]}"; do
  if [[ -z "$DESIGN_MD" ]] || ! grep -qE "^(## $h|[0-9]+\. \*\*$h\*\*)" "$DESIGN_MD"; then
    design_miss=$((design_miss+1))
    echo "    missing: $h"
  fi
done
if [[ $design_miss -eq 0 ]]; then
  check_pass "$DESIGN_AGENT.md ${#DESIGN_SECTIONS[@]}/${#DESIGN_SECTIONS[@]} plan sections"
else
  check_fail "$DESIGN_AGENT.md missing $design_miss/${#DESIGN_SECTIONS[@]} plan sections"
fi

# -------------------------------------------------------------------------
# 6. _infer_outcome unit tests pass.
# -------------------------------------------------------------------------
echo
echo "[6/12] agents/_shared/token-tracking/tests/test_infer_outcome.py"
if "$PY" agents/_shared/token-tracking/tests/test_infer_outcome.py; then
  check_pass "_infer_outcome unit tests"
else
  check_fail "_infer_outcome unit tests"
fi

# -------------------------------------------------------------------------
# 7. agent-token-log.py canonical vs .claude/hooks/ copy drift check.
# -------------------------------------------------------------------------
# `link_file()` in agents/scripts/core/setup-harness.sh short-circuits when the
# destination exists, so an independent copy at `.claude/hooks/agent-token-log.py`
# (different inode, possibly stale) can silently diverge from the canonical at
# `agents/_shared/token-tracking/agent-token-log.py`: edits to the canonical
# don't propagate and the live SubagentStop hook runs the stale copy.
echo
echo "[7/12] agent-token-log.py — canonical vs .claude/hooks/ copy drift"
canonical=agents/_shared/token-tracking/agent-token-log.py
# .claude/ is the HOST-side adapter dir.
hook_copy="$PROJECT_ROOT/.claude/hooks/agent-token-log.py"
if [[ ! -f "$hook_copy" ]]; then
  # Hook copy absent — Claude Code harness not set up locally.
  check_pass "drift check skipped (hook copy absent — setup-harness.sh not run)"
elif cmp -s "$canonical" "$hook_copy"; then
  check_pass "canonical and hook copy byte-identical"
else
  check_fail "DRIFT: $canonical vs $hook_copy differ — run \`cp -f $canonical $hook_copy\` or \`bash agents/scripts/core/setup-harness.sh claude-code\` (after \`rm $hook_copy\`)"
fi

# -------------------------------------------------------------------------
# 8. Every skill carries its own `version:` field for telemetry.
# -------------------------------------------------------------------------
echo
echo "[8/12] Every skill SKILL.md has a frontmatter version: field"
skill_unversioned=()
for skill_md in agents/_shared/skills/*/SKILL.md; do
  [[ -f "$skill_md" ]] || continue
  # `|| true`: under `set -euo pipefail` a SKILL.md with no `version:` line makes
  # grep exit 1, which (via pipefail) aborts the script before the report below.
  skill_ver=$(awk '/^---$/{p=!p;next}p' "$skill_md" | grep -E "^version:" | head -1 | awk -F': *' '{print $2}' | tr -d '[:space:]' || true)
  [[ -n "$skill_ver" ]] || skill_unversioned+=("$(basename "$(dirname "$skill_md")")")
done
if [[ ${#skill_unversioned[@]} -eq 0 ]]; then
  check_pass "all skills carry version:"
else
  for s in "${skill_unversioned[@]}"; do echo "    missing version: $s"; done
  check_fail "${#skill_unversioned[@]} skills missing a frontmatter version: field"
fi

# -------------------------------------------------------------------------
# 9. The debug-instrument skill contains the literal phrase
#    "reproducer-first contract", so a doc rewrite cannot silently soften it.
# -------------------------------------------------------------------------
echo
echo "[9/12] debug-instrument SKILL.md contains literal 'reproducer-first contract'"
if [[ -f "$DEBUG_SKILL" ]] && grep -qF "reproducer-first contract" "$DEBUG_SKILL"; then
  check_pass "'reproducer-first contract' phrase present"
else
  check_fail "'reproducer-first contract' phrase missing from $DEBUG_SKILL"
fi

# -------------------------------------------------------------------------
# 10. Every agent prompt references the `## Self-improvement` output-contract
#     section. A mention (inline in the output-contract line OR a literal
#     heading) counts; a literal trailing heading is deliberately not required.
# -------------------------------------------------------------------------
echo
echo "[10/12] ## Self-improvement contract referenced in every agent prompt"
miss_selfimp=()
for f in "${AGENT_FILES[@]}"; do
  if ! grep -qF "## Self-improvement" "$f"; then miss_selfimp+=("$(basename "$f")"); fi
done
if [[ ${#miss_selfimp[@]} -eq 0 ]]; then
  check_pass "${#AGENT_FILES[@]}/${#AGENT_FILES[@]} agents reference ## Self-improvement"
else
  for m in "${miss_selfimp[@]}"; do echo "    missing: $m"; done
  check_fail "${#miss_selfimp[@]} agents missing ## Self-improvement reference"
fi

# -------------------------------------------------------------------------
# 11. Top-level `model:` key ↔ harness-hints.claude-code.model parity.
#     The top-level key is the Claude Code wire (native subagent model
#     routing); the harness-hints value feeds the pi/codex generators. Both
#     must exist and agree — delegation.md § Model tiering.
# -------------------------------------------------------------------------
echo
echo "[11/12] Top-level model: ↔ harness-hints.claude-code.model parity"
model_mismatch=()
for f in "${AGENT_FILES[@]}"; do
  verdict=$(model_verdict "$f")
  [[ -n "$verdict" ]] && model_mismatch+=("$verdict")
done
if [[ ${#model_mismatch[@]} -eq 0 ]]; then
  check_pass "all top-level model: keys match harness-hints.claude-code.model"
else
  for m in "${model_mismatch[@]}"; do echo "    $m"; done
  check_fail "${#model_mismatch[@]} model-key mismatches"
fi

# -------------------------------------------------------------------------
# 12. Tool scope: every agent declares `tools:`; a read-only agent lists no
#     Edit tool; only code-review lists Write (for its review artifact).
# -------------------------------------------------------------------------
echo
echo "[12/12] tools: frontmatter present and within the agent's write scope"
tools_violation=()
for f in "${AGENT_FILES[@]}"; do
  while IFS= read -r v; do
    [[ -n "$v" ]] && tools_violation+=("$v")
  done < <(tools_verdict "$f")
done
if [[ ${#tools_violation[@]} -eq 0 ]]; then
  check_pass "${#AGENT_FILES[@]}/${#AGENT_FILES[@]} agents declare tools: within their write scope"
else
  for m in "${tools_violation[@]}"; do echo "    $m"; done
  check_fail "${#tools_violation[@]} tools: violations"
fi

# -------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------
echo
echo "----------------------------------------"
echo "test-agent-contract — Passed: $PASS  Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  echo
  echo "Failures:"
  for c in "${FAILED_CHECKS[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
