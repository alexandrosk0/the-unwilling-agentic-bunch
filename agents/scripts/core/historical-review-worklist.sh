#!/usr/bin/env bash
# historical-review-worklist.sh — build a historical-review sweep work-list and
# FAIL LOUDLY when the two PR enumerators disagree.
# ----------------------------------------------------------------------------
# WHY THIS EXISTS (tooling 2026-08-16-historical-review-worklist-misses-merge-commit-prs)
#   A sweep's work-list used to be built by scraping `(#N)` off develop squash
#   subjects. That is only correct under the repo's squash-merge invariant, and
#   the invariant does not always hold: a PR merged with a MERGE COMMIT carries
#   the subject `Merge pull request #N from <branch>` (no trailing `(#N)`), and
#   its constituent commits carry no PR reference at all. Such a PR does not get
#   "skipped with a warning" — it never enters the work-list, so it cannot appear
#   in the batch's reviewed/clean/superseded counts and the batch reports a
#   complete frontier it never covered.
#
#   Measured: for #1878-#1940 GitHub reports 60 merged PRs, the scrape 53. The 7
#   invisible ones (#1883/#1919/#1920/#1921/#1923/#1927/#1932) were all merge
#   commits, and all release-publishing code that had never been survivor-
#   reviewed. Batch 20 nonetheless claimed "#1-#1940 contiguous". The same class
#   hit Batch 13 (#1439/#1577/#1593/#1597) and was caught then only because that
#   run happened to hand-cross-validate. Nothing enforced it, so honesty about
#   coverage depended on whether a given run remembered.
#
#   Second-order defect this also fixes: `git blame` attributes lines to a merge
#   commit's CONSTITUENTS, never to the merge commit itself. Feeding a merge sha
#   to historical-review-survivors.sh yields a falsely-clean `FULLY SUPERSEDED`
#   (an empty review surface that looks like "nothing to review"). Merge shas are
#   therefore expanded to one unit per constituent — promoting the Batch 16 #1593
#   "per-constituent special" from prose into the default path.
#
# THE CORE PROPERTY
#   The develop-log scrape is a CANDIDATE set, never an authority. This script
#   refuses to emit a work-list from the scrape alone: an authoritative merged-PR
#   set must be supplied (gh, or --merged-list for gh-less environments such as
#   every remote session). No authority -> exit 2, never a quiet partial list.
#
# USAGE
#   historical-review-worklist.sh --range <lo> <hi> [--merged-list <file>]
#   historical-review-worklist.sh --range=<lo>-<hi> [--merged-list=<file>]
#   historical-review-worklist.sh --selftest
#
#   --range <lo> <hi>     inclusive PR-number range to build units for.
#   --range=<lo>-<hi>     same, as one token (`,` also accepted as the separator).
#   --merged-list <file>  authoritative merged-PR numbers, whitespace/newline
#                         separated (a JSON array of numbers also parses). Use in
#                         gh-less environments; produce it from the GitHub API /
#                         MCP `list_pull_requests(base=develop, state=closed)`
#                         filtered on a non-null merged_at.
#   --against <ref>       tree to enumerate (default origin/develop).
#   --merge-oids <file>   "<pr> <sha>" lines: GitHub's merge-commit oid per PR
#                         (MCP `merge_commit_sha`). Resolves a PR the scrape
#                         misses that is NOT a `Merge pull request #N` commit —
#                         a squash whose subject was edited to drop `(#N)`, or a
#                         PR merged into another PR's branch. With gh present it
#                         is fetched per missed PR instead (`mergeCommit.oid`).
#
# OUTPUT (stdout) — a JSON array of units, ready for the sweep workflow's args:
#   [{"pr":1883,"sha":"e5aa8d11","note":"merge-PR constituent 1/2"}, ...]
# With --json, ONE OBJECT instead, carrying the computed coverage triple so the
# sweep workflow can RETURN it and a batch header quotes the computed number
# (the part-(3) close of the merge-commit work-list entry — transcribing the
# stderr triple by hand was the last asserted-not-computed step):
#   {"range":[lo,hi],"against":"...","authority":"...",
#    "coverage":{"authoritative":N,"scraped":N,"missed":[...],"covered":N,"units":N},
#    "units":[...]}
# The human-readable triple + any disagreement report still goes to STDERR.
#
# EXIT: 0 = work-list emitted and enumerators agree. 2 = usage / no authority /
# unresolvable PR / enumerator disagreement that could not be repaired.
#
# Sibling of historical-review-survivors.sh (the per-unit extractor) and
# historical-review-ledger-reconcile.sh (the staleness probe).
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

# shellcheck source=agents/scripts/core/lib/resolve-py.sh
. "$(dirname "$0")/lib/resolve-py.sh"

MODE="range"
LO=""; HI=""; MERGED_LIST=""; MERGE_OIDS=""; AGAINST="origin/develop"; JSON_OUT=0
# need_args <n> <flag> <args...> — a value-taking flag must have its values. `shift N` with fewer
# than N args left fails without shifting, and this parser runs without errexit, so a short
# trailing flag would loop forever instead of being a usage error.
need_args() {
    local n="$1" flag="$2"
    shift 2
    [ "$#" -ge "$n" ] || { echo "historical-review-worklist: $flag needs $((n - 1)) value(s)" >&2; exit 2; }
}
while [ $# -gt 0 ]; do
    case "$1" in
        --json) JSON_OUT=1; shift ;;
        --range) need_args 3 "$1" "$@"; LO="$2"; HI="$3"; shift 3 ;;
        # `--range=<lo>-<hi>` / `--range=<lo>,<hi>` — the single-token twin of the
        # two-arg form above (shell-lint FLAG_PARITY requires a `=` twin for any
        # value-taking flag; it is also the form that survives being pasted into a
        # CI `run:` line without arg-splitting surprises).
        --range=*) LO="${1#*=}"; HI="${LO#*[-,]}"; LO="${LO%%[-,]*}"; shift ;;
        --merged-list) need_args 2 "$1" "$@"; MERGED_LIST="$2"; shift 2 ;;
        --merged-list=*) MERGED_LIST="${1#*=}"; shift ;;
        --against) need_args 2 "$1" "$@"; AGAINST="$2"; shift 2 ;;
        --against=*) AGAINST="${1#*=}"; shift ;;
        --selftest) MODE="selftest"; shift ;;
        --merge-oids) need_args 2 "$1" "$@"; MERGE_OIDS="$2"; shift 2 ;;
        --merge-oids=*) MERGE_OIDS="${1#*=}"; shift ;;
        -h|--help) sed -n '2,52p' "$0"; exit 0 ;;
        *) echo "historical-review-worklist: unknown arg $1" >&2; exit 2 ;;
    esac
done

# --- pure helpers (testable without gh) --------------------------------------

# scrape_candidates <ref> <lo> <hi> — "<pr> <sha>" per line from `(#N)` subjects.
scrape_candidates() {
    git log "$1" --format='%h|%s' 2>/dev/null | awk -F'|' -v lo="$2" -v hi="$3" '
        {
            s=$0; sub(/^[^|]*\|/,"",s)
            if (match(s, /\(#[0-9]+\)$/)) {
                n = substr(s, RSTART+2, RLENGTH-3) + 0
                if (n >= lo && n <= hi) print n, $1
            }
        }' | sort -n -u
}

# read_merged_list <file> — bare PR numbers from a plain or JSON-array file.
read_merged_list() {
    tr -c '0-9' ' ' < "$1" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n -u
}

# merge_commit_for <pr> <ref> — the `Merge pull request #<pr>` commit, if any.
merge_commit_for() {
    git log "$2" --format='%h|%s' 2>/dev/null \
        | awk -F'|' -v pr="$1" '{
              s=$0; sub(/^[^|]*\|/,"",s)
              if (s ~ ("^Merge pull request #" pr "( |$)")) { print $1; exit }
          }'
}

# merge_oid_for <pr> — GitHub's merge-commit oid for <pr>: from --merge-oids
# when given, else gh. Empty when neither knows it.
merge_oid_for() {
    if [ -n "$MERGE_OIDS" ]; then
        awk -v pr="$1" '$1 == pr { print $2; exit }' "$MERGE_OIDS"
    elif command -v gh >/dev/null 2>&1; then
        gh pr view "$1" --json mergeCommit --jq '.mergeCommit.oid // empty' 2>/dev/null
    fi
}

# constituents_of <sha> — non-merge commits unique to a merge commit's topic side.
constituents_of() {
    local first
    first="$(git rev-list --parents -n1 "$1" 2>/dev/null | awk '{print $2}')"
    [ -n "$first" ] || return 1
    git log --format='%h' --no-merges "${first}..$1" 2>/dev/null
}

# is_merge_commit <sha>
is_merge_commit() {
    [ "$(git rev-list --parents -n1 "$1" 2>/dev/null | wc -w)" -ge 3 ]
}

if [ "$MODE" = "range" ]; then
    case "$LO$HI" in ''|*[!0-9]*) echo "historical-review-worklist: --range <lo> <hi> required (integers)" >&2; exit 2 ;; esac
    if ! git rev-parse --verify -q "${AGAINST}^{commit}" >/dev/null 2>&1; then
        echo "historical-review-worklist: '$AGAINST' does not resolve — fetch first" >&2; exit 2
    fi

    # --- the authority. The scrape alone is NEVER acceptable. ----------------
    AUTH_SRC=""
    AUTH_FILE="$(mktemp)"; trap 'rm -f "$AUTH_FILE"' EXIT
    if [ -n "$MERGED_LIST" ]; then
        [ -r "$MERGED_LIST" ] || { echo "historical-review-worklist: --merged-list '$MERGED_LIST' unreadable" >&2; exit 2; }
        read_merged_list "$MERGED_LIST" | awk -v lo="$LO" -v hi="$HI" '$1>=lo && $1<=hi' > "$AUTH_FILE"
        AUTH_SRC="--merged-list $MERGED_LIST"
    elif command -v gh >/dev/null 2>&1; then
        gh pr list --state merged --base develop --limit 900 --json number \
           --jq '.[].number' 2>/dev/null \
          | awk -v lo="$LO" -v hi="$HI" '$1>=lo && $1<=hi' | sort -n -u > "$AUTH_FILE"
        AUTH_SRC="gh pr list"
        [ -s "$AUTH_FILE" ] || { echo "historical-review-worklist: gh returned no merged PRs in [$LO,$HI] — refusing to emit a scrape-only work-list" >&2; exit 2; }
    else
        cat >&2 <<'EOF'
historical-review-worklist: NO AUTHORITATIVE MERGED-PR SET AVAILABLE.
  `gh` is absent and --merged-list was not supplied. The develop-log `(#N)`
  scrape is a CANDIDATE set only: it cannot see a PR merged with a merge
  commit, so emitting from it alone silently understates coverage (the
  #1878-#1940 case: 60 merged, 53 scraped). Supply the authority:
    --merged-list <file>   # numbers from list_pull_requests(base=develop,
                           # state=closed) filtered on non-null merged_at
EOF
        exit 2
    fi

    CAND_FILE="$(mktemp)"; SCRAPE_NUMS="$(mktemp)"
    trap 'rm -f "$AUTH_FILE" "$CAND_FILE" "$SCRAPE_NUMS"' EXIT
    scrape_candidates "$AGAINST" "$LO" "$HI" > "$CAND_FILE"
    awk '{print $1}' "$CAND_FILE" | sort -n -u > "$SCRAPE_NUMS"

    MISSING="$(comm -23 "$AUTH_FILE" "$SCRAPE_NUMS" | tr '\n' ' ')"
    EXTRA="$(comm -13 "$AUTH_FILE" "$SCRAPE_NUMS" | tr '\n' ' ')"

    # EXTRA = in the log but not in the merged list. Never silently dropped:
    # it means the authority is stale or the subject was hand-edited.
    if [ -n "${EXTRA// /}" ]; then
        echo "historical-review-worklist: WARN — in the develop log but NOT in the authoritative merged set: $EXTRA" >&2
        echo "  (stale authority, or an edited squash subject — verify before trusting this batch's coverage)" >&2
    fi

    UNITS=""; RESOLVED=0; UNRESOLVED=""; SHARED=""
    # A sha already emitted under another PR (a PR merged into a sibling PR's
    # branch, whose commits that sibling's merge also carries) is not reviewed
    # twice: the PR counts as covered through the shared unit.
    emit() {
        if printf '%s\n' "$UNITS" | awk -v s="$2" '$2 == s { f=1 } END { exit !f }'; then
            SHARED="${SHARED}${SHARED:+ }$1"; return
        fi
        UNITS="${UNITS}${UNITS:+$'\n'}$1 $2 $3"; RESOLVED=$((RESOLVED+1))
    }
    emit_merge() {
        local pr="$1" mc="$2" idx=0 total c
        total=$(constituents_of "$mc" | wc -l)
        if [ "$total" -eq 0 ]; then
            UNRESOLVED="${UNRESOLVED}${UNRESOLVED:+ }#$pr(no-constituents)"; return
        fi
        while read -r c; do
            [ -n "$c" ] || continue
            idx=$((idx+1)); emit "$pr" "$c" "merge-PR constituent $idx/$total"
        done < <(constituents_of "$mc")
    }

    while read -r pr sha; do
        [ -n "$pr" ] || continue
        if is_merge_commit "$sha"; then
            # A squash-subject match that is nonetheless a merge commit.
            idx=0; total=$(constituents_of "$sha" | wc -l)
            while read -r c; do
                [ -n "$c" ] || continue
                idx=$((idx+1)); emit "$pr" "$c" "merge-PR constituent $idx/$total"
            done < <(constituents_of "$sha")
        else
            emit "$pr" "$sha" ""
        fi
    done < "$CAND_FILE"

    # Repair the misses the scrape structurally cannot see.
    # `Merge pull request #N` repairs first, so a PR merged INTO a sibling's
    # branch resolves to the sibling's units as shared coverage.
    OID_MISSES=""
    for pr in $MISSING; do
        mc="$(merge_commit_for "$pr" "$AGAINST")"
        if [ -n "$mc" ]; then emit_merge "$pr" "$mc"; else OID_MISSES="$OID_MISSES $pr"; fi
    done
    # Then GitHub's own merge-commit oid: a squash whose subject was edited to
    # drop `(#N)`, or a merge commit inside another PR's branch.
    for pr in $OID_MISSES; do
        oid="$(merge_oid_for "$pr")"
        if [ -z "$oid" ] || ! git merge-base --is-ancestor "$oid" "$AGAINST" 2>/dev/null; then
            UNRESOLVED="${UNRESOLVED}${UNRESOLVED:+ }#$pr"
            continue
        fi
        if is_merge_commit "$oid"; then
            emit_merge "$pr" "$oid"
        else
            emit "$pr" "$(git log -1 --format=%h "$oid")" "squash, subject lacks (#$pr)"
        fi
    done

    AUTH_N=$(wc -l < "$AUTH_FILE" | tr -d ' ')
    SCRAPE_N=$(wc -l < "$SCRAPE_NUMS" | tr -d ' ')
    # shellcheck disable=SC2086  # SHARED is a space-separated PR list
    COVERED=$( { printf '%s\n' "$UNITS" | awk 'NF{print $1}'; printf '%s\n' $SHARED; } \
               | awk 'NF' | sort -u | wc -l | tr -d ' ')

    {
        echo "historical-review-worklist: range [$LO,$HI] against $AGAINST (authority: $AUTH_SRC)"
        echo "  authoritative merged PRs : $AUTH_N"
        echo "  develop-log scrape       : $SCRAPE_N"
        if [ -n "${MISSING// /}" ]; then
            echo "  scrape MISSED (repaired) : $MISSING"
        else
            echo "  scrape MISSED            : none"
        fi
        # shellcheck disable=SC2086
        [ -z "$SHARED" ] || echo "  covered via a shared unit: $(printf '%s\n' $SHARED | sort -n -u | tr '\n' ' ')"
        echo "  coverage                 : $COVERED/$AUTH_N PRs -> $RESOLVED review unit(s)"
    } >&2

    if [ -n "$UNRESOLVED" ]; then
        echo "historical-review-worklist: FAIL — merged PR(s) with no resolvable commit on $AGAINST: $UNRESOLVED" >&2
        echo "  Refusing to emit a work-list that silently omits them." >&2
        exit 2
    fi

    PY="$(resolve_py)" || { echo "historical-review-worklist: python required to emit JSON" >&2; exit 2; }
    printf '%s\n' "$UNITS" | "$PY" -c '
import json,sys
out=[]
for line in sys.stdin:
    line=line.rstrip("\n")
    if not line.strip(): continue
    parts=line.split(" ",2)
    u={"pr":int(parts[0]),"sha":parts[1]}
    if len(parts)>2 and parts[2].strip(): u["note"]=parts[2].strip()
    out.append(u)
if sys.argv[1] == "1":
    lo, hi, against, src, auth_n, scrape_n, covered, resolved, missing = sys.argv[2:11]
    json.dump({
        "range": [int(lo), int(hi)], "against": against, "authority": src,
        "coverage": {
            "authoritative": int(auth_n), "scraped": int(scrape_n),
            "missed": [int(m) for m in missing.split()],
            "covered": int(covered), "units": int(resolved),
        },
        "units": out,
    }, sys.stdout)
else:
    json.dump(out, sys.stdout)
sys.stdout.write("\n")' "$JSON_OUT" "$LO" "$HI" "$AGAINST" "$AUTH_SRC" \
        "$AUTH_N" "$SCRAPE_N" "$COVERED" "$RESOLVED" "${MISSING:-}"
    exit 0
fi

# --- selftest ----------------------------------------------------------------
# Replays the MOTIVATING BUG against a real git fixture: a range holding one
# squash-merged PR and one TRUE MERGE-COMMIT PR. The scrape sees only the squash
# one; the gate must notice, repair it to constituents, and never emit a
# scrape-only list.
fail=0
self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# Fixture A — the motivating bug. Merge-commit PR must be detected + expanded.
repoA="$(mktemp -d)"
(
    cd "$repoA" || exit 99
    git init -q -b develop && git config user.email t@t && git config user.name t
    mkdir -p agents/scripts/core/lib
    cp "$self" agents/scripts/core/historical-review-worklist.sh
    cp "$(dirname "$self")/lib/resolve-py.sh" agents/scripts/core/lib/resolve-py.sh
    echo a > a.txt && git add -A && git commit -qm "base"
    echo b > b.txt && git add -A && git commit -qm "feat: squashed thing (#100)"
    # a true merge-commit PR (#101) with two constituents
    git checkout -q -b topic
    echo c > c.txt && git add -A && git commit -qm "first half"
    echo d > d.txt && git add -A && git commit -qm "second half"
    git checkout -q develop
    git merge -q --no-ff topic -m "Merge pull request #101 from o/topic"
    printf '100\n101\n' > /tmp/auth.$$
    bash agents/scripts/core/historical-review-worklist.sh \
         --range 100 101 --merged-list /tmp/auth.$$ --against develop >/dev/null 2>/tmp/err.$$
    rc=$?
    out="$(bash agents/scripts/core/historical-review-worklist.sh \
             --range 100 101 --merged-list /tmp/auth.$$ --against develop 2>/dev/null)"
    err="$(cat /tmp/err.$$)"; rm -f /tmp/auth.$$ /tmp/err.$$
    [ "$rc" = "0" ] || { echo "FAIL(A): exit $rc, want 0"; exit 1; }
    case "$err" in *"scrape MISSED (repaired) : 101"*) ;; *) echo "FAIL(A): #101 not reported as missed; stderr: $err"; exit 1 ;; esac
    case "$out" in *'"pr": 101'*|*'"pr":101'*) ;; *) echo "FAIL(A): #101 absent from work-list: $out"; exit 1 ;; esac
    n=$(printf '%s' "$out" | grep -o '"pr"' | wc -l)
    [ "$n" = "3" ] || { echo "FAIL(A): want 3 units (1 squash + 2 constituents), got $n: $out"; exit 1; }
    case "$out" in *"constituent 1/2"*) ;; *) echo "FAIL(A): constituents not expanded: $out"; exit 1 ;; esac
    # The `--range=<lo>-<hi>` twin must produce a byte-identical work-list to the
    # two-arg form (else the FLAG_PARITY twin is decorative).
    printf '100\n101\n' > /tmp/auth2.$$
    out2="$(bash agents/scripts/core/historical-review-worklist.sh \
              --range=100-101 --merged-list=/tmp/auth2.$$ --against develop 2>/dev/null)"
    rm -f /tmp/auth2.$$
    [ "$out2" = "$out" ] || { echo "FAIL(A): --range=lo-hi differs from --range lo hi"; echo "  two-arg: $out"; echo "  =form  : $out2"; exit 1; }
    # --json must wrap the SAME units in an object carrying the COMPUTED
    # coverage triple (part 3: the sweep workflow returns it, so a batch header
    # quotes a computed number, never a transcription of the stderr line).
    printf '100\n101\n' > /tmp/auth3.$$
    outj="$(bash agents/scripts/core/historical-review-worklist.sh \
              --json --range 100 101 --merged-list /tmp/auth3.$$ --against develop 2>/dev/null)"
    rm -f /tmp/auth3.$$
    PYQ="$(resolve_py)" || { echo "FAIL(A): no python for --json assertion"; exit 1; }
    printf '%s\n%s\n' "$outj" "$out" | "$PYQ" -c '
import json, sys
obj = json.loads(sys.stdin.readline())
bare = json.loads(sys.stdin.readline())
cov = obj["coverage"]
assert cov == {"authoritative": 2, "scraped": 1, "missed": [101],
               "covered": 2, "units": 3}, cov
assert obj["units"] == bare, "units differ between --json and bare output"
assert obj["range"] == [100, 101] and obj["against"] == "develop", obj
' || { echo "FAIL(A): --json coverage object wrong"; exit 1; }
) || fail=1
rm -rf "$repoA"

# Fixture B — NO authority (no gh, no --merged-list) must exit 2 rather than emit
# a scrape-only list. This is the property the whole gate exists for.
# selftest: asserts-failure — a work-list with no authoritative merged set must be refused (exit 2).
repoB="$(mktemp -d)"
(
    cd "$repoB" || exit 99
    git init -q -b develop && git config user.email t@t && git config user.name t
    mkdir -p agents/scripts/core/lib
    cp "$self" agents/scripts/core/historical-review-worklist.sh
    cp "$(dirname "$self")/lib/resolve-py.sh" agents/scripts/core/lib/resolve-py.sh
    echo a > a.txt && git add -A && git commit -qm "feat: thing (#100)"
    PATH="/usr/bin:/bin" bash agents/scripts/core/historical-review-worklist.sh \
        --range 100 100 --against develop >/dev/null 2>&1
    rc=$?
    # gh may genuinely exist on a dev box; only assert the no-gh contract when absent.
    if command -v gh >/dev/null 2>&1; then exit 0; fi
    [ "$rc" = "2" ] || { echo "FAIL(B): no-authority exit $rc, want 2 (scrape-only list must be refused)"; exit 1; }
) || fail=1
rm -rf "$repoB"

# Fixture C — an authoritative PR with no resolvable commit must fail loudly, not
# vanish silently from the work-list.
# selftest: asserts-failure — a merged PR with no resolvable commit must exit 2.
repoC="$(mktemp -d)"
(
    cd "$repoC" || exit 99
    git init -q -b develop && git config user.email t@t && git config user.name t
    mkdir -p agents/scripts/core/lib
    cp "$self" agents/scripts/core/historical-review-worklist.sh
    cp "$(dirname "$self")/lib/resolve-py.sh" agents/scripts/core/lib/resolve-py.sh
    echo a > a.txt && git add -A && git commit -qm "feat: thing (#100)"
    printf '100\n102\n' > /tmp/authC.$$; : > /tmp/oidsC.$$
    bash agents/scripts/core/historical-review-worklist.sh \
        --range 100 102 --merged-list /tmp/authC.$$ --merge-oids /tmp/oidsC.$$ \
        --against develop >/dev/null 2>/tmp/errC.$$
    rc=$?; err="$(cat /tmp/errC.$$)"; rm -f /tmp/authC.$$ /tmp/oidsC.$$ /tmp/errC.$$
    [ "$rc" = "2" ] || { echo "FAIL(C): unresolvable PR exit $rc, want 2"; exit 1; }
    case "$err" in *"no resolvable commit"*) ;; *) echo "FAIL(C): missing loud message; stderr: $err"; exit 1 ;; esac
) || fail=1
rm -rf "$repoC"

# Fixture D — a PR the scrape misses that is NOT a `Merge pull request #N`
# commit: a squash whose subject was edited to drop `(#N)` (#2233/#2235/#2236),
# and a PR merged into a sibling PR's branch (#2198 inside #2207). Both must
# resolve through GitHub's merge-commit oid, and the nested one must count as
# covered via the sibling's units instead of being reviewed twice.
repoD="$(mktemp -d)"
(
    cd "$repoD" || exit 99
    git init -q -b develop && git config user.email t@t && git config user.name t
    mkdir -p agents/scripts/core/lib
    cp "$self" agents/scripts/core/historical-review-worklist.sh
    cp "$(dirname "$self")/lib/resolve-py.sh" agents/scripts/core/lib/resolve-py.sh
    echo a > a.txt && git add -A && git commit -qm "feat: thing (#100)"
    echo b > b.txt && git add -A && git commit -qm "Fix: an edited squash subject"
    squash="$(git rev-parse HEAD)"
    git checkout -q -b inner
    echo c > c.txt && git add -A && git commit -qm "inner work"
    git checkout -q -b outer develop
    echo d > d.txt && git add -A && git commit -qm "outer work"
    git merge -q --no-ff inner -m "Merge remote-tracking branch 'origin/inner' into outer"
    nested="$(git rev-parse HEAD)"
    git checkout -q develop
    git merge -q --no-ff outer -m "Merge pull request #105 from o/outer"
    printf '100\n103\n104\n105\n' > /tmp/authD.$$
    printf '103 %s\n104 %s\n' "$squash" "$nested" > /tmp/oidsD.$$
    out="$(bash agents/scripts/core/historical-review-worklist.sh --json --range 100 105 \
             --merged-list /tmp/authD.$$ --merge-oids /tmp/oidsD.$$ --against develop 2>/tmp/errD.$$)"
    rc=$?; err="$(cat /tmp/errD.$$)"; rm -f /tmp/authD.$$ /tmp/oidsD.$$ /tmp/errD.$$
    [ "$rc" = "0" ] || { echo "FAIL(D): exit $rc, want 0; stderr: $err"; exit 1; }
    case "$err" in *"covered via a shared unit: 104"*) ;; *) echo "FAIL(D): #104 not reported as shared coverage; stderr: $err"; exit 1 ;; esac
    PYQ="$(resolve_py)" || { echo "FAIL(D): no python for --json assertion"; exit 1; }
    printf '%s\n' "$out" | "$PYQ" -c '
import json, sys
obj = json.loads(sys.stdin.readline())
assert obj["coverage"]["covered"] == 4 and obj["coverage"]["units"] == 4, obj["coverage"]
notes = {u["pr"]: u.get("note", "") for u in obj["units"]}
assert notes.get(103) == "squash, subject lacks (#103)", notes
assert 104 not in notes, "nested PR re-emitted its sibling units: %r" % notes
assert sum(1 for u in obj["units"] if u["pr"] == 105) == 2, obj["units"]
' || { echo "FAIL(D): oid-resolved units wrong: $out"; exit 1; }
) || fail=1
rm -rf "$repoD"

# Fixture E — a value-taking flag left short at the end is a usage error. The parser runs
# without errexit, so a failed `shift N` used to loop forever; `timeout` turns a hang into a FAIL.
# selftest: asserts-failure — every short trailing value-taking flag must exit 2, not loop.
if command -v timeout >/dev/null 2>&1; then
    for argsE in "--range" "--range 5" "--merged-list" "--against" "--range 1 2 --merge-oids"; do
        # shellcheck disable=SC2086  # word-split the fixture on purpose
        timeout 10 bash "$self" $argsE >/dev/null 2>&1
        rcE=$?
        [ "$rcE" = "2" ] || { echo "FAIL(E): '$argsE' exit $rcE, want 2 (124 = hung)"; fail=1; }
    done
else
    echo "SKIP(E): no timeout command, so the short-trailing-flag cases are not run"
fi

if [ "$fail" = "0" ]; then echo "historical-review-worklist --selftest: PASS (4 e2e fixtures + arg parsing)"; exit 0; fi
echo "historical-review-worklist --selftest: FAIL"; exit 1
