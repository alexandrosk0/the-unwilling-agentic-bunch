# Security surface — the agent layer's own trust boundaries

**When to read this file**: a diff touches the prompt-capture hook or the intent redactor, the merge watcher's notify path, or the host app's notify receiver; or you are running `security-review` (it reads this file on every run). The host app's own attack surface (its network listeners, CLI, scripting, external clients) lives in the project's attack-surface map, which the project's review checklist (`project.config.json` → `docs.review_checklist`) links under § Security.

These surfaces guard layer code, so their review contract lives with the layer and travels to every host.

## Intent-capture pipeline

`docs/harness/claude-code/hooks/capture-intent.sh` → `agents/scripts/core/redact-intent.py` → the gitignored `.session-intent/<branch>.log` → the PR body's `## Intent` section. A raw user prompt flows toward an eventually PUBLIC PR body. A change to either script must preserve all four guarantees:

1. **Secret exfiltration** (raw prompt → redactor → public PR). `redact-intent.py` is the boundary: greedy named-format, high-entropy and userinfo / username sweeps; fail-safe means over-redact, never under-redact; its `--selftest` case suite must stay green and gain a case for every new class. A new value or authority class belongs IN the redactor, never bolted on at a call site.
2. **Path traversal through the branch name.** The log filename is `<branch>.log`; `capture-intent.sh` neutralises the branch with `tr -c 'A-Za-z0-9._-' '-'` (slashes become `-`), and git itself bans `..` in refnames. Any new filename construction keeps that allow-list transform.
3. **Log / line injection.** The appended line is `- $REDACTED`, and the redactor collapses whitespace runs (`\s+` → one space) so an embedded newline cannot forge a second entry. A new emitter keeps the single-line guarantee.
4. **Fail-open.** A missing interpreter or a redactor crash MUST write nothing, never the raw prompt: `capture-intent.sh` emits only the redacted value and writes nothing when it is empty. Flag any path that could emit the raw `$PROMPT`.

## Merge-watcher notify endpoint

The merge watcher (`agents/scripts/core/merge-watcher.py`) reports PR state through its notify client script in `agents/scripts/core/`, which POSTs `{pr, state, message, pr_url}` to the host app's localhost receiver (`/merge-watch/notify`) and falls back to a native toast or a log file. The receiver is the host's code; this is the contract every host receiver meets, and a review of either side checks it:

1. **Loopback-only bind, hard-coded.** The receiver binds `127.0.0.1` with no environment or config override and is unreachable from other hosts. A bug here exposes the in-app toast surface to the network.
2. **Payload validated before it reaches the UI.** A bounded JSON parse; `pr` an integer, `state` one of a fixed allow-list, `message` a string; anything else is a 400 with an input-free error body.
3. **Message text sanitised.** Control characters are stripped and the length capped. The toast renderer draws text verbatim, so no markup escaping is needed today; a renderer that starts interpreting markup (HTML, markdown) adds escaping in the same change, because watcher messages carry CodeRabbit finding bodies full of markdown.
4. **No subprocess execution from the payload.** The endpoint may only post a toast append to the UI thread — never exec or shell out.
5. **Sanitizer build mandatory** for the receiver code path (UX Pillar 3, never crash).

## Pointers

- The review agent that applies this file: `agents/core/security-review.md`.
- The pipeline's documentation and hook wiring: `docs/harness/claude-code/hooks/capture-intent.sh` (header comment) and the PR-intent check `agents/scripts/core/check-pr-intent.sh`.
