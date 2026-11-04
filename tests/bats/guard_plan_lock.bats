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
# Asserts: solo never blocks; >=1 sibling + uncovered -> deny (auto-claim off);
# covered by a MY-BRANCH lock (exact or dir-prefix) -> allow; an OTHER-branch lock
# is not my cover (the branch-key / owner-collision canary); union-of-distinct sibling
# count dedups a sid across regdirs; bypass + detached-HEAD + out-of-repo all
# fail open; the two review artifacts (.review-findings.json, .review-ack) are
# never gated while untracked, ignored plain files, but every other ignored path,
# a tracked or different-case copy, and a symlink/hardlink to a tracked file are.
#
# Auto-claim (the last section) runs against a sandbox bare remote with
# SMATCHET_LOCK_BYPASS_REPO_CHECK=1 and the real locks-show / lock-claim scripts:
# an uncovered contended edit files a lock under the branch's deterministic slug
# (or extends the branch's own lock under a pinned lease, never dropping a path a
# concurrent extension added) and allows with a note; another branch's lock still
# denies, also when only the fresh re-read after the claim sees it (the claim is
# rolled back); a failed or slow claim fails open; a host without timeout(1) or
# gtimeout gets the classic deny; SMATCHET_PLAN_LOCK_AUTOCLAIM=0 restores the
# deny. A git shim on PATH interleaves a concurrent writer or hangs one call.
# Every other section runs with auto-claim off.
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
    # The coverage / exemption sections assert the classic deny; the auto-claim
    # section turns auto-claim back on (enable_autoclaim).
    export SMATCHET_PLAN_LOCK_AUTOCLAIM=0
    AC_SANDBOX=""
}

teardown() {
    git -C "$PROJ" worktree remove --force "$WT" 2>/dev/null || true
    rm -rf "$PROJ" "$(dirname "$WT")" "$ROWS" 2>/dev/null || true
    [ -z "$AC_SANDBOX" ] || rm -rf "$AC_SANDBOX" 2>/dev/null || true
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

# ---------------------------------------------------------------------------
# Auto-claim: an uncovered contended edit files (or grows) this branch's lock
# instead of being denied. A sandbox bare repo is the remote; the hook drives the
# real locks-show.sh / lock-claim.sh / lock-claim-update.sh against it.
# ---------------------------------------------------------------------------

AC_BRANCH="Feat/Auto_Claim"

enable_autoclaim() {
    unset SMATCHET_PLAN_LOCK_AUTOCLAIM LTC_ROWS_OVERRIDE SMATCHET_LOCK_BACKEND \
        LOCK_PLAN LOCK_NOTES LOCK_BRANCH LOCK_REMOTE LOCK_RETRY_MAX AGENT_ID GIT_SSH_COMMAND
    AC_SANDBOX="$(mktemp -d)"; AC_SANDBOX="$(cd "$AC_SANDBOX" && pwd -P)"
    BARE="$AC_SANDBOX/bare.git"
    git init -q --bare "$BARE"
    git -C "$PROJ" remote add origin "$BARE"
    export SMATCHET_LOCK_BYPASS_REPO_CHECK=1
    # Per-test lock-table cache: the cache lives under TMPDIR.
    export TMPDIR="$AC_SANDBOX/tmp"; mkdir -p "$TMPDIR"
    git -C "$PROJ" checkout -q -b "$AC_BRANCH"
}

# The documented slug: auto-<sanitised branch>-<crc32 of the raw branch, 8 hex>.
expected_slug() { # $1 = sanitised branch, $2 = raw branch
    printf 'auto-%s-%08x' "$1" "$(printf '%s' "$2" | cksum | awk '{print $1}')"
}

# File a lock as another party would. PLANT_PLAN / PLANT_NOTES / PLANT_OWNER optional.
plant_lock() { # $1 = slug, $2 = branch, $3.. = write-set paths
    local slug="$1" br="$2"; shift 2
    printf '%s\n' "$@" > "$AC_SANDBOX/ws-$slug"
    (cd "$PROJ" && AGENT_ID="${PLANT_OWNER:-orchestrator}" LOCK_BRANCH="$br" \
        LOCK_PLAN="${PLANT_PLAN:-}" LOCK_NOTES="${PLANT_NOTES:-}" \
        bash "$REPO_ROOT/agents/scripts/core/lock-claim.sh" "$slug" "$AC_SANDBOX/ws-$slug") >/dev/null 2>&1
}

claim_json() { git -C "$BARE" cat-file blob "refs/locks/$1:claim.json"; }
lock_refs() { git -C "$BARE" for-each-ref --format='%(refname)' refs/locks/; }

table_cache_file() {
    LTC_PROJ="$PROJ" bash -c '. "$1" && _ltc_table_cache_path "$(_ltc_repo_key)"' _ \
        "$REPO_ROOT/agents/scripts/core/lock-table-cache.sh"
}
# Serve a fresh cached lock table, as a session that read it moments ago would.
seed_table_cache() { # $1 = lock-table JSON
    printf '%s\n%s' "$(date -u +%s)" "$1" > "$(table_cache_file)"
}

context_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // empty'; }
reason_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'; }

# A git on PATH that wraps the real one. A call whose arguments contain SHIM_HANG
# hangs (as a dead remote would); one whose arguments contain SHIM_FAIL fails at
# once (as an unreachable remote would); one whose arguments contain SHIM_SLOW
# first sleeps SHIM_SLOW_SECS (a slow remote); after a call whose arguments contain
# SHIM_AFTER_MATCH, the script SHIM_AFTER runs with the real git (another
# session acting between this hook's steps).
install_git_shim() {
    SHIM_DIR="$AC_SANDBOX/shim"; mkdir -p "$SHIM_DIR"
    SHIM_REAL_GIT="$(command -v git)"; SHIM_PATH="$PATH"
    export SHIM_REAL_GIT SHIM_PATH
    cat > "$SHIM_DIR/git" <<'SHIM'
#!/usr/bin/env bash
args=" $* "
if [ -n "${SHIM_HANG:-}" ] && [[ "$args" == *"$SHIM_HANG"* ]]; then
    exec sleep 30 </dev/null >/dev/null 2>&1
fi
if [ -n "${SHIM_FAIL:-}" ] && [[ "$args" == *"$SHIM_FAIL"* ]]; then
    echo "fatal: unable to access the remote" >&2
    exit 128
fi
if [ -n "${SHIM_SLOW:-}" ] && [[ "$args" == *"$SHIM_SLOW"* ]]; then
    sleep "${SHIM_SLOW_SECS:-3}"
fi
"$SHIM_REAL_GIT" "$@"; rc=$?
if [ -n "${SHIM_AFTER:-}" ] && [[ "$args" == *"${SHIM_AFTER_MATCH:-}"* ]]; then
    PATH="$SHIM_PATH" bash "$SHIM_AFTER" </dev/null >/dev/null 2>&1
fi
exit "$rc"
SHIM
    chmod +x "$SHIM_DIR/git"
    export PATH="$SHIM_DIR:$PATH"
}

# Another session of this branch, in its own clone, that grows plan-lock
# 'mywork' each time it runs (Theirs1.cpp, Theirs2.cpp, ...), at most $1 times.
concurrent_extender() { # $1 = how many times it acts
    git clone -q "$BARE" "$AC_SANDBOX/other" 2>/dev/null
    cat > "$AC_SANDBOX/concurrent.sh" <<CONC
k=\$(( \$(cat "$AC_SANDBOX/acted" 2>/dev/null || echo 0) + 1 ))
[ "\$k" -le "$1" ] || exit 0
printf '%s' "\$k" > "$AC_SANDBOX/acted"
{
    printf '%s\n' Source/Core/src/Sync/A.cpp
    i=1
    while [ "\$i" -le "\$k" ]; do printf 'Source/Core/src/Sync/Theirs%s.cpp\n' "\$i"; i=\$((i + 1)); done
} > "$AC_SANDBOX/ws-conc"
cd "$AC_SANDBOX/other" || exit 1
GIT_AUTHOR_NAME=o GIT_AUTHOR_EMAIL=o@o GIT_COMMITTER_NAME=o GIT_COMMITTER_EMAIL=o@o \
    AGENT_ID=alice LOCK_BRANCH='$AC_BRANCH' \
    bash '$REPO_ROOT/agents/scripts/core/lock-claim-update.sh' mywork "$AC_SANDBOX/ws-conc"
CONC
    export SHIM_AFTER="$AC_SANDBOX/concurrent.sh" SHIM_AFTER_MATCH="+refs/locks/mywork:"
}
ws_of() { claim_json "$1" | jq -c '.write_set'; }
# The cached table as a session that read it before 'mywork' grew past A.cpp.
seed_mywork_cache() {
    seed_table_cache "[{\"_slug\":\"mywork\",\"branch\":\"$AC_BRANCH\",\"started\":\"2026-01-01T00:00:00Z\",\"write_set\":[\"Source/Core/src/Sync/A.cpp\"]}]"
}

# The note path never sets a permissionDecision: the session's own permission
# mode still decides the edit.
assert_note_without_decision() {
    printf '%s' "$1" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"
        and (.hookSpecificOutput | has("permissionDecision") | not)
        and (.systemMessage | length > 0)' >/dev/null
}

@test "auto-claim: an uncovered contended edit files a new lock under the branch slug and allows" {
    enable_autoclaim
    reg "$REGDIR" sibling-a
    slug="$(expected_slug feat-auto-claim "$AC_BRANCH")"
    seed_table_cache '[]'
    run run_hook "Source/Core/src/Sync/New.cpp"
    [ "$status" -eq 0 ]
    assert_note_without_decision "$output"
    ctx="$(context_of "$output")"
    [[ "$ctx" == *"auto-claimed plan-lock '$slug'"* ]]
    [[ "$ctx" == *"'Source/Core/src/Sync/New.cpp'"* ]]
    claim_json "$slug" | jq -e --arg br "$AC_BRANCH" '.branch == $br
        and .write_set == ["Source/Core/src/Sync/New.cpp"]
        and (.notes | test("auto-claimed"))' >/dev/null
    # The fresh cross-branch re-read after the claim rewrote the cached table,
    # which now holds the lock, so the very next edit sees it: plain allow.
    grep -qF "$slug" "$(table_cache_file)"
    run run_hook "Source/Core/src/Sync/New.cpp"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "auto-claim: the branch's own lock is extended from its fresh claim.json, nothing dropped" {
    enable_autoclaim
    reg "$REGDIR" sibling-a
    PLANT_OWNER=alice PLANT_PLAN=docs/plans/active/x.md PLANT_NOTES="keep me" \
        plant_lock mywork "$AC_BRANCH" Source/Core/src/Sync/A.cpp Source/Core/src/Persistence/
    # A stale cached table that only knows A.cpp: the extension must still keep
    # Persistence/, which only the lock ref's claim.json carries.
    seed_table_cache "[{\"_slug\":\"mywork\",\"branch\":\"$AC_BRANCH\",\"started\":\"2026-01-01T00:00:00Z\",\"write_set\":[\"Source/Core/src/Sync/A.cpp\"]}]"
    run run_hook "Source/Core/src/Sync/C.cpp"
    [ "$status" -eq 0 ]
    assert_note_without_decision "$output"
    ctx="$(context_of "$output")"
    [[ "$ctx" == *"extended your plan-lock 'mywork'"* ]]
    [[ "$ctx" == *"'Source/Core/src/Sync/C.cpp'"* ]]
    claim_json mywork | jq -e --arg br "$AC_BRANCH" '.branch == $br
        and .write_set == ["Source/Core/src/Sync/A.cpp", "Source/Core/src/Persistence/", "Source/Core/src/Sync/C.cpp"]
        and .owner == "alice" and .originating_plan == "docs/plans/active/x.md" and .notes == "keep me"' >/dev/null
    [ "$(lock_refs)" = "refs/locks/mywork" ]
}

@test "auto-claim: another branch's lock still DENIES and nothing is claimed" {
    enable_autoclaim
    reg "$REGDIR" sibling-a
    plant_lock theirs feat/other Source/Core/src/Tracker/
    run run_hook "Source/Core/src/Tracker/X.cpp"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
    [[ "$output" == *"another branch's plan-lock 'theirs'"* ]]
    [ "$(lock_refs)" = "refs/locks/theirs" ]
    claim_json theirs | jq -e '.branch == "feat/other" and .write_set == ["Source/Core/src/Tracker/"]' >/dev/null
}

@test "auto-claim: another branch's claim the cached table missed is caught by the fresh re-read; the new lock is released and the edit DENIED" {
    enable_autoclaim
    reg "$REGDIR" sibling-a
    slug="$(expected_slug feat-auto-claim "$AC_BRANCH")"
    # feat/other claimed the path from its own clone after this session cached its table.
    plant_lock theirs feat/other Source/Core/src/Sync/Race.cpp
    seed_table_cache '[]'
    run run_hook "Source/Core/src/Sync/Race.cpp"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
    reason="$(reason_of "$output")"
    [[ "$reason" == *"another branch's plan-lock 'theirs' claims 'Source/Core/src/Sync/Race.cpp'"* ]]
    [[ "$reason" == *"auto-claim '$slug' is released again"* ]]
    [ "$(lock_refs)" = "refs/locks/theirs" ]
    # The rollback dropped the cache, so the next edit re-reads and denies again.
    run run_hook "Source/Core/src/Sync/Race.cpp"
    [[ "$(reason_of "$output")" == *"you hold no plan-lock covering 'Source/Core/src/Sync/Race.cpp'"* ]]
}

@test "auto-claim: an extension racing another branch's claim is rolled back to the previous set and DENIED" {
    enable_autoclaim
    reg "$REGDIR" sibling-a
    PLANT_OWNER=alice PLANT_NOTES="keep me" plant_lock mywork "$AC_BRANCH" Source/Core/src/Sync/A.cpp
    plant_lock theirs feat/other Source/Core/src/Sync/C.cpp
    seed_mywork_cache
    run run_hook "Source/Core/src/Sync/C.cpp"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
    reason="$(reason_of "$output")"
    [[ "$reason" == *"another branch's plan-lock 'theirs'"* ]]
    [[ "$reason" == *"plan-lock 'mywork' is restored to its previous write set"* ]]
    claim_json mywork | jq -e '.write_set == ["Source/Core/src/Sync/A.cpp"]
        and .owner == "alice" and .notes == "keep me"' >/dev/null
}

@test "auto-claim: a rollback that cannot finish inside the budget still DENIES and says so" {
    command -v timeout >/dev/null 2>&1 || skip "no timeout(1)"
    enable_autoclaim
    reg "$REGDIR" sibling-a
    slug="$(expected_slug feat-auto-claim "$AC_BRANCH")"
    plant_lock theirs feat/other Source/Core/src/Sync/Race.cpp
    seed_table_cache '[]'
    install_git_shim
    export SHIM_HANG=" :refs/locks/$slug "   # the release's delete push hangs
    start=$SECONDS
    SMATCHET_PLAN_LOCK_AUTOCLAIM_TIMEOUT=4 run run_hook "Source/Core/src/Sync/Race.cpp"
    [ $((SECONDS - start)) -lt 15 ]
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
    reason="$(reason_of "$output")"
    [[ "$reason" == *"another branch's plan-lock 'theirs'"* ]]
    [[ "$reason" == *"Rolling back its auto-claim '$slug' did not complete (the auto-claim budget ran out)"* ]]
    [[ "$reason" == *"lock-release.sh $slug"* ]]
    lock_refs | grep -qxF "refs/locks/$slug"
    # Retrying the edit does not pass silently: the overlap the unfinished
    # rollback left behind still denies, naming how to resolve it.
    unset SHIM_HANG
    run run_hook "Source/Core/src/Sync/Race.cpp"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
    reason="$(reason_of "$output")"
    [[ "$reason" == *"another branch's plan-lock 'theirs' claims 'Source/Core/src/Sync/Race.cpp', which your plan-lock '$slug' also covers: this edit hook claimed"* ]]
    [[ "$reason" == *"lock-release.sh $slug"* ]]
    # Once the other branch's lock is gone, the overlap is resolved: the edit
    # passes and the record is dropped.
    git -C "$BARE" update-ref -d refs/locks/theirs
    rm -f "$(table_cache_file)"
    run run_hook "Source/Core/src/Sync/Race.cpp"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    ! grep -qs 'Race.cpp' "$TMPDIR"/.smatchet-planlock-unresolved-*
}

@test "auto-claim: a failed restore after extending a hand-claimed lock keeps denying the retried edit" {
    command -v timeout >/dev/null 2>&1 || skip "no timeout(1)"
    enable_autoclaim
    reg "$REGDIR" sibling-a
    PLANT_OWNER=alice plant_lock mywork "$AC_BRANCH" Source/Core/src/Sync/A.cpp
    plant_lock theirs feat/other Source/Core/src/Sync/C.cpp
    seed_mywork_cache
    install_git_shim
    # The extension's push lands; the restore's push (the second push of
    # refs/locks/mywork) hangs until the budget runs out.
    # Hang every refs/locks/mywork push once armed: the first push (the extend)
    # arms it after it lands.
    cat > "$SHIM_DIR/git" <<SHIM2
#!/usr/bin/env bash
args=" \$* "
if [ "\$1" = push ] && [ -e "$AC_SANDBOX/armed" ] && [[ "\$args" == *"refs/locks/mywork"* ]]; then
    exec sleep 30 </dev/null >/dev/null 2>&1
fi
"$SHIM_REAL_GIT" "\$@"; rc=\$?
if [ "\$1" = push ] && [[ "\$args" == *"refs/locks/mywork"* ]]; then : > "$AC_SANDBOX/armed"; fi
exit "\$rc"
SHIM2
    chmod +x "$SHIM_DIR/git"
    SMATCHET_PLAN_LOCK_AUTOCLAIM_TIMEOUT=4 run run_hook "Source/Core/src/Sync/C.cpp"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
    reason="$(reason_of "$output")"
    [[ "$reason" == *"Restoring your plan-lock 'mywork' to its previous write set did not complete"* ]]
    [[ "$reason" == *"Until then this hook keeps denying edits of 'Source/Core/src/Sync/C.cpp'"* ]]
    [ "$(ws_of mywork)" = '["Source/Core/src/Sync/A.cpp","Source/Core/src/Sync/C.cpp"]' ]
    # The retry is denied too, naming the hand lock the hook claimed into.
    rm -f "$AC_SANDBOX/armed"
    run run_hook "Source/Core/src/Sync/C.cpp"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
    [[ "$(reason_of "$output")" == *"which your plan-lock 'mywork' also covers: this edit hook claimed"* ]]
}

@test "auto-claim: an earlier auto-claim that another branch overlaps later is never denied by the overlap rule" {
    enable_autoclaim
    reg "$REGDIR" sibling-a
    slug="$(expected_slug feat-auto-claim "$AC_BRANCH")"
    seed_table_cache '[]'
    run run_hook "Source/Core/src/Sync/P.cpp"
    [ "$status" -eq 0 ]
    [[ "$(context_of "$output")" == *"auto-claimed plan-lock '$slug'"* ]]
    # Another branch claims the same path by hand afterwards.
    plant_lock theirs feat/other Source/Core/src/Sync/P.cpp
    rm -f "$(table_cache_file)"
    run run_hook "Source/Core/src/Sync/P.cpp"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "auto-claim: a hand-claimed lock of this branch overlapping another branch's lock still allows (a coordinated claim)" {
    enable_autoclaim
    reg "$REGDIR" sibling-a
    plant_lock mywork "$AC_BRANCH" Source/Core/src/Sync/Shared.cpp
    plant_lock theirs feat/other Source/Core/src/Sync/Shared.cpp
    run run_hook "Source/Core/src/Sync/Shared.cpp"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "auto-claim: rolling back a new lock is pinned to its commit, so a same-branch extension made since is kept" {
    enable_autoclaim
    reg "$REGDIR" sibling-a
    slug="$(expected_slug feat-auto-claim "$AC_BRANCH")"
    plant_lock theirs feat/other Source/Core/src/Sync/Race.cpp
    seed_table_cache '[]'
    install_git_shim
    # Another session of this branch grows the just-filed auto lock right after
    # this hook's claim push, before its rollback runs.
    git clone -q "$BARE" "$AC_SANDBOX/other" 2>/dev/null
    cat > "$AC_SANDBOX/grow.sh" <<GROW
[ -e "$AC_SANDBOX/acted" ] && exit 0
: > "$AC_SANDBOX/acted"
printf '%s\n' Source/Core/src/Sync/Race.cpp Source/Core/src/Sync/Theirs.cpp > "$AC_SANDBOX/ws-grow"
cd "$AC_SANDBOX/other" || exit 1
GIT_AUTHOR_NAME=o GIT_AUTHOR_EMAIL=o@o GIT_COMMITTER_NAME=o GIT_COMMITTER_EMAIL=o@o \
    AGENT_ID=alice LOCK_BRANCH='$AC_BRANCH' \
    bash '$REPO_ROOT/agents/scripts/core/lock-claim-update.sh' '$slug' "$AC_SANDBOX/ws-grow"
GROW
    export SHIM_AFTER="$AC_SANDBOX/grow.sh" SHIM_AFTER_MATCH=":refs/locks/$slug"
    run run_hook "Source/Core/src/Sync/Race.cpp"
    [ "$status" -eq 0 ]
    [ -e "$AC_SANDBOX/acted" ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
    reason="$(reason_of "$output")"
    [[ "$reason" == *"Rolling back its auto-claim '$slug' did not complete (lock-release.sh exit 1"* ]]
    lock_refs | grep -qxF "refs/locks/$slug"
    claim_json "$slug" | jq -e '.write_set | index("Source/Core/src/Sync/Theirs.cpp") != null' >/dev/null
}

@test "auto-claim: a fresh re-read that cannot run fails OPEN, keeps the claim and says the re-check did not run" {
    command -v timeout >/dev/null 2>&1 || skip "no timeout(1)"
    enable_autoclaim
    reg "$REGDIR" sibling-a
    slug="$(expected_slug feat-auto-claim "$AC_BRANCH")"
    seed_table_cache '[]'
    install_git_shim
    export SHIM_HANG='+refs/locks/*:refs/locks/*'   # locks-show's table fetch hangs
    SMATCHET_PLAN_LOCK_AUTOCLAIM_TIMEOUT=3 run run_hook "Source/Core/src/Sync/New.cpp"
    [ "$status" -eq 0 ]
    assert_note_without_decision "$output"
    ctx="$(context_of "$output")"
    [[ "$ctx" == *"auto-claimed plan-lock '$slug'"* ]]
    [[ "$ctx" == *"re-check did not run (exit 124)"* ]]
    [ "$(lock_refs)" = "refs/locks/$slug" ]
}

@test "auto-claim: a fresh re-read whose lock fetch fails is never a stale local read: fails OPEN and says the re-check did not run" {
    enable_autoclaim
    reg "$REGDIR" sibling-a
    slug="$(expected_slug feat-auto-claim "$AC_BRANCH")"
    seed_table_cache '[]'
    install_git_shim
    export SHIM_FAIL='+refs/locks/*:refs/locks/*'   # locks-show's table fetch fails at once
    run run_hook "Source/Core/src/Sync/New.cpp"
    [ "$status" -eq 0 ]
    assert_note_without_decision "$output"
    ctx="$(context_of "$output")"
    [[ "$ctx" == *"auto-claimed plan-lock '$slug'"* ]]
    [[ "$ctx" == *"re-check did not run (exit 2)"* ]]
    [ "$(lock_refs)" = "refs/locks/$slug" ]
}

@test "auto-claim: an extension pinned to the commit it read keeps a path a concurrent extension added" {
    enable_autoclaim
    reg "$REGDIR" sibling-a
    PLANT_OWNER=alice plant_lock mywork "$AC_BRANCH" Source/Core/src/Sync/A.cpp
    seed_mywork_cache
    install_git_shim
    concurrent_extender 1   # acts once, right after this hook fetches the lock
    run run_hook "Source/Core/src/Sync/C.cpp"
    [ "$status" -eq 0 ]
    assert_note_without_decision "$output"
    [[ "$(context_of "$output")" == *"extended your plan-lock 'mywork'"*"(3 paths now; none dropped)"* ]]
    [ "$(cat "$AC_SANDBOX/acted")" = "1" ]
    [ "$(ws_of mywork)" = '["Source/Core/src/Sync/A.cpp","Source/Core/src/Sync/Theirs1.cpp","Source/Core/src/Sync/C.cpp"]' ]
}

@test "auto-claim: an extension that loses its pinned lease twice fails OPEN without writing" {
    enable_autoclaim
    reg "$REGDIR" sibling-a
    PLANT_OWNER=alice plant_lock mywork "$AC_BRANCH" Source/Core/src/Sync/A.cpp
    seed_mywork_cache
    install_git_shim
    concurrent_extender 5   # acts after every fetch of the lock
    run run_hook "Source/Core/src/Sync/C.cpp"
    [ "$status" -eq 0 ]
    assert_note_without_decision "$output"
    ctx="$(context_of "$output")"
    [[ "$ctx" == *"allowed fail-open"* ]]
    [[ "$ctx" == *"changed again while this hook re-read it"*"nothing was written"* ]]
    [ "$(cat "$AC_SANDBOX/acted")" = "2" ]
    [ "$(ws_of mywork)" = '["Source/Core/src/Sync/A.cpp","Source/Core/src/Sync/Theirs1.cpp","Source/Core/src/Sync/Theirs2.cpp"]' ]
}

@test "auto-claim: the branch's slug already held by this branch (stale cache) and covering the path allows" {
    enable_autoclaim
    reg "$REGDIR" sibling-a
    slug="$(expected_slug feat-auto-claim "$AC_BRANCH")"
    # Another session of this branch filed the slug after this session cached its table.
    plant_lock "$slug" "$AC_BRANCH" Source/Core/src/Sync/Race.cpp
    seed_table_cache '[]'
    run run_hook "Source/Core/src/Sync/Race.cpp"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(ws_of "$slug")" = '["Source/Core/src/Sync/Race.cpp"]' ]
}

@test "auto-claim: the branch's slug already held, not covering the path, fails open with a warning" {
    enable_autoclaim
    reg "$REGDIR" sibling-a
    slug="$(expected_slug feat-auto-claim "$AC_BRANCH")"
    plant_lock "$slug" "$AC_BRANCH" Source/Core/src/Sync/Elsewhere.cpp
    seed_table_cache '[]'
    run run_hook "Source/Core/src/Sync/Race.cpp"
    [ "$status" -eq 0 ]
    assert_note_without_decision "$output"
    [[ "$(context_of "$output")" == *"already held, exit 1"* ]]
    [ "$(ws_of "$slug")" = '["Source/Core/src/Sync/Elsewhere.cpp"]' ]
}

@test "auto-claim: a network failure fails OPEN with a warning" {
    enable_autoclaim
    reg "$REGDIR" sibling-a
    git -C "$PROJ" remote set-url origin "$AC_SANDBOX/missing.git"
    run run_hook "Source/Core/src/Sync/New.cpp"
    [ "$status" -eq 0 ]
    assert_note_without_decision "$output"
    ctx="$(context_of "$output")"
    [[ "$ctx" == *"allowed fail-open"* ]]
    [[ "$ctx" == *"exit 3"* ]]
}

@test "auto-claim: a hung push is cut off by the budget and fails OPEN" {
    command -v timeout >/dev/null 2>&1 || skip "no timeout(1)"
    enable_autoclaim
    reg "$REGDIR" sibling-a
    git -C "$PROJ" remote set-url origin "ssh://plan-lock.invalid/x.git"
    export GIT_SSH_COMMAND="sh -c 'sleep 30' hung-ssh"
    seed_table_cache '[]'
    start=$SECONDS
    SMATCHET_PLAN_LOCK_AUTOCLAIM_TIMEOUT=2 run run_hook "Source/Core/src/Sync/New.cpp"
    [ $((SECONDS - start)) -lt 10 ]
    [ "$status" -eq 0 ]
    assert_note_without_decision "$output"
    [[ "$(context_of "$output")" == *"exit 124"* ]]
}

# Stand-ins for timeout(1) / gtimeout: "absent" fails the --version probe;
# "real" wraps the real timeout and records that it ran.
fake_limiter() { # $1 = name, $2 = absent|real
    mkdir -p "$AC_SANDBOX/lim"
    if [ "$2" = absent ]; then
        printf '#!/bin/sh\nexit 127\n' > "$AC_SANDBOX/lim/$1"
    else
        printf '#!/bin/sh\necho "$*" >> "%s/%s.ran"\nexec "%s" "$@"\n' \
            "$AC_SANDBOX" "$1" "$(command -v timeout)" > "$AC_SANDBOX/lim/$1"
    fi
    chmod +x "$AC_SANDBOX/lim/$1"
}

@test "auto-claim: without timeout(1) or gtimeout it never runs: classic deny naming the reason, nothing claimed" {
    enable_autoclaim
    reg "$REGDIR" sibling-a
    seed_table_cache '[]'
    fake_limiter timeout absent
    fake_limiter gtimeout absent
    PATH="$AC_SANDBOX/lim:$PATH" run run_hook "Source/Core/src/Sync/New.cpp"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
    reason="$(reason_of "$output")"
    [[ "$reason" == *"Auto-claim did not run: it needs timeout(1) or gtimeout"* ]]
    [[ "$reason" == *"lock-claim.sh"* ]]
    [ -z "$(lock_refs)" ]
}

@test "auto-claim: gtimeout bounds the claim where timeout(1) is absent (macOS with coreutils)" {
    command -v timeout >/dev/null 2>&1 || skip "no timeout(1) to stand in for gtimeout"
    enable_autoclaim
    reg "$REGDIR" sibling-a
    slug="$(expected_slug feat-auto-claim "$AC_BRANCH")"
    seed_table_cache '[]'
    fake_limiter timeout absent
    fake_limiter gtimeout real
    PATH="$AC_SANDBOX/lim:$PATH" run run_hook "Source/Core/src/Sync/New.cpp"
    [ "$status" -eq 0 ]
    [[ "$(context_of "$output")" == *"auto-claimed plan-lock '$slug'"* ]]
    grep -q "lock-claim.sh $slug" "$AC_SANDBOX/gtimeout.ran"
    [ ! -e "$AC_SANDBOX/timeout.ran" ]
}

@test "auto-claim: SMATCHET_PLAN_LOCK_AUTOCLAIM=0 restores the deny and claims nothing" {
    enable_autoclaim
    reg "$REGDIR" sibling-a
    SMATCHET_PLAN_LOCK_AUTOCLAIM=0 run run_hook "Source/Core/src/Sync/New.cpp"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
    [[ "$output" == *"lock-claim.sh"* ]]
    [ -z "$(lock_refs)" ]
}

@test "auto-claim: solo (0 siblings) is unchanged: no output, no lock" {
    enable_autoclaim
    run run_hook "Source/Core/src/Sync/New.cpp"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$(lock_refs)" ]
}

@test "auto-claim: a path the write-set format cannot carry is denied, not claimed" {
    enable_autoclaim
    reg "$REGDIR" sibling-a
    run run_hook "#notes.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
    [ -z "$(lock_refs)" ]
    # A raw control byte in the path: the deny must still be valid JSON, or the
    # harness cannot read the decision and the edit goes through.
    run run_hook "Source/Core/src/Sync/a$(printf '\001')b.cpp"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
    [ -z "$(lock_refs)" ]
}

@test "auto-claim: the budget counts from the hook's start, so a slow lock-table read fails OPEN without claiming" {
    command -v timeout >/dev/null 2>&1 || skip "no timeout(1)"
    enable_autoclaim
    reg "$REGDIR" sibling-a
    install_git_shim
    export SHIM_SLOW='+refs/locks/*:refs/locks/*' SHIM_SLOW_SECS=3   # the cold-cache table read
    start=$SECONDS
    SMATCHET_PLAN_LOCK_AUTOCLAIM_TIMEOUT=2 run run_hook "Source/Core/src/Sync/New.cpp"
    [ $((SECONDS - start)) -lt 10 ]
    [ "$status" -eq 0 ]
    assert_note_without_decision "$output"
    [[ "$(context_of "$output")" == *"the lock-table read took the whole 2 s auto-claim budget"* ]]
    [ -z "$(lock_refs)" ]
}

@test "auto-claim: an integration branch (develop) is denied, never auto-claimed" {
    enable_autoclaim
    reg "$REGDIR" sibling-a
    git -C "$PROJ" checkout -q develop
    run run_hook "Source/Core/src/Sync/New.cpp"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
    [[ "$output" == *"on branch 'develop'"* ]]
    [ -z "$(lock_refs)" ]
}

@test "auto-claim: an inherited SECONDS does not make the budget look spent" {
    # bash imports SECONDS from the environment; the budget is measured from
    # the hook's own start, so a huge inherited value changes nothing.
    enable_autoclaim
    reg "$REGDIR" sibling-a
    slug="$(expected_slug feat-auto-claim "$AC_BRANCH")"
    seed_table_cache '[]'
    payload="$(jq -cn --arg fp "$PROJ/Source/Core/src/Sync/New.cpp" '{tool_name:"Edit", tool_input:{file_path:$fp}, session_id:"mysid"}')"
    run env SECONDS=100000 bash "$HOOK" <<<"$payload"
    [ "$status" -eq 0 ]
    [[ "$(context_of "$output")" == *"auto-claimed plan-lock '$slug'"* ]]
}

@test "auto-claim: a stale record never denies once its lock no longer covers the path (released, then hand-claimed)" {
    command -v timeout >/dev/null 2>&1 || skip "no timeout(1)"
    enable_autoclaim
    reg "$REGDIR" sibling-a
    slug="$(expected_slug feat-auto-claim "$AC_BRANCH")"
    plant_lock theirs feat/other Source/Core/src/Sync/Race.cpp
    seed_table_cache '[]'
    install_git_shim
    export SHIM_HANG=" :refs/locks/$slug "   # the rollback's release push hangs
    SMATCHET_PLAN_LOCK_AUTOCLAIM_TIMEOUT=4 run run_hook "Source/Core/src/Sync/Race.cpp"
    [[ "$(reason_of "$output")" == *"did not complete"* ]]
    grep -qs "$slug" "$TMPDIR"/.smatchet-planlock-unresolved-*
    unset SHIM_HANG
    # The user follows the remediation: release the auto lock, coordinate, and
    # claim the path by hand. The retried edit passes and the record goes.
    git -C "$BARE" update-ref -d "refs/locks/$slug"
    plant_lock handlock "$AC_BRANCH" Source/Core/src/Sync/Race.cpp
    rm -f "$(table_cache_file)"
    run run_hook "Source/Core/src/Sync/Race.cpp"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    ! grep -qs "$slug" "$TMPDIR"/.smatchet-planlock-unresolved-*
}

@test "auto-claim: re-adding the path to the same hand lock after the remediation is a person's claim and passes" {
    command -v timeout >/dev/null 2>&1 || skip "no timeout(1)"
    enable_autoclaim
    reg "$REGDIR" sibling-a
    PLANT_OWNER=alice plant_lock mywork "$AC_BRANCH" Source/Core/src/Sync/A.cpp
    plant_lock theirs feat/other Source/Core/src/Sync/C.cpp
    seed_mywork_cache
    install_git_shim
    # The extension lands; the restore's push hangs (as in the failed-restore case).
    cat > "$SHIM_DIR/git" <<SHIM2
#!/usr/bin/env bash
args=" \$* "
if [ "\$1" = push ] && [ -e "$AC_SANDBOX/armed" ] && [[ "\$args" == *"refs/locks/mywork"* ]]; then
    exec sleep 30 </dev/null >/dev/null 2>&1
fi
"$SHIM_REAL_GIT" "\$@"; rc=\$?
if [ "\$1" = push ] && [[ "\$args" == *"refs/locks/mywork"* ]]; then : > "$AC_SANDBOX/armed"; fi
exit "\$rc"
SHIM2
    chmod +x "$SHIM_DIR/git"
    SMATCHET_PLAN_LOCK_AUTOCLAIM_TIMEOUT=4 run run_hook "Source/Core/src/Sync/C.cpp"
    [[ "$(reason_of "$output")" == *"did not complete"* ]]
    rm -f "$AC_SANDBOX/armed" "$SHIM_DIR/git"
    # The remediation (drop the path), then the coordinated re-add, both by hand.
    printf '%s\n' Source/Core/src/Sync/A.cpp > "$AC_SANDBOX/ws-a"
    printf '%s\n' Source/Core/src/Sync/A.cpp Source/Core/src/Sync/C.cpp > "$AC_SANDBOX/ws-ac"
    (cd "$PROJ" && LOCK_BRANCH="$AC_BRANCH" AGENT_ID=alice bash "$REPO_ROOT/agents/scripts/core/lock-claim-update.sh" mywork "$AC_SANDBOX/ws-a") >/dev/null 2>&1
    (cd "$PROJ" && LOCK_BRANCH="$AC_BRANCH" AGENT_ID=alice bash "$REPO_ROOT/agents/scripts/core/lock-claim-update.sh" mywork "$AC_SANDBOX/ws-ac") >/dev/null 2>&1
    [ "$(ws_of mywork)" = '["Source/Core/src/Sync/A.cpp","Source/Core/src/Sync/C.cpp"]' ]
    rm -f "$(table_cache_file)"
    run run_hook "Source/Core/src/Sync/C.cpp"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    ! grep -qs 'C.cpp' "$TMPDIR"/.smatchet-planlock-unresolved-*
}

@test "lock-table-cache: a record lock dir left by a killed writer is broken after a minute" {
    local lib="$REPO_ROOT/agents/scripts/core/lock-table-cache.sh"
    run bash -c '
        . "$1"; cd "$2" || exit 9
        ltc_unresolved_add feat/a slug src/x.cpp deadbeef || exit 8
        f="$(_ltc_unresolved_path "$(_ltc_repo_key)")"
        mkdir "$f.lock" || exit 7
        python3 -c "import os, sys, time; t = time.time() - 120; os.utime(sys.argv[1], (t, t))" "$f.lock" || exit 6
        ltc_unresolved_drop feat/a src/x.cpp
        if ltc_unresolved_get feat/a src/x.cpp >/dev/null; then echo kept; else echo dropped; fi
        [ -d "$f.lock" ] && echo lockdir-left || echo lockdir-gone' _ "$lib" "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"dropped"* ]]
    [[ "$output" == *"lockdir-gone"* ]]
}

@test "lock-table-cache: concurrent record adds and no-op drops lose no record" {
    local lib="$REPO_ROOT/agents/scripts/core/lock-table-cache.sh" n
    run bash -c '
        . "$1"; cd "$2" || exit 9
        ( for i in $(seq 60); do ltc_unresolved_drop other-branch some/path; done ) &
        ( for i in $(seq 60); do ltc_unresolved_drop feat/a "p-nomatch"; done ) &
        for i in $(seq 60); do ltc_unresolved_add feat/a slug "p$i"; done
        wait
        for i in $(seq 60); do ltc_unresolved_get feat/a "p$i" >/dev/null || echo "lost p$i"; done
        echo done' _ "$lib" "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"done"* ]]
    [[ "$output" != *"lost"* ]]
}

@test "auto-claim: a zero-padded budget is read as decimal, not octal" {
    enable_autoclaim
    reg "$REGDIR" sibling-a
    slug="$(expected_slug feat-auto-claim "$AC_BRANCH")"
    SMATCHET_PLAN_LOCK_AUTOCLAIM_TIMEOUT=08 run run_hook "Source/Core/src/Sync/New.cpp"
    [ "$status" -eq 0 ]
    [[ "$(context_of "$output")" == *"auto-claimed plan-lock '$slug'"* ]]
}

@test "settings.json.tmpl: the hook's harness timeout (seconds) sits above the default auto-claim budget" {
    # Claude Code reads a hook's "timeout" in seconds. Below the 8 s budget the
    # harness kills a slow claim before its warning note; a millisecond-scale
    # value (3000) would let a wedged hook stall an edit for 50 minutes.
    t="$(jq -r '.hooks.PreToolUse[].hooks[] | select(.command | test("guard-plan-lock\\.sh")) | .timeout' \
        "$REPO_ROOT/docs/harness/claude-code/settings.json.tmpl")"
    [ "$(printf '%s\n' "$t" | grep -c .)" -eq 1 ]
    [ "$t" -gt 8 ]
    [ "$t" -le 120 ]
}
