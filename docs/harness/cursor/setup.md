# Cursor adapter

Generated locally at `.cursor/rules/agents.mdc` by:

```bash
bash agents/scripts/core/setup-harness.sh cursor
```

Idempotent. The script never overwrites a user-modified rule file. A rule file that is an unmodified copy of an earlier shipped template is upgraded.

If your `.cursor/rules` already exists as a single file (some tools write to it directly), the setup script will refuse to clobber it and print a fix-it message. Move it aside (`mv .cursor/rules .cursor/rules.bak`) and re-run to switch to the `.mdc`-rules layout.

## What it does

Cursor auto-loads `.mdc` files from `.cursor/rules/` and applies them based on the rule's frontmatter (globs + `alwaysApply`). The shipped `agents.mdc` template:

- Sets `alwaysApply: true` so the rule is always in context.
- Points Cursor at `AGENTS.md` (project rules + delegation table) and the agent definitions: the layer's `agents/core/*.md`, plus a host project's own `agents/project/*.md`.

That's the whole adapter — Cursor's built-in file-search + the rule's pointer are enough for the agent files to be discovered.

## Template source

`docs/harness/cursor/rules/agents.mdc` — edit there to change the project default. Edits to `.cursor/rules/agents.mdc` after setup are local-only.

The template is rendered, not copied. `{{AGENT_LAYER}}` becomes the agent layer's path from the project root: empty in a standalone layer checkout, `agent-layer/` in a host that mounts the layer as a submodule. Write every layer path in the template with that prefix; a host's own paths (`AGENTS.md`, `agents/project/`) take none.

## Refreshing after a `git pull`

Re-run `bash agents/scripts/core/setup-harness.sh cursor`. The script renders the template only if you haven't locally modified `.cursor/rules/agents.mdc`; an unmodified copy of an earlier shipped template counts as unmodified and is upgraded.

## Removing the adapter

```bash
rm -rf .cursor
```

Safe — fully regenerable via the setup script.
