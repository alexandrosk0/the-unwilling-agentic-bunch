# Delegation — when to spawn an agent, and the spawn contracts

> Lifted from [`AGENTS.md`](../../AGENTS.md) § Delegation. Unqualified `AGENTS.md § <subsection>` references resolve against this file's headings. Edit this file directly — no parallel copy in AGENTS.md.

## Default behaviour

The main thread does the work. It loads the skill or rule doc the [`AGENTS.md`](../../AGENTS.md) on-demand table names for the task (debugging, perf, tests, PR-bot feedback, cleanup, builds) and runs it inline. Spawn a subagent only where a separate context is the capability:

- **`architect`** — a design that spans two or more subsystems, or changes a shared interface (a backend contract, the command registry, view storage, a wire schema). Hand off **before** code exists; it returns a plan the main thread implements.
- **`code-review`** — before every commit ([`process-rules.md`](process-rules.md) § Code-review before every commit) and on every PR diff.
- **`security-review`** — on a diff that adds or widens a trust boundary, at plan time and pre-merge ([`ship-loops.md`](ship-loops.md) § Plan-time security review).
- **Built-in `Explore` / `general-purpose`** — broad read-only fan-out (one reader per subsystem or question), or a mechanical edit handed to a cheap model ([`process-rules.md`](process-rules.md) § Mechanical edits).

## Orchestrator delegation packet

Before delegating a multi-step slice, build a compact handoff packet so the spawn does not re-read the same docs, rediscover the same call sites, or re-litigate invariants. Each packet includes:

- **Parallel-plan pre-flight**: query the live ref-based plan-lock state via `bash agents/scripts/core/locks-show.sh` before composing the packet. The generated snapshot [`docs/plans/active/_plan-locks.generated.md`](../plans/active/_plan-locks.generated.md) may lag by up to 30 minutes ([`.github/workflows/locks-render.yml`](../../.github/workflows/locks-render.yml)) — never the authoritative read. Intersect the slice's planned write set with every active claim. **Empty** → claim via `bash agents/scripts/core/lock-claim.sh <slug> <write-set-file>` (env `AGENT_ID`, `LOCK_BRANCH`, `LOCK_PLAN` populate `claim.json`). **Non-empty** → STOP: coordinate with the holder (re-scope, sequence behind it, pick another slice) or escalate the overlap via `AskUserQuestion`. Every packet carries the literal sentence: *"Run `bash agents/scripts/core/locks-show.sh` first. Refuse if your write set overlaps any active claim; surface to the orchestrator. On scope growth, run `bash agents/scripts/core/lock-claim-update.sh <slug> <write-set-file>`."* Each PR holding a lock carries a `lock-slug: <slug>` body line so [`.github/workflows/lock-cleanup.yml`](../../.github/workflows/lock-cleanup.yml) releases the ref on close. [`docs/plans/active/_plan-locks-archive.md`](../plans/active/_plan-locks-archive.md) is a frozen audit trail.
- **Owner + scope**: the owning subsystem, the allowed write set, and the files / modules explicitly out of scope.
- **Inline task context**: paste only the relevant design-doc section(s); say "do not reopen the design doc unless blocked" when the excerpt is complete.
- **Shared inventory**: for exact symbol / literal work, run one exhaustive text-search in the orchestrator and pass matches as `<file>:<line>:<role>` (`(cfg-read)`, `(draft-write)`, `(audit-only)`).
- **Invariant decisions**: scan the task against the hard rules and the touched leaf `AGENTS.md`; where the plan collides with a backend contract, the command registry, view storage, a wire schema or the dual-target constraint, pre-resolve the intended option in the prompt.
- **Plan-time probes — file existence, symbol + build-variable resolution, INTERFACE-target linkage, file-split closure, Post-split include-replication rule, pure-helper TU-split recipe, regex budgets**: run them per the [`author-plan-doc`](../../agents/_shared/skills/author-plan-doc/SKILL.md) skill § Pre-seal probes before delegating. The packet states a split's closure rule (never a symbol list from memory) and pre-authorises a pure-helper split in the write set; the host plan template § Files to modify names the project paths and precedents.
- **Subsystem split**: if a design-doc PR spans more than one subsystem, split it before delegating unless one cross-cutting design decision is still open.
- **Output budget**: request `Report <= 200 words, table form, no prose paragraphs` unless the task needs a design write-up.
- **Comment discipline**: code comments explain durable intent, never the task / PR / temporary plan (no `PR 4:` or `remove in PR 7`).
- **Pre-push lint gate**: include, verbatim, *"before push run `bash agents/scripts/project/test-lint-rules.sh --diff origin/develop` and fix every FAIL (comment-noise, function-size, strict-zone) — a green dual-target build does NOT run these"*. Those gates fire only via `test-all.sh` or CI's bucket-A step, never via a targeted `cmake --build` / `ctest`.
- **Build-touching packets — no-reconfigure clause + FetchContent pre-seed**: include, verbatim, *"verify with `cmake --build --preset <preset> --target ...` against the already-provisioned build dir; do NOT run `cmake --preset` / reconfigure / wipe it (a stray reconfigure re-picks the wrong side-by-side toolset or drops `/EHsc` and breaks the dir for the next consumer); if a dir looks broken, STOP and report"* ([`build.md`](build.md) § Fresh-worktree configure pitfalls #5). A worktree-isolated build spawn also pre-seeds `-DFETCHCONTENT_BASE_DIR=<main-repo>/.fetchcontent-src` for its first configure (#6).
- **Plan revision contract**: name the originating `docs/plans/active/<slug>.md` and remind the spawn to append § Implementation log + § Deviations from plan + § Verification per [`process-rules.md`](process-rules.md) § Plan revision after implementation.
- **Verification automation handoff**: the spawn lists every manual verification step in its report ("no manual steps" is a valid statement); the main thread then converts each one, loading the [`test-authoring`](../../agents/_shared/skills/test-authoring/SKILL.md) skill.
- **Subagent progress markers reminder** (per § Subagent progress markers): include the literal sentence *"Emit one-line progress markers to `.progress.log` via `bash agents/scripts/core/agent-progress.sh "<phase>: <text>"` at each major step (start, lock, design, code, test, gate, commit, push, pr, end) so `tail-agent.sh` shows live progress."*

## Parallel dispatch

Run two or more subagents in a **single tool-use block** when their contracts are independent:

- Pre-merge gate → `code-review` + `security-review` concurrently.
- Broad read-only question → one built-in `Explore` per subsystem or sub-question.
- Multi-subsystem feature with disjoint write sets → `general-purpose` spawns, each in its own worktree after the lock pre-flight.

**Do not parallelise when one delegation feeds another** (`architect` → implementation). For **deterministic** fan-out (barrier / pipeline / loop-until-dry / adversarial-verify) or a **saved** multi-agent recipe, use a `Workflow` — [`workflow-fleets.md`](workflow-fleets.md) holds the decision rule, the fan-out-safe roster, the boundaries and the cost guardrails. Claude-Code-only; other harnesses stay on manual dispatch.

## Session scratchpad protocol

A per-session orchestrator scratchpad lives at `.session-context.md` at the repo root (gitignored). The `SessionStart` hook (`agents/scripts/core/clear-session-context.sh`) archives the prior scratchpad (when it carries any agent-appended `## ` section) to `.session-context.archive/<ts>-<sid8>.md`, then writes a fresh banner. The `SubagentStop` hook (`agent-token-log.py`) appends a dated header block from each subagent whose report carries a `## Session context append` section.

- **Subagents do not Read or Edit `.session-context.md`.** The orchestrator reads it once per turn and passes the relevant context inline — no races between parallel spawns.
- **Subagents emit `## Session context append`** for session-durable facts — repro state, file:line evidence, decisions locked, open questions. The hook appends; the agent never writes the file.
- **Append-only.** The hook never edits prior entries.
- **Cross-session archive.** Archives are gitignored, never auto-pruned, and surfaced on demand by the [`scratchpad-recall`](../../agents/_shared/skills/scratchpad-recall/SKILL.md) skill — use it when the user references "last session", "yesterday's run" or "what did <agent> find earlier".

Section shape:

```
# Session context append
- <fact 1 with file:line>
- <decision locked>
- <open question handed back to orchestrator>
```

## Subagent progress markers

A subagent in an isolated worktree emits single-line progress markers to `.progress.log` at the worktree root (gitignored); the orchestrator and the user tail it with `bash agents/scripts/core/tail-agent.sh`.

```bash
bash agents/scripts/core/agent-progress.sh "<phase>: <one-line message>"
# or two-arg form:
bash agents/scripts/core/agent-progress.sh <phase> <one-line message>
```

The helper resolves the worktree root via `git rev-parse --show-toplevel` and appends `[HH:MM:SS] <phase>: <message>`; each call is its own process, so `tail -f` sees the line within ~1 s. Emit at least at `start`, `lock` (claim filed), `design` (first production file drafted), `code` (each major chunk landed), `test` (each new test TU), `gate` (before and after each build / ctest / `test-all.sh`), `commit`, `push`, `pr` (with the URL) and `end`. Under `SMATCHET_AGENT_VCS=p4` also emit `p4-shelf`, `inter-slice`, `end-gate`, `prepare-review-cl` and `promote` ([`ship-loops.md`](ship-loops.md) § P4-gated ship-loop). Best-effort, not a merge gate. Quote phase + message as one shell-safe arg (no embedded newlines; single-quote anything with backticks or braces).

## Tool-trace contract

Captured automatically. The `SubagentStop` hook counts `tool_use` blocks in the transcript and writes a `tool_trace` field on each JSONL row (e.g. `"Edit×4, Read×8, Bash×2"`); `agents/scripts/core/agent-tokens-report.py` and `agents-statusline.py` surface it. A `## Tool trace: ...` line in a report is for the reader only.

## Agent output contract

Each agent's prompt defines its report body (architect: the plan sections; the review agents: severity-ranked findings). Every report — an agent's or a `general-purpose` spawn's — ends with:

- `## Outcome: <value>`, one of `applied | halted | failed | partial | aborted`; the telemetry hook keys on it. A halted report adds a `halt_reason:` line naming the blocker.
- `## Session context append` when it has session-durable facts (§ Session scratchpad protocol).
- `## Self-improvement` per [`AGENTS.md`](../../AGENTS.md) § Self-improvement loop — empty is fine.

**Durable finding-append** — a spawn that accumulates findings over a long run (a finder, an auditor, a sweep) appends each finding to a repo file (`build/<run>/findings/<charter>.jsonl`, one JSON object per line) the moment evidence confirms it, not only in its final report, so a session- or token-limit death loses one finding, never the run. Fleet counterpart: [`workflow-fleets.md`](workflow-fleets.md) § Checkpoint contract.

**Pushing spawns run the pre-first-push gate** — a spawn that reports a *pushed* branch ran the `[pre-first-push gate]` ([`ship-loops.md`](ship-loops.md) § Autonomous ship-loop default) before that push and reports its results.

## Stay in the orchestrator for

- Routine command registration, ImGui panels, view-column additions and field-catalog tweaks — follow the touched subsystem's leaf `AGENTS.md`
- Localization strings and annotate UI tweaks
- Additive SQLite schema changes
- Adding or scoping unit tests (the [`test-authoring`](../../agents/_shared/skills/test-authoring/SKILL.md) skill § Unit rig)
- Build breaks ([`build.md`](build.md) § Fix discipline), behavioural bugs (the [`debug-instrument`](../../agents/_shared/skills/debug-instrument/SKILL.md) skill), perf work (the perf skills), PR-bot feedback (the [`coderabbit-triage`](../../agents/_shared/skills/coderabbit-triage/SKILL.md) skill)

## Heuristic

- \>3 files across ≥2 top-level dirs **and** the design isn't obvious → `architect`
- Prompt already specifies file paths + symbols + commit messages → design is resolved; **skip `architect`** and implement
- "Refactor" that one regex + replacement expresses (rename, format pass, typo sweep) → mechanical edit per [`process-rules.md`](process-rules.md) § Mechanical edits; a refactor that moves an interface or module boundary → `architect`
- "Review this" / pre-merge / `/review` → `code-review`; "address the CodeRabbit / Bugbot comments" → the `coderabbit-triage` skill
- "Prove it" / "double-check your work" before declaring your own edits done → the [`but-for-real`](../../agents/_shared/skills/but-for-real/SKILL.md) skill (a self-review, no spawn)
- Crash / wrong output / "doesn't work" / a hang that never recovers / regression without perf wording → the debug pause-loop ([`ship-loops.md`](ship-loops.md) § Debug-mode pause-loop); slow AND wrong → the wrong output first, then the perf workflow
- Slow / FPS / lag / hitch / stutter / freeze / brief or intermittent stall / spike / optimize / profile / high memory or CPU / perf regression → the perf workflow guide (a stall that recovers on its own → its § Spikes) + the `perf-measure` / `perf-instrument` / `perf-gatekeeper` skills
- Else the orchestrator handles it directly

## Model tiering

The three agents pin `model: opus` at `effort: high` — design and review are one-shot-or-lose — and are **pinned, not `inherit`**, so a cheaper session never silently downgrades a merge-gating review (pi runs them on its session model unless a `PI_MODEL_OPUS` map is set). No agent pins a cheaper model; a cheaper model is chosen only by an explicit spawn for mechanical work ([`process-rules.md`](process-rules.md) § Mechanical edits).

**Double-key invariant:** the top-level `model:` must equal `harness-hints.claude-code.model` — the former is what Claude Code executes, the latter feeds the pi/codex generators. To retier an agent, edit **both keys together**; `test-agent-contract.sh` enforces the lockstep.

## Agent versioning

Bump an agent's frontmatter `version: <N>` when a capability tag, a mandatory report section or the output shape changes, not for prose edits; the token log (`agent-token-log.py`) records it with each run.
