#!/usr/bin/env bash
# test-subsystem-docs.sh — coverage + staleness gate for per-subsystem agent docs.
# ----------------------------------------------------------------------------
# Per-subsystem leaf docs live at <dir>/{AGENTS,CONTEXT,README}.md for a <dir>
# below Source/ (Source/Core/src/<ctx>/, a plugin dir, ...) and are registered in
# the root CONTEXT-MAP.md. This gate keeps the registry, the on-disk leaves, and
# the central review checklists in sync.
#
# FAIL (exit 1) on any structural breakage:
#   1. A leaf listed in CONTEXT-MAP.md is missing on disk.
#   2. An on-disk leaf AGENTS.md below Source/ (lib/leaf-docs.sh: tracked, outside
#      the lint exempt zones) is absent from CONTEXT-MAP.md.
#   3. A leaf invariant bullet is duplicated verbatim in a central checklist:
#      agents/core/code-review.md, plus the host checklist named by
#      project.config.json docs.review_checklist when set (central<->leaf drift —
#      the rule must live in ONE place: the leaf). A configured checklist that
#      does not exist FAILs.
#
# WARN (never changes exit code), only in --diff mode:
#   4. A registered leaf's .cpp/.h changed vs <ref> but its registered README.md
#      did not (stale orientation).
#
# Modes:
#   (no args)          structural checks 1-3 + staleness WARN vs origin/develop when that
#                      ref resolves (degrades to structural-only if it doesn't).
#   --diff[=]<ref>     structural checks 1-3 + staleness WARN vs <ref> (e.g. origin/develop).
#   --selftest         assert the registry parses and matches on-disk leaves; checks 1-2 only.
#
# Project-bound (hardcodes the Source/ leaf root) — lives in agents/scripts/project/,
# not core/, per the portable/project split. Goes through test-shell-lint.sh (5 rules).
# ----------------------------------------------------------------------------
set -uo pipefail

# Host content (CONTEXT-MAP.md, the Source/ leaf docs) is read from PROJECT_ROOT: scripts/dev/project-config.sh resolves it to
# the superproject once this script lives in the agent-layer/ submodule, and to this
# checkout before the flip. A climb from this script's own path would land in the
# layer after the flip.
# The layer checklist (agents/core/code-review.md) is layer content, read from
# this script's own tree; the optional host checklist (docs.review_checklist) is
# host content, relative to PROJECT_ROOT.
_tsd_self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
_tsd_layer="$(cd "$(dirname "$_tsd_self")/../../.." && pwd)"
unset PC_DOCS_REVIEW_CHECKLIST
_tsd_config_err=0
if [ -f "$_tsd_layer/scripts/dev/project-config.sh" ]; then
    # Full load, not PC_ROOTS_ONLY: check 3 reads docs.review_checklist and the
    # leaf set reads the lint exempt zones. A failed load (no working python, a
    # malformed config) still exports the roots; see the policy after fail=0.
    # shellcheck source=scripts/dev/project-config.sh
    . "$_tsd_layer/scripts/dev/project-config.sh" || _tsd_config_err=1
else
    unset PROJECT_ROOT AGENT_LAYER_ROOT  # no config beside this script (a fixture copy): its own tree, never an inherited root
fi
cd "${PROJECT_ROOT:-$_tsd_layer}" || { echo "test-subsystem-docs: cannot cd to ${PROJECT_ROOT:-$_tsd_layer}" >&2; exit 2; }

# MAP/SRC_GLOB are read-only override seams (no command-from-env injection) so
# --selftest can point check 1 (registered-leaf-missing-on-disk) at a synthetic
# temp registry and assert the REAL detection path FAILS on a known-bad fixture.
# Defaults are unchanged in every real invocation (no env set) — a test seam, not
# a logic change. SUBSYS_DOCS_NEGCHECK guards against selftest re-entrancy.
# shellcheck source=agents/scripts/core/lib/leaf-docs.sh
. "$_tsd_layer/agents/scripts/core/lib/leaf-docs.sh" \
  || { echo "test-subsystem-docs: missing $_tsd_layer/agents/scripts/core/lib/leaf-docs.sh" >&2; exit 2; }

MAP="${SUBSYS_DOCS_MAP:-CONTEXT-MAP.md}"
SRC_GLOB="${SUBSYS_DOCS_SRC_GLOB:-Source}"
CENTRAL_FILES=("$_tsd_layer/agents/core/code-review.md")
if [[ -n "${PC_DOCS_REVIEW_CHECKLIST:-}" ]]; then
  CENTRAL_FILES+=("$PC_DOCS_REVIEW_CHECKLIST")
fi

# Default (no args, as test-all.sh invokes it): structural checks + staleness vs
# origin/develop when that ref resolves. --diff names an explicit ref; --selftest
# is structure-only (checks 1-2). Staleness is always WARN — never flips exit.
MODE="diff"
DIFF_REF="origin/develop"
case "${1:-}" in
  --diff=*)   DIFF_REF="${1#--diff=}" ;;
  --diff)     DIFF_REF="${2:-origin/develop}" ;;
  --selftest) MODE="selftest" ;;
  "")         ;;
  *) echo "usage: test-subsystem-docs.sh [--diff[=]<ref> | --selftest]" >&2; exit 2 ;;
esac
# Staleness needs a resolvable base ref; degrade to structural-only if absent
# (shallow CI clone, detached HEAD) rather than erroring.
if [[ "$MODE" == "diff" ]] && ! git rev-parse --verify --quiet "$DIFF_REF" >/dev/null 2>&1; then
  MODE="structural"
fi

# --- selftest negative fixture (Gap C / Slice 3) -----------------------------
# selftest: asserts-failure — feed a synthetic registry that names a leaf NOT on
# disk and assert the REAL check-1 path returns non-zero. Re-enters this same
# script (so it exercises production logic, not a copy) with the MAP/SRC_GLOB
# seams pointed at a temp tree; SUBSYS_DOCS_NEGCHECK breaks the recursion.
if [[ "$MODE" == "selftest" && "${SUBSYS_DOCS_NEGCHECK:-0}" != "1" ]]; then
  _neg_tmp="$(mktemp -d)" || { echo "test-subsystem-docs selftest: mktemp failed" >&2; exit 1; }
  trap 'rm -rf "$_neg_tmp"' EXIT
  # A registry section that registers a leaf which does not exist on disk.
  cat > "$_neg_tmp/MAP.md" <<EOF
## Registry
- \`$_neg_tmp/src/ghost/AGENTS.md\` — a deliberately absent leaf (selftest fixture).
## Next section
EOF
  mkdir -p "$_neg_tmp/src"   # SRC_GLOB root exists but holds no */AGENTS.md
  if SUBSYS_DOCS_NEGCHECK=1 SUBSYS_DOCS_MAP="$_neg_tmp/MAP.md" \
       SUBSYS_DOCS_SRC_GLOB="$_neg_tmp/src" bash "$_tsd_self" --selftest >/dev/null 2>&1; then
    echo "test-subsystem-docs selftest: FAIL — a registry naming a missing-on-disk leaf was NOT detected" >&2
    exit 1
  fi
  rm -rf "$_neg_tmp"; trap - EXIT
fi

fail=0
warn=0

# A config that could not be loaded must not silently drop a configured host
# checklist: FAIL when its raw text names docs.review_checklist, else WARN (the
# layer checklist alone loses nothing that was configured).
if [[ "$_tsd_config_err" == 1 ]]; then
  if [[ -f "${PC_CONFIG_FILE:-}" ]] && grep -q '"review_checklist"' "$PC_CONFIG_FILE"; then
    echo "test-subsystem-docs: FAIL — ${PC_CONFIG_FILE} names docs.review_checklist but could not be loaded; fix it (or the python it needs) so check 3 can read it." >&2
    fail=1
  else
    echo "test-subsystem-docs: WARN — project.config.json not loaded; checking against agents/core/code-review.md only, and no lint exempt zones." >&2
  fi
fi

if [[ ! -f "$MAP" ]]; then
  echo "test-subsystem-docs: FAIL — registry $MAP not found" >&2
  exit 1
fi

# --- Parse the registry: every backtick-wrapped Source/<dir>/<X>.md path
# inside the `## Registry` section ONLY (awk scopes to it, so format-contract examples
# and the growth-path `<ctx>` placeholder elsewhere in the doc don't get parsed as real
# leaves). The `<` filter is a belt-and-braces guard against any placeholder path.
# `sort -u` dedups; these are the leaves the registry claims exist.
registered="$(awk '/^## Registry/{f=1; next} /^## /{f=0} f' "$MAP" \
  | grep -oE '`'"$SRC_GLOB"'/[^`]+\.md`' | tr -d '`' | grep -v '<' | sort -u)"

# --- Check 1: every registered leaf exists on disk.
while IFS= read -r leaf; do
  [[ -z "$leaf" ]] && continue
  if [[ ! -f "$leaf" ]]; then
    echo "test-subsystem-docs: FAIL — registered leaf missing on disk: $leaf" >&2
    fail=1
  fi
done <<< "$registered"

# --- Check 2: every on-disk leaf AGENTS.md is registered.
# The leaf set is lib/leaf-docs.sh's (tracked AGENTS.md at any depth below
# $SRC_GLOB, minus the lint exempt zones such as vendored ThirdParty/), the same
# set setup-harness.sh shims.
ondisk_agents="$(leaf_agents_files "$SRC_GLOB" | sort -u)"
while IFS= read -r leaf; do
  [[ -z "$leaf" ]] && continue
  if ! grep -qF "$leaf" <<< "$registered"; then
    echo "test-subsystem-docs: FAIL — on-disk leaf not in $MAP registry: $leaf" >&2
    echo "    add a row for it, or remove the file." >&2
    fail=1
  fi
done <<< "$ondisk_agents"

# --- Check 3: no leaf invariant bullet duplicated verbatim in a central checklist.
# Normalise a line to plain lowercase text (strip markdown emphasis/backticks/list
# marker, collapse whitespace) so a copy-paste is caught regardless of formatting.
# Skip --selftest (structure-only).
_normalize() {
  sed -E 's/[`*_]//g; s/^[[:space:]]*-[[:space:]]+//; s/[[:space:]]+/ /g; s/^ //; s/ $//' \
    | tr '[:upper:]' '[:lower:]'
}
_check_central() { # $1 = central checklist; FAILs on each leaf bullet it restates
  local central="$1" central_norm leaf bullet norm
  central_norm="$(_normalize < "$central")"
  while IFS= read -r leaf; do
    [[ -z "$leaf" || ! -f "$leaf" ]] && continue
    # Only bullet lines inside the leaf that read as rules (start with "- "), long
    # enough that a match is meaningful (>= 60 normalised chars rules out short shared phrases).
    while IFS= read -r bullet; do
      norm="$(printf '%s' "$bullet" | _normalize)"
      [[ "${#norm}" -lt 60 ]] && continue
      if grep -qF "$norm" <<< "$central_norm"; then
        echo "test-subsystem-docs: FAIL — leaf rule duplicated in $central:" >&2
        echo "    leaf: $leaf" >&2
        echo "    rule: ${norm:0:80}..." >&2
        echo "    keep the rule in the leaf only; the central file points, it does not restate." >&2
        fail=1
      fi
    done < <(grep -E '^- ' "$leaf")
  done <<< "$ondisk_agents"
}
if [[ "$MODE" != "selftest" ]]; then
  for central in "${CENTRAL_FILES[@]}"; do
    if [[ -f "$central" ]]; then
      _check_central "$central"
    elif [[ "$central" != "${CENTRAL_FILES[0]}" ]]; then
      echo "test-subsystem-docs: FAIL — project.config.json docs.review_checklist names a missing file: $central" >&2
      fail=1
    fi
  done
fi

# --- Check 4 (diff mode only): README staleness WARN.
if [[ "$MODE" == "diff" ]]; then
  changed="$(git diff --name-only "$DIFF_REF"...HEAD 2>/dev/null || git diff --name-only "$DIFF_REF" 2>/dev/null || true)"
  # Every README the registry names (data-driven — a new row is picked up). Only
  # registered orientation docs: a vendored or plugin README below Source/ is not
  # a leaf and must not WARN.
  while IFS= read -r readme; do
    [[ -z "$readme" || ! -f "$readme" ]] && continue
    ctx_dir="$(dirname "$readme")"
    code_touched="$(grep -E "^${ctx_dir}/.*\.(cpp|h)$" <<< "$changed" || true)"
    readme_touched="$(grep -Fx "$readme" <<< "$changed" || true)"
    if [[ -n "$code_touched" && -z "$readme_touched" ]]; then
      echo "test-subsystem-docs: WARN — $ctx_dir code changed but $readme untouched (orientation may be stale)." >&2
      echo "    review $readme; if still accurate, touch it or add PR label 'subsystem-docs-out-of-band'." >&2
      warn=1
    fi
  done < <(grep -E '/README\.md$' <<< "$registered" || true)
fi

if [[ "$fail" -ne 0 ]]; then
  echo "test-subsystem-docs: FAILED" >&2
  # Summary line consumed by scripts/dev/test-all.sh (regex-extracted).
  echo "Passed: 0  Failed: 1"
  exit 1
fi
if [[ "$warn" -ne 0 ]]; then
  echo "test-subsystem-docs: passed with staleness warnings (non-blocking)." >&2
else
  echo "test-subsystem-docs: OK — registry, leaves, and central checklist in sync." >&2
fi
# Staleness is WARN-only — a warning still reports Failed: 0 so it never blocks the gate.
echo "Passed: 1  Failed: 0"
exit 0
