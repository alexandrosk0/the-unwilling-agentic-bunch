#!/usr/bin/env python3
"""test_doc_anchors.py — verify every `AGENTS.md § <section>` reference resolves.

Problem (process.md 2026-05-19 orchestrator P3 — cross-link rot):
Across the repo, ~74 files reference AGENTS.md sections by name. The
redirect-stub pattern from PR #273 (AGENTS.md § Delegation lifted to
docs/agent-rules/delegation.md) is convention-only — nothing automated
catches a typo or stale anchor today.

Strategy:
  1. Collect the valid anchor set = headings (## / ###) + bold-prefix
     paragraphs (^**Name**:) from AGENTS.md and every docs/agent-rules/*.md.
  2. Walk the repo, find every `AGENTS.md § <name>` reference, extract
     <name> conservatively (stop at sentence punctuation / closing bracket).
  3. For each reference, find the longest anchor that is a substring of
     the extracted name. If no anchor matches, the reference is broken.
  4. Skip vendored / generated / archive paths.
  5. A reference that names its AGENTS.md by path ("Source/Core/src/Ui/AGENTS.md
     § Grid") and points at an existing subsystem leaf resolves against THAT
     file's headings only. The root contract (this tree's AGENTS.md, the host's,
     the agent-layer/ mount's) and a path naming no existing file keep step 1's
     shared anchor set.

Bucket A (CLI). Zero manual steps. Invoked from agents/scripts/core/test-doc-anchors.sh,
which runs --selftest (synthetic tree, asserts a pass and a failure) first.
"""

from __future__ import annotations

import contextlib
import io
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


# The anchors (AGENTS.md + docs/agent-rules/) are agent-layer content: read from this
# file's own tree. The references are scanned in PROJECT_ROOT — the host once the
# layer is the agent-layer/ submodule (test-doc-anchors.sh exports it), this tree
# before the flip and in the layer's own CI.
REPO_ROOT = Path(__file__).resolve().parents[3]
SCAN_ROOT = Path(os.environ.get("PROJECT_ROOT") or REPO_ROOT).resolve()

# Files searched for `AGENTS.md §` references — limit to source / docs / scripts.
SCAN_GLOBS = (
    "*.md",
    "*.sh",
    "*.py",
    "*.h",
    "*.cpp",
    "*.hpp",
    "*.json",
    "*.yaml",
    "*.yml",
)

# Paths excluded from the reference scan (vendored / archives / generated).
EXCLUDE_GLOBS = (
    ":(exclude)build/**",
    ":(exclude).fetchcontent-src/**",
    ":(exclude).claude/worktrees/**",
    ":(exclude)docs/plans/active/_plan-locks-archive.md",
    ":(exclude)docs/plans/active/_plan-locks.generated.md",
    ":(exclude)docs/self-improvement/categories/applied.md",
    # Rotated monthly partitions of applied.md (rotate-applied-md.sh): the same
    # archive, so the same stale-section-reference expectation applies.
    ":(exclude)docs/self-improvement/categories/applied-*.md",
)

# The optional group captures a path prefix ("Source/Core/src/Ui/"), so a
# reference can name the AGENTS.md it means; see step 5 of the module doc.
REFERENCE_RE = re.compile(r"((?:[\w.\-]+/)*)AGENTS\.md\s*§\s*(.+)")

# Terminators that end a section-name reference: opening + closing punctuation,
# quotes, brackets, markdown-table pipes. Section names never contain these.
TERMINATOR_CHARS = re.compile(r"[\[\].,;:()+\"`<>|]")

# Connective words that often appear right after a section name in prose —
# trim them off so "X gains Y" becomes "X" alone.
# Note: words like `note`, `rule`, `comment` are NOT in this list because they
# appear in legitimate section names (`Anti-deception note`, `Post-split
# include-replication rule`, etc.).
CONNECTIVE_TAIL_RE = re.compile(
    r"\s+(?:and|or|to|for|if|when|per|so|under|above|below|after|before|with|"
    r"from|into|on|in|of|the|that|this|which|since|until|see|gains?|gained|"
    r"encoded?|documents?|documented?|covered?|adds?|extends?|naming|states?|"
    r"stating|lists?|listing|paragraph|sub-section|invocation|"
    r"here|directly|now|via|already|"
    r"alone|exists|missing|empty|present|absent|first|then|next|last|also|"
    r"only|too|either|both)\b.*$"
)


def shared_anchor_files(repo_root: Path) -> list[Path]:
    """Anchor sources for an unqualified reference: AGENTS.md + docs/agent-rules/*.md."""
    return [repo_root / "AGENTS.md"] + sorted((repo_root / "docs" / "agent-rules").glob("*.md"))


def collect_anchors(files: list[Path]) -> list[str]:
    """Return the union of headings + bold-prefix paragraph names in `files`."""
    anchors: set[str] = set()
    heading_re = re.compile(r"^\s{0,3}#{1,6}\s+(.+?)\s*$", re.MULTILINE)
    # Bold-prefix paragraphs — match `**Name**` at the start of a line / bullet /
    # numbered item. Tolerates trailing ` (...)` / ` —` / `:` because AGENTS.md
    # uses `**Available libs** (FetchContent, linked):` style.
    bold_prefix_re = re.compile(
        r"^\s*(?:[-*]|\d+\.)?\s*\*\*([A-Z][^*]+?)\*\*", re.MULTILINE
    )
    for f in files:
        try:
            text = f.read_text(encoding="utf-8")
        except FileNotFoundError:
            continue
        for m in heading_re.finditer(text):
            heading = m.group(1).strip()
            # Strip trailing comment tokens like `<!-- tier: portable -->`.
            heading = re.sub(r"\s*<!--.*?-->\s*$", "", heading).strip()
            if heading:
                anchors.add(heading)
        for m in bold_prefix_re.finditer(text):
            name = m.group(1).strip()
            if name:
                anchors.add(name)
    return sorted(anchors, key=len, reverse=True)  # Longest first for greedy match.


def collect_references(scan_root: Path) -> list[tuple[str, str, int, str]]:
    """Return [(extracted_name, file_path, line_number, path_prefix), ...]."""
    cmd = [
        "git",
        "grep",
        "-n",
        "-E",
        r"AGENTS\.md\s*§\s*[A-Za-z]",
        "--",
        *SCAN_GLOBS,
        *EXCLUDE_GLOBS,
    ]
    try:
        out = subprocess.check_output(cmd, cwd=scan_root, text=True, encoding="utf-8")
    except subprocess.CalledProcessError as exc:
        if exc.returncode == 1:
            return []  # No matches.
        raise
    refs: list[tuple[str, str, int, str]] = []
    for line in out.splitlines():
        # Format: <file>:<line>:<content>
        try:
            file_path, line_no_str, content = line.split(":", 2)
            line_no = int(line_no_str)
        except ValueError:
            continue
        match = REFERENCE_RE.search(content)
        if not match:
            continue
        prefix, raw = match.group(1), match.group(2)
        # Stop at the first terminator character.
        term = TERMINATOR_CHARS.search(raw)
        if term:
            raw = raw[: term.start()]
        # Trim connective tail words like "gains a", "encoded as", etc.
        raw = CONNECTIVE_TAIL_RE.sub("", raw)
        # Final trim.
        name = raw.strip()
        if name:
            refs.append((name, file_path, line_no, prefix))
    return refs


def leaf_target(prefix: str, ref_file: str, scan_root: Path, root_contracts: set[Path]) -> Path | None:
    """Return the subsystem leaf a path-qualified reference names, else None.

    None means "resolve against the shared anchor set": no path prefix, a path
    to a root contract, or a path that names no existing file (kept lenient, as
    before path-qualified references were resolved). The prefix is tried against
    the scan root, then against the referencing file's own directory.
    """
    if not prefix:
        return None
    for base in (scan_root, (scan_root / ref_file).parent):
        candidate = (base / prefix / "AGENTS.md").resolve()
        if candidate.is_file():
            return None if candidate in root_contracts else candidate
    return None


def resolves(name: str, anchors: list[str]) -> str | None:
    """Return the matching anchor (longest), or None if no match."""
    # Direct match — name IS an anchor.
    if name in anchors:
        return name
    # Substring match — an anchor is a prefix / inside the extracted name.
    # Anchors are sorted longest-first so we get the most specific hit.
    for anchor in anchors:
        if anchor in name:
            return anchor
    # Reverse substring — extracted name is shorter than an anchor (partial).
    for anchor in anchors:
        if name in anchor:
            return anchor
    return None


def display_path(path: Path, scan_root: Path) -> str:
    """`path` relative to the scan root when it lies inside it, else absolute."""
    try:
        return path.relative_to(scan_root.resolve()).as_posix()
    except ValueError:
        return str(path)


def run(repo_root: Path, scan_root: Path) -> int:
    anchor_files = shared_anchor_files(repo_root)
    anchors = collect_anchors(anchor_files)
    root_contracts = {
        p.resolve()
        for p in (repo_root / "AGENTS.md", scan_root / "AGENTS.md", scan_root / "agent-layer" / "AGENTS.md")
    }
    refs = collect_references(scan_root)

    # Dedup the references by (target leaf, extracted name) to keep the output
    # compact while preserving one example file:line per broken name.
    by_key: dict[tuple[str, str], tuple[str, int]] = {}
    leaves: dict[str, Path] = {}
    for name, file_path, line_no, prefix in refs:
        leaf = leaf_target(prefix, file_path, scan_root, root_contracts)
        leaf_key = ""
        if leaf is not None:
            leaf_key = display_path(leaf, scan_root)
            leaves[leaf_key] = leaf
        by_key.setdefault((leaf_key, name), (file_path, line_no))

    leaf_anchors: dict[str, list[str]] = {}
    failed: list[tuple[str, str, str, int]] = []
    resolved_count = 0
    for (leaf_key, name), (file_path, line_no) in sorted(by_key.items()):
        if leaf_key:
            if leaf_key not in leaf_anchors:
                leaf_anchors[leaf_key] = collect_anchors([leaves[leaf_key]])
            candidates = leaf_anchors[leaf_key]
        else:
            candidates = anchors
        if resolves(name, candidates):
            resolved_count += 1
        else:
            failed.append((leaf_key, name, file_path, line_no))

    total = len(by_key)
    print("test-doc-anchors — cross-link audit for AGENTS.md sections")
    print(f"  Anchor source: AGENTS.md + {len(anchor_files) - 1} file(s) under docs/agent-rules/"
          f" + {len(leaves)} path-qualified subsystem leaf file(s)")
    print(f"  Distinct anchors:       {len(anchors)}")
    print(f"  Distinct references:    {total}")
    print(f"  Resolved:               {resolved_count}")
    print(f"  Broken:                 {len(failed)}")

    if failed:
        print()
        print(f"FAILED — {len(failed)} reference(s) name a section that doesn't")
        print("match any anchor in AGENTS.md or docs/agent-rules/*.md (or, for a")
        print("path-qualified reference, in the subsystem leaf it names):")
        for leaf_key, name, file_path, line_no in failed:
            print(f"  - {name!r}" + (f" in {leaf_key}" if leaf_key else ""))
            print(f"      first occurrence: {file_path}:{line_no}")
        print()
        print("Fix options:")
        print("  1. Add the section to AGENTS.md or docs/agent-rules/<X>.md.")
        print("  2. Rename the reference to match an existing section name.")
        print("  3. Update AGENTS.md redirect stub to mention the moved name.")
        return 1

    print()
    print("PASS — every AGENTS.md § <section> reference resolves.")
    return 0


def selftest() -> int:
    """Synthetic tree: a passing set of references, then one that must fail."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp).resolve()
        (root / "docs" / "agent-rules").mkdir(parents=True)
        (root / "Source" / "Core" / "src" / "Ui").mkdir(parents=True)
        (root / "AGENTS.md").write_text("# Root\n\n## Root rules\n", encoding="utf-8")
        (root / "docs" / "agent-rules" / "shared.md").write_text("## Shared section\n", encoding="utf-8")
        (root / "Source" / "Core" / "src" / "Ui" / "AGENTS.md").write_text(
            "# Ui\n\n## Grid\n\n**Docking**: rules.\n", encoding="utf-8")
        # The section sign is spliced in so this source file's own scan (it is a
        # *.py under the scan root) does not read the fixtures as real references.
        sec = "\u00a7"
        (root / "docs" / "refs.md").write_text(
            f"See AGENTS.md {sec} Root rules.\n"
            f"See Source/Core/src/Ui/AGENTS.md {sec} Grid.\n"
            f"See Source/Core/src/Ui/AGENTS.md {sec} Docking.\n"
            f"See agent-layer/AGENTS.md {sec} Shared section.\n",
            encoding="utf-8")
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
        with contextlib.redirect_stdout(io.StringIO()):
            clean = run(root, root)
        # A leaf-qualified reference to a ROOT-only section must fail: it names
        # the leaf, and the leaf has no such heading.
        (root / "docs" / "bad.md").write_text(
            f"See Source/Core/src/Ui/AGENTS.md {sec} Root rules.\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            broken = run(root, root)
    if clean != 0:
        print("test-doc-anchors --selftest: FAIL — a consistent tree reported broken references")
        return 1
    if broken != 1 or "in Source/Core/src/Ui/AGENTS.md" not in buf.getvalue():
        print("test-doc-anchors --selftest: FAIL — a leaf reference to a root-only section was not caught")
        return 1
    print("test-doc-anchors --selftest: PASS — root, leaf and mount references resolve; a wrong leaf section fails.")
    return 0


def main() -> int:
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    return run(REPO_ROOT, SCAN_ROOT)


if __name__ == "__main__":
    sys.exit(main())
