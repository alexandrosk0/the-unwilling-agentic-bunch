# coderabbit-triage — reference recipes

The copy-paste mechanics for [`SKILL.md`](SKILL.md); the judgement (what each finding is, whether it is rejected, where it routes) lives there. Section names match SKILL.md's citations.

## Fetch

Run the three REST fetches in parallel and capture each to its file — never stream them into a UI. `--slurp` makes `--paginate` emit one valid JSON array (of pages) instead of a concatenated stream of arrays:

```bash
PR=<num>; OWNER_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
gh api "repos/$OWNER_REPO/pulls/$PR/reviews"   --paginate --slurp > .triage-reviews.json
gh api "repos/$OWNER_REPO/pulls/$PR/comments"  --paginate --slurp > .triage-review-comments.json
gh api "repos/$OWNER_REPO/issues/$PR/comments" --paginate --slurp > .triage-issue-comments.json
```

A `gh` older than 2.40 has no `--slurp`: use `--paginate --jq '.[]' | jq -s '.'` instead. The three dumps are gitignored; delete them once the report is out so `git status` stays quiet.

**Thread state** (the `stale` validation state: resolved or outdated) exists only in GraphQL:

```bash
gh api graphql -F owner="${OWNER_REPO%/*}" -F name="${OWNER_REPO#*/}" -F pr="$PR" -f query='
query($owner:String!, $name:String!, $pr:Int!) {
  repository(owner:$owner, name:$name) { pullRequest(number:$pr) {
    reviewThreads(first:100) { pageInfo { hasNextPage endCursor }
      nodes { id isResolved isOutdated path line
        comments(first:1) { nodes { databaseId author { login } } } } } } } }'
```

A thread's first comment `databaseId` equals the REST review-comment `id`, which joins the two. `hasNextPage: true` → re-run with `reviewThreads(first:100, after:"<endCursor>")`. The thread `id` is what `resolveReviewThread` takes.

## Body-shape markers

**CodeRabbit** tags severity with emoji — 🛠️ actionable · ⚠️ caution · 💡 nit · 🧹 chore (read literally) — and heads its summary review `_Actionable comments posted: N_` / `_Nitpick comments (N)_`. In the review body it groups findings per file as `` In `@<file>`: `` followed by `- Around line N-M: <finding>` bullets; that is the shape `coderabbit-triage.py` parses.

**Cursor Bugbot** opens each inline finding with a `### <title>` heading, then a `**<Sev> Severity**` line (e.g. `**Medium Severity**`), then a `<!-- DESCRIPTION START -->` marker. Its summary review carries `<!-- BUGBOT_REVIEW -->`, "found N potential issues" and `<!-- BUGBOT_FIX_ALL -->`. Bugbot filters its inline findings to High and Medium and never requests changes, so its summary review is always `COMMENTED` ([`merge-gates.md`](../../../../docs/agent-rules/merge-gates.md) gate 4).

## Report template

Paths, areas and symbols below are illustrative; take the real ones from the PR and the area map.

```text
## Triage table
| # | file:line | severity | applies? | target | reason / rule |
|---|-----------|----------|----------|--------|---------------|
| 1 | src/net/Client.cpp:123 | High | yes | area:net (src/net/AGENTS.md) | direct socket call bypasses the typed client; route fix |
| 2 | src/net/include/Cache.h:42 | Medium | no (override #1) | — | suggestion used `std::optional`; C++14 hard |
| 3 | src/ui/Panel.cpp:88 | Low | superseded | — | rewritten in commit abc1234 |
| 4 | src/ui/Panel.cpp:140 | Nit | stale | — | thread already resolved |
...

## Findings

### #1 — High · `src/net/Client.cpp:123` → area:net
**Bot body (verbatim, trimmed):**
> <quoted summary, at most 4 lines>

**Validation:** live — `Client::Save` still calls the socket API directly at line 127 instead of the typed client.

**Handoff packet:**
- **Scope**: replace the direct call in `Client::Save` with the typed client's `Post`, run on the existing worker thread; marshal the result back to the main thread.
- **Allowed write set**: `src/net/Client.cpp`, `src/net/include/Client.h`.
- **Out of scope**: every other file in the area; do NOT touch the shared interface headers.
- **Read first**: `src/net/AGENTS.md` (the route's docs).
- **Invariant pre-decisions**: the typed-client chokepoint holds (override #7 checked — the finding enforces it, it is not rejected); UI-thread non-blocking (Pillar 2).
- **Verification**: the existing `Client` unit tests cover the call shape — no new test. Manual: none.
- **Reply to bot** (post once the fix lands): `Addressed in <sha>; routed through the typed client as suggested.`

### #2 — Medium · `src/net/include/Cache.h:42` → REJECTED (override #1)
**Bot body:** suggests `std::optional<Entry>` for the return type.
**Reason:** C++14 hard (`AGENTS.md` § Project rules); the nullable-pointer return is the intended contract.
**Reply to bot:** `Not applicable — this repo is C++14-hard and std::optional is banned; the nullable-pointer return is intentional.`

...

## Outcome: applied

## Session context append
- <decision locked this round, with file:line evidence>

## Self-improvement
- <empty is fine>
```

A REJECT-AMBIGUOUS finding (the bot gave too little to act on) gets the REJECTED block shape with the reason `ambiguous — <what is missing>`.

## Watcher dispatch

1. **The watcher** spawns `claude -p` with `AUTO_ACT_PROMPT` (the literal text is in `agents/scripts/core/merge-watcher.py`) when a PR is blocked on CodeRabbit findings. Spawning needs `MERGE_WATCH_AUTO_ACT=true` (off by default: token spend and runaway-loop risk), fires at most once per (PR, head sha), stays within the per-PR budget `MERGE_WATCH_AUTO_ACT_BUDGET`, and refuses when `claude` is not on PATH or the clone has modified tracked files. The prompt carries PR metadata only (`pr`, `owner`, `repo`, `head_sha`, `budget`, `attempt`).
2. **The spawned session** checks out the PR, loads this skill and runs the triage phase, fetching per § Fetch: VALID packets name their area and docs; REJECT-INVARIANT and REJECT-AMBIGUOUS findings carry their rationale.
3. It applies each VALID packet after reading the route's docs, and skips every REJECT finding, listing its rationale in the commit body.
4. It commits and pushes once every fix has landed. If the PR head moved since dispatch, it stops without committing.
5. **The watcher** re-polls on its next cycle; CodeRabbit re-reviews the new head and the merge gates decide.
6. Once the new head's poll shows CodeRabbit no longer blocking, the watcher resolves the CodeRabbit-authored, non-outdated, unresolved threads still open on earlier commits (`maybe_resolve_stuck_cr_threads`, one GraphQL `resolveReviewThread` per thread; on by default, `MERGE_WATCH_RESOLVE_CR_THREADS=false` opts out). Those threads would otherwise keep the CodeRabbit gate's open-thread count above zero and wedge the merge ([`merge-gates.md`](../../../../docs/agent-rules/merge-gates.md) gate 2).

Separately, when the gates are BLOCKED on CodeRabbit findings, the watcher runs `coderabbit-triage.py post-comment <owner> <repo> <pr>`, which posts the regex classifier's advisory report (VALID / REJECT-INVARIANT / REJECT-AMBIGUOUS); `MERGE_WATCH_TRIAGE_BUDGET` caps those posts per head sha. A failing sanitizer job takes `AUTO_ACT_SANITIZER_PROMPT` instead and skips this skill.
