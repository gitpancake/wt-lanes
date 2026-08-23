#!/usr/bin/env bash
# lane-run.sh: respawn on the handoff-doc sentinel, terminal-state exit,
# respawn cap, immunity to agent-state clobbers.
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
# call number in $TEST_TMP/state.<n> (default DONE), and — mimicking
# lane-handoff.sh — drops the respawn sentinel when $TEST_TMP/sentinel.<n>
# exists.
agent="$TEST_TMP/agent.sh"
cat > "$agent" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$calls"
n=\$(wc -l < "$calls" | tr -d ' ')
next="$TEST_TMP/state.\$n"
if [[ -f "\$next" ]]; then cp "\$next" "$wt/.claude/agent-state"
else echo "DONE" > "$wt/.claude/agent-state"; fi
sent="$TEST_TMP/sentinel.\$n"
if [[ -f "\$sent" ]]; then cp "\$sent" "$wt/.claude/handoff-doc"; fi
EOF
chmod +x "$agent"

reset() { rm -f "$calls" "$TEST_TMP"/state.* "$TEST_TMP"/sentinel.* "$wt/.claude/handoff-doc"; }

template='resume {N}/{MAX} doc={DOC}'

# 1) first session hands off, second finishes -> exactly two invocations,
#    second prompted from the template with the doc substituted, sentinel
#    consumed by the respawn.
printf 'HANDOFF:%s\n' "$doc" > "$TEST_TMP/state.1"
printf '%s\n' "$doc" > "$TEST_TMP/sentinel.1"
WT_MAX_RESPAWNS=3 "$LANE_RUN" "$wt" "$agent" "kickoff" "$template" >/dev/null
assert_eq "respawned once then stopped" "$(wc -l < "$calls" | tr -d ' ')" "2"
assert_contains "resume prompt substituted" "$(tail -n1 "$calls")" "resume 1/3 doc=$doc"
assert_eq "final state DONE" "$(cat "$wt/.claude/agent-state")" "DONE"
assert_eq "sentinel consumed" "$(cat "$wt/.claude/handoff-doc" 2>/dev/null || echo none)" "none"

# 2) terminal pause state, no sentinel -> no respawn.
reset
printf 'WAITING:review:PR pending\n' > "$TEST_TMP/state.1"
WT_MAX_RESPAWNS=3 "$LANE_RUN" "$wt" "$agent" "kickoff" "$template" >/dev/null
assert_eq "no respawn on WAITING" "$(wc -l < "$calls" | tr -d ' ')" "1"

# 3) empty resume template (Pi lanes) -> no respawn even with a sentinel.
reset
printf 'HANDOFF:%s\n' "$doc" > "$TEST_TMP/state.1"
printf '%s\n' "$doc" > "$TEST_TMP/sentinel.1"
"$LANE_RUN" "$wt" "$agent" "kickoff" "" >/dev/null
assert_eq "no respawn without template" "$(wc -l < "$calls" | tr -d ' ')" "1"

# 4) the race lane-run must survive: an in-flight ACTIVE hook clobbered the
#    HANDOFF state after lane-handoff's kill landed. Sentinel present ->
#    respawn anyway (pre-sentinel, this exited and closed the tmux window).
reset
printf 'ACTIVE:Bash\n' > "$TEST_TMP/state.1"
printf '%s\n' "$doc" > "$TEST_TMP/sentinel.1"
WT_MAX_RESPAWNS=3 "$LANE_RUN" "$wt" "$agent" "kickoff" "$template" >/dev/null
assert_eq "respawn despite clobbered state" "$(wc -l < "$calls" | tr -d ' ')" "2"
assert_contains "clobbered-state resume prompt" "$(tail -n1 "$calls")" "resume 1/3 doc=$doc"

# 5) agent that hands off every time -> capped, lane re-tagged WAITING:input,
#    spent sentinel removed so a manual runner restart can't insta-respawn.
#    lane-pause.sh resolves vocab via ~/.claude/state-codes.sh; point HOME at
#    a sandbox with the repo's copy + a stub lane-pause call path.
reset
sandbox_home="$TEST_TMP/home"
mkdir -p "$sandbox_home/.claude/scripts" "$sandbox_home/.claude/hooks"
cp "$REPO_DIR/share/state-codes.sh" "$sandbox_home/.claude/state-codes.sh"
cp "$REPO_DIR/scripts/lane-pause.sh" "$sandbox_home/.claude/scripts/lane-pause.sh"
cp "$REPO_DIR/hooks/_state-write.sh" "$sandbox_home/.claude/hooks/_state-write.sh"
for n in 1 2 3 4; do
  printf 'HANDOFF:%s\n' "$doc" > "$TEST_TMP/state.$n"
  printf '%s\n' "$doc" > "$TEST_TMP/sentinel.$n"
done
HOME="$sandbox_home" WT_MAX_RESPAWNS=3 CLAUDE_PROJECT_DIR="$wt" \
  "$LANE_RUN" "$wt" "$agent" "kickoff" "$template" >/dev/null
assert_eq "cap: kickoff + 3 respawns" "$(wc -l < "$calls" | tr -d ' ')" "4"
assert_contains "cap re-tags WAITING:input" "$(cat "$wt/.claude/agent-state")" "WAITING:input:handoff respawn cap"
assert_eq "cap clears sentinel" "$(cat "$wt/.claude/handoff-doc" 2>/dev/null || echo none)" "none"

finish
