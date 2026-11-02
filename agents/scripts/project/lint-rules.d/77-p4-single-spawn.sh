#!/usr/bin/env bash
# 77-p4-single-spawn.sh — p4-single-spawn rule (sourced by test-lint-rules.sh, not run directly).

# p4-single-spawn — ABSOLUTE-0 whole-file rule over the Perforce annotate implementation
# (Source/Core/src/P4Annotate.cpp). Every Perforce call in that file goes through P4RunCommand,
# which consults cfg.P4RunOverride — the zero-credential test seam that tests/support/FakeP4Runner.h
# installs to replay fixtures (ADR-0009) — before its one SubprocessCapture::Run spawn. A second
# spawn site runs a real Perforce client under test and bypasses the seam; a deleted override
# consult leaves the end-to-end doctests driving nothing while production still spawns. So the rule
# asserts on CODE (comments stripped), across the whole file:
#   - exactly one `SubprocessCapture::Run(` call,
#   - at least one `cfg.P4RunOverride` consult,
#   - no other process-spawn primitive (`system(`, `popen(`, `_popen(`, `CreateProcess`).
# A count has no single line to anchor to, so the (rule, basename, hash) delta gate cannot see this
# invariant: deleting the consult adds no new triple. It therefore runs as an absolute whole-tree
# check, like no-glfw-in-core-headers. The implementation missing while its header
# (Source/Core/include/P4Annotate.h) is tracked is also a violation (the seam moved and the rule did
# not follow); a tree without that header (a lint fixture, the layer's own checkout) has nothing to
# check. Escape: one `SMATCHET_DEVIATION(rule=p4-single-spawn; reason=...; owner=...; revisit=...)`
# anywhere in the file (the tu-line-ceiling whole-file grammar).
#
# Text proxy, not a parser: comment stripping treats a `//` or `/*` inside a string literal as a
# comment start. That can only hide code from the counts, which fails the Run and override checks
# closed; the one open case (a second Run on the same line as such a literal) is not a realistic
# shape.
# shellcheck disable=SC2034  # the rule-id registry is consumed by the entry point (--selftest card check).
P4_SPAWN_RULES=(p4-single-spawn)
P4_SPAWN_IMPL="Source/Core/src/P4Annotate.cpp"
P4_SPAWN_HEADER="Source/Core/include/P4Annotate.h"

p4_spawn_strip_comments() {
    # $1 = a C++ file. Prints it line for line (numbering preserved) with `/* ... */` (multi-line)
    # and `// ...` comments removed.
    awk '
    {
        line = $0; out = ""
        while (length(line) > 0) {
            if (inblk) {
                p = index(line, "*/")
                if (p == 0) { line = ""; break }
                line = substr(line, p + 2); inblk = 0; continue
            }
            p1 = index(line, "/*"); p2 = index(line, "//")
            if (p2 > 0 && (p1 == 0 || p2 < p1)) { out = out substr(line, 1, p2 - 1); line = ""; break }
            if (p1 > 0) { out = out substr(line, 1, p1 - 1); line = substr(line, p1 + 2); inblk = 1; continue }
            out = out line; line = ""
        }
        print out
    }' "$1"
}

scan_p4_single_spawn_file() {
    # $1 = the P4 annotate implementation file (path as it should be reported). Emits
    # `p4-single-spawn\t<f>:<line>\t<detail>` per broken condition, nothing when the seam holds.
    local f="$1"
    [ -f "$f" ] || return 0
    if grep -q 'SMATCHET_DEVIATION(rule=p4-single-spawn' "$f" 2>/dev/null; then return 0; fi
    local code run_lines run_count override_count spawn_lines first
    code="$(p4_spawn_strip_comments "$f")"
    run_lines="$(printf '%s\n' "$code" | grep -nE 'SubprocessCapture::Run[[:space:]]*\(' || true)"
    run_count="$(printf '%s\n' "$code" | { grep -oE 'SubprocessCapture::Run[[:space:]]*\(' || true; } | wc -l | tr -d ' ')"
    override_count="$(printf '%s\n' "$code" | { grep -oE 'cfg[[:space:]]*\.[[:space:]]*P4RunOverride' || true; } | wc -l | tr -d ' ')"
    if [ "$run_count" -ne 1 ]; then
        if [ "$run_count" -eq 0 ]; then
            first=1
        else
            # Anchor on the second call site (the one that breaks "exactly one").
            first="$(printf '%s\n' "$run_lines" | sed -n '2p' | cut -d: -f1)"
            [ -n "$first" ] || first="$(printf '%s\n' "$run_lines" | sed -n '1p' | cut -d: -f1)"
        fi
        printf 'p4-single-spawn\t%s:%s\tSubprocessCapture::Run calls=%s (want exactly 1)\n' "$f" "$first" "$run_count"
    fi
    if [ "$override_count" -lt 1 ]; then
        printf 'p4-single-spawn\t%s:1\tcfg.P4RunOverride consults=0 (want >= 1)\n' "$f"
    fi
    spawn_lines="$(printf '%s\n' "$code" | grep -nE '(^|[^A-Za-z0-9_])(std::)?(system|_?popen)[[:space:]]*\(|CreateProcess[AW]?[[:space:]]*\(' || true)"
    if [ -n "$spawn_lines" ]; then
        local ln
        while IFS= read -r ln; do
            [ -n "$ln" ] || continue
            printf 'p4-single-spawn\t%s:%s\tsecond spawn primitive (route it through P4RunCommand)\n' "$f" "${ln%%:*}"
        done <<< "$spawn_lines"
    fi
}

compute_p4_single_spawn_violations() {
    # Whole-tree check, run from the scanned root (debug + bats harness + the blocking --diff path).
    # Silent when the header is not tracked: there is no P4 annotate subsystem in this tree.
    [ -n "$(git ls-files -- "$P4_SPAWN_HEADER" 2>/dev/null)" ] || return 0
    if [ ! -f "$P4_SPAWN_IMPL" ]; then
        printf 'p4-single-spawn\t%s:0\timplementation missing while %s is tracked\n' "$P4_SPAWN_IMPL" "$P4_SPAWN_HEADER"
        return 0
    fi
    scan_p4_single_spawn_file "$P4_SPAWN_IMPL"
}
