#!/usr/bin/env bats
# tests/bats/setup_harness_render_template.bats — the rendered Cursor rule.
#
# setup-harness.sh renders .cursor/rules/agents.mdc from a template whose layer
# paths carry an {{AGENT_LAYER}} prefix: empty in a standalone layer checkout,
# `agent-layer/` in a host that mounts the layer. A verbatim copy pointed a
# mounted host at host-root paths that the flip moved under agent-layer/.
# The lib cases pin lib/render-template.sh; the end-to-end cases run the real
# setup-harness.sh cursor against both layouts.

setup() {
    LAYER_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # shellcheck source=agents/scripts/core/lib/render-template.sh
    . "$LAYER_ROOT/agents/scripts/core/lib/render-template.sh"
    TMP_TREE="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_TREE"
}

# Run the real setup-harness.sh cursor with $1 as the host root and $2 as the
# layer root, the way project-config.sh would resolve a mounted layer.
run_cursor_setup() {
    run bash -c 'cd "$1" && SMATCHET_PROJECT_ROOT_OVERRIDE=1 PROJECT_ROOT="$1" AGENT_LAYER_ROOT="$2" \
        bash "$2/agents/scripts/core/setup-harness.sh" cursor' _ "$1" "$2"
}

@test "layer_prefix: same directory renders nothing" {
    mkdir -p "$TMP_TREE/repo"
    [ "$(layer_prefix "$TMP_TREE/repo" "$TMP_TREE/repo")" = "" ]
}

@test "layer_prefix: a layer inside the host renders its relative path" {
    mkdir -p "$TMP_TREE/host/agent-layer"
    [ "$(layer_prefix "$TMP_TREE/host/agent-layer" "$TMP_TREE/host")" = "agent-layer/" ]
}

@test "layer_prefix: a layer outside the host renders its absolute path" {
    mkdir -p "$TMP_TREE/host" "$TMP_TREE/elsewhere/layer"
    [ "$(layer_prefix "$TMP_TREE/elsewhere/layer" "$TMP_TREE/host")" = "$TMP_TREE/elsewhere/layer/" ]
}

@test "layer_prefix: a symlinked mount still renders the relative path" {
    mkdir -p "$TMP_TREE/host" "$TMP_TREE/real-layer"
    ln -s "$TMP_TREE/real-layer" "$TMP_TREE/host/agent-layer"
    [ "$(layer_prefix "$TMP_TREE/host/agent-layer" "$TMP_TREE/host")" = "agent-layer/" ]
}

@test "render_template: substitutes every placeholder, keeps & literal, and is idempotent" {
    printf 'a `{{AGENT_LAYER}}agents/core/`\nb `{{AGENT_LAYER}}docs/`\n' > "$TMP_TREE/t.mdc"
    run render_template "$TMP_TREE/t.mdc" "$TMP_TREE/out/r.mdc" "x&y/"
    [ "$status" -eq 0 ]
    [[ "$output" == *"render"* ]]
    [ "$(cat "$TMP_TREE/out/r.mdc")" = "$(printf 'a `x&y/agents/core/`\nb `x&y/docs/`')" ]
    run render_template "$TMP_TREE/t.mdc" "$TMP_TREE/out/r.mdc" "x&y/"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "render_template: a locally edited destination is left alone" {
    printf 'p `{{AGENT_LAYER}}agents/`\n' > "$TMP_TREE/t.mdc"
    mkdir -p "$TMP_TREE/out"
    printf 'my own rule\n' > "$TMP_TREE/out/r.mdc"
    run render_template "$TMP_TREE/t.mdc" "$TMP_TREE/out/r.mdc" "agent-layer/" "$(file_sha256 "$TMP_TREE/t.mdc")"
    [[ "$output" == *"skip-copy"* ]]
    [ "$(cat "$TMP_TREE/out/r.mdc")" = "my own rule" ]
}

@test "render_template: a verbatim copy of a superseded version is upgraded" {
    printf 'old shipped rule `agents/core/`\n' > "$TMP_TREE/old.mdc"
    printf 'p `{{AGENT_LAYER}}agents/core/`\n' > "$TMP_TREE/t.mdc"
    mkdir -p "$TMP_TREE/out"
    cp "$TMP_TREE/old.mdc" "$TMP_TREE/out/r.mdc"
    run render_template "$TMP_TREE/t.mdc" "$TMP_TREE/out/r.mdc" "agent-layer/" "$(file_sha256 "$TMP_TREE/old.mdc")"
    [[ "$output" == *"upgrade"* ]]
    [ "$(cat "$TMP_TREE/out/r.mdc")" = 'p `agent-layer/agents/core/`' ]
}

@test "setup-harness cursor: a standalone layer gets layer-root paths that resolve" {
    # A minimal standalone layer: the script and what setup_cursor reads, plus the
    # directories the rule names. No project-config.sh beside the script, so both
    # roots resolve to the fixture itself and nothing touches this checkout.
    L="$TMP_TREE/layer"
    mkdir -p "$L/agents/scripts/core/lib" "$L/docs/harness/cursor/rules" \
        "$L/agents/core" "$L/agents/_shared"
    cp "$LAYER_ROOT/agents/scripts/core/setup-harness.sh" "$L/agents/scripts/core/"
    cp "$LAYER_ROOT"/agents/scripts/core/lib/render-template.sh \
        "$LAYER_ROOT"/agents/scripts/core/lib/agents-dir-current.sh "$L/agents/scripts/core/lib/"
    cp "$LAYER_ROOT/docs/harness/cursor/rules/agents.mdc" "$L/docs/harness/cursor/rules/"
    printf 'agent\n' > "$L/agents/core/sample.md"
    run bash -c 'cd "$1" && bash agents/scripts/core/setup-harness.sh cursor' _ "$L"
    [ "$status" -eq 0 ]
    rule="$L/.cursor/rules/agents.mdc"
    [ -f "$rule" ]
    ! grep -q '{{AGENT_LAYER}}' "$rule"
    ! grep -q 'agent-layer/' "$rule"
    while IFS= read -r p; do
        ( cd "$L" && compgen -G "$p" >/dev/null ) || { echo "unresolved: $p"; return 1; }
    done < <(grep -oE '`(agents/core|agents/_shared|docs/harness)[^`]*`' "$rule" | tr -d '`')
    [ "$(grep -cE '`(agents/core|agents/_shared|docs/harness)' "$rule")" -ge 3 ]
}

@test "setup-harness cursor: a mounted layer gets agent-layer/ paths that resolve from the host" {
    mkdir -p "$TMP_TREE/host/agents/project"
    ln -s "$LAYER_ROOT" "$TMP_TREE/host/agent-layer"
    run_cursor_setup "$TMP_TREE/host" "$TMP_TREE/host/agent-layer"
    [ "$status" -eq 0 ]
    rule="$TMP_TREE/host/.cursor/rules/agents.mdc"
    [ -f "$rule" ]
    ! grep -q '{{AGENT_LAYER}}' "$rule"
    # Every backticked layer path in the rule must exist from the host root.
    while IFS= read -r p; do
        ( cd "$TMP_TREE/host" && compgen -G "$p" >/dev/null ) || { echo "unresolved: $p"; return 1; }
    done < <(grep -o '`agent-layer/[^`]*`' "$rule" | tr -d '`')
    [ "$(grep -c '`agent-layer/' "$rule")" -ge 3 ]
}
