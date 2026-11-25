#!/usr/bin/env bash
# 85-ui-include-direction.sh — no-ui-include-in-domain rule (sourced by test-lint-rules.sh, not run directly).

# no-ui-include-in-domain — include-direction rule over the DOMAIN subsystems (Source/Core/
# {src,include}/{Tracker,Sync,Persistence,Config}/ + Source/Plugins/Mcp/). A quote-form
# `#include "Ui/..."` in domain code inverts the architecture layer DAG (Ui=6 sits ABOVE every
# domain layer — include_cycle_audit.py's ranking): the domain becomes compile-coupled to the
# render layer, so a Ui refactor rebuilds/breaks Tracker and the domain TUs stop being buildable
# without the Ui surface (the mobile/posix lanes compile CORE_SOURCES standalone). The include-cycle
# gate cannot catch this class — its back-edge check is deliberately header->header ("a .cpp pulls
# in the higher-layer headers it implements against" is normal for e.g. AppController TUs), so a
# domain .cpp -> Ui/ header edge sailed through (the TouchCellEditGesture.h escape: three cell-editor
# TUs included a Ui/ header for a layer-neutral gesture gate). This rule closes exactly that
# direction where it is never legitimate. Shared layer-neutral helpers belong at the include/ root
# (leaf/utility rank), not under Ui/.
#
# Two spellings fire. (1) A quote-form `#include "Ui/..."`. (2) A quote-form BARE name (no
# directory component, `#include "SmatchetToast.h"`) that the compiler resolves to a file directly
# under Source/Core/src/Ui/ or Source/Core/include/Ui/: the host's CMake puts both dirs on the
# include path, so the bare spelling reached a Ui header while dodging (1) — it escaped in practice.
# Resolution mirrors the host compiler: the includer's own directory wins, then UIINCLUDE_ROOTS in
# order; the FIRST root holding the name decides — a Ui root fires, any earlier non-Ui root (or the
# includer's dir) shadows it. The Ui-header name set is built once per process; absent Ui dirs (the
# layer's own CI has no host tree) leave it empty, so only spelling (1) can fire.
# Known limits: an `#include` inside a multi-line /* */ block or under `#if 0` still fires (as the
# quote-form always did); `"./X.h"`, backslash spellings and case-only matches are not resolved.
#
# Commands/ is intentionally NOT in scope: its Scenarios/ TUs drive UI-level machinery on the UI
# thread by contract (MobileTextureGuardScenario -> SmatchetImGuiTextureGuardRuntime.h) and
# AppViewCommands.cpp consumes the Ui view-visibility seam — sanctioned couplings that would need
# grandfathering; graduate Commands/ in once those seams are inverted. The rule is absolute-0 (no
# grandfathering — same model as no-glfw / ui-request-flag-off-thread): a hit is either a
# regression or a coupling that must carry a reviewed escape. A
# SMATCHET_DEVIATION(rule=no-ui-include-in-domain; ...) on the nearest non-blank line above the
# include escapes.
UIINCLUDE_RULES=(no-ui-include-in-domain)

# Include roots in compiler search order. Two parts, mirrored separately:
#   * the PRIVATE src roots of the core impl targets (smatchet_configure_core_impl_target in the
#     host's Source/Core/CMakeLists.txt) — searched first, because a target's own include dirs
#     precede the INTERFACE dirs it links. Mirrored from the host CMake BY HAND:
#     include_cycle_audit.py does not model them, and no selftest can pin them (no host tree here).
#   * the INTERFACE include/* roots — mirrored from include_cycle_audit.py INCLUDE_ROOTS up to and
#     including include/Ui (later roots can never shadow a Ui hit); the selftest pins this part.
# A root whose last component is `Ui` is a Ui root.
UIINCLUDE_SRC_ROOTS=(
    Source/Core/src
    Source/Core/src/Tracker
    Source/Core/src/Sync
    Source/Core/src/Persistence
    Source/Core/src/Config
    Source/Core/src/Ui
    Source/Core/ThirdParty
    Source/Plugins/Mcp
    Source/Plugins/Whisper
)
UIINCLUDE_INCLUDE_ROOTS=(
    Source/Core/include
    Source/Core/include/Tracker
    Source/Core/include/Sync
    Source/Core/include/Persistence
    Source/Core/include/Config
    Source/Core/include/Ui
)
UIINCLUDE_ROOTS=("${UIINCLUDE_SRC_ROOTS[@]}" "${UIINCLUDE_INCLUDE_ROOTS[@]}")
# Tree every relative path (roots AND the includer) resolves against: the scanned repo root (the
# driver's cwd). Deliberately NOT inherited from the environment — a stray export would silently
# disable the bare-name half; the selftest assigns it explicitly to point at a fixture tree.
UIINCLUDE_TREE_ROOT="."
_UIINCLUDE_UI_SET=""        # "|a.h|b.h|" — bash-3-safe set (no associative arrays in this driver)
_UIINCLUDE_UI_SET_FOR=""    # tree root the set was built for ("" = not built yet)

_uii_build_ui_set() {
    # Build the Ui-header name set (every Ui root) once per process per tree root. Missing dirs ->
    # empty set.
    [ "$_UIINCLUDE_UI_SET_FOR" = "$UIINCLUDE_TREE_ROOT" ] && return 0
    local r p acc="|"
    for r in "${UIINCLUDE_ROOTS[@]}"; do
        case "$r" in */Ui) ;; *) continue ;; esac
        [ -d "$UIINCLUDE_TREE_ROOT/$r" ] || continue
        for p in "$UIINCLUDE_TREE_ROOT/$r"/*; do
            [ -f "$p" ] && acc+="${p##*/}|"
        done
    done
    _UIINCLUDE_UI_SET="$acc"
    _UIINCLUDE_UI_SET_FOR="$UIINCLUDE_TREE_ROOT"
}

_uii_bare_resolves_to_ui() {
    # $1 = bare include name, $2 = includer path (tree-root-relative or absolute). True when the
    # first search location holding the name is a Ui root.
    local name="$1" inc="$2" dir r
    [[ "$_UIINCLUDE_UI_SET" == *"|$name|"* ]] || return 1
    if [[ "$inc" == */* ]]; then dir="${inc%/*}"; else dir="."; fi
    # No command substitution here or below: a fork per call is slow on Windows Git Bash.
    case "$dir" in /*) ;; *) dir="$UIINCLUDE_TREE_ROOT/$dir" ;; esac
    [ -e "$dir/$name" ] && return 1
    for r in "${UIINCLUDE_ROOTS[@]}"; do
        [ -e "$UIINCLUDE_TREE_ROOT/$r/$name" ] || continue
        case "$r" in */Ui) return 0 ;; *) return 1 ;; esac
    done
    return 1
}

scan_ui_include_direction_file() {
    # $1 = a first-party C++ file (.cpp/.h/.hpp). Emits `no-ui-include-in-domain\t<f>:<line>` per
    # quote-form `#include "Ui/..."`, or bare-name quote include resolving to a Ui/ header (see the
    # header comment), with no suppressing deviation. Path-agnostic (the domain-dir scoping lives in
    # compute_ui_include_direction_violations; --scan-file / selftest fixtures exercise this
    # directly); a relative <f> and every root resolve against UIINCLUDE_TREE_ROOT.
    local f="$1" path="$1"
    case "$f" in /*) ;; *) path="$UIINCLUDE_TREE_ROOT/$f" ;; esac
    [ -f "$path" ] || return 0
    case "$f" in *.cpp|*.h|*.hpp) ;; *) return 0 ;; esac
    _uii_build_ui_set
    local -a lines=()
    local line
    while IFS= read -r line || [ -n "$line" ]; do lines+=("$line"); done < "$path"
    local n=${#lines[@]} i j spec
    local re='^[[:space:]]*#[[:space:]]*include[[:space:]]*"([^"]+)"'
    for ((i = 0; i < n; i++)); do
        # Quote-form includes only; a comment mention of the path or an angle-bracket include never
        # matches.
        [[ "${lines[$i]}" =~ $re ]] || continue
        spec="${BASH_REMATCH[1]}"
        case "$spec" in
            Ui/*) ;;
            */*|*\\*|*'|'*) continue ;;
            *) _uii_bare_resolves_to_ui "$spec" "$f" || continue ;;
        esac
        # Nearest non-blank line ABOVE the include may carry the suppressing deviation (mirrors the
        # include-cycle / dup nearest-non-blank-above grammar).
        local dev=0
        for ((j = i - 1; j >= 0; j--)); do
            [[ "${lines[$j]}" =~ ^[[:space:]]*$ ]] && continue
            case "${lines[$j]}" in *'SMATCHET_DEVIATION(rule=no-ui-include-in-domain'*) dev=1 ;; esac
            break
        done
        if [ "$dev" -eq 0 ]; then
            printf 'no-ui-include-in-domain\t%s:%s\n' "$f" "$((i + 1))"
        fi
    done
}

compute_ui_include_direction_violations() {
    # Domain scope = the strict-zone subsystems MINUS Commands/ (see the header comment), src +
    # include mirrors + the Mcp plugin. Ui/ itself, AppController TUs, and the root src/include
    # leaves are out of scope (legitimate or grandfathered Ui consumers live there).
    local files=() f
    while IFS= read -r f; do files+=("$f"); done < <(
        git ls-files \
            'Source/Core/src/Tracker/**' 'Source/Core/include/Tracker/**' \
            'Source/Core/src/Sync/**' 'Source/Core/include/Sync/**' \
            'Source/Core/src/Persistence/**' 'Source/Core/include/Persistence/**' \
            'Source/Core/src/Config/**' 'Source/Core/include/Config/**' \
            'Source/Plugins/Mcp/**' \
            2>/dev/null \
            | grep -E '\.(cpp|h|hpp)$' | grep -vE '(^|/)ThirdParty/' || true
    )
    [ "${#files[@]}" -gt 0 ] || return 0
    for f in "${files[@]}"; do scan_ui_include_direction_file "$f"; done
}
