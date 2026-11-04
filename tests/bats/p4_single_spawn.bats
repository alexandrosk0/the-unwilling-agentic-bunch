#!/usr/bin/env bats
# tests/bats/p4_single_spawn.bats
# ----------------------------------------------------------------------------
# Bats coverage for the p4-single-spawn lint rule
# (agents/scripts/project/lint-rules.d/77-p4-single-spawn.sh): the Perforce annotate
# implementation keeps exactly one SubprocessCapture::Run spawn and at least one
# cfg.P4RunOverride consult (the zero-credential test seam), counted on code with
# comments stripped. Each fixture is a throwaway git tree the module scans from its root.
#
# Requires: bash, bats, git.
# ----------------------------------------------------------------------------

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    export REPO_ROOT
    export MOD="$REPO_ROOT/agents/scripts/project/lint-rules.d/77-p4-single-spawn.sh"
}

teardown() {
    # Clean outside the @test body so a trailing rm never masks a failing assertion.
    [ -n "${tmp:-}" ] && rm -rf "$tmp"
    return 0
}

# Build a fixture tree with a tracked P4Annotate.h and the given P4Annotate.cpp body.
_fixture() {
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/Source/Core/include" "$tmp/Source/Core/src"
    printf '#pragma once\n' > "$tmp/Source/Core/include/P4Annotate.h"
    printf '%b' "$1" > "$tmp/Source/Core/src/P4Annotate.cpp"
    ( cd "$tmp" && git init -q && git add -A ) >/dev/null 2>&1
}

_scan() {
    run bash -c "set -euo pipefail; cd '$tmp' && source '$MOD' && compute_p4_single_spawn_violations"
}

GOOD='bool P4RunCommand(const Cfg& cfg) {\n    if (cfg.P4RunOverride) {\n        return cfg.P4RunOverride(args);\n    }\n    auto r = SubprocessCapture::Run(opts);\n    return r.has_value();\n}\n'

@test "one Run + an override consult passes" {
    _fixture "$GOOD"
    _scan
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "two SubprocessCapture::Run calls fail, anchored on the second" {
    _fixture 'bool A(const Cfg& cfg) {\n    if (cfg.P4RunOverride) {\n        return true;\n    }\n    SubprocessCapture::Run(opts);\n    return true;\n}\nbool B() {\n    return SubprocessCapture::Run(opts).has_value();\n}\n'
    _scan
    [ "$status" -eq 0 ]
    [[ "$output" == *"p4-single-spawn"*"Source/Core/src/P4Annotate.cpp:9"*"calls=2"* ]]
}

@test "zero cfg.P4RunOverride consults fail" {
    _fixture 'bool P4RunCommand(const Cfg& cfg) {\n    return SubprocessCapture::Run(opts).has_value();\n}\n'
    _scan
    [ "$status" -eq 0 ]
    [[ "$output" == *"p4-single-spawn"*"consults=0"* ]]
}

@test "an override named only in a comment does not count as a consult" {
    _fixture '// installs cfg.P4RunOverride for tests\n/* cfg.P4RunOverride is\n   consulted elsewhere */\nbool P4RunCommand(const Cfg& cfg) {\n    return SubprocessCapture::Run(opts).has_value();\n}\n'
    _scan
    [ "$status" -eq 0 ]
    [[ "$output" == *"consults=0"* ]]
}

@test "a Run mentioned only in a comment does not count as a call" {
    _fixture '// a second SubprocessCapture::Run(opts) would bypass the seam\n'"$GOOD"
    _scan
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "zero Run calls fail" {
    _fixture 'bool P4RunCommand(const Cfg& cfg) {\n    if (cfg.P4RunOverride) {\n        return true;\n    }\n    return false;\n}\n'
    _scan
    [ "$status" -eq 0 ]
    [[ "$output" == *"calls=0"* ]]
}

@test "another spawn primitive fails" {
    _fixture "$GOOD"'int Legacy() {\n    return std::system("p4 info");\n}\n'
    _scan
    [ "$status" -eq 0 ]
    [[ "$output" == *"p4-single-spawn"*"P4Annotate.cpp:9"*"second spawn primitive"* ]]
}

@test "a wide-char CRT spawn (_wpopen) fails" {
    _fixture "$GOOD"'#if defined(_WIN32)\nFILE* Legacy() {\n    return _wpopen(L"p4 info", L"r");\n}\n#endif\n'
    _scan
    [ "$status" -eq 0 ]
    [[ "$output" == *"p4-single-spawn"*"P4Annotate.cpp:10"*"second spawn primitive"* ]]
}

@test "a Windows shell launch (ShellExecuteW) fails" {
    _fixture "$GOOD"'void OpenP4() {\n    ShellExecuteW(nullptr, nullptr, L"p4.exe", L"sync", nullptr, SW_HIDE);\n}\n'
    _scan
    [ "$status" -eq 0 ]
    [[ "$output" == *"p4-single-spawn"*"P4Annotate.cpp:9"*"second spawn primitive"* ]]
}

@test "the exec and posix_spawn families fail, one finding per line" {
    _fixture "$GOOD"'void Legacy(char* const* argv, pid_t* pid) {\n    execvp("p4", argv);\n    posix_spawnp(pid, "p4", nullptr, nullptr, argv, environ);\n    _wsystem(L"p4 sync");\n}\n'
    _scan
    [ "$status" -eq 0 ]
    [[ "$output" == *"P4Annotate.cpp:9"*"P4Annotate.cpp:10"*"P4Annotate.cpp:11"* ]]
}

@test "a longer identifier ending in a spawn name does not fail" {
    _fixture "$GOOD"'int ParseSystem(int x) { return x; }\nint Run_popen(int x) { return ParseSystem(x); }\nint TryCreateProcessAsUser(int x) { return Run_popen(x); }\n'
    _scan
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a SMATCHET_DEVIATION(rule=p4-single-spawn) anywhere in the file escapes" {
    _fixture '// SMATCHET_DEVIATION(rule=p4-single-spawn; reason=test; owner=x; revisit=2099-01-01)\nbool A() {\n    return SubprocessCapture::Run(a).has_value() && SubprocessCapture::Run(b).has_value();\n}\n'
    _scan
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "the implementation missing while its header is tracked fails" {
    _fixture "$GOOD"
    rm "$tmp/Source/Core/src/P4Annotate.cpp"
    _scan
    [ "$status" -eq 0 ]
    [[ "$output" == *"p4-single-spawn"*"implementation missing"* ]]
}

@test "a tree without the P4Annotate header has nothing to check" {
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/Source/Core/src/Ui"
    printf 'void F() {}\n' > "$tmp/Source/Core/src/Ui/F.cpp"
    ( cd "$tmp" && git init -q && git add -A ) >/dev/null 2>&1
    _scan
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "the real host tree passes" {
    # The host tree is PROJECT_ROOT (the superproject when this layer is its agent-layer/
    # submodule). The layer's own checkout has no Source/, so there is nothing to scan there.
    # Resolved with the inherited roots cleared: the host's test-all.sh runs layer suites with the
    # layer as PROJECT_ROOT, which would otherwise always skip this case there.
    local host
    host="$(env -u PROJECT_ROOT -u PC_PROJECT_ROOT -u AGENT_LAYER_ROOT -u PC_AGENT_LAYER_ROOT \
        -u SMATCHET_PROJECT_ROOT_OVERRIDE -u SMATCHET_PROJECT_CONFIG \
        bash -c 'PC_ROOTS_ONLY=1 . "$1" >/dev/null 2>&1; printf %s "${PROJECT_ROOT:-}"' _ \
        "$REPO_ROOT/scripts/dev/project-config.sh")"
    if [ -z "$host" ] || [ ! -f "$host/Source/Core/include/P4Annotate.h" ]; then
        skip "no host tree with Source/Core/include/P4Annotate.h (layer-only checkout)"
    fi
    run bash -c "set -euo pipefail; cd '$host' && source '$MOD' && compute_p4_single_spawn_violations"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
