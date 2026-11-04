# Agent vs skill — the decision rule

Use this when a recurring procedure needs a home: an **agent** (`agents/core/<name>.md`, a spawned subagent with its own context) or a **skill** (`agents/_shared/skills/<name>/SKILL.md`, loaded into the main thread).

## The rule

- **An agent only where a separate context is the capability.** Independent review (`code-review`, `security-review`) is worth something because the reviewer did not write the diff and does not carry the author's assumptions; design (`architect`) is worth a fresh context because it reads widely across subsystems before anything is edited. Specialist knowledge alone is not a reason: a subsystem's rules belong in its leaf `AGENTS.md`, where every session that touches it reads them.
- **A skill for every bounded procedure the main thread runs** — debugging, perf measurement, test authoring, PR-bot triage, cleanup, plan authoring. The main thread already holds the task's context; spawning a specialist to run a procedure costs that context and buys nothing.
- **Broad read-only fan-out uses the built-in agents** (`Explore`, `general-purpose`), not a custom one — [`workflow-fleets.md`](workflow-fleets.md) § Fan-out-safe roster.

A new agent needs a reason the three existing ones do not cover: a role whose value is that it does **not** share the main thread's context. Everything else is a skill, a rule doc, or a leaf `AGENTS.md` bullet.

## How a skill reaches every harness

- **Claude Code** auto-discovers every skill: `setup-harness.sh claude-code` links each `agents/_shared/skills/<name>/` into `.claude/skills/`, and the skill's `description:` decides when it loads.
- **Codex, Cursor, pi and generic harnesses** read [`AGENTS.md`](../../AGENTS.md) and have no skill discovery, so a skill reaches them only by a path link to `agents/_shared/skills/<name>/SKILL.md`: a row in its § Project rules on-demand table, or a link from a doc that AGENTS.md routes to (the work-item review and close skills, for example, are linked from [`work-items.md`](work-items.md) and [`review-panels.md`](review-panels.md) where those steps run).

So every skill ships with both:

1. A `description:` that names the user-visible symptoms and requests that should load it ("crash", "wrong output", "doesn't work", "address the CodeRabbit comments") — not only the procedure's name.
2. A route on every harness: an on-demand row when the trigger is a top-level task class (debugging, perf, tests, PR-bot feedback, cleanup); otherwise a path link from a doc that AGENTS.md routes to, at the step where the procedure runs or in a heuristic bullet (`delegation.md` links the self-check and session-recall skills that way). AGENTS.md has a hard line cap, so a narrow trigger takes a link, not a row. A skill named only in prose, without its path, reaches Claude Code alone.

Rule 2 is gated: `test-skill-reachability.sh` fails any skill whose `SKILL.md` path is not a markdown link in AGENTS.md or in a doc AGENTS.md links to (one hop; prose, code spans and fenced examples do not count).

## Shaping a skill

- **SKILL.md holds the judgement**: when to load, scope and boundaries, hard rules, the loop, the report shape. **REFERENCE.md** beside it holds the verbatim recipes (long shell blocks, command sets, cleanup commands) once SKILL.md nears the ~400-line soft cap — the reasoning stays readable and the recipes load only when run.
- **Keep the hot path inline.** A rule the procedure always applies stays in SKILL.md; only conditional, standalone recipes move to REFERENCE.md.
- **Project facts go to the host.** A skill under `agents/_shared/` is a portable dir: build presets, paths and target names come from `project.config.json` or a host doc the skill points at, never a literal (`test-portable-purity`).

The same seam applies inside an agent prompt that grows large: its reasoning (scope, hypothesis ranking, refusals, report shape) stays; a deterministic recipe it runs occasionally is a skill in the wrong place — extract it and leave a one-line *what + when + path* pointer. The size gate (`agent_size_audit.py`, [`AGENTS.md`](../../AGENTS.md) § Project rules § Prompt/contract size) keeps agents readable.

**Purity-refresh gotcha:** `test-portable-purity.sh --refresh` reads **tracked files only** (`git ls-files`), so `git add` a new skill or rule doc before refreshing the baseline; refreshing while the file is untracked silently misses it, and CI catches it later.
