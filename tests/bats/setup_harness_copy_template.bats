#!/usr/bin/env bats
# tests/bats/setup_harness_copy_template.bats — copy_template's upgrade path.
#
# setup-harness.sh copies hook scripts and other adapter templates into the
# host (.claude/hooks/*.sh, .claude/settings.json, ...). A copy that differs from
# the template used to be skipped as "user-modified" even when it was a verbatim
# copy of an OLDER version of that template, so a hook fix never reached an
# already-provisioned checkout (.claude/hooks/guard-plan-lock.sh stayed at the
# 33f2fa2 version after a bump to f39a7dd). copy_template now upgrades a copy that
# matches any version in the layer's git history and still skips a real edit.
#
# The cases load the real copy_template (and the helpers it calls) out of
# setup-harness.sh and run it with ROOT pointed at a fixture layer: a temp git
# repo whose template has two committed versions. The script's top level is not
# sourced, so nothing touches the real repo.
#
# Requires: bash, git, bats.

setup() {
    LAYER_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$LAYER_ROOT/agents/scripts/core/setup-harness.sh"
    BASE="$(mktemp -d)"
    FIX="$BASE/layer"
    HOST="$BASE/host"
    mkdir -p "$FIX/docs/hooks" "$HOST"
    git init -q "$FIX"
    git -C "$FIX" config user.email t@local
    git -C "$FIX" config user.name t
    git -C "$FIX" config commit.gpgsign false
    printf '#!/usr/bin/env bash\necho v1\n' > "$FIX/docs/hooks/h.sh"
    git -C "$FIX" add -A
    git -C "$FIX" commit -qm v1
    V1_SHORT="$(git -C "$FIX" rev-parse --short HEAD)"
    cp "$FIX/docs/hooks/h.sh" "$BASE/h.v1"
    printf '#!/usr/bin/env bash\necho v2\n' > "$FIX/docs/hooks/h.sh"
    git -C "$FIX" commit -qam v2
}

teardown() { rm -rf "$BASE" 2>/dev/null || true; }

# run_copy <layer-root> <src> <dst> — run the real copy_template from the host
# root, the way setup-harness.sh does (cwd = host, ROOT = layer).
run_copy() {
    run bash -c '
        set -euo pipefail
        eval "$(sed -n -e "/^git_cmd() {/,/^}/p" -e "/^_layer_src() {/,/^}/p" \
            -e "/^_template_history_match() {/,/^}/p" -e "/^copy_template() {/,/^}/p" "$1")"
        ROOT="$2"
        cd "$3"
        copy_template "$4" "$5"' _ "$SCRIPT" "$1" "$HOST" "$2" "$3"
}

@test "the functions under test load out of setup-harness.sh" {
    run bash -c 'eval "$(sed -n -e "/^git_cmd() {/,/^}/p" -e "/^_layer_src() {/,/^}/p" \
        -e "/^_template_history_match() {/,/^}/p" -e "/^copy_template() {/,/^}/p" "$1")"
        declare -F git_cmd _layer_src _template_history_match copy_template' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 4 ]
}

@test "a missing destination is copied, executable" {
    run_copy "$FIX" docs/hooks/h.sh .claude/hooks/h.sh
    [ "$status" -eq 0 ]
    [[ "$output" == *"copy       .claude/hooks/h.sh"* ]]
    cmp -s "$FIX/docs/hooks/h.sh" "$HOST/.claude/hooks/h.sh"
    [ -x "$HOST/.claude/hooks/h.sh" ]
}

@test "an up-to-date copy is left alone silently" {
    mkdir -p "$HOST/.claude/hooks"
    cp "$FIX/docs/hooks/h.sh" "$HOST/.claude/hooks/h.sh"
    run_copy "$FIX" docs/hooks/h.sh .claude/hooks/h.sh
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a pristine copy of an older template version is upgraded" {
    mkdir -p "$HOST/.claude/hooks"
    cp "$BASE/h.v1" "$HOST/.claude/hooks/h.sh"
    chmod -x "$HOST/.claude/hooks/h.sh" 2>/dev/null || true
    run_copy "$FIX" docs/hooks/h.sh .claude/hooks/h.sh
    [ "$status" -eq 0 ]
    [[ "$output" == *"upgrade    .claude/hooks/h.sh (was $V1_SHORT)"* ]]
    cmp -s "$FIX/docs/hooks/h.sh" "$HOST/.claude/hooks/h.sh"
    [ -x "$HOST/.claude/hooks/h.sh" ]
}

@test "a CRLF copy of an older version is upgraded" {
    mkdir -p "$HOST/.claude/hooks"
    printf '#!/usr/bin/env bash\r\necho v1\r\n' > "$HOST/.claude/hooks/h.sh"
    printf '* text=auto eol=lf\n' > "$FIX/.gitattributes"
    run_copy "$FIX" docs/hooks/h.sh .claude/hooks/h.sh
    [ "$status" -eq 0 ]
    [[ "$output" == *"upgrade    .claude/hooks/h.sh (was $V1_SHORT)"* ]]
    cmp -s "$FIX/docs/hooks/h.sh" "$HOST/.claude/hooks/h.sh"
}

@test "a locally edited copy is skipped with a diff hint" {
    mkdir -p "$HOST/.claude/hooks"
    { cat "$BASE/h.v1"; printf 'echo mine\n'; } > "$HOST/.claude/hooks/h.sh"
    cp "$HOST/.claude/hooks/h.sh" "$BASE/edited"
    run_copy "$FIX" docs/hooks/h.sh .claude/hooks/h.sh
    [ "$status" -eq 0 ]
    [[ "$output" == *"skip-copy  .claude/hooks/h.sh (differs from the template and matches no earlier version of it"* ]]
    [[ "$output" == *"git diff --no-index -- \"$FIX/docs/hooks/h.sh\" \".claude/hooks/h.sh\""* ]]
    cmp -s "$BASE/edited" "$HOST/.claude/hooks/h.sh"
}

@test "without layer history an older copy falls back to skip" {
    # The same two versions, but the layer is a plain directory: no .git.
    NOGIT="$BASE/nogit"
    mkdir -p "$NOGIT/docs/hooks" "$HOST/.claude/hooks"
    cp "$FIX/docs/hooks/h.sh" "$NOGIT/docs/hooks/h.sh"
    cp "$BASE/h.v1" "$HOST/.claude/hooks/h.sh"
    run_copy "$NOGIT" docs/hooks/h.sh .claude/hooks/h.sh
    [ "$status" -eq 0 ]
    [[ "$output" == *"skip-copy  .claude/hooks/h.sh"* ]]
    [[ "$output" != *"upgrade"* ]]
    cmp -s "$BASE/h.v1" "$HOST/.claude/hooks/h.sh"
}

@test "a shallow layer whose history lacks the old version falls back to skip" {
    git clone -q --depth 1 "file://$FIX" "$BASE/shallow"
    [ "$(git -C "$BASE/shallow" rev-parse --is-shallow-repository)" = "true" ]
    mkdir -p "$HOST/.claude/hooks"
    cp "$BASE/h.v1" "$HOST/.claude/hooks/h.sh"
    run_copy "$BASE/shallow" docs/hooks/h.sh .claude/hooks/h.sh
    [ "$status" -eq 0 ]
    [[ "$output" == *"skip-copy  .claude/hooks/h.sh"* ]]
    cmp -s "$BASE/h.v1" "$HOST/.claude/hooks/h.sh"
}

@test "a copy of another template's version is not an upgrade of this one" {
    # History is per path: v1 of a different file must not count.
    printf 'other v1\n' > "$FIX/docs/hooks/other.sh"
    git -C "$FIX" add -A && git -C "$FIX" commit -qm other
    printf 'other v2\n' > "$FIX/docs/hooks/other.sh"
    git -C "$FIX" commit -qam other2
    mkdir -p "$HOST/.claude/hooks"
    printf 'other v1\n' > "$HOST/.claude/hooks/h.sh"
    run_copy "$FIX" docs/hooks/h.sh .claude/hooks/h.sh
    [[ "$output" == *"skip-copy"* ]]
    [ "$(cat "$HOST/.claude/hooks/h.sh")" = "other v1" ]
}

@test "a symlink to an older version is skipped, not written through" {
    ln -s "$BASE/h.v1" "$BASE/probe" 2>/dev/null && [ -L "$BASE/probe" ] || skip "no symlink support"
    mkdir -p "$HOST/.claude/hooks"
    ln -s "$BASE/h.v1" "$HOST/.claude/hooks/h.sh"
    cp "$BASE/h.v1" "$BASE/h.v1.orig"
    run_copy "$FIX" docs/hooks/h.sh .claude/hooks/h.sh
    [[ "$output" == *"skip-copy"* ]]
    cmp -s "$BASE/h.v1.orig" "$BASE/h.v1"
}
