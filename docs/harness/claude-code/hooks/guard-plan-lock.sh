#!/usr/bin/env bash
# guard-plan-lock.sh — PreToolUse(Edit|Write|MultiEdit|NotebookEdit) plan-lock
# guard (Layer A of the 3-layer force-on-contention enforcement).
#
# A write set must be claimed before edits IFF another session is concurrently
# live (force-on-contention). Solo / sequential work — the common case — is never
# touched; it pays at most one cross-edit-cached liveness probe per edit.
#
# Decision under contention (>=1 other live session), for the edited path:
#   - covered by a refs/locks/* claim whose `branch` == the session's own
#     checkout's HEAD branch (the checkout comes from the payload's `cwd`) -> allow.
#   - covered by ANOTHER branch's claim -> DENY. That is real contention; the hook
#     never takes, extends or overrides another branch's lock.
#   - covered by no claim -> AUTO-CLAIM and allow, with a note the model sees:
#       * this branch already holds a lock -> lock-claim-update.sh grows it to
#         its current write set (read fresh from the lock ref's claim.json, never
#         shrunk) plus this path, keeping its owner, plan and notes;
#       * otherwise -> lock-claim.sh files a new lock under a deterministic slug
#         derived from the branch (auto-<sanitised branch>-<crc32 hex>).
#     Never auto-claimed, denied with the lock-claim.sh remediation instead: an
#     integration branch (develop, main), whose lock would read as a collision to
#     every feature push, and a path the one-per-line write-set file cannot carry.
#     An extend is pinned to the lock commit it read the set from
#     (LOCK_EXPECT_SHA): a concurrent extension by another session of this branch
#     makes it re-read and try once more, and a second lost lease fails open
#     without writing, so a path someone else added is never dropped.
#     After a successful claim or extend, a fresh (uncached) re-read checks
#     whether ANOTHER branch covers the path, a claim the cached table had not
#     seen yet: if so the hook rolls its own claim back best-effort (releases the
#     new lock, or restores the extended lock's previous set, each under a lease
#     pinned to the commit its claim wrote) and DENIES, saying whether the
#     rollback completed. This, not the claim's exit 1, is the cross-branch race
#     guard: auto slugs are per branch. The re-read fetches strictly: a failed
#     fetch is "could not run", never a read of stale local refs. A rollback
#     that did not complete is recorded on this machine (lock-table-cache.sh
#     ltc_unresolved_*), and later edits of the path stay DENIED while the
#     lock it names still covers the path for this branch and the other
#     branch's lock does too. An overlap the hook did not make
#     (a hand claim, or another branch claiming over this one later) passes.
#     The new slug already held (exit 1, normally this branch seen through a
#     stale cache) -> fresh re-read: another branch covers -> DENY; this branch
#     covers -> allow; else allow with a warning. Any other failure (exit 2/3/4,
#     network, budget) -> FAIL OPEN: allow with a warning.
#     Bounded: each claim script makes one push attempt (LOCK_RETRY_MAX=1), and
#     every network step runs under timeout(1)/gtimeout inside one wall-clock
#     budget (SMATCHET_PLAN_LOCK_AUTOCLAIM_TIMEOUT, default 8 s) counted from the
#     hook's start, so a slow lock-table read leaves less for the claim. With neither
#     timeout(1) nor gtimeout, auto-claim does not run: the classic deny (fail
#     closed), never an unbounded network step.
#     Every claim, extend or rollback drops the cached lock table.
#     Lock lookups and claims run in the session's checkout, whose remote they use.
# The two gitignored review artifacts the commit/push gates require are never
# gated (they cannot reach another branch). Identity is keyed on BRANCH, never
# owner/AGENT_ID (unprovisioned in prod). Same-tree-same-branch contention is out
# of scope (the tree guards own that); plan-locks target cross-BRANCH parallel work.
#
# ADVISORY / FAIL-OPEN: any missing lib / network / parse / worktree-enum error,
# a detached HEAD, an unresolvable path, a failed auto-claim or a blown hook
# timeout -> allow. The one fail-closed case is a host without timeout(1) or
# gtimeout, which gets the deny auto-claim would otherwise have replaced. The authoritative nets are Layer B (every push) and Layer C
# (the CI gate). This hook runs alongside guard-head-drift.sh on the edit matcher;
# both ALWAYS run and a deny from either wins (array order is cosmetic) — the
# common-case cheapness comes only from this hook's own solo `exit 0`, never from
# a sibling hook short-circuiting.
#
# Output: plain allow = exit 0, no stdout. Deny = the PreToolUse
# permissionDecision JSON. Auto-claim note = systemMessage (the user) +
# hookSpecificOutput.additionalContext (the model) with NO permissionDecision, so
# the session's own permission mode still decides the edit; the hook never
# auto-approves an edit the user would have been asked about.
#
# Switches (session env, set BEFORE launch — an inline `VAR=0 <edit>` prefix
# does NOT reach a hook):
#   SMATCHET_REQUIRE_PLAN_LOCK=0    disable the hook entirely.
#   SMATCHET_PLAN_LOCK_AUTOCLAIM=0  no auto-claim: an uncovered contended edit is
#                                   denied with a lock-claim.sh remediation.
#   SMATCHET_PLAN_LOCK_AUTOCLAIM_TIMEOUT=<secs>  auto-claim budget (default 8, at least 2);
#                                   keep it under this hook's harness timeout
#                                   (30 s in settings.json.tmpl).
#
# See docs/plans/shipped/plan-lock-enforcement.md (Layer A) +
#     docs/agent-rules/process-rules.md § Concurrent interactive sessions.

set -u
# The hook's own start, for the auto-claim budget. Relative, so an inherited
# SECONDS (bash imports it from the environment) cannot shift it.
HOOK_T0=$SECONDS

# Override reaches the hook only via the session env (the hook reads its own env
# before the tool runs; an inline `SMATCHET_REQUIRE_PLAN_LOCK=0 <edit>` prefix
# does NOT work).
[ "${SMATCHET_REQUIRE_PLAN_LOCK:-1}" = "0" ] && exit 0

json_escape() { # backslash, double-quote and every control character (U+0001-U+001F, U+007F)
  local s="$1" out="" c i
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  case "$s" in
    *[[:cntrl:]]*)
      # Rare (a path carrying a raw control byte): escape byte by byte, so the
      # deny stays valid JSON the harness can act on.
      for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
          [[:cntrl:]]) out+="$(printf '\\u%04x' "'$c")" ;;
          *) out+="$c" ;;
        esac
      done
      s="$out"
      ;;
  esac
  printf '%s' "$s"
}

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$(json_escape "$1")"
  exit 0
}

# Allow with a note: systemMessage reaches the user, additionalContext the model.
# No permissionDecision, so the session's permission mode still decides the edit.
allow_note() {
  local m
  m="$(json_escape "$1")"
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}' "$m" "$m"
  exit 0
}

PROJ="${CLAUDE_PROJECT_DIR:-$(pwd)}"
INPUT="$(cat || true)"
[ -n "$INPUT" ] || exit 0

json_field() { # $1 = jq filter, $2 = sed key
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null
  else
    printf '%s' "$INPUT" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n1
  fi
}

FP="$(json_field '.tool_input.file_path' 'file_path')"
[ -n "$FP" ] || exit 0   # no edit target -> nothing to gate

# own session id: stdin-preferred, env fallback — the SAME effective precedence
# session-tree-banner.sh writes the registry basename with, so self-exclusion
# can't miss its own entry and gate solo work (the F2 fix). NEVER sr_session_pid
# (a ~300-500ms powershell ancestor walk this hot path must not pay).
SID="$(json_field '.session_id' 'session_id')"
[ -n "$SID" ] || SID="${CLAUDE_SESSION_ID:-}"

# Shared substrate lib — layer content. Resolve the layer from CLAUDE_PROJECT_DIR
# (layer-root.sh, copied beside this hook: the agent-layer/ mount once the layer is
# a submodule), then the git top-level of the hook's own location (the in-repo
# source path the bats run). Missing lib -> fail OPEN.
HOOK_LAYER="$PROJ"
# shellcheck source=docs/harness/claude-code/hooks/layer-root.sh
. "${BASH_SOURCE[0]%/*}/layer-root.sh" 2>/dev/null && hook_layer_root "$PROJ"
_ltc_lib="$HOOK_LAYER/agents/scripts/core/lock-table-cache.sh"
if [ ! -f "$_ltc_lib" ]; then
  _top="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$_top" ] && _ltc_lib="$_top/agents/scripts/core/lock-table-cache.sh"
fi
[ -f "$_ltc_lib" ] || exit 0
export LTC_PROJ="$PROJ"
# shellcheck source=agents/scripts/core/lock-table-cache.sh
. "$_ltc_lib"

# Force-on-contention: 0 live siblings -> never block (no tax on solo BLOCKING).
# Count is repo-global + cross-edit-cached; fail-open to 0 on any error.
count="$(ltc_sibling_count "$SID")"
case "$count" in ''|*[!0-9]*) exit 0 ;; esac
# >=1 sibling == >=2 agents total == contended (own is already excluded; the
# off-by-one trap is that "excluding self" pairs with a threshold of >=1, not 2).
[ "$count" -ge 1 ] || exit 0

# Claude Code sets CLAUDE_PROJECT_DIR to the main tree even for a session working
# in a linked worktree (e.g. <project>/.claude/worktrees/<id>/). Keying both the
# branch and the path on it named the main tree's branch and a
# ".claude/worktrees/<id>/..." path, which no lock can cover, so every contended
# worktree edit was denied. Two checkouts matter instead, each resolved to a
# worktree only when it shares this repo's git common dir (a submodule, an
# unrelated repo or an unresolvable dir keeps the project dir):
#   CHECKOUT    — owns the edited file; the lock path is relative to it.
#   SESSION_CO  — the session's own checkout, from the payload's `cwd`; its branch
#                 is the identity. Keying identity on the FILE's checkout would let
#                 a session edit a sibling worktree's file under the sibling's lock.
#                 A payload without `cwd` falls back to CHECKOUT.
# Normalize separators so a Windows backslash path strips cleanly.
FP_N="${FP//\\//}"
common_dir() { # $1 = dir in a checkout -> canonical git common dir (empty on error)
  local d
  d="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 0
  (cd "$1" && cd "$d" 2>/dev/null && pwd -P)
}
PROJ_COMMON="$(common_dir "${PROJ//\\//}")"
sibling_checkout() { # $1 = path (file or dir) -> its worktree top if it shares this repo, else empty
  local d top c
  d="${1//\\//}"
  while [ -n "$d" ] && [ ! -d "$d" ]; do
    [ "${d%/*}" = "$d" ] && return 0
    d="${d%/*}"
  done
  [ -n "$d" ] || return 0
  top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || return 0
  [ -n "$top" ] || return 0
  c="$(common_dir "$top")"
  # -ef compares directory identity, so drive-letter case / separator spelling
  # differences between the two paths cannot break the match.
  [ -n "$c" ] && [ -n "$PROJ_COMMON" ] && [ "$c" -ef "$PROJ_COMMON" ] && printf '%s' "$top"
}
CHECKOUT="$(sibling_checkout "${FP_N%/*}")"
[ -n "$CHECKOUT" ] || CHECKOUT="$PROJ"
SCWD="$(json_field '.cwd' 'cwd')"
if [ -n "$SCWD" ]; then
  SESSION_CO="$(sibling_checkout "$SCWD")"
  [ -n "$SESSION_CO" ] || SESSION_CO="$PROJ"
else
  SESSION_CO="$CHECKOUT"
fi

# Discriminator is the session checkout's HEAD branch (my own seed lock). Detached /
# unresolvable -> fail-open allow (an unattributable session can't be keyed).
mybr="$(git -C "$SESSION_CO" symbolic-ref --short HEAD 2>/dev/null)" || exit 0
[ -n "$mybr" ] || exit 0

# Resolve the edited path to checkout-relative; an edit OUTSIDE this repo is not
# ours to gate.
PROJ_TOP="$(git -C "$CHECKOUT" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$PROJ_TOP" ] || exit 0
TOP_N="${PROJ_TOP//\\//}"
case "$FP_N" in
  "$TOP_N"/*) rel="${FP_N#"$TOP_N"/}" ;;
  *) exit 0 ;;
esac
[ -n "$rel" ] || exit 0

# The review artifacts the commit/push gates require (.review-findings.json,
# .review-ack at the checkout root) are per-checkout scratch, gitignored and never
# committed, so no other branch can collide on them; gating them blocked the very
# writes the gates demand. The exemption is an allowlist of exactly those two
# paths, and only while the write lands on that untracked file itself:
#   - ignored in the checkout that owns it (check-ignore also skips tracked files);
#   - no index entry under ANY letter case (a case-insensitive filesystem would
#     otherwise let ".Review-Ack" in the index be written through ".review-ack");
#   - not a symlink, and no second hardlink (either could point at a tracked
#     file, as the .claude/ adapter's links do).
# Anything else ignored (build/ scratch, a loosely matched fixture) can still be
# force-added and committed, so it stays gated.
review_artifact_exempt() { # $1 = checkout-relative path, $2 = checkout top, $3 = absolute path
  local links
  case "$1" in
    .review-findings.json|.review-ack) ;;
    *) return 1 ;;
  esac
  git -C "$2" check-ignore -q -- "$1" 2>/dev/null || return 1
  [ -z "$(git -C "$2" ls-files -- ":(icase)$1" 2>/dev/null)" ] || return 1
  [ -L "$3" ] && return 1
  if [ -e "$3" ]; then
    [ -f "$3" ] || return 1
    links="$(stat -c %h -- "$3" 2>/dev/null || stat -f %l -- "$3" 2>/dev/null)"
    [ "$links" = "1" ] || return 1
  fi
  return 0
}
review_artifact_exempt "$rel" "$PROJ_TOP" "$FP_N" && exit 0


# locks-show.sh and the lock-claim scripts resolve the remote from the current
# directory, so every lock lookup and claim below runs in the session's checkout.
cd "$SESSION_CO" 2>/dev/null || :

deny_uncovered() { # $1 = optional sentence appended to the remediation
  deny "Plan-lock: ${count} other live session(s) share this repo and you hold no plan-lock covering '${rel}' on branch '${mybr}'.${1:-} Claim one before editing — write the paths you will touch (one per line, repo-relative) to a file, then run: LOCK_PLAN=<your plan-doc> bash agents/scripts/core/lock-claim.sh <slug> <that-file>. Already hold a lock for this work but missed a file? Grow it: bash agents/scripts/core/lock-claim-update.sh <slug> <full-write-set-file> (it REPLACES the set, so list every path). Override: export SMATCHET_REQUIRE_PLAN_LOCK=0 in the session env BEFORE launch (an inline prefix does NOT reach this hook)."
}
deny_other() { # $1 = the other branch's slug, $2 = optional sentence on this hook's own just-made claim
  local what="you hold no plan-lock covering '${rel}' on branch '${mybr}': another branch's plan-lock '${1}' claims it."
  [ -z "${2:-}" ] || what="another branch's plan-lock '${1}' claims '${rel}', which this hook had just claimed for branch '${mybr}' too.${2}"
  deny "Plan-lock: ${count} other live session(s) share this repo and ${what} Auto-claim never takes or overrides another branch's lock. See who holds it (bash agents/scripts/core/locks-show.sh), then coordinate with that branch or wait for its release. Override: export SMATCHET_REQUIRE_PLAN_LOCK=0 in the session env BEFORE launch (an inline prefix does NOT reach this hook)."
}

# auto-<branch lowercased, non-[a-z0-9] runs -> '-', <= 48 chars>-<crc32 of the
# raw branch, 8 hex>: at most 62 chars, matches lock-claim.sh's slug grammar, and
# the checksum keeps branches that sanitise alike (feat/x, feat-x) apart.
autoclaim_slug() { # $1 = branch
  local s crc
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | tr -s '-')"
  s="${s#-}"
  s="${s:0:48}"
  s="${s%-}"
  crc="$(printf '%s' "$1" | cksum 2>/dev/null | awk '{print $1}')"
  case "$crc" in ''|*[!0-9]*) crc=0 ;; esac
  printf 'auto-%s%s%08x' "$s" "${s:+-}" "$crc"
}
SLUG_RE='^[a-z0-9][a-z0-9-]{0,63}$'
aslug="$(autoclaim_slug "$mybr")"

deny_overlap() { # $1 = the other branch's slug, $2 = this branch's lock the hook claimed the path into
  deny "Plan-lock: ${count} other live session(s) share this repo and another branch's plan-lock '${1}' claims '${rel}', which your plan-lock '${2}' also covers: this edit hook claimed '${rel}' into '${2}', lost the race to that branch, and could not roll the claim back. Drop '${rel}' from '${2}' (bash agents/scripts/core/lock-claim-update.sh ${2} <full-write-set-file>, listing every other path; or bash agents/scripts/core/lock-release.sh ${2} if it holds nothing else), then coordinate with that branch (bash agents/scripts/core/locks-show.sh). Override: export SMATCHET_REQUIRE_PLAN_LOCK=0 in the session env BEFORE launch (an inline prefix does NOT reach this hook)."
}

# Allow iff covered by a lock whose branch == mine. rc: 0 covered, 1 not, 2
# undetermined (table unavailable -> fail-open allow). One exception: a path
# this hook claimed into this branch's lock, lost to another branch's claim and
# could not roll back (crosscheck_after_claim records it) stays denied while
# that other lock still covers it, rather than a retried edit passing silently.
# Any other overlap passes, as before: a lock claimed by hand over another
# branch's is a deliberate, coordinated claim, and a later claim by another
# branch over this branch's earlier one is that branch's to resolve (Layers B
# and C flag both).
ltc_covering_slug "$rel" same "$mybr" >/dev/null; cov=$?
case "$cov" in
  0)
    if uslug="$(ltc_unresolved_slug "$mybr" "$rel")"; then
      # The record holds only while the lock it names still covers the path for
      # this branch (not released, the path not dropped, the branch not reused)
      # AND another branch's lock covers it too. Either one gone: resolved.
      ltc_covering_slug "$rel" same-slug "$mybr" "" "$uslug" >/dev/null; ucov=$?
      if [ "$ucov" -eq 0 ]; then
        oslug="$(ltc_covering_slug "$rel" other "$mybr")"; ocov=$?
        case "$ocov" in
          0) deny_overlap "$oslug" "$uslug" ;;
          1) ltc_unresolved_drop "$mybr" "$rel" ;;
        esac
      elif [ "$ucov" -eq 1 ]; then
        ltc_unresolved_drop "$mybr" "$rel"
      fi
    fi
    exit 0
    ;;
  2) exit 0 ;;
esac
# This branch no longer covers the path: any unresolved-rollback record for it is stale.
ltc_unresolved_drop "$mybr" "$rel"

# Another branch's claim covering the path is real contention: always deny.
oslug="$(ltc_covering_slug "$rel" other "$mybr")"; ocov=$?
case "$ocov" in
  0) deny_other "$oslug" ;;
  2) exit 0 ;;
esac

[ "${SMATCHET_PLAN_LOCK_AUTOCLAIM:-1}" = "0" ] && deny_uncovered
# A lock owned by an integration branch reads as a collision to every feature
# branch's pre-push stop (lock-claim.sh warns for the same reason): never auto-claim one.
case "$mybr" in
  develop|main) deny_uncovered ;;
esac

# The write-set file carries one path per line, stripped, with blank and '#'
# lines skipped: a path that format cannot carry verbatim is never auto-claimed.
case "$rel" in
  *[[:cntrl:]]*|'#'*|[[:space:]]*|*[[:space:]]) deny_uncovered ;;
esac

# Every auto-claim network step runs under timeout(1), or gtimeout (macOS with
# coreutils), so one wall-clock budget bounds the edit. With neither, auto-claim
# never runs and the edit gets the classic deny: FAIL CLOSED to the behaviour
# without auto-claim, never an unbounded network step on the edit path. The probe
# asks for --version, so Windows timeout.exe (a wait, not a limiter) and a limiter
# without GNU options both read as absent.
AC_TIMEOUT=""
for _t in timeout gtimeout; do
  if "$_t" --version >/dev/null 2>&1; then
    AC_TIMEOUT="$_t"
    break
  fi
done
[ -n "$AC_TIMEOUT" ] || deny_uncovered " Auto-claim did not run: it needs timeout(1) or gtimeout (GNU coreutils) to bound its network steps."

# ---------------------------------------------------------------------------
# Auto-claim. Every outcome below allows the edit, except another branch's claim
# on the path seen by the fresh re-read after this hook's own claim, which
# denies. A failure fails OPEN with a warning (Layers B and C decide).
# ---------------------------------------------------------------------------
fail_open() { # $1 = what failed
  allow_note "Plan-lock: ${count} other live session(s) share this repo and no plan-lock covers '${rel}' on branch '${mybr}'. Auto-claim failed (${1}), so this edit is allowed fail-open; the pre-push (Layer B) and CI (Layer C) gates still check overlap. Claim it yourself: write the paths you will touch to a file, then run LOCK_PLAN=<your plan-doc> bash agents/scripts/core/lock-claim.sh <slug> <that-file>, or grow a lock you hold with bash agents/scripts/core/lock-claim-update.sh <slug> <full-write-set-file>."
}
last_line() { # $1 = script output -> its last non-empty line, CR-free, <= 160 chars
  local l
  l="$(printf '%s\n' "$1" | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -n 1)"
  printf '%s' "${l:0:160}"
}

_claim="$_LTC_DIR/lock-claim.sh"
_update="$_LTC_DIR/lock-claim-update.sh"
_release="$_LTC_DIR/lock-release.sh"
{ [ -n "$_LTC_DIR" ] && [ -f "$_claim" ] && [ -f "$_update" ] && [ -f "$_release" ]; } ||
  fail_open "lock scripts not found beside lock-table-cache.sh"

# One wall-clock budget shared by every network step of this edit: the claim,
# the fresh cross-branch re-read and any rollback. Each claim script makes one
# push attempt (LOCK_RETRY_MAX=1); an extend whose pinned lease went stale re-reads
# and tries once more. Keep the budget under the harness's hook timeout for this
# hook (settings.json.tmpl), or a slow claim is killed without its warning note.
AC_BUDGET="${SMATCHET_PLAN_LOCK_AUTOCLAIM_TIMEOUT:-8}"
case "$AC_BUDGET" in ''|*[!0-9]*) AC_BUDGET=8 ;; esac
AC_BUDGET=$((10#$AC_BUDGET)) # a leading 0 is not octal
[ "$AC_BUDGET" -gt 0 ] || AC_BUDGET=8
# $SECONDS has whole-second resolution and can tick 1 well before a second has
# passed, so a budget under 2 s could read as spent at once: 2 s is the floor.
[ "$AC_BUDGET" -ge 2 ] || AC_BUDGET=2
# The budget runs from the hook's start (HOOK_T0), so the lock-table reads
# above, which a cold cache runs without a limiter, count against it too: a
# slow read leaves less for the claim, never more.
AC_START=$HOOK_T0
[ $((AC_BUDGET - (SECONDS - AC_START))) -gt 0 ] ||
  fail_open "the lock-table read took the whole ${AC_BUDGET} s auto-claim budget"
run_bounded() { # run "$@" in what is left of the budget; 124 once it is spent
  local left=$((AC_BUDGET - (SECONDS - AC_START)))
  [ "$left" -gt 0 ] || return 124
  GIT_TERMINAL_PROMPT=0 "$AC_TIMEOUT" "$left" "$@" </dev/null
}

# A claim, extension or rollback must be visible to the next edit: drop the
# cached table.
drop_table_cache() {
  command -v ltc_invalidate_table >/dev/null 2>&1 && ltc_invalidate_table
  return 0
}


# The lock this branch extends: its auto-claim lock when it holds one, else its
# most recently active lock (ties -> lowest slug). None -> claim a new one.
own=""
if command -v ltc_lock_rows >/dev/null 2>&1; then
  own="$(ltc_lock_rows 2>/dev/null | tr -d '\r' | awk -F '\t' -v br="$mybr" -v auto="$aslug" '
    $1 == br && $3 != "" {
      if ($3 == auto) found = 1
      e = ($2 ~ /^[0-9]+$/) ? $2 + 0 : -1
      if (best == "" || e > be || (e == be && $3 < best)) { best = $3; be = e }
    }
    END { if (found) print auto; else if (best != "") print best }')"
fi
[ -z "$own" ] || [[ "$own" =~ $SLUG_RE ]] || fail_open "this branch's plan-lock slug '${own}' is malformed"

ws="$(mktemp "${TMPDIR:-/tmp}/plan-lock-ws.XXXXXX" 2>/dev/null)" || fail_open "could not create a write-set file"
ws_prev="$ws.prev"
trap 'rm -f -- "$ws" "$ws_prev"' EXIT
remote="${LOCK_REMOTE:-origin}"
pybin="python3"
command -v _ltc_pybin >/dev/null 2>&1 && pybin="$(_ltc_pybin)"

# Fresh (uncached) read, inside the budget, of whether ANOTHER branch's lock
# covers the path; prints that lock's slug. rc 0 covered, 1 not, anything else
# undetermined (table unavailable, a failed refs/locks fetch, or 124 once the
# budget is spent). LOCKS_SHOW_STRICT_FETCH makes a failed fetch an error rather
# than a read of the stale local refs, so "not covered" always means the remote
# was read. It also rewrites the cached table the next edit reads.
other_cover_fresh() {
  # shellcheck disable=SC2016 # expanded by the child shell
  run_bounded bash -c '. "$1" && LOCKS_SHOW_STRICT_FETCH=1 LTC_TABLE_TTL=0 ltc_covering_slug "$2" other "$3"' \
    _ "$_ltc_lib" "$rel" "$mybr" 2>/dev/null
}

# Why a rollback did not complete, from its exit code and output.
rollback_failure() { # $1 = rc, $2 = script name, $3 = output
  if [ "$1" -eq 124 ]; then
    printf 'the auto-claim budget ran out'
  else
    printf '%s exit %s: %s' "$2" "$1" "$(last_line "$3")"
  fi
}

# Undo a just-filed new lock: release it, pinned to the commit this hook's claim
# wrote, so an extension another session of this branch made since is never
# released with it. Prints one sentence for the deny.
rollback_new() {
  local out rc
  if [ -z "$claim_sha" ]; then
    rc=2
    out="the new lock's commit is unknown"
  else
    out="$(LOCK_REMOTE="$remote" LOCK_RETRY_MAX=1 LOCK_EXPECT_SHA="$claim_sha" run_bounded bash "$_release" "$aslug" 2>&1)"; rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    printf " Its auto-claim '%s' is released again." "$aslug"
    return 0
  fi
  printf " Rolling back its auto-claim '%s' did not complete (%s): release it with bash agents/scripts/core/lock-release.sh %s. Until then this hook keeps denying edits of '%s'." \
    "$aslug" "$(rollback_failure "$rc" lock-release.sh "$out")" "$aslug" "$rel"
  return 1
}

# Undo a just-made extension: restore the previous write set, pinned to the
# commit the extension wrote so a later update is never overwritten.
rollback_extend() {
  local out rc
  if [ -z "$new_sha" ]; then
    rc=2
    out="the extended lock's commit is unknown"
  else
    out="$(AGENT_ID="${c_owner:-${AGENT_ID:-orchestrator}}" LOCK_BRANCH="$mybr" LOCK_PLAN="$c_plan" LOCK_NOTES="$c_notes" \
      LOCK_REMOTE="$remote" LOCK_RETRY_MAX=1 LOCK_EXPECT_SHA="$new_sha" run_bounded bash "$_update" "$own" "$ws_prev" 2>&1)"; rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    printf " Your plan-lock '%s' is restored to its previous write set." "$own"
    return 0
  fi
  printf " Restoring your plan-lock '%s' to its previous write set did not complete (%s): drop '%s' from it with bash agents/scripts/core/lock-claim-update.sh %s <full-write-set-file>. Until then this hook keeps denying edits of '%s'." \
    "$own" "$(rollback_failure "$rc" lock-claim-update.sh "$out")" "$rel" "$own" "$rel"
  return 1
}

# Another branch can claim the path between this hook's cached read and its own
# claim: the cache lives up to LTC_TABLE_TTL, and a claim made from another clone
# never drops this machine's copy. So once this hook's claim lands, it re-reads
# the table fresh. Of two branches racing for one path, the later claimer's
# re-read sees the earlier claim, so at most one keeps editing (both may deny,
# which is safe). Another branch covers the path -> roll back best-effort, then
# DENY, also when the budget is spent and the rollback did not run. Re-read
# undetermined -> allow with the note, fail-open, saying the re-check did not run.
crosscheck_after_claim() { # $1 = rollback function, $2 = the claimed slug, $3 = the allow note
  local xslug xrc rb
  xslug="$(other_cover_fresh)"; xrc=$?
  case "$xrc" in
    0)
      # An incomplete rollback is recorded, so the deny holds on a retried edit.
      if rb="$("$1")"; then
        ltc_unresolved_drop "$mybr" "$rel"
      else
        ltc_unresolved_add "$mybr" "$2" "$rel" ||
          rb="$rb (This machine could not record it, so a retry may not be denied.)"
      fi
      drop_table_cache
      deny_other "$xslug" "$rb"
      ;;
    1) allow_note "$3" ;;
  esac
  allow_note "$3 The fresh cross-branch re-check did not run (exit ${xrc}), so a claim another branch filed moments ago is not ruled out; the pre-push gate (Layer B) still checks."
}

# One extend attempt under a pinned lease. Exits on success-without-write and on
# failure (fail-open); returns 0 once written (new_sha = the new lock commit), or
# 1 when the lock moved since this hook read it (nothing written; re-read).
extend_own() {
  local rc esha claim parsed paths out
  run_bounded git fetch --quiet "$remote" "+refs/locks/${own}:refs/locks/${own}" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] || fail_open "could not fetch plan-lock '${own}' from ${remote}, git exit ${rc}"
  esha="$(git rev-parse --verify --quiet "refs/locks/${own}^{commit}" 2>/dev/null)" ||
    fail_open "plan-lock '${own}' did not resolve after the fetch"
  claim="$(git cat-file blob "${esha}:claim.json" 2>/dev/null)" || fail_open "plan-lock '${own}' has no readable claim.json"
  # Line 1 branch, 2 owner, 3 plan, 4 notes, then one write-set path per line.
  parsed="$(printf '%s' "$claim" | "$pybin" -c '
import json, sys
d = json.load(sys.stdin)
def one(v):
    return (v if isinstance(v, str) else "").replace("\r", " ").replace("\n", " ")
for k in ("branch", "owner", "originating_plan", "notes"):
    print(one(d.get(k)))
for p in d.get("write_set") or []:
    if isinstance(p, str) and p and "\n" not in p and "\r" not in p:
        print(p)
' 2>/dev/null)" || fail_open "plan-lock '${own}' has an unparseable claim.json"
  parsed="${parsed//$'\r'/}"
  { IFS= read -r c_branch; IFS= read -r c_owner; IFS= read -r c_plan; IFS= read -r c_notes; } <<<"$parsed"
  [ "$c_branch" = "$mybr" ] || fail_open "plan-lock '${own}' now names branch '${c_branch}'"
  paths="$(printf '%s\n' "$parsed" | tail -n +5)"
  printf '%s\n' "$paths" | grep -qxF -- "$rel" && { drop_table_cache; exit 0; }
  printf '%s\n' "$paths" | awk 'NF && !seen[$0]++' >"$ws_prev" || fail_open "could not write the write-set file"
  { cat "$ws_prev"; printf '%s\n' "$rel"; } >"$ws" || fail_open "could not write the write-set file"
  n="$(grep -c . "$ws")"
  out="$(AGENT_ID="${c_owner:-${AGENT_ID:-orchestrator}}" LOCK_BRANCH="$mybr" LOCK_PLAN="$c_plan" LOCK_NOTES="$c_notes" \
    LOCK_REMOTE="$remote" LOCK_RETRY_MAX=1 LOCK_EXPECT_SHA="$esha" run_bounded bash "$_update" "$own" "$ws" 2>&1)"; rc=$?
  case "$rc" in
    0) ;;
    1)
      ext_err="$(last_line "$out")"
      return 1
      ;;
    *) fail_open "lock-claim-update.sh ${own} exit ${rc}: $(last_line "$out")" ;;
  esac
  new_sha="$(printf '%s\n' "$out" | sed -n 's/.* updated to \([0-9a-f]\{40,64\}\) (was .*/\1/p' | tail -n 1)"
  return 0
}

if [ -n "$own" ]; then
  # Extend. lock-claim-update.sh REPLACES the write set, so the set is read fresh
  # from the lock ref (the cached table can trail a recent update) and the update
  # is pinned to the commit it was read from (LOCK_EXPECT_SHA): a concurrent
  # extension from another session of this branch is re-read, never dropped. A
  # second lost lease fails open without writing.
  new_sha="" ext_err="" n=0 c_owner="" c_plan="" c_notes=""
  extend_own || extend_own ||
    fail_open "plan-lock '${own}' changed again while this hook re-read it (${ext_err}); nothing was written"
  drop_table_cache
  crosscheck_after_claim rollback_extend "$own" "Plan-lock: ${count} other live session(s) share this repo, so this edit hook extended your plan-lock '${own}' on branch '${mybr}' with '${rel}' (${n} paths now; none dropped). Keep editing; release it with the rest of the work as usual."
fi

# Claim a new lock for this branch under its deterministic slug.
claim_sha=""
printf '%s\n' "$rel" >"$ws" || fail_open "could not write the write-set file"
out="$(LOCK_BRANCH="$mybr" LOCK_NOTES="auto-claimed by the guard-plan-lock.sh edit hook" LOCK_REMOTE="$remote" \
  LOCK_RETRY_MAX=1 run_bounded bash "$_claim" "$aslug" "$ws" 2>&1)"; rc=$?
case "$rc" in
  0)
    claim_sha="$(printf '%s\n' "$out" | sed -n 's/.* claimed at \([0-9a-f]\{40,64\}\) (owner=.*/\1/p' | tail -n 1)"
    drop_table_cache
    crosscheck_after_claim rollback_new "$aslug" "Plan-lock: ${count} other live session(s) share this repo, so this edit hook auto-claimed plan-lock '${aslug}' for '${rel}' on branch '${mybr}'. Later uncovered edits on this branch extend it. Set its plan with LOCK_PLAN=<your plan-doc> bash agents/scripts/core/lock-claim-update.sh ${aslug} <full-write-set-file>, and release it with the rest of the work as usual."
    ;;
  1)
    # The slug is already held. It is derived from this branch, so the holder is
    # normally this branch itself, filed moments ago by another clone or session
    # and not yet in this session's cached table. Re-read fresh: another branch
    # now covering the path denies; this branch covering it allows; otherwise
    # fail open.
    drop_table_cache
    oslug="$(other_cover_fresh)"; ocov=$?
    case "$ocov" in
      0) deny_other "$oslug" ;;
      1) ltc_covering_slug "$rel" same "$mybr" >/dev/null && exit 0 ;;
    esac
    fail_open "plan-lock '${aslug}' is already held, exit 1"
    ;;
  *)
    fail_open "lock-claim.sh ${aslug} exit ${rc}: $(last_line "$out")"
    ;;
esac
