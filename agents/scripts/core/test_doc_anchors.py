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
  6. Any other markdown citation — `<path>.md § <heading>`, with or without the
     backticks, or a `[label](<path>.md) § <heading>` link — resolves against
     THAT file's headings + bold-prefix paragraphs, with step 3's matching. The
     path is tried relative to the scan root and to the citing file (the citing
     file first for `./`, `../`, a link href and a bare basename); an
     `agent-layer/` prefix names
     the layer tree this checker reads its anchors from (then the scan root's
     own agent-layer/ mount); an unprefixed path missing from the scan root is
     also tried in the layer tree (a host doc citing docs/agent-rules/<x>.md).
     A bare basename (no `/`, not a link href) that names no sibling and no root
     file is looked up in the rule-doc directories: the layer's docs/agent-rules/
     and docs/guides/, and, from a host, the host's docs/guides/. When several
     files answer to the name (a sibling and a root README.md, or the same
     basename in two rule-doc directories) the citation resolves against all of
     them: an ambiguous path never fails a section any candidate has.
     A path that names no existing file is skipped and counted, never failed:
     a dangling path is test-markdown-links.sh's finding, not this one.

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
    # Shipped plans are frozen history (test-markdown-links.sh excludes them for
    # the same reason): a section their prose cited has since been renamed, and
    # nobody acts on a shipped plan's pointers.
    ":(exclude)docs/plans/shipped/**",
    ":(exclude)docs/plans/active/applied/**",
)

# A markdown path immediately followed (after an optional closing backtick and/or
# link paren) by the section sign. Group 1 is the path; group 2 is the closing
# punctuation, so a link href (`)`) can be told apart from a bare or backticked
# path. AGENTS.md citations keep steps 1-5; any other .md is step 6. The section
# name is the text after the match, cut at TERMINATOR_CHARS. One line may carry
# several citations, so this is iterated, not searched once.
REFERENCE_RE = re.compile(r"(?<![\w./\-])((?:[\w.\-]+/)*[\w.\-]+\.md)(`?\)?|\)?`?)\s*§\s*(?=[A-Za-z])")
AGENT_LAYER_PREFIX = "agent-layer/"

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


def name_variants(name: str) -> list[str]:
    """The names a heading or bold label is cited by: the full text, plus the text
    without parenthetical asides ("Remote-container (cloud sandbox) bootstrap" is
    cited as "Remote-container bootstrap"), without a leading list number ("7.
    Gate-check vs baseline"), and the head before an em-dash subtitle ("PR batching
    — logical-feature granularity" is cited as "PR batching"), and the text without
    code-span backticks (a backtick ends a cited name, so "The `405 ... is
    cancelled` recovery" can only be cited as "The 405 ..."). Each variant only
    adds a way to RESOLVE, so the set can only become more lenient, never stricter.
    """
    out = [name]
    bare = re.sub(r"\s+", " ", re.sub(r"\s*\([^()]*\)", "", name)).strip().rstrip(".:").strip()
    bare = re.sub(r"^\d+[.)]\s+", "", bare)
    for cand in (bare, bare.split(" — ", 1)[0].strip(), name.replace("`", "").strip()):
        if cand and cand not in out:
            out.append(cand)
    return out


def collect_anchors(files: list[Path]) -> list[str]:
    """Return the union of headings + bold-prefix paragraph names in `files`."""
    anchors: set[str] = set()
    heading_re = re.compile(r"^\s{0,3}#{1,6}\s+(.+?)\s*$", re.MULTILINE)
    # Bold-prefix paragraphs — match `**Name**` at the start of a line / bullet /
    # numbered item. Tolerates trailing ` (...)` / ` —` / `:` because AGENTS.md
    # uses `**Available libs** (FetchContent, linked):` style.
    # A `> ` blockquote marker is allowed in front: a callout's bold label is a
    # paragraph name like any other.
    bold_prefix_re = re.compile(
        r"^\s*(?:>\s*)?(?:[-*]|\d+\.)?\s*\*\*([A-Z][^*]+?)\*\*", re.MULTILINE
    )
    # A bold label that opens with a code span — **`[pre-first-push gate]` (…)** —
    # may start lower-case: the backticks make it a deliberate, distinctive name,
    # not an emphasised word. The name is the code span's text.
    code_label_re = re.compile(
        r"^\s*(?:>\s*)?(?:[-*]|\d+\.)?\s*\*\*`\[?([^`\]]{3,}?)\]?`", re.MULTILINE
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
                anchors.update(name_variants(heading))
        for regex in (bold_prefix_re, code_label_re):
            for m in regex.finditer(text):
                name = m.group(1).strip()
                if name:
                    anchors.update(name_variants(name))
    return sorted(anchors, key=len, reverse=True)  # Longest first for greedy match.


def section_name(raw: str) -> str:
    """The section name at the start of `raw` (the text after the section sign)."""
    # Stop at the first terminator character.
    term = TERMINATOR_CHARS.search(raw)
    if term:
        raw = raw[: term.start()]
    # Trim connective tail words like "gains a", "encoded as", etc.
    return CONNECTIVE_TAIL_RE.sub("", raw).strip()


def collect_references(scan_root: Path, env: dict[str, str] | None = None) -> list[tuple[str, str, int, str, bool]]:
    """Return [(extracted_name, file_path, line_number, cited_md_path, is_link_href), ...]."""
    cmd = [
        "git",
        "-c",
        "core.quotePath=false",
        "grep",
        "-n",
        "-E",
        r"\.md`?\)?`?[[:space:]]*§[[:space:]]*[A-Za-z]",
        "--",
        *SCAN_GLOBS,
        *EXCLUDE_GLOBS,
    ]
    try:
        out = subprocess.check_output(cmd, cwd=scan_root, text=True, encoding="utf-8", env=env)
    except subprocess.CalledProcessError as exc:
        if exc.returncode == 1:
            return []  # No matches.
        raise
    refs: list[tuple[str, str, int, str, bool]] = []
    for line in out.splitlines():
        # Format: <file>:<line>:<content>
        try:
            file_path, line_no_str, content = line.split(":", 2)
            line_no = int(line_no_str)
        except ValueError:
            continue
        for match in REFERENCE_RE.finditer(content):
            name = section_name(content[match.end():])
            if name:
                refs.append((name, file_path, line_no, match.group(1), ")" in match.group(2)))
    return refs


def leaf_target(prefix: str, ref_file: str, scan_root: Path, root_contracts: set[Path]) -> Path | None:
    """Return the subsystem leaf a path-qualified reference names, else None.

    None means "resolve against the shared anchor set": no path prefix, a path
    to a root contract, or a path that names no existing file inside the scan
    root (kept lenient, as before path-qualified references were resolved). A
    `./` or `../` prefix is relative to the referencing file, so its directory is
    tried first; any other prefix is repo-relative, so the scan root is.
    """
    if not prefix:
        return None
    root = scan_root.resolve()
    file_dir = (scan_root / ref_file).parent
    bases = (file_dir, scan_root) if prefix.startswith(("./", "../")) else (scan_root, file_dir)
    for base in bases:
        candidate = (base / prefix / "AGENTS.md").resolve()
        if candidate != root / "AGENTS.md" and root not in candidate.parents:
            continue  # outside the scanned tree: never this repo's leaf
        if candidate.is_file():
            return None if candidate in root_contracts else candidate
    return None


def _inside(candidate: Path, roots: tuple[Path, ...]) -> bool:
    return any(candidate == r or r in candidate.parents for r in roots)


def cited_files(path: str, ref_file: str, is_href: bool, repo_root: Path, scan_root: Path) -> tuple[Path, ...]:
    """The markdown file(s) a step-6 citation names; empty when no candidate exists.

    Candidates must lie inside the scan root or the layer tree, so a `../` chain
    can never resolve against an arbitrary file on the machine. A path with a
    directory part names the first existing candidate. A bare basename names
    every existing sibling / root candidate, else every existing rule-doc
    directory candidate (module doc step 6); the caller resolves the section
    against their union, so ambiguity can only make a citation pass.
    """
    scan = scan_root.resolve()
    layer = repo_root.resolve()
    file_dir = (scan / ref_file).parent

    def existing(cands: list[Path]) -> list[Path]:
        out: list[Path] = []
        for cand in cands:
            cand = cand.resolve()
            if _inside(cand, (scan, layer)) and cand.is_file() and cand not in out:
                out.append(cand)
        return out

    if path.startswith(AGENT_LAYER_PREFIX):
        rest = path[len(AGENT_LAYER_PREFIX):]
        return tuple(existing([layer / rest, scan / "agent-layer" / rest])[:1])
    if path.startswith(("./", "../")) or ("/" in path and is_href):
        return tuple(existing([file_dir / path, scan / path, layer / path])[:1])
    if "/" in path:
        return tuple(existing([scan / path, file_dir / path, layer / path])[:1])
    # A bare basename: a script citing the README.md beside it means the sibling,
    # a root contract the root file; one that names neither is a rule-doc
    # shorthand (`process-rules.md`, `perf-workflow.md`). A link href is
    # file-relative by markdown's rules, so it gets no rule-doc fallback.
    found = existing([file_dir / path, scan / path, layer / path])
    if not found and not is_href:
        found = existing([
            layer / "docs" / "agent-rules" / path,
            layer / "docs" / "guides" / path,
            scan / "docs" / "guides" / path,
        ])
    return tuple(found)


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


def run(repo_root: Path, scan_root: Path, env: dict[str, str] | None = None) -> int:
    anchor_files = shared_anchor_files(repo_root)
    anchors = collect_anchors(anchor_files)
    root_contracts = {
        p.resolve()
        for p in (repo_root / "AGENTS.md", scan_root / "AGENTS.md", scan_root / "agent-layer" / "AGENTS.md")
    }
    refs = collect_references(scan_root, env)

    # Dedup the references by (target file, extracted name) to keep the output
    # compact while preserving one example file:line per broken name. An empty
    # target key is the shared AGENTS.md + docs/agent-rules/ anchor set.
    by_key: dict[tuple[str, str], tuple[str, int]] = {}
    leaves: dict[str, Path] = {}
    cited: dict[str, Path] = {}
    unresolved_paths = 0
    for name, file_path, line_no, path, is_href in refs:
        target_key = ""
        if path.rsplit("/", 1)[-1] == "AGENTS.md":
            prefix = path[: -len("AGENTS.md")]
            leaf = leaf_target(prefix, file_path, scan_root, root_contracts)
            if leaf is not None:
                target_key = display_path(leaf, scan_root)
                leaves[target_key] = leaf
        else:
            found = cited_files(path, file_path, is_href, repo_root, scan_root)
            if not found:
                unresolved_paths += 1
                continue
            target_key = " or ".join(display_path(t, scan_root) for t in found)
            cited[target_key] = list(found)
        by_key.setdefault((target_key, name), (file_path, line_no))
    targets: dict[str, list[Path]] = {**cited, **{k: [v] for k, v in leaves.items()}}

    target_anchors: dict[str, list[str]] = {}
    failed: list[tuple[str, str, str, int]] = []
    resolved_count = 0
    for (target_key, name), (file_path, line_no) in sorted(by_key.items()):
        if target_key:
            if target_key not in target_anchors:
                target_anchors[target_key] = collect_anchors(targets[target_key])
            candidates = target_anchors[target_key]
        else:
            candidates = anchors
        if resolves(name, candidates):
            resolved_count += 1
        else:
            failed.append((target_key, name, file_path, line_no))

    total = len(by_key)
    print("test-doc-anchors — cross-link audit for <file>.md § <section> citations")
    print(f"  Anchor source: AGENTS.md + {len(anchor_files) - 1} file(s) under docs/agent-rules/"
          f" + {len(leaves)} path-qualified subsystem leaf file(s)"
          f" + {len({f for fs in cited.values() for f in fs})} other cited markdown file(s)")
    print(f"  Distinct anchors:       {len(anchors)}")
    print(f"  Distinct references:    {total}")
    print(f"  Resolved:               {resolved_count}")
    print(f"  Broken:                 {len(failed)}")
    print(f"  Skipped (path names no existing file): {unresolved_paths}")

    if failed:
        print()
        print(f"FAILED — {len(failed)} reference(s) name a section that doesn't")
        print("match any anchor in AGENTS.md or docs/agent-rules/*.md (or, for a")
        print("path-qualified reference, in the file it names):")
        for target_key, name, file_path, line_no in failed:
            print(f"  - {name!r}" + (f" in {target_key}" if target_key else ""))
            print(f"      first occurrence: {file_path}:{line_no}")
        print()
        print("Fix options:")
        print("  1. Add the section (a heading or a **Bold**: paragraph) to the cited file.")
        print("  2. Rename the reference to match an existing section name.")
        print("  3. Point the reference at the file the section moved to.")
        return 1

    print()
    print("PASS — every <file>.md § <section> reference resolves.")
    return 0


def selftest() -> int:
    """Synthetic tree: a passing set of references, then one that must fail."""
    # Strip every GIT_* variable: a git hook exports GIT_DIR (and friends) into
    # this process, and git would then init / stage / grep the CALLER's repository
    # instead of the temp tree.
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp).resolve()
        (root / "docs" / "agent-rules").mkdir(parents=True)
        (root / "Source" / "Core" / "src" / "Ui").mkdir(parents=True)
        (root / "AGENTS.md").write_text("# Root\n\n## Root rules\n", encoding="utf-8")
        (root / "docs" / "agent-rules" / "shared.md").write_text(
            "## Shared section\n\n## Rule doc only\n", encoding="utf-8")
        (root / "Source" / "Core" / "src" / "Ui" / "AGENTS.md").write_text(
            "# Ui\n\n## Grid\n\n**Docking**: rules.\n", encoding="utf-8")
        # The section sign is spliced in so this source file's own scan (it is a
        # *.py under the scan root) does not read the fixtures as real references.
        sec = "\u00a7"
        (root / "docs" / "refs.md").write_text(
            f"See AGENTS.md {sec} Root rules.\n"
            f"See Source/Core/src/Ui/AGENTS.md {sec} Grid.\n"
            f"See Source/Core/src/Ui/AGENTS.md {sec} Docking.\n"
            f"See agent-layer/AGENTS.md {sec} Shared section.\n"
            f"See `docs/agent-rules/shared.md` {sec} Rule doc only.\n"
            f"See [shared](agent-rules/shared.md) {sec} Shared section.\n",
            encoding="utf-8")
        # A file-relative reference resolves against the sibling leaf.
        (root / "Source" / "Core" / "src" / "Ui" / "README.md").write_text(
            f"See ./AGENTS.md {sec} Grid.\n", encoding="utf-8")
        subprocess.run(["git", "init", "-q", str(root)], check=True, env=env)
        subprocess.run(["git", "-C", str(root), "add", "-A"], check=True, env=env)
        with contextlib.redirect_stdout(io.StringIO()):
            clean = run(root, root, env)
        # selftest: asserts-failure — a leaf-qualified reference to a ROOT-only
        # section must fail: it names the leaf, and the leaf has no such heading.
        (root / "docs" / "bad.md").write_text(
            f"See Source/Core/src/Ui/AGENTS.md {sec} Root rules.\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(root), "add", "-A"], check=True, env=env)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            broken = run(root, root, env)
        # selftest: asserts-failure — a step-6 citation of a heading its file lacks
        # must fail, though the shared anchor set has that heading (AGENTS.md).
        (root / "docs" / "bad.md").write_text(
            f"See `docs/agent-rules/shared.md` {sec} Root rules.\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(root), "add", "-A"], check=True, env=env)
        buf6 = io.StringIO()
        with contextlib.redirect_stdout(buf6):
            broken6 = run(root, root, env)
    if clean != 0:
        print("test-doc-anchors --selftest: FAIL — a consistent tree reported broken references")
        return 1
    if broken != 1 or "in Source/Core/src/Ui/AGENTS.md" not in buf.getvalue():
        print("test-doc-anchors --selftest: FAIL — a leaf reference to a root-only section was not caught")
        return 1
    if broken6 != 1 or "'Root rules' in docs/agent-rules/shared.md" not in buf6.getvalue():
        print("test-doc-anchors --selftest: FAIL — a <path>.md citation of a missing heading was not caught")
        return 1
    print("test-doc-anchors --selftest: PASS — root, leaf, mount and <path>.md references resolve;"
          " a wrong leaf section and a wrong <path>.md section fail.")
    return 0


def main() -> int:
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    return run(REPO_ROOT, SCAN_ROOT)


if __name__ == "__main__":
    sys.exit(main())
