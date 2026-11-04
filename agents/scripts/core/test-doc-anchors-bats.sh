#!/usr/bin/env bash
# test-doc-anchors-bats.sh — bats wrapper for tests/bats/doc_anchors.bats.
#
# Bucket A (CLI) per AGENTS.md § Verification automation. Zero manual steps.
# Auto-enrolled by scripts/dev/test-all.sh via the test-*.sh glob.
#
# Wraps the regression suite for agents/scripts/core/test_doc_anchors.py: the
# --selftest passes and never touches the caller's repository when a git hook
# has exported GIT_DIR; a path-qualified leaf reference resolves against that
# leaf (and a wrong section fails); a file-relative reference resolves against
# the sibling leaf. Emits the canonical `Passed: N  Failed: M` line test-all.sh
# greps.
#
# Exit codes follow the test-script convention (see the test-all.sh header):
#   0 — every bats test passed
#   1 — at least one bats test failed
#   2 — bats binary missing (BUILD.md § Dev-script CLI tools lists the install)

set -uo pipefail

CDPATH='' cd "$(dirname "$0")/../../.." || exit 2

if ! command -v bats >/dev/null 2>&1; then
    cat >&2 <<'MSG'
test-doc-anchors-bats: bats not on PATH.
  Install: npm i -g bats   (preferred — resolves on the bash-tool PATH)
           pacman -S bats  (MSYS2)
           brew install bats-core  (macOS)
  See BUILD.md § Dev-script CLI tools.
MSG
    echo "Passed: 0  Failed: 0  (skipped — bats missing)"
    exit 2
fi

BATS_FILE="tests/bats/doc_anchors.bats"
if [ ! -f "$BATS_FILE" ]; then
    echo "test-doc-anchors-bats: $BATS_FILE not found" >&2
    echo "Passed: 0  Failed: 1"
    exit 1
fi

OUT="$(bats --tap "$BATS_FILE" 2>&1)"
RC=$?

echo "$OUT"

passed="$(printf '%s\n' "$OUT" | grep -cE '^ok ')"
failed="$(printf '%s\n' "$OUT" | grep -cE '^not ok ')"
echo "Passed: $passed  Failed: $failed"

[ "$RC" -eq 0 ] && [ "$failed" -eq 0 ] && exit 0
exit 1
