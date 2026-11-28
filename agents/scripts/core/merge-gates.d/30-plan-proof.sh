#!/usr/bin/env bash
# agents/scripts/core/merge-gates.d/30-plan-proof.sh
# ----------------------------------------------------------------------------
# The plan CI-proof gate's pure helpers: which changed files are plan docs,
# which lines a PR patch adds, and which CI checks a plan's `## Verification`
# names as its proof "on this PR".
#
# Why the gate exists: a plan can name a CI check as the proof for its change
# (`- CI: "Sanitizer (UBSan via Clang)" green on this PR`). A delta-gated check
# that skips on that PR concludes SKIPPED, and SKIPPED is a pass to branch
# protection and to the CI gate, so the proof the plan asked for never ran and
# the PR merges green. The host's pre-push check predicts the skip; this gate
# reads the outcome on the head, at merge time.
#
# Side-effect-free (function definitions only: no gh, git or file access
# beyond reading the file a caller names), so the parsing is testable without
# a network. The gh-backed steps that feed these helpers (the PR file list, the
# head copy of a plan, the check-run lookup) stay with the caller,
# merge-gates.sh's _mg_plan_proof_verdict.
#
# Scope rule, kept identical to the host's pre-push check: only proof lines the
# PR ADDS count. "This PR" means the PR that wrote the line, so a later docs-only
# edit of a plan, or its move to shipped/, does not inherit the original PR's
# proof. A plan file the API sends no patch for (too large) is read whole.
# ----------------------------------------------------------------------------

# _mg_planproof_is_plan <path> — rc 0 when <path> is a plan doc this gate reads
# (docs/plans/active/*.md or docs/plans/shipped/*.md, one level deep). A basename
# starting with `_` is a meta-file, not a plan (_plan-template.md carries a real
# `## Verification` heading; _plan-locks*.md are bot-rendered), so it is skipped:
# an example check name added to the template must not read as a proof.
_mg_planproof_is_plan() {
    case "$1" in
        docs/plans/active/*/*|docs/plans/shipped/*/*) return 1 ;;
        docs/plans/active/_*|docs/plans/shipped/_*) return 1 ;;
        docs/plans/active/*.md|docs/plans/shipped/*.md) return 0 ;;
    esac
    return 1
}

# _mg_planproof_uri_path <path> — percent-encode <path> for a URL path, byte by
# byte, leaving the unreserved set and `/` as they are.
_mg_planproof_uri_path() {
    local LC_ALL=C s="$1" out="" c i
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [A-Za-z0-9._~/-]) out+="$c" ;;
            *) out+="$(printf '%%%02X' "'$c")" ;;
        esac
    done
    printf '%s' "$out"
}

# _mg_planproof_added_lines — read one file's unified-diff patch (the `patch`
# field GitHub's pulls/<n>/files returns: hunks only, no file header) on stdin
# and print the head-side line numbers of its added lines, space-separated, with
# a leading and trailing space (" 3 7 8 ") so a caller can match " <n> ".
# Prints " " for a patch with no added line.
_mg_planproof_added_lines() {
    awk '
        /^@@ / {
            n = $3; sub(/^\+/, "", n); split(n, p, ",")
            line = p[1] + 0
            next
        }
        /^\+/ { out = out " " line; line++; next }
        /^ /  { line++; next }
        /^-/  { next }
        END { print out " " }
    '
}

# _mg_planproof_checks <plan-file> <added-lines|all> — print each check name the
# plan's `## Verification` section names as proof on the PR, one per line,
# keeping only lines whose number is in <added-lines> (the
# _mg_planproof_added_lines format); "all" keeps every line. Only the exact
# `## Verification` heading opens the section (`## Verification (actual)`
# records what happened, not what is asked). A proof reads
# `CI: "<check>" green on this PR` (or `the PR`); the name may sit in backticks
# instead of quotes, and one line may carry several. Lines inside a fenced code
# block (``` or ~~~, closed by the same marker) are neither headings nor proofs, so a `## …` line in an
# example cannot close the section early, and a quoted grammar example is not a
# proof. A name with a `<placeholder>` shape is a template, never a check.
# shellcheck disable=SC2016  # awk / sed programs; the backticks are literal
_mg_planproof_checks() {
    local file="$1" added="$2"
    [ "$added" = all ] || added=" ${added# } "
    # A fence closes only on the marker that opened it (same character, at least
    # as long). A fence that never closes would hide the rest of the file, so in
    # that case fences are ignored altogether: over-reading only adds proofs to
    # check, under-reading lets one through unchecked.
    local fences=1
    awk '
        match($0, /^[[:space:]]*(```+|~~~+)/) {
            m = substr($0, RSTART, RLENGTH); sub(/^[[:space:]]*/, "", m)
            if (open == "") open = m
            else if (substr(m, 1, 1) == substr(open, 1, 1) && length(m) >= length(open)) open = ""
        }
        END { exit open == "" ? 0 : 1 }
    ' "$file" || fences=0
    awk -v added="$added" -v fences="$fences" '
        fences && match($0, /^[[:space:]]*(```+|~~~+)/) {
            m = substr($0, RSTART, RLENGTH); sub(/^[[:space:]]*/, "", m)
            if (open == "") open = m
            else if (substr(m, 1, 1) == substr(open, 1, 1) && length(m) >= length(open)) open = ""
            next
        }
        open != "" { next }
        /^## / { in_v = ($0 ~ /^## Verification[[:space:]]*$/); next }
        in_v && (added == "all" || index(added, " " NR " ")) { print }
    ' "$file" \
        | grep -oE 'CI:[[:space:]]*["`][^"`]+["`][[:space:]]+green on (this|the) PR' \
        | sed -E 's/^CI:[[:space:]]*["`]([^"`]+)["`].*/\1/' \
        | grep -vE '^<[^>]*>$' || true
}

# _mg_planproof_conclusion_skipped <conclusion> — rc 0 when a check-run
# conclusion means the proof did not run: SKIPPED, or the check never reported
# on the head at all (an empty conclusion from a lookup that found no run). A
# check that is still running is NOT skipped (the CI gate already holds the
# merge for it).
_mg_planproof_conclusion_skipped() {
    case "$1" in
        skipped|SKIPPED|absent) return 0 ;;
    esac
    return 1
}
