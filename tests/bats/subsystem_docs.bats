#!/usr/bin/env bats
# tests/bats/subsystem_docs.bats
# ----------------------------------------------------------------------------
# Tests for agents/scripts/project/test-subsystem-docs.sh.
#
# Each test runs the gate inside a throwaway sandbox git repo scaffolded to the
# layout the gate expects (the gate cd's to its own `../../..`, so copying it
# into <sandbox>/agents/scripts/project/ scopes every check to the sandbox).
# This keeps synthetic failure scenarios (missing leaf, unregistered leaf,
# duplicated rule, stale README) from touching the real tree.
#
# Requires: bash, git, bats.
# ----------------------------------------------------------------------------

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    GATE_SRC="$REPO_ROOT/agents/scripts/project/test-subsystem-docs.sh"
    SANDBOX="$(mktemp -d)"

    mkdir -p "$SANDBOX/agents/scripts/project" "$SANDBOX/agents/core" \
             "$SANDBOX/Source/Core/src/Tracker"
    cp "$GATE_SRC" "$SANDBOX/agents/scripts/project/test-subsystem-docs.sh"

    printf '# code-review\n\nGlobal rules only; subsystem invariants live in the leaves.\n' \
        > "$SANDBOX/agents/core/code-review.md"

    printf '# Tracker rules\n\n## Invariants\n- No backend leak into the shared tracker interface family for any concrete backend.\n' \
        > "$SANDBOX/Source/Core/src/Tracker/AGENTS.md"

    cat > "$SANDBOX/CONTEXT-MAP.md" <<'MAP'
# CONTEXT-MAP

## Registry

| Subsystem | Rules | Glossary | Orientation |
|---|---|---|---|
| Tracker | `Source/Core/src/Tracker/AGENTS.md` | — | — |

## Growth path
Add `Source/Core/src/<ctx>/AGENTS.md` when content exists.
MAP

    git -C "$SANDBOX" init -q
    git -C "$SANDBOX" -c user.email=t@t.test -c user.name=test add -A
    git -C "$SANDBOX" -c user.email=t@t.test -c user.name=test commit -qm init

    GATE="$SANDBOX/agents/scripts/project/test-subsystem-docs.sh"
}

teardown() {
    [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
}

_commit() {
    git -C "$SANDBOX" -c user.email=t@t.test -c user.name=test add -A
    git -C "$SANDBOX" -c user.email=t@t.test -c user.name=test commit -qm "$1"
}

@test "clean tree passes with summary line" {
    run bash "$GATE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Passed: 1  Failed: 0"* ]]
}

@test "selftest passes on a consistent registry" {
    run bash "$GATE" --selftest
    [ "$status" -eq 0 ]
}

@test "registered leaf missing on disk FAILs" {
    rm "$SANDBOX/Source/Core/src/Tracker/AGENTS.md"
    run bash "$GATE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"registered leaf missing on disk"* ]]
    [[ "$output" == *"Passed: 0  Failed: 1"* ]]
}

@test "on-disk leaf absent from registry FAILs" {
    mkdir -p "$SANDBOX/Source/Core/src/Sync"
    printf '# Sync rules\n' > "$SANDBOX/Source/Core/src/Sync/AGENTS.md"
    _commit "add unregistered Sync leaf"
    run bash "$GATE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not in"* ]]
    [[ "$output" == *"registry"* ]]
}

@test "leaf rule duplicated in the central checklist FAILs" {
    printf -- '- No backend leak into the shared tracker interface family for any concrete backend.\n' \
        >> "$SANDBOX/agents/core/code-review.md"
    run bash "$GATE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"duplicated"* ]]
}

@test "README staleness WARNs but never blocks" {
    printf '# Tracker orientation\n' > "$SANDBOX/Source/Core/src/Tracker/README.md"
    printf 'int x = 1;\n' > "$SANDBOX/Source/Core/src/Tracker/JiraClient.cpp"
    # register the README cell
    sed -i 's#| — | — |#| — | `Source/Core/src/Tracker/README.md` |#' "$SANDBOX/CONTEXT-MAP.md"
    _commit "add README + code baseline"
    printf 'int x = 1; int y = 2;\n' > "$SANDBOX/Source/Core/src/Tracker/JiraClient.cpp"
    _commit "change code, leave README untouched"
    run bash "$GATE" --diff HEAD~1
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN"* ]]
    [[ "$output" == *"orientation may be stale"* ]]
    [[ "$output" == *"Passed: 1  Failed: 0"* ]]
}

@test "data-driven: a second subsystem README is discovered for staleness" {
    mkdir -p "$SANDBOX/Source/Core/src/Persistence"
    printf '# Persistence rules\n' > "$SANDBOX/Source/Core/src/Persistence/AGENTS.md"
    printf '# Persistence orientation\n' > "$SANDBOX/Source/Core/src/Persistence/README.md"
    printf 'int a = 0;\n' > "$SANDBOX/Source/Core/src/Persistence/LocalCacheManager.cpp"
    # Rewrite the registry with both subsystems (avoids sed/delimiter pitfalls).
    cat > "$SANDBOX/CONTEXT-MAP.md" <<'MAP'
# CONTEXT-MAP

## Registry

| Subsystem | Rules | Glossary | Orientation |
|---|---|---|---|
| Tracker | `Source/Core/src/Tracker/AGENTS.md` | — | — |
| Persistence | `Source/Core/src/Persistence/AGENTS.md` | — | `Source/Core/src/Persistence/README.md` |

## Growth path
Add a row when content exists.
MAP
    _commit "add Persistence leaf + README + code baseline"
    printf 'int a = 0; int b = 1;\n' > "$SANDBOX/Source/Core/src/Persistence/LocalCacheManager.cpp"
    _commit "change Persistence code only"
    run bash "$GATE" --diff HEAD~1
    [ "$status" -eq 0 ]
    [[ "$output" == *"Source/Core/src/Persistence"* ]]
    [[ "$output" == *"WARN"* ]]
}

# --- Leaves below Source/ outside Source/Core/src, and the host checklist -----

# The sandbox gains the real project-config.sh + a minimal project.config.json so
# the gate's full config load reads docs.review_checklist from the sandbox host.
_with_config() { # $1 = docs object JSON
    mkdir -p "$SANDBOX/scripts/dev"
    cp "$REPO_ROOT/scripts/dev/project-config.sh" "$SANDBOX/scripts/dev/project-config.sh"
    printf '{"docs": %s}\n' "$1" > "$SANDBOX/project.config.json"
    _commit "config"
}

_register_plugin_leaf() {
    mkdir -p "$SANDBOX/Source/Plugins/Mcp"
    printf '# Mcp rules\n\n## Invariants\n- Tool descriptions are written for an LLM consumer because clients show them verbatim.\n' \
        > "$SANDBOX/Source/Plugins/Mcp/AGENTS.md"
    cat > "$SANDBOX/CONTEXT-MAP.md" <<'MAP'
# CONTEXT-MAP

## Registry

| Subsystem | Rules | Glossary | Orientation |
|---|---|---|---|
| Tracker | `Source/Core/src/Tracker/AGENTS.md` | — | — |
| Mcp | `Source/Plugins/Mcp/AGENTS.md` | — | — |

## Growth path
Add a row when content exists.
MAP
    _commit "add Mcp plugin leaf"
}

@test "leaf outside Source/Core/src: unregistered FAILs" {
    mkdir -p "$SANDBOX/Source/Plugins/Mcp"
    printf '# Mcp rules\n' > "$SANDBOX/Source/Plugins/Mcp/AGENTS.md"
    _commit "add unregistered plugin leaf"
    run bash "$GATE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"on-disk leaf not in"*"Source/Plugins/Mcp/AGENTS.md"* ]]
}

@test "leaf outside Source/Core/src: registered passes, and its bullets are checked against the central checklist" {
    _register_plugin_leaf
    run bash "$GATE"
    [ "$status" -eq 0 ]
    printf -- '- Tool descriptions are written for an LLM consumer because clients show them verbatim.\n' \
        >> "$SANDBOX/agents/core/code-review.md"
    run bash "$GATE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"leaf rule duplicated"*"Source/Plugins/Mcp/AGENTS.md"* ]]
}

@test "an unregistered README below Source/ is not a leaf and never WARNs" {
    mkdir -p "$SANDBOX/Source/UnrealPlugins/Thing"
    printf '# Plugin readme\n' > "$SANDBOX/Source/UnrealPlugins/Thing/README.md"
    printf 'int x = 1;\n' > "$SANDBOX/Source/UnrealPlugins/Thing/Thing.cpp"
    _commit "plugin baseline"
    printf 'int x = 2;\n' > "$SANDBOX/Source/UnrealPlugins/Thing/Thing.cpp"
    _commit "change plugin code"
    run bash "$GATE" --diff HEAD~1
    [ "$status" -eq 0 ]
    [[ "$output" != *"WARN"* ]]
}

@test "host checklist (docs.review_checklist): a leaf rule restated there FAILs" {
    mkdir -p "$SANDBOX/docs/guides"
    printf '# Review checklist\n\n- No backend leak into the shared tracker interface family for any concrete backend.\n' \
        > "$SANDBOX/docs/guides/review-checklist.md"
    _with_config '{"review_checklist": "docs/guides/review-checklist.md"}'
    run bash "$GATE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"leaf rule duplicated in docs/guides/review-checklist.md"* ]]
}

@test "host checklist (docs.review_checklist): a clean checklist passes" {
    mkdir -p "$SANDBOX/docs/guides"
    printf '# Review checklist\n\n- Trace execution order through the scheduler, never lexical order.\n' \
        > "$SANDBOX/docs/guides/review-checklist.md"
    _with_config '{"review_checklist": "docs/guides/review-checklist.md"}'
    run bash "$GATE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Passed: 1  Failed: 0"* ]]
}

@test "host checklist (docs.review_checklist): a configured path that does not exist FAILs" {
    _with_config '{"review_checklist": "docs/guides/no-such-checklist.md"}'
    run bash "$GATE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"docs.review_checklist names a missing file: docs/guides/no-such-checklist.md"* ]]
}

@test "no docs.review_checklist key: only the layer checklist is used" {
    _with_config '{"taxonomy_exceptions": []}'
    run bash "$GATE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Passed: 1  Failed: 0"* ]]
}
