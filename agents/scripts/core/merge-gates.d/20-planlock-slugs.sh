#!/usr/bin/env bash
# agents/scripts/core/merge-gates.d/20-planlock-slugs.sh
# ----------------------------------------------------------------------------
# The plan-lock per-slug disposition rule's pure helpers: parsing the Plan-lock
# gate's own lines into the colliding lock slugs, and checking each slug
# against the accepted plan-lock-disposition reasons.
#
# Side-effect-free (one integer default and function definitions, no gh, git
# or file access), so every merge actor sources the SAME parser and cap:
# merge-gates.sh (the poller, through its explicit load list), safe-admin-merge.sh
# (through merge-gates.sh) and all-checks-green.sh (directly, in CI). The
# gh-backed steps that feed these helpers (the re-check, the annotation read)
# stay with their callers.
# ----------------------------------------------------------------------------

# MERGE_GATES_ANNOTATION_CAP — GitHub keeps at most this many error
# annotations per job step (10). A Plan-lock gate run showing that many of its
# own lines may have lost the rest, so its slug list is not trusted as complete.
MERGE_GATES_ANNOTATION_CAP="${MERGE_GATES_ANNOTATION_CAP:-10}"
case "$MERGE_GATES_ANNOTATION_CAP" in ''|*[!0-9]*|0) MERGE_GATES_ANNOTATION_CAP=10 ;; esac

# _mg_planlock_slug_ok <slug> — rc 0 when <slug> has the lock-claim.sh grammar
# ([a-z0-9][a-z0-9-]{0,63}); spelled out letter by letter, so no locale can
# widen the class.
_mg_planlock_slug_ok() {
    case "$1" in
        ''|-*|*[!abcdefghijklmnopqrstuvwxyz0123456789-]*) return 1 ;;
    esac
    [ "${#1}" -le 64 ]
}

# _mg_planlock_gate_slugs <recheck|annotations> — read Plan-lock gate output
# lines on stdin (::error lines from the re-run decision, or annotation
# messages) and print "<state> [<slug> …]" with the colliding slugs, sorted
# and de-duplicated. Only the gate's own lines count (they carry
# `plan-lock-gate:`). A collision line is recognised by its LAST
# "overlaps the write set of plan-lock '" phrase followed by a slug in the
# lock grammar and "', held by a different branch." — the template text after
# the slug never repeats the phrase, so a changed-file path that spells it out
# cannot substitute its own slug. Any line that looks like both a collision
# and an undetermined-table line, or carries the phrase without a well-formed
# slug, is ambiguous and makes the result "ambiguous" (fail closed: callers
# never resolve it from another source). States:
#   recheck:     complete | partial (an undetermined / unrecognised gate line:
#                that file has no verdict, so the list may be short)
#                | ambiguous
#   annotations: complete (infrastructure lines carry no slug and are skipped)
#                | ambiguous | unknown (no gate line, or as many gate lines as
#                GitHub keeps per step: the list may be truncated)
_mg_planlock_gate_slugs() {
    local mode="$1" line rest slug state=complete n=0
    local phrase="overlaps the write set of plan-lock '"
    local -a slugs=()
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in *"plan-lock-gate:"*) ;; *) continue ;; esac
        n=$((n + 1))
        if [[ "$line" == *"$phrase"* ]]; then
            rest="${line##*"$phrase"}"
            slug="${rest%%\'*}"
            if [[ "$line" == *"unverifiable lock state"* ]] || ! _mg_planlock_slug_ok "$slug" \
                || [[ "$rest" != "${slug}', held by a different branch."* ]]; then
                printf 'ambiguous (a Plan-lock gate line names no well-formed lock slug, or reads as both a collision and an undetermined lock state)\n'
                return 0
            fi
            slugs+=("$slug")
        elif [ "$mode" = recheck ]; then
            state=partial
        fi
    done
    if [ "$mode" = annotations ]; then
        if [ "$n" -eq 0 ]; then
            printf 'unknown (the red run carries no Plan-lock gate annotation)\n'
            return 0
        fi
        if [ "$n" -ge "$MERGE_GATES_ANNOTATION_CAP" ]; then
            printf 'unknown (%s Plan-lock gate annotations: GitHub keeps at most %s per step, so the list may be truncated)\n' \
                "$n" "$MERGE_GATES_ANNOTATION_CAP"
            return 0
        fi
    fi
    if [ "${#slugs[@]}" -gt 0 ]; then
        printf '%s %s\n' "$state" "$(printf '%s\n' "${slugs[@]}" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')"
    else
        printf '%s\n' "$state"
    fi
}

# _mg_planlock_unnamed_slugs <reasons> <slug> … — print (space-separated) each
# slug that no plan-lock-disposition reason names. A reason names a slug when
# the slug appears in it as a whole word: lower-cased, with every character
# outside the slug alphabet treated as a separator, so `docs-index` is named by
# "docs-index: coordinated" or "(docs-index)" but not by "docs-index-v2".
_mg_planlock_unnamed_slugs() {
    local norm slug out=""
    norm=" $(printf '%s' "$1" | LC_ALL=C tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz' \
        | LC_ALL=C tr -c 'abcdefghijklmnopqrstuvwxyz0123456789-' ' ') "
    shift
    for slug in "$@"; do
        case "$norm" in
            *" ${slug} "*) ;;
            *) out="${out:+$out }$slug" ;;
        esac
    done
    printf '%s' "$out"
}

# _mg_planlock_slug_report <slug set> <reasons> — the per-slug disposition
# rule: return 0 (print the BLOCK line on stderr) when the plan-lock-out-of-band
# waiver must be REFUSED, 1 when it stands. Refused when the slug set is
# unknown (fail closed: a waiver that cannot say which locks it crosses is not
# a recorded decision) or when any colliding slug is named by no disposition.
# A complete, empty set (nothing collides now, or an infrastructure-only red)
# needs no slug: the disposition the filter already required stands.
_mg_planlock_slug_report() {
    local set="$1" reasons="$2" missing
    case "$set" in
        complete) return 1 ;;
        "complete "*)
            # shellcheck disable=SC2086  # word-split the slug list (grammar: no glob or space)
            missing="$(_mg_planlock_unnamed_slugs "$reasons" ${set#complete })"
            [ -n "$missing" ] || return 1
            echo "BLOCK: Plan-lock gate: plan-lock-out-of-band refused — no plan-lock-disposition names the colliding lock slug(s): ${missing}. Each slug the gate reports needs its own disposition: a 'plan-lock-disposition:<slug>' label or a PR-body line 'plan-lock-disposition: <slug> — <why crossing it is safe>' (colliding now: ${set#complete })." >&2
            return 0 ;;
    esac
    echo "BLOCK: Plan-lock gate: plan-lock-out-of-band refused — the lock slug(s) this red collides with could not be determined ${set#unknown }, so no disposition can be checked against them (fail closed). Restore the lock-table read (a checkout with a remote for the base repository) or re-run the gate, then re-poll." >&2
    return 0
}

