#!/usr/bin/env bash
# render-template.sh — sourceable helpers for the adapter templates that
# setup-harness.sh renders rather than copies (the Cursor rule today).
#
# A rendered template names layer paths with the {{AGENT_LAYER}} placeholder.
# It becomes the layer's path from the host root plus a slash: empty in a
# standalone layer checkout, `agent-layer/` when a host mounts the layer as a
# submodule. A verbatim copy would point a mounted host at host-root paths that
# do not exist there (`agents/core/` instead of `agent-layer/agents/core/`).
#
# Tests: tests/bats/setup_harness_render_template.bats.

# layer_prefix <layer-root> <host-root>
# Print the {{AGENT_LAYER}} value: nothing when the two roots are the same
# directory, the layer's path relative to the host plus `/` when the layer sits
# inside the host, and the layer's absolute path plus `/` otherwise. Logical
# paths (`pwd`, not `pwd -P`), so a mount reached through a symlink still
# renders as the relative `agent-layer/` a reader of the rule would use.
layer_prefix() {
    local layer host
    layer="$(cd "$1" 2>/dev/null && pwd)" || { printf '%s/' "$1"; return 0; }
    host="$(cd "$2" 2>/dev/null && pwd)" || host=""
    if [ "$layer" = "$host" ]; then
        return 0
    fi
    if [ -z "$host" ]; then
        printf '%s/' "$layer"
        return 0
    fi
    case "$layer" in
        "$host"/*) printf '%s/' "${layer#"$host"/}" ;;
        *) printf '%s/' "$layer" ;;
    esac
}

# file_sha256 <file>
# Print the file's sha256, or nothing when neither sha256sum nor shasum exists
# (render_template then treats every existing destination as a local edit).
file_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -c1-64
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -c1-64
    fi
}

# render_template <src> <dst> <prefix> [superseded-sha256 ...]
# Write <src> to <dst> with every {{AGENT_LAYER}} replaced by <prefix>.
# copy_template's never-clobber contract holds: an existing <dst> that differs
# from the rendering is a local edit and is left alone. The one exception is a
# byte-for-byte copy of a template version setup-harness.sh shipped earlier (its
# sha256 is passed in), which is not a local edit, so it is upgraded.
render_template() {
    local src="$1" dst="$2" prefix="$3" rendered sha legacy
    shift 3
    rendered="$(cat "$src")" || return 1
    # The quoted replacement keeps a `&` in the prefix literal under bash 5.2's
    # patsub_replacement.
    rendered="${rendered//'{{AGENT_LAYER}}'/"$prefix"}"
    mkdir -p "$(dirname "$dst")"
    if [ -e "$dst" ]; then
        [ "$(cat "$dst")" = "$rendered" ] && return 0
        sha="$(file_sha256 "$dst")"
        for legacy in "$@"; do
            if [ -n "$sha" ] && [ "$sha" = "$legacy" ]; then
                printf '%s\n' "$rendered" > "$dst"
                echo "  upgrade    $dst (a superseded copy of the template)"
                return 0
            fi
        done
        echo "  skip-copy  $dst (user-modified — not overwriting)"
        return 0
    fi
    printf '%s\n' "$rendered" > "$dst"
    echo "  render     $dst"
}
