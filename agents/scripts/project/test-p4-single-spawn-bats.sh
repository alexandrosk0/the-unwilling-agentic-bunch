#!/usr/bin/env bash
# test-p4-single-spawn-bats.sh — bats wrapper for tests/bats/p4_single_spawn.bats.
#
# Bucket A (CLI). Zero manual steps. Auto-enrolled by scripts/dev/test-all.sh via the
# test-*.sh glob. Covers the p4-single-spawn lint rule module
# (agents/scripts/project/lint-rules.d/77-p4-single-spawn.sh) directly, so the rule's
# detection is tested apart from the test-lint-rules.sh entry point that wires it in.
#
# Exit codes (test-author convention):
#   0 — every bats test passed
#   1 — at least one bats test failed
#   2 — bats binary missing (BUILD.md § Dev-script CLI tools)

set -uo pipefail
CDPATH='' cd "$(dirname "$0")/../../.." || exit 2

if ! command -v bats >/dev/null 2>&1; then
    cat >&2 <<'EOF'
test-p4-single-spawn-bats: bats not on PATH.
  Install: npm i -g bats   (preferred — resolves on the bash-tool PATH)
           pacman -S bats  (MSYS2)
           brew install bats-core  (macOS)
  See BUILD.md § Dev-script CLI tools.
EOF
    echo "Passed: 0  Failed: 0  (skipped — bats missing)"
    exit 2
fi

BATS_FILE="tests/bats/p4_single_spawn.bats"
[ -f "$BATS_FILE" ] || { echo "missing $BATS_FILE" >&2; exit 1; }

OUT="$(bats --tap "$BATS_FILE" 2>&1)"
rc=$?
echo "$OUT"
p=$(printf '%s\n' "$OUT" | grep -cE '^ok [0-9]+' || true)
f=$(printf '%s\n' "$OUT" | grep -cE '^not ok [0-9]+' || true)
echo "Passed: ${p}  Failed: ${f}"
if [ "$f" -gt 0 ] || [ "$rc" -ne 0 ]; then
    exit 1
fi
exit 0
