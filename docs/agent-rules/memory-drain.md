# Weekly memory drain

The memory-drain process (cadence, the three verdicts, verify-before-trust, the after-sweep steps) lives in the [`drain-memory`](../../agents/_shared/skills/drain-memory/SKILL.md) skill; the SessionStart nudge `agents/scripts/core/memory-drain-nudge.sh` points there with `/drain-memory`. Auto-memory is a Claude Code feature, so the skill is the single home. This file keeps the drain log, which the skill's last step appends to.

## History

- 2026-05-30 — bootstrap drain. 6 items → 2 implemented, 1 backlogged, 3 tossed.
  Implemented `feedback-auto-launch-exe` (→ `ship-loops.md`) +
  `project-watcher-janitor-branch-swap` (→ `process-rules.md`). Backlogged
  `project-bats-gh-stub-windows` (→ tooling). Tossed `project-unreal-msvc-toolset`
  (guarded in code, PR #508), `project-python3-stub-windows` (machine-specific),
  and `project-build-vcvars-toolset` (still guarded on develop — `with-msvc-env.sh`
  reads `msvc_toolset_pin: 14.38` from `project.config.json`). **Verify-first
  lesson**: an initial read of `with-msvc-env.sh` showed the pin missing and the
  item was wrongly filed as an infra regression; the read had landed on a
  watcher-swapped sibling branch, not develop. Always `git show origin/develop:<file>`
  to verify, never trust the local working tree mid-session (see the very
  `project-watcher-janitor-branch-swap` rule this drain implemented).
- 2026-06-01 — second drain. 8 items → 8 implemented, 0 backlogged, 0 tossed
  (all verified against the tree first; none stale). Implemented into
  `process-rules.md` (concurrent-worktree isolation incl. never `git add -A`,
  leave-worktree-until-merged, verify-layout-before-path-edits via `git ls-files`,
  re-verify-after-tool-batch-cancel-cascade), `ship-loops.md` (ship+auto-register
  standing default with menu suppressed, register-only-after-every-commit-pushed),
  and `AGENTS.md` (light build for core-feature work, Unreal-build lib-only cleanup).
  Shipped in PR #685. **Process note**: the Unreal-cleanup item was first written
  into `process-rules.md` but tripped `test-portable-purity` (its Unreal/DX-target
  path literals may not leak into the portable `docs/agent-rules/` layer);
  relocated to `AGENTS.md` (project-root doc, not purity-scanned) — project-specific
  literals belong outside the portable agentic layer.
