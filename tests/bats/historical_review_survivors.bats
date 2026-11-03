#!/usr/bin/env bats
# tests/bats/historical_review_survivors.bats
# ----------------------------------------------------------------------------
# Bats tests for agents/scripts/core/historical-review-survivors.sh — the
# historical-code-review survivor extractor.
#
# Core invariant under test: a line introduced by commit A that a LATER commit
# B rewrote must NOT appear in A's survivor set (git blame re-attributes it to
# B); a line A introduced and nobody touched since MUST appear. This is what
# stops a historical re-review from re-flagging already-fixed code.
#
# Requires: bash, git, python (python3/python), bats.
# ----------------------------------------------------------------------------

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    export SCRIPT="$REPO_ROOT/agents/scripts/core/historical-review-survivors.sh"

    SANDBOX="$(mktemp -d)"
    export SANDBOX
    cd "$SANDBOX"
    git init -q
    git config user.email t@t.t
    git config user.name t
    git config commit.gpgsign false
}

teardown() {
    # Cleanup belongs HERE, never as a tail command inside a @test: a trailing
    # `rm -rf` succeeds unconditionally and becomes the test's exit status,
    # masking an assertion that failed above it (the fail-open authoring gate's
    # G-bats-cleanup-tail shape).
    rm -rf "$SANDBOX" "${REMOTE_TMP:-}"
}

@test "surviving line included, later-modified line excluded" {
    printf 'alpha\nbravo\ncharlie\n' > f.txt
    git add f.txt && git commit -qm "A: add three lines"
    A="$(git rev-parse HEAD)"
    # B rewrites only line 2.
    printf 'alpha\nBRAVO-FIXED\ncharlie\n' > f.txt
    git add f.txt && git commit -qm "B: fix line 2"

    run bash "$SCRIPT" "$A"
    [ "$status" -eq 0 ]
    # alpha + charlie survive (untouched since A); bravo does NOT (B rewrote it).
    echo "$output" | grep -q "alpha"
    echo "$output" | grep -q "charlie"
    # Counted, not `! grep`: bats ignores a negated status anywhere but the last
    # line of a test, which made these two absence checks no-ops.
    [ "$(grep -c "bravo" <<<"$output")" -eq 0 ]         # original line 2 gone
    [ "$(grep -c "BRAVO-FIXED" <<<"$output")" -eq 0 ]   # B's line is not A's survivor
    echo "$output" | grep -q "2/3 introduced line(s) still alive"
}

@test "fully superseded commit reports nothing to review" {
    printf 'one\ntwo\n' > g.txt
    git add g.txt && git commit -qm "A: two lines"
    A="$(git rev-parse HEAD)"
    printf 'ONE\nTWO\n' > g.txt          # B rewrites every line A added
    git add g.txt && git commit -qm "B: rewrite all"

    run bash "$SCRIPT" "$A"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "FULLY SUPERSEDED"
}

@test "all lines survive when nothing touched them" {
    printf 'keep1\nkeep2\n' > h.txt
    git add h.txt && git commit -qm "A: two lines"
    A="$(git rev-parse HEAD)"
    echo "unrelated" > other.txt          # B touches a different file
    git add other.txt && git commit -qm "B: unrelated file"

    run bash "$SCRIPT" "$A"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "keep1"
    echo "$output" | grep -q "keep2"
    echo "$output" | grep -q "2/2 introduced line(s) still alive"
}

@test "non-ancestor commit is rejected" {
    printf 'x\n' > k.txt
    git add k.txt && git commit -qm "base"
    git checkout -q -b side
    printf 'y\n' > k.txt
    git add k.txt && git commit -qm "side-only commit"
    SIDE="$(git rev-parse HEAD)"
    git checkout -q -
    run bash "$SCRIPT" "$SIDE"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "not an ancestor"
}

@test "deleted-since file contributes no survivors" {
    printf 'gone1\ngone2\n' > d.txt
    git add d.txt && git commit -qm "A: add file"
    A="$(git rev-parse HEAD)"
    git rm -q d.txt && git commit -qm "B: delete file"
    run bash "$SCRIPT" "$A"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "FULLY SUPERSEDED"
}

@test "dotted nested-path workflow survivor appears (MSYS rev:path mangling regression)" {
    # Regression for the Git-for-Windows/MSYS bug where the existence guard ran
    # `git cat-file -e "<ref>:<path>"`: MSYS rewrote the colon arg (':' -> ';',
    # '/' -> '\'), so the guard errored (fatal=128) and the old `|| continue`
    # SILENTLY dropped a fully-alive survivor file from the digest.
    #
    # Two conditions are BOTH required to trip the MSYS path-list heuristic, so
    # the test must reproduce both or it proves nothing:
    #   (1) the <path> after the colon is a dotted nested path (".github/...");
    #   (2) the <ref> BEFORE the colon contains a slash. A bare "HEAD" does NOT
    #       mangle ("HEAD" isn't path-like), so we force a slash-bearing review
    #       ref via `--against refs/heads/<branch>` — the production shape
    #       (`origin/develop:.github/...`). Pre-fix under MSYS this digest omits
    #       the file; the post-fix ls-tree guard keeps it. On Linux the bug never
    #       manifests, so the assertion holds either way.
    mkdir -p .github/workflows
    printf 'name: tsan\njobs:\n  build:\n    runs-on: ubuntu-latest\n' > .github/workflows/tsan.yml
    git add .github/workflows/tsan.yml && git commit -qm "A: add workflow"
    A="$(git rev-parse HEAD)"
    echo "unrelated" > other.txt          # B touches a different file; workflow survives intact
    git add other.txt && git commit -qm "B: unrelated file"
    REF="refs/heads/$(git rev-parse --abbrev-ref HEAD)"   # slash-bearing — needed to trip the bug

    run bash "$SCRIPT" --against "$REF" "$A"
    [ "$status" -eq 0 ]
    # The alive workflow MUST appear — it was silently dropped before the fix.
    echo "$output" | grep -q ".github/workflows/tsan.yml"
    echo "$output" | grep -q "runs-on: ubuntu-latest"
    ! echo "$output" | grep -q "FULLY SUPERSEDED"
}

@test "parser temp path survives MSYS conversion being disabled (native python handoff)" {
    # Complementary to the colon-mangling guard above. Operators sometimes export
    # MSYS_NO_PATHCONV / MSYS2_ARG_CONV_EXCL globally (e.g. to keep <rev>:<path>
    # git args intact). With conversion OFF, the POSIX mktemp parser path
    # (/tmp/tmp.XXXX.py) reaches a NATIVE Windows python verbatim and is
    # mis-resolved as C:\tmp\.. — the script must cygpath-normalise it before the
    # handoff. No-op on Linux/macOS (vars unused, cygpath absent), so the
    # assertions hold either way.
    export MSYS_NO_PATHCONV=1
    export MSYS2_ARG_CONV_EXCL='*'
    printf 'survive1\nsurvive2\n' > m.txt
    git add m.txt && git commit -qm "A: two lines"
    A="$(git rev-parse HEAD)"
    echo "elsewhere" > n.txt && git add n.txt && git commit -qm "B: unrelated file"

    run bash "$SCRIPT" "$A"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "survive1"
    echo "$output" | grep -q "survive2"
    echo "$output" | grep -q "2/2 introduced line(s) still alive"
}

@test "origin without origin/HEAD: reviews against origin/develop, not local HEAD" {
    # Regression: `git rev-parse --abbrev-ref origin/HEAD` ECHOES "origin/HEAD"
    # on stdout while failing, so the old `[ -z "$DEFREF" ]` guard skipped the
    # origin/develop fallback and fell through to local HEAD. A clone made by
    # `git remote add` + fetch (this session's shape) has no origin/HEAD, so
    # every run silently used a stale baseline and re-flagged fixed lines.
    printf 'alpha\nbravo\n' > f.txt
    git add f.txt && git commit -qm "A: add two lines"
    A="$(git rev-parse HEAD)"
    # A later commit rewrites 'bravo' — it must NOT survive.
    printf 'alpha\nBRAVO-REWRITTEN\n' > f.txt
    git add f.txt && git commit -qm "B: rewrite bravo"

    # Publish B as origin/develop, then park local HEAD back on A so local HEAD
    # is genuinely behind the canonical ref.
    REMOTE_TMP="$(mktemp -d)"
    export REMOTE_TMP
    git init -q --bare "$REMOTE_TMP"
    git remote add origin "$REMOTE_TMP"
    git push -q origin HEAD:develop
    git fetch -q origin
    git checkout -q "$A"
    # The bug's precondition: no origin/HEAD in this clone.
    run git rev-parse --verify -q origin/HEAD
    [ "$status" -ne 0 ]

    run bash "$SCRIPT" "$A" --context 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"Reviewed against: origin/develop"* ]]
    # bravo was rewritten by B, so against origin/develop it is superseded.
    ! echo "$output" | grep -q "bravo"
}

@test "no origin at all: falls back to HEAD but SAYS the baseline is local" {
    printf 'alpha\n' > f.txt
    git add f.txt && git commit -qm "A: add a line"
    A="$(git rev-parse HEAD)"
    run bash "$SCRIPT" "$A" --context 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"Reviewed against: HEAD"* ]]
    # Degrading silently is what made the fallback dangerous.
    [[ "$output" == *"not the canonical latest"* ]]
}

@test "binary file contributes no survivors (golden PNGs must not outrank source)" {
    printf 'alpha\nbravo\n' > f.txt
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x01\x02\x03binary\x00bytes\n' > img.png
    git add f.txt img.png && git commit -qm "A: add source and a binary"
    A="$(git rev-parse HEAD)"
    run bash "$SCRIPT" "$A" --context 0
    [ "$status" -eq 0 ]
    # The source file is still reviewed...
    [[ "$output" == *"=== f.txt ==="* ]]
    # ...but the binary never appears as a reviewable file.
    ! echo "$output" | grep -q "=== img.png ==="
}

@test "a submodule pointer (gitlink) in the commit is skipped, not fatal" {
    # git blame on a gitlink exits 128 ("no such path"); under pipefail that used
    # to abort the whole digest for any commit that also moved a submodule
    # pointer, so its real files were never reviewed.
    printf 'alpha\nbravo\n' > f.txt
    git add f.txt
    git update-index --add --cacheinfo "160000,$(git hash-object -t blob --stdin </dev/null),sub"
    git commit -qm "A: add source and a submodule pointer"
    A="$(git rev-parse HEAD)"
    run bash "$SCRIPT" "$A" --context 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== f.txt ==="* ]]
    [[ "$output" == *"2/2 introduced line(s) still alive"* ]]
    [ "$(grep -c "=== sub ===" <<<"$output")" -eq 0 ]
}

@test "a commit that only moves a submodule pointer is NOTHING TO ASSESS, not superseded" {
    # Zero introduced lines because nothing reviewable was there must not read as
    # "every line was since replaced": the ledger reconcile drops a finding on that banner.
    printf 'alpha\n' > f.txt
    git add f.txt
    git commit -qm "base"
    git update-index --add --cacheinfo "160000,$(git hash-object -t blob --stdin </dev/null),sub"
    git commit -qm "A: pointer bump only"
    A="$(git rev-parse HEAD)"
    run bash "$SCRIPT" "$A" --context 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOTHING TO ASSESS"* ]]
    ! echo "$output" | grep -q "FULLY SUPERSEDED"
}

@test "a binary-only commit is NOTHING TO ASSESS" {
    printf 'alpha\n' > f.txt
    git add f.txt
    git commit -qm "base"
    printf '\x00\x01\x02' > blob.bin
    git add blob.bin
    git commit -qm "A: binary only"
    A="$(git rev-parse HEAD)"
    run bash "$SCRIPT" "$A" --context 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOTHING TO ASSESS"* ]]
}

@test "lines added to a file deleted since are still FULLY SUPERSEDED, not NOTHING TO ASSESS" {
    printf 'alpha\n' > keep.txt
    git add keep.txt
    git commit -qm "base"
    printf 'bravo\n' > gone.txt
    git add gone.txt
    git commit -qm "A: add gone.txt"
    A="$(git rev-parse HEAD)"
    git rm -q gone.txt
    git commit -qm "B: delete it"
    run bash "$SCRIPT" "$A" --context 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"FULLY SUPERSEDED"* ]]
    ! echo "$output" | grep -q "NOTHING TO ASSESS"
}

@test "a commit that only deletes a file is NOTHING TO ASSESS, not superseded" {
    printf 'alpha\n' > keep.txt
    printf 'bravo\n' > doomed.txt
    git add keep.txt doomed.txt
    git commit -qm "base"
    git rm -q doomed.txt
    git commit -qm "A: delete only"
    A="$(git rev-parse HEAD)"
    run bash "$SCRIPT" "$A" --context 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOTHING TO ASSESS"* ]]
    ! echo "$output" | grep -q "FULLY SUPERSEDED"
}

@test "a pure rename is NOTHING TO ASSESS, not superseded (the moved code is still there)" {
    printf 'alpha\nbravo\ncharlie\ndelta\n' > a.txt
    git add a.txt
    git commit -qm "base"
    git mv a.txt b.txt
    git commit -qm "A: rename only"
    A="$(git rev-parse HEAD)"
    run bash "$SCRIPT" "$A" --context 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOTHING TO ASSESS"* ]]
    ! echo "$output" | grep -q "FULLY SUPERSEDED"
}

@test "a pure rename whose new path was later deleted is still NOTHING TO ASSESS" {
    printf 'alpha\nbravo\n' > a.txt
    git add a.txt
    git commit -qm "base"
    git mv a.txt b.txt
    git commit -qm "A: rename only"
    A="$(git rev-parse HEAD)"
    git rm -q b.txt
    git commit -qm "B: delete the renamed file"
    run bash "$SCRIPT" "$A" --context 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOTHING TO ASSESS"* ]]
    ! echo "$output" | grep -q "FULLY SUPERSEDED"
}

@test "a binary-only addition later deleted is NOTHING TO ASSESS" {
    printf 'x\n' > keep.txt
    git add keep.txt
    git commit -qm "base"
    printf '\000\001\002\003' > blob.bin
    git add blob.bin
    git commit -qm "A: binary only"
    A="$(git rev-parse HEAD)"
    git rm -q blob.bin
    git commit -qm "B: delete the binary"
    run bash "$SCRIPT" "$A" --context 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOTHING TO ASSESS"* ]]
    ! echo "$output" | grep -q "FULLY SUPERSEDED"
}

@test "a binary-only addition later replaced by a directory is NOTHING TO ASSESS" {
    printf 'x\n' > keep.txt
    git add keep.txt
    git commit -qm "base"
    printf '\000\001\002\003' > blob.bin
    git add blob.bin
    git commit -qm "A: binary only"
    A="$(git rev-parse HEAD)"
    git rm -q blob.bin
    mkdir blob.bin
    printf 'y\n' > blob.bin/inner.txt
    git add blob.bin/inner.txt
    git commit -qm "B: a directory where the binary was"
    run bash "$SCRIPT" "$A" --context 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOTHING TO ASSESS"* ]]
    ! echo "$output" | grep -q "FULLY SUPERSEDED"
}

@test "a removal-only edit whose file was later deleted is NOTHING TO ASSESS" {
    printf 'alpha\nbravo\n' > a.txt
    git add a.txt
    git commit -qm "base"
    printf 'alpha\n' > a.txt
    git commit -qam "A: remove a line"
    A="$(git rev-parse HEAD)"
    git rm -q a.txt
    git commit -qm "B: delete the file"
    run bash "$SCRIPT" "$A" --context 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOTHING TO ASSESS"* ]]
    ! echo "$output" | grep -q "FULLY SUPERSEDED"
}

@test "a binary rename whose new path was later deleted is NOTHING TO ASSESS" {
    printf '\000\001\002\003' > blob.bin
    git add blob.bin
    git commit -qm "base"
    git mv blob.bin moved.bin
    git commit -qm "A: rename the binary"
    A="$(git rev-parse HEAD)"
    git rm -q moved.bin
    git commit -qm "B: delete it"
    run bash "$SCRIPT" "$A" --context 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOTHING TO ASSESS"* ]]
    ! echo "$output" | grep -q "FULLY SUPERSEDED"
}

@test "a rename with an edit counts only the edited lines" {
    printf 'alpha\nbravo\ncharlie\ndelta\necho\n' > a.txt
    git add a.txt
    git commit -qm "base"
    git mv a.txt b.txt
    printf 'alpha\nbravo\ncharlie\ndelta\necho\nfoxtrot\n' > b.txt
    git add b.txt
    git commit -qm "A: rename plus one line"
    A="$(git rev-parse HEAD)"
    run bash "$SCRIPT" "$A" --context 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"~1/1 introduced line(s) still alive"* ]]
    echo "$output" | grep -q "foxtrot"
}

@test "a submodule pointer added and later removed is NOTHING TO ASSESS" {
    printf 'alpha\n' > keep.txt
    git add keep.txt
    git commit -qm "base"
    git update-index --add --cacheinfo "160000,$(git hash-object -t blob --stdin </dev/null),sub"
    git commit -qm "A: add a pointer"
    A="$(git rev-parse HEAD)"
    git rm -q --cached sub
    git commit -qm "B: drop it"
    run bash "$SCRIPT" "$A" --context 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOTHING TO ASSESS"* ]]
    ! echo "$output" | grep -q "FULLY SUPERSEDED"
}

@test "a file later replaced by a directory is FULLY SUPERSEDED, not fatal" {
    printf 'alpha\n' > keep.txt
    git add keep.txt
    git commit -qm "base"
    printf 'bravo\n' > thing
    git add thing
    git commit -qm "A: add thing as a file"
    A="$(git rev-parse HEAD)"
    git rm -q thing
    mkdir thing
    printf 'charlie\n' > thing/inner.txt
    git add thing/inner.txt
    git commit -qm "B: thing becomes a directory"
    run bash "$SCRIPT" "$A" --context 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"FULLY SUPERSEDED"* ]]
}

@test "a file later replaced by a submodule pointer is FULLY SUPERSEDED" {
    printf 'alpha\n' > keep.txt
    git add keep.txt
    git commit -qm "base"
    printf 'bravo\n' > sub
    git add sub
    git commit -qm "A: add sub as a file"
    A="$(git rev-parse HEAD)"
    git rm -q --cached sub
    rm sub
    git update-index --add --cacheinfo "160000,$(git hash-object -t blob --stdin </dev/null),sub"
    git commit -qm "B: replace it with a pointer"
    run bash "$SCRIPT" "$A" --context 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"FULLY SUPERSEDED"* ]]
    ! echo "$output" | grep -q "NOTHING TO ASSESS"
}
