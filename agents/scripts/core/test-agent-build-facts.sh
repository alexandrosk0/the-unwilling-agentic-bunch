#!/usr/bin/env bash
# test-agent-build-facts.sh — verify build-related FACTS in agent-facing docs
# match ground truth, so an agent never instructs a user to run a preset that
# does not exist or cites a retired toolchain. Both classes shipped real defects
# an eval caught (a build prompt cited ninja-debug-msvc-{tsan,msan}; a test
# prompt cited ninja-asan; review prompts cited "MinGW UCRT").
#
# Scanned: every *.md under agents/ in the layer (agent prompts + skills) and in
# the host, docs/agent-rules/build.md, and the host docs a working agent loads
# for build facts: every leaf AGENTS.md (lib/leaf-docs.sh), BUILD.md and
# docs/guides/*.md. The other rule docs stay out of scope: they cite retired
# presets as history, which is not a fact an agent acts on.
#
# Checks:
#   1. Every `ninja-*` preset token in the scanned docs resolves to a real
#      `"name"` in the host's CMakePresets.json. A brace form
#      (`ninja-test-{msvc,clang}`) is expanded first; a family prefix
#      (`ninja-test-*`) must match at least one preset. A historical mention is
#      exempt when "retired" is one of the first five words after the token, in
#      the same sentence, with no other preset token in between and not negated
#      ("the `ninja-foo` preset is retired", "`ninja-foo` (retired)"; not
#      "`ninja-foo` is not retired"); each retired token needs its own.
#   2. No retired-build-toolchain phrase ("MinGW UCRT") in the scanned docs.
#      (MSYS2-as-lint-tooling / MinGW-GCC-sanitizer-runtime mentions stay
#      allowed — only the retired C++ *build-target* phrasing is banned.)
#
# Bucket A (CLI) per AGENTS.md § Verification automation. Zero manual steps.
# Auto-enrolled by scripts/dev/test-all.sh via the test-*.sh glob.

set -euo pipefail

# Two trees: the layer (this script's own; agent prompts, skills, build.md) and
# the host (CMakePresets.json, leaf docs, BUILD.md, guides). project-config.sh
# resolves the host — the superproject when the layer is a submodule. One tree
# when they are the same checkout. Full load, not PC_ROOTS_ONLY: the leaf set
# reads the lint exempt zones; a failed load still exports the roots.
LAYER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [ -f "$LAYER/scripts/dev/project-config.sh" ]; then
  # shellcheck source=scripts/dev/project-config.sh
  . "$LAYER/scripts/dev/project-config.sh" 2>/dev/null || true
else
  unset PROJECT_ROOT AGENT_LAYER_ROOT  # no config beside this script (a fixture copy): its own tree, never an inherited root
fi
HOST="${PROJECT_ROOT:-$LAYER}"
# shellcheck source=agents/scripts/core/lib/leaf-docs.sh
. "$LAYER/agents/scripts/core/lib/leaf-docs.sh"

PRESETS_JSON="$HOST/CMakePresets.json"

PASS=0
FAIL=0
FAILED_CHECKS=()
check_pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
check_fail() { FAIL=$((FAIL + 1)); FAILED_CHECKS+=("$1"); printf '  FAIL  %s\n' "$1"; }

# All scanned markdown (agent prompts, skills, build.md, host leaf docs,
# BUILD.md, guides; READMEs under agents/ excluded), one path per line.
agent_md() {
  local leaf
  { find "$LAYER/agents" -name '*.md' ! -name 'README.md' 2>/dev/null || true
    if [[ "$HOST" != "$LAYER" ]]; then
      find "$HOST/agents" -name '*.md' ! -name 'README.md' 2>/dev/null || true
    fi
    if [[ -f "$LAYER/docs/agent-rules/build.md" ]]; then printf '%s\n' "$LAYER/docs/agent-rules/build.md"; fi
    if [[ -f "$HOST/BUILD.md" ]]; then printf '%s\n' "$HOST/BUILD.md"; fi
    find "$HOST/docs/guides" -maxdepth 1 -name '*.md' 2>/dev/null || true
    while IFS= read -r leaf; do
      if [[ -n "$leaf" && -f "$HOST/$leaf" ]]; then printf '%s\n' "$HOST/$leaf"; fi
    done < <(cd "$HOST" && leaf_agents_files)
  } | sort -u
}

# rel <path> — <path> relative to the tree it belongs to, for reporting.
rel() {
  case "$1" in
    "$LAYER"/*) printf '%s\n' "${1#"$LAYER"/}" ;;
    "$HOST"/*) printf '%s\n' "${1#"$HOST"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# expand_braces <token> — print each expansion of the brace groups in <token>
# (`ninja-{msvc,clang}-asan` -> ninja-msvc-asan, ninja-clang-asan), one per line.
expand_braces() {
  local pre body post alt
  local -a alts
  if [[ "$1" =~ ^([^{]*)\{([^}]*)\}(.*)$ ]]; then
    pre="${BASH_REMATCH[1]}" body="${BASH_REMATCH[2]}" post="${BASH_REMATCH[3]}"
    IFS=',' read -ra alts <<< "$body"
    for alt in "${alts[@]}"; do expand_braces "$pre$alt$post"; done
  else
    printf '%s\n' "$1"
  fi
}

# preset_tokens <file> — the ninja-* preset tokens <file> cites, brace forms
# expanded; a token ending in `-` is a family prefix (`ninja-test-*`). A token
# is skipped as historical only when "retired" is one of the first five words
# after it, before the next preset token or the end of its sentence, and is not
# negated ("not retired", "isn't retired", "never retired"): the documented
# shapes are "`ninja-foo` preset is retired" and "`ninja-foo` (retired)".
# Paragraphs are joined, so a sentence may wrap lines.
preset_tokens() {
  local raw
  while IFS= read -r raw; do
    expand_braces "$raw"
  done < <(awk 'BEGIN { RS = "" }
    {
      gsub(/\n/, " ")
      text = $0
      while (match(text, /ninja-[a-z0-9-]*(\{[a-z0-9,-]+\}[a-z0-9-]*)*/)) {
        tok = substr(text, RSTART, RLENGTH)
        text = substr(text, RSTART + RLENGTH)
        win = text
        n = index(win, "ninja-")
        if (n > 0) win = substr(win, 1, n - 1)
        if (match(win, /[.!?]([ \t]|$)/)) win = substr(win, 1, RSTART)
        w = tolower(win)
        gsub(/[`*()_,;:.!?]/, " ", w)
        nw = split(w, words, /[ \t]+/)
        hist = 0
        seen = 0
        for (i = 1; i <= nw && seen < 5; i++) {
          if (words[i] == "") continue
          seen++
          if (words[i] == "retired") {
            prev = (i > 1) ? words[i - 1] : ""
            if (prev != "not" && prev != "never" && prev !~ /n.t$/) hist = 1
            break
          }
        }
        if (!hist) print tok
      }
    }' "$1" 2>/dev/null || true)
}

# -------------------------------------------------------------------------
# 1. ninja-* preset tokens resolve to a real CMakePresets.json preset name.
# -------------------------------------------------------------------------
echo "[1/2] ninja-* preset tokens in agent-facing docs resolve to CMakePresets.json"

# Valid preset names (the ninja-* ones; hidden _smatchet-* presets never match
# the ninja- prefix so they cannot collide).
valid_presets=" $(grep -oE '"name"[[:space:]]*:[[:space:]]*"ninja-[a-z0-9-]+"' "$PRESETS_JSON" 2>/dev/null \
  | sed -E 's/.*"(ninja-[a-z0-9-]+)".*/\1/' | sort -u | tr '\n' ' ') "

if [[ "$valid_presets" == "  " || -z "${valid_presets// /}" ]]; then
  check_fail "could not read any ninja-* preset from $PRESETS_JSON"
else
  dangling=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    while IFS= read -r tok; do
      [[ -z "$tok" || "$tok" == "ninja-" ]] && continue
      if [[ "$tok" == *- ]]; then
        # Family prefix: some preset must start with it.
        [[ "$valid_presets" == *" $tok"* ]] && continue
      elif [[ "$valid_presets" == *" $tok "* ]]; then
        continue  # whole-word membership in the valid set
      fi
      echo "    $(rel "$f"): unknown preset '$tok'"
      dangling=$((dangling + 1))
    done < <(preset_tokens "$f" | sort -u)
  done < <(agent_md)
  if [[ $dangling -eq 0 ]]; then
    check_pass "all ninja-* tokens resolve to a real preset"
  else
    check_fail "$dangling dangling ninja-* preset reference(s) in agent-facing docs"
  fi
fi

# -------------------------------------------------------------------------
# 2. No retired "MinGW UCRT" build-target citation in agent prompts.
# -------------------------------------------------------------------------
echo
echo "[2/2] No retired-build-toolchain phrase 'MinGW UCRT' in agent-facing docs"
retired_hits=""
while IFS= read -r f; do
  [[ -n "$f" ]] && grep -qF 'MinGW UCRT' "$f" 2>/dev/null && retired_hits+="$(rel "$f")"$'\n'
done < <(agent_md)
if [[ -z "$retired_hits" ]]; then
  check_pass "no 'MinGW UCRT' build-target citation (target is MSVC + Clang)"
else
  while IFS= read -r h; do [[ -n "$h" ]] && echo "    $h"; done <<< "$retired_hits"
  check_fail "retired 'MinGW UCRT' citation present — target is MSVC + Clang"
fi

# -------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------
echo
echo "----------------------------------------"
echo "test-agent-build-facts — Passed: $PASS  Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  echo
  echo "Failures:"
  for c in "${FAILED_CHECKS[@]}"; do echo "  - $c"; done
  exit 1
fi
exit 0
