#!/usr/bin/env bats
# tests/bats/doc_anchors.bats
# ----------------------------------------------------------------------------
# Tests for agents/scripts/core/test_doc_anchors.py.
#
# A sandbox repo holds a copy of the checker at agents/scripts/core/ (it reads
# its anchors from its own tree, three levels up) plus the AGENTS.md /
# docs/agent-rules / leaf files the references point at, so every scenario is
# synthetic and the real tree is never scanned. The section sign is spliced in
# with printf so this file's own lines are not read as references. Covers the
# AGENTS.md / <dir>/AGENTS.md resolution and the citations of any other markdown
# file (`<path>.md` + section sign + heading; the checker's module doc step 6).
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
    if [ -n "${HOST:-}" ]; then rm -rf "$HOST"; fi
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

# ---------- <path>.md citations of any markdown file (module doc step 6) ----------

@test "a backticked <path>.md citation resolves against that file's headings" {
    _refs docs/refs.md "See \`docs/agent-rules/shared.md\` $S Shared section."
    _run
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 other cited markdown file(s)"* ]]
}

@test "a bare <path>.md citation of a heading the file lacks FAILs, naming the file" {
    # 'Root rules' is a heading of AGENTS.md, so the shared set would accept it:
    # the citation names shared.md, and only shared.md's headings count.
    _refs docs/refs.md "See docs/agent-rules/shared.md $S Root rules."
    _run
    [ "$status" -eq 1 ]
    [[ "$output" == *"'Root rules' in docs/agent-rules/shared.md"* ]]
}

@test "a broken backticked <path>.md citation FAILs" {
    _refs docs/refs.md "See \`docs/agent-rules/shared.md\` $S Tiered enforcement zones."
    _run
    [ "$status" -eq 1 ]
    [[ "$output" == *"'Tiered enforcement zones' in docs/agent-rules/shared.md"* ]]
}

@test "a **Bold**: paragraph is a citable section of its file" {
    printf '# Rules\n\n**Docking**: the dock rules.\n' > "$SANDBOX/docs/agent-rules/rules.md"
    git -C "$SANDBOX" add -- docs/agent-rules/rules.md
    _refs docs/refs.md "See \`docs/agent-rules/rules.md\` $S Docking."
    _run
    [ "$status" -eq 0 ]
}

@test "a code-span bold label and a blockquoted bold label are citable sections" {
    printf '# Label fixture\n\n**`[pre-first-push gate]` (mandatory before a push).** Text.\n\n> **Config drift — inert until re-run.** Text.\n' \
        > "$SANDBOX/docs/agent-rules/labels.md"
    git -C "$SANDBOX" add -- docs/agent-rules/labels.md
    _refs docs/refs.md "$(printf 'A docs/agent-rules/labels.md %s pre-first-push gate.\nB docs/agent-rules/labels.md %s Config drift.' "$S" "$S")"
    _run
    [ "$status" -eq 0 ]
}

@test "a heading cited without its parenthetical, list number or em-dash subtitle resolves" {
    # The title must not be a substring of any cited name (the resolver's
    # substring match would accept it), so it is deliberately distinctive.
    printf '# Variant fixture\n\n## Remote (cloud) bootstrap\n\n## 7. Gate-check vs baseline\n\n## PR batching — feature granularity\n' \
        > "$SANDBOX/docs/agent-rules/rules.md"
    git -C "$SANDBOX" add -- docs/agent-rules/rules.md
    _refs docs/refs.md "$(printf 'A docs/agent-rules/rules.md %s Remote bootstrap.\nB docs/agent-rules/rules.md %s Gate-check vs baseline.\nC docs/agent-rules/rules.md %s PR batching.' "$S" "$S" "$S")"
    _run
    [ "$status" -eq 0 ]
}

@test "a [label](<path>.md) citation is resolved relative to the citing file" {
    # From docs/, the href agent-rules/shared.md is docs/agent-rules/shared.md.
    _refs docs/refs.md "See [shared](agent-rules/shared.md) $S Root rules."
    _run
    [ "$status" -eq 1 ]
    [[ "$output" == *"'Root rules' in docs/agent-rules/shared.md"* ]]
}

@test "a bare basename prefers the citing file's sibling over the root file" {
    printf '# Tool\n\n## Republish\n' > "$SANDBOX/docs/README.md"
    printf '# Root readme\n' > "$SANDBOX/README.md"
    git -C "$SANDBOX" add -- docs/README.md README.md
    _refs docs/tool.md "See README.md $S Republish."
    _run
    [ "$status" -eq 0 ]
}

@test "every citation on a line is checked, not only the first" {
    _refs docs/refs.md "See \`docs/agent-rules/shared.md\` $S Shared section and \`docs/agent-rules/shared.md\` $S Gone section."
    _run
    [ "$status" -eq 1 ]
    [[ "$output" == *"'Gone section' in docs/agent-rules/shared.md"* ]]
}

@test "a <path>.md naming no existing file is skipped and counted, not failed" {
    _refs docs/refs.md "See docs/nowhere/missing.md $S Anything."
    _run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipped (path names no existing file): 1"* ]]
}

@test "shipped plans are frozen history and are not scanned" {
    _refs docs/plans/shipped/old.md "See \`docs/agent-rules/shared.md\` $S Renamed long ago."
    _run
    [ "$status" -eq 0 ]
}

@test "from a host, agent-layer/<path>.md resolves against the layer tree the checker reads" {
    HOST="$(mktemp -d)"
    HOST="$(cd "$HOST" && pwd -P)"
    mkdir -p "$HOST/docs"
    printf '%s\n' "Good: \`agent-layer/docs/agent-rules/shared.md\` $S Shared section." \
        "Layer path without the prefix: docs/agent-rules/shared.md $S Shared section." \
        > "$HOST/docs/refs.md"
    git -C "$HOST" init -q
    git -C "$HOST" add -A
    run env PROJECT_ROOT="$HOST" python3 "$CHECKER"
    [ "$status" -eq 0 ]
    printf '%s\n' "Bad: \`agent-layer/docs/agent-rules/shared.md\` $S Not there." >> "$HOST/docs/refs.md"
    git -C "$HOST" add -A
    run env PROJECT_ROOT="$HOST" python3 "$CHECKER"
    [ "$status" -eq 1 ]
    [[ "$output" == *"'Not there' in $SANDBOX/docs/agent-rules/shared.md"* ]]
}

# ---------- bare-basename rule-doc fallback (module doc step 6) ----------

@test "a bare basename naming no sibling or root file resolves in the layer's docs/agent-rules/" {
    _refs tools/notes.md "See shared.md $S Shared section."
    _run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipped (path names no existing file): 0"* ]]
    _refs tools/notes.md "See shared.md $S Gone section."
    _run
    [ "$status" -eq 1 ]
    [[ "$output" == *"'Gone section' in docs/agent-rules/shared.md"* ]]
}

@test "a bare basename naming no sibling or root file resolves in the layer's docs/guides/" {
    mkdir -p "$SANDBOX/docs/guides"
    printf '# Perf guide fixture\n\n## Spikes\n' > "$SANDBOX/docs/guides/perf-guide.md"
    git -C "$SANDBOX" add -- docs/guides
    _refs tools/notes.md "See perf-guide.md $S Spikes."
    _run
    [ "$status" -eq 0 ]
    _refs tools/notes.md "See perf-guide.md $S Steady pace."
    _run
    [ "$status" -eq 1 ]
    [[ "$output" == *"'Steady pace' in docs/guides/perf-guide.md"* ]]
}

@test "a bare basename two rule-doc directories answer to resolves against either" {
    mkdir -p "$SANDBOX/docs/guides"
    printf '# Twin rule fixture\n\n## Alpha section\n' > "$SANDBOX/docs/agent-rules/twin.md"
    printf '# Twin guide fixture\n\n## Beta section\n' > "$SANDBOX/docs/guides/twin.md"
    git -C "$SANDBOX" add -- docs
    _refs tools/notes.md "$(printf 'A twin.md %s Alpha section.\nB twin.md %s Beta section.' "$S" "$S")"
    _run
    [ "$status" -eq 0 ]
    _refs tools/notes.md "See twin.md $S Gamma section."
    _run
    [ "$status" -eq 1 ]
    [[ "$output" == *"'Gamma section' in docs/agent-rules/twin.md or docs/guides/twin.md"* ]]
}

@test "a bare link href gets no rule-doc fallback: markdown resolves it beside the citing file" {
    _refs tools/notes.md "See [shared](shared.md) $S Gone section."
    _run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipped (path names no existing file): 1"* ]]
}

@test "from a host, a bare basename resolves in the host's docs/guides/" {
    HOST="$(mktemp -d)"
    HOST="$(cd "$HOST" && pwd -P)"
    mkdir -p "$HOST/docs/guides" "$HOST/tools"
    printf '# Host guide fixture\n\n## Host recipes\n' > "$HOST/docs/guides/host-guide.md"
    printf '%s\n' "See host-guide.md $S Host recipes." > "$HOST/tools/notes.md"
    git -C "$HOST" init -q
    git -C "$HOST" add -A
    run env PROJECT_ROOT="$HOST" python3 "$CHECKER"
    [ "$status" -eq 0 ]
    printf '%s\n' "See host-guide.md $S Gone recipes." >> "$HOST/tools/notes.md"
    git -C "$HOST" add -A
    run env PROJECT_ROOT="$HOST" python3 "$CHECKER"
    [ "$status" -eq 1 ]
    [[ "$output" == *"'Gone recipes' in docs/guides/host-guide.md"* ]]
}

@test "a heading with a code span is citable by its text without the backticks" {
    printf '# Code heading fixture\n\n### The `405 ... is cancelled` recovery\n' > "$SANDBOX/docs/agent-rules/code.md"
    git -C "$SANDBOX" add -- docs/agent-rules/code.md
    _refs docs/refs.md "See docs/agent-rules/code.md $S The 405 ... is cancelled recovery."
    _run
    [ "$status" -eq 0 ]
}
