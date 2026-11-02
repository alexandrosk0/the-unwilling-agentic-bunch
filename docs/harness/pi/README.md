# pi (earendil-works/pi-coding-agent) — adapter

How the canonical agents — the layer's three in `agents/core/*.md` (`architect`,
`code-review`, `security-review`), plus a host project's own `agents/project/*.md`
when it has any — are made loadable by **pi**'s subagent extension, and the two
mismatches the adapter resolves. pi does not discover the skills under
`agents/_shared/skills/`: it reaches each one through its row in the on-demand
table in `AGENTS.md` § Project rules.

## TL;DR — bring-up

```bash
bash agents/scripts/core/setup-harness.sh pi
```

That command (idempotent, like the other harness adapters) does two things under
the **gitignored** `.pi/` dir (regenerated, never committed — same model as
`.claude/` / `.codex/` / `.cursor/`):

1. **`.pi/agents/*.md`** — pi-native agent files generated from
   `agents/{core,project}/` by `agents/scripts/core/gen-pi-agents.py`.
2. **`.pi/extensions/subagent/`** — the stock pi subagent example, copied from
   your installed pi package and **patched** so this trusted repo's project
   agents load without a per-call opt-in.

Then just run `pi` from the repo root and delegate (e.g. *"Use code-review on the
current branch diff"*, or a workflow prompt). Agents are discovered fresh each
invocation, so re-running setup after editing a canonical agent picks it up.

## The two mismatches it fixes

### 1. Project agents off by default (security)
pi's subagent tool defaults to `agentScope:"user"` (only `~/.pi/agent/agents`)
and prompts for confirmation before running any project-local agent. The adapter
copies the extension to the auto-discovered, hot-reloadable `.pi/extensions/`
and patches three defaults in `index.ts`:

| default | stock | patched |
|---|---|---|
| `params.agentScope ?? …` (execute) | `"user"` | `"both"` |
| `params.confirmProjectAgents ?? …` | `true` | `false` |
| `args.agentScope ?? …` (render label) | `"user"` | `"both"` |

This relaxed default is **only** safe because this is a trusted repo, and it
stays scoped to this repo's `.pi/` — it never leaks to other repos. To keep the
confirmation prompt, re-add `confirmProjectAgents: true` (or revert that sed line
in the script and re-run).

### 2. Format + directory mismatch
The canonical agents are Claude-Code-shaped: nested `core/` + `project/` dirs,
`capabilities:` tags, `harness-hints:`, `triggers:`.
pi discovers a **flat** `.pi/agents/*.md` and its parser reads only
`name` / `description` / `tools` / `model`. The generator bridges this:

- **flattens** `core/` + `project/` into `.pi/agents/`.
- **`description`** re-emitted as a quoted YAML scalar (pi uses a real YAML
  parser; unquoted colons/backticks would break it).
- **`capabilities:` → `tools:`** via the capability-adapter table (the **pi**
  column in [`../capability-adapter.md`](../capability-adapter.md)). Read-only
  agents (no `file-edit`/`file-write` capability) therefore never receive
  `edit`/`write` tools — the read-only contract is enforced by tool scoping, not
  just prose.
- **`model:`** resolved from a tier→pi-model map (see below); unmapped ⇒ omit so
  the subagent inherits your default pi model.
- the **body** (system prompt, the `## Outcome:` output contract) passes
  through unchanged — pi won't *enforce* the extra frontmatter, but the prose
  rules still steer the subagent.

## Model tiers

Canonical agents carry a tier (`opus`/`sonnet`/`haiku`) under
`harness-hints.claude-code.model`. The generator leaves `model:` **off** for an
unmapped tier, so the subagent runs on your configured default pi model. The
committed map leaves `opus` empty on purpose: the three agents run the session's
model, so pi inherits your default instead of pinning an ageing ID (pi's default
provider may not be Anthropic either). `sonnet` / `haiku` stay mapped for an
explicitly cheaper spawn of mechanical work. To change a tier, either:

- edit `docs/harness/pi/model-map.json` (committed) — set `opus`/`sonnet`/`haiku`
  to concrete pi `--model` patterns (e.g. `"anthropic/claude-sonnet-4-5"`), or
- export `PI_MODEL_OPUS` / `PI_MODEL_SONNET` / `PI_MODEL_HAIKU` before setup
  (env overrides the file), or
- add an explicit `harness-hints.pi.model:` to a canonical agent (a value with a
  `/` is used verbatim as a pi pattern).

Re-run `bash agents/scripts/core/setup-harness.sh pi` after any change.

## Notes / limits

- pi has no semantic-code-search or file-skeleton tool, so those capabilities map
  to `grep`/`read` fallbacks (degraded but workable — more round-trips).
- `web-fetch` is dropped (no pi built-in web tool here).
- `.pi/` is gitignored; never hand-edit `.pi/agents/*.md` (each carries a
  GENERATED banner) — edit the canonical agent file and re-run.
- If the pi package can't be auto-located, set `PI_PACKAGE_DIR=<path>` and re-run;
  the agent files are still generated regardless.
