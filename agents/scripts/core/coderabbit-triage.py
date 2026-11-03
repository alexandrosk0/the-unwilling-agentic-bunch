#!/usr/bin/env python3
"""
coderabbit-triage — classify CR findings against Smatchet invariants.

Phase 3 of `docs/plans/shipped/smatchet-merge-watcher.md`. Python port of
the override table in `agents/_shared/skills/coderabbit-triage/SKILL.md` (the
skill stays the source-of-truth for the rules; this is the executable mirror).

When `merge-watcher.py`'s daemon polls a PR + sees the gate BLOCKED on
CR findings (state == BLOCKED + last-CR-review has `Actionable comments
posted: N` with N > 0), it invokes this script:

  coderabbit-triage classify <owner> <repo> <pr>     # print per-finding verdicts
  coderabbit-triage post-comment <owner> <repo> <pr> # also POST a triage summary

and the skill's routing step runs:

  coderabbit-triage area <path>...                   # first matching area-map route

Each finding gets one of three verdicts:

- **VALID**: the finding is a real Smatchet bug or improvement. User
  should review + apply (Phase 3 doesn't auto-apply — see § Out of
  scope in plan-doc).
- **REJECT_INVARIANT**: the finding collides with a Smatchet invariant
  (C++14-hard, banned headers, RAII, LOG_*, etc.). Don't apply.
- **REJECT_AMBIGUOUS**: parser couldn't extract a confident
  classification. User decides.

Phase 3 v1 scope: classify + post the structured comment. Per-pattern
auto-fix dispatch deferred to a Phase 3.5 follow-up once we have
calibration data from a few real PR rounds.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Any

# triage-rules-version: 5
# Shared rules-version marker — MUST match
# agents/_shared/skills/coderabbit-triage/SKILL.md. `coderabbit-triage.py selftest`
# greps both files for this token and fails if they disagree (run in CI by
# tests/bats/coderabbit_triage.bats). Bump in BOTH whenever the login allow-list,
# override table, severity parse, or noise filter changes. v5: the skill replaces
# the agent + handoff skill; routing reads the project's area map. v4
# (bugbot-merge-gate): PR-bot login allow-list {coderabbitai[bot], cursor[bot]} +
# Bugbot body-shape severity parse + couldn't-run / usage-limit noise filter.

# PR-bot login allow-list (lower-cased substring match — covers both the REST
# `[bot]` suffix and the GraphQL-stripped form). CodeRabbit + Cursor Bugbot are
# live today; Greptile / Sweep join here as they appear (same routing rules).
PR_BOT_LOGIN_TOKENS = ("coderabbit", "cursor")

# Bugbot conversation-tab run-status notices ("### Bugbot couldn't run …",
# "usage limit reached") are spend/availability status, NOT findings — they must
# never enter the triage set (they are the merge-gate's no-wedge TERMINAL signal,
# never a block). Mirrors merge-gates.sh $bbterminal.
_BUGBOT_NOISE_RE = re.compile(r"couldn.t run|usage limit", re.IGNORECASE)


def _is_pr_bot_login(login: str) -> bool:
    """True when `login` is an allow-listed PR-bot (CodeRabbit or Cursor Bugbot)."""
    low = (login or "").lower()
    return any(tok in low for tok in PR_BOT_LOGIN_TOKENS)


def _is_bugbot_noise(body: str) -> bool:
    """True when a body is a Bugbot run-status notice (drop it from the triage set)."""
    return bool(_BUGBOT_NOISE_RE.search(body or ""))


class Verdict(str, Enum):
    VALID = "VALID"
    REJECT_INVARIANT = "REJECT_INVARIANT"
    REJECT_AMBIGUOUS = "REJECT_AMBIGUOUS"


@dataclass
class Finding:
    file: str
    line_range: str
    body: str  # raw text of the finding
    verdict: Verdict
    reason: str  # why this verdict


# ---------------------------------------------------------------------------
# Smatchet invariant patterns
# ---------------------------------------------------------------------------
# Each entry: (regex, one-line reason). If CR's finding body matches the
# regex, the finding is REJECT_INVARIANT.
#
# Sourced from AGENTS.md § Project rules. The skill's override table
# (`agents/_shared/skills/coderabbit-triage/SKILL.md`) is the long-form
# authoritative source; this list is the executable mirror — keep in sync per
# the watcher plan-doc § Risks § Phase 3 duplication drift.
INVARIANT_REJECTS: list[tuple[re.Pattern[str], str]] = [
    (
        re.compile(r"\bstd::string_view\b|`string_view`|<string_view>", re.IGNORECASE),
        "string_view banned (AGENTS.md § Project rules § Language: C++14 hard)",
    ),
    (
        re.compile(r"\bstd::optional\b|`optional`|<optional>", re.IGNORECASE),
        "std::optional banned (C++14 hard)",
    ),
    (
        re.compile(r"\bstd::variant\b|`variant`|<variant>", re.IGNORECASE),
        "std::variant banned (C++14 hard)",
    ),
    (
        re.compile(r"\bif\s+constexpr\b", re.IGNORECASE),
        "if constexpr banned (C++14 hard)",
    ),
    (
        re.compile(r"structured\s+binding|auto\s*\[\s*\w+\s*,", re.IGNORECASE),
        "structured bindings banned (C++14 hard)",
    ),
    (
        re.compile(r"\bstd::filesystem\b|<filesystem>", re.IGNORECASE),
        "std::filesystem banned (use ghc::filesystem from FetchContent)",
    ),
    (
        re.compile(r"\bprintf\b|\bstd::cerr\b|\bstd::cout\b", re.IGNORECASE),
        "printf/cerr/cout banned (use LOG_DEBUG/INFO/WARN/ERROR/TRACE per AGENTS.md § Logging)",
    ),
    (
        re.compile(r"\braw\s+new\b|`\s*new\s+[A-Z]|delete\s+\w+|raw\s+pointer", re.IGNORECASE),
        "raw new/delete banned (use std::unique_ptr + make_unique per AGENTS.md § Quality)",
    ),
    (
        re.compile(r"GLFW.*Source/Core/(?:include|src)/.*\.h", re.IGNORECASE),
        "GLFW headers banned in Source/Core/ (DX12 compiles them too — AGENTS.md § Don't)",
    ),
    (
        re.compile(
            r"obj\s*=\s*\{[^}]*\}|json\s*=\s*\{[^}]*\}",
            re.IGNORECASE,
        ),
        "nlohmann json reassign-with-brace-list won't compile (use obj[\"k\"] = v per AGENTS.md)",
    ),
    (
        re.compile(r"C\+\+1[78]|C\+\+2[0-9]", re.IGNORECASE),
        "C++17/20 features banned (C++14 hard for Unreal compat)",
    ),
]


# ---------------------------------------------------------------------------
# CR review body parser
# ---------------------------------------------------------------------------
FINDING_HEADER_RE = re.compile(
    r"In `@(?P<file>[^`]+)`:\s*\n\s*-\s+Around line[s]?\s*(?P<line_range>[\d\-,\s]+):",
    re.MULTILINE,
)

# Cursor Bugbot inline-finding body shape (per the bugbot-merge-gate plan's wire
# notes): a `### <title>` heading then a `**<Sev> Severity**` line then a
# `<!-- DESCRIPTION START -->` marker. Bugbot anchors file/line via the comment
# metadata, not the body, so a Bugbot body parses to {file: "", line_range: ""}
# here — the caller supplies path/line from the inline-comment JSON.
BUGBOT_SEVERITY_RE = re.compile(r"\*\*(High|Medium|Low)\s+Severity\*\*", re.IGNORECASE)
BUGBOT_MARKERS_RE = re.compile(r"<!--\s*BUGBOT_(?:REVIEW|FIX_ALL)\s*-->|<!--\s*DESCRIPTION START\s*-->|\*\*(?:High|Medium|Low)\s+Severity\*\*", re.IGNORECASE)


def looks_like_bugbot_body(body: str) -> bool:
    """True when a body carries Cursor Bugbot's wire markers (vs CodeRabbit's shape)."""
    return bool(BUGBOT_MARKERS_RE.search(body or ""))


def parse_bugbot_findings(body: str) -> list[dict[str, str]]:
    """Extract findings from a Cursor Bugbot finding/review body.

    Bugbot opens each finding with a `### <title>` heading then a
    `**<Sev> Severity**` line. Run-status notices (couldn't run / usage limit) are
    dropped as noise. Returns list of {file, line_range, body} (file/line empty —
    Bugbot line-anchors via the inline-comment metadata, not the body text).
    """
    if _is_bugbot_noise(body):
        return []
    findings: list[dict[str, str]] = []
    # Split on `### ` headings; each block is one finding. Fall back to the whole
    # body as a single finding when there are no headings (a bare inline comment).
    blocks = re.split(r"(?:^|\n)###\s+", body)
    candidates = blocks[1:] if len(blocks) > 1 else [body]
    for block in candidates:
        text = block.strip()
        if not text or _is_bugbot_noise(text):
            continue
        sev = BUGBOT_SEVERITY_RE.search(text)
        # Keep only blocks that actually look like a finding (carry a Severity
        # line or a DESCRIPTION marker) so prose/marker-only blocks are skipped.
        if not sev and "DESCRIPTION START" not in text.upper():
            continue
        findings.append({"file": "", "line_range": "", "body": text})
    return findings


def parse_findings(review_body: str) -> list[dict[str, str]]:
    """Extract findings from a PR-bot review body.

    Dispatches on body shape: Cursor Bugbot (`### <title>` + `**<Sev> Severity**`)
    vs CodeRabbit (the `In `@<file>`: - Around line N-M:` enumeration below).

    CR's format (post-2026):
      In `@<file>`:
      - Around line N-M: <body of finding>
        ... (multiple lines of explanation)
      - Around line P-Q: <next finding>

    Returns list of {file, line_range, body}.
    """
    if looks_like_bugbot_body(review_body):
        return parse_bugbot_findings(review_body)
    findings = []
    # Split on per-file 'In `@...`:' headers, then scan each file-block for
    # '- Around line ...' bullets.
    file_blocks = re.split(r"\nIn `@", "\n" + review_body)
    for block in file_blocks[1:]:  # skip pre-first-block prose
        # Reattach the marker we split on for header parsing.
        block = "In `@" + block
        file_match = re.search(r"In `@([^`]+)`:", block)
        if not file_match:
            continue
        file_path = file_match.group(1).strip()
        # Each '- Around line ...' bullet starts a finding within this block.
        bullets = re.split(r"(?:^|\n)-\s+Around line[s]?\s*", block)
        for bullet in bullets[1:]:
            # Bullet starts with "<line_range>: <body...>"
            colon = bullet.find(":")
            if colon == -1:
                continue
            line_range = bullet[:colon].strip()
            body = bullet[colon + 1:].strip()
            # Truncate at next file-block / next bullet boundary (already split).
            findings.append({"file": file_path, "line_range": line_range, "body": body})
    return findings


# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------
def classify_finding(finding: dict[str, str]) -> Finding:
    body = finding["body"]
    for pattern, reason in INVARIANT_REJECTS:
        if pattern.search(body):
            return Finding(
                file=finding["file"],
                line_range=finding["line_range"],
                body=body,
                verdict=Verdict.REJECT_INVARIANT,
                reason=reason,
            )
    # No invariant violation — VALID unless the body is too short to be
    # meaningful (< 40 chars suggests CR couldn't articulate a real fix).
    if len(body) < 40:
        return Finding(
            file=finding["file"],
            line_range=finding["line_range"],
            body=body,
            verdict=Verdict.REJECT_AMBIGUOUS,
            reason=f"finding body too short ({len(body)} chars) — parser can't classify confidently",
        )
    return Finding(
        file=finding["file"],
        line_range=finding["line_range"],
        body=body,
        verdict=Verdict.VALID,
        reason="no Smatchet invariant violation detected; user should review + apply",
    )


# ---------------------------------------------------------------------------
# gh wrappers
# ---------------------------------------------------------------------------
def fetch_cr_review_body(owner: str, repo: str, pr: int) -> str | None:
    """Fetch the latest CodeRabbit review body. Returns None if no CR review."""
    result = subprocess.run(
        [
            "gh",
            "pr",
            "view",
            str(pr),
            "--repo",
            f"{owner}/{repo}",
            "--json",
            "reviews,headRefOid",
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError(f"gh pr view {pr} failed: {result.stderr.strip()[:200]}")
    data = json.loads(result.stdout)
    head = data.get("headRefOid", "")
    reviews = data.get("reviews", [])
    # Allow-list match (CodeRabbit + Cursor Bugbot); drop Bugbot run-status notices
    # (couldn't run / usage limit) — those are not findings.
    bot_reviews = [
        r
        for r in reviews
        if _is_pr_bot_login((r.get("author", {}) or {}).get("login", ""))
        and not _is_bugbot_noise(r.get("body", ""))
    ]
    if not bot_reviews:
        return None
    # Latest bot review on current head; fall back to most-recent stale.
    on_head = [
        r
        for r in bot_reviews
        if (r.get("commit") or {}).get("oid") == head
    ]
    pool = on_head if on_head else bot_reviews
    pool.sort(key=lambda r: r.get("submittedAt", ""))
    return pool[-1].get("body", "")


def post_pr_comment(owner: str, repo: str, pr: int, body: str) -> bool:
    """POST a PR comment via gh api. Returns True on success."""
    result = subprocess.run(
        [
            "gh",
            "pr",
            "comment",
            str(pr),
            "--repo",
            f"{owner}/{repo}",
            "--body",
            body,
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=30,
    )
    return result.returncode == 0


# ---------------------------------------------------------------------------
# Report formatting
# ---------------------------------------------------------------------------
def format_triage_report(findings: list[Finding], pr: int, attempt: int, budget: int) -> str:
    lines = [
        "## `smatchet-merge-watcher` triage report",
        "",
        f"_Phase 3 classifier per `docs/plans/shipped/smatchet-merge-watcher.md`. Attempt {attempt}/{budget}._",
        "",
    ]
    if not findings:
        lines += [
            "_No findings parsed from CR's review body — either the format changed or there are no inline comments to triage._",
        ]
    else:
        valid = [f for f in findings if f.verdict == Verdict.VALID]
        invariant = [f for f in findings if f.verdict == Verdict.REJECT_INVARIANT]
        ambiguous = [f for f in findings if f.verdict == Verdict.REJECT_AMBIGUOUS]
        lines += [
            f"**Findings: {len(findings)} total — {len(valid)} VALID · {len(invariant)} REJECT-INVARIANT · {len(ambiguous)} REJECT-AMBIGUOUS**",
            "",
        ]
        if valid:
            lines += ["### ✅ VALID findings (user should review + apply)", ""]
            for f in valid:
                lines += [f"- [ ] **`{f.file}:{f.line_range}`** — {f.body[:200]}{'...' if len(f.body) > 200 else ''}", ""]
        if invariant:
            lines += ["### 🛑 REJECT-INVARIANT (Smatchet rule collision; do NOT apply)", ""]
            for f in invariant:
                lines += [f"- **`{f.file}:{f.line_range}`** — _{f.reason}_", f"  CR's suggestion: {f.body[:160]}{'...' if len(f.body) > 160 else ''}", ""]
        if ambiguous:
            lines += ["### ❓ REJECT-AMBIGUOUS (parser couldn't classify)", ""]
            for f in ambiguous:
                lines += [f"- **`{f.file}:{f.line_range}`** — {f.body[:160]}", ""]
    lines += [
        "",
        "---",
        "_Triage is advisory — no code changes have been applied. Apply VALID findings manually + push to clear._",
        f"_Generated by `agents/scripts/core/coderabbit-triage.py` on PR #{pr}._",
    ]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def cmd_classify(args: argparse.Namespace) -> int:
    body = fetch_cr_review_body(args.owner, args.repo, int(args.pr))
    if body is None:
        print("coderabbit-triage: no CR review on this PR", file=sys.stderr)
        return 1
    findings = [classify_finding(f) for f in parse_findings(body)]
    report = format_triage_report(findings, int(args.pr), int(args.attempt), int(args.budget))
    print(report)
    return 0


def cmd_post_comment(args: argparse.Namespace) -> int:
    body = fetch_cr_review_body(args.owner, args.repo, int(args.pr))
    if body is None:
        print("coderabbit-triage: no CR review on this PR", file=sys.stderr)
        return 1
    findings = [classify_finding(f) for f in parse_findings(body)]
    report = format_triage_report(findings, int(args.pr), int(args.attempt), int(args.budget))
    if post_pr_comment(args.owner, args.repo, int(args.pr), report):
        print(f"coderabbit-triage: posted triage report to PR #{args.pr}")
        return 0
    print(f"coderabbit-triage: failed to post comment to PR #{args.pr}", file=sys.stderr)
    return 2


# ---------------------------------------------------------------------------
# Area map — the project's path -> area routing table
# ---------------------------------------------------------------------------
# The map is HOST data (it names product paths), so it lives in the project tree,
# not in this layer: <project root>/docs/area-map.json. The project root is the
# PROJECT_ROOT that scripts/dev/project-config.sh resolves (roots-only), the same
# ladder sync-issue-labels.sh reads the map through: SMATCHET_PROJECT_CONFIG, the
# superproject when this layer is a submodule, else this layer's own tree, which
# has no map (routing then falls back to the skill's generic rows); a caller's
# PROJECT_ROOT counts when it names that tree or SMATCHET_PROJECT_ROOT_OVERRIDE=1.
# Without project-config.sh beside this script (a fixture copy) the root is its
# own tree; without a runnable bash (or a root python cannot open), the
# superproject probe alone decides.
# AREA_MAP_FILE names another map (bats fixtures). Doc paths resolve against the
# directory above the map's own directory — the project root for docs/area-map.json.
AREA_MAP_REL = Path("docs") / "area-map.json"


def _layer_root() -> Path:
    # This script lives at agents/scripts/core/ under the layer root.
    return Path(__file__).resolve().parents[3]


# Sources project-config.sh roots-only and prints PROJECT_ROOT, as a mixed-form
# Windows path under Git Bash (cygpath) so a native python can open it.
_ROOTS_SNIPPET = (
    'PC_ROOTS_ONLY=1 . "$1" || exit 1; '
    'if command -v cygpath >/dev/null 2>&1; then cygpath -m "${PROJECT_ROOT:-}"; '
    'else printf %s "${PROJECT_ROOT:-}"; fi'
)


def _project_root() -> Path:
    layer = _layer_root()
    config_sh = layer / "scripts" / "dev" / "project-config.sh"
    if not config_sh.is_file():
        return layer
    try:
        proc = subprocess.run(
            ["bash", "-c", _ROOTS_SNIPPET, "_", config_sh.as_posix()],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=10,
        )
        if proc.stderr:
            sys.stderr.write(proc.stderr)  # project-config.sh's WARN on an ignored PROJECT_ROOT
        resolved = proc.stdout.strip() if proc.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        resolved = ""
    if resolved and Path(resolved).is_dir():
        return Path(resolved)
    try:
        out = subprocess.run(
            ["git", "-C", str(layer), "rev-parse", "--show-superproject-working-tree"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=10,
        ).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        out = ""
    return Path(out) if out else layer


def _area_map_path() -> Path:
    override = os.environ.get("AREA_MAP_FILE", "").strip()
    return Path(override) if override else _project_root() / AREA_MAP_REL


def glob_to_regex(glob: str) -> re.Pattern[str]:
    """Compile an area-map glob: `**/` = any directories (or none), `**` = any
    characters, `*` / `?` = within one path segment, `{a,b}` = alternatives."""
    out: list[str] = []
    i = 0
    while i < len(glob):
        if glob.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif glob.startswith("**", i):
            out.append(".*")
            i += 2
        elif glob[i] == "*":
            out.append("[^/]*")
            i += 1
        elif glob[i] == "?":
            out.append("[^/]")
            i += 1
        elif glob[i] == "{" and "}" in glob[i:]:
            j = glob.index("}", i)
            out.append("(?:" + "|".join(re.escape(a) for a in glob[i + 1:j].split(",")) + ")")
            i = j + 1
        else:
            out.append(re.escape(glob[i]))
            i += 1
    return re.compile("".join(out) + r"\Z")


def load_area_map(path: Path) -> dict[str, Any]:
    """Parse the area map. Raises ValueError (with the reason) when malformed."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path}: not valid JSON ({exc})") from exc
    if not isinstance(data, dict) or not isinstance(data.get("routes"), list):
        raise ValueError(f"{path}: top level must be an object with a `routes` list")
    return data


def area_map_errors(data: dict[str, Any], doc_root: Path) -> list[str]:
    """Structural problems in a parsed area map (empty list = sound)."""
    errors: list[str] = []
    seen: set[str] = set()
    for i, route in enumerate(data["routes"]):
        where = f"routes[{i}]"
        if not isinstance(route, dict):
            errors.append(f"{where}: not an object")
            continue
        area = route.get("area")
        if area is not None and (not isinstance(area, str) or not area.strip()):
            errors.append(f"{where}: `area` must be a non-empty string or null")
        elif isinstance(area, str):
            if area in seen:
                errors.append(f"{where}: area `{area}` appears in more than one route")
            seen.add(area)
        globs = route.get("globs")
        if not isinstance(globs, list) or not globs or not all(isinstance(g, str) and g for g in globs):
            errors.append(f"{where}: `globs` must be a non-empty list of strings")
        docs = route.get("docs")
        if not isinstance(docs, list) or not docs or not all(isinstance(d, str) and d for d in docs):
            errors.append(f"{where}: `docs` must be a non-empty list of strings")
        else:
            for d in docs:
                if not (doc_root / d).exists():
                    errors.append(f"{where}: doc `{d}` does not exist under {doc_root}")
    generic = data.get("generic_areas", [])
    if not isinstance(generic, list) or not all(isinstance(g, str) and g for g in generic):
        errors.append("`generic_areas` must be a list of strings")
    else:
        for g in generic:
            if g in seen:
                errors.append(f"generic area `{g}` also owns a route")
    return errors


def route_for(data: dict[str, Any], path: str) -> dict[str, Any] | None:
    """First route whose glob matches `path` (repo-relative), or None."""
    norm = path.replace("\\", "/")
    while norm.startswith("./"):
        norm = norm[2:]
    for route in data["routes"]:
        if any(glob_to_regex(g).match(norm) for g in route.get("globs", [])):
            return route
    return None


def cmd_area(args: argparse.Namespace) -> int:
    """Print `<path>\t<area|->\t<docs>` for each path (first matching route)."""
    path = _area_map_path()
    if not path.is_file():
        print(f"coderabbit-triage: no area map at {path}", file=sys.stderr)
        return 2
    try:
        data = load_area_map(path)
    except ValueError as exc:
        print(f"coderabbit-triage: {exc}", file=sys.stderr)
        return 2
    for p in args.paths:
        route = route_for(data, p)
        if route is None:
            print(f"{p}\t-\t-")
        else:
            print(f"{p}\t{route.get('area') or '-'}\t{' '.join(route.get('docs', []))}")
    return 0


# ---------------------------------------------------------------------------
# selftest — skill<->py rules-version drift guard + area-map integrity
# (core-agent-prompts-03: implement the sync-check the docs advertise;
#  core-scripts-python-03: give the .py a --selftest against the rules doc.)
# ---------------------------------------------------------------------------
_RULES_VERSION_RE = re.compile(r"triage-rules-version:\s*(\d+)")


def _triage_md_path() -> Path:
    # This script lives at agents/scripts/core/; the skill is at agents/_shared/skills/.
    return Path(__file__).resolve().parents[2] / "_shared" / "skills" / "coderabbit-triage" / "SKILL.md"


def _extract_rules_version(text: str) -> int | None:
    m = _RULES_VERSION_RE.search(text)
    return int(m.group(1)) if m else None


def cmd_selftest(args: argparse.Namespace) -> int:
    """Drift-guard: the skill's SKILL.md is source-of-truth for the rules, the
    .py is its executable mirror, and both carry a `triage-rules-version:` marker
    that must stay in lockstep. This is the end-of-CI sync check both files
    advertise — exercised by tests/bats/coderabbit_triage.bats in the Agentic
    self-tests lane. Also asserts the invariant-reject table is structurally
    sound, and — when the project has an area map — that the map parses, names
    each area once and cites only docs that exist. Exit 0 = OK, 1 = failure."""
    errors: list[str] = []

    py_marker = _extract_rules_version(Path(__file__).read_text(encoding="utf-8"))
    if py_marker is None:
        errors.append("coderabbit-triage.py: missing `# triage-rules-version:` marker")

    md_path = _triage_md_path()
    md_marker: int | None = None
    if not md_path.is_file():
        errors.append(f"coderabbit-triage SKILL.md not found at {md_path}")
    else:
        md_marker = _extract_rules_version(md_path.read_text(encoding="utf-8"))
        if md_marker is None:
            errors.append(f"{md_path}: missing `triage-rules-version:` marker")

    if py_marker is not None and md_marker is not None and py_marker != md_marker:
        errors.append(
            f"rules-version DRIFT: SKILL.md={md_marker} vs "
            f"coderabbit-triage.py={py_marker} — bump the marker in BOTH files in lockstep"
        )

    # Invariant-reject table integrity: non-empty, each a (compiled regex, reason).
    if not INVARIANT_REJECTS:
        errors.append("INVARIANT_REJECTS is empty — no invariant rules compiled")
    for i, entry in enumerate(INVARIANT_REJECTS):
        pattern, reason = entry
        if not isinstance(pattern, re.Pattern):
            errors.append(f"INVARIANT_REJECTS[{i}]: not a compiled regex")
        if not isinstance(reason, str) or not reason.strip():
            errors.append(f"INVARIANT_REJECTS[{i}]: empty reason")

    # Area map: optional (a standalone layer has none), validated when present.
    map_path = _area_map_path()
    map_note = f"no area map at {map_path} (skipped)"
    if os.environ.get("AREA_MAP_FILE", "").strip() and not map_path.is_file():
        errors.append(f"AREA_MAP_FILE names a missing file: {map_path}")
    elif map_path.is_file():
        try:
            data = load_area_map(map_path)
        except ValueError as exc:
            errors.append(str(exc))
        else:
            doc_root = map_path.resolve().parent.parent
            errors.extend(f"{map_path.name}: {e}" for e in area_map_errors(data, doc_root))
            map_note = f"area map OK ({len(data['routes'])} routes)"

    if errors:
        for e in errors:
            print(f"coderabbit-triage --selftest: FAIL — {e}", file=sys.stderr)
        return 1
    print(
        f"coderabbit-triage --selftest: OK — rules-version={md_marker} "
        f"(skill<->py in sync), {len(INVARIANT_REJECTS)} invariant rules, {map_note}"
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="coderabbit-triage",
        description=(
            "Classify CodeRabbit findings against Smatchet invariants. "
            "Python port of the coderabbit-triage skill's override table for "
            "smatchet-merge-watcher Phase 3."
        ),
    )
    sub = p.add_subparsers(dest="cmd", required=True)
    for name, fn, helptext in (
        ("classify", cmd_classify, "classify findings; print report to stdout"),
        ("post-comment", cmd_post_comment, "classify + POST the report as a PR comment"),
    ):
        sp = sub.add_parser(name, help=helptext)
        sp.add_argument("owner")
        sp.add_argument("repo")
        sp.add_argument("pr")
        sp.add_argument("--attempt", default=1, help="current attempt number (default 1)")
        sp.add_argument(
            "--budget",
            default=3,
            help="MERGE_WATCH_TRIAGE_BUDGET (default 3)",
        )
        sp.set_defaults(func=fn)
    sp_area = sub.add_parser(
        "area",
        help="print the first matching area-map route (area + docs) for each path",
    )
    sp_area.add_argument("paths", nargs="+", help="repo-relative file paths")
    sp_area.set_defaults(func=cmd_area)
    # selftest takes no positional args (skill<->py drift + table + area map).
    sp_self = sub.add_parser(
        "selftest",
        help="assert SKILL.md <-> .py rules-version sync, table integrity and the area map",
    )
    sp_self.set_defaults(func=cmd_selftest)
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except RuntimeError as exc:
        print(f"coderabbit-triage: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
