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

# 6) an outage revive launches the runner with `--resume <id>` in agent_cmd.
#    A respawn must drop it, or every "fresh" session reopens the same one.
reset
argv_agent="$TEST_TMP/argv-agent.sh"
argv_calls="$TEST_TMP/argv-calls"
cat > "$argv_agent" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$argv_calls"
exec "$agent" "\${@: -1}"
EOF
chmod +x "$argv_agent"
printf 'HANDOFF:%s\n' "$doc" > "$TEST_TMP/state.1"
printf '%s\n' "$doc" > "$TEST_TMP/sentinel.1"
WT_MAX_RESPAWNS=3 "$LANE_RUN" "$wt" "$argv_agent --resume abc-123 --continue" "kickoff" "$template" >/dev/null
assert_contains "first spawn keeps --resume" "$(sed -n 1p "$argv_calls")" "--resume abc-123"
assert_eq "respawn drops --resume/--continue" "$(sed -n '$p' "$argv_calls")" "resume 1/3 doc=$doc"

# ---- external kills: the agent dies, the lane does not ----------------------
# A claude-named fake: logs its full argv, sets the state scripted in
# $TEST_TMP/cstate.<n> (default ACTIVE:Bash), sleeps $TEST_TMP/csleep seconds
# if present, and exits with the code in $TEST_TMP/crc.<n> (default 0).
mkdir -p "$TEST_TMP/bin"
cfake="$TEST_TMP/bin/claude-fake"
ccalls="$TEST_TMP/ccalls"
cat > "$cfake" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$ccalls"
n=\$(wc -l < "$ccalls" | tr -d ' ')
if [[ -f "$TEST_TMP/cstate.\$n" ]]; then cp "$TEST_TMP/cstate.\$n" "$wt/.claude/agent-state"
else echo "ACTIVE:Bash" > "$wt/.claude/agent-state"; fi
[[ -f "$TEST_TMP/csleep" ]] && sleep "\$(cat "$TEST_TMP/csleep")"
[[ -f "$TEST_TMP/crc.\$n" ]] && exit "\$(cat "$TEST_TMP/crc.\$n")"
exit 0
EOF
chmod +x "$cfake"
creset() { reset; rm -f "$ccalls" "$TEST_TMP"/cstate.* "$TEST_TMP"/crc.* "$TEST_TMP/csleep"; }
sid_of() { sed -nE "s/.*--session-id ([^ ]+).*/\1/p" <<<"$1"; }

# 7) killed mid-work (143, no sentinel) -> revived once on the SAME session:
#    the first launch minted a --session-id, the revive passes it as --resume
#    with the in-place prompt; a clean exit then ends the runner.
creset
printf '143\n' > "$TEST_TMP/crc.1"
"$LANE_RUN" "$wt" "$cfake" "kickoff" "$template" >/dev/null 2>&1
assert_eq "revive: launched twice" "$(wc -l < "$ccalls" | tr -d ' ')" "2"
first_sid=$(sid_of "$(sed -n 1p "$ccalls")")
assert_contains "revive: first launch minted a session id" "$(sed -n 1p "$ccalls")" "--session-id "
assert_contains "revive: resumes the minted session" "$(sed -n 2p "$ccalls")" "--resume $first_sid"
assert_contains "revive: in-place prompt" "$(sed -n 2p "$ccalls")" "resumed IN PLACE"
assert_eq "revive: no --session-id on the resume" "$(sed -n 2p "$ccalls" | grep -c -- '--session-id')" "0"

# 8) Ctrl-C (130) and a clean 0 are a person quitting -> no revive.
creset
printf '130\n' > "$TEST_TMP/crc.1"
"$LANE_RUN" "$wt" "$cfake" "kickoff" "$template" >/dev/null 2>&1
assert_eq "no revive on 130" "$(wc -l < "$ccalls" | tr -d ' ')" "1"

# 9) a DONE lane whose idle session gets killed has nothing to resume.
creset
printf 'DONE\n' > "$TEST_TMP/cstate.1"
printf '143\n' > "$TEST_TMP/crc.1"
"$LANE_RUN" "$wt" "$cfake" "kickoff" "$template" >/dev/null 2>&1
assert_eq "no revive when DONE" "$(wc -l < "$ccalls" | tr -d ' ')" "1"

# 10) crash loop -> capped at WT_MAX_REVIVES, lane re-tagged WAITING:input
#     naming the session to resume by hand.
creset
for n in 1 2 3 4; do printf '1\n' > "$TEST_TMP/crc.$n"; done
HOME="$sandbox_home" WT_MAX_REVIVES=3 CLAUDE_PROJECT_DIR="$wt" \
  "$LANE_RUN" "$wt" "$cfake" "kickoff" "$template" >/dev/null 2>&1
assert_eq "revive cap: kickoff + 3 revives" "$(wc -l < "$ccalls" | tr -d ' ')" "4"
assert_contains "revive cap re-tags WAITING:input" "$(cat "$wt/.claude/agent-state")" "WAITING:input:agent exited 1 after 3 in-place revives"

# 11) a runner launched with --resume <id> (outage revive) adopts that id:
#     no --session-id is minted, and a crash resumes the same id once.
creset
printf '143\n' > "$TEST_TMP/crc.1"
"$LANE_RUN" "$wt" "$cfake --resume abc-123" "kickoff" "$template" >/dev/null 2>&1
assert_eq "adopt: first launch keeps the given --resume" "$(sed -n 1p "$ccalls")" "--resume abc-123 kickoff"
assert_contains "adopt: crash resumes the same id" "$(sed -n 2p "$ccalls")" "--resume abc-123 Autonomous mode, resumed IN PLACE"
assert_eq "adopt: --resume appears once" "$(sed -n 2p "$ccalls" | grep -o -- '--resume' | wc -l | tr -d ' ')" "1"

# 12) SIGTERM at the runner (pkill -f matching its argv) is not fatal: the
#     agent runs to its own exit and the runner finishes normally.
creset
printf '2\n' > "$TEST_TMP/csleep"
"$LANE_RUN" "$wt" "$cfake" "kickoff" "$template" >/dev/null 2>&1 &
runner_pid=$!
sleep 0.5
kill -TERM "$runner_pid"
wait "$runner_pid"; runner_rc=$?
assert_rc "runner survives SIGTERM" "$runner_rc" 0
assert_eq "agent ran once through the SIGTERM" "$(wc -l < "$ccalls" | tr -d ' ')" "1"

# 13) a handoff respawn mints a fresh session id (never the one that handed
#     off) and resets the revive budget.
creset
printf 'HANDOFF:%s\n' "$doc" > "$TEST_TMP/cstate.1"
printf '%s\n' "$doc" > "$TEST_TMP/sentinel.1"
cfake_handoff="$TEST_TMP/bin/claude-handoff"
cat > "$cfake_handoff" <<EOF
#!/usr/bin/env bash
n=\$(( \$(wc -l < "$ccalls" 2>/dev/null | tr -d ' ') + 1 ))
[[ -f "$TEST_TMP/sentinel.\$n" ]] && cp "$TEST_TMP/sentinel.\$n" "$wt/.claude/handoff-doc"
exec "$cfake" "\$@"
EOF
chmod +x "$cfake_handoff"
printf '143\n' > "$TEST_TMP/crc.2"
WT_MAX_RESPAWNS=3 "$LANE_RUN" "$wt" "$cfake_handoff" "kickoff" "$template" >/dev/null 2>&1
assert_eq "handoff then kill: three launches" "$(wc -l < "$ccalls" | tr -d ' ')" "3"
sid1=$(sid_of "$(sed -n 1p "$ccalls")"); sid2=$(sid_of "$(sed -n 2p "$ccalls")")
[[ -n "$sid1" && -n "$sid2" && "$sid1" != "$sid2" ]] && pass "handoff respawn mints a new session id" || fail "handoff respawn mints a new session id" "sid1=$sid1 sid2=$sid2"
assert_contains "kill after handoff resumes the NEW session" "$(sed -n 3p "$ccalls")" "--resume $sid2"

finish
