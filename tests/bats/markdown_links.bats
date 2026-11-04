#!/usr/bin/env bats
# tests/bats/markdown_links.bats
# ----------------------------------------------------------------------------
# Bats coverage for agents/scripts/core/test-markdown-links.sh.
#
# Why this lint exists: sed-based path renames routinely update body text but
# miss `[label](href)` link hrefs when the label happens to match the path.
# PRs #496 + #497 each shipped with 3-4 CR-caught broken-href findings of
# exactly this shape; this lint catches them mechanically before push. Also
# covers #fragment anchors resolved by GitHub's slug rules (rule 3) and the
# subsystem leaves scanned from a host fixture (rule 7).
# ----------------------------------------------------------------------------

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    export REPO_ROOT
    export LINT="$REPO_ROOT/agents/scripts/core/test-markdown-links.sh"
    FIXTURE_DIR="$(mktemp -d)"
    export FIXTURE_DIR
    # Resolve a WORKING python interpreter (bats-coverage-01): a bare `python3`
    # matches the Windows WinStore alias which passes `command -v` but exits 49
    # on exec, red-walling 5/7 of these tests. Exec-validate each candidate and
    # skip cleanly when none runs (mirrors agent_size.bats).
    PY=""
    for c in python3 python py; do
        if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then PY="$c"; break; fi
    done
    export PY
    [ -n "$PY" ] || skip "no working python interpreter"
}

teardown() {
    rm -rf "${FIXTURE_DIR:-}"
}

# ---------- env-gate ----------

@test "SMATCHET_SKIP_MARKDOWN_LINK_CHECK=1 bypasses and exits 0" {
    SMATCHET_SKIP_MARKDOWN_LINK_CHECK=1 run bash "$LINT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SMATCHET_SKIP_MARKDOWN_LINK_CHECK=1"* ]]
    [[ "$output" == *"Passed: 0  Failed: 0"* ]]
}

# ---------- broken-link detection (inline Python with isolated REPO_ROOT) ----------

@test "broken relative link is flagged" {
    # Set up a fixture under the bats temp dir. Use cygpath on Windows to give
    # Python a path it can chdir to (MSYS /tmp/... isn't visible to native python3).
    mkdir -p "$FIXTURE_DIR/docs"
    cat > "$FIXTURE_DIR/docs/broken.md" <<'MD'
# Broken

See [missing target](./does-not-exist.md) for context.
MD
    PY_FIXTURE_DIR="$FIXTURE_DIR"
    if command -v cygpath >/dev/null 2>&1; then
        PY_FIXTURE_DIR="$(cygpath -w "$FIXTURE_DIR")"
    fi
    # Assert the regex + path-resolve mechanics directly.
    run "$PY" -c "
import os, re
os.chdir(r'$PY_FIXTURE_DIR')
text = open('docs/broken.md').read()
LINK_RE = re.compile(r'(?<!\!)\[[^\]]*\]\(([^)\s]+)\)')
for m in LINK_RE.finditer(text):
    href = m.group(1)
    if href.startswith(('/', 'http://', 'https://', '#')): continue
    href_path = href.split('#', 1)[0]
    target = os.path.normpath(os.path.join('docs', href_path))
    if not os.path.exists(target):
        print(f'BROKEN: {href} -> {target}')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"BROKEN: ./does-not-exist.md"* ]]
}

@test "absolute / external / anchor links are NOT flagged" {
    run "$PY" -c "
import re
LINK_RE = re.compile(r'(?<!\!)\[[^\]]*\]\(([^)\s]+)\)')
hrefs = ['/abs/path.md', 'https://example.com', 'http://a.b', 'mailto:x@y',
         '#section', 'ftp://server/file']
flagged = 0
for h in hrefs:
    if not h.startswith(('/', 'http://', 'https://', 'mailto:', '#', 'ftp://', 'file://', 'data:')):
        flagged += 1
        print(f'BUG: {h} not skipped')
print(f'flagged={flagged}')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"flagged=0"* ]]
}

@test "image links (![alt](path)) are NOT flagged" {
    run "$PY" -c "
import re
text = '![image](missing.png)\n[regular](missing.md)'
LINK_RE = re.compile(r'(?<!\!)\[[^\]]*\]\(([^)\s]+)\)')
hits = [m.group(1) for m in LINK_RE.finditer(text)]
print('hits:', hits)
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"hits: ['missing.md']"* ]]
    [[ "$output" != *"missing.png"* ]]
}

@test "line-anchor suffix (path:NNN) is stripped before existence check" {
    run "$PY" -c "
import re, os
hrefs = ['Source/Core/include/Foo.h:58', 'Source/Core/src/Bar.cpp:123:7', 'Plain.md']
for h in hrefs:
    m = re.match(r'^(.*?):\d+(?::\d+)?$', h)
    stripped = m.group(1) if m else h
    print(f'{h} -> {stripped}')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Source/Core/include/Foo.h:58 -> Source/Core/include/Foo.h"* ]]
    [[ "$output" == *"Source/Core/src/Bar.cpp:123:7 -> Source/Core/src/Bar.cpp"* ]]
    [[ "$output" == *"Plain.md -> Plain.md"* ]]
}

# ---------- exclude archived plan dirs ----------

@test "docs/plans/shipped/ is excluded from default scan (was docs/design/archive/)" {
    run "$PY" -c "
import os
EXCLUDED = ('docs/plans/shipped',)
def is_active_md(rel_in):
    if not rel_in.endswith('.md'): return False
    rel = rel_in.replace(os.sep, '/')
    parts = rel.split('/')
    if parts[0] in ('AGENTS.md', 'BUILD.md', 'README.md') and len(parts) == 1: return True
    if parts[0] not in ('docs', 'agents'): return False
    for p in EXCLUDED:
        if rel == p or rel.startswith(p + '/'): return False
    return True
print('active:', is_active_md('docs/plans/active/foo.md'))

print('shipped excluded:', is_active_md('docs/plans/shipped/baz.md'))
print('agents:', is_active_md('agents/whatever.md'))
print('root agents.md:', is_active_md('AGENTS.md'))
print('src:', is_active_md('Source/Core/foo.md'))
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"active: True"* ]]
    
    [[ "$output" == *"shipped excluded: False"* ]]
    [[ "$output" == *"agents: True"* ]]
    [[ "$output" == *"root agents.md: True"* ]]
    [[ "$output" == *"src: False"* ]]
}

# ---------- widened target set + baseline (gate-blind-spot-sweep Slice 3) ----------

@test "the remaining root-level docs are IN the target set" {
    # Rule 5's target list and is_active_md()'s root-file tuple must agree — the
    # header is the documented contract. cli.md carried two dangling links for the
    # entire time it sat outside the scan, which is why this parity check exists.
    for f in AGENTS.md BUILD.md README.md AI_POLICY.md CONTEXT-MAP.md; do
        grep -q "\"$f\"" "$LINT" || {
            echo "is_active_md() does not list $f" >&2
            return 1
        }
        grep -q "$f" <(sed -n '1,45p' "$LINT") || {
            echo "rule 5 header does not document $f" >&2
            return 1
        }
    done
}

@test "the relocated guides and audit reports are covered via the docs/ branch" {
    # The root-declutter move put the user-facing guides under docs/guides/ and the
    # dated audit reports under docs/audits/, so they no longer need a root-file
    # tuple entry — is_active_md() matches them on parts[0] == 'docs'. This asserts
    # they really are under docs/ (a move back to the root without a matching tuple
    # entry would silently drop them out of the scan, the exact Slice 3 regression).
    # These are the consuming product's docs; a standalone agent layer has none.
    [ -d "$REPO_ROOT/Source" ] || skip "product docs not present (standalone agent layer)"
    for f in docs/guides/cli.md docs/guides/lua.md docs/guides/mcp.md \
             docs/audits/SECURITY_AUDIT.md docs/audits/CPP_CODE_AUDIT.md \
             docs/audits/AGENTIC_INFRA_AUDIT.md docs/audits/UX_DESIGN_CRITIQUE.md \
             docs/audits/TEST_COVERAGE_GAP_MAP.md docs/audits/MUTATION_PILOT.md; do
        [ -f "$REPO_ROOT/$f" ] || {
            echo "$f is not where the docs/ branch of is_active_md() expects it" >&2
            return 1
        }
    done
}

@test "the scanner actually walks docs/guides/ and docs/audits/, not just the file-existence check above" {
    # The file-existence test above passes even if is_active_md() stops scanning
    # docs/** entirely — it only proves the files are on disk, not that the scanner
    # sees them. Exercise $LINT --all for real, on an isolated fixture (same
    # copied-script idiom as the --all tests below), with a dangling link planted
    # in each relocated directory, and assert both are actually flagged.
    mkdir -p "$FIXTURE_DIR/agents/scripts/core" "$FIXTURE_DIR/docs/guides" "$FIXTURE_DIR/docs/audits"
    cp "$LINT" "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh"
    printf '# Guide\n\nSee [gone](./nope-guide.md).\n' > "$FIXTURE_DIR/docs/guides/cli.md"
    printf '# Audit\n\nSee [gone](./nope-audit.md).\n' > "$FIXTURE_DIR/docs/audits/SECURITY_AUDIT.md"

    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 1 ]
    [[ "$output" == *"docs/guides/cli.md"*"nope-guide.md"* ]]
    [[ "$output" == *"docs/audits/SECURITY_AUDIT.md"*"nope-audit.md"* ]]
}

@test "--all passes on the real repo using the committed baseline" {
    # --all must be usable as a gate: without the baseline, widening the target set
    # would have meant burning down the pre-existing links first. The --baseline
    # WRITE path is exercised by the round-trip test below, not here.
    run bash "$LINT" --all
    [ "$status" -eq 0 ]
    [[ "$output" == *"Passed:"* ]]
    [ -f "$REPO_ROOT/docs/high-integrity/markdown-link-baseline.md" ]
}

@test "--all grandfathers a baselined link but still FAILS on a new one" {
    # End-to-end on the REAL script. It re-anchors with
    # `cd "$(dirname "$0")/../../.."`, so the copy has to sit at the same depth
    # inside the fixture for that to land on the fixture root instead of the repo.
    mkdir -p "$FIXTURE_DIR/agents/scripts/core" "$FIXTURE_DIR/docs/high-integrity"
    cp "$LINT" "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh"
    printf '# a\n\n[old](missing-old.md)\n[new](missing-new.md)\n' > "$FIXTURE_DIR/docs/a.md"
    {
        printf '# Dangling markdown links — grandfathered baseline\n\n'
        printf '## dangling links (1)\n'
        printf -- '- `docs/a.md` — `missing-old.md` (resolves to `docs/missing-old.md`)\n'
    } > "$FIXTURE_DIR/docs/high-integrity/markdown-link-baseline.md"

    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 1 ]
    [[ "$output" == *"missing-new.md"* ]]
    [[ "$output" != *"BROKEN_LINK: 'missing-old.md'"* ]]
    [[ "$output" == *"1 grandfathered"* ]]
}

# Diff scope in a fixture repo: a.md is on origin/develop with one baselined
# dangling link, then a commit adds a second dangling link to the same file.
_diff_scope_fixture() {
    mkdir -p "$FIXTURE_DIR/agents/scripts/core" "$FIXTURE_DIR/docs/high-integrity"
    cp "$LINT" "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh"
    {
        printf '# Dangling markdown links — grandfathered baseline\n\n'
        printf '## dangling links (1)\n'
        printf -- '- `docs/a.md` — `missing-old.md` (resolves to `docs/missing-old.md`)\n'
    } > "$FIXTURE_DIR/docs/high-integrity/markdown-link-baseline.md"
    printf '# a\n\n[old](missing-old.md)\n' > "$FIXTURE_DIR/docs/a.md"
    git -C "$FIXTURE_DIR" init -q -b develop
    git -C "$FIXTURE_DIR" add -A
    git -C "$FIXTURE_DIR" -c user.name=t -c user.email=t@t.test commit -q -m base
    git -C "$FIXTURE_DIR" update-ref refs/remotes/origin/develop HEAD
    printf '[new](missing-new.md)\n' >> "$FIXTURE_DIR/docs/a.md"
    git -C "$FIXTURE_DIR" -c user.name=t -c user.email=t@t.test commit -q -am change
}

@test "diff scope in a standalone layer grandfathers a baselined link but FAILS a new one" {
    # The layer repo on its own (its config says profile agent-layer), where links
    # into the host cannot resolve.
    _diff_scope_fixture
    printf '{"profile": "agent-layer"}\n' > "$FIXTURE_DIR/project.config.json"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"BROKEN_LINK: 'missing-new.md'"* ]]
    [[ "$output" != *"BROKEN_LINK: 'missing-old.md'"* ]]
}

@test "diff scope in a host checkout still FAILS a baselined link in a touched file" {
    # No agent-layer profile, and no Source/ either (a sparse host checkout): touching
    # a file still means fixing its dangling links. The marker is positive, so a
    # missing directory cannot switch the stricter rule off.
    _diff_scope_fixture
    printf '{"project": {"name": "host"}}\n' > "$FIXTURE_DIR/project.config.json"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"BROKEN_LINK: 'missing-new.md'"* ]]
    [[ "$output" == *"BROKEN_LINK: 'missing-old.md'"* ]]
}

@test "the rendered baseline rows parse back (round-trip)" {
    # Regression guard: the row regex was once anchored at end-of-line while the
    # renderer appends "(resolves to ...)", so EVERY row failed to parse and --all
    # grandfathered nothing — while the baseline file itself looked perfectly fine.
    mkdir -p "$FIXTURE_DIR/agents/scripts/core" "$FIXTURE_DIR/docs"
    cp "$LINT" "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh"
    printf '# a\n\n[gone](missing-one.md)\n' > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --baseline
    [ "$status" -eq 0 ]
    [ -f "$FIXTURE_DIR/docs/high-integrity/markdown-link-baseline.md" ]
    # Written by --baseline, read back by --all: the whole point of the round trip.
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 grandfathered"* ]]
}

@test "an unknown argument is an infra error (exit 2), not a silent full scan" {
    run bash "$LINT" --definitely-not-a-mode
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown argument"* ]]
}

# ---------- diff scope default (smoke) ----------

@test "default mode runs without crash on the real repo (no diff = 0/0)" {
    # The repo's working tree state is whatever bats sees. The lint should
    # always return cleanly when SCOPE=diff and no markdown is in the diff
    # OR every diff-touched markdown's links resolve.
    run bash "$LINT"
    # Acceptable exits: 0 (clean) or 1 (real broken refs in current diff).
    # Either way it should NOT exit 2 (binary missing) or crash unexpectedly.
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
    [[ "$output" == *"Passed:"* ]]
    [[ "$output" == *"Failed:"* ]]
}

# ---------- inline code spans (tooling 2026-08-07) ----------
#
# Two halves of one blindness: a repo path written as a bare code span was never
# checked (so a backlog entry could cite a file that does not exist), and prose
# quoting LINK SYNTAX inside a code span was parsed as a real link and reported
# dangling. Teaching the tokenizer about code spans fixes both.

# Build a fixture repo with a real `origin/develop` ref — the code-span rule
# falls back to that tree, and stays SILENT when it cannot be resolved, so a
# git-less fixture would vacuously pass every warning assertion below.
_mk_span_repo() {
    mkdir -p "$FIXTURE_DIR/agents/scripts/core" \
             "$FIXTURE_DIR/docs/self-improvement/categories/tooling"
    cp "$LINT" "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh"
    git -C "$FIXTURE_DIR" init -q
    git -C "$FIXTURE_DIR" config user.email t@t
    git -C "$FIXTURE_DIR" config user.name t
    git -C "$FIXTURE_DIR" add -A
    git -C "$FIXTURE_DIR" commit -qm base
    git -C "$FIXTURE_DIR" update-ref refs/remotes/origin/develop HEAD
}

@test "a backlog code span citing a nonexistent repo path WARNs without failing" {
    _mk_span_repo
    printf -- '- entry\n\n  Proposal anchored on `scripts/dev/does-not-exist-xyz.sh` here.\n' \
        > "$FIXTURE_DIR/docs/self-improvement/categories/tooling/e.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]   # WARN-first: never changes the exit code
    [[ "$output" == *"WARN: code-span path 'scripts/dev/does-not-exist-xyz.sh'"* ]]
}

@test "a backlog code span citing a path that EXISTS draws no warning" {
    _mk_span_repo
    printf -- '- entry\n\n  Anchored on `agents/scripts/core/test-markdown-links.sh` which exists.\n' \
        > "$FIXTURE_DIR/docs/self-improvement/categories/tooling/e.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]
    [[ "$output" != *"WARN: code-span path"* ]]
}

# applied.md is the ARCHIVE of already-actioned entries: a path that has since
# moved is expected there and nobody will act on it. Without this exemption the
# real repo emits ~100 rows of noise that drown the live signal.
@test "applied.md is exempt from the code-span path rule" {
    _mk_span_repo
    printf -- '- old entry citing `scripts/dev/does-not-exist-xyz.sh`\n' \
        > "$FIXTURE_DIR/docs/self-improvement/categories/applied.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]
    [[ "$output" != *"WARN: code-span path"* ]]
}

# `Source/Core/.../Commands/Foo.h` is prose shorthand for "somewhere under",
# never a literal file — it cannot resolve and was never meant to.
@test "an ELIDED code-span path (...) draws no warning" {
    _mk_span_repo
    printf -- '- entry citing `Source/Core/.../Commands/PathConfinement.h` loosely\n' \
        > "$FIXTURE_DIR/docs/self-improvement/categories/tooling/e.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]
    [[ "$output" != *"WARN: code-span path"* ]]
}

# The false-positive half: a doc that needs to DISCUSS link syntax had to
# describe it in words, because a link-shaped code span was checked as a link.
@test "link-shaped text inside a code span is not parsed as a link" {
    mkdir -p "$FIXTURE_DIR/agents/scripts/core" "$FIXTURE_DIR/docs"
    cp "$LINT" "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh"
    printf '# a\n\nThe checker matches `[label](some-missing-target.md)` shaped text.\n' \
        > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]
    [[ "$output" != *"BROKEN_LINK"* ]]
}

# A REAL link whose label happens to be a code span must still be checked —
# blanking spans must not blind the checker to the href half.
@test "a real link with a code-span label is still checked" {
    mkdir -p "$FIXTURE_DIR/agents/scripts/core" "$FIXTURE_DIR/docs"
    cp "$LINT" "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh"
    printf '# a\n\nSee [`docs/gone.md`](gone-missing-target.md) for detail.\n' \
        > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 1 ]
    [[ "$output" == *"BROKEN_LINK: 'gone-missing-target.md'"* ]]
}

# The common case the entry calls out: an entry and the file it cites land in
# the SAME PR. That path is in the worktree but not yet at origin/develop, so a
# develop-only check would false-warn on nearly every new entry. HEAD is
# therefore consulted FIRST, with develop only as the fallback.
@test "a code-span path added by this change (worktree-only, not on develop) draws no warning" {
    _mk_span_repo
    # Created AFTER the base commit, so it exists in the worktree and is absent
    # from the origin/develop tree.
    mkdir -p "$FIXTURE_DIR/scripts/dev"
    printf '#!/usr/bin/env bash\n' > "$FIXTURE_DIR/scripts/dev/brand-new-helper.sh"
    printf -- '- entry\n\n  Anchored on `scripts/dev/brand-new-helper.sh` added by this same change.\n' \
        > "$FIXTURE_DIR/docs/self-improvement/categories/tooling/e.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]
    [[ "$output" != *"WARN: code-span path"* ]]
}

# A backlog entry's PROPOSAL block names files it exists to CREATE. Those paths
# are absent by design and were 8 of the 12 warnings on the first real run —
# warning on them would train readers to ignore the rule, the same failure the
# applied.md exemption avoids. The block is structural (label-delimited), not a
# verb guess.
@test "a path proposed under 'Concrete next action' draws no warning" {
    _mk_span_repo
    {
        printf -- '- 2026-08-16 entry\n'
        printf '  Details: something is missing.\n'
        printf '  Concrete next action: add a `scripts/dev/install-security-tools.sh` mirror.\n'
        printf '  Status: open\n'
    } > "$FIXTURE_DIR/docs/self-improvement/categories/tooling/e.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]
    [[ "$output" != *"WARN: code-span path"* ]]
}

@test "'Proposed:' opens a proposal block too" {
    _mk_span_repo
    {
        printf -- '- 2026-08-16 entry\n'
        printf '  Proposed: extract the helper into `scripts/dev/lib/ui-test-home.sh` and source it.\n'
        printf '  Status: open\n'
    } > "$FIXTURE_DIR/docs/self-improvement/categories/tooling/e.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]
    [[ "$output" != *"WARN: code-span path"* ]]
}

# The proposal block must CLOSE at the next sibling label, or a stale citation in
# Cross-ref/Status would be swallowed by a proposal earlier in the same entry —
# which is exactly where two of the three real staleness bugs lived.
@test "a stale path in Cross-ref AFTER a proposal block still warns" {
    _mk_span_repo
    {
        printf -- '- 2026-08-16 entry\n'
        printf '  Concrete next action: add a `scripts/dev/brand-new-thing.sh` helper.\n'
        printf '  Cross-ref: `tests/Core/moved-away-xyz.test.cpp` (the pattern to copy)\n'
        printf '  Status: open\n'
    } > "$FIXTURE_DIR/docs/self-improvement/categories/tooling/e.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN: code-span path 'tests/Core/moved-away-xyz.test.cpp'"* ]]
    [[ "$output" != *"brand-new-thing.sh"* ]]
}

# A sub-bullet inside a proposal must not close it — proposals routinely list
# steps, and closing early would re-enable the false positives.
@test "a sub-bullet does not close a proposal block" {
    _mk_span_repo
    {
        printf -- '- 2026-08-16 entry\n'
        printf '  Concrete next action: do these:\n'
        printf '    - author `agents/scripts/core/brand-new-helper.sh` first\n'
        printf '  Status: open\n'
    } > "$FIXTURE_DIR/docs/self-improvement/categories/tooling/e.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]
    [[ "$output" != *"WARN: code-span path"* ]]
}

# A new entry header resets proposal state, so entry N's proposal cannot silence
# entry N+1's stale citation in a monolith category file.
@test "a new entry header closes the previous entry's proposal block" {
    _mk_span_repo
    {
        printf -- '- 2026-08-15 first entry\n'
        printf '  Concrete next action: add a `scripts/dev/brand-new-thing.sh` helper.\n'
        printf -- '- 2026-08-16 second entry citing `tests/Core/moved-away-xyz.test.cpp` as real\n'
    } > "$FIXTURE_DIR/docs/self-improvement/categories/tooling/e.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN: code-span path 'tests/Core/moved-away-xyz.test.cpp'"* ]]
}

# ---------- rule 3: #fragment anchors resolve by GitHub's slug rules ----------

_mk_frag_fixture() {
    mkdir -p "$FIXTURE_DIR/agents/scripts/core" "$FIXTURE_DIR/docs"
    cp "$LINT" "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh"
    {
        printf '# Rules\n\n'
        printf '## Merge gates § Sanctioned step-level masks\n'
        printf '## `merge-gates.sh` — the (REST) contract + C++ & more\n'
        printf '## Dup\n## Dup\n'
        printf '## __init__ and snake_case_name\n'
        printf '## Café 🚀 notes\n'
        printf 'Setext heading\n--------------\n'
        printf '<a id="Custom-ID"></a>\n'
        printf '```\n## Not a heading inside a fence\n```\n'
    } > "$FIXTURE_DIR/docs/rules.md"
}

@test "a good #fragment on a relative link passes (section sign, em dash, punctuation, dup suffix, unicode)" {
    _mk_frag_fixture
    {
        printf '# a\n\n'
        printf '[1](rules.md#merge-gates--sanctioned-step-level-masks)\n'
        printf '[2](rules.md#merge-gatessh--the-rest-contract--c--more)\n'
        printf '[3](rules.md#dup) [4](rules.md#dup-1)\n'
        printf '[5](rules.md#init-and-snake_case_name)\n'
        printf '[6](rules.md#café--notes) [7](rules.md#caf%%C3%%A9--notes)\n'
        printf '[8](rules.md#setext-heading) [9](rules.md#Custom-ID) [10](rules.md#L12)\n'
        printf '[11](#a) [12](rules.md#user-content-dup)\n'
    } > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]
    [[ "$output" != *"BROKEN_LINK"* ]]
}

@test "a broken #fragment on a relative link FAILs though the target file exists" {
    _mk_frag_fixture
    printf '# a\n\n[gone](rules.md#tiered-enforcement-zones)\n' > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 1 ]
    [[ "$output" == *"BROKEN_LINK: 'rules.md#tiered-enforcement-zones' — no heading in docs/rules.md has the GitHub anchor '#tiered-enforcement-zones'"* ]]
}

@test "slug edge cases FAIL where GitHub would: collapsed dashes, an unused dup suffix, a fenced heading" {
    _mk_frag_fixture
    {
        printf '# a\n\n'
        printf '[x](rules.md#merge-gates-sanctioned-step-level-masks)\n'
        printf '[y](rules.md#dup-2)\n'
        printf '[z](rules.md#not-a-heading-inside-a-fence)\n'
    } > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 1 ]
    [[ "$output" == *"'rules.md#merge-gates-sanctioned-step-level-masks'"* ]]
    [[ "$output" == *"'rules.md#dup-2'"* ]]
    [[ "$output" == *"'rules.md#not-a-heading-inside-a-fence'"* ]]
}

@test "a broken same-file #fragment FAILs" {
    mkdir -p "$FIXTURE_DIR/agents/scripts/core" "$FIXTURE_DIR/docs"
    cp "$LINT" "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh"
    printf '# Title\n\nSee [up](#title) and [gone](#no-such-section).\n' > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 1 ]
    [[ "$output" == *"BROKEN_LINK: '#no-such-section'"* ]]
    [[ "$output" != *"'#title'"* ]]
}

_mk_lint_fixture() {
    mkdir -p "$FIXTURE_DIR/agents/scripts/core" "$FIXTURE_DIR/docs"
    cp "$LINT" "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh"
}

@test "a fence closes only on its opener's character and run length" {
    _mk_lint_fixture
    # A ``` line inside a ~~~ block and a short ``` run inside a ```` block are
    # code. Toggling on any fence-shaped line ends each block early, reopens it
    # at the real closer and drops every heading after it.
    {
        printf '# Fences\n\n'
        printf '~~~\n```\n## Tilde body\n[in code](nope.md)\n~~~\n\n'
        printf '````\n```\n## Long body\n````\n\n'
        printf '## After mixed fences\n'
    } > "$FIXTURE_DIR/docs/rules.md"
    printf '# a\n\n[ok](rules.md#after-mixed-fences)\n' > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]
    [[ "$output" != *"nope.md"* ]]
    printf '# a\n\n[x](rules.md#tilde-body) [y](rules.md#long-body)\n' > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 1 ]
    [[ "$output" == *"'rules.md#tilde-body'"* ]]
    [[ "$output" == *"'rules.md#long-body'"* ]]
}

@test "a multi-line setext heading answers to its folded paragraph text" {
    _mk_lint_fixture
    printf '# Setext\n\nTwo line\nsetext title\n------------\n' > "$FIXTURE_DIR/docs/rules.md"
    # GitHub renders the whole paragraph as the heading: 'Two line setext title'.
    # The underlined line alone stays an accepted alternative.
    printf '# a\n\n[f](rules.md#two-line-setext-title) [l](rules.md#setext-title)\n' > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]
    [[ "$output" != *"BROKEN_LINK"* ]]
}

@test "a heading's other-number characters (superscripts, fractions) drop out of its slug" {
    _mk_lint_fixture
    printf '# Slug\n\n## x\302\262 scaling at \302\275 rate\n' > "$FIXTURE_DIR/docs/rules.md"
    printf '# a\n\n[ok](rules.md#x-scaling-at--rate)\n' > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]
    [[ "$output" != *"BROKEN_LINK"* ]]
}

@test "headings inside a blockquote or opening a list item have anchors and take duplicate slots" {
    _mk_lint_fixture
    {
        printf '# Quoted\n\n'
        printf '> ## Remediation status\n\n'
        printf '> ### What escaped\n\n'
        printf '### What escaped\n\n### What escaped\n\n'
        printf -- '- ## In list\n'
    } > "$FIXTURE_DIR/docs/rules.md"
    # GitHub: the quoted 'What escaped' is the first of three, so the real ones
    # are -1 and -2; missing the quoted one would make #what-escaped-2 fail.
    printf '# a\n\n[r](rules.md#remediation-status) [w](rules.md#what-escaped-2) [l](rules.md#in-list)\n' \
        > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]
    [[ "$output" != *"BROKEN_LINK"* ]]
    printf '# a\n\n[w](rules.md#what-escaped-3)\n' > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 1 ]
    [[ "$output" == *"'rules.md#what-escaped-3'"* ]]
}

@test "a setext paragraph led by emphasis is a heading; a quoted paragraph above a top-level --- is not" {
    _mk_lint_fixture
    {
        printf '# Setext\n\n'
        printf '**Status** shipped\n---\n\n'
        printf '> Quoted line\n---\n\n'
        printf '## Quoted line\n'
    } > "$FIXTURE_DIR/docs/rules.md"
    # '> Quoted line' over a top-level '---' is a quote then a thematic break, so
    # the '## Quoted line' heading is the first of its name: #quoted-line, no -1.
    printf '# a\n\n[s](rules.md#status-shipped) [q](rules.md#quoted-line)\n' > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]
    [[ "$output" != *"BROKEN_LINK"* ]]
    printf '# a\n\n[q](rules.md#quoted-line-1)\n' > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 1 ]
    [[ "$output" == *"'rules.md#quoted-line-1'"* ]]
}

@test "a fence opened inside a blockquote hides its heading-shaped lines" {
    _mk_lint_fixture
    {
        printf '# Quoted fence\n\n'
        printf '> ```sh\n> # not a heading\n> ```\n\n'
        printf '## Not a heading\n'
    } > "$FIXTURE_DIR/docs/rules.md"
    printf '# a\n\n[n](rules.md#not-a-heading)\n' > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]
    printf '# a\n\n[n](rules.md#not-a-heading-1)\n' > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 1 ]
    [[ "$output" == *"'rules.md#not-a-heading-1'"* ]]
}

@test "a heading with a code-span link label or an undefined [A][B] reference answers to GitHub's anchor" {
    _mk_lint_fixture
    {
        printf '# Headings\n\n'
        printf '### Runner scripts (mirror [`scripts/x.sh`](a.md))\n\n'
        printf '### 1. [High][Logic/correctness] Bug\n'
    } > "$FIXTURE_DIR/docs/rules.md"
    printf '# a\n\n[r](rules.md#runner-scripts-mirror-scriptsxsh) [b](rules.md#1-highlogiccorrectness-bug)\n' \
        > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]
    [[ "$output" != *"BROKEN_LINK"* ]]
}

@test "an inner fence shown indented inside a fenced example does not close it" {
    _mk_lint_fixture
    {
        printf '# Template\n\n'
        printf '```markdown\n1. Build:\n    ```bash\n    make\n    ```\n```\n\n'
        printf '## Verification\n\n'
        printf '```bash\nmake test\n```\n\n'
        printf 'See [gone](missing-file.md).\n'
    } > "$FIXTURE_DIR/docs/rules.md"
    printf '# a\n\n[v](rules.md#verification)\n' > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 1 ]
    # The heading after the example has its anchor, and the link after the
    # later fence is checked (not swallowed by a phantom fence).
    [[ "$output" != *"'rules.md#verification'"* ]]
    [[ "$output" == *"missing-file.md"* ]]
}

@test "a heading inside a list item's continuation takes its duplicate slot" {
    _mk_lint_fixture
    printf '# Doc\n\n## Foo\n\n1. Step\n\n    ## Foo\n\n## Foo\n' > "$FIXTURE_DIR/docs/rules.md"
    printf '# a\n\n[f](rules.md#foo-2)\n' > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]
    printf '# a\n\n[f](rules.md#foo-3)\n' > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 1 ]
    [[ "$output" == *"'rules.md#foo-3'"* ]]
}

@test "a tab-indented fence opener closes on a space-indented closer at the same column" {
    _mk_lint_fixture
    printf '# Setup\n\n1.  Install:\n\n\t```bash\n\tmake\n      ```\n\n## Verification\n\nSee [gone](missing.md).\n' \
        > "$FIXTURE_DIR/docs/rules.md"
    printf '# a\n\n[v](rules.md#verification)\n' > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 1 ]
    [[ "$output" != *"'rules.md#verification'"* ]]
    [[ "$output" == *"missing.md"* ]]
}

@test "a full reference whose label is a code span renders as its label" {
    _mk_lint_fixture
    printf '# Doc\n\n## Use [`run.sh`][run] now\n\n## See [`a`](a.md) and [b][zz]\n\n[run]: a.md\n' > "$FIXTURE_DIR/docs/rules.md"
    # The second heading mixes an inline link (renders as its label) with an
    # undefined reference (renders literally): GitHub's slug is see-a-and-bzz.
    printf '# a\n\n[r](rules.md#use-runsh-now) [s](rules.md#see-a-and-bzz)\n' > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]
    [[ "$output" != *"BROKEN_LINK"* ]]
}

@test "list-item headings: an outer item after a nested one, a lazy line and a tab continuation keep their slots" {
    _mk_lint_fixture
    local body
    for body in \
        '## Foo\n\n- a\n  - b\n\n  para\n\n    ## Foo\n\n## Foo\n' \
        '## Foo\n\n1. Step\nlazy\n\n    ## Foo\n\n## Foo\n' \
        '## Foo\n\n- Step\n\n\t## Foo\n\n## Foo\n' \
        '## Foo\n\n1.  Step\n    - sub\n    ## Foo\n\n## Foo\n'; do
        printf "# Doc\n\n$body" > "$FIXTURE_DIR/docs/rules.md"
        printf '# a\n\n[f](rules.md#foo-2)\n' > "$FIXTURE_DIR/docs/a.md"
        run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
        [ "$status" -eq 0 ]
    done
    # A thematic break is not a list item, and a top-level heading after a list
    # still counts.
    printf '# Doc\n\n## Foo\n\n- - -\n\n## Foo\n' > "$FIXTURE_DIR/docs/rules.md"
    printf '# a\n\n[f](rules.md#foo-1)\n' > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]
}

@test "a non-markdown target's fragment is not checked" {
    mkdir -p "$FIXTURE_DIR/agents/scripts/core" "$FIXTURE_DIR/docs"
    cp "$LINT" "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh"
    printf 'int x;\n' > "$FIXTURE_DIR/docs/foo.h"
    printf '# a\n\n[src](foo.h#anything-at-all)\n' > "$FIXTURE_DIR/docs/a.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]
}

@test "a baselined broken #fragment is grandfathered by --all (keyed by source::href)" {
    _mk_frag_fixture
    mkdir -p "$FIXTURE_DIR/docs/high-integrity"
    printf '# a\n\n[old](rules.md#gone-old)\n[new](rules.md#gone-new)\n' > "$FIXTURE_DIR/docs/a.md"
    {
        printf '# Dangling markdown links — grandfathered baseline\n\n## dangling links (1)\n'
        printf -- '- `docs/a.md` — `rules.md#gone-old` (resolves to `docs/rules.md#gone-old`)\n'
    } > "$FIXTURE_DIR/docs/high-integrity/markdown-link-baseline.md"
    run bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 1 ]
    [[ "$output" == *"'rules.md#gone-new'"* ]]
    [[ "$output" != *"'rules.md#gone-old'"* ]]
    [[ "$output" == *"1 grandfathered"* ]]
}

# ---------- rule 7: the subsystem leaves are scanned from a host ----------

# A host fixture: the lint, the leaf library and the config loader at their real
# depths, a host project.config.json with ThirdParty exempt, and two tracked
# leaves carrying a dangling link — one registered, one in the exempt zone.
_mk_host_fixture() {
    mkdir -p "$FIXTURE_DIR/agents/scripts/core/lib" "$FIXTURE_DIR/scripts/dev" "$FIXTURE_DIR/docs" \
             "$FIXTURE_DIR/Source/Core/src/Ui" "$FIXTURE_DIR/Source/ThirdParty/vendor"
    cp "$LINT" "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh"
    cp "$REPO_ROOT/agents/scripts/core/lib/leaf-docs.sh" "$FIXTURE_DIR/agents/scripts/core/lib/leaf-docs.sh"
    cp "$REPO_ROOT/scripts/dev/project-config.sh" "$FIXTURE_DIR/scripts/dev/project-config.sh"
    printf '{"project": {"name": "host"}, "lint": {"zones": {"exempt": ["ThirdParty", "build"]}}}\n' \
        > "$FIXTURE_DIR/project.config.json"
    printf '# Ui\n\nSee [root](../../../../AGENTS.md#tiered-enforcement-zones).\n' \
        > "$FIXTURE_DIR/Source/Core/src/Ui/AGENTS.md"
    printf '# Root\n\n## Project rules\n' > "$FIXTURE_DIR/AGENTS.md"
    printf '# Vendor\n\n[upstream](./nope-vendor.md)\n' > "$FIXTURE_DIR/Source/ThirdParty/vendor/AGENTS.md"
    git -C "$FIXTURE_DIR" init -q -b develop
    git -C "$FIXTURE_DIR" add -A
}

@test "--all from a host scans a registered leaf and FAILs its broken fragment, skipping exempt zones" {
    _mk_host_fixture
    run env -u PROJECT_ROOT -u AGENT_LAYER_ROOT bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 1 ]
    [[ "$output" == *"Source/Core/src/Ui/AGENTS.md:3: BROKEN_LINK: '../../../../AGENTS.md#tiered-enforcement-zones'"* ]]
    [[ "$output" != *"nope-vendor.md"* ]]
}

@test "--all from a host passes once the leaf's pointer is fixed" {
    _mk_host_fixture
    printf '# Ui\n\nSee [root](../../../../AGENTS.md#project-rules).\n' > "$FIXTURE_DIR/Source/Core/src/Ui/AGENTS.md"
    run env -u PROJECT_ROOT -u AGENT_LAYER_ROOT bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanned 2 markdown file(s)"* ]]
}

@test "diff scope from a host checks a CHANGED leaf" {
    _mk_host_fixture
    printf '# Ui\n\nNo links yet.\n' > "$FIXTURE_DIR/Source/Core/src/Ui/AGENTS.md"
    git -C "$FIXTURE_DIR" add -A
    git -C "$FIXTURE_DIR" -c user.name=t -c user.email=t@t.test commit -q -m base
    git -C "$FIXTURE_DIR" update-ref refs/remotes/origin/develop HEAD
    printf '# Ui\n\nSee [gone](./missing-leaf-target.md).\n' > "$FIXTURE_DIR/Source/Core/src/Ui/AGENTS.md"
    run env -u PROJECT_ROOT -u AGENT_LAYER_ROOT bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Source/Core/src/Ui/AGENTS.md:3: BROKEN_LINK: './missing-leaf-target.md'"* ]]
}

@test "a Source/ tree without the leaf library is an infra error (exit 2), not a silent skip" {
    _mk_host_fixture
    rm -f "$FIXTURE_DIR/agents/scripts/core/lib/leaf-docs.sh"
    run env -u PROJECT_ROOT -u AGENT_LAYER_ROOT bash "$FIXTURE_DIR/agents/scripts/core/test-markdown-links.sh" --all
    [ "$status" -eq 2 ]
    [[ "$output" == *"leaf-docs.sh is missing"* ]]
}
