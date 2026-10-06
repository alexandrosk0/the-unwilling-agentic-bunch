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
# Portable to bash 3.2 (stock macOS): no ${var//pat/rep} with a quoted
# replacement, whose quotes bash <= 4.2 keeps as literal characters.
#
# Tests: tests/bats/setup_harness_render_template.bats.

# _rt_under <dir> <root> — print <dir>'s path below <root> plus `/`; fail when
# <dir> is not inside <root>.
_rt_under() {
    case "$1" in
        "$2"/*) printf '%s/' "${1#"$2"/}" ;;
        *) return 1 ;;
    esac
}

# layer_prefix <layer-root> <host-root>
# Print the {{AGENT_LAYER}} value: nothing when the two roots are the same
# directory, the layer's path relative to the host plus `/` when the layer sits
# inside the host, and the layer's absolute path plus `/` otherwise. Logical
# paths first, so a mount reached through a symlink renders as the relative
# `agent-layer/` a reader would use; physical paths second, because git reports
# the superproject physically while the layer root may arrive logically (macOS
# /tmp -> /private/tmp).
layer_prefix() {
    local layer host layer_p host_p
    layer="$(cd "$1" 2>/dev/null && pwd)" || { printf '%s/' "$1"; return 0; }
    host="$(cd "$2" 2>/dev/null && pwd)" || { printf '%s/' "$layer"; return 0; }
    [ "$layer" = "$host" ] && return 0
    _rt_under "$layer" "$host" && return 0
    layer_p="$(cd "$1" && pwd -P)"
    host_p="$(cd "$2" && pwd -P)"
    [ "$layer_p" = "$host_p" ] && return 0
    _rt_under "$layer_p" "$host_p" && return 0
    printf '%s/' "$layer"
}

# file_sha256 <file>
# Print the file's sha256, or nothing (status 0) when the file is unreadable or
# neither sha256sum nor shasum exists; render_template then treats an existing
# destination as a local edit.
file_sha256() {
    local out=""
    if command -v sha256sum >/dev/null 2>&1; then
        out="$(sha256sum "$1" 2>/dev/null)" || out=""
    elif command -v shasum >/dev/null 2>&1; then
        out="$(shasum -a 256 "$1" 2>/dev/null)" || out=""
    fi
    printf '%s' "${out%% *}"
}

# render_placeholder <text> <placeholder> <replacement> — print <text> with every
# <placeholder> replaced. Split-and-join on literal (quoted) patterns, so the
# replacement is never interpreted (`&`, quotes, backslashes stay as written).
render_placeholder() {
    local rest="$1" ph="$2" rep="$3" out=""
    while [[ "$rest" == *"$ph"* ]]; do
        out="$out${rest%%"$ph"*}$rep"
        rest="${rest#*"$ph"}"
    done
    printf '%s' "$out$rest"
}

# _rt_stamp_path <dst> — where render_template records the sha256 of what it
# last wrote to <dst>: a dotfile beside it (`.cursor/rules/.agents.mdc.sha256`),
# outside the `*.mdc` set Cursor loads.
_rt_stamp_path() {
    printf '%s/.%s.sha256' "$(dirname "$1")" "$(basename "$1")"
}

# _rt_writable <path> — succeed when <path> is absent or a regular file that is
# not a symlink. A symlink (dangling or not) or any other file type is never
# written through: the write would land on whatever the link names.
_rt_writable() {
    [ -L "$1" ] && return 1
    [ -e "$1" ] && [ ! -f "$1" ] && return 1
    return 0
}

# _rt_write_stamp <dst> <stamp> — record <dst>'s sha256 in <stamp>; a stamp
# path that _rt_writable refuses is left alone, which only costs the next run
# its stamp-based upgrade.
_rt_write_stamp() {
    _rt_writable "$2" || return 0
    file_sha256 "$1" > "$2"
}

# render_template <src> <dst> <prefix> [superseded-sha256 ...]
# Write <src> to <dst> with every {{AGENT_LAYER}} replaced by <prefix>, and
# stamp the sha256 of what was written.
# copy_template's never-clobber contract holds: an existing <dst> that differs
# from the rendering is a local edit and is left alone, and a symlink or other
# non-regular file in <dst>'s place is never written through. <dst> is not a
# local edit, and is upgraded, when it still matches the stamp (this script
# wrote it and nobody changed it since) or a listed sha256 (a copy of a
# template version shipped before rendering and stamping existed).
render_template() {
    local src="$1" dst="$2" prefix="$3" rendered stamp sha known legacy
    shift 3
    rendered="$(cat "$src")" || return 1
    rendered="$(render_placeholder "$rendered" '{{AGENT_LAYER}}' "$prefix")"
    stamp="$(_rt_stamp_path "$dst")"
    mkdir -p "$(dirname "$dst")"
    if ! _rt_writable "$dst"; then
        echo "  skip-copy  $dst (a symlink or not a regular file — not writing through it)"
        return 0
    fi
    if [ -f "$dst" ]; then
        if [ "$(cat "$dst")" = "$rendered" ]; then
            [ -f "$stamp" ] || _rt_write_stamp "$dst" "$stamp"
            return 0
        fi
        sha="$(file_sha256 "$dst")"
        known=""
        if [ -n "$sha" ]; then
            if [ -f "$stamp" ] && [ ! -L "$stamp" ] && [ "$(cat "$stamp")" = "$sha" ]; then
                known="stamp"
            else
                for legacy in "$@"; do
                    if [ "$sha" = "$legacy" ]; then
                        known="legacy"
                    fi
                done
            fi
        fi
        if [ -z "$known" ]; then
            echo "  skip-copy  $dst (user-modified — not overwriting)"
            return 0
        fi
        printf '%s\n' "$rendered" > "$dst"
        _rt_write_stamp "$dst" "$stamp"
        echo "  upgrade    $dst (unmodified since setup wrote it)"
        return 0
    fi
    printf '%s\n' "$rendered" > "$dst"
    _rt_write_stamp "$dst" "$stamp"
    echo "  render     $dst"
}
