#!/usr/bin/env bash
# test-markdown-links.sh — flag dangling relative markdown links across docs.
#
# Why: sed-based path renames (e.g. docs/plans/active/applied/ → archive/) routinely
# update body text but miss `[label](href)` link hrefs when only the label
# happens to look like the path. PR #496 + #497 each shipped with 3-4
# CR-caught broken-href findings of exactly this shape; this lint catches
# them mechanically before push.
#
# Rules:
#   1. Only relative links are checked (paths starting with `/`, `http://`,
#      `https://` or `mailto:` are skipped). A same-file `#section` link is
#      relative too: rule 3 checks it against the source file's own headings.
#   2. The href is resolved relative to the source markdown file's directory.
#   3. An anchor fragment (`#section`) is split off before the existence check,
#      then, when the target is a markdown file, resolved against that file's
#      headings by GitHub's slug rules: lower-case; every character that is not
#      a letter, mark, decimal or letter number, `_`, space or `-` dropped (so
#      `§`, `—`, `.`, `+`, `&`, `/`, parentheses, backticks, emoji and other
#      numbers such as `²` vanish); each space to `-`
#      with no collapsing (`A — B` is `a--b`); a repeated slug suffixed `-1`,
#      `-2`, ... in document order. Explicit `<a id=…>` / `name=` anchors and
#      GitHub's `#L10` line anchors count. The heading set over-approximates the
#      rendering, so an approximation error can only let a broken fragment
#      pass, never fail a good one. A non-markdown target (`Foo.h#L10`) or a
#      directory is not fragment-checked.
#   4. Image links (`![alt](path)`) are NOT checked — image assets vary by
#      build state.
#   5. Targets: docs/**/*.md, agents/**/*.md, and the top-level repo docs
#      AGENTS.md, BUILD.md, README.md, AI_POLICY.md, CONTEXT-MAP.md,
#      QUICKSTART.md (each if present). QUICKSTART.md joined in
#      dev-onboarding-first-run-quickstart slice 3 — it is the first-run entry
#      doc and links out to BUILD.md, so a dangling link there is the highest-
#      cost one in the tree. The user-facing guides joined the set in gate-blind-spot-sweep
#      Slice 3 — they were the only actively-maintained docs the gate could not
#      see, and cli.md carried two dangling links the whole time. They are no
#      longer named individually here: the root-declutter move relocated them to
#      docs/guides/ and the dated audit reports to docs/audits/, so both groups
#      are covered by the docs/** branch and cannot silently fall out of scope
#      again. KEEP IN SYNC with the is_active_md() root-file tuple below; this
#      header is the documented contract, so a target added there must be added
#      here too.
#   6. Links inside fenced code blocks (``` / ~~~) are skipped — illustrative
#      example paths in a template are literal, not navigable links. A fence
#      closes only on its opener's character with a run at least as long, as
#      CommonMark renders it, so a ``` line inside a ~~~ block stays code.
#   7. Run from a host, the registered subsystem leaves are targets too: every
#      Source/**/AGENTS.md that lib/leaf-docs.sh's leaf_agents_files lists under
#      PROJECT_ROOT (tracked, outside the host's lint exempt zones). Source/ is
#      outside rule 5's branches, so a broken pointer in a leaf used to ship
#      silently. A Source/ tree with no leaf library to enumerate it exits 2.
#
# Bypass: SMATCHET_SKIP_MARKDOWN_LINK_CHECK=1 (logged when used).
#
# Modes:
#   default — diff-scope: only check markdown files modified vs origin/develop.
#             Grandfathers pre-existing broken refs; catches new regressions.
#   --all   — repo-wide scan of every actively-maintained markdown, minus the
#             entries grandfathered in docs/high-integrity/markdown-link-baseline.md.
#             The baseline exists so --all is usable as a gate at all: widening
#             the target set (rule 5) would otherwise have meant burning down the
#             pre-existing dangling links first. Note the two counts differ and
#             both are correct: the baseline holds 9 distinct `file::href` KEYS,
#             which `--all` reports as 14 line-level OCCURRENCES (one file repeats
#             three hrefs across eight lines). Entries are keyed by
#             `file::href`, not by line number, so unrelated edits above a
#             grandfathered link do not un-grandfather it.
#   --baseline — regenerate that baseline from the current tree, then commit it.
#             The burn-down path the plain diff-scope mode never had: every
#             --all run prints the remaining grandfathered count, and an entry
#             that has been fixed is reported as stale.
#   --merge-tree-warn — advisory (always exit 0): flag TIERED plan links
#             (docs/plans/{active,shipped,deferred}/<slug>.md) in changed
#             markdown that would 404 post-archive on CI though they pass the
#             local existence check. Remedy: the tier-less docs/plans/<slug>.md
#             form (markdown-links-local-passes-ci-fails-after-plan-archive).
#
# Exit codes:
#   0 — every relative link in every scanned markdown resolves to an existing file
#       (and every checked #fragment to a heading in it)
#   1 — at least one dangling link or fragment
#   2 — missing binary (python), or a Source/ tree without lib/leaf-docs.sh

set -euo pipefail
# The tree whose markdown is checked is PROJECT_ROOT (scripts/dev/project-config.sh):
# the host before and after the flip — once this script lives in the agent-layer/
# submodule it is the superproject — and the layer itself in the layer's own CI. A
# climb from this script's path would check the layer's markdown from the host.
_tml_self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
if [ -f "$(dirname "$_tml_self")/../../../scripts/dev/project-config.sh" ]; then
    # shellcheck source=scripts/dev/project-config.sh
    PC_ROOTS_ONLY=1 . "$(dirname "$_tml_self")/../../../scripts/dev/project-config.sh" || true
else
    unset PROJECT_ROOT AGENT_LAYER_ROOT  # no config beside this script (a fixture copy): its own tree, never an inherited root
fi
cd "${PROJECT_ROOT:-$(dirname "$_tml_self")/../../..}"

if [ "${SMATCHET_SKIP_MARKDOWN_LINK_CHECK:-0}" = "1" ]; then
    echo "test-markdown-links: SMATCHET_SKIP_MARKDOWN_LINK_CHECK=1 — skipping" >&2
    echo "Passed: 0  Failed: 0"
    exit 0
fi

PY="${PYTHON:-}"
if [ -n "$PY" ]; then
    if ! "$PY" -c "" >/dev/null 2>&1; then
        echo "test-markdown-links: PYTHON='$PY' is not executable" >&2
        exit 2
    fi
else
    for _c in python3 python py; do
        _p="$(command -v "$_c" 2>/dev/null)" || continue
        if "$_p" -c "" >/dev/null 2>&1; then
            PY="$_p"
            break
        fi
    done
fi
[ -n "$PY" ] || { echo "test-markdown-links: python not found" >&2; exit 2; }

# --selftest — prove the diff-scope path INCLUDES untracked files (Slice 8a).
# Regression killed: an UNTRACKED new markdown (e.g. a fresh
# docs/plans/active/<slug>.md) is invisible to `git diff` so it false-passed
# pre-push then failed CI on the same content. We synthesize an untracked
# markdown with a dangling link, run the diff-scope scan, and assert it FAILS
# (caught) — then a clean untracked file must PASS.
if [ "${1:-}" = "--selftest" ]; then
    fail=0
    stamp="docs/.slice8-mdlink-selftest-$$"
    bad="$stamp-bad.md"
    good="$stamp-good.md"
    # Ensure these never linger as tracked refs and always get cleaned.
    cleanup() { rm -f "$bad" "$good"; }
    trap cleanup EXIT
    # An untracked markdown with a dangling relative link.
    printf '# selftest\n\nsee [missing](./this-target-does-not-exist-xyz.md)\n' > "$bad"
    # selftest: asserts-failure — an untracked file with a dangling link MUST be
    # detected; if the diff-scope skips untracked files this scan wrongly passes.
    # Re-invoke with no args -> the default diff-scope path (which now unions
    # untracked files). The new untracked file must drive a non-zero exit.
    # Re-invoked as `bash "$0"`, not `"$0"`: this script is tracked mode 100644
    # (like most of agents/scripts/core), so executing it directly fails with
    # "permission denied" on a POSIX checkout — which made BOTH assertions below
    # read the same non-zero exit and reported the second one as a false failure.
    if bash "$_tml_self" >/dev/null 2>&1; then
        echo "test-markdown-links --selftest: FAIL — untracked dangling link NOT detected (scope skipped untracked)" >&2
        fail=1
    fi
    rm -f "$bad"
    # selftest: asserts-failure — a link whose #fragment names no heading in its
    # target (rule 3) MUST fail even though the target file exists.
    printf '# selftest\n\nsee [gone](#no-such-heading-xyz)\n' > "$bad"
    if bash "$_tml_self" >/dev/null 2>&1; then
        echo "test-markdown-links --selftest: FAIL — a broken #fragment was NOT detected" >&2
        fail=1
    fi
    rm -f "$bad"
    # A clean untracked markdown (a fragment that resolves) must PASS.
    printf '# selftest\n\n## Merge gates § Masks\n\nsee [ok](#merge-gates--masks)\n' > "$good"
    if ! bash "$_tml_self" >/dev/null 2>&1; then
        echo "test-markdown-links --selftest: FAIL — clean untracked file wrongly flagged" >&2
        fail=1
    fi
    cleanup
    trap - EXIT
    if [ "$fail" = "0" ]; then
        echo "test-markdown-links --selftest: PASS (untracked files are in diff-scope; a broken #fragment fails)"
        exit 0
    fi
    echo "test-markdown-links --selftest: FAIL" >&2
    exit 1
fi

# --merge-tree-warn — synthetic-behind-develop WARN mode
# (markdown-links-local-passes-ci-fails-after-plan-archive). A TIERED plan link
# `[…](…/docs/plans/active/<slug>.md)` resolves locally while the plan still
# lives in active/, but the SAME branch's archival `git mv active -> shipped`
# (or a sibling PR's archival merged into develop) moves the target — so the
# link 404s on CI/post-merge though it passed the local existence check. The
# durable fix is the TIER-LESS form `docs/plans/<slug>.md` (the gates resolve it
# against any tier — see plan_tierless_resolves below); this advisory mode flags
# tiered plan links in CHANGED markdown so the author rewrites them tier-less
# before they rot. WARN-only: always exits 0 (it never blocks a push).
if [ "${1:-}" = "--merge-tree-warn" ]; then
    "$PY" - <<'PY'
import os
import re
import subprocess
import sys

REPO_ROOT = os.getcwd()

# Markdown changed vs origin/develop (committed + working-tree + untracked),
# mirroring the default diff-scope so the warning fires on exactly what a PR
# would ship.
def _changed():
    cmds = (
        ["git", "diff", "--name-only", "origin/develop...HEAD"],
        ["git", "diff", "--name-only", "HEAD"],
        ["git", "ls-files", "--others", "--exclude-standard"],
    )
    out = ""
    for c in cmds:
        try:
            out += subprocess.run(c, capture_output=True, text=True, check=True).stdout
        except subprocess.CalledProcessError:
            pass
    return sorted({ln.strip() for ln in out.splitlines() if ln.strip()})

# A TIERED plan link: `docs/plans/<tier>/<slug>.md` with tier in active/shipped/
# deferred. These are fragile across an archival move; the tier-less form is not.
TIERED_RE = re.compile(
    r'(?<!\!)\[[^\]]*\]\(([^)\s]*docs/plans/(?:active|shipped|deferred)/[A-Za-z0-9._-]+\.md)'
    r'(?:#[^)\s]*)?(?:\s+"[^"]*")?\)'
)

warnings = []
for rel in _changed():
    if not rel.endswith(".md") or not os.path.exists(rel):
        continue
    try:
        with open(rel, encoding="utf-8") as fh:
            in_fence = False
            for lineno, line in enumerate(fh, 1):
                s = line.lstrip()
                if s.startswith("```") or s.startswith("~~~"):
                    in_fence = not in_fence
                    continue
                if in_fence:
                    continue
                for m in TIERED_RE.finditer(line):
                    warnings.append(
                        "%s:%d: TIERED_PLAN_LINK: '%s' — use the tier-less form "
                        "'docs/plans/<slug>.md' so it survives an archival "
                        "git mv (active->shipped)." % (rel, lineno, m.group(1))
                    )
    except (OSError, UnicodeDecodeError):
        pass

for w in warnings:
    print("WARN: " + w, file=sys.stderr)

# WARN-only: never block. Report count on stdout for the wrapper.
print("Passed: 1  Failed: 0  (merge-tree-warn: %d tiered plan-link warning(s))" % len(warnings))
sys.exit(0)
PY
    exit 0
fi

# Diff-scope by default; --all overrides for whole-repo audit; --baseline
# regenerates the grandfather file from a whole-repo audit (and never fails).
SCOPE="diff"
case "${1:-}" in
    --all) SCOPE="all" ;;
    --baseline) SCOPE="baseline" ;;
    "") : ;;
    *)
        echo "test-markdown-links: unknown argument '$1'" >&2
        echo "  usage: test-markdown-links.sh [--all|--baseline|--merge-tree-warn|--selftest]" >&2
        exit 2
        ;;
esac
export SCOPE
# This script as the project's checkout spells it, for the baseline header's
# regeneration command: agent-layer/agents/... once the layer is the project's
# agent-layer/ submodule, agents/... otherwise (as layer_paths.py does).
TML_SELF_FROM_PROJECT="agents/scripts/core/test-markdown-links.sh"
_tml_self_phys="$(cd "$(dirname "$_tml_self")" && pwd -P)/$(basename "$_tml_self")"
case "$_tml_self_phys" in "$(pwd -P)"/agent-layer/*) TML_SELF_FROM_PROJECT="${_tml_self_phys#"$(pwd -P)"/}" ;; esac
export TML_SELF_FROM_PROJECT

# Rule 7: the subsystem leaves (lib/leaf-docs.sh, the leaf set setup-harness.sh and
# the leaf-doc gates share) are in the target set — a broken pointer in a leaf used
# to ship silently because Source/ is outside the docs/ + agents/ branches. The
# leaf set honours the HOST's lint exempt zones, so the zones are read from the
# project.config.json of the tree being checked (rung 0, PC_CONFIG_FILE), in a
# subshell so the full load leaks nothing into this script. A failed config load
# leaves the zones empty, which only widens the set (fail-closed). A tree with a
# Source/ directory but no leaf library beside this script cannot say which files
# are leaves, so it exits 2 (fail-closed); a tree without Source/ (the standalone
# layer, a fixture copy) has no leaves to miss and scans none.
_tml_leaf_lib="$(dirname "$_tml_self")/lib/leaf-docs.sh"
_tml_pc="$(dirname "$_tml_self")/../../../scripts/dev/project-config.sh"
TML_LEAF_DOCS=""
if [ -f "$_tml_leaf_lib" ]; then
    TML_LEAF_DOCS="$(
        if [ -f "$_tml_pc" ] && [ -f "$(pwd)/project.config.json" ]; then
            PC_CONFIG_FILE="$(pwd)/project.config.json"
            # shellcheck source=scripts/dev/project-config.sh
            . "$_tml_pc" >/dev/null 2>&1 || true
        fi
        # shellcheck source=agents/scripts/core/lib/leaf-docs.sh
        . "$_tml_leaf_lib" && leaf_agents_files Source
    )" || { echo "test-markdown-links: could not load $_tml_leaf_lib" >&2; exit 2; }
elif [ -d Source ]; then
    echo "test-markdown-links: $_tml_leaf_lib is missing;" \
        "the subsystem leaves under Source/ cannot be enumerated" >&2
    exit 2
fi
export TML_LEAF_DOCS

"$PY" - <<'PY'
import html
import json
import os
import re
import subprocess
import sys
import unicodedata
import urllib.parse

REPO_ROOT = os.getcwd()
SCOPE = os.environ.get("SCOPE", "diff")
# Rule 7: the registered subsystem leaves, repo-relative (exported by the shell
# above from lib/leaf-docs.sh; empty in a tree without Source/).
LEAF_DOCS = {ln.strip() for ln in os.environ.get("TML_LEAF_DOCS", "").splitlines() if ln.strip()}
# Excluded paths under docs/ (active vs archived): docs/plans/active/applied/ and
# docs/plans/shipped/ hold shipped/historical plans whose link-paths drifted
# over time without being maintained — they're documentation-history, not
# active. Scope to docs that ARE actively maintained.
# Use POSIX separators throughout — git diff --name-only emits forward
# slashes on every platform, including Windows. Mixing os.sep here would
# silently misclassify paths in diff scope under cmd/powershell.
EXCLUDED_PREFIXES = (
    "docs/plans/active/applied",
    "docs/plans/shipped",
)


def is_active_md(rel_path):
    """True if rel_path is one of the actively-maintained markdown files
    (docs/, agents/, root-level repo docs) and NOT under an archived dir."""
    if not rel_path.endswith(".md"):
        return False
    # Normalize to POSIX so the same logic works for git-diff output and
    # os.walk output on Windows (os.sep == '\\').
    rel = rel_path.replace(os.sep, "/")
    parts = rel.split("/")
    # Top-level repo docs. KEEP IN SYNC with rule 5 in this script's header —
    # that header is the documented contract for what the gate covers. The
    # user-facing guides (docs/guides/) and the dated audit reports
    # (docs/audits/) used to be listed here as root files; the root-declutter
    # move put them under docs/, where the docs/** branch below already covers
    # them — so they need no entry in this tuple.
    if parts[0] in ("AGENTS.md", "BUILD.md", "README.md", "AI_POLICY.md",
                    "CONTEXT-MAP.md", "QUICKSTART.md") and len(parts) == 1:
        return True
    if parts[0] not in ("docs", "agents"):
        return False
    for p in EXCLUDED_PREFIXES:
        if rel == p or rel.startswith(p + "/"):
            return False
    return True


BASELINE_PATH = "docs/high-integrity/markdown-link-baseline.md"
# Matches a rendered row `- `<src>` — `<href>` (resolves to `<target>`)`. Deliberately NOT
# anchored at end-of-line: the trailing "(resolves to ...)" is human context, not part of the key.
_BASELINE_ROW_RE = re.compile(r"^-\s+`([^`]+)`\s+—\s+`([^`]+)`")


def read_baseline():
    """Grandfathered `(source_md, href)` pairs. Keyed by href rather than line number so an
    unrelated edit above a grandfathered link does not silently un-grandfather it. A missing
    baseline is an EMPTY set — the honest answer for a fresh checkout, not an error."""
    keys = set()
    try:
        with open(os.path.join(REPO_ROOT, BASELINE_PATH), encoding="utf-8") as fh:
            for raw in fh:
                m = _BASELINE_ROW_RE.match(raw.strip())
                if m:
                    keys.add((m.group(1), m.group(2)))
    except OSError:
        return set()
    return keys


def render_baseline(entries):
    """entries: sorted list of (source_md, href, resolved_target)."""
    out = [
        "# Dangling markdown links — grandfathered baseline",
        "",
        "_Auto-generated. Do not hand-edit; run `bash %s "
        "--baseline` and commit._" % os.environ.get(
            "TML_SELF_FROM_PROJECT", "agents/scripts/core/test-markdown-links.sh"),
        "_Scope: `--all` (repo-wide). The DEFAULT diff-scope mode does not consult this file — it "
        "already grandfathers by scope, only ever checking markdown a change actually touches._",
        "_Keyed by `source::href`, not by line number, so an edit above a grandfathered link does "
        "not un-grandfather it. Burn these down and re-run `--baseline`; `--all` reports any entry "
        "that is already fixed as stale._",
        "",
        "## dangling links (%d)" % len(entries),
    ]
    if entries:
        for src, href, target in entries:
            out.append("- `%s` — `%s` (resolves to `%s`)" % (src, href, target))
    else:
        out.append("- _(none — every relative link in every actively-maintained markdown resolves)_")
    out += ["", "## Totals", "- dangling links grandfathered: %d" % len(entries), ""]
    return "\n".join(out)


TARGETS = []
if SCOPE == "diff":
    # Find every markdown changed vs origin/develop (ahead-range).
    try:
        out = subprocess.run(
            ["git", "diff", "--name-only", "origin/develop...HEAD"],
            capture_output=True, text=True, check=True,
        ).stdout
        # Also include uncommitted working-tree changes.
        out += subprocess.run(
            ["git", "diff", "--name-only", "HEAD"],
            capture_output=True, text=True, check=True,
        ).stdout
        # And UNTRACKED files (respecting .gitignore via --exclude-standard).
        # A brand-new uncommitted markdown file is invisible to `git diff` (it
        # has no tracked baseline) yet CI sees it the moment it's committed — so
        # the local mirror must scope it identically or a new doc/plan file
        # false-passes pre-push then fails CI (close-gate-gaps Slice 8a).
        out += subprocess.run(
            ["git", "ls-files", "--others", "--exclude-standard"],
            capture_output=True, text=True, check=True,
        ).stdout
    except subprocess.CalledProcessError as exc:
        sys.stderr.write(f"WARN: git diff failed ({exc}); falling back to repo-wide\n")
        out = ""
    changed = sorted(set(
        line.strip() for line in out.splitlines() if line.strip()
    ))
    for rel_path in changed:
        if (is_active_md(rel_path) or rel_path in LEAF_DOCS) and os.path.exists(rel_path):
            TARGETS.append(os.path.join(REPO_ROOT, rel_path))
else:
    # Repo-wide scan.
    for root, dirs, files in os.walk(REPO_ROOT):
        skip = {".git", "build", "node_modules", "_deps", "FetchContent",
                "external", "__pycache__", ".claude"}
        dirs[:] = [d for d in dirs if d not in skip]
        for f in files:
            full = os.path.join(root, f)
            rel = os.path.relpath(full, REPO_ROOT)
            if is_active_md(rel) or rel.replace(os.sep, "/") in LEAF_DOCS:
                TARGETS.append(full)

# Match `[label](href)` but NOT image links `![alt](path)`. Negative
# look-behind for `!`. The href group is everything up to the closing `)`
# but stops at whitespace (defensive against malformed links).
LINK_RE = re.compile(r'(?<!\!)\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)')

# An inline code span: a run of N backticks, content, then the SAME run. Prose
# that quotes link syntax inside a span is literal, not a navigable link, so the
# span must come out of the line BEFORE LINK_RE sees it — otherwise a doc that
# needs to discuss link syntax is reported as carrying a dangling link (the
# false-positive half of tooling 2026-08-07).
_CODE_SPAN_RE = re.compile(r"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)")


def strip_code_spans(line):
    """(line_with_spans_blanked, [(span_text, end_offset), ...]).

    Spans are replaced by an equal run of SPACES rather than deleted, so column
    offsets stay truthful and two halves of a line can never be glued into a
    link shape that the author did not write."""
    spans = []

    def _blank(m):
        spans.append((m.group(2), m.end()))
        return " " * len(m.group(0))

    return _CODE_SPAN_RE.sub(_blank, line), spans


# A code span that LOOKS like a repo path: a known top-level dir, then a path
# with a file extension. Anchored and space-free so prose in a span never
# matches; an optional `:NNN[:NNN]` line-anchor suffix is tolerated because
# backlog entries cite file:line constantly.
_REPO_PATH_SPAN_RE = re.compile(
    r"^(?:scripts|Source|docs|agents|tests|tools)/"
    r"[A-Za-z0-9._/-]*\.[A-Za-z0-9]+(?::\d+(?::\d+)?)?$"
)
# The code-span path rule is scoped to the backlog: an entry is read months
# later by someone who will act on it, and its whole value is that the cited
# path is real. `applied.md` is exempt — it is the ARCHIVE of entries already
# actioned, so a path that has since moved or been deleted is expected there and
# nobody is going to act on it. Warning on it produced ~100 rows of pure noise
# that would drown the live signal. The rotated monthly partitions
# (applied-YYYY-MM.md, rotate-applied-md.sh) are the same archive, same
# exemption.
CODE_SPAN_SCOPE = "docs/self-improvement/categories/"
CODE_SPAN_EXEMPT_BASENAMES = ("applied.md",)
CODE_SPAN_EXEMPT_PREFIXES = ("applied-",)

# A backlog entry's PROPOSAL block names files it exists to CREATE — "Concrete
# next action: add a `scripts/dev/install-security-tools.sh`". Those paths are
# absent by design, and they are the single most common repo-path code span in
# the backlog: on the first real run they were 8 of 12 warnings. Warning on them
# would train readers to ignore the rule, which is the same failure the
# applied.md exemption avoids. The block is structural, not a verb guess: it
# opens at one of these labels...
_PROPOSAL_OPEN_RE = re.compile(r"^\s*-?\s*(?:Concrete next action|Proposed)\b.*?:")
# ...and closes at the next sibling label, or at the next entry header (`- YYYY-
# MM-DD ...` at column 0). Sub-bullets inside a proposal must NOT close it, so a
# bare `- ` is deliberately not a terminator.
_PROPOSAL_CLOSE_RE = re.compile(
    r"^(?:\s{0,3}(?:Status|Last-reviewed|Cross-ref|Details|Related|Mechanics)\b.*?:"
    r"|- \d{4}-\d{2}-\d{2}\b)"
)


def _develop_tree():
    """Repo-relative paths tracked at origin/develop, or None when that ref is
    unavailable (shallow clone / fresh fork). None means 'cannot answer', and
    the caller must then stay silent rather than warn on every path."""
    try:
        out = subprocess.run(
            ["git", "ls-tree", "-r", "--name-only", "origin/develop"],
            capture_output=True, text=True, check=True,
        ).stdout
    except (subprocess.CalledProcessError, OSError):
        return None
    return {ln.strip() for ln in out.splitlines() if ln.strip()}


def _added_lines(rel_path):
    """Line numbers ADDED/MODIFIED vs origin/develop for rel_path, or None for
    'every line' (untracked file, or git unavailable). Delta-scoping keeps the
    existing backlog from having to be clean on day one — only what a change
    actually writes is held to the rule."""
    # An UNTRACKED file has no baseline, so `git diff` reports no hunks for it —
    # indistinguishable from "tracked and unchanged" by hunk count alone. Ask git
    # directly, or a brand-new backlog entry (the common case for this rule)
    # would be scoped to zero lines and checked not at all.
    try:
        subprocess.run(["git", "ls-files", "--error-unmatch", "--", rel_path],
                       capture_output=True, text=True, check=True)
    except (subprocess.CalledProcessError, OSError):
        return None
    added = set()
    saw_git = False
    for args in (["git", "diff", "-U0", "origin/develop...HEAD", "--", rel_path],
                 ["git", "diff", "-U0", "HEAD", "--", rel_path]):
        try:
            out = subprocess.run(args, capture_output=True, text=True, check=True).stdout
        except (subprocess.CalledProcessError, OSError):
            continue
        saw_git = True
        for ln in out.splitlines():
            m = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", ln)
            if m:
                start = int(m.group(1))
                count = 1 if m.group(2) is None else int(m.group(2))
                added.update(range(start, start + count))
    if not saw_git:
        return None
    # A tracked-but-unchanged file yields an empty set (nothing to check); an
    # untracked file yields empty too, but there git reported no hunks because
    # it has no baseline — so treat a file git does not track as all-lines.
    return added


# Match a tier-LESS plan path `docs/plans/<slug>.md` (no active/shipped/deferred
# segment) anywhere in the repo-relative resolved target.
_TIERLESS_PLAN_RE = re.compile(r"(?:^|/)docs/plans/([A-Za-z0-9._-]+\.md)$")


def plan_tierless_target(target):
    """The tier file a tier-less plan link `docs/plans/<slug>.md` lands on: the
    first of active/, shipped/, deferred/ holding <slug>.md, else None."""
    rel = os.path.relpath(target, REPO_ROOT).replace(os.sep, "/")
    m = _TIERLESS_PLAN_RE.search("/" + rel)
    if not m:
        return None
    for tier in ("active", "shipped", "deferred"):
        cand = os.path.join(REPO_ROOT, "docs", "plans", tier, m.group(1))
        if os.path.exists(cand):
            return cand
    return None


def plan_tierless_resolves(target):
    """A tier-less plan link `docs/plans/<slug>.md` resolves when <slug>.md
    exists in active/, shipped/, or deferred/ — so a plan can move between tiers
    without breaking the reference (no ref-sweep on archival). Returns True iff
    the target is such a path AND the slug exists in some tier."""
    return plan_tierless_target(target) is not None


# ---------- rule 3: #fragment anchors, resolved the way GitHub renders them ----------
#
# GitHub gives every heading an id from its RENDERED text (github-slugger): lower-
# case; drop every character that is not a letter, mark, decimal or letter
# number, connector punctuation (`_`), space or hyphen — so `§`, `—`, `.`, `+`,
# `&`, `/`, `(`, `)`, backticks, emoji and other numbers (`²`, `½`) all vanish;
# each space becomes `-` (runs are not collapsed,
# so `A — B` is `a--b`); a repeated slug gets `-1`, `-2`, ... in document order.
# The anchor set is deliberately an OVER-approximation (every plausible rendering
# of a heading, plus explicit `id=` / `name=` HTML anchors): a heading the
# approximation renders wrongly can only make a broken fragment pass. Headings
# inside blockquotes and list items are found too, because each one also takes
# a slot in the duplicate numbering; a heading GitHub renders that this scan
# missed would shift every later duplicate's suffix and fail good links.
_ATX_HEADING_RE = re.compile(r"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$")
_SETEXT_UNDERLINE_RE = re.compile(r"^ {0,3}(?:=+|-+)[ \t]*$")
# Lines that end a paragraph without being text a setext underline could turn
# into a heading: a table row, a heading or fence marker, an HTML comment, a
# blank line. A list-item marker and a thematic break are matched separately,
# because `*`, `-` and `+` also start ordinary text (`**Status** shipped`).
_SETEXT_NOT_TEXT_RE = re.compile(r"^\s*(?:\||#|```|~~~|<!--)|^\s*$")
_LIST_MARKER_RE = re.compile(r"^\s*(?:[-*+]|\d{1,9}[.)])(?:[ \t]+|$)")
_THEMATIC_BREAK_RE = re.compile(r"^ {0,3}(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$")
# A blockquote prefix (`>`, `> >`, ...): GitHub renders a heading inside a quote
# with its own anchor, and that heading takes a slot in the duplicate numbering.
_QUOTE_PREFIX_RE = re.compile(r"^ {0,3}((?:>[ ]?)+)")
_HTML_ID_RE = re.compile(r"""<[A-Za-z][^>]*?\b(?:id|name)\s*=\s*["']([^"']+)["']""")
_HEADING_CODE_RE = re.compile(r"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)")
_GH_LINE_ANCHOR_RE = re.compile(r"^L\d+(?:C\d+)?(?:-L\d+(?:C\d+)?)?$")
_FENCE_RE = re.compile(r"^\s*(`{3,}|~{3,})(.*)$")


def _indent_cols(line):
    """Columns of leading whitespace, tabs expanded to 4-column stops."""
    lead = line[:len(line) - len(line.lstrip(" \t"))]
    return len(lead.expandtabs(4))


class FenceTracker:
    """CommonMark fenced-code state, fed one line at a time. A fence closes only
    on a run of the opener's character at least as long as the opener, with
    nothing after it but blanks, indented at most three spaces past the
    opener: so a ``` line inside a ~~~ block, a short run inside a longer one,
    or an inner fence shown indented inside a fenced example all stay code. A
    backtick run followed by another backtick on the line is an inline code
    span, not an opener. The opener's own indentation is not capped at three
    spaces: a fence nested in a list item is indented further, and treating it
    as code is the established reading here."""

    def __init__(self):
        self.opener = None  # (character, run length, indentation) while inside a fence

    def step(self, line):
        """True when `line` opens, closes or lies inside a fence."""
        line = line.rstrip("\r\n")
        m = _FENCE_RE.match(line)
        indent = _indent_cols(line)
        if self.opener is None:
            if m is None or (m.group(1)[0] == "`" and "`" in m.group(2)):
                return False
            self.opener = (m.group(1)[0], len(m.group(1)), indent)
            return True
        if (m is not None and m.group(1)[0] == self.opener[0]
                and len(m.group(1)) >= self.opener[1] and not m.group(2).strip()
                and indent <= self.opener[2] + 3):
            self.opener = None
        return True


def github_slug(text):
    """github-slugger's slug of already-rendered heading text (no dedup suffix)."""
    kept = []
    for ch in text.strip().lower():
        cat = unicodedata.category(ch)
        # \p{No} (`²`, `½`) is dropped: github-slugger keeps letters, marks,
        # decimal and letter numbers and connector punctuation only.
        if ch in (" ", "-") or cat[0] in ("L", "M") or cat in ("Nd", "Nl", "Pc"):
            kept.append(ch)
    return "".join(kept).replace(" ", "-")


def _render_inline(seg, strip_emphasis, keep_refs=False):
    """Plain text of a non-code-span stretch of a heading, as GitHub renders it.
    keep_refs leaves a full or collapsed reference (`[a][b]`, `[a][]`) as its
    literal bracketed text, which is how GitHub renders one whose label the file
    never defines."""
    escaped = []

    def _protect(m):
        escaped.append(m.group(1))
        return "\x00%d\x00" % (len(escaped) - 1)

    seg = re.sub(r"\\([!-/:-@\[-`{-~])", _protect, seg)
    seg = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", seg)
    seg = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", seg)
    if not keep_refs:
        seg = re.sub(r"\[([^\]]*)\]\[[^\]]*\]", r"\1", seg)
    seg = re.sub(r"<((?:https?|mailto):[^>\s]+)>", r"\1", seg)
    seg = re.sub(r"<[^>]+>", "", seg)
    if strip_emphasis:
        # `_` survives the slug (connector punctuation), so emphasis delimiters
        # must come out first; an intraword `_` (snake_case) is literal text.
        seg = re.sub(r"(?<![A-Za-z0-9])_+|_+(?![A-Za-z0-9])", "", seg)
    seg = html.unescape(seg)
    return re.sub(r"\x00(\d+)\x00", lambda m: escaped[int(m.group(1))], seg)


# An inline link or image, or a full / collapsed reference, its label allowed
# one level of nested brackets.
_HEADING_LINK_RE = re.compile(r"!?\[((?:[^\[\]]|\[[^\[\]]*\])*)\](?:\([^)]*\)|\[[^\]]*\])")


def heading_renderings(raw):
    """Every plausible rendered text of heading source `raw` (see the block
    comment). Link destinations and reference labels also come out BEFORE the
    code-span split, so a link or reference whose label is a code span
    (`[`x.sh`](x.sh)`, `[`x.sh`][x]`) renders as its label; and full /
    collapsed references are rendered both resolved and literal."""
    out = []
    sources = [raw]
    delinked = _HEADING_LINK_RE.sub(r"\1", raw)
    if delinked != raw:
        sources.append(delinked)
    for src in sources:
        for strip_emphasis in (True, False):
            for keep_refs in (False, True):
                parts, pos = [], 0
                for m in _HEADING_CODE_RE.finditer(src):
                    parts.append(_render_inline(src[pos:m.start()], strip_emphasis, keep_refs))
                    code = m.group(2)
                    if len(code) > 2 and code.startswith(" ") and code.endswith(" ") and code.strip():
                        code = code[1:-1]
                    parts.append(code)
                    pos = m.end()
                parts.append(_render_inline(src[pos:], strip_emphasis, keep_refs))
                text = "".join(parts)
                if text not in out:
                    out.append(text)
    return out


def _quote_split(line):
    """(blockquote depth, the line with its `>` prefix removed)."""
    m = _QUOTE_PREFIX_RE.match(line)
    if not m:
        return 0, line
    return m.group(1).count(">"), line[m.end():]


def heading_sources(lines):
    """Heading source text, document order: one list of alternative raw texts per
    ATX or setext heading, outside fences and a leading YAML front-matter block.
    Headings inside a blockquote (`> ## X`) or opening a list item (`- ## X`)
    count, as GitHub gives them anchors too; a fence inside a blockquote is
    tracked at its own quote depth. A setext heading's text is its whole
    paragraph, folded onto one line as GitHub renders it; the underlined line
    alone is kept as a second alternative. The underline must sit at the
    paragraph's quote depth, so a quoted paragraph above a top-level `---`
    (a thematic break) is not misread as a heading that would shift the
    duplicate numbering. A heading inside a list item's continuation counts at
    the item's content column. A list item's continuation paragraph is not
    tracked for setext underlines."""
    heads = []
    fence = FenceTracker()
    fence_depth = 0
    start = 0
    if lines and lines[0].strip() == "---":
        for i in range(1, len(lines)):
            if lines[i].strip() in ("---", "..."):
                start = i + 1
                break
    para = []
    para_depth = 0
    items = []         # content columns of the open list items, outermost first
    last_text = False  # the previous line was paragraph text (lazy continuation)
    for line in lines[start:]:
        depth, content = _quote_split(line.rstrip("\n"))
        if fence.opener is not None:
            # Inside a fence: only a line at the opener's quote depth can close it.
            if depth == fence_depth:
                fence.step(content)
            para = []
            last_text = False
            continue
        if fence.step(content):
            fence_depth = depth
            para = []
            last_text = False
            continue
        # Columns, with leading tabs expanded, for the list-item arithmetic.
        lead = content[:len(content) - len(content.lstrip(" \t"))]
        cols = lead.expandtabs(4) + content[len(lead):]
        indent = len(cols) - len(cols.lstrip(" "))
        # A thematic break (`- - -`, `* * *`) wins over a list marker.
        lm = None if _THEMATIC_BREAK_RE.match(cols) else _LIST_MARKER_RE.match(cols)
        target = content
        if lm:
            # A marker closes every open item nested at or past its column.
            while items and items[-1] > indent:
                items.pop()
            target = cols[lm.end():]
            items.append(lm.end() if target.strip() else lm.end() + 1)
        elif cols.strip():
            if items and indent < items[-1]:
                top_heading = _ATX_HEADING_RE.match(cols) is not None
                if last_text and not top_heading:
                    pass  # a lazy continuation line keeps every item open
                else:
                    while items and items[-1] > indent:
                        items.pop()
            if items and indent >= items[-1]:
                # A line inside an open item: a heading there is indented by
                # the item's content column, not the 0-3 spaces of the top level.
                target = cols[items[-1]:]
        m = _ATX_HEADING_RE.match(target)
        if m:
            heads.append([m.group(2) or ""])
            para = []
            last_text = False
            continue
        if para and depth == para_depth and _SETEXT_UNDERLINE_RE.match(content):
            folded = " ".join(p.strip() for p in para)
            last = para[-1].strip()
            heads.append([folded] if folded == last else [folded, last])
            para = []
            last_text = False
            continue
        if lm or _THEMATIC_BREAK_RE.match(content) or _SETEXT_NOT_TEXT_RE.match(content):
            para = []
            last_text = bool(lm and target.strip())
            continue
        if para and depth != para_depth:
            para = []
        para.append(content)
        para_depth = depth
        last_text = True
    return heads


_ANCHOR_CACHE = {}


def file_anchors(path):
    """Every fragment `path` answers to: deduplicated heading slugs (per rendering)
    plus explicit HTML ids / names. None when the file cannot be read."""
    if path in _ANCHOR_CACHE:
        return _ANCHOR_CACHE[path]
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.readlines()
    except (OSError, UnicodeDecodeError):
        _ANCHOR_CACHE[path] = None
        return None
    anchors = set()
    renderings = []
    for alternatives in heading_sources(lines):
        texts = []
        for raw in alternatives:
            texts.extend(t for t in heading_renderings(raw) if t not in texts)
        renderings.append(texts)
    for variant in range(max((len(t) for t in renderings), default=1)):
        seen = {}
        for texts in renderings:
            base = github_slug(texts[min(variant, len(texts) - 1)])
            slug = base
            if base in seen:
                # github-slugger: bump the base's counter until the result is unused.
                while True:
                    seen[base] += 1
                    slug = "%s-%d" % (base, seen[base])
                    if slug not in seen:
                        break
            seen[slug] = 0
            anchors.add(slug)
    fence = FenceTracker()
    for line in lines:
        if not fence.step(line):
            anchors.update(m.group(1) for m in _HTML_ID_RE.finditer(line))
    _ANCHOR_CACHE[path] = anchors
    return anchors


def fragment_resolves(target, fragment):
    """True when `#fragment` names an anchor in markdown file `target`. Anything
    that is not a readable .md file is not checked (True): a source file's `#L10`
    and a directory have no heading set to resolve against."""
    if not target.lower().endswith(".md") or not os.path.isfile(target):
        return True
    frag = urllib.parse.unquote(fragment)
    if not frag or _GH_LINE_ANCHOR_RE.match(frag):
        return True
    anchors = file_anchors(target)
    if anchors is None:
        return True
    if frag.startswith("user-content-"):
        frag = frag[len("user-content-"):]
    return frag in anchors or frag.lower() in anchors


violations = []
span_warnings = []
_develop_cache = []  # lazily filled once; [] = not yet looked up
checked = 0
for path in TARGETS:
    rel_src_path = os.path.relpath(path, REPO_ROOT).replace(os.sep, "/")
    span_scope = (rel_src_path.startswith(CODE_SPAN_SCOPE)
                  and os.path.basename(rel_src_path) not in CODE_SPAN_EXEMPT_BASENAMES
                  and not os.path.basename(rel_src_path).startswith(CODE_SPAN_EXEMPT_PREFIXES))
    span_lines = _added_lines(rel_src_path) if (span_scope and SCOPE == "diff") else None
    in_proposal = False
    try:
        with open(path, encoding="utf-8") as fh:
            fence = FenceTracker()
            for lineno, line in enumerate(fh, 1):
                if span_scope:
                    if _PROPOSAL_CLOSE_RE.match(line):
                        in_proposal = False
                    if _PROPOSAL_OPEN_RE.match(line):
                        in_proposal = True
                # Skip fenced code blocks (``` / ~~~): a link inside a fence is
                # illustrative/literal (e.g. example paths in a doc template),
                # never a navigable link — checking it produces false positives.
                if fence.step(line):
                    continue
                line, code_spans = strip_code_spans(line)
                # WARN-first: a repo path cited in a backlog code span must
                # resolve. Checked at HEAD (the worktree) FIRST, falling back to
                # origin/develop — checking only develop would false-warn on
                # every path the same PR adds, which is the common case, while
                # checking only HEAD would miss the failure this rule exists for
                # (a path that lives on some other feature branch).
                if span_scope and not in_proposal and (span_lines is None or lineno in span_lines):
                    for span_text, span_end in code_spans:
                        cand = span_text.strip()
                        if not _REPO_PATH_SPAN_RE.match(cand):
                            continue
                        # `Source/Core/.../Commands/Foo.h` is an ELIDED path —
                        # prose shorthand for "somewhere under", never a literal
                        # file. It can't resolve and was never meant to.
                        if "..." in cand:
                            continue
                        # Skip a link LABEL span — `[`docs/x.md`](docs/x.md)` —
                        # the href half is already checked as a real link, and
                        # reporting both would double-count one mistake.
                        if line[span_end:span_end + 2] == "](":
                            continue
                        bare = re.sub(r":\d+(?::\d+)?$", "", cand)
                        if os.path.exists(os.path.join(REPO_ROOT, bare)):
                            continue
                        # A tier-less `docs/plans/<slug>.md` resolves when the
                        # slug exists in any tier — same rule the link checker
                        # already applies, so a plan moving active -> shipped
                        # does not turn every citation of it into a warning.
                        if plan_tierless_resolves(os.path.join(REPO_ROOT, bare)):
                            continue
                        if not _develop_cache:
                            _develop_cache.append(_develop_tree())
                        tracked = _develop_cache[0]
                        # Unknown develop (shallow clone / fresh fork) means we
                        # cannot answer — stay silent rather than warn on every
                        # path in the file.
                        if tracked is None or bare in tracked:
                            continue
                        span_warnings.append((rel_src_path, lineno, cand))
                for m in LINK_RE.finditer(line):
                    href = m.group(1)
                    # Skip absolute / external / mailto.
                    if href.startswith(("/", "http://", "https://", "mailto:",
                                        "ftp://", "file://", "data:")):
                        continue
                    # Split off the anchor fragment (rule 3 checks it below).
                    href_path, _sep, fragment = href.partition("#")
                    rel_src = os.path.relpath(path, REPO_ROOT).replace(os.sep, "/")
                    if not href_path:
                        # Same-file anchor (`#section`): the source's own headings.
                        if fragment and not fragment_resolves(path, fragment):
                            violations.append((rel_src, lineno, href, rel_src + "#" + fragment))
                        continue
                    # Strip `:NNN` line-anchor suffix — `[label](Foo.cpp:123)`
                    # is widely used in plan-docs as a file+line reference.
                    # Treat as if pointing at the file.
                    line_match = re.match(r"^(.*?):\d+(?::\d+)?$", href_path)
                    if line_match:
                        href_path = line_match.group(1)
                    # Resolve relative to the file's directory.
                    src_dir = os.path.dirname(path)
                    target = os.path.normpath(os.path.join(src_dir, href_path))
                    landed = target if os.path.exists(target) else plan_tierless_target(target)
                    rel_tgt = os.path.relpath(landed or target, REPO_ROOT).replace(os.sep, "/")
                    if landed is None:
                        violations.append((rel_src, lineno, href, rel_tgt))
                    elif fragment and not fragment_resolves(landed, fragment):
                        violations.append((rel_src, lineno, href, rel_tgt + "#" + fragment))
    except (OSError, UnicodeDecodeError) as exc:
        sys.stderr.write(f"WARN: could not read {path}: {exc}\n")
    checked += 1

if SCOPE == "baseline":
    entries = sorted({(src, href, tgt) for src, _lineno, href, tgt in violations})
    out_path = os.path.join(REPO_ROOT, BASELINE_PATH)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(render_baseline(entries) + "\n")
    print(f"test-markdown-links: regenerated {BASELINE_PATH} "
          f"({len(entries)} grandfathered link(s)) — review + commit it.")
    print(f"Passed: 1  Failed: 0  (scanned {checked} markdown file(s))")
    sys.exit(0)

# --all consults the grandfather file so the target set could be widened without a
# 14-item cleanup blocking the slice. Diff-scope does NOT: it already grandfathers by
# scope (it only ever sees markdown a change actually touched), so consulting the
# baseline there would double-grandfather and let a NEW break slip through on a file
# that happens to carry an old one.
# Except in a standalone agent layer: the layer repo checked out on its own, which
# its project.config.json marks with "profile": "agent-layer". There the baseline
# holds links into the host's tree, which cannot resolve without a host, so
# "touching a file means fixing its links" would fail every layer PR that edits
# such a file. A new break with a new href still fails. A positive marker, so a
# host checkout missing something (a sparse checkout) still fails closed.
def _standalone_layer():
    try:
        with open(os.path.join(REPO_ROOT, "project.config.json"), encoding="utf-8") as fh:
            cfg = json.load(fh)
    except (OSError, ValueError):
        return False
    return isinstance(cfg, dict) and cfg.get("profile") == "agent-layer"


STANDALONE_LAYER = _standalone_layer()
baseline = read_baseline() if (SCOPE == "all" or STANDALONE_LAYER) else set()
reportable = [v for v in violations if (v[0], v[2]) not in baseline]
grandfathered = len(violations) - len(reportable)

for src, lineno, href, tgt in reportable:
    if "#" in tgt:
        _file, _sep, _frag = tgt.partition("#")
        print(f"{src}:{lineno}: BROKEN_LINK: '{href}' — no heading in {_file} has the "
              f"GitHub anchor '#{_frag}'", file=sys.stderr)
    else:
        print(f"{src}:{lineno}: BROKEN_LINK: '{href}' does not resolve (looked at {tgt})",
              file=sys.stderr)

if SCOPE == "all":
    stale = sorted(baseline - {(v[0], v[2]) for v in violations})
    if grandfathered:
        print(f"NOTE: {grandfathered} dangling link(s) grandfathered in {BASELINE_PATH} "
              f"— burn down and re-run --baseline.", file=sys.stderr)
    if stale:
        print(f"NOTE: {len(stale)} baselined link(s) already fixed — re-run --baseline to shrink "
              f"the grandfather set: " + ", ".join(f"{s}::{h}" for s, h in stale), file=sys.stderr)

# WARN-first and deliberately NOT part of the exit code: a reference to a path on
# another unmerged branch is legitimate, and that entry should then carry the
# "not on develop yet" caveat in prose — which is exactly the review this warning
# prompts (tooling 2026-08-07).
for src, lineno, cand in span_warnings:
    print(f"{src}:{lineno}: WARN: code-span path '{cand}' resolves neither in the worktree "
          f"nor at origin/develop — fix it, or note in prose that it is not on develop yet.",
          file=sys.stderr)

# Diff scope with nothing in it (no markdown touched vs the base) checked nothing:
# say so with an explicit Skipped marker rather than a vacuous 0/0 pass, which
# test-all.sh flags as a possible silent skip.
if SCOPE == "diff" and checked == 0:
    print("Passed: 0  Failed: 0  Skipped: 1  (no in-scope markdown changed — nothing to check)")
    sys.exit(0)

passed = checked - (1 if reportable else 0)
failed = 1 if reportable else 0
print(f"Passed: {passed}  Failed: {failed}  (scanned {checked} markdown file(s); "
      f"{len(reportable)} dangling link(s)"
      + (f"; {grandfathered} grandfathered" if grandfathered else "") + ")")
sys.exit(1 if reportable else 0)
PY
