#!/usr/bin/env bats
# tests/bats/skill_reachability.bats
# ----------------------------------------------------------------------------
# Coverage for agents/scripts/core/test-skill-reachability.sh — the gate behind
# docs/agent-rules/AGENT-VS-SKILL.md § How a skill reaches every harness, rule 2:
# every agents/_shared/skills/<name>/SKILL.md needs a markdown path link in
# AGENTS.md or in a doc AGENTS.md links to (one hop). Prose mentions, fenced
# examples, images and deeper hops do not count.
# ----------------------------------------------------------------------------

setup() {
    LAYER_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    GATE="$LAYER_ROOT/agents/scripts/core/test-skill-reachability.sh"
    FX="$(mktemp -d)"
    mkdir -p "$FX/docs"
}

teardown() {
    rm -rf "${FX:-}"
}

# add_skill <root> <name> — a minimal SKILL.md.
add_skill() {
    mkdir -p "$1/agents/_shared/skills/$2"
    printf -- '---\nname: %s\n---\n' "$2" >"$1/agents/_shared/skills/$2/SKILL.md"
}

# A fixture layer: AGENTS.md links one skill directly and routes to docs/rules.md.
base_fixture() {
    add_skill "$FX" alpha
    cat >"$FX/AGENTS.md" <<'MD'
# Rules

| Trigger | Doc |
|---|---|
| debugging | [alpha skill](agents/_shared/skills/alpha/SKILL.md) |

Process detail: [rules](docs/rules.md).
MD
    printf '# Rules\n\n' >"$FX/docs/rules.md"
}

@test "real tree: every skill is reachable" {
    run bash "$GATE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Failed: 0"* ]]
    [[ "$output" != *"FAIL "* ]]
}

@test "--selftest passes" {
    run bash "$GATE" --selftest
    [ "$status" -eq 0 ]
    [[ "$output" == *"Passed: 2  Failed: 0"* ]]
}

@test "a skill linked from AGENTS.md passes" {
    base_fixture
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok   alpha — linked from AGENTS.md"* ]]
    [[ "$output" == *"Passed: 1  Failed: 0"* ]]
}

@test "a skill with no link fails" {
    base_fixture
    add_skill "$FX" orphan
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL orphan"* ]]
    [[ "$output" == *"Passed: 1  Failed: 1"* ]]
}

@test "a skill linked from a routed doc passes" {
    base_fixture
    add_skill "$FX" beta
    printf 'At this step run [beta](../agents/_shared/skills/beta/SKILL.md#the-loop).\n' >>"$FX/docs/rules.md"
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok   beta — linked from docs/rules.md"* ]]
    [[ "$output" == *"Passed: 2  Failed: 0"* ]]
}

@test "a reference-style link counts" {
    base_fixture
    add_skill "$FX" beta
    printf 'Run the [beta skill][b].\n\n[b]: ../agents/_shared/skills/beta/SKILL.md\n' >>"$FX/docs/rules.md"
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok   beta"* ]]
}

@test "a prose-only mention fails and is named in the hint" {
    base_fixture
    add_skill "$FX" gamma
    cat >>"$FX/docs/rules.md" <<'MD'
Use the gamma skill, at agents/_shared/skills/gamma/SKILL.md
(`agents/_shared/skills/gamma/SKILL.md`, or [`gamma`] in brackets).
MD
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL gamma"*"named in prose only in docs/rules.md"* ]]
}

@test "a link inside an inline code span does not count" {
    base_fixture
    add_skill "$FX" gamma
    printf 'Example: `[gamma](../agents/_shared/skills/gamma/SKILL.md)`.\n' >>"$FX/docs/rules.md"
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL gamma"* ]]
}

@test "a link inside a fenced code block does not count" {
    base_fixture
    add_skill "$FX" gamma
    cat >>"$FX/docs/rules.md" <<'MD'
```markdown
| t | [gamma](../agents/_shared/skills/gamma/SKILL.md) |
```
MD
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL gamma"* ]]
}

@test "an image link does not count" {
    base_fixture
    add_skill "$FX" gamma
    printf '![gamma](../agents/_shared/skills/gamma/SKILL.md)\n' >>"$FX/docs/rules.md"
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL gamma"* ]]
}

@test "a link two hops from AGENTS.md does not count" {
    base_fixture
    add_skill "$FX" delta
    printf 'More in [deep](deep.md).\n' >>"$FX/docs/rules.md"
    printf 'Run [delta](../agents/_shared/skills/delta/SKILL.md).\n' >"$FX/docs/deep.md"
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL delta"* ]]
}

@test "a doc AGENTS.md does not link is not a route" {
    base_fixture
    add_skill "$FX" delta
    printf 'Run [delta](../agents/_shared/skills/delta/SKILL.md).\n' >"$FX/docs/unrouted.md"
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL delta"* ]]
}

@test "a link to a different file in the skill dir does not count" {
    base_fixture
    add_skill "$FX" gamma
    printf 'x\n' >"$FX/agents/_shared/skills/gamma/REFERENCE.md"
    printf 'See [gamma recipes](../agents/_shared/skills/gamma/REFERENCE.md).\n' >>"$FX/docs/rules.md"
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL gamma"* ]]
}

@test "host root: resolves against the agent-layer/ mount's AGENTS.md" {
    HOST="$FX/host"
    mkdir -p "$HOST/agent-layer"
    add_skill "$HOST/agent-layer" alpha
    add_skill "$HOST/agent-layer" beta
    mkdir -p "$HOST/agent-layer/docs"
    printf '# Layer\n\n[alpha](agents/_shared/skills/alpha/SKILL.md) · [rules](docs/rules.md)\n' \
        >"$HOST/agent-layer/AGENTS.md"
    printf '[beta](../agents/_shared/skills/beta/SKILL.md)\n' >"$HOST/agent-layer/docs/rules.md"
    # The host's own AGENTS.md links neither skill: only the layer's routes count.
    printf '# Host\n\n@agent-layer/AGENTS.md\n' >"$HOST/AGENTS.md"
    run bash "$GATE" --root "$HOST"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Passed: 2  Failed: 0"* ]]
}

@test "inherited PROJECT_ROOT / AGENT_LAYER_ROOT do not redirect the check" {
    base_fixture
    add_skill "$FX" orphan
    PROJECT_ROOT="$FX" AGENT_LAYER_ROOT="$FX" SMATCHET_PROJECT_ROOT_OVERRIDE=1 run bash "$GATE"
    [ "$status" -eq 0 ]
    [[ "$output" != *"orphan"* ]]
}

@test "environment error: no skills dir exits 2" {
    printf '# Rules\n' >"$FX/AGENTS.md"
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Passed: 0  Failed: 0"* ]]
}

@test "environment error: no AGENTS.md exits 2" {
    add_skill "$FX" alpha
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 2 ]
}

@test "environment error: a skills dir with no SKILL.md exits 2" {
    mkdir -p "$FX/agents/_shared/skills/empty"
    printf '# Rules\n' >"$FX/AGENTS.md"
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 2 ]
}

@test "environment error: no python exits 2" {
    base_fixture
    SMATCHET_RESOLVE_PY_FORCE_NONE=1 run bash "$GATE" --root "$FX"
    [ "$status" -eq 2 ]
}

@test "environment error: an unknown argument exits 2" {
    run bash "$GATE" --bogus
    [ "$status" -eq 2 ]
}

@test "environment error: an explicit empty --root exits 2 (both forms)" {
    run bash "$GATE" --root ""
    [ "$status" -eq 2 ]
    [[ "$output" == *"--root needs a non-empty directory"* ]]
    run bash "$GATE" --root=
    [ "$status" -eq 2 ]
    [[ "$output" == *"--root needs a non-empty directory"* ]]
}

@test "a link inside a multi-line HTML comment does not count" {
    base_fixture
    add_skill "$FX" gamma
    cat >>"$FX/docs/rules.md" <<'MD'
Kept text. <!-- retired row:

| t | [gamma](../agents/_shared/skills/gamma/SKILL.md) |
-->
MD
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL gamma"* ]]
}

@test "a link inside a list-indented fence does not count" {
    base_fixture
    add_skill "$FX" gamma
    cat >>"$FX/docs/rules.md" <<'MD'
1. Step one:

       ```markdown
       [gamma](../agents/_shared/skills/gamma/SKILL.md)
       ```
MD
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL gamma"* ]]
}

@test "a fence line with an info string does not close an open fence" {
    base_fixture
    add_skill "$FX" gamma
    cat >>"$FX/docs/rules.md" <<'MD'
````markdown
```python
print("x")
```
[gamma](../agents/_shared/skills/gamma/SKILL.md)
````
MD
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL gamma"* ]]
}

@test "a code span wrapped across two lines hides its link" {
    base_fixture
    add_skill "$FX" gamma
    printf 'Example: `see\n[gamma](../agents/_shared/skills/gamma/SKILL.md)` here.\n' >>"$FX/docs/rules.md"
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL gamma"* ]]
}

@test "an escaped bracket is not a link" {
    base_fixture
    add_skill "$FX" gamma
    printf 'Literal: \\[gamma](../agents/_shared/skills/gamma/SKILL.md)\n' >>"$FX/docs/rules.md"
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL gamma"* ]]
}

@test "an unused reference definition does not count" {
    base_fixture
    add_skill "$FX" gamma
    printf 'No use of the label here.\n\n[g]: ../agents/_shared/skills/gamma/SKILL.md\n' >>"$FX/docs/rules.md"
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL gamma"* ]]
}

@test "collapsed and shortcut references count, labels case-insensitive" {
    base_fixture
    add_skill "$FX" beta
    add_skill "$FX" gamma
    printf 'Run [Beta Skill][] and [gamma].\n\n[beta   skill]: ../agents/_shared/skills/beta/SKILL.md\n[GAMMA]: ../agents/_shared/skills/gamma/SKILL.md\n' \
        >>"$FX/docs/rules.md"
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok   beta"* ]]
    [[ "$output" == *"ok   gamma"* ]]
}

@test "link text wrapped across two lines counts" {
    base_fixture
    add_skill "$FX" beta
    printf 'Run the [beta\nskill](../agents/_shared/skills/beta/SKILL.md) first.\n' >>"$FX/docs/rules.md"
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok   beta"* ]]
}

@test "an HTML anchor counts" {
    base_fixture
    add_skill "$FX" beta
    printf 'Run <a href="../agents/_shared/skills/beta/SKILL.md">beta</a>.\n' >>"$FX/docs/rules.md"
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok   beta"* ]]
}

@test "a comment opener quoted in a code span does not hide the links after it" {
    base_fixture
    add_skill "$FX" beta
    printf 'An unterminated `<!--` hides the rest.\n\nRun [beta](../agents/_shared/skills/beta/SKILL.md).\n' >>"$FX/docs/rules.md"
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok   beta"* ]]
}

@test "an inner fence shown indented inside a fenced example does not turn a later example into prose" {
    base_fixture
    add_skill "$FX" gamma
    cat >>"$FX/docs/rules.md" <<'MD'
```markdown
1. Build:
    ```bash
    make
    ```
```

Example of a skill row:

```
[gamma](../agents/_shared/skills/gamma/SKILL.md)
```
MD
    run bash "$GATE" --root "$FX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL gamma"* ]]
}
