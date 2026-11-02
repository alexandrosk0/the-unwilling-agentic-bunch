#!/usr/bin/env bats
# tests/bats/doc_anchors.bats
# ----------------------------------------------------------------------------
# Tests for agents/scripts/core/test_doc_anchors.py.
#
# A sandbox repo holds a copy of the checker at agents/scripts/core/ (it reads
# its anchors from its own tree, three levels up) plus the AGENTS.md /
# docs/agent-rules / leaf files the references point at, so every scenario is
# synthetic and the real tree is never scanned. The section sign is spliced in
# with printf so this file's own lines are not read as references.
# ----------------------------------------------------------------------------

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    CHECKER_SRC="$REPO_ROOT/agents/scripts/core/test_doc_anchors.py"
    SANDBOX="$(mktemp -d)"
    SANDBOX="$(cd "$SANDBOX" && pwd -P)"
    S="$(printf '\302\247')"
    mkdir -p "$SANDBOX/agents/scripts/core" "$SANDBOX/docs/agent-rules" "$SANDBOX/Source/Core/src/Ui"
    cp "$CHECKER_SRC" "$SANDBOX/agents/scripts/core/test_doc_anchors.py"
    printf '# Root\n\n## Root rules\n' > "$SANDBOX/AGENTS.md"
    printf '## Shared section\n' > "$SANDBOX/docs/agent-rules/shared.md"
    printf '# Ui\n\n## Grid\n' > "$SANDBOX/Source/Core/src/Ui/AGENTS.md"
    git -C "$SANDBOX" init -q
    # Track only the fixtures: the copied checker's own docstring cites real
    # sections the sandbox does not have.
    git -C "$SANDBOX" add -- AGENTS.md docs Source
    CHECKER="$SANDBOX/agents/scripts/core/test_doc_anchors.py"
}

teardown() {
    if [ -n "${SANDBOX:-}" ]; then rm -rf "$SANDBOX"; fi
    if [ -n "${DECOY:-}" ]; then rm -rf "$DECOY"; fi
}

_refs() { # $1 = file (sandbox-relative), $2 = content
    mkdir -p "$(dirname "$SANDBOX/$1")"
    printf '%s\n' "$2" > "$SANDBOX/$1"
    git -C "$SANDBOX" add -- "$1"
}

_run() { run env PROJECT_ROOT="$SANDBOX" python3 "$CHECKER"; }

@test "--selftest passes" {
    run python3 "$CHECKER" --selftest
    [ "$status" -eq 0 ]
    [[ "$output" == *"--selftest: PASS"* ]]
}

@test "--selftest under an exported GIT_DIR leaves that repository untouched" {
    DECOY="$(mktemp -d)"
    git init -q "$DECOY/repo"
    git -C "$DECOY/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed
    before="$(git -C "$DECOY/repo" config --list --local | sort)"
    GIT_DIR="$DECOY/repo/.git" run python3 "$CHECKER" --selftest
    [ "$status" -eq 0 ]
    [ "$(git -C "$DECOY/repo" config --list --local | sort)" = "$before" ]
    [ -z "$(git -C "$DECOY/repo" status --porcelain)" ]
}

@test "a path-qualified leaf reference resolves against that leaf" {
    _refs docs/refs.md "See Source/Core/src/Ui/AGENTS.md $S Grid."
    _run
    [ "$status" -eq 0 ]
}

@test "a path-qualified leaf reference to a root-only section FAILs, naming the leaf" {
    _refs docs/refs.md "See Source/Core/src/Ui/AGENTS.md $S Root rules."
    _run
    [ "$status" -eq 1 ]
    [[ "$output" == *"'Root rules' in Source/Core/src/Ui/AGENTS.md"* ]]
}

@test "an unqualified reference still resolves against AGENTS.md + docs/agent-rules" {
    _refs docs/refs.md "See AGENTS.md $S Shared section."
    _run
    [ "$status" -eq 0 ]
}

@test "a ./ reference in a leaf directory resolves against the sibling leaf, not the root" {
    _refs Source/Core/src/Ui/README.md "See ./AGENTS.md $S Grid."
    _run
    [ "$status" -eq 0 ]
}

@test "a path naming no existing file keeps the shared anchor set (lenient, as before)" {
    _refs docs/refs.md "See agent-layer/AGENTS.md $S Root rules."
    _run
    [ "$status" -eq 0 ]
}
