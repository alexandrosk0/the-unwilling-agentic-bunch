#!/usr/bin/env bats
# locks_render_markdown.bats — regression suite for
# agents/scripts/core/locks-render-markdown.sh (the refs/locks/* -> Markdown
# mirror written to docs/plans/active/_plan-locks.generated.md).
#
# Behaviour under test: a lock's originating plan is rendered as a Markdown link
# ONLY when that plan file exists in the rendering checkout. A plan that lives
# only on the lock owner's unmerged branch is rendered as inline code with a
# "(not on this branch yet)" note, so the mirror never carries a dangling link
# that reds test-markdown-links.sh / test-plan-ref-integrity.sh on the sync PR.
#
# Sandbox: a bare repo stands in for origin; a clone of it is the rendering
# checkout. Each lock is built with plumbing (hash-object / mktree /
# commit-tree) and pushed to refs/locks/<slug> on the bare remote, so the
# script's own `git fetch ... refs/locks/*` is what brings it into the clone.
#
# Requires: bash, git, python(3), bats.

setup() {
    # Cleared before any skip: bats runs teardown after a setup-time skip, and an
    # inherited SANDBOX must never reach its rm -rf.
    SANDBOX=""
    SCRIPT="$(git rev-parse --show-toplevel)/agents/scripts/core/locks-render-markdown.sh"
    export SCRIPT
    # Exec-validate the interpreter: a bare `command -v python3` matches the
    # Windows WinStore alias stub, which resolves on PATH but exits non-zero.
    PYBIN=""
    for c in python3 python py; do
        if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then
            PYBIN="$(command -v "$c")"; break
        fi
    done
    export PYBIN
    [ -n "$PYBIN" ] || skip "no working python interpreter"

    SANDBOX="$(mktemp -d)"
    export SANDBOX
    REMOTE="$SANDBOX/remote.git"
    CLONE="$SANDBOX/clone"
    export REMOTE CLONE

    git init --quiet --bare "$REMOTE"
    git clone --quiet "$REMOTE" "$CLONE" 2>/dev/null
    git -C "$CLONE" config user.email t@t
    git -C "$CLONE" config user.name t
    git -C "$CLONE" config commit.gpgsign false
    git -C "$CLONE" commit --quiet --allow-empty -m seed

    # The sandbox remote URL is not a Smatchet repo URL.
    export SMATCHET_LOCK_BYPASS_REPO_CHECK=1
}

teardown() {
    rm -rf "${SANDBOX:-}"
}

# push_lock <slug> <originating_plan> — build a lock commit holding claim.json
# and push it to refs/locks/<slug> on the bare remote. No local ref is written,
# so only the script's own fetch brings the lock into the clone.
push_lock() {
    local slug="$1" plan="$2" claim blob tree commit
    claim="$SANDBOX/claim_${slug}.json"
    cat > "$claim" <<JSON
{"slug":"$slug","owner":"alice","branch":"claude/$slug","originating_plan":"$plan","started":"2026-01-01T00:00:00Z","updated":"2026-01-01T00:00:00Z","write_set":["a.cpp"]}
JSON
    blob="$(git -C "$CLONE" hash-object -w "$claim")"
    tree="$(printf '100644 blob %s\tclaim.json\n' "$blob" | git -C "$CLONE" mktree)"
    commit="$(git -C "$CLONE" commit-tree "$tree" -m "lock $slug")"
    git -C "$CLONE" push --quiet origin "$commit:refs/locks/$slug"
}

# render [<dir>] — run the script from <dir> (default: the clone root).
render() {
    run bash -c 'cd "$1" && bash "$2"' _ "${1:-$CLONE}" "$SCRIPT"
}

@test "originating plan present in the checkout -> rendered as a link" {
    mkdir -p "$CLONE/docs/plans/active"
    printf '# plan\n' > "$CLONE/docs/plans/active/landed-plan.md"
    push_lock landed docs/plans/active/landed-plan.md

    render
    [ "$status" -eq 0 ]
    [[ "$output" == *'### `landed`'* ]]
    [[ "$output" == *'- **Originating plan**: [`docs/plans/active/landed-plan.md`](../../../docs/plans/active/landed-plan.md)'* ]]
    [[ "$output" != *"not on this branch yet"* ]]
}

@test "originating plan absent from the checkout -> code form, no link" {
    push_lock unlanded docs/plans/active/unlanded-plan.md

    render
    [ "$status" -eq 0 ]
    [[ "$output" == *'### `unlanded`'* ]]
    [[ "$output" == *'- **Originating plan**: `docs/plans/active/unlanded-plan.md` (not on this branch yet)'* ]]
    [[ "$output" != *"](../../../docs/plans/active/unlanded-plan.md)"* ]]
}

@test "rendered from a subdirectory -> existence is checked at the checkout top level" {
    mkdir -p "$CLONE/docs/plans/active"
    printf '# plan\n' > "$CLONE/docs/plans/active/landed-plan.md"
    push_lock landed docs/plans/active/landed-plan.md

    render "$CLONE/docs"
    [ "$status" -eq 0 ]
    [[ "$output" == *'- **Originating plan**: [`docs/plans/active/landed-plan.md`](../../../docs/plans/active/landed-plan.md)'* ]]
}

@test "absolute or ..-escaping plan path -> code form, never a link" {
    mkdir -p "$CLONE/docs/plans/active"
    printf '# plan\n' > "$CLONE/docs/plans/active/landed-plan.md"
    push_lock abs "$CLONE/docs/plans/active/landed-plan.md"
    push_lock dotdot docs/plans/active/../active/landed-plan.md

    render
    [ "$status" -eq 0 ]
    [[ "$output" == *'### `abs`'* ]]
    [[ "$output" == *'### `dotdot`'* ]]
    # The header's own workflow link is the only link left.
    [[ "$output" != *'**Originating plan**: ['* ]]
    [[ "$output" == *'landed-plan.md` (not on this branch yet)'* ]]
    [[ "$output" == *'docs/plans/active/../active/landed-plan.md` (not on this branch yet)'* ]]
}
