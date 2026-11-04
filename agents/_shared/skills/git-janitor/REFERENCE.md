# git-janitor — reference recipes

The commands behind [`SKILL.md`](SKILL.md), which owns what to merge, what to refuse and when; section names match its citations. Project values (protected branches, build targets and presets, code globs) come from `project.config.json` through `scripts/dev/project-config.sh`.

## Path resolution

```bash
MAIN_REPO="$(git rev-parse --show-toplevel)"      # the repo you were invoked from
git worktree list                                 # full list
# If MAIN_REPO is itself a worktree, the canonical main repo is the first line
# whose path is not the current worktree.
OWNER_REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
OWNER="${OWNER_REPO%%/*}"; REPO="${OWNER_REPO##*/}"
```

With one worktree, drop the `-C "$WORKTREE"` lines below; with several, confirm which is in scope and show `git worktree list` in the report.

## Pre-flight

Run in order, before any mutation:

```bash
git worktree list                                                    # 0. scope
git -C "$MAIN_REPO" fetch origin --prune                             # 1. remote state
[ -n "${WORKTREE:-}" ] && git -C "$WORKTREE" fetch origin --prune
git -C "$MAIN_REPO" status --short                                   # 2. uncommitted state
[ -n "${WORKTREE:-}" ] && git -C "$WORKTREE" status --short
git -C "$MAIN_REPO" branch --no-merged origin/develop                # 3. unmerged local branches
[ -n "${WORKTREE:-}" ] && git -C "$WORKTREE" branch --no-merged origin/develop
gh pr list --base develop --json number,title,headRefName,mergeable,mergeStateStatus,isDraft   # 4. open PRs
gh auth status >/dev/null || { echo "gh auth failed — HALT" >&2; exit 1; }                     # 5. identity
ORCH_USER="$(gh api user --jq .login)"; export ORCH_USER
# 6. The poller: poll_merge_gates, gh_pr_ready_idempotent, ask_user_question.
source "$MAIN_REPO/agents/scripts/core/merge-gates.sh"
```

Step 2 showing anything outside `build/` and `.fetchcontent-*/` is a hard refusal: HALT and surface the list. A host that mounts the layer as a submodule sources `merge-gates.sh` from the mount.

## Poll-until-stable

GitHub computes `mergeable` and `mergeStateStatus` lazily; the first read after a sibling merge is often `UNKNOWN`. Call before every merge decision:

```bash
pr_state() {
    local n="$1" tries=0 max=10 m s          # 10 × 2 s = 20 s ceiling
    while [ "$tries" -lt "$max" ]; do
        read -r m s < <(gh pr view "$n" --json mergeable,mergeStateStatus \
            --jq '"\(.mergeable) \(.mergeStateStatus)"')
        case "$s" in
            UNKNOWN|"") sleep 2; tries=$((tries + 1)) ;;
            *) echo "$m $s"; return 0 ;;     # CLEAN DIRTY BLOCKED BEHIND HAS_HOOKS UNSTABLE …
        esac
    done
    echo "$m $s"; return 1                   # still UNKNOWN: non-zero
}
```

`read < <()` reports `read`'s own status, not the function's, so capture stdout first, branch on the exit, then split:

```bash
if ! PR_OUT=$(pr_state "$N"); then
    echo "PR #$N stuck UNKNOWN after 20s — HALT, surface to user" >&2; exit 1
fi
read -r MERGEABLE STATE <<< "$PR_OUT"
case "$MERGEABLE/$STATE" in
    MERGEABLE/CLEAN) ;;                                                     # ready
    MERGEABLE/UNSTABLE|*/HAS_HOOKS) echo "PR #$N: $STATE, proceed with caution" >&2 ;;
    MERGEABLE/BLOCKED) echo "PR #$N: BLOCKED (required check failing) — HALT" >&2; exit 1 ;;
    CONFLICTING/*)     echo "PR #$N: CONFLICTING — user must resolve" >&2; exit 1 ;;
    *)                 echo "PR #$N: $MERGEABLE/$STATE — HALT" >&2; exit 1 ;;
esac
```

## Pre-flight cross-checks

Before any destructive op:
1. **Worktree bookkeeping audit.** Parse `git worktree list --porcelain`. The main worktree has no `gitdir` line; skip it. Each other entry's `gitdir` points at `.git/worktrees/<id>/`; a missing dir means the working dir is orphaned. Conversely, flag directories under `.claude/worktrees/<id>/` with no matching `worktree` line. Remove a phantom dir by hand only after the user confirms; basename parity against `.git/worktrees/` is not reliable.
2. **Detached-HEAD salvage tag.** For each worktree on a detached HEAD, `git -C <path> log --oneline HEAD ^origin/develop ^origin/main` lists its unique commits. If any exist, tag `salvage/<worktree-name>-<short-summary>` before any prune or remove, so a parallel agent's WIP is not garbage-collected.
3. **Lock-staleness sweep.** `bash agents/scripts/core/lock-staleness-sweep.sh` surfaces plan-locks whose PR merged without the auto-release firing (a squash-merge edge case). Run it before the final report.
4. **Backstop bump proposer** (two-repo hosts only), next.

### Backstop bump proposer

Proposes the layer-pin bump the layer repo's `auto-bump.yml` missed. All four predicates must hold; each failure mode is spelled out, because a wrong reading either spams bump PRs or hides a rewritten layer history.

```bash
# P2 first: no gitlink means a pre-flip tree, and the whole step is a no-op.
pinned=$(git -C "$MAIN_REPO" ls-tree origin/develop agent-layer | awk '$1 == "160000" {print $3}')
[ -n "$pinned" ] || exit 0
layer_url=$(git -C "$MAIN_REPO" config -f .gitmodules submodule.agent-layer.url)
layer_slug=$(printf '%s' "$layer_url" | sed -E 's#^https://github.com/##; s#\.git$##')
host_slug=$(gh repo view --json nameWithOwner --jq .nameWithOwner)

# P1: the layer tip resolves. A network failure skips silently; never propose blind.
layer_tip=$(git ls-remote "$layer_url" refs/heads/develop | cut -f1) || exit 0
[ -n "$layer_tip" ] || exit 0

# P3: the tip moved and the pin is its ancestor. Fetch both into the cache FIRST:
# on a missing object merge-base exits 128, not 1, which would read like a rewrite.
[ "$layer_tip" != "$pinned" ] || exit 0
cache="$MAIN_REPO/.git/agent-layer-backstop.git"
[ -d "$cache" ] || git clone --bare --filter=blob:none "$layer_url" "$cache"
git -C "$cache" fetch --no-tags origin develop && git -C "$cache" fetch --no-tags origin "$pinned" || exit 0
rc=0; git -C "$cache" merge-base --is-ancestor "$pinned" "$layer_tip" || rc=$?
case "$rc" in
    0) ;;                                                    # ancestor: proceed
    1) echo "HALT: layer develop no longer contains the host pin $pinned (history rewritten)"; exit 1 ;;
    *) exit 0 ;;                                             # fetch/lookup failed: skip silently
esac

# P4: no open bump PR, and auto-bump is not mid-run (terminal and older than 20 min).
open=$(gh pr list --repo "$host_slug" --head bot/agent-layer-bump --base develop --state open --json number --jq length)
[ "$open" = 0 ] || exit 0
last=$(gh run list --repo "$layer_slug" --workflow auto-bump.yml --limit 1 --json status,createdAt \
       --jq 'if length == 0 then "" else .[0] | "\(.status) \(.createdAt)" end')
case "$last" in
    "") ;;                                                   # never ran
    completed\ *) [ $(( $(date -u +%s) - $(date -u -d "${last#completed }" +%s) )) -ge 1200 ] || exit 0 ;;
    *) exit 0 ;;                                             # queued / in progress: racing auto-bump
esac
```

When all four hold: **propose only**. Open the PR `auto-bump.yml` would open (branch `bot/agent-layer-bump` off the host's `develop`, `git update-index --cacheinfo 160000,$layer_tip,agent-layer`, title `chore(agent-layer): bump to <sha>`), or print those commands in dry-run. Never merge it in the pass that opened it: it rides the full gate poll ([`merge-gates.md`](../../../../docs/agent-rules/merge-gates.md) § Bump-PR gate profile).

## Merge-gate return codes

The executable form of SKILL.md § Merge-gate return codes; keep the two in lockstep. `ask_user_question` is the shell shim from `merge-gates-prompt.sh`; in a live session ask with `AskUserQuestion` using the same option strings.
```bash
gate_skip=false
if [ "${SKIP_MERGE_GATES:-false}" != "true" ]; then
    MERGE_GATES_FLIP_READY=true poll_merge_gates "$OWNER" "$REPO" "$N"; rc=$?
    case "$rc" in
        0) ;;
        1|2|3)
            if [ "$rc" = 3 ]; then
                choice=$(ask_user_question "gh API failed 3 consecutive polls (code=3)." \
                    "Retry now" "Skip gates and merge anyway" "Abandon")
            else
                choice=$(ask_user_question "Gates blocked (code=$rc)." \
                    "Skip gates and merge anyway" "Keep waiting (extend poll)" "Abandon")
            fi
            case "$choice" in
                "Skip gates and merge anyway") echo "WARN: user skipped gates: code=$rc" >&2; gate_skip=true ;;
                "Retry now")
                    MERGE_GATES_FLIP_READY=true poll_merge_gates "$OWNER" "$REPO" "$N" || exit 1 ;;
                "Keep waiting"*)
                    # Seed the default before doubling: under set -u an unset knob aborts.
                    MERGE_GATES_MAX_POLLS=$(( ${MERGE_GATES_MAX_POLLS:-90} * 2 )) \
                    MERGE_GATES_FLIP_READY=true poll_merge_gates "$OWNER" "$REPO" "$N" || exit 1 ;;
                *) exit 1 ;;
            esac ;;
        4) echo "PR #$N no longer mergeable (CLOSED/MERGED) — abandon; if MERGED, run git-janitor.sh --post-merge $N" >&2; exit 1 ;;
        5)
            choice=$(ask_user_question "Pagination overflow — manual review required." \
                "Abandon (manual review required)" "Skip gates and merge anyway (acknowledge risk)")
            case "$choice" in
                "Skip gates and merge anyway"*) echo "WARN: user skipped gates: code=5" >&2; gate_skip=true ;;
                *) exit 1 ;;
            esac ;;
        7)  # Actions outage. No skip: a merge past absent checks is a gate escape.
            choice=$(ask_user_question "Actions unavailable (code=7) — see the ESCALATE diagnosis above." \
                "Wait for Actions to drain, then re-poll" \
                "Re-fire CI (push or close-reopen), then re-poll" "Abandon")
            case "$choice" in
                "Wait for Actions"*) MERGE_GATES_FLIP_READY=true poll_merge_gates "$OWNER" "$REPO" "$N" || exit 1 ;;
                "Re-fire CI"*) gh pr close "$N" && gh pr reopen "$N"
                               MERGE_GATES_FLIP_READY=true poll_merge_gates "$OWNER" "$REPO" "$N" || exit 1 ;;
                *) exit 1 ;;
            esac ;;
        8)  # Required run cancelled while pending: waiting cannot clear it. No skip.
            choice=$(ask_user_question "Required run cancelled while pending (code=8) — see the gh run rerun line(s) above." \
                "Rerun the named run(s), then re-poll" "Abandon")
            case "$choice" in
                "Rerun the named run(s)"*)
                    # Run the printed `gh run rerun <id>` line(s) first. A check fed by
                    # github.event.pull_request.body/title needs the PR body edited instead.
                    MERGE_GATES_FLIP_READY=true poll_merge_gates "$OWNER" "$REPO" "$N" || exit 1 ;;
                *) exit 1 ;;
            esac ;;
        *) echo "poll_merge_gates: unexpected rc=$rc — HALT" >&2; exit 1 ;;
    esac
fi
```

## Merge and ledger row

```bash
if [ "$gate_skip" = true ]; then
    SKIP_MERGE_GATES=true bash agents/scripts/core/safe-merge.sh "$N"; mrc=$?   # this PR only
else
    bash agents/scripts/core/safe-merge.sh "$N"; mrc=$?
fi
```

`safe-merge.sh` re-runs the full gate poll (quick once green), flips a draft ready, arms `gh pr merge --squash --auto --match-head-commit <gated head>` and waits up to `SAFE_MERGE_SNAPSHOT_WAIT_SECONDS` (default 120) for the merge, then appends the merge-snapshot row itself (actor `orchestrator-automerge`; verdict `GATES_PASSED`, or `GATES_SKIPPED` when `SKIP_MERGE_GATES=true` bypassed the poll — a skip is recorded as a skip, never as a pass). Its exit codes:

| `mrc` | Meaning | Action |
|---|---|---|
| 0 | Armed (or merged) | bounded wait for `MERGED` (below) |
| 1 | Refused: gates did not pass, or the head moved after the poll | back to the gate step; never bypass |
| 2 | Usage or dependency error (`gh` / `jq` missing) | HALT |
| 3 | Gate-poll precondition (PR closed or merged, `gh` down, head undeterminable) | re-check state: `MERGED` → the one-PR path; otherwise HALT |
| 4 | Required run cancelled while pending | run the printed `gh run rerun <id>` line(s), then re-run `safe-merge.sh` |
| other | `gh pr merge` failed to arm (its status, passed through) | HALT and surface gh's error |

Then wait for `MERGED` (a merge queue can hold it past `safe-merge.sh`'s budget), bounded, and check the row. Auto-merge waits on every branch-protection required check and a user skip does not bypass that, so a red or pending one never merges: the wait HALTs on `CLOSED`, on auto-merge disarmed on two polls in a row (the head moved after the arm, or a dequeue), on three `gh` failures in a row, or past `JANITOR_MERGE_WAIT_SECONDS` (default 1800):
```bash
q='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){state autoMergeRequest{enabledAt} isInMergeQueue}}}'
deadline=$(( $(date +%s) + ${JANITOR_MERGE_WAIT_SECONDS:-1800} )); fails=0; unarmed=0
while :; do
    if st=$(gh api graphql -f query="$q" -f o="$OWNER" -f r="$REPO" -F n="$N" --jq \
        '.data.repository.pullRequest | .state + (if .autoMergeRequest or .isInMergeQueue then " armed" else " unarmed" end)'); then
        fails=0
    else
        fails=$((fails + 1)); st=""
    fi
    case "$st" in
        MERGED*) break ;;
        CLOSED*) echo "PR #$N closed without merging — HALT" >&2; exit 1 ;;
        "OPEN unarmed") unarmed=$((unarmed + 1)) ;;   # two in a row: not a queue hand-off
        *) unarmed=0 ;;
    esac
    [ "$unarmed" -lt 2 ] || { echo "PR #$N auto-merge disarmed (head moved or dequeued) — back to the gate step" >&2; exit 1; }
    [ "$fails" -lt 3 ] || { echo "gh failed 3 polls in a row — HALT" >&2; exit 1; }
    [ "$(date +%s)" -lt "$deadline" ] || { echo "PR #$N not MERGED within the wait budget — HALT: a required check is red or pending" >&2; exit 1; }
    sleep 10
done
SHA=$(gh pr view "$N" --json mergeCommit --jq .mergeCommit.oid)
ledger="${PROJECT_ROOT:-$MAIN_REPO}/docs/self-improvement/merge-snapshots.jsonl"
grep -qF "\"pr\":$N," "$ledger" || echo "no ledger row for #$N yet" >&2
```

- `safe-merge.sh` printed `SNAPSHOT PENDING` (the merge was still queued): once `MERGED`, run the paste-ready `merge-snapshot-append.sh` line it printed, with `<mergeCommit>` / `<mergedAt>` filled from `gh pr view "$N" --json mergeCommit,mergedAt`. The helper is idempotent on `pr` + `mergeCommit`.
- `safe-merge.sh` warned that the PR merged at a head other than the gated one: no row is written, and the merge is a gate escape. HALT, surface it, and run the `gate-escape-postmortem` skill.
- A hole that survives anyway is backfilled by `git-janitor.sh --post-merge "$N"` (verdict `BACKFILLED`, actor `git-janitor`) while the merge is at most 6 h old, and is nudged at SessionStart by `merge-snapshot-holes.sh`. Never compose a row by hand hours later: a stale row is worse than a hole. Rows land uncommitted; commit them with the next develop-bound commit.

## Protected-branch guards

Run before every local or remote branch delete; a hit on either refuses:

```bash
. scripts/dev/project-config.sh                 # exports PC_VCS_PROTECTED_BRANCHES (space-joined)
read -ra _protected <<< "${PC_VCS_PROTECTED_BRANCHES:-}"
is_protected() { local x="$1" p; for p in "${_protected[@]}"; do [ "$x" = "$p" ] && return 0; done; return 1; }
# Code-reference net (zero config): a branch named in committed source is runtime infrastructure.
code_referenced() { git grep -qlF "$1" origin/develop -- Source/ tools/ scripts/ 2>/dev/null; }
if is_protected "$b" || code_referenced "$b"; then echo "PROTECTED: $b — skip"; fi
```

Remote delete after a merge: `HEAD_REF=$(gh pr view "$N" --json headRefName --jq .headRefName)`, run both guards on it, then `gh api -X DELETE "repos/$OWNER/$REPO/git/refs/heads/$HEAD_REF"` (a 422 "Reference does not exist" means GitHub already deleted it).

## FF-clean execution

The decision (preconditions and why) is SKILL.md § FF-clean docs-batch exception.

```bash
ahead_behind=$(git -C "$MAIN_REPO" rev-list --left-right --count origin/develop...develop)
case "$ahead_behind" in
    0$'\t'[1-9]*) ;;                                       # 0 behind, ≥ 1 ahead
    *) echo "not FF-clean ($ahead_behind); fall back to PR-only"; exit 1 ;;
esac

# Blacklist: the project's code globs plus CMake. In a case pattern `*` also matches `/`.
. scripts/dev/project-config.sh                            # exports PC_CI_CODE_GLOBS
read -ra _code <<< "${PC_CI_CODE_GLOBS:-}"
while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in cmake/*|CMakeLists.txt|CMakePresets.json) echo "blacklisted: $f; PR-only"; exit 1 ;; esac
    for g in "${_code[@]}"; do
        # shellcheck disable=SC2254  # the glob is the pattern
        case "$f" in $g) echo "blacklisted: $f; PR-only"; exit 1 ;; esac
    done
done <<< "$(git -C "$MAIN_REPO" diff --name-only origin/develop..develop)"

bash agents/scripts/core/is-pure-docs-diff.sh develop && echo "pure-docs: skip test-all.sh" \
    || bash scripts/dev/test-all.sh || exit 1
git -C "$MAIN_REPO" push origin develop                    # fast-forward push
```

Check the whitelist (precondition 2) against the same list before pushing.

## Diverged-branch recovery

A squash-merged branch that then got more commits conflicts on rebase. Recover by file restore:

```bash
git log --oneline origin/develop..origin/<branch>          # 1. the gap
git diff origin/develop..origin/<branch> --stat            # 2. the file delta
git checkout -b <new-clean-branch> origin/develop          # 3. recover
git checkout origin/<branch> -- <each-changed-file>        # the final delta, one staged change
```

Verify the build, open a fresh PR titled for what is new, and close the stale PR pointing at it. Cherry-pick replays every intermediate state against the squash; file restore yields one commit equal to the delta.

## Stale-branch sweep

**The cherry / ahead-count trap.** Under squash-merge, `git rev-list develop..<branch>` and `git cherry develop <branch>` prove nothing: a fully merged branch still reports N ahead and `+` for every commit, because the squash rewrote the patch-ids. The only reliable signals are (a) `gh pr list --head <b> --state all` returning `MERGED`, (b) a content-in-develop spot check (`git diff origin/develop <branch> -- <file>` empty, or `git grep` for the commit's substance on `origin/develop`), and (c) the squash commit's reachability, `git merge-base --is-ancestor <PR mergeCommit.oid> origin/develop` (the squash commit, never the branch tip). (c) is the strongest single check.

Enumerate local branches (`git branch --format='%(refname:short)'` minus `develop` / `main`) and remote ones (`git branch -r` minus `origin/HEAD`, `origin/develop`, `origin/main`), de-duplicated by short name, and classify:

```bash
classify_branch() { gh pr list --head "$1" --state all --json state --jq '.[0].state // "NO-PR"' 2>/dev/null; }
```

| Class | Action |
|---|---|
| `MERGED` | Delete (worktree → local → remote) after the protected-branch guards |
| `OPEN` | Keep: active PR |
| `CLOSED` (unmerged) | Check content-in-develop (it may have shipped through a superseding PR). Superseded → delete; otherwise ask |
| `NO-PR` | Keep when committed under ~24 h ago or local-only (no upstream); otherwise ask. Never auto-delete |

Delete in worktree-before-branch order, never a dirty worktree:

```bash
if is_protected "$b" || code_referenced "$b"; then echo "PROTECTED: $b — skip"; continue; fi
wt=$(git worktree list --porcelain | awk -v b="$b" '/^worktree /{p=$2} $0=="branch refs/heads/"b{print p}')
if [ -n "$wt" ]; then
    if [ -n "$(git -C "$wt" status --porcelain)" ]; then
        echo "DIRTY worktree $wt holds $b — skip, surface to user"; continue
    fi
    git -C "$MAIN_REPO" worktree remove "$wt"
fi
git -C "$MAIN_REPO" branch -D "$b"
git -C "$MAIN_REPO" push origin --delete "$b" 2>/dev/null || true      # only if it had an upstream
```

A clean, confirmed-merged worktree is safe to remove inline; dirty or unconfirmed → skip and surface, never force. Finish with `git -C "$MAIN_REPO" fetch origin --prune` and the sweep table (name · class · action) in the report; protected branches appear as `kept: PROTECTED`.

## Bringing develop to latest

`gh` reports a merge before the new commit has replicated; the belt below re-fetches when local and remote still differ.

```bash
git -C "$MAIN_REPO" fetch origin
git -C "$MAIN_REPO" checkout develop
git -C "$MAIN_REPO" pull --ff-only
if [ "$(git -C "$MAIN_REPO" rev-parse develop)" != "$(git -C "$MAIN_REPO" rev-parse origin/develop)" ]; then
    git -C "$MAIN_REPO" fetch origin && git -C "$MAIN_REPO" pull --ff-only          # replication-lag belt
fi
if [ -n "${WORKTREE:-}" ]; then                         # worktrees cannot share the develop checkout
    git -C "$WORKTREE" fetch origin
    git -C "$WORKTREE" checkout --detach origin/develop
fi
```

### Post-squash-merge fast path

The 5-step destructive-op pre-flight does not apply to a branch squash-merged this session and untouched by another agent: it holds nothing at risk. Confirm (a) `gh pr view <N> --json state` is `MERGED` and (b) the PR's `mergeCommit.oid` is reachable from `origin/<base>`, then delete with `-D` (the squash commit has a different sha, so `-d` refuses). The 5-step still binds for any branch whose merge you have not confirmed.

```bash
git -C "$MAIN_REPO" branch -D <branch-name>
[ -n "${WORKTREE:-}" ] && git -C "$WORKTREE" branch -D <branch-name>
git -C "$MAIN_REPO" worktree remove "$WORKTREE"        # from the main repo: removing from inside the worktree fails
```

## Orphan-scenario sweep

Step 10.5, end of session only, advisory. A registered scenario is an orphan when **all three** hold: (i) no commit cited its name in the last 60 days, (ii) it is in no curated set, (iii) no test references it. Any single hit disqualifies it. The project's glossary defines where scenarios live and which curated sets count (in a host: `docs/CONTEXT.md`, **Orphan-scenario**); set `SCENARIO_GLOB` and `CURATED` from it:

```bash
for f in $SCENARIO_GLOB; do                      # e.g. <src>/Commands/Scenarios/*Scenario.cpp
    # kebab-case of the file stem (GNU sed); a prefix of Name() still matches the substring greps
    name=$(basename "$f" .cpp | sed 's/Scenario$//; s/\([A-Z]\)/-\L\1/g; s/^-//')
    recent=$(git log --grep="$name" --since="60.days.ago" --oneline | wc -l)
    curated=$(for c in $CURATED; do grep -rlF "$name" "$c" 2>/dev/null; find "$c" -type f -name "*$name*" 2>/dev/null; done | wc -l)
    intests=$(grep -rlF "$name" tests/ 2>/dev/null | wc -l)
    [ "$recent" -eq 0 ] && [ "$curated" -eq 0 ] && [ "$intests" -eq 0 ] && echo "ORPHAN: $name ($f)"
done
```

Surface every match in one combined `AskUserQuestion` (per orphan: `keep` / `archive to docs/reference/<name>.md` / `delete the .cpp + its registry line`). Default `keep`. Carry the three counts verbatim so the user can audit.

## Regression gate

```bash
. scripts/dev/project-config.sh                 # PC_BUILD_TARGETS, PC_BUILD_PRESETS
read -ra _targets <<< "${PC_BUILD_TARGETS:-}"
read -ra _presets <<< "${PC_BUILD_PRESETS:-}"
if [ "${#_targets[@]}" -gt 0 ]; then            # an agent-layer-profile repo has no build block
    preset="${_presets[0]}"                     # the iteration preset is listed first
    for t in "${_targets[@]}"; do
        cmake --build --preset "$preset" --target "$t" || { echo "build FAILED: $t — HALT" >&2; exit 1; }
    done
fi
bash scripts/dev/test-all.sh                    # auto-discovers every scripts/dev/test-*.sh
```

**Feature-OFF variants** (the project's build doc lists them, with the exact flag): configure through the preset with `-B` / `-D` overrides, then build the primary target, e.g. `cmake --preset "$preset" -B build/<variant>-check -D<FEATURE_FLAG>=OFF` and `cmake --build build/<variant>-check --target <primary>`. Never a bare `cmake -B … -G Ninja`: it picks whatever compiler is on `PATH` and can skip compiler-gated link settings the preset pins (an MSVC-only entry-point override, for one), so the link fails for reasons unrelated to the merge.

Decide on exit codes, never on piped output (`process-rules.md` § Cadence and verification). `test-all.sh`: 0 all pass; 1 a regression; 2 a missing binary (an upstream build problem). Any non-zero is a HALT.

## Final report template

```
=== git-janitor — end-of-session cleanup ===
## Pre-flight
  main repo:    <commit-msg-short>  (clean / DIRTY → halted)
  worktree:     <commit-msg-short>  (clean / DIRTY → halted)
  open PRs:     N
## Mutations applied
  #<N>  <title>  →  squash <sha-short>   ledger: written | pending paste line
  branches deleted: <name> (local + remote) …
  develop: <old-sha> → <new-sha>
  backlog sweep: <N applied / 0>
  stale-branch sweep:
    <name>  <MERGED|CLOSED|OPEN|NO-PR>  <deleted | kept: reason | kept: PROTECTED | asked-user>
## Regression gate
  <target>               PASS
  <feature-OFF variant>  PASS
  scripts/dev/test-all.sh  N/N PASS
## Residue requiring user action
  - git -C "$MAIN_REPO" worktree remove "$WORKTREE"   (if you want this worktree gone)
  - commit the merge-snapshot rows: docs/self-improvement/merge-snapshots.jsonl
  - test-authoring follow-up: PR #<N> shipped a manual verification step
  - <other manual items | none>
develop now at:  <sha-short>  <title>
Worktrees in scope: <git worktree list output>
## Outcome: <applied | halted | failed | partial | aborted>
```
