---
name: git-janitor
description: End-of-session git maintenance. Load on "end of session", "no more changes coming", "merge the open PRs", "tidy up", "clean up branches" / "clean up worktrees", "post-merge cleanup", "bring develop to latest", "get develop to latest", "stale branches", or after the last PR of a session merges. Squash-merges authorised open PRs in dependency order through safe-merge.sh (full merge-gate poll, merge-snapshot ledger row), deletes merged branches and worktrees behind the protected-branch guards, brings develop to latest, and runs the regression gate. Refuses on uncommitted user work, force-push to develop/main, reverting a merge, or unvalidated visual commits. SKILL.md holds the judgement (hard refusals, merge-gate return-code mapping, the FF-clean decision, dry-run triggers, report contract); REFERENCE.md holds the commands.
triggers:
  - end of session
  - no more changes coming
  - merge open PRs
  - post-merge cleanup
  - bring to develop
  - get develop to latest
  - stale-branch sweep
  - worktree cleanup
  - git maintenance
  - tidy up
version: 8
---

# git-janitor

`git-janitor` is the end-of-session cleanup role: a merge actor in [`merge-gates.md`](../../../../docs/agent-rules/merge-gates.md), the `git-janitor cleanup` stage of the ship-loop, the `git-janitor` token in the merge-snapshot ledger, and the script `agents/scripts/core/git-janitor.sh`. The session that finished the work runs it; it needs no subagent. This file holds the judgement; every command it cites by section name is in [`REFERENCE.md`](REFERENCE.md).

Scope is the git/GitHub ship-line only, identical in either VCS mode. It never touches Perforce shelves, streams, counters or server state; a project that runs the optional p4 layer keeps its janitor pass in its own Perforce doc (`docs/perforce/AGENT_FLOWS.md` § Janitor pass). Watcher registration (`merge-watch register --authorized <pr>`) is VCS-agnostic: registration alone is watch-only, and `--authorized` is the user's merge consent.

## Pick the path

- **One PR already merged** (by any actor — watcher, a human in the GitHub UI, a session): `bash agents/scripts/core/git-janitor.sh --post-merge <N>`. It refuses a dirty tree and a PR that is not `MERGED`, defers (exit 0) while another live session is registered in the tree, fast-forwards `develop`, deletes the local branch, backfills a missing merge-snapshot row (verdict `BACKFILLED`, actor `git-janitor`, merges at most 6 h old) and runs the dual-target build. Override the deferral only with the user's consent; HEAD moves under the sibling session.
- **End-of-session pass** (open PRs to merge, branches and worktrees to sweep): the loop below.

## Hard refusals

These are non-negotiable stops; the bash that enforces the mechanical ones is in REFERENCE.md.

- **Uncommitted user work blocks operations.** `git status` showing modified or untracked files other than `build/` and `.fetchcontent-*` → STOP and surface the file list. Never stash silently; ask the user to commit or discard.
- **Destructive ops on a worktree you did not check out this session** (`reset --hard`, `checkout --`, `clean -f`, `branch -D`) require the 5-step pre-flight in [`process-rules.md`](../../../../docs/agent-rules/process-rules.md) § Git/p4 discipline (**Destructive git ops in shared worktrees**). A worktree path's *name* does not say which branch it holds: run `git -C <path> branch --show-current` first, every time. One exception: § Post-squash-merge fast path in REFERENCE.md.
- **Force-push to `develop` / `main`** — never, even with `--force-with-lease`. A merge that needs public history rewritten goes back to the user.
- **Revert a merged PR** — never. A regression that slipped through is flagged and the pass stops; the user authors the revert.
- **Delete a protected or load-bearing branch** — never, even with no open PR and nothing unmerged. Some branches are runtime infrastructure (an asset-host branch the product pushes to, or one that mirrors a tarball fetched at configure time); deleting one breaks live behaviour and can red-wall the build. Before any local or remote branch delete, two guards run and a hit on either refuses: (1) `vcs.protected_branches` in `project.config.json`, (2) the code-reference net (the branch name appears in committed source). The branch literal lives only in `project.config.json`.
- **Squash-merge a PR carrying unvalidated visual commits** — never. Intermediate commits on a draft PR can be visual iterations still awaiting a verdict ([`ship-loops.md`](../../../../docs/agent-rules/ship-loops.md) § Exceptions, the visual-validation exception). Confirm the user approved the latest visual state; the user-comment gate covers it when the user commented, otherwise ask.
- **Push directly to `develop`** — never, except § FF-clean docs-batch exception. Everything else lands by PR + squash-merge.
- **Act on a rewritten layer history** — never. When the backstop bump proposer (REFERENCE.md § Backstop bump proposer) finds the host's pinned layer commit is not an ancestor of the layer's `develop`, HALT and surface it.
- **One invocation cleans one repo.** The layer repo's PRs and branches are a second pass run against the layer repo, never a cross-repo delete from this one.
- **Skip the regression gate** — never, even for a docs-only batch, except under the FF-clean exception (which substitutes `test-all.sh`). A broken `develop` blocks all future work.
- **Merge without authorisation** — a user request to merge the open PRs (or a standing `governance.auto_merge: on`, "merge when green", a watcher entry with `authorized: true`) authorises those PRs. Report every other PR; do not merge it ([`merge-gates.md`](../../../../docs/agent-rules/merge-gates.md), **Auto-`gh pr ready` + merge**).

## FF-clean docs-batch exception (the decision)

The PR-only rule for `develop` is suspended for one batch — `develop` only, never `main` — when **all** of these hold; any failure falls back to PR-only:

1. **Strictly ahead, FF-only** — `git rev-list --left-right --count origin/develop...develop` reports `0 N` with `N ≥ 1`.
2. **Path whitelist** — every commit touches only `docs/**`, `agents/**`, `scripts/dev/**`, `tests/**`, `backlog/**`, `.gitignore`, `AGENTS.md` or a root `*.md`.
3. **Path blacklist** — no commit touches a path in the project's code globs (`ci.path_filters.code_globs` in `project.config.json`), `cmake/**`, a root `CMakeLists.txt` or `CMakePresets.json`. One hit sends the whole batch to PR-only.
4. **Gates green** — `bash scripts/dev/test-all.sh` exits 0. The dual-target rebuild is not required here (no compiled source in the diff); it is required everywhere else.

**Pure-docs sub-exception** (relaxes precondition 4): when the ahead-range passes `bash agents/scripts/core/is-pure-docs-diff.sh develop` (allow-list `docs/**`, `backlog/**`, `agents/scripts/**`, any `*.md` at any depth, a pointer-only `agent-layer` / `.gitmodules` bump; the script is authoritative), `test-all.sh` is skipped as well. Anything not allow-listed restores the full gate. The trivial-visual-only envelope (`process-rules.md`) is a separate gate-relaxation path; do not conflate them.

Why narrow: behaviour-changing code stays under PR review, and only the friction case the PR-only rule never meant to block is removed. When the exception fires, § Mutations applied carries `FF-clean docs-batch push to origin/develop — N commits, whitelist ok, blacklist clean` and the outcome is `applied`. Execution: REFERENCE.md § FF-clean execution.

## Pre-flight

Before any mutation run REFERENCE.md § Path resolution, § Pre-flight (worktree list, fetch + prune, uncommitted-state audit, unmerged-branch audit, open-PR list, `ORCH_USER`, source the poller) and § Pre-flight cross-checks (worktree bookkeeping, detached-HEAD salvage tag, lock-staleness sweep, and on a two-repo host the backstop bump proposer). With more than one worktree, confirm which one is in scope; do not guess. When the cleanup must move HEAD in a tree where another live session is registered (`process-rules.md` § Git/p4 discipline, **Concurrent interactive sessions**), run the pass from your own worktree, or stop and ask.

## Cleanup loop

For each authorised open PR targeting `develop`, in **dependency order** (oldest unmerged first; when two PRs touch the same file, the older merges first):

1. **Verify merge state** with REFERENCE.md § Poll-until-stable. Require `MERGEABLE` + `CLEAN`; `CONFLICTING` → halt (the user resolves). `UNKNOWN` is transient, but `UNKNOWN` sustained for 20 s is itself halt-worthy (repo migration, rate limit, replication outage).
2. **Best-effort draft → ready** (`gh_pr_ready_idempotent`) so a review bot that skips drafts reviews the PR. Non-blocking; the poll retries the flip. Return code 6 (unknown failure) → surface the error, do not merge.
3. **Run the merge gates** unless `SKIP_MERGE_GATES=true` was set at session start: `MERGE_GATES_FLIP_READY=true poll_merge_gates`, then map the return code with the table below. Never fall through to a merge on an unexpected code.
4. **Merge through `safe-merge.sh`** (REFERENCE.md § Merge and ledger row). It re-runs the full gate poll, arms `gh pr merge --squash --auto` bound to the gated head, waits for the merge and appends the merge-snapshot row (actor `orchestrator-automerge`); the janitor then waits for `MERGED` on a bounded budget and HALTs when it does not come. Never a bare `gh pr merge --auto` and never a direct REST `PUT …/merge`: both skip the review-bot, user-comment and Bugbot gates. Confirm the ledger row exists before moving on.
5. **Delete the remote branch** after the protected-branch guards (REFERENCE.md § Protected-branch guards).
6. **Append to the plan revision** when the PR shipped a slice of `docs/plans/active/<slug>.md`: `- <sha-short> · <PR-title>` under § Implementation log, on a fresh branch + PR (or batched into the closeout PR).
7. **Re-check the next PR's mergeability** — merging A can flip B to `CONFLICTING`.
8. **Post-merge backlog sweep** — apply any `docs/self-improvement/` entry that now meets its threshold, one small PR each, and archive it to `applied.md`.
9. **Verification-automation handoff** — any manual-verification language in the merged plan's § Verification is flagged for a follow-up through the `test-authoring` skill.

After the last PR:

10. **Bring `develop` to latest** (REFERENCE.md § Bringing develop to latest) and run the **stale-branch sweep** (REFERENCE.md § Stale-branch sweep): under squash-merge, ahead counts and `git cherry` prove nothing; only PR state `MERGED`, a content-in-develop check or the squash commit's reachability do. `NO-PR` branches are never auto-deleted.
10.5. **Orphan-scenario sweep** (end of session only, advisory, default `keep`) — REFERENCE.md § Orphan-scenario sweep.
10.6. **Triggered follow-ups** — `bash agents/scripts/core/followup-due-nudge.sh --list`, so a follow-up that came due surfaces at closeout and not only at SessionStart (`process-rules.md` § Triggered follow-ups).

Then the regression gate.

### Merge-gate return codes (step 3)

The options mirror the **Halt prompts (per return code)** table in [`merge-gates.md`](../../../../docs/agent-rules/merge-gates.md) row for row; ask with `AskUserQuestion`.

| rc | Meaning | Options |
|---|---|---|
| 0 | Gates passed | proceed to step 4 |
| 1 | Still blocked at `MERGE_GATES_MAX_POLLS` | Skip gates and merge anyway · Keep waiting (double `MERGE_GATES_MAX_POLLS`, re-poll once; a second failure abandons) · Abandon |
| 2 | Wall-clock timeout | same as 1 |
| 3 | `gh` API failed 3 consecutive polls (also a poll precondition: `ORCH_USER` unset, query file missing) | Retry now · Skip gates and merge anyway · Abandon |
| 4 | PR closed or merged externally | Abandon. If it is `MERGED`, run the one-PR path for it |
| 5 | Pagination overflow | Abandon (manual review required) · Skip gates and merge anyway (acknowledge risk) |
| 7 | Actions unavailable (outage escalation) | Wait for Actions to drain, then re-poll · Re-fire CI (push or close-reopen), then re-poll · Abandon — **no skip**: a merge past absent checks is exactly what the postmortem-owed required-ABSENT detector flags |
| 8 | Required run cancelled while pending | Rerun the named run(s) (`gh run rerun <id>` from the BLOCK output), then re-poll · Abandon — **no skip**, same reason as 7; a check fed by the PR body or title needs the body edited instead |
| other | Unexpected | HALT |

The user chooses a skip; the janitor never picks it on its own, also not under `governance.auto_merge: on`. A skip logs `WARN: user skipped gates: code=<rc>`, runs `safe-merge.sh` with `SKIP_MERGE_GATES=true` scoped to that one PR, and is listed in § Mutations applied. A skip bypasses only the poller: GitHub auto-merge still waits on a red or pending branch-protection required check, so the bounded wait HALTs there — surface it to the user (`safe-admin-merge.sh` only for a stale-BLOCKED PR whose checks are all green). The ledger row `safe-merge.sh` writes records `GATES_PASSED` either way, so the report is the record of the skip. Executable form: REFERENCE.md § Merge-gate return codes.

## Regression gate

After all merges and the sweep, before declaring done: build every target in `build.targets` (`project.config.json`) with the project's iteration preset, build the feature-OFF variants the project's build doc names (they catch stub-build drift), and run `bash scripts/dev/test-all.sh` (REFERENCE.md § Regression gate). `git-janitor.sh --post-merge` runs only the dual-target build; the end-of-session pass runs all three. A build failure means a squash-merge produced a non-buildable `develop`: HALT and surface it; the fix follows [`build.md`](../../../../docs/agent-rules/build.md) § Fix discipline and lands by PR. `test-all.sh` non-zero is a HALT (exit 2 = a missing binary, an upstream build problem).

## Dry-run mode

When the request says `DRY RUN`: run the pre-flight and the audits, print every intended mutation verbatim (the `safe-merge.sh` calls, branch deletes, plan-revision text, backlog edits, the bump PR), apply none, and mark the report `[DRY RUN — no changes applied]`. Enter dry-run automatically when the batch holds 3 or more PRs, when any PR touches the project's code globs or build files, or when the dependency order is not obvious; the user then says "go" for the real run.

## Report contract

Report in this order (template: REFERENCE.md § Final report template):

- `## Pre-flight` — tree state per worktree, open PRs, `git worktree list`.
- `## Mutations applied` — only what happened, one bullet each: each merge (PR, title, squash sha, ledger row written or the pending paste line), each branch deleted (local / remote), `develop` old → new tip, backlog status flips, a gate skip and its code, the FF-clean push row, the backstop bump PR (number, old → new pin).
- `## Regression gate` — each target, each feature-OFF variant, `test-all.sh`.
- `## Residue requiring user action` — each line names the exact command: `git -C "$MAIN_REPO" worktree remove "$WORKTREE"` (worktrees are kept by default for inspection); the uncommitted merge-snapshot rows (commit them with the next develop-bound commit, a `chore(ledger)` PR when nothing else is in flight); a `test-authoring` follow-up for each flagged manual verification step; backlog entries upgraded P3 → P2 when the same friction recurred 3 or more times this session; merges that left review-bot findings unresolved; a stranded p4 shelf or task stream (the project's Perforce janitor pass). `none` when empty.
- `## Outcome: <applied | halted | failed | partial | aborted>`, then `## Self-improvement` (only real friction: a CLI surprise, a refusal that fired unexpectedly, the gate catching a real regression; empty is fine).
