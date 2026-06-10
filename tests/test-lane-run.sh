#!/usr/bin/env bash
# lane-run.sh: respawn on HANDOFF state, terminal-state exit, respawn cap.
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

LANE_RUN="$REPO_DIR/scripts/lane-run.sh"

# Under .claude/worktrees/ so _state-write.sh (used by lane-pause at the
# respawn cap) routes the WAITING write to the lane's agent-state.
wt="$TEST_TMP/repo/.claude/worktrees/lane"
mkdir -p "$wt/.claude"
calls="$TEST_TMP/calls"
doc="$TEST_TMP/handoff.md"
printf 'handoff doc\n' > "$doc"

# Fake agent: logs each invocation's prompt, sets the state scripted for that
# call number in $TEST_TMP/state.<n> (default DONE).
agent="$TEST_TMP/agent.sh"
cat > "$agent" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$calls"
n=\$(wc -l < "$calls" | tr -d ' ')
next="$TEST_TMP/state.\$n"
if [[ -f "\$next" ]]; then cp "\$next" "$wt/.claude/agent-state"
else echo "DONE" > "$wt/.claude/agent-state"; fi
EOF
chmod +x "$agent"

template='resume {N}/{MAX} doc={DOC}'

# 1) first session hands off, second finishes -> exactly two invocations,
#    second prompted from the template with the doc substituted.
printf 'HANDOFF:%s\n' "$doc" > "$TEST_TMP/state.1"
"$LANE_RUN" "$wt" "$agent" "kickoff" "$template" >/dev/null
assert_eq "respawned once then stopped" "$(wc -l < "$calls" | tr -d ' ')" "2"
assert_contains "resume prompt substituted" "$(tail -n1 "$calls")" "resume 1/3 doc=$doc"
assert_eq "final state DONE" "$(cat "$wt/.claude/agent-state")" "DONE"

# 2) terminal pause state -> no respawn.
rm -f "$calls" "$TEST_TMP"/state.*
printf 'WAITING:review:PR pending\n' > "$TEST_TMP/state.1"
"$LANE_RUN" "$wt" "$agent" "kickoff" "$template" >/dev/null
assert_eq "no respawn on WAITING" "$(wc -l < "$calls" | tr -d ' ')" "1"

# 3) empty resume template (Pi lanes) -> no respawn even on HANDOFF.
rm -f "$calls" "$TEST_TMP"/state.*
printf 'HANDOFF:%s\n' "$doc" > "$TEST_TMP/state.1"
"$LANE_RUN" "$wt" "$agent" "kickoff" "" >/dev/null
assert_eq "no respawn without template" "$(wc -l < "$calls" | tr -d ' ')" "1"

# 4) agent that hands off every time -> capped, lane re-tagged WAITING:input.
#    lane-pause.sh resolves vocab via ~/.claude/state-codes.sh; point HOME at
#    a sandbox with the repo's copy + a stub lane-pause call path.
rm -f "$calls" "$TEST_TMP"/state.*
sandbox_home="$TEST_TMP/home"
mkdir -p "$sandbox_home/.claude/scripts" "$sandbox_home/.claude/hooks"
cp "$REPO_DIR/share/state-codes.sh" "$sandbox_home/.claude/state-codes.sh"
cp "$REPO_DIR/scripts/lane-pause.sh" "$sandbox_home/.claude/scripts/lane-pause.sh"
cp "$REPO_DIR/hooks/_state-write.sh" "$sandbox_home/.claude/hooks/_state-write.sh"
for n in 1 2 3 4; do printf 'HANDOFF:%s\n' "$doc" > "$TEST_TMP/state.$n"; done
HOME="$sandbox_home" WT_MAX_RESPAWNS=3 CLAUDE_PROJECT_DIR="$wt" \
  "$LANE_RUN" "$wt" "$agent" "kickoff" "$template" >/dev/null
assert_eq "cap: kickoff + 3 respawns" "$(wc -l < "$calls" | tr -d ' ')" "4"
assert_contains "cap re-tags WAITING:input" "$(cat "$wt/.claude/agent-state")" "WAITING:input:handoff respawn cap"

finish
