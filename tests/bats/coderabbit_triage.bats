#!/usr/bin/env bats
# tests/bats/coderabbit_triage.bats
# ----------------------------------------------------------------------------
# Bats tests for `agents/scripts/core/coderabbit-triage.py`:
#   - `selftest` — the skill<->py rules-version drift guard (campaign findings
#     core-agent-prompts-03 + core-scripts-python-03) plus area-map integrity.
#     agents/_shared/skills/coderabbit-triage/SKILL.md is source-of-truth for the
#     override table; coderabbit-triage.py is its executable mirror; both carry a
#     `triage-rules-version:` marker that must stay in lockstep.
#   - `area` — first-match-wins routing over the project's area map
#     (<project root>/docs/area-map.json, the root project-config.sh resolves;
#     AREA_MAP_FILE names a fixture).
#
# Requires: bash, a working python3 (exec-validated — the WinStore alias exits
# 49 on `-c ''`), bats, git.
# ----------------------------------------------------------------------------

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    export REPO_ROOT
    PY_SRC="$REPO_ROOT/agents/scripts/core/coderabbit-triage.py"
    MD_SRC="$REPO_ROOT/agents/_shared/skills/coderabbit-triage/SKILL.md"
    export PY_SRC MD_SRC
    unset AREA_MAP_FILE

    # Exec-validating python probe (agent_size.bats:25-29 canonical form): a
    # bare python3 can be a WinStore alias that resolves on PATH but exits 49.
    PY=""
    for c in python3 python py; do
        if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then
            PY="$c"
            break
        fi
    done
    [ -n "$PY" ] || skip "no working python interpreter"
    export PY

    WORK="$(mktemp -d)"
    export WORK
}

teardown() {
    [ -n "${WORK:-}" ] && rm -rf "$WORK"
}

# Build a mirror tree at $WORK with the real py + a (possibly tampered) SKILL.md,
# so the script's Path(__file__).parents[2]/_shared/skills/coderabbit-triage/SKILL.md
# lookup lands on our fixture. `$1` (optional) rewrites the SKILL.md marker version.
mirror() {
    local md_version="${1:-}"
    mkdir -p "$WORK/agents/scripts/core" "$WORK/agents/_shared/skills/coderabbit-triage"
    cp "$PY_SRC" "$WORK/agents/scripts/core/coderabbit-triage.py"
    if [ -n "$md_version" ]; then
        sed "s/triage-rules-version: [0-9][0-9]*/triage-rules-version: ${md_version}/" \
            "$MD_SRC" > "$WORK/agents/_shared/skills/coderabbit-triage/SKILL.md"
    else
        cp "$MD_SRC" "$WORK/agents/_shared/skills/coderabbit-triage/SKILL.md"
    fi
}

# The py marker, read from the real script (so a lockstep bump needs no test edit).
py_marker() {
    sed -n 's/^# triage-rules-version: \([0-9][0-9]*\)$/\1/p' "$PY_SRC" | head -n1
}

# Write a fixture project at $WORK/proj: docs/area-map.json (from stdin) plus the
# docs it cites. Doc paths resolve against the directory above the map's docs/.
fixture_map() {
    mkdir -p "$WORK/proj/docs" "$WORK/proj/src/net" "$WORK/proj/src/ui"
    printf '# net\n' > "$WORK/proj/src/net/AGENTS.md"
    printf '# ui\n' > "$WORK/proj/src/ui/AGENTS.md"
    cat > "$WORK/proj/docs/area-map.json"
}

good_map() {
    fixture_map <<'JSON'
{
  "routes": [
    {"area": "net-widgets", "globs": ["src/ui/**/NetWidget*"], "docs": ["src/net/AGENTS.md", "src/ui/AGENTS.md"]},
    {"area": "net", "globs": ["src/net/**", "**/{Http,Socket}Client*"], "docs": ["src/net/AGENTS.md"]},
    {"area": "ui", "globs": ["src/ui/**"], "docs": ["src/ui/AGENTS.md"]},
    {"area": null, "globs": ["tests/**"], "docs": ["src/net/AGENTS.md"]}
  ],
  "generic_areas": ["build"]
}
JSON
}

@test "selftest passes on the real tree (skill and py markers in sync)" {
    run "$PY" "$PY_SRC" selftest
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
    [[ "$output" == *"in sync"* ]]
}

@test "selftest reports the invariant-rule count" {
    run "$PY" "$PY_SRC" selftest
    [ "$status" -eq 0 ]
    [[ "$output" == *"invariant rules"* ]]
}

@test "selftest validates the host area map when the layer is mounted in a host" {
    # The host is the PROJECT_ROOT project-config.sh resolves with no inherited root, the way a
    # caller runs the script: the host's test-all.sh points layer suites at the layer itself
    # (PROJECT_ROOT=<layer> + SMATCHET_PROJECT_ROOT_OVERRIDE=1), which would otherwise skip this,
    # the only CI check that every route's docs still exist.
    local host
    host="$(host_root)"
    if [ -z "$host" ] || [ ! -f "$host/docs/area-map.json" ]; then
        skip "standalone layer: no host area map"
    fi
    run_rooted "$PY" "$PY_SRC" selftest
    [ "$status" -eq 0 ]
    [[ "$output" == *"area map OK"* ]]
}

@test "selftest FAILS when the SKILL.md marker drifts from the py marker" {
    mirror 99
    run "$PY" "$WORK/agents/scripts/core/coderabbit-triage.py" selftest
    [ "$status" -eq 1 ]
    [[ "$output" == *"DRIFT"* ]]
}

@test "selftest FAILS when the SKILL.md marker is absent entirely" {
    mkdir -p "$WORK/agents/scripts/core" "$WORK/agents/_shared/skills/coderabbit-triage"
    cp "$PY_SRC" "$WORK/agents/scripts/core/coderabbit-triage.py"
    grep -v 'triage-rules-version:' "$MD_SRC" > "$WORK/agents/_shared/skills/coderabbit-triage/SKILL.md"
    run "$PY" "$WORK/agents/scripts/core/coderabbit-triage.py" selftest
    [ "$status" -eq 1 ]
    [[ "$output" == *"marker"* ]]
}

@test "selftest FAILS when the skill is missing" {
    mkdir -p "$WORK/agents/scripts/core"
    cp "$PY_SRC" "$WORK/agents/scripts/core/coderabbit-triage.py"
    run "$PY" "$WORK/agents/scripts/core/coderabbit-triage.py" selftest
    [ "$status" -eq 1 ]
    [[ "$output" == *"SKILL.md not found"* ]]
}

@test "selftest passes again when a drifted SKILL.md is bumped back into sync" {
    v="$(py_marker)"
    [ -n "$v" ]
    mirror "$v"
    run "$PY" "$WORK/agents/scripts/core/coderabbit-triage.py" selftest
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "selftest accepts a sound area map" {
    good_map
    AREA_MAP_FILE="$WORK/proj/docs/area-map.json" run "$PY" "$PY_SRC" selftest
    [ "$status" -eq 0 ]
    [[ "$output" == *"area map OK (4 routes)"* ]]
}

@test "selftest FAILS when an area-map route cites a missing doc" {
    fixture_map <<'JSON'
{"routes": [{"area": "net", "globs": ["src/net/**"], "docs": ["src/net/NOPE.md"]}]}
JSON
    AREA_MAP_FILE="$WORK/proj/docs/area-map.json" run "$PY" "$PY_SRC" selftest
    [ "$status" -eq 1 ]
    [[ "$output" == *"src/net/NOPE.md"* ]]
}

@test "selftest FAILS when an area names two routes or a route has no globs" {
    fixture_map <<'JSON'
{"routes": [
  {"area": "net", "globs": ["src/net/**"], "docs": ["src/net/AGENTS.md"]},
  {"area": "net", "globs": [], "docs": ["src/net/AGENTS.md"]}
]}
JSON
    AREA_MAP_FILE="$WORK/proj/docs/area-map.json" run "$PY" "$PY_SRC" selftest
    [ "$status" -eq 1 ]
    [[ "$output" == *"more than one route"* ]]
    [[ "$output" == *"globs"* ]]
}

@test "selftest FAILS on a malformed area map and on a missing AREA_MAP_FILE" {
    fixture_map <<'JSON'
{"routes": [
JSON
    AREA_MAP_FILE="$WORK/proj/docs/area-map.json" run "$PY" "$PY_SRC" selftest
    [ "$status" -eq 1 ]
    [[ "$output" == *"not valid JSON"* ]]
    AREA_MAP_FILE="$WORK/proj/docs/none.json" run "$PY" "$PY_SRC" selftest
    [ "$status" -eq 1 ]
    [[ "$output" == *"missing file"* ]]
}

@test "area: first matching route wins, null area and no match print '-'" {
    good_map
    AREA_MAP_FILE="$WORK/proj/docs/area-map.json" run "$PY" "$PY_SRC" area \
        src/ui/panels/NetWidgetList.cpp src/ui/Panel.cpp ./src/net/Client.cpp \
        lib/x/HttpClient.h tests/net/ClientTest.cpp other/README.md
    [ "$status" -eq 0 ]
    [[ "$output" == *$'src/ui/panels/NetWidgetList.cpp\tnet-widgets\tsrc/net/AGENTS.md src/ui/AGENTS.md'* ]]
    [[ "$output" == *$'src/ui/Panel.cpp\tui\tsrc/ui/AGENTS.md'* ]]
    [[ "$output" == *$'./src/net/Client.cpp\tnet\tsrc/net/AGENTS.md'* ]]
    [[ "$output" == *$'lib/x/HttpClient.h\tnet\t'* ]]
    [[ "$output" == *$'tests/net/ClientTest.cpp\t-\tsrc/net/AGENTS.md'* ]]
    [[ "$output" == *$'other/README.md\t-\t-'* ]]
}

@test "area: '*' stays within one path segment" {
    fixture_map <<'JSON'
{"routes": [{"area": "net", "globs": ["src/*.cpp"], "docs": ["src/net/AGENTS.md"]}]}
JSON
    AREA_MAP_FILE="$WORK/proj/docs/area-map.json" run "$PY" "$PY_SRC" area src/a.cpp src/net/b.cpp
    [ "$status" -eq 0 ]
    [[ "$output" == *$'src/a.cpp\tnet'* ]]
    [[ "$output" == *$'src/net/b.cpp\t-\t-'* ]]
}

# Run the real script with the project-root env cleared, then the given assignments.
run_rooted() {
    run env -u PROJECT_ROOT -u PC_PROJECT_ROOT -u AGENT_LAYER_ROOT -u PC_AGENT_LAYER_ROOT \
        -u SMATCHET_PROJECT_ROOT_OVERRIDE -u SMATCHET_PROJECT_CONFIG "$@"
}

# The project root project-config.sh resolves for this checkout with no inherited root.
host_root() {
    env -u PROJECT_ROOT -u PC_PROJECT_ROOT -u AGENT_LAYER_ROOT -u PC_AGENT_LAYER_ROOT \
        -u SMATCHET_PROJECT_ROOT_OVERRIDE -u SMATCHET_PROJECT_CONFIG \
        bash -c 'PC_ROOTS_ONLY=1 . "$1" >/dev/null 2>&1; printf %s "${PROJECT_ROOT:-}"' _ \
        "$REPO_ROOT/scripts/dev/project-config.sh"
}

@test "area: finds the map under a SMATCHET_PROJECT_CONFIG host, like sync-issue-labels.sh" {
    good_map
    run_rooted SMATCHET_PROJECT_CONFIG="$WORK/proj" "$PY" "$PY_SRC" area src/net/a.cpp
    [ "$status" -eq 0 ]
    [[ "$output" == *$'src/net/a.cpp\tnet\tsrc/net/AGENTS.md'* ]]
    run_rooted SMATCHET_PROJECT_CONFIG="$WORK/proj" "$PY" "$PY_SRC" selftest
    [ "$status" -eq 0 ]
    [[ "$output" == *"area map OK (4 routes)"* ]]
}

@test "area: honours PROJECT_ROOT only with SMATCHET_PROJECT_ROOT_OVERRIDE=1" {
    good_map
    run_rooted PROJECT_ROOT="$WORK/proj" SMATCHET_PROJECT_ROOT_OVERRIDE=1 "$PY" "$PY_SRC" area src/ui/x.cpp
    [ "$status" -eq 0 ]
    [[ "$output" == *$'src/ui/x.cpp\tui\tsrc/ui/AGENTS.md'* ]]
    run_rooted PROJECT_ROOT="$WORK/proj" "$PY" "$PY_SRC" area src/ui/x.cpp
    [[ "$output" == *"ignoring PROJECT_ROOT"* ]]
    [[ "$output" != *$'src/ui/x.cpp\tui'* ]]
}

@test "area: a fixture copy without project-config.sh ignores an inherited PROJECT_ROOT" {
    good_map
    mirror
    run_rooted PROJECT_ROOT="$WORK/proj" SMATCHET_PROJECT_ROOT_OVERRIDE=1 \
        "$PY" "$WORK/agents/scripts/core/coderabbit-triage.py" area src/ui/x.cpp
    [ "$status" -eq 2 ]
    [[ "$output" == *"no area map at $WORK/docs/area-map.json"* ]]
}

@test "area: exits 2 when there is no area map" {
    AREA_MAP_FILE="$WORK/none.json" run "$PY" "$PY_SRC" area src/a.cpp
    [ "$status" -eq 2 ]
    [[ "$output" == *"no area map"* ]]
}
