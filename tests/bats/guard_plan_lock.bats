#!/usr/bin/env bats
# tests/bats/guard_plan_lock.bats
# ----------------------------------------------------------------------------
# Bats tests for docs/harness/claude-code/hooks/guard-plan-lock.sh — Layer A of
# the force-on-contention plan-lock enforcement.
#
# Siblings are injected as registry entries (ppid=1 + fresh ts -> ts-freshness
# live arm). The lock table is injected via LTC_ROWS_OVERRIDE (pre-flattened TSV
# rows: branch<TAB>epoch<TAB>slug<TAB>path) so no network / locks-show is needed.
# LTC_COUNT_TTL=0 makes every sibling-count recompute (no cross-test cache).
#
# Asserts: solo never blocks; >=1 sibling + uncovered -> deny; covered by a
# MY-BRANCH lock (exact or dir-prefix) -> allow; an OTHER-branch lock is not my
# cover (the branch-key / owner-collision canary); union-of-distinct sibling
# count dedups a sid across regdirs; bypass + detached-HEAD + out-of-repo all
# fail open; the two review artifacts (.review-findings.json, .review-ack) are
# never gated while untracked, ignored plain files, but every other ignored path,
# a tracked or different-case copy, and a symlink/hardlink to a tracked file are.
# ----------------------------------------------------------------------------

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    HOOK="$REPO_ROOT/docs/harness/claude-code/hooks/guard-plan-lock.sh"

    # Canonical path (pwd -P) so `git rev-parse --show-toplevel` matches the
    # file_path prefix even where TMPDIR is a symlink (macOS /tmp -> /private).
    PROJ="$(mktemp -d)"; PROJ="$(cd "$PROJ" && pwd -P)"
    git -C "$PROJ" init -q -b develop
    git -C "$PROJ" config user.email t@local
    git -C "$PROJ" config user.name t
    echo seed > "$PROJ/seed.txt"; git -C "$PROJ" add -A; git -C "$PROJ" commit -qm seed
    # A linked worktree, for the cross-worktree sibling-count tests.
    WT="$(mktemp -d)/wt"
    git -C "$PROJ" worktree add -q -b feat/wt "$WT" >/dev/null 2>&1
    WT="$(cd "$WT" && pwd -P)"

    REGDIR="$PROJ/.claude/.active-sessions";     mkdir -p "$REGDIR"
    WT_REGDIR="$WT/.claude/.active-sessions";     mkdir -p "$WT_REGDIR"

    # Synthetic lock table: a develop (MINE) lock + a feat/x (OTHER) lock.
    ROWS="$(mktemp)"
    {
        printf 'develop\t1781049600\tmine\tSource/Core/src/Sync/Foo.cpp\n'
        printf 'develop\t1781049600\tmine\tSource/Core/src/Persistence/\n'
        printf 'feat/x\t1781049600\tother\tSource/Core/src/Tracker/Bar.cpp\n'
    } > "$ROWS"

    export CLAUDE_PROJECT_DIR="$PROJ"
    export LTC_ROWS_OVERRIDE="$ROWS"
    export LTC_COUNT_TTL=0
    export SMATCHET_REGISTRY_OS=posix
    export SMATCHET_REGISTRY_FRESH_SECS=1800
    unset SMATCHET_REQUIRE_PLAN_LOCK
}

teardown() {
    git -C "$PROJ" worktree remove --force "$WT" 2>/dev/null || true
    rm -rf "$PROJ" "$(dirname "$WT")" "$ROWS" 2>/dev/null || true
}

# A live registry entry (ppid=1 -> ts arm; fresh ts -> live).
reg() { printf 'ppid=1\nts=%s\n' "$(date -u +%s)" > "$1/$2"; }

# Run the hook for an edit to <repo-relative-path> (made absolute under PROJ).
# HOOK_CWD, when set, is sent as the payload's `cwd` (the session's checkout).
run_hook() { # $1 = repo-relative path
    run_hook_abs "$PROJ/$1"
}
# Run the hook with an explicit absolute file_path (for out-of-repo tests).
run_hook_abs() { # $1 = absolute path
    jq -cn --arg fp "$1" --arg cwd "${HOOK_CWD:-}" \
        '{tool_name:"Edit", tool_input:{file_path:$fp}, session_id:"mysid"}
         + (if $cwd == "" then {} else {cwd:$cwd} end)' \
        | bash "$HOOK"
}

@test "solo (0 siblings) never blocks, even an uncovered path" {
    run run_hook "Source/Core/src/Sync/Unlisted.cpp"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "solo: own sid double-registered across regdirs still dedups to 0 (allow)" {
    reg "$REGDIR" mysid
    reg "$WT_REGDIR" mysid
    run run_hook "Source/Core/src/Sync/Unlisted.cpp"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "contended + uncovered path is DENIED (threshold is >=1 sibling)" {
    reg "$REGDIR" sibling-a
    run run_hook "Source/Core/src/Sync/Unlisted.cpp"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
    [[ "$output" == *"1 other live session"* ]]
}

@test "contended + path covered by MY-branch lock is ALLOWED" {
    reg "$REGDIR" sibling-a
    run run_hook "Source/Core/src/Sync/Foo.cpp"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "contended + path under a MY-branch dir-prefix lock is ALLOWED" {
    reg "$REGDIR" sibling-a
    run run_hook "Source/Core/src/Persistence/Db.cpp"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "branch-key canary: an OTHER-branch lock is NOT my cover -> DENY" {
    reg "$REGDIR" sibling-a
    run run_hook "Source/Core/src/Tracker/Bar.cpp"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
}

@test "cross-worktree: 2 distinct siblings across two regdirs are counted" {
    reg "$REGDIR" sibling-a
    reg "$WT_REGDIR" sibling-b
    run run_hook "Source/Core/src/Sync/Unlisted.cpp"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
    [[ "$output" == *"2 other live session"* ]]
}

@test "dedup: the SAME sibling sid in two regdirs counts as 1, not 2" {
    reg "$REGDIR" dupe-sib
    reg "$WT_REGDIR" dupe-sib
    run run_hook "Source/Core/src/Sync/Unlisted.cpp"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
    [[ "$output" == *"1 other live session"* ]]   # union-of-distinct, not a sum
}

@test "bypass: SMATCHET_REQUIRE_PLAN_LOCK=0 allows a contended uncovered edit" {
    reg "$REGDIR" sibling-a
    SMATCHET_REQUIRE_PLAN_LOCK=0 run run_hook "Source/Core/src/Sync/Unlisted.cpp"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "fail-open: detached HEAD allows even when contended + uncovered" {
    reg "$REGDIR" sibling-a
    git -C "$PROJ" checkout -q --detach
    run run_hook "Source/Core/src/Sync/Unlisted.cpp"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "fail-open: an edit OUTSIDE the repo is not gated" {
    reg "$REGDIR" sibling-a
    run run_hook_abs "$(dirname "$PROJ")/outside-file.txt"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "no file_path -> allow (nothing to gate)" {
    reg "$REGDIR" sibling-a
    run bash -c "printf '%s' '{\"tool_name\":\"Edit\",\"tool_input\":{},\"session_id\":\"mysid\"}' | bash '$HOOK'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "deny output is a single valid PreToolUse deny JSON object" {
    reg "$REGDIR" sibling-a
    run run_hook "Source/Core/src/Sync/Unlisted.cpp"
    [ "$status" -eq 0 ]
    # Valid JSON with the deny decision and the remediation one-liner.
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
    [[ "$output" == *"lock-claim.sh"* ]]
    [[ "$output" == *"SMATCHET_REQUIRE_PLAN_LOCK=0"* ]]
}

# ---------------------------------------------------------------------------
# Worktree resolution: CLAUDE_PROJECT_DIR is the main tree (branch develop) even
# when the session edits a linked worktree. The hook must key on the checkout
# that owns the file — its branch and its relative path — not on the main tree.
# ---------------------------------------------------------------------------

# A worktree nested under the project dir, the .claude/worktrees/<id>/ layout.
mk_nested_wt() {
    NWT="$PROJ/.claude/worktrees/nested"
    git -C "$PROJ" worktree add -q -b feat/nested "$NWT" >/dev/null 2>&1
    [ -d "$NWT" ] || { echo "mk_nested_wt: git worktree add failed" >&2; return 1; }
}

@test "nested worktree: an edit covered by the WORKTREE branch's lock is ALLOWED" {
    reg "$REGDIR" sibling-a
    mk_nested_wt
    printf 'feat/nested\t1781049600\tnested\tSource/Core/src/Sync/Wt.cpp\n' >> "$ROWS"
    run run_hook ".claude/worktrees/nested/Source/Core/src/Sync/Wt.cpp"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "nested worktree: the main tree's lock is NOT the worktree's cover -> DENY naming the worktree branch + path" {
    reg "$REGDIR" sibling-a
    mk_nested_wt
    # Source/Core/src/Sync/Foo.cpp is covered by a develop (main-tree) lock only.
    run run_hook ".claude/worktrees/nested/Source/Core/src/Sync/Foo.cpp"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
    [[ "$output" == *"on branch 'feat/nested'"* ]]
    [[ "$output" == *"covering 'Source/Core/src/Sync/Foo.cpp'"* ]]
}

@test "linked worktree outside the project dir: its own branch's lock is the cover" {
    reg "$REGDIR" sibling-a
    printf 'feat/wt\t1781049600\twt\tSource/Core/src/Sync/Wt.cpp\n' >> "$ROWS"
    run run_hook_abs "$WT/Source/Core/src/Sync/Wt.cpp"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "linked worktree outside the project dir: a main-tree lock is NOT its cover -> DENY naming its branch" {
    reg "$REGDIR" sibling-a
    # Only develop holds Wt.cpp. The pre-fix hook allowed this (path outside PROJ).
    printf 'develop\t1781049600\tmine\tSource/Core/src/Sync/Wt.cpp\n' >> "$ROWS"
    run run_hook_abs "$WT/Source/Core/src/Sync/Wt.cpp"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
    [[ "$output" == *"covering 'Source/Core/src/Sync/Wt.cpp' on branch 'feat/wt'"* ]]
}

@test "session cwd in the worktree: the worktree branch's lock is the cover" {
    reg "$REGDIR" sibling-a
    mk_nested_wt
    printf 'feat/nested\t1781049600\tnested\tSource/Core/src/Sync/Wt.cpp\n' >> "$ROWS"
    HOOK_CWD="$NWT" run run_hook ".claude/worktrees/nested/Source/Core/src/Sync/Wt.cpp"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "session cwd in the main tree: a SIBLING worktree's lock does not let it edit that worktree's file" {
    reg "$REGDIR" sibling-a
    mk_nested_wt
    printf 'feat/nested\t1781049600\tnested\tSource/Core/src/Sync/Wt.cpp\n' >> "$ROWS"
    HOOK_CWD="$PROJ" run run_hook ".claude/worktrees/nested/Source/Core/src/Sync/Wt.cpp"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
    [[ "$output" == *"on branch 'develop'"* ]]
}

@test "session cwd with backslash separators resolves to the same worktree" {
    reg "$REGDIR" sibling-a
    mk_nested_wt
    printf 'feat/nested\t1781049600\tnested\tSource/Core/src/Sync/Wt.cpp\n' >> "$ROWS"
    HOOK_CWD="${NWT//\//\\}" run run_hook_abs "${NWT//\//\\}\\Source\\Core\\src\\Sync\\Wt.cpp"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a separate repo inside the project dir (e.g. a submodule) keeps project-dir gating" {
    reg "$REGDIR" sibling-a
    git init -q -b main "$PROJ/sub"
    run run_hook "sub/file.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
    [[ "$output" == *"covering 'sub/file.txt' on branch 'develop'"* ]]
}

# ---------------------------------------------------------------------------
# The review artifacts the commit / push gates require (.review-findings.json,
# .review-ack) are never gated while they are untracked, ignored plain files.
# Every other ignored path stays gated (it can still be force-added), and so does
# an artifact path that would write through to a tracked file.
# ---------------------------------------------------------------------------

commit_gitignore() { # $1 = checkout
    printf '.review-findings.json\n.review-ack\nbuild/\n' > "$1/.gitignore"
    git -C "$1" add .gitignore
    git -C "$1" commit -qm ignore
}

@test "review artifact: contended + untracked ignored .review-findings.json is ALLOWED" {
    reg "$REGDIR" sibling-a
    commit_gitignore "$PROJ"
    run run_hook ".review-findings.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "review artifact: an existing untracked ignored .review-ack is ALLOWED" {
    reg "$REGDIR" sibling-a
    commit_gitignore "$PROJ"
    printf 'fp\n' > "$PROJ/.review-ack"
    run run_hook ".review-ack"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "review artifact: any OTHER ignored path (build/ scratch) is still DENIED" {
    reg "$REGDIR" sibling-a
    commit_gitignore "$PROJ"
    run run_hook "build/run-1/findings/charter.jsonl"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
}

@test "review artifact: a TRACKED (force-added) .review-ack is still DENIED" {
    reg "$REGDIR" sibling-a
    commit_gitignore "$PROJ"
    printf 'fp\n' > "$PROJ/.review-ack"
    git -C "$PROJ" add -f .review-ack
    git -C "$PROJ" commit -qm tracked
    run run_hook ".review-ack"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
    [[ "$output" == *"covering '.review-ack'"* ]]
}

@test "review artifact: a different-case tracked copy (case-insensitive checkout) is still DENIED" {
    reg "$REGDIR" sibling-a
    commit_gitignore "$PROJ"
    git -C "$PROJ" config core.ignorecase true
    printf 'fp\n' > "$PROJ/.Review-Ack"
    git -C "$PROJ" add -f .Review-Ack
    git -C "$PROJ" commit -qm tracked-case
    run run_hook ".review-ack"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
}

@test "review artifact: an ignored SYMLINK to a tracked file is still DENIED" {
    reg "$REGDIR" sibling-a
    commit_gitignore "$PROJ"
    ln -s seed.txt "$PROJ/.review-findings.json"
    run run_hook ".review-findings.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
}

@test "review artifact: an ignored HARDLINK to a tracked file is still DENIED" {
    reg "$REGDIR" sibling-a
    commit_gitignore "$PROJ"
    ln "$PROJ/seed.txt" "$PROJ/.review-ack"
    run run_hook ".review-ack"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
}

@test "review artifact: the main tree's ignore rules do not exempt a worktree whose branch lacks them" {
    reg "$REGDIR" sibling-a
    mk_nested_wt
    # .gitignore lands on develop AFTER the worktree branched, so feat/nested has
    # no ignore rule: the worktree's .review-ack is an ordinary untracked file there.
    commit_gitignore "$PROJ"
    HOOK_CWD="$NWT" run run_hook ".claude/worktrees/nested/.review-ack"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
}

@test "review artifact: nested worktree + its own ignored .review-ack is ALLOWED" {
    reg "$REGDIR" sibling-a
    commit_gitignore "$PROJ"
    mk_nested_wt   # branches from the commit that carries .gitignore
    HOOK_CWD="$NWT" run run_hook ".claude/worktrees/nested/.review-ack"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
