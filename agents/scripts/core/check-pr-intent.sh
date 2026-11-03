#!/usr/bin/env bash
# check-pr-intent.sh — validate a PR body has a filled `## Intent` section BEFORE
# opening the PR out-of-band (GitHub MCP / REST `create_pull_request`), so the body
# can't ship without Intent and red the required-adjacent `Intent section` CI check
# (postmortems 2026-06-20 #1438: an API-opened PR with no `## Intent` reded the gate;
# the gate self-heals on a body edit, but the cheaper path is to never ship the miss).
# Local mirror of `.github/workflows/doc-validation.yml` job `Intent section` — keep
# the regex in sync with that job.
#
# Usage:
#   bash check-pr-intent.sh <body-file>     # validate a file
#   bash check-pr-intent.sh < body.txt      # or stdin
#   bash check-pr-intent.sh --selftest
#
# Exit: 0 = `## Intent` present + filled; 1 = missing/empty; 2 = usage / no python3.
#
# selftest: asserts-failure
set -euo pipefail

# shellcheck source=agents/scripts/core/lib/resolve-py.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/resolve-py.sh"
PY="$(resolve_py)" || { echo "check-pr-intent: python3 required (no working interpreter on PATH)" >&2; exit 2; }

# _check <body-text> — mirrors the doc-validation.yml `Intent section` python.
# Body goes through the ENV (never an inline arg into the python source) so a
# backtick / $() in a title can't re-parse — same discipline as the CI job.
_check() {
    PR_BODY="$1" "$PY" - <<'PY'
import os, re, sys
body = os.environ.get("PR_BODY", "") or ""
m = re.search(r'(?ms)^##\s+Intent\s*$(.*?)(?=^##\s|\Z)', body)
if not m:
    print("check-pr-intent: MISSING `## Intent` section. Add a one-line redacted "
          "statement of the originating ask (docs/agent-rules/ship-loops.md "
          "§ Intent capture), or apply the 'intent-out-of-band' label.", file=sys.stderr)
    sys.exit(1)
section = re.sub(r'(?s)<!--.*?-->', '', m.group(1)).strip()
if not section:
    print("check-pr-intent: EMPTY `## Intent` (only the template placeholder). "
          "Fill it with the originating ask.", file=sys.stderr)
    sys.exit(1)
# Pre-first-push review verdict — the review step otherwise leaves no trace
# (pre-first-push-review-step-is-unenforced-and-was-skipped). Comments are
# stripped FIRST so the template's commented placeholder cannot satisfy it.
# This proves a claim was RECORDED, never that the review ran — the entry is
# explicit that a check can do no more, which is why it lives in the body lint
# and not the pre-push hook. KEEP IN SYNC with doc-validation.yml `Intent section`.
stripped = re.sub(r'(?s)<!--.*?-->', '', body)
verdict_re = re.compile(
    r'(?mi)^\s*(?:[-*+]\s+)?(?:\[[ xX]\]\s+)?[*_`]*adversarial-code-review[*_`]*\s*:[*_]*\s*'
    r'(?:\d+\s+findings?\b(?:[\s,:;—–-]*(?![<,\s:;—–-])\S.*)?|n/a\s*[—–-]+\s*(?!<)\S.*)[ \t]*\r?$')
mv = verdict_re.search(stripped)
if not mv:
    print("check-pr-intent: MISSING review verdict. Add a line "
          "`adversarial-code-review: N findings, <disposition>` or "
          "`adversarial-code-review: n/a — <reason>` "
          "(ship-loops.md § [pre-first-push gate] item 5).", file=sys.stderr)
    sys.exit(1)
# Head binding — a verdict that names no commit is "reviewed something once";
# binding it to the head makes every push invalidate the prior verdict, so an
# unreviewed push is machine-visible (review-verdict-not-bound-to-head,
# process 2026-08-13: the recorded verdict survived six review-fix pushes it
# never covered). The template's literal `head=<sha>` cannot match the hex
# class, so an unfilled placeholder stays red. KEEP IN SYNC with
# doc-validation.yml `Intent section`.
head_re = re.compile(r'\bhead=([0-9a-f]{7,40})\b')
hm = head_re.search(mv.group(0))
if not hm:
    print("check-pr-intent: MISSING head= binding on the review verdict. Append "
          "`(head=<sha>)` naming the reviewed head — "
          "`bash agents/scripts/core/record-review-verdict.sh` stamps and prints "
          "the line. Every push invalidates the prior verdict.", file=sys.stderr)
    sys.exit(1)
expected = os.environ.get("PR_HEAD_SHA", "")
if expected and not (expected.startswith(hm.group(1)) or hm.group(1).startswith(expected)):
    print("check-pr-intent: STALE review verdict — recorded head=%s but the PR head "
          "is %s. The diff changed since the recorded review: re-review the delta "
          "(or record a fresh `n/a — <reason>` for a trivial delta) and update the "
          "verdict line." % (hm.group(1), expected), file=sys.stderr)
    sys.exit(1)
print("check-pr-intent: OK — `## Intent` present and filled; review verdict recorded and head-bound.")
PY
}

# _check_independent <body-text> <changed-files-file> — the independent-review
# requirement for a diff that edits the review-enforcement surface itself
# (RA_ENFORCEMENT_GLOBS: gate scripts, lint rules, dev scripts, git hooks, CI,
# harness hooks, gate config, the agent-layer gitlink). A self-review is where a
# blind spot in gate logic is most expensive, so such a diff must also record a
# review by someone other than the author: `independent-review: <who>; N
# findings[, <disposition>] (head=<sha>)` (process 2026-08-17
# cr-finding-gate-accepts-a-verdict-line-without-a-review, action 3). Like the
# verdict line, this proves a claim was recorded for THIS head, never that the
# review ran. A diff that touches none of those paths needs no such line.
_check_independent() {
    local body="$1" files="$2"
    [ -r "$files" ] || { echo "check-pr-intent: cannot read changed-files list: $files" >&2; return 2; }
    # shellcheck source=agents/scripts/core/lib/review-ack.sh
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/review-ack.sh"
    PR_BODY="$body" CHANGED_FILES="$files" PR_AUTHOR="${PR_AUTHOR:-}" \
        ENFORCEMENT_GLOBS="$(printf '%s\n' "${RA_ENFORCEMENT_GLOBS[@]}")" "$PY" - <<'PY'
import fnmatch, os, re, sys
body = os.environ.get("PR_BODY", "") or ""
globs = [g for g in os.environ["ENFORCEMENT_GLOBS"].splitlines() if g]
with open(os.environ["CHANGED_FILES"], encoding="utf-8") as fh:
    changed = [ln.strip() for ln in fh if ln.strip()]
# Git pathspec glob semantics: `*` also matches `/`, as fnmatchcase does.
hits = [f for f in changed if any(fnmatch.fnmatchcase(f, g) for g in globs)]
if not hits:
    print("check-pr-intent: independent review not required — no change under the review-enforcement surface.")
    sys.exit(0)
shown = ", ".join(hits[:3]) + (" …" if len(hits) > 3 else "")
# Text GitHub does not render as a plain line cannot carry the review: closed and
# unclosed HTML comments, and fenced code blocks.
# CRLF (the web editor's line ending) is normalised first so `$` meets a bare `\n`.
stripped = re.sub(r'(?s)<!--.*?(?:-->|\Z)', '', body.replace('\r\n', '\n'))
stripped = re.sub(r'(?ms)^[ \t]*(`{3,}|~{3,}).*?(?:^[ \t]*\1[`~]*[ \t]*$|\Z)', '', stripped)
ind_re = re.compile(
    r'(?mi)^\s*(?:[-*+]\s+)?(?:\[[ xX]\]\s+)?[*_`]*independent-review[*_`]*\s*:[*_]*\s*'
    r'(?P<who>(?![<\s])[^;\n]*?)\s*;\s*\d+\s+findings?\b(?:[\s,:;—–-]*(?![<,\s:;—–-])\S.*)?[ \t]*\r?$')
NOT_A_REVIEWER = {"self", "myself", "none", "n/a", "na", "author", "the author",
                  "me", "reviewer", "<reviewer>"}
expected = os.environ.get("PR_HEAD_SHA", "")
author = (os.environ.get("PR_AUTHOR", "") or "").strip().lstrip("@").lower()

def problem(m):
    """None when this line is a valid, current independent review, else why not."""
    who = m.group("who").strip().strip("*_`").strip().rstrip(".,!").strip()
    key = who.lstrip("@").lower()
    if not who or key in NOT_A_REVIEWER or (author and key == author):
        return ("independent review names no independent reviewer (%r). Name who reviewed it, "
                "other than the PR author: a separate review agent run, a review bot, or a person." % who)
    hm = re.search(r'\bhead=([0-9a-f]{7,40})\b', m.group(0))
    if not hm:
        return ("MISSING head= binding on the independent review. Append `(head=<sha>)` "
                "naming the reviewed head.")
    if expected and not (expected.startswith(hm.group(1)) or hm.group(1).startswith(expected)):
        return ("STALE independent review — recorded head=%s but the PR head is %s. Have the "
                "delta re-reviewed and update the line." % (hm.group(1), expected))
    return None

matches = list(ind_re.finditer(stripped))
if not matches:
    print("check-pr-intent: MISSING independent review. This diff edits the review-enforcement "
          "surface (%s), so the PR body must also record a review by someone other than the "
          "author: `independent-review: <reviewer>; N findings, <disposition> (head=<sha>)` "
          "(ship-loops.md § [pre-first-push gate] item 5)." % shown, file=sys.stderr)
    sys.exit(1)
# Any one valid line passes, so an older line left above a re-recorded one is harmless.
problems = [problem(m) for m in matches]
for m, why in zip(matches, problems):
    if why is None:
        print("check-pr-intent: OK — independent review recorded by %s and head-bound "
              "(%d enforcement-surface file(s))." % (m.group("who").strip(), len(hits)))
        sys.exit(0)
print("check-pr-intent: " + problems[-1], file=sys.stderr)
sys.exit(1)
PY
}

run_selftest() {
    local rc=0
    # Failure path: a body with no `## Intent` MUST be rejected.
    _check "## Summary"$'\n\n'"no intent here" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "check-pr-intent --selftest: FAIL — did not block a body missing ## Intent" >&2
        return 1
    fi
    # Pass path: a filled `## Intent` + a findings-form verdict MUST be accepted.
    # Pass fixtures carry `(head=…)` and pin PR_HEAD_SHA="" so each case tests
    # ONE thing: here the verdict grammar, with head binding in presence-only
    # mode (no expected head to compare against). Head cases come later.
    rc=0
    PR_HEAD_SHA="" _check "## Intent"$'\n\n'"Fix the thing the user asked for."$'\n\n'"adversarial-code-review: 4 findings, all fixed (head=abc1234)" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "check-pr-intent --selftest: FAIL — blocked a body WITH intent + findings verdict" >&2
        return 1
    fi
    # Pass path: the n/a escape form MUST be accepted.
    rc=0
    PR_HEAD_SHA="" _check "## Intent"$'\n\n'"Fix it."$'\n\n'"- adversarial-code-review: n/a — trivial one-line doc fix (head=abc1234)" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "check-pr-intent --selftest: FAIL — blocked the n/a verdict escape" >&2
        return 1
    fi
    # Empty-section path (template placeholder only) MUST be rejected.
    rc=0
    _check "## Intent"$'\n\n'"<!-- placeholder -->" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "check-pr-intent --selftest: FAIL — did not block an empty ## Intent" >&2
        return 1
    fi
    # Verdict-missing path: intent filled but NO verdict line MUST be rejected,
    # and for the RIGHT reason — a bare non-zero would also be produced by a
    # python error or a broken Intent regex, so assert the message names it.
    local out
    out="$(_check "## Intent"$'\n\n'"Fix it, no review recorded." 2>&1)" && {
        echo "check-pr-intent --selftest: FAIL — did not block a body with no review verdict" >&2
        return 1
    }
    case "$out" in
        *"MISSING review verdict"*) ;;
        *) echo "check-pr-intent --selftest: FAIL — verdict-missing body rejected for the wrong reason:" >&2
           printf '%s\n' "$out" | sed 's/^/    /' >&2
           return 1 ;;
    esac
    # A verdict living ONLY inside an HTML comment (the untouched template) MUST
    # be rejected — comments are stripped before the search. The comment is
    # MULTI-LINE deliberately: on a single-line `<!-- adversarial... -->` the
    # `<!--` prefix already breaks the line-start match, so that shape rejects
    # even WITHOUT the strip and proves nothing about it (found by mutation:
    # `stripped = body` stayed green against the single-line form). Inside a
    # multi-line comment the verdict line stands alone and WOULD match raw.
    out="$(_check "## Intent"$'\n\n'"Fix it."$'\n\n'"<!--"$'\n'"adversarial-code-review: 0 findings"$'\n'"-->" 2>&1)" && {
        echo "check-pr-intent --selftest: FAIL — a commented-out verdict satisfied the check" >&2
        return 1
    }
    case "$out" in
        *"MISSING review verdict"*) ;;
        *) echo "check-pr-intent --selftest: FAIL — commented-verdict body rejected for the wrong reason:" >&2
           printf '%s\n' "$out" | sed 's/^/    /' >&2
           return 1 ;;
    esac
    # The template's n/a line uncommented but NOT filled in — the reason is still
    # the literal `<reason the diff is trivial>` placeholder — MUST be rejected.
    # Without the `(?!<)` guard this false-passed: `\S.*` happily accepted `<r…`,
    # so following the template's instructions halfway earned a green verdict.
    out="$(_check "## Intent"$'\n\n'"Fix it."$'\n\n'"adversarial-code-review: n/a — <reason the diff is trivial>" 2>&1)" && {
        echo "check-pr-intent --selftest: FAIL — an unfilled n/a placeholder satisfied the check" >&2
        return 1
    }
    case "$out" in
        *"MISSING review verdict"*) ;;
        *) echo "check-pr-intent --selftest: FAIL — placeholder n/a rejected for the wrong reason:" >&2
           printf '%s\n' "$out" | sed 's/^/    /' >&2
           return 1 ;;
    esac
    # The FINDINGS branch has the same placeholder hole: a count filled in but
    # the disposition left as the literal `<disposition>` template MUST be
    # rejected. The naive guard `[,:—–-]*\s*(?!<)\S` still PASSES this via
    # backtracking — the separator class gives back the comma, `\S` matches the
    # comma itself, and the lookahead never sees the `<`. The separator class
    # and the disposition-start class must be DISJOINT so backtracking cannot
    # reassign the comma. (CodeRabbit's committable suggestion had exactly the
    # backtracking hole; verified before adopting the disjoint form.)
    out="$(_check "## Intent"$'\n\n'"Fix it."$'\n\n'"adversarial-code-review: 0 findings, <disposition>" 2>&1)" && {
        echo "check-pr-intent --selftest: FAIL — an unfilled findings-disposition placeholder satisfied the check" >&2
        return 1
    }
    case "$out" in
        *"MISSING review verdict"*) ;;
        *) echo "check-pr-intent --selftest: FAIL — placeholder findings-form rejected for the wrong reason:" >&2
           printf '%s\n' "$out" | sed 's/^/    /' >&2
           return 1 ;;
    esac
    # A bare count with NO disposition stays accepted — `0 findings` is a
    # complete verdict; the guard's job is placeholders, not prose quality.
    rc=0
    PR_HEAD_SHA="" _check "## Intent"$'\n\n'"Fix it."$'\n\n'"adversarial-code-review: 0 findings (head=abc1234)" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "check-pr-intent --selftest: FAIL — blocked a bare-count verdict (0 findings)" >&2
        return 1
    fi
    # ... including with TRAILING whitespace (Markdown hard-break spaces, a
    # stray tab, or a CR from a CRLF body). Invisible to the author, so
    # rejecting it produces an undebuggable red; `[ \t]*\r?` before `$` eats it.
    rc=0
    PR_HEAD_SHA="" _check "## Intent"$'\n\n'"Fix it."$'\n\n'"adversarial-code-review: 0 findings (head=abc1234)  " >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "check-pr-intent --selftest: FAIL — blocked a bare-count verdict with trailing whitespace" >&2
        return 1
    fi
    # Head binding: a verdict with NO head= token MUST be rejected, for the
    # head reason (not a grammar miss — the verdict line itself is valid).
    out="$(PR_HEAD_SHA="" _check "## Intent"$'\n\n'"Fix it."$'\n\n'"adversarial-code-review: 0 findings" 2>&1)" && {
        echo "check-pr-intent --selftest: FAIL — accepted a verdict with no head= binding" >&2
        return 1
    }
    case "$out" in
        *"MISSING head="*) ;;
        *) echo "check-pr-intent --selftest: FAIL — head-less verdict rejected for the wrong reason:" >&2
           printf '%s\n' "$out" | sed 's/^/    /' >&2
           return 1 ;;
    esac
    # The template's literal `(head=<sha>)` placeholder MUST stay red — the hex
    # class cannot match `<sha>`, so pasting the template unfilled is caught.
    out="$(PR_HEAD_SHA="" _check "## Intent"$'\n\n'"Fix it."$'\n\n'"adversarial-code-review: 0 findings (head=<sha>)" 2>&1)" && {
        echo "check-pr-intent --selftest: FAIL — the literal head=<sha> placeholder satisfied the check" >&2
        return 1
    }
    case "$out" in
        *"MISSING head="*) ;;
        *) echo "check-pr-intent --selftest: FAIL — placeholder head rejected for the wrong reason:" >&2
           printf '%s\n' "$out" | sed 's/^/    /' >&2
           return 1 ;;
    esac
    # With PR_HEAD_SHA set, a recorded head that PREFIXES the actual head MUST
    # pass — record-review-verdict.sh stamps a short sha, CI supplies the full one.
    rc=0
    PR_HEAD_SHA="abc1234def5678900aabbccddeeff00112233445" _check "## Intent"$'\n\n'"Fix it."$'\n\n'"adversarial-code-review: 0 findings (head=abc1234)" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "check-pr-intent --selftest: FAIL — blocked a verdict whose head= matches PR_HEAD_SHA" >&2
        return 1
    fi
    # ... and a recorded head that does NOT match MUST be rejected as STALE —
    # this is the whole point of the binding: a push after the review invalidates
    # the verdict (review-verdict-not-bound-to-head).
    out="$(PR_HEAD_SHA="deadbeef00112233445566778899aabbccddeeff" _check "## Intent"$'\n\n'"Fix it."$'\n\n'"adversarial-code-review: 0 findings (head=abc1234)" 2>&1)" && {
        echo "check-pr-intent --selftest: FAIL — accepted a verdict recorded for a DIFFERENT head" >&2
        return 1
    }
    case "$out" in
        *"STALE review verdict"*) ;;
        *) echo "check-pr-intent --selftest: FAIL — stale-head verdict rejected for the wrong reason:" >&2
           printf '%s\n' "$out" | sed 's/^/    /' >&2
           return 1 ;;
    esac
    # Sync guard: identical copies pass, a drifted copy MUST be rejected with
    # the drift message. Uses the path override so the case is cwd-independent;
    # the "workflow" is a copy of this very script (the extractor is file-shape
    # agnostic), with the negative copy's regex perturbed.
    local tmpd
    tmpd="$(mktemp -d)" || { echo "check-pr-intent --selftest: FAIL — mktemp failed" >&2; return 1; }
    cp "${BASH_SOURCE[0]}" "$tmpd/same.yml"
    rc=0
    CHECK_PR_INTENT_WORKFLOW_PATH="$tmpd/same.yml" check_workflow_sync >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        rm -rf "$tmpd"
        echo "check-pr-intent --selftest: FAIL — sync check rejected an identical copy" >&2
        return 1
    fi
    # The drift token is `findings?` — a string that occurs ONLY inside the
    # verdict_re source lines, so the mutation provably lands in the extracted
    # region under ANY reading of sed semantics. (The first draft mutated
    # `adversarial-code-review`, which also works — `s///` without `g` replaces
    # the first occurrence per LINE, so the regex line was mutated too — but a
    # reviewer modelling `s///` as first-occurrence-per-FILE reads that as
    # mutating only an earlier comment; a regex-only token needs no model.)
    sed 's/findings?/findingsX?/' "$tmpd/same.yml" > "$tmpd/drift.yml"
    out="$(CHECK_PR_INTENT_WORKFLOW_PATH="$tmpd/drift.yml" check_workflow_sync 2>&1)" && {
        rm -rf "$tmpd"
        echo "check-pr-intent --selftest: FAIL — sync check passed a DRIFTED copy" >&2
        return 1
    }
    case "$out" in
        *"VERDICT REGEX DRIFT"*) ;;
        *) rm -rf "$tmpd"
           echo "check-pr-intent --selftest: FAIL — drifted copy rejected for the wrong reason:" >&2
           printf '%s\n' "$out" | sed 's/^/    /' >&2
           return 1 ;;
    esac
    # A drift in head_re MUST also be caught. The token `{7,40}` also appears in
    # this selftest's own sed script (the copy contains the whole file), but
    # `s///` without `g` replaces the first occurrence on EVERY matching line —
    # so the head_re source line is mutated no matter what else is; the
    # verdict_re lines contain no `{7,40}`, so the drift is head_re-only.
    sed 's/{7,40}/{7,41}/' "$tmpd/same.yml" > "$tmpd/drift-head.yml"
    out="$(CHECK_PR_INTENT_WORKFLOW_PATH="$tmpd/drift-head.yml" check_workflow_sync 2>&1)" && {
        rm -rf "$tmpd"
        echo "check-pr-intent --selftest: FAIL — sync check passed a head_re-only drift" >&2
        return 1
    }
    rm -rf "$tmpd"
    case "$out" in
        *"VERDICT REGEX DRIFT"*) ;;
        *) echo "check-pr-intent --selftest: FAIL — head_re-drifted copy rejected for the wrong reason:" >&2
           printf '%s\n' "$out" | sed 's/^/    /' >&2
           return 1 ;;
    esac
    run_selftest_independent || return 1
    echo "check-pr-intent --selftest: PASS"
}

# run_selftest_independent — the --independent-review mode. Each red case asserts
# the reason, so a python error or a broken regex cannot pass as a rejection.
run_selftest_independent() {
    local tmpd out rc body
    tmpd="$(mktemp -d)" || { echo "check-pr-intent --selftest: FAIL — mktemp failed" >&2; return 1; }
    printf '%s\n' "docs/README.md" "Source/Core/src/Foo.cpp" > "$tmpd/plain"
    printf '%s\n' "docs/README.md" "agents/scripts/core/merge-gates.sh" > "$tmpd/gate"
    printf '%s\n' "agent-layer" > "$tmpd/bump"
    body="## Intent"$'\n\n'"Fix it."$'\n\n'"adversarial-code-review: 0 findings (head=abc1234)"
    _ind_expect() { # <want: ok|reason-substring> <files> <body> <label>
        local want="$1" files="$2" b="$3" label="$4"
        rc=0
        out="$(PR_HEAD_SHA="${IND_HEAD:-}" PR_AUTHOR="${IND_AUTHOR:-}" _check_independent "$b" "$files" 2>&1)" || rc=$?
        if [ "$want" = ok ]; then
            [ "$rc" -eq 0 ] && return 0
            echo "check-pr-intent --selftest: FAIL — independent: $label was rejected:" >&2
        else
            [ "$rc" -ne 0 ] && case "$out" in *"$want"*) return 0 ;; esac
            echo "check-pr-intent --selftest: FAIL — independent: $label was not rejected for '$want':" >&2
        fi
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        return 1
    }
    local fail=0
    # Not required: nothing under the enforcement surface.
    _ind_expect ok "$tmpd/plain" "$body" "a diff outside the enforcement surface" || fail=1
    # Required and missing, for a gate script and for a bare layer-pointer bump.
    _ind_expect "MISSING independent review" "$tmpd/gate" "$body" "a gate-script diff with no line" || fail=1
    _ind_expect "MISSING independent review" "$tmpd/bump" "$body" "an agent-layer gitlink bump with no line" || fail=1
    # Recorded properly.
    _ind_expect ok "$tmpd/gate" "$body"$'\n'"independent-review: code-review agent run; 2 findings, both fixed (head=abc1234)" \
        "a named reviewer with findings and head" || fail=1
    _ind_expect ok "$tmpd/gate" "$body"$'\n'"- independent-review: the-unwilling-agentic-bunch#11 review; 0 findings (head=abc1234)" \
        "a bulleted line citing a layer PR's review" || fail=1
    # Self, an unfilled placeholder, no head, a stale head, a commented-out line.
    _ind_expect "names no independent reviewer" "$tmpd/gate" "$body"$'\n'"independent-review: self; 0 findings (head=abc1234)" \
        "a self-review" || fail=1
    _ind_expect "MISSING independent review" "$tmpd/gate" "$body"$'\n'"independent-review: <reviewer>; N findings, <disposition> (head=<sha>)" \
        "the unfilled template line" || fail=1
    _ind_expect "MISSING head=" "$tmpd/gate" "$body"$'\n'"independent-review: CodeRabbit; 1 finding, fixed" \
        "a line with no head binding" || fail=1
    IND_HEAD="deadbeef00112233445566778899aabbccddeeff" \
        _ind_expect "STALE independent review" "$tmpd/gate" "$body"$'\n'"independent-review: CodeRabbit; 1 finding, fixed (head=abc1234)" \
        "a line bound to another head" || fail=1
    _ind_expect "MISSING independent review" "$tmpd/gate" "$body"$'\n'"<!--"$'\n'"independent-review: CodeRabbit; 0 findings (head=abc1234)"$'\n'"-->" \
        "a line inside an HTML comment" || fail=1
    _ind_expect "MISSING independent review" "$tmpd/gate" "$body"$'\n'"<!--"$'\n'"independent-review: CodeRabbit; 0 findings (head=abc1234)" \
        "a line after an unclosed HTML comment (hidden when rendered)" || fail=1
    _ind_expect "MISSING independent review" "$tmpd/gate" "$body"$'\n'"\`\`\`"$'\n'"independent-review: CodeRabbit; 0 findings (head=abc1234)"$'\n'"\`\`\`" \
        "a line inside a fenced code block" || fail=1
    _ind_expect ok "$tmpd/gate" "## Intent"$'\r\n\r\n'"\`\`\`bash"$'\r\n'"foo"$'\r\n'"\`\`\`"$'\r\n\r\n'"independent-review: CodeRabbit; 0 findings (head=abc1234)"$'\r\n' \
        "a CRLF body with a closed code block before the line" || fail=1
    _ind_expect ok "$tmpd/gate" "$body"$'\n'"\`\`\`\`"$'\n'"foo"$'\n'"\`\`\`\`"$'\n'"independent-review: CodeRabbit; 0 findings (head=abc1234)" \
        "a four-backtick fence closed before the line" || fail=1
    _ind_expect "names no independent reviewer" "$tmpd/gate" "$body"$'\n'"independent-review: Myself.; 0 findings (head=abc1234)" \
        "a self-review spelled 'Myself.'" || fail=1
    IND_AUTHOR="octo-dev" \
        _ind_expect "names no independent reviewer" "$tmpd/gate" "$body"$'\n'"independent-review: @Octo-Dev; 0 findings (head=abc1234)" \
        "a review naming the PR author" || fail=1
    # An older line left above a re-recorded one does not turn the check red.
    IND_HEAD="deadbeef00112233445566778899aabbccddeeff" \
        _ind_expect ok "$tmpd/gate" "$body"$'\n'"independent-review: CodeRabbit; 1 finding (head=abc1234)"$'\n'"independent-review: CodeRabbit; 0 findings (head=deadbeef0011)" \
        "a stale line followed by a current one" || fail=1
    rm -rf "$tmpd"
    unset -f _ind_expect
    return "$fail"
}

# --check-workflow-sync — the machine check behind the KEEP IN SYNC comment.
# The pr-intent-lint CI job is deliberately checkout-free, so it cannot call
# this script and must carry a COPY of the verdict regex; nothing failed when
# the copies drifted (CodeRabbit, round six). This extracts the two regex
# source lines from BOTH files and compares them byte-for-byte. Wired into
# scripts/dev/test-docs.sh and the doc-anchors CI job (which does check out).
check_workflow_sync() {
    local wf="${CHECK_PR_INTENT_WORKFLOW_PATH:-.github/workflows/doc-validation.yml}"
    local self="${BASH_SOURCE[0]}"
    WF_PATH="$wf" SELF_PATH="$self" "$PY" - <<'PY'
import os, re, sys
def extract(path, label):
    try:
        text = open(path, encoding="utf-8").read()
    except OSError as e:
        print("check-pr-intent --check-workflow-sync: cannot read %s (%s)" % (path, e), file=sys.stderr)
        sys.exit(2)
    m = re.search(r"verdict_re = re\.compile\(\s*\n\s*r'([^\n]*)'\s*\n\s*r'([^\n]*)'\)", text)
    if not m:
        print("check-pr-intent --check-workflow-sync: no verdict_re definition found in %s (%s)" % (path, label), file=sys.stderr)
        sys.exit(2)
    h = re.search(r"head_re = re\.compile\(r'([^\n]*)'\)", text)
    if not h:
        print("check-pr-intent --check-workflow-sync: no head_re definition found in %s (%s)" % (path, label), file=sys.stderr)
        sys.exit(2)
    return m.group(1) + m.group(2) + "\n" + h.group(1)
mine = extract(os.environ["SELF_PATH"], "local mirror")
theirs = extract(os.environ["WF_PATH"], "CI copy")
if mine != theirs:
    print("check-pr-intent --check-workflow-sync: VERDICT REGEX DRIFT between the local mirror and the CI copy:", file=sys.stderr)
    print("  local: %s" % mine, file=sys.stderr)
    print("  CI:    %s" % theirs, file=sys.stderr)
    print("  A fix applied to one copy did not reach the other — apply it to both.", file=sys.stderr)
    sys.exit(1)
print("check-pr-intent --check-workflow-sync: OK — verdict regex identical in both copies.")
PY
}

case "${1:-}" in
    --selftest) run_selftest; exit $? ;;
    --check-workflow-sync) check_workflow_sync; exit $? ;;
    --independent-review)
        shift
        FILES=""
        case "${1:-}" in
            --changed-files) FILES="${2:-}"; shift; shift || true ;;
            --changed-files=*) FILES="${1#--changed-files=}"; shift ;;
        esac
        [ -n "$FILES" ] ||
            { echo "check-pr-intent: usage: --independent-review --changed-files <file> [<body-file>]" >&2; exit 2; }
        if [ -n "${1:-}" ]; then
            [ -f "$1" ] || { echo "check-pr-intent: no such file: $1" >&2; exit 2; }
            BODY="$(cat "$1")"
        else
            BODY="$(cat)"
        fi
        rc=0
        _check_independent "$BODY" "$FILES" || rc=$?
        exit "$rc"
        ;;
    --help | -h) sed -n '2,12p' "$0"; exit 0 ;;
    "") BODY="$(cat)" ;;
    *)
        [ -f "$1" ] || { echo "check-pr-intent: no such file: $1" >&2; exit 2; }
        BODY="$(cat "$1")"
        ;;
esac
_check "$BODY"
