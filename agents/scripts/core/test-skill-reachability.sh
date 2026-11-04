#!/usr/bin/env bash
# test-skill-reachability.sh — every skill is reachable on a harness without
# skill discovery.
#
# The rule (docs/agent-rules/AGENT-VS-SKILL.md § How a skill reaches every
# harness, rule 2): Claude Code auto-discovers skills, but Codex, Cursor, pi and
# generic harnesses read AGENTS.md and nothing else, so a skill reaches them only
# through a path link to agents/_shared/skills/<name>/SKILL.md — a row in
# AGENTS.md itself, or a link from a doc that AGENTS.md routes to. A skill named
# only in prose reaches Claude Code alone. This gate checks exactly that:
#
#   For every agents/_shared/skills/<name>/SKILL.md, a markdown link whose href
#   resolves to that file must appear in AGENTS.md (hop 0) or in a markdown doc
#   AGENTS.md links to (hop 1). Nothing deeper counts: "a doc that AGENTS.md
#   routes to" is one hop.
#
# What counts as a link: an inline `[text](href)` link (its text may wrap across
# lines), a full / collapsed / shortcut reference whose `[label]: href`
# definition exists, or an HTML `<a href="...">`, with a relative href that
# resolves (against the linking file's directory, `#anchor` and `?query`
# stripped) to the SKILL.md path. Not a link: an image `![alt](href)`, an unused
# reference definition, an escaped `\[text](href)`, anything in a fenced code
# block (at any indentation), an inline code span (even one wrapped across
# lines) or an HTML comment, an absolute or URL href, a bare path or skill name
# in prose. Known gap: a 4-space indented code block outside a list is read as
# prose (telling it from list continuation needs a full CommonMark parser); no
# routed doc uses one. A hop-1 doc is a
# `.md` file AGENTS.md links to that exists inside the layer tree; a link that
# leaves the layer tree is not followed (it is not portable to every mount).
#
# Roots: the layer is this script's own tree (agents/scripts/core/ → three up), so
# it checks the same thing standalone and from a host where the layer is the
# agent-layer/ mount — the host's AGENTS.md imports agent-layer/AGENTS.md, and the
# layer's AGENTS.md with its links is the route set. Inherited PROJECT_ROOT /
# AGENT_LAYER_ROOT are ignored on purpose: a host root would point the check at
# the wrong AGENTS.md. `--root DIR` overrides (fixtures, or a host checkout):
# DIR is the layer when it holds agents/_shared/skills/, else DIR/agent-layer.
#
# Pure text-and-path check: no network, no git.
#
# Fail-closed: a missing AGENTS.md, skills dir, python, or a tree with no
# SKILL.md is an environment error (exit 2), never a silent pass. An unreadable
# hop-1 doc is also exit 2 (its links cannot be ruled out, so neither pass nor
# fail is honest).
#
# Usage:
#   bash agents/scripts/core/test-skill-reachability.sh              # check the tree
#   bash agents/scripts/core/test-skill-reachability.sh --root DIR   # check DIR
#   bash agents/scripts/core/test-skill-reachability.sh --selftest
#
# Exit codes follow the test-script convention (see the test-all.sh header):
#   0 — every skill is reachable
#   1 — at least one skill is unreachable (or a --selftest assertion failed)
#   2 — environment error (python, AGENTS.md, skills dir, bad arguments)
# Prints a final "Passed: N  Failed: M" line (N reachable skills, M unreachable).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=agents/scripts/core/lib/resolve-py.sh
. "$SCRIPT_DIR/lib/resolve-py.sh"

die_env() {
    echo "test-skill-reachability: $1" >&2
    echo "Passed: 0  Failed: 0"
    exit 2
}

# --selftest — build fixture layers and assert both verdicts.
run_selftest() {
    local tmp rc out fails=0
    tmp="$(mktemp -d)" || die_env "mktemp failed"
    # shellcheck disable=SC2064  # expand $tmp now: the trap must remove this dir
    trap "rm -rf '$tmp'" EXIT

    mkdir -p "$tmp/agents/_shared/skills/alpha" "$tmp/agents/_shared/skills/beta" "$tmp/docs"
    printf -- '---\nname: alpha\n---\n' >"$tmp/agents/_shared/skills/alpha/SKILL.md"
    printf -- '---\nname: beta\n---\n' >"$tmp/agents/_shared/skills/beta/SKILL.md"
    printf '# Rules\n\n| Trigger | Doc |\n|---|---|\n| a | [alpha](agents/_shared/skills/alpha/SKILL.md) |\n\nSee [rules](docs/rules.md).\n' \
        >"$tmp/AGENTS.md"
    printf '# Rules\n\nRun [beta](../agents/_shared/skills/beta/SKILL.md#loop).\n' >"$tmp/docs/rules.md"

    out="$(bash "$SCRIPT_PATH" --root "$tmp" 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'Passed: 2  Failed: 0'; then
        echo "  ok   selftest: a hop-0 row and a hop-1 doc link both pass"
    else
        echo "  FAIL selftest: linked fixture should pass (rc=$rc)"
        printf '%s\n' "$out" | sed 's/^/       /'
        fails=$((fails + 1))
    fi

    # selftest: asserts-failure — a skill named only in prose (its name and its
    # path in backticks, never as a link href) is unreachable and MUST fail.
    mkdir -p "$tmp/agents/_shared/skills/gamma"
    printf -- '---\nname: gamma\n---\n' >"$tmp/agents/_shared/skills/gamma/SKILL.md"
    # shellcheck disable=SC2016  # literal backticks: the fixture's inline code span
    printf 'Use the gamma skill (`agents/_shared/skills/gamma/SKILL.md`).\n' >>"$tmp/docs/rules.md"
    out="$(bash "$SCRIPT_PATH" --root "$tmp" 2>&1)"
    rc=$?
    if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'FAIL gamma' \
        && printf '%s\n' "$out" | grep -q 'Passed: 2  Failed: 1'; then
        echo "  ok   selftest: a prose-only skill fails"
    else
        echo "  FAIL selftest: prose-only fixture should fail with exit 1 (rc=$rc)"
        printf '%s\n' "$out" | sed 's/^/       /'
        fails=$((fails + 1))
    fi

    if [ "$fails" -eq 0 ]; then
        echo "Passed: 2  Failed: 0"
        return 0
    fi
    echo "Passed: $((2 - fails))  Failed: $fails"
    return 1
}

ROOT=""
ROOT_SET=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --selftest)
            run_selftest
            exit $?
            ;;
        --root)
            [ "$#" -ge 2 ] || die_env "--root needs a directory"
            ROOT="$2"
            ROOT_SET=1
            shift 2
            ;;
        --root=*)
            ROOT="${1#--root=}"
            ROOT_SET=1
            shift
            ;;
        -h|--help)
            sed -n '2,55p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            die_env "unknown argument: $1"
            ;;
    esac
done

# An explicit but empty --root (an unset variable in the caller) is an error,
# never a silent check of this script's own tree.
if [ "$ROOT_SET" -eq 1 ]; then
    [ -n "$ROOT" ] || die_env "--root needs a non-empty directory"
else
    ROOT="$SCRIPT_DIR/../../.."
fi
[ -d "$ROOT" ] || die_env "root is not a directory: $ROOT"
ROOT="$(cd "$ROOT" && pwd)" || die_env "cannot enter root: $ROOT"
if [ -d "$ROOT/agents/_shared/skills" ]; then
    LAYER="$ROOT"
elif [ -d "$ROOT/agent-layer/agents/_shared/skills" ]; then
    LAYER="$ROOT/agent-layer"
else
    die_env "no agents/_shared/skills/ under $ROOT or $ROOT/agent-layer"
fi
[ -f "$LAYER/AGENTS.md" ] || die_env "no AGENTS.md at the layer root $LAYER"

PY="$(resolve_py)" || die_env "no working python 3 found"

"$PY" -I - "$LAYER" <<'PYEOF'
import os
import re
import sys
from urllib.parse import unquote

layer = os.path.normpath(sys.argv[1])
agents_md = os.path.join(layer, "AGENTS.md")
skills_dir = os.path.join(layer, "agents", "_shared", "skills")

# A fence opens on 3+ backticks or tildes at any indentation (a list item indents
# its fences past the 0-3 spaces of a top-level block) and closes only on a bare
# run of the same character at least as long (CommonMark: a closing fence carries
# no info string), indented at most three spaces past the opener (a deeper run is
# content, such as an inner fence shown inside a fenced example). A backtick
# opener whose info string holds a backtick is an inline code span, not a fence.
FENCE_OPEN_RE = re.compile(r"^\s*(`{3,}|~{3,})(.*)$")
FENCE_CLOSE_RE = re.compile(r"^\s*(`{3,}|~{3,})\s*$")
CODE_SPAN_RE = re.compile(r"(`+)(?:(?!\1).)+?\1", re.S)
LINE_CODE_SPAN_RE = re.compile(r"(`+)(?:(?!\1).)+?\1")
ESCAPED_BRACKET_RE = re.compile(r"\\[\[\]]")
# One level of nested brackets in the link text covers `[![badge](i)](href)`.
LINK_TEXT = r"\[((?:[^\[\]]|\[[^\[\]]*\])*)\]"
INLINE_RE = re.compile(r"(!?)" + LINK_TEXT + r"\(\s*(<[^>]*>|[^)\s]+)")
# A full `[text][label]`, collapsed `[label][]` or shortcut `[label]` reference;
# a following `(` is an inline link and a following `:` is a definition.
REFUSE_RE = re.compile(r"(!?)" + LINK_TEXT + r"(?:\[([^\[\]]*)\])?(?![(:\[])")
REFDEF_RE = re.compile(r"^[ \t]{0,3}\[([^\]]+)\]:[ \t]*(<[^>]*>|\S+)", re.M)
HTML_A_RE = re.compile(r"<a\s[^>]*?\bhref\s*=\s*([\"'])(.*?)\1", re.I | re.S)
SCHEME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")


def env_error(msg):
    print("test-skill-reachability: " + msg, file=sys.stderr)
    print("Passed: 0  Failed: 0")
    sys.exit(2)


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError as exc:
        env_error("cannot read %s: %s" % (path, exc))


def indent_cols(line):
    """Columns of leading whitespace, tabs expanded to 4-column stops."""
    lead = line[:len(line) - len(line.lstrip(" \t"))]
    return len(lead.expandtabs(4))


def prose_paragraphs(text):
    """Paragraphs outside fenced code blocks and HTML comments, lines joined by
    newlines, so a link or code span wrapped across lines is still one match."""
    fence = None
    in_comment = False
    para = []
    for line in text.splitlines():
        if fence is not None:
            m = FENCE_CLOSE_RE.match(line)
            if (m and m.group(1)[0] == fence[0][0] and len(m.group(1)) >= len(fence[0])
                    and indent_cols(line) <= fence[1] + 3):
                fence = None
            continue
        if not in_comment:
            m = FENCE_OPEN_RE.match(line)
            if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):
                fence = (m.group(1), indent_cols(line))
                if para:
                    yield "\n".join(para)
                    para = []
                continue
        # A `<!--` quoted in an inline code span is text, not a comment opener.
        masked = LINE_CODE_SPAN_RE.sub(lambda s: " " * len(s.group(0)), line)
        kept = []
        i = 0
        while i <= len(line):
            if in_comment:
                j = line.find("-->", i)
                if j < 0:
                    break
                in_comment = False
                i = j + 3
            else:
                j = masked.find("<!--", i)
                if j < 0:
                    kept.append(line[i:])
                    break
                kept.append(line[i:j])
                in_comment = True
                i = j + 4
        cleaned = " ".join(kept)
        if cleaned.strip():
            para.append(cleaned)
        elif para:
            yield "\n".join(para)
            para = []
    if para:
        yield "\n".join(para)


def ref_label(label):
    return " ".join(label.split()).casefold()


def link_targets(path):
    """Normalized absolute paths of the relative links in a markdown file."""
    base = os.path.dirname(path)
    paras = []
    for para in prose_paragraphs(read_text(path)):
        para = ESCAPED_BRACKET_RE.sub("  ", para)
        paras.append(CODE_SPAN_RE.sub(lambda s: " " * len(s.group(0)), para))
    defs = {}
    for para in paras:
        for m in REFDEF_RE.finditer(para):
            defs.setdefault(ref_label(m.group(1)), m.group(2))
    hrefs = []
    for para in paras:
        body = REFDEF_RE.sub(" ", para)
        hrefs.extend(m.group(3) for m in INLINE_RE.finditer(body) if m.group(1) != "!")
        hrefs.extend(m.group(2) for m in HTML_A_RE.finditer(body))
        for m in REFUSE_RE.finditer(INLINE_RE.sub(" ", body)):
            if m.group(1) == "!":
                continue
            href = defs.get(ref_label(m.group(3) or m.group(2)))
            if href is not None:
                hrefs.append(href)
    out = []
    for href in hrefs:
        if href.startswith("<") and href.endswith(">"):
            href = href[1:-1]
        href = href.split("#", 1)[0].split("?", 1)[0]
        if not href or href.startswith("/") or SCHEME_RE.match(href):
            continue
        out.append(os.path.normpath(os.path.join(base, unquote(href))))
    return out


def inside_layer(p):
    return p == layer or p.startswith(layer + os.sep)


def rel(p):
    return os.path.relpath(p, layer).replace(os.sep, "/")


try:
    names = sorted(
        n for n in os.listdir(skills_dir)
        if os.path.isfile(os.path.join(skills_dir, n, "SKILL.md"))
    )
except OSError as exc:
    env_error("cannot list %s: %s" % (skills_dir, exc))
if not names:
    env_error("no agents/_shared/skills/<name>/SKILL.md under " + layer)

# route[target] = the first doc (AGENTS.md, then hop-1 docs in link order) linking it.
route = {}
hop0 = link_targets(agents_md)
for t in hop0:
    route.setdefault(t, "AGENTS.md")
hop1_docs = []
for t in hop0:
    if t.endswith(".md") and inside_layer(t) and os.path.isfile(t) and t != agents_md and t not in hop1_docs:
        hop1_docs.append(t)
for doc in hop1_docs:
    for t in link_targets(doc):
        route.setdefault(t, rel(doc))

routed_texts = [("AGENTS.md", read_text(agents_md))] + [(rel(d), read_text(d)) for d in hop1_docs]

passed = failed = 0
for name in names:
    skill = os.path.normpath(os.path.join(skills_dir, name, "SKILL.md"))
    via = route.get(skill)
    if via is not None:
        passed += 1
        print("  ok   %s — linked from %s" % (name, via))
        continue
    failed += 1
    word = re.compile(r"(?<![\w-])" + re.escape(name) + r"(?![\w-])")
    mentions = [label for label, text in routed_texts if word.search(text)]
    hint = ("; named in prose only in " + ", ".join(mentions)) if mentions else ""
    print("  FAIL %s — no link to agents/_shared/skills/%s/SKILL.md in AGENTS.md or a doc it links to%s"
          % (name, name, hint))

if failed:
    print("Unreachable skills reach Claude Code alone. Add an on-demand row in AGENTS.md, or a path link")
    print("from a doc AGENTS.md links to (docs/agent-rules/AGENT-VS-SKILL.md § How a skill reaches every harness).")
print("Passed: %d  Failed: %d" % (passed, failed))
sys.exit(1 if failed else 0)
PYEOF
