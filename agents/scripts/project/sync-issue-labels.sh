#!/usr/bin/env bash
# sync-issue-labels.sh — reconcile the GitHub Issue label set from a checked-in
# manifest (agents/scripts/project/issue-labels.manifest), so the label set is
# reproducible and the area:<x> labels stay in parity with the project's area map
# (<project root>/docs/area-map.json — the path -> area routing table the
# coderabbit-triage skill and issue triage read).
#
# Issue-triage protocol (ADR-0014): docs/agent-rules/issue-triage.md § Labels.
# Plan: docs/plans/shipped/issue-triage-protocol.md § C.
#
# Usage:
#   bash agents/scripts/project/sync-issue-labels.sh                # dry-run (default): print the plan
#   bash agents/scripts/project/sync-issue-labels.sh --apply        # create/update labels via gh
#   bash agents/scripts/project/sync-issue-labels.sh --check-parity # area:* labels <-> area map
#
# Env:
#   REPO                  — owner/repo (default: derived from `gh repo view` in the project root, else alexandrosk0/Smatchet)
#   ISSUE_LABELS_MANIFEST — manifest path (default: the one beside this script)
#   AREA_MAP_FILE         — area map path (default: <project root>/docs/area-map.json)
#
# The manifest is layer content, read from this script's own tree; the area map is
# host content, read from PROJECT_ROOT (scripts/dev/project-config.sh: the
# superproject once the layer is the agent-layer/ submodule). A standalone layer has
# no area map, so --check-parity reports SKIP there; with a host, a missing map fails.
#
# Exit codes (test-script convention):
#   0 — dry-run printed / apply succeeded / parity OK or SKIP (standalone layer)
#   1 — parity drift (an area:* label with no route or generic area, or a map area with no label)
#   2 — bad args / missing manifest or map / malformed map / gh or python missing

set -uo pipefail

_sil_layer="$(cd "$(dirname "$0")/../../.." && pwd)" || exit 2
if [ -f "$_sil_layer/scripts/dev/project-config.sh" ]; then
    # shellcheck source=scripts/dev/project-config.sh
    PC_ROOTS_ONLY=1 . "$_sil_layer/scripts/dev/project-config.sh" || true
else
    unset PROJECT_ROOT AGENT_LAYER_ROOT  # no config beside this script (a fixture copy): its own tree, never an inherited root
fi
_sil_project="${PROJECT_ROOT:-$_sil_layer}"

# Paths are env-overridable so the bats harness can point --check-parity at fixtures.
MANIFEST="${ISSUE_LABELS_MANIFEST:-$_sil_layer/agents/scripts/project/issue-labels.manifest}"
AREA_MAP="${AREA_MAP_FILE:-$_sil_project/docs/area-map.json}"

MODE="dry-run"
case "${1:-}" in
    --apply)        MODE="apply" ;;
    --check-parity) MODE="parity" ;;
    "")             MODE="dry-run" ;;
    *) echo "usage: $0 [--apply|--check-parity]" >&2; exit 2 ;;
esac

[ -f "$MANIFEST" ] || { echo "sync-issue-labels: missing $MANIFEST" >&2; exit 2; }

# Read the manifest into parallel arrays (name / color / desc), skipping # + blanks.
names=(); colors=(); descs=()
while IFS='|' read -r name color desc; do
    case "$name" in ''|\#*) continue ;; esac
    name="$(printf '%s' "$name" | sed 's/[[:space:]]*$//')"
    [ -n "$name" ] || continue
    names+=("$name"); colors+=("$color"); descs+=("$desc")
done < "$MANIFEST"

# --- parity check: area:<x> labels <-> area-map areas (both directions) ---
if [ "$MODE" = "parity" ]; then
    if [ ! -f "$AREA_MAP" ]; then
        if [ -z "${AREA_MAP_FILE:-}" ] && [ "$(cd "$_sil_project" && pwd)" = "$_sil_layer" ]; then
            echo "sync-issue-labels: parity SKIP — standalone layer, no host area map at $AREA_MAP"
            exit 0
        fi
        echo "sync-issue-labels: missing area map $AREA_MAP" >&2
        exit 2
    fi
    # command -v alone is insufficient on Windows: the python3 Store-alias stub passes
    # it but exits 49 when run. Take the first candidate that actually executes.
    PY=""
    for _c in python3 python py; do
        if command -v "$_c" >/dev/null 2>&1 && "$_c" -c "" >/dev/null 2>&1; then PY="$_c"; break; fi
    done
    [ -n "$PY" ] || { echo "sync-issue-labels: python required for --check-parity" >&2; exit 2; }
    # One area name per line: every non-null route area, then every generic area.
    if ! map_areas="$("$PY" - "$AREA_MAP" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    routes = data["routes"]
    generic = data.get("generic_areas", [])
    areas = [r["area"] for r in routes if r.get("area") is not None] + list(generic)
except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
    sys.exit("sync-issue-labels: malformed area map %s: %s" % (sys.argv[1], exc))
for a in areas:
    print(a)
PY
)"; then
        exit 2
    fi
    miss=0
    label_areas=""
    for n in "${names[@]}"; do
        case "$n" in area:*) ;; *) continue ;; esac
        sub="${n#area:}"
        label_areas="$label_areas $sub "
        if ! printf '%s\n' "$map_areas" | grep -qxF -- "$sub"; then
            echo "PARITY FAIL: $n has no route in $AREA_MAP (add a route with \"area\": \"$sub\", list it in generic_areas, or drop the label)" >&2
            miss=1
        fi
    done
    while IFS= read -r a; do
        [ -n "$a" ] || continue
        case "$label_areas" in *" $a "*) continue ;; esac
        echo "PARITY FAIL: area '$a' in $AREA_MAP has no area:$a label in $MANIFEST (add the label, or set the route's area to null)" >&2
        miss=1
    done <<< "$map_areas"
    if [ "$miss" -eq 0 ]; then
        echo "sync-issue-labels: parity OK — every area:* label maps to an area-map route or generic area, and every map area has a label (${#names[@]} labels)"
        exit 0
    fi
    exit 1
fi

# gh derives the repo from the working directory: the labels belong to the project.
cd "$_sil_project" || exit 2
command -v gh >/dev/null 2>&1 || { echo "sync-issue-labels: gh required" >&2; exit 2; }
REPO="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo alexandrosk0/Smatchet)}"

# Snapshot existing labels (name<TAB>color<TAB>description).
existing="$(gh label list --repo "$REPO" --limit 200 \
    --json name,color,description \
    --jq '.[] | [.name, .color, .description] | @tsv' 2>/dev/null || true)"

creates=0; updates=0; nochange=0
for i in "${!names[@]}"; do
    n="${names[$i]}"; c="${colors[$i]}"; d="${descs[$i]}"
    line="$(printf '%s\n' "$existing" | awk -F'\t' -v n="$n" '$1==n {print; exit}')"
    if [ -z "$line" ]; then
        echo "  CREATE  $n  (#$c)  $d"
        creates=$((creates+1))
        if [ "$MODE" = "apply" ]; then
            gh label create "$n" --repo "$REPO" --color "$c" --description "$d" --force >/dev/null \
                || echo "sync-issue-labels: WARN create '$n' failed" >&2
        fi
    else
        cur_color="$(printf '%s' "$line" | cut -f2)"
        cur_desc="$(printf '%s' "$line" | cut -f3)"
        if [ "$cur_color" != "$c" ] || [ "$cur_desc" != "$d" ]; then
            echo "  UPDATE  $n  (#$cur_color→#$c)"
            updates=$((updates+1))
            if [ "$MODE" = "apply" ]; then
                gh label edit "$n" --repo "$REPO" --color "$c" --description "$d" >/dev/null \
                    || echo "sync-issue-labels: WARN edit '$n' failed" >&2
            fi
        else
            nochange=$((nochange+1))
        fi
    fi
done

verb=$([ "$MODE" = "apply" ] && echo "applied" || echo "would apply (dry-run; pass --apply)")
echo "sync-issue-labels: $verb — $creates create, $updates update, $nochange unchanged (repo $REPO)"
exit 0
