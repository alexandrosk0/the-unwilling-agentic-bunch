#!/usr/bin/env bats
# tests/bats/sync_issue_labels.bats
# ----------------------------------------------------------------------------
# Bats coverage for agents/scripts/project/sync-issue-labels.sh (issue-triage
# protocol Slice 2). Tests the gh-free surfaces: --check-parity (area:* labels <->
# the project's area map, docs/area-map.json in the project root) + manifest
# well-formedness. The live gh create/update path is exercised by the read-only
# dry-run against the repo (not mocked here).
#
# Requires: bash, bats, git, python3.
# ----------------------------------------------------------------------------

setup() {
    # The host's test-all.sh runs layer suites with PROJECT_ROOT pointed at the
    # layer and SMATCHET_PROJECT_ROOT_OVERRIDE=1, which would hide the host's area
    # map from the real-manifest case; let the script resolve the roots itself.
    unset PROJECT_ROOT AGENT_LAYER_ROOT PC_PROJECT_ROOT PC_AGENT_LAYER_ROOT
    unset SMATCHET_PROJECT_ROOT_OVERRIDE
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    export REPO_ROOT
    export SCRIPT="$REPO_ROOT/agents/scripts/project/sync-issue-labels.sh"
    export MANIFEST="$REPO_ROOT/agents/scripts/project/issue-labels.manifest"
    unset AREA_MAP_FILE ISSUE_LABELS_MANIFEST
    WORK="$BATS_TEST_TMPDIR"
    export WORK
}

# Area-map fixture: one route per argument (`-` prefix = a route with area null),
# plus a `generic_areas` list from $GENERIC (space-separated).
map() {
    local routes="" a sep=""
    for a in "$@"; do
        if [ "${a#-}" != "$a" ]; then
            routes="$routes$sep{\"area\": null, \"globs\": [\"${a#-}/**\"], \"docs\": [\"x.md\"]}"
        else
            routes="$routes$sep{\"area\": \"$a\", \"globs\": [\"src/$a/**\"], \"docs\": [\"x.md\"]}"
        fi
        sep=", "
    done
    local generic="" g gsep=""
    for g in ${GENERIC:-}; do generic="$generic$gsep\"$g\""; gsep=", "; done
    printf '{"routes": [%s], "generic_areas": [%s]}\n' "$routes" "$generic" > "$WORK/area-map.json"
}

parity() {
    ISSUE_LABELS_MANIFEST="$WORK/m.manifest" AREA_MAP_FILE="$WORK/area-map.json" \
        run bash "$SCRIPT" --check-parity
}

@test "real manifest passes --check-parity (SKIP when the layer is standalone)" {
    cd "$REPO_ROOT"
    run bash "$SCRIPT" --check-parity
    [ "$status" -eq 0 ]
    super="$(git -C "$REPO_ROOT" rev-parse --show-superproject-working-tree 2>/dev/null)"
    if [ -n "$super" ]; then
        [[ "$output" == *"parity OK"* ]]
    else
        [[ "$output" == *"parity SKIP"* ]]
    fi
}

@test "an area:* label with no route fails parity" {
    printf 'area:nonesuch|1d76db|bogus area\n' > "$WORK/m.manifest"
    map tracker-backend
    parity
    [ "$status" -eq 1 ]
    [[ "$output" == *"PARITY FAIL"* ]]
    [[ "$output" == *"area:nonesuch"* ]]
}

@test "a map area with no area:* label fails parity" {
    printf 'area:tracker-backend|1d76db|t\n' > "$WORK/m.manifest"
    map tracker-backend grid-engine
    parity
    [ "$status" -eq 1 ]
    [[ "$output" == *"PARITY FAIL"* ]]
    [[ "$output" == *"'grid-engine'"* ]]
}

@test "generic areas pass parity without a route" {
    printf 'area:ui|1d76db|general ui\narea:build|1d76db|build\n' > "$WORK/m.manifest"
    GENERIC="ui build" map
    parity
    [ "$status" -eq 0 ]
    [[ "$output" == *"parity OK"* ]]
}

@test "a subsystem area resolves to its route; null-area routes and non-area labels are ignored" {
    printf 'P0|b60205|crit\narea:tracker-backend|1d76db|t\n' > "$WORK/m.manifest"
    map tracker-backend -tests
    parity
    [ "$status" -eq 0 ]
    [[ "$output" == *"parity OK"* ]]
}

@test "a named area map that is missing exits 2" {
    printf 'area:ui|1d76db|ui\n' > "$WORK/m.manifest"
    ISSUE_LABELS_MANIFEST="$WORK/m.manifest" AREA_MAP_FILE="$WORK/none.json" \
        run bash "$SCRIPT" --check-parity
    [ "$status" -eq 2 ]
    [[ "$output" == *"missing area map"* ]]
}

@test "a malformed area map exits 2" {
    printf 'area:ui|1d76db|ui\n' > "$WORK/m.manifest"
    printf '{"routes": [' > "$WORK/area-map.json"
    parity
    [ "$status" -eq 2 ]
    [[ "$output" == *"malformed area map"* ]]
}

@test "manifest is well-formed (every non-comment line is name|color|desc, 6-hex color)" {
    run bash -c "grep -vE '^[[:space:]]*(#|\$)' '$MANIFEST' | awk -F'|' '{ if (NF<3) exit 1; if (\$2 !~ /^[0-9a-fA-F]{6}\$/) exit 2 }'"
    [ "$status" -eq 0 ]
}

@test "bad arg exits 2" {
    cd "$REPO_ROOT"
    run bash "$SCRIPT" --bogus
    [ "$status" -eq 2 ]
}
