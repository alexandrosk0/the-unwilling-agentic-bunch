#!/usr/bin/env bash
# test-setup-harness.sh — V1 + V7 verification for docs/plans/shipped/agents-skill-conversion.md.
#
# Covers:
#   1. setup-harness.sh claude-code creates .claude/skills/perf-measure + .claude/skills/perf-instrument symlinks.
#   2. Existing skills (grill-with-docs, scratchpad-recall) still linked (no regression).
#   3. Re-running setup-harness.sh produces zero new link-dir lines (idempotency).
#   4. agents/perf-{measure,instrument}.md still exist (dual-publish: agent form preserved for Codex / Cursor).
#   5. SKILL.md aliases exist + contain a sync-warning header comment.
#   6. V7 doc-consistency: rg matches in agents/ + docs/ are consistent with dual-publish wording
#      (perf-detective / spike-hunter / debug-detective all mention skill-form availability).
#   7. sync-settings-hooks.sh heals missing template hooks additively.
#   8. Codex setup verifies native discovery, generates Codex-native
#      hooks/custom agents, and does not clobber Claude Code setup.
#   9. Leaf CLAUDE.md shims are written beside leaves at any depth under
#      Source/ only where no CLAUDE.md exists and the path is ignored (a tracked
#      or user-owned CLAUDE.md is left alone); dangling LAYER links under
#      .claude/skills + .claude/workflows are pruned, a user's own links and
#      dirs are not (hermetic temp host, no global git config).
#
# Auto-enrolled by scripts/dev/test-all.sh.

set -euo pipefail

# Two trees. The adapters setup-harness writes (.claude/, .codex/) and the project
# agents (agents/project/) are HOST content: cwd is the host — PROJECT_ROOT from
# scripts/dev/project-config.sh (the superproject once the layer is a submodule),
# the very tree the setup-harness under test writes into, so the snapshot, the
# restore and every assertion cover what the run wrote. (Not CLAUDE_PROJECT_DIR:
# set to another checkout, it split the test from the writes — the assertions read
# a tree nothing wrote, and the real writes went unrestored.) What the test runs
# and reads from the layer (setup-harness.sh, agents/core/, the skills, the rule
# docs, the harness templates) is addressed through LAYER, this script's own tree.
# Before the flip the two are one checkout.
LAYER="$(cd "$(dirname "$0")/../../.." && pwd)"
if [ -f "$LAYER/scripts/dev/project-config.sh" ]; then
    # shellcheck source=scripts/dev/project-config.sh
    PC_ROOTS_ONLY=1 . "$LAYER/scripts/dev/project-config.sh" || true
else
    unset PROJECT_ROOT AGENT_LAYER_ROOT  # no config beside this script (a fixture copy): its own tree, never an inherited root
fi
PROJ_DIR="${PROJECT_ROOT:-$LAYER}"
cd "$PROJ_DIR" || exit 1
SETUP_HARNESS="$LAYER/agents/scripts/core/setup-harness.sh"

PY=""
for _c in python3 python py; do
    _p="$(command -v "$_c" 2>/dev/null)" || continue
    if "$_p" -c "" >/dev/null 2>&1; then
        PY="$_p"
        break
    fi
done

PASS=0
FAIL=0
declare -a FAILURES=()

note() { echo "[setup-harness] $*"; }
ok()   { PASS=$((PASS + 1)); echo "  PASS  $1"; }
nope() { FAIL=$((FAIL + 1)); FAILURES+=("$1"); echo "  FAIL  $1"; }

# --- Hermetic-adapter guard (order-independence for test-all.sh) --------------
# setup-harness.sh has no root override — it regenerates the REAL .claude/ adapter
# (agents/hooks/skills/settings). This test invokes it against the live tree, so
# left unrestored it FRESHENS .claude/ and MASKS the staleness that
# test-adapter-drift / test-agent-contract exist to catch: if this test runs
# earlier in test-all.sh, a genuine stale-adapter drift is silently re-linked away
# (reproduced: drift → this test → drift now passes). Snapshot the adapter
# artifacts this test perturbs and restore them byte-for-byte on exit, so the
# shared mirror is exactly as we found it regardless of suite order.
_HARNESS_SNAP="$(mktemp -d)"
_HARNESS_SNAP_PATHS=(.claude/agents .claude/hooks .claude/skills .claude/settings.json)
for _hp in "${_HARNESS_SNAP_PATHS[@]}"; do
    if [ -e "$_hp" ]; then
        mkdir -p "$_HARNESS_SNAP/$(dirname "$_hp")"
        cp -a "$_hp" "$_HARNESS_SNAP/$_hp" 2>/dev/null || true
    fi
done
# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
_restore_harness_snapshot() {
    local _hp
    for _hp in "${_HARNESS_SNAP_PATHS[@]}"; do
        rm -rf "$_hp" 2>/dev/null || true
        if [ -e "$_HARNESS_SNAP/$_hp" ]; then
            mkdir -p "$(dirname "$_hp")"
            cp -a "$_HARNESS_SNAP/$_hp" "$_hp" 2>/dev/null || true
        fi
    done
    rm -rf "$_HARNESS_SNAP"
}
trap _restore_harness_snapshot EXIT

# Resolve an agent's canonical .md across the post-reorg layout (agents/core/
# + agents/project/, falling back to the legacy flat path). The agentic reorg
# (PRs #542-549) split agents into core/ + project/; this test follows.
# Prints the path and returns 0 if found; returns 1 otherwise.
resolve_agent_md() {
    local name="$1"
    local candidate
    for candidate in "$LAYER/agents/core/${name}.md" "$PROJ_DIR/agents/project/${name}.md" "$LAYER/agents/${name}.md"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# -------------------------------------------------------------------- Test 1
note "Test 1 — first run links perf-measure + perf-instrument skills"
# setup-harness.sh is idempotent; if links exist, this is a no-op.
SETUP_OUT_1=$(bash "$SETUP_HARNESS" claude-code 2>&1) || true  # assert on artifacts regardless of exit; keep the suite running

if [[ -e ".claude/skills/perf-measure/SKILL.md" ]]; then
    ok "perf-measure SKILL.md reachable via .claude/skills/"
else
    nope "perf-measure SKILL.md missing under .claude/skills/"
fi

if [[ -e ".claude/skills/perf-instrument/SKILL.md" ]]; then
    ok "perf-instrument SKILL.md reachable via .claude/skills/"
else
    nope "perf-instrument SKILL.md missing under .claude/skills/"
fi

# HP-02: lint-cpp-common.sh invokes .claude/hooks/lint-catch-all.py, so setup
# must deploy it (previously never copied → the catch-all lint silently no-op'd).
if [[ -e ".claude/hooks/lint-catch-all.py" ]]; then
    ok "lint-catch-all.py deployed to .claude/hooks/ (HP-02)"
else
    nope "lint-catch-all.py missing from .claude/hooks/ — HP-02 regression (lint-cpp-common invokes it)"
fi

# -------------------------------------------------------------------- Test 2
note "Test 2 — existing skills still linked (no regression)"
for existing in grill-with-docs scratchpad-recall agent-tokens; do
    if [[ -e ".claude/skills/$existing/SKILL.md" ]]; then
        ok "$existing SKILL.md reachable"
    else
        nope "$existing SKILL.md missing — regression"
    fi
done

# -------------------------------------------------------------------- Test 3
note "Test 3 — re-run produces zero new link-dir lines (idempotency)"
SETUP_OUT_2=$(bash "$SETUP_HARNESS" claude-code 2>&1) || true  # assert on artifacts regardless of exit; keep the suite running
NEW_LINKS=$(echo "$SETUP_OUT_2" | grep -c '^\s*link-' || true)
if [[ "$NEW_LINKS" -eq 0 ]]; then
    ok "idempotent re-run (zero new link- lines)"
else
    nope "re-run produced $NEW_LINKS link- lines (expected 0)"
fi

# -------------------------------------------------------------------- Test 4
note "Test 4 — agent files preserved under dual-publish"
for agent in perf-measure perf-instrument; do
    if agent_path="$(resolve_agent_md "$agent")"; then
        ok "$agent_path exists (cross-harness canonical)"
    else
        nope "agents/{core,project}/$agent.md missing — dual-publish broken"
    fi
done

# -------------------------------------------------------------------- Test 5
note "Test 5 — SKILL.md aliases have sync-warning header"
for skill in perf-measure perf-instrument; do
    SKILL_FILE="$LAYER/agents/_shared/skills/$skill/SKILL.md"
    if [[ ! -f "$SKILL_FILE" ]]; then
        nope "$SKILL_FILE missing"
        continue
    fi
    # The agentic reorg (PRs #542-549) reworded the sync-warning header and
    # moved the referenced agent file from agents/<skill>.md to
    # agents/core/<skill>.md. Match on the durable intent (a "mirror" header
    # that points back at the canonical agent file + a keep-in-sync directive)
    # rather than the exact pre-reorg sentence.
    if grep -qi "mirror" "$SKILL_FILE" && grep -qi "in sync" "$SKILL_FILE"; then
        ok "$skill SKILL.md carries sync-warning header"
    else
        nope "$skill SKILL.md missing sync-warning header"
    fi
done

# -------------------------------------------------------------------- Test 6
note "Test 6 — V7 doc-consistency: dependent agents mention skill-form availability"
for agent in perf-detective spike-hunter debug-detective; do
    if ! agent_path="$(resolve_agent_md "$agent")"; then
        nope "agents/{core,project}/$agent.md (or legacy agents/$agent.md) missing"
    elif grep -q "Helper-form preference" "$agent_path"; then
        ok "$agent_path mentions skill-form preference"
    else
        nope "$agent_path missing Helper-form preference block"
    fi
done

if grep -q "Claude Code skill alias" "$LAYER/docs/agent-rules/delegation.md"; then
    ok "delegation.md mentions skill-alias availability"
else
    nope "delegation.md missing skill-alias note"
fi

# -------------------------------------------------------------------- Test 7
note "Test 7 — sync-settings-hooks.sh heals missing template hooks (additive, non-destructive)"
T7_SYNC="$LAYER/agents/scripts/core/sync-settings-hooks.sh"
T7_TMPL="$LAYER/docs/harness/claude-code/settings.json.tmpl"
if ! command -v jq >/dev/null 2>&1; then
    ok "Test 7 skipped — jq not installed (sync degrades to a WARN by design)"
elif [[ ! -f "$T7_SYNC" || ! -f "$T7_TMPL" ]]; then
    nope "Test 7 — $T7_SYNC or $T7_TMPL missing"
else
    T7_DIR="$(mktemp -d)"
    T7_DEP="$T7_DIR/settings.json"
    mkdir -p "$T7_DIR/hooks"
    : > "$T7_DIR/hooks/layer-run.sh"   # the dispatcher a reroute needs, deployed beside the settings
    # Deployed: permissions sentinel + a user-added custom SessionStart hook +
    # only the bootstrap hook + only lint-cpp-drain under Stop (the proven gap).
    # The bootstrap hook is in its pre-dispatcher form, naming the layer script
    # from the project dir; a user hook in that same form names a script the
    # template does not, so the sync must reroute the first and leave the second.
    cat > "$T7_DEP" <<'JSON'
{
  "permissions": { "defaultMode": "plan", "allow": ["Bash(ls:*)"] },
  "hooks": {
    "SessionStart": [
      { "matcher": "", "hooks": [
        { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/agents/scripts/core/clear-session-context.sh\"", "timeout": 3000 },
        { "type": "command", "command": "echo t7-user-hook", "timeout": 1000 },
        { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/agents/scripts/core/t7-user-tool.sh\"", "timeout": 1000 }
      ]}
    ],
    "Stop": [
      { "matcher": "", "hooks": [
        { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/lint-cpp-drain.sh\"", "timeout": 120000 }
      ]}
    ]
  }
}
JSON
    bash "$T7_SYNC" "$T7_TMPL" "$T7_DEP" >/dev/null 2>&1 || true
    T7_BEFORE="$(cat "$T7_DEP")"
    bash "$T7_SYNC" "$T7_TMPL" "$T7_DEP" >/dev/null 2>&1 || true   # 2nd run = idempotent?
    T7_AFTER="$(cat "$T7_DEP")"

    if [[ -z "$PY" ]]; then
        nope "Test 7 - python not found for sync-settings-hooks assertion"
    elif "$PY" - "$T7_DEP" "$T7_TMPL" <<'PY'
import json, sys
dep = json.load(open(sys.argv[1])); tmpl = json.load(open(sys.argv[2]))
assert dep.get("permissions") == {"defaultMode": "plan", "allow": ["Bash(ls:*)"]}, "permissions clobbered"
def cmds(o):
    return {(ev, g.get("matcher", ""), h["command"])
            for ev, groups in o["hooks"].items() for g in groups for h in g["hooks"]}
missing = cmds(tmpl) - cmds(dep)
assert not missing, f"template hooks not healed: {missing}"
ss = [h["command"] for g in dep["hooks"]["SessionStart"] for h in g["hooks"]]
assert "echo t7-user-hook" in ss, "user hook lost"
user_tool = 'bash "$CLAUDE_PROJECT_DIR/agents/scripts/core/t7-user-tool.sh"'
assert user_tool in ss, "a user hook the template does not name was rewritten"
legacy = [c for c in ss if c.startswith('bash "$CLAUDE_PROJECT_DIR/agents/') and c != user_tool]
assert not legacy, f"legacy layer hook not rerouted through layer-run.sh: {legacy}"
assert len(ss) == len(set(ss)), "a SessionStart hook runs twice"
assert len([g for g in dep["hooks"]["Stop"] if g.get("matcher", "") == ""]) == 1, "duplicate Stop matcher group"
PY
    then
        ok "sync heals missing hooks (permissions preserved, user hooks kept, legacy layer hook rerouted once, no Stop dup)"
    else
        nope "sync-settings-hooks.sh merge incorrect"
    fi
    if [[ "$T7_BEFORE" == "$T7_AFTER" ]]; then
        ok "sync is idempotent (2nd run no-op)"
    else
        nope "sync not idempotent — 2nd run changed the file"
    fi
    # hooks-session-lifecycle-03: --check reports deployed hooks with no template
    # counterpart. The deployed fixture carries `echo t7-user-hook` (not in the
    # template), so --check must surface it (read-only — leaves the file untouched).
    T7_CHECK="$(bash "$T7_SYNC" --check "$T7_TMPL" "$T7_DEP" 2>&1 || true)"
    if [[ "$T7_CHECK" == *"t7-user-hook"* && "$T7_CHECK" == *"NO template counterpart"* ]]; then
        ok "sync --check flags a deployed hook absent from the template (hooks-session-lifecycle-03)"
    else
        nope "sync --check did not flag the template-absent deployed hook: $T7_CHECK"
    fi
    if [[ "$(cat "$T7_DEP")" == "$T7_AFTER" ]]; then
        ok "sync --check is read-only (deployed file unchanged)"
    else
        nope "sync --check mutated the deployed file"
    fi
    # The old form appended beside the new one (an older branch's sync ran in this
    # tree) collapses to one entry rather than running every hook twice.
    jq --slurpfile d "$T7_DEP" '.hooks.SessionStart[0].hooks += [{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/agents/scripts/core/clear-session-context.sh\""}]' \
        "$T7_TMPL" > "$T7_DIR/dup.json"
    mv "$T7_DIR/dup.json" "$T7_DEP"
    bash "$T7_SYNC" "$T7_TMPL" "$T7_DEP" >/dev/null 2>&1 || true
    if [[ -z "$(jq -r '.hooks.SessionStart[].hooks[].command' "$T7_DEP" | sort | uniq -d)" ]]; then
        ok "a legacy hook beside its rerouted form collapses to one entry"
    else
        nope "sync left a SessionStart hook in the group twice"
    fi
    # No dispatcher deployed: the legacy command still works before the flip, so it
    # is left alone rather than rerouted to a script that is not there.
    rm -f "$T7_DIR/hooks/layer-run.sh"
    printf '%s\n' '{"hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/agents/scripts/core/clear-session-context.sh\""}]}]}}' > "$T7_DEP"
    bash "$T7_SYNC" "$T7_TMPL" "$T7_DEP" >/dev/null 2>&1 || true
    if jq -r '.hooks.SessionStart[].hooks[].command' "$T7_DEP" | grep -qxF 'bash "$CLAUDE_PROJECT_DIR/agents/scripts/core/clear-session-context.sh"'; then
        ok "without a deployed layer-run.sh the legacy hook is not rerouted"
    else
        nope "sync rerouted a legacy hook to a dispatcher that is not deployed"
    fi
    rm -rf "$T7_DIR"
fi

# -------------------------------------------------------------------- Test 8
note "Test 8 - codex setup generates native hooks/agents without clobbering Claude setup"
SETUP_CODEX_OUT=$(bash "$SETUP_HARNESS" codex 2>&1) || true  # assert on artifacts regardless of exit; keep the suite running
if echo "$SETUP_CODEX_OUT" | grep -q 'Codex parity report:'; then
    ok "codex setup emits parity report"
else
    nope "codex setup missing parity report"
fi
if echo "$SETUP_CODEX_OUT" | grep -q 'agents/{core,project}/\*.md = '; then
    ok "codex setup counts agents/{core,project}/*.md"
else
    nope "codex setup did not count canonical agent files"
fi
if echo "$SETUP_CODEX_OUT" | grep -q '\.codex/agents/\*\.toml'; then
    ok "codex setup reports generated custom agents"
else
    nope "codex setup missing generated custom-agent report"
fi
if echo "$SETUP_CODEX_OUT" | grep -q 'Safe SessionStart/Stop command hooks'; then
    ok "codex setup reports Codex-native hook install"
else
    nope "codex setup missing Codex-native hook install report"
fi
if echo "$SETUP_CODEX_OUT" | grep -q 'git-hooks'; then
    ok "codex setup reports git-hook wiring state"
else
    nope "codex setup missing git-hook wiring report"
fi
if [[ -f ".codex/config.toml" && -f ".codex/hooks.json" ]]; then
    ok ".codex config + hooks generated"
else
    nope ".codex config or hooks missing after codex setup"
fi
CANONICAL_AGENT_COUNT=$(( $(find "$LAYER/agents/core" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ' || true) + $(find "$PROJ_DIR/agents/project" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ' || true) ))
CODEX_AGENT_COUNT=$(find .codex/agents -maxdepth 1 -name '*.toml' 2>/dev/null | wc -l | tr -d ' ' || true)
if [[ "$CODEX_AGENT_COUNT" -eq "$CANONICAL_AGENT_COUNT" ]]; then
    ok ".codex/agents count matches canonical agent count"
else
    nope ".codex/agents count $CODEX_AGENT_COUNT did not match canonical count $CANONICAL_AGENT_COUNT"
fi
if [[ -f ".codex/agents/code-review.toml" ]] \
    && grep -q 'name = "code-review"' ".codex/agents/code-review.toml" \
    && grep -q 'developer_instructions =' ".codex/agents/code-review.toml"; then
    ok "generated code-review Codex agent has required fields"
else
    nope "generated code-review Codex agent missing required fields"
fi
if [[ -n "$PY" ]] && "$PY" -m json.tool ".codex/hooks.json" >/dev/null 2>&1; then
    ok ".codex/hooks.json is valid JSON"
elif [[ -z "$PY" ]]; then
    nope "python not found for .codex/hooks.json validation"
else
    nope ".codex/hooks.json is invalid JSON"
fi
if [[ -f ".claude/settings.json" && -e ".claude/skills/perf-measure/SKILL.md" ]]; then
    ok "codex setup left Claude Code adapter intact"
else
    nope "codex setup clobbered Claude Code adapter files"
fi

# -------------------------------------------------------------------- Test 9
note "Test 9 — leaf shims (ignored, absent paths only; any depth under Source/); dangling layer links pruned"
# Hermetic: a throwaway host repo, so the live tree's adapter is never touched;
# no global/system git config (commit signing, a global excludesFile listing
# CLAUDE.md) can change the result; and no GIT_DIR-family variable a git hook may
# have exported can aim the fixture's git commands at the caller's repository.
# SMATCHET_PROJECT_ROOT_OVERRIDE=1 aims the layer's setup at that host.
T9_HOST="$(mktemp -d)"
T9_HOST="$(cd "$T9_HOST" && pwd -P)"
trap '_restore_harness_snapshot; rm -rf "$T9_HOST"' EXIT
T9_GIT_ENV=(-u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR
            -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_PREFIX
            GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1)
t9_fixture() {
    cd "$T9_HOST" || return 1
    git init -q -b develop . || return 1
    git config user.email t@local
    git config user.name t
    git config commit.gpgsign false
    mkdir -p Source/Core/src/Alpha Source/Core/src/Epsilon Source/Plugins/Beta \
             Source/Plugins/Gamma Source/Plugins/Delta
    for leaf in Source/Core/src/Alpha Source/Core/src/Epsilon Source/Plugins/Beta \
                Source/Plugins/Gamma Source/Plugins/Delta; do
        printf '# %s rules\n' "${leaf##*/}" > "$leaf/AGENTS.md"
    done
    # Every leaf's CLAUDE.md is ignored except Gamma's.
    printf 'Source/**/CLAUDE.md\n!Source/Plugins/Gamma/CLAUDE.md\n.claude/\n' > .gitignore
    # Delta: a tracked (force-added) CLAUDE.md with the team's own content.
    printf '# team notes\n' > Source/Plugins/Delta/CLAUDE.md
    git add -A && git add -f Source/Plugins/Delta/CLAUDE.md && git commit -qm seed || return 1
    # Epsilon: the user's own untracked (ignored) CLAUDE.md notes.
    printf '# my local notes\n' > Source/Core/src/Epsilon/CLAUDE.md
    mkdir -p .claude/skills/zz-user-skill .claude/workflows
    printf 'user-owned\n' > .claude/skills/zz-user-skill/SKILL.md
    ln -s ../../agent-layer/agents/_shared/skills/zz-removed .claude/skills/zz-removed-skill
    ln -s ../../agents/_shared/workflows/zz-removed.js .claude/workflows/zz-removed.js
    ln -s ../../no-such-dotfiles/my-skill .claude/skills/zz-user-link
}
if ! env "${T9_GIT_ENV[@]}" bash -c "$(declare -f t9_fixture); T9_HOST='$T9_HOST' t9_fixture" >/dev/null 2>&1; then
    nope "Test 9 fixture setup failed (git init/commit in a temp host)"
else
    T9_OUT="$(env "${T9_GIT_ENV[@]}" SMATCHET_PROJECT_ROOT_OVERRIDE=1 \
        PROJECT_ROOT="$T9_HOST" AGENT_LAYER_ROOT="$LAYER" bash "$SETUP_HARNESS" claude-code 2>&1)" || true
    if grep -qx '@AGENTS.md' "$T9_HOST/Source/Core/src/Alpha/CLAUDE.md" 2>/dev/null \
        && grep -qx '@AGENTS.md' "$T9_HOST/Source/Plugins/Beta/CLAUDE.md" 2>/dev/null; then
        ok "shims written beside ignored leaves (Source/Core/src/<ctx>/ and a plugin dir)"
    else
        nope "shim missing beside an ignored leaf (Alpha or Beta)"
    fi
    if [[ ! -e "$T9_HOST/Source/Plugins/Gamma/CLAUDE.md" ]] \
        && grep -q 'Source/Plugins/Gamma/CLAUDE.md is not ignored' <<< "$T9_OUT"; then
        ok "no shim beside a leaf whose CLAUDE.md is not ignored, and the skip is reported"
    else
        nope "shim written (or skip not reported) beside a leaf whose CLAUDE.md is not ignored"
    fi
    if [[ "$(cat "$T9_HOST/Source/Plugins/Delta/CLAUDE.md" 2>/dev/null)" == '# team notes' ]] \
        && grep -q 'Source/Plugins/Delta/CLAUDE.md is tracked' <<< "$T9_OUT"; then
        ok "a tracked CLAUDE.md beside a leaf is left as is, and the skip names the fix"
    else
        nope "a tracked CLAUDE.md beside a leaf was overwritten (or the skip was not reported)"
    fi
    if [[ "$(cat "$T9_HOST/Source/Core/src/Epsilon/CLAUDE.md" 2>/dev/null)" == '# my local notes' ]] \
        && grep -q 'Source/Core/src/Epsilon/CLAUDE.md exists' <<< "$T9_OUT"; then
        ok "the user's own untracked CLAUDE.md beside a leaf is left as is"
    else
        nope "the user's own untracked CLAUDE.md beside a leaf was overwritten (or not reported)"
    fi
    if [[ -z "$(git -C "$T9_HOST" status --porcelain 2>/dev/null)" ]]; then
        ok "setup left the host's tracked tree clean (shims are ignored)"
    else
        nope "setup left untracked or modified files in the host: $(git -C "$T9_HOST" status --porcelain | tr '\n' ' ')"
    fi
    if [[ ! -L "$T9_HOST/.claude/skills/zz-removed-skill" && ! -L "$T9_HOST/.claude/workflows/zz-removed.js" ]]; then
        ok "dangling layer skill + workflow links pruned"
    else
        nope "dangling layer skill or workflow link left behind"
    fi
    if [[ -L "$T9_HOST/.claude/skills/zz-user-link" && -f "$T9_HOST/.claude/skills/zz-user-skill/SKILL.md" \
        && -e "$T9_HOST/.claude/skills/perf-measure/SKILL.md" ]]; then
        ok "a user's own link (even dangling), a user skill dir and live layer links survive the prune"
    else
        nope "prune removed a user-owned link or dir, or a live layer skill link"
    fi
fi
rm -rf "$T9_HOST"
trap _restore_harness_snapshot EXIT

# -------------------------------------------------------------------- Report
echo
# test-all.sh aggregator parses the literal "Passed: N  Failed: M" line.
echo "Passed: $PASS  Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
    echo
    echo "setup-harness failures:"
    for msg in "${FAILURES[@]}"; do echo "  - $msg"; done
    exit 1
fi
exit 0
