#!/usr/bin/env bash
# leaf-docs.sh — the single definition of a subsystem LEAF AGENTS.md, shared by
# setup-harness.sh (CLAUDE.md shims + the Codex leaf report),
# test-leaf-doc-discovery.sh and test-subsystem-docs.sh, so the three can never
# disagree about which files are leaves.
#
# A leaf is a tracked AGENTS.md in a directory below <root> (default Source/; the
# pathspec `*` spans directories), excluding any path with a component named in
# the lint exempt zones — project.config.json lint.zones.exempt, exported by
# scripts/dev/project-config.sh as PC_LINT_EXEMPT_ZONES (vendored code such as
# ThirdParty/ carries upstream AGENTS.md files that are not this project's rules).
# Without a loaded config nothing is excluded.
#
# Paths are read NUL-delimited with core.quotePath off, so a non-ASCII path is
# printed as-is rather than C-quoted. Output: one repo-relative path per line,
# relative to the current directory's repository.
#
# Sourced, not executed. Uses the caller's git_cmd when one is defined
# (setup-harness.sh's git / git.exe fallback), plain git otherwise.

_leaf_docs_git() {
    if declare -F git_cmd >/dev/null 2>&1; then
        git_cmd "$@"
    else
        git "$@"
    fi
}

# leaf_agents_files [root] — print every leaf AGENTS.md below <root>.
leaf_agents_files() {
    local root="${1:-Source}" path zone skip
    local -a zones=()
    read -r -a zones <<< "${PC_LINT_EXEMPT_ZONES:-}"
    while IFS= read -r -d '' path; do
        skip=0
        for zone in "${zones[@]}"; do
            zone="${zone%/}"
            [ -n "$zone" ] || continue
            case "/$path/" in
                */"$zone"/*) skip=1; break ;;
            esac
        done
        [ "$skip" -eq 0 ] && printf '%s\n' "$path"
    done < <(_leaf_docs_git -c core.quotePath=false ls-files -z -- "$root/*/AGENTS.md" 2>/dev/null)
    return 0
}
