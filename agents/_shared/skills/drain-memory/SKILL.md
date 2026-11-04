---
name: drain-memory
description: Drain the Claude Code auto-memory inbox (~/.claude/projects/<slug>/memory/) into the repo. Load on "drain memory", "triage memory", "clean up memory", "memory inbox", when the SessionStart "Memory-drain due" nudge fires, or when the inbox holds 5 or more items or any item older than 7 days. Triages every memory file except MEMORY.md into implement / backlog / toss, verifying each claim against origin/develop first, resets MEMORY.md with a tally, ships the repo edits as a pure-docs PR and logs the drain. Read-write: edits repo docs and deletes local memory files.
version: 2
---

# drain-memory

The harness's auto-memory (`~/.claude/projects/<slug>/memory/`) is a **transient inbox**, not a durable store. Facts captured there during sessions rot: they go stale against the code, duplicate `AGENTS.md`, or stay invisible to the other harnesses (Codex, Cursor and Aider read the repo, never user-private memory). A drain turns the inbox into repo-resident truth. This skill is the whole process; [`docs/agent-rules/memory-drain.md`](../../../../docs/agent-rules/memory-drain.md) keeps only the drain History log.

## When

Event-driven, not calendar. The SessionStart hook `agents/scripts/core/memory-drain-nudge.sh` checks the local inbox on every session start and prints a one-line nudge when the inbox holds ≥ 5 live items **or** any item is > 7 days old (both thresholds are env-overridable; see the hook's header). Act on the nudge, or drain whenever the user asks. A remote or cloud routine **cannot** drain: the memory dir is machine-local, outside the repo, and only a local session sees it.

## Steps

1. **Locate the inbox.** `ls "$HOME/.claude/projects/"*/memory/` and pick the dir whose slug names this repo. List every `*.md` except `MEMORY.md`.
2. **If it is empty**, report "inbox empty" and stop.
3. **Triage every item** — verify first (§ Verify before trusting), then pick one verdict:

   | Verdict | Action |
   |---|---|
   | **Implement** | A durable behavioural rule or project invariant. A one-line rule goes into `AGENTS.md` § Project rules, a fuller one into the matching `docs/agent-rules/<topic>.md` (AGENTS.md § Process rules, **Where new rules go**). A project-specific literal (a path, target, preset or product name) goes into a project doc, never into the portable layer dirs (`agents/core`, `agents/_shared`, `docs/agent-rules`, `docs/harness`): `test-portable-purity` fails the PR otherwise. Delete the memory file. |
   | **Backlog** | Real follow-up work (a regression, a missing guard, a tooling gap) that is not yet a rule. Add a per-entry file `docs/self-improvement/categories/<cat>/<YYYY-MM-DD>-<slug>.md` (format: [`AGENT_SELF_IMPROVEMENT.md`](../../../../docs/self-improvement/AGENT_SELF_IMPROVEMENT.md) § Format) with a `Source: memory <slug> (drained <date>)` line. Delete the memory file. |
   | **Toss** | Already guarded in code, machine-specific (not portable repo truth), or contradicted by the current tree. Delete the memory file and note the reason in the drain summary. |

4. **Reset `MEMORY.md`** to the empty-inbox header: keep the banner and the link to this skill, and record the tally as `_(inbox empty — last drained <date>: N items → A implemented, B backlogged, C tossed)_`.
5. **Ship the repo edits as a PR to `develop`** — a pure-docs diff, so build and tests are skipped (`process-rules.md` § Cadence and verification, **Pure-docs slice skip**); never a direct push. The memory-file deletions are user-private (outside the repo) and are not part of the PR.
6. **Append a History line** to [`memory-drain.md`](../../../../docs/agent-rules/memory-drain.md) § History in the same PR: date, tally, where each implemented item went, and any lesson.

## Verify before trusting

Memories are point-in-time. Before implementing or backlogging, check every cited file path, function name and "fixed in PR #N" note against the tree; a directory restructure that renamed core source paths and moved config files once orphaned several citations at once.

- **Read the claim from `origin/develop`, never the local working tree**: `git show origin/develop:<file>`. Mid-session the local tree may be on a sibling branch the merge-watcher or another session swapped in, and a check there gives the wrong verdict (the first drain filed a still-guarded toolset pin as a regression this way).
- **A memory that says "now wired into tooling" may describe a guard that has since regressed.** That flips the verdict from *toss* to *backlog (regression)*, which is the point of verifying first.
- Never migrate a stale claim verbatim.

## Boundaries

- Never commit the local memory dir into the repo; it is user-private.
- One pure-docs PR per drain; do not bundle unrelated changes.
