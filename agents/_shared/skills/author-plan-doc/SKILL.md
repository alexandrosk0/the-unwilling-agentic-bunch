---
name: author-plan-doc
description: Author a new plan-doc at docs/plans/active/<slug>.md from a one-line request — copy the template, set the slug to the basename, fill every section (N/A — <reason>, never delete) including Interface contracts, Implementation handoff and Open questions, run the pre-seal probes on Files to modify (files exist, named symbols and build variables resolve, interface targets are linked, split closure, regex budgets probed), include the Perf-review-system-gates section when the diff would touch the project's perf-gated core source tree, keep the three mandatory Verification/Out-of-scope items the template bakes in (doc-validation suite, grill-with-docs stress-test, deferral residue-sweep), then git add + wip(plan) commit immediately (working-tree-only plans are lost on checkout). Use when the user says "write a plan", "draft a plan", "new plan", "plan for X", "plan this", "spec this out", or before delegating a multi-step implementation slice. Calls the architect agent for a design that spans 2+ subsystems. The authoring counterpart to grill-with-docs (the stress-test). Read-write — creates + commits the plan file.
version: 3
---

# author-plan-doc

The invocation shortcut for the most-repeated structured procedure in the
project: authoring a template-conformant plan-doc. The rules it encodes live in
[`docs/agent-rules/process-rules.md`](../../../../docs/agent-rules/process-rules.md)
§ Plan-doc family / Plan-doc safety / Plan template and
[`docs/plans/active/_plan-template.md`](../../../../docs/plans/active/_plan-template.md);
this skill drives them in one shot. It is the *authoring* counterpart to
[`grill-with-docs`](../grill-with-docs/SKILL.md) (the *stress-test*) — together
they bracket the plan lifecycle: author → grill → ship → revise (PR-only).
Generic probes live here; the project's own specifics (its interfaces, build
wiring, split precedents, risk list) live in the template's section guidance.

## When

- User says "write a plan" / "draft a plan" / "new plan" / "plan for X" / "plan this".
- Any non-trivial work that § Project rules requires a plan-doc for, before implementation starts.
- Before delegating a multi-step implementation slice: the plan is the handoff packet's source.

## Steps

1. **Derive the slug.** Kebab-case, describes the work; the plan path is
   `docs/plans/active/<slug>.md`. The slug MUST equal the basename without `.md`
   (a doc-validation gate enforces this).
2. **Copy the template.** Start from `docs/plans/active/_plan-template.md` — never
   author from blank. Set the `> **Slug**:` line to the derived slug.
3. **Design first when it is cross-cutting.** If the change spans two or more
   subsystems (two leaf `AGENTS.md` directories) or changes a shared interface,
   spawn the `architect` agent with the request and paste its report into
   § Context (Goal), § Files to modify (Affected components), § Interface
   contracts, § Risks, § Implementation handoff and § Open questions. A change
   inside one subsystem skips the agent; fill those sections yourself.
4. **Fill every section.** Context, Approach, Interface contracts, Files to
   modify, Existing utilities reused, Extraction sizing, UX Pillar callouts,
   Perf gate, Risks / non-goals, Implementation handoff, Verification, Open
   questions, Out of scope. A section that does not apply gets
   `N/A — <one-line reason>` — **never delete a section** (the empty section is
   the forcing function that catches a skipped concern).
   - **Extraction sizing is mandatory when the plan EXTRACTS or SPLITS** an
     over-cap file (whale agent prompt, `AGENTS.md` section, long TU) into a sink:
     classify each chunk EXTRACT-vs-STAYS, state the projected post-extraction
     line count, confirm it clears the cap (250 / 150). `N/A — <reason>` when the
     plan extracts nothing.
   - **Three Verification/Out-of-scope items the template bakes in are MANDATORY —
     keep them in every plan** (they are the recurring plan-doc misses CodeRabbit
     flags via learned repo rules): (a) the **doc-validation** bullet enumerating
     the `test-docs.sh` suite; (b) the **`grill-with-docs` stress-test** bullet;
     (c) the **deferral residue-sweep** note under Out-of-scope. Fill them with
     the plan's specifics; never strip them.
   - Every Verification item maps to a test bucket (A–E, `test-authoring` skill);
     a step that is interactive today is bucket E with an explicit follow-up.
5. **Run the pre-seal probes** on § Files to modify and § Implementation handoff
   (§ Pre-seal probes below). Fix the table or the scope for every miss.
6. **Perf-gate section is mandatory** when the planned diff would touch the
   project's perf-gated core source tree (the `project.config.json` `lint.zones`
   / `perf` paths; the plan template marks which) — assert the PR-fast / Pillar-2-scanner / dispatcher-drain /
   bucket-E / marker-inventory state per `AGENTS.md` § Project rules. If the diff
   is pure-docs / agentic-shell / CI-config, say so and mark the gates N/A.
7. **Commit immediately** — `git add docs/plans/active/<slug>.md` then
   `git commit -m "wip(plan): <slug>"`. This is **mandatory, not optional**:
   working-tree-only plan files are silently lost on the next checkout
   (plan-doc-safety). Do the commit BEFORE handing off to grill-with-docs.
8. **Stress-test — required before finalising.** § Plan-doc family requires a
   `grill-with-docs` pass before a plan is final — mandatory, not optional. Keep
   the `grill-with-docs` Verification bullet (step 4) and run `grill-with-docs`
   to challenge the plan against the domain model + sharpen terminology before
   finalising.
9. **Post-ship is PR-only.** Note that § Implementation log / § Deviations /
   § Verification(actual) get filled after the work ships, via a PR (never a
   direct push to develop) — and in that SAME PR the plan's `> **Status**:`
   header is flipped to `shipped` AND the file is `git mv`'d active → shipped
   (the template's § Archive checklist). Both happen together once the post-ship
   sections are populated and all cited PRs are merged; the `git mv` is the step
   that historically drops off, so `plan-archival-owed.sh` nags at SessionStart
   for any `active/` plan already marked `shipped` but not moved.

## Pre-seal probes

Each probe costs seconds and saves the implementer a wiring round. Run them
before the plan is committed as final and before any slice is delegated.

- **Files exist.** Glob every production source file the plan names and confirm
  it lives at the stated path. A renamed, moved or aliased file otherwise costs
  the implementer a cross-walk per phase before it can even record a deferral.
- **Named symbols and build variables resolve.** For every symbol named as a
  caller or definer, `git grep -nF -- "<symbol>"`: zero hits means it was renamed,
  removed or never landed — fix the table or the scope. For every build-list
  variable named as the target of a list edit, grep the build files that define
  it: when the variable is populated by a recursive glob, no list edit is needed
  — drop the row. Mechanical form: `bash agents/scripts/core/plan-doc-table-probe.sh <plan>`
  checks every row of a `File-level changes` table (Symbol / CMake variable
  columns; exit 1 on any miss; self-test `test-plan-doc-table-probe.sh`).
- **Interface targets are linked.** For every header-only / `INTERFACE` library
  the plan adds, name at least one consumer that links it. A shim nothing links
  propagates none of its compile definitions, and the gap stays invisible until a
  later phase compiles against it. No consumer named → the plan is incomplete.
- **Split closure.** When a slice splits one large source file into several,
  state the closure rule — "everything `<target-fn>` calls that is not already in
  another translation unit goes to `<bucket>`" — instead of enumerating symbols
  from memory: enumeration misses transitive callees (export builders, modal
  helpers). Then require the new internal header to replicate every non-self
  include of the original file; includes that lived only in the original are
  silent until the build breaks.
- **Pure-helper split.** When the unit under test keeps pure helpers in an
  anonymous namespace inside a file whose includes pull heavy dependencies
  (network, database, UI, engine headers), pre-authorise the production-side split
  in the write set: the helpers move to a new `<Unit>Pure` (or `<Unit>Parse`)
  header + source pair in a named namespace, the original file keeps its call
  sites through `using` declarations, and the new pair includes none of the heavy
  headers (verify with a grep guard). Without that pre-authorisation an
  auto-mode classifier denies the split as out of scope. The template names the
  project's paths and precedents.
- **Regex budgets are probed, not guessed.** Before pinning a size or latency
  number on a `std::regex` path (a ReDoS sentinel, say), run a 4-point probe —
  256 B / 512 B / 1 KiB / 2 KiB — on the standard library of every toolchain
  that compiles that code. Backtracking implementations differ by orders of
  magnitude between standard libraries and can recurse deep enough to overflow
  the stack on input of a few KiB, so a guessed budget ships unachievable.

## Out of scope

- Stress-testing the plan (that's `grill-with-docs`).
- Designing a cross-cutting change from scratch (that's the `architect` agent; this skill persists its report).
- Implementing the plan (that's the orchestrator).
- Authoring a plan blank or skipping the immediate commit — both are failure modes
  this skill exists to prevent.
- Stripping the three mandatory Verification / Out-of-scope items (doc-validation
  suite, `grill-with-docs` stress-test, deferral residue-sweep) — they are baked
  into the template on purpose and are the recurring plan-doc misses.
