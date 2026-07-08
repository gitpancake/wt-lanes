#!/usr/bin/env bash
# lane-handoff.sh: state write, lane-session kill via agent-pid (the runner's
# exit trigger), DONE-wins guard, non-lane / no-pid / stale-pid safety.
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

LANE_HANDOFF="$REPO_DIR/scripts/lane-handoff.sh"

wt="$TEST_TMP/repo/.claude/worktrees/lane"
mkdir -p "$wt/.claude"
doc="$TEST_TMP/handoff.md"
printf 'handoff doc\n' > "$doc"

# A process whose comm matches *claude*: symlink to bash (a COPY of a system
# binary gets Killed:9 by macOS code signing). comm is the exec path, which
# ends in /claude.
fake_claude="$TEST_TMP/claude"
ln -s "$(command -v bash)" "$fake_claude"
spawn_fake() {  # writes its pid to agent-pid, then idles like a REPL
  "$fake_claude" -c "echo \$\$ > '$wt/.claude/agent-pid'; sleep 30; :" &
  fake_pid=$!
  sleep 1  # let it write agent-pid
}

# 1) missing doc -> rc 2, no state write.
out=$(CLAUDE_PROJECT_DIR="$wt" "$LANE_HANDOFF" "$TEST_TMP/nope.md" 2>&1)
rc=$?
assert_rc "missing doc rejected" "$rc" 2
assert_eq "missing doc writes no state" "$(cat "$wt/.claude/agent-state" 2>/dev/null || echo none)" "none"

# 2) non-lane dir -> state set, no sentinel, kill path never engages.
nonlane="$TEST_TMP/repo"
out=$(CLAUDE_PROJECT_DIR="$nonlane" "$LANE_HANDOFF" "$doc" 2>&1)
assert_eq "non-lane state set" "$(cat "$nonlane/.claude/agent-state")" "HANDOFF:$doc"
assert_eq "non-lane writes no sentinel" "$(cat "$nonlane/.claude/handoff-doc" 2>/dev/null || echo none)" "none"
assert_contains "non-lane reported" "$out" "not a lane worktree"

# 3) lane dir, no agent-pid -> state + sentinel set, manual-kill warning,
#    no watcher.
rm -f "$wt/.claude/agent-pid" "$wt/.claude/agent-state"
out=$(CLAUDE_PROJECT_DIR="$wt" "$LANE_HANDOFF" "$doc" 2>&1)
assert_eq "no-pid state set" "$(cat "$wt/.claude/agent-state")" "HANDOFF:$doc"
assert_eq "no-pid sentinel set" "$(cat "$wt/.claude/handoff-doc")" "$doc"
assert_contains "no-pid reported" "$out" "no agent-pid recorded"

# 4) stale agent-pid (dead / not claude) -> state set, warning, no kill.
echo "99999999" > "$wt/.claude/agent-pid"
out=$(CLAUDE_PROJECT_DIR="$wt" "$LANE_HANDOFF" "$doc" 2>&1)
assert_contains "stale pid reported" "$out" "not a live claude"

# 5) live lane session: state set + the agent-pid process is killed after
#    grace, never the caller's own ancestry.
rm -f "$wt/.claude/agent-state"
spawn_fake
out=$(CLAUDE_PROJECT_DIR="$wt" WT_HANDOFF_KILL_GRACE=1 "$LANE_HANDOFF" "$doc" 2>&1)
assert_contains "kill scheduled" "$out" "terminates in ~1s"
dead=no
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  kill -0 "$fake_pid" 2>/dev/null || { dead=yes; break; }
  sleep 1
done
assert_eq "lane session killed after grace" "$dead" "yes"
assert_eq "state survives the kill" "$(cat "$wt/.claude/agent-state")" "HANDOFF:$doc"
assert_eq "sentinel survives the kill" "$(cat "$wt/.claude/handoff-doc")" "$doc"
kill -9 "$fake_pid" 2>/dev/null
wait "$fake_pid" 2>/dev/null

# 5b) the race the sentinel closes: an ACTIVE hook clobbers agent-state after
#     the watcher's re-assert — the sentinel must still be there for lane-run.
rm -f "$wt/.claude/agent-state" "$wt/.claude/handoff-doc"
spawn_fake
CLAUDE_PROJECT_DIR="$wt" WT_HANDOFF_KILL_GRACE=1 "$LANE_HANDOFF" "$doc" >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  kill -0 "$fake_pid" 2>/dev/null || break
  sleep 1
done
printf 'ACTIVE:Bash\n' > "$wt/.claude/agent-state"
assert_eq "sentinel outlives state clobber" "$(cat "$wt/.claude/handoff-doc")" "$doc"
kill -9 "$fake_pid" 2>/dev/null
wait "$fake_pid" 2>/dev/null

# 6) DONE wins: lane declared done before the grace expired -> no kill, and
#    the spent sentinel is dropped so nothing respawns a finished lane.
spawn_fake
CLAUDE_PROJECT_DIR="$wt" WT_HANDOFF_KILL_GRACE=3 "$LANE_HANDOFF" "$doc" >/dev/null 2>&1
printf 'DONE\n' > "$wt/.claude/agent-state"
sleep 5
if kill -0 "$fake_pid" 2>/dev/null; then
  pass "DONE lane not killed"
else
  fail "DONE lane not killed" "pid $fake_pid was terminated"
fi
kill -9 "$fake_pid" 2>/dev/null
wait "$fake_pid" 2>/dev/null
assert_eq "DONE state preserved" "$(cat "$wt/.claude/agent-state")" "DONE"
assert_eq "DONE clears sentinel" "$(cat "$wt/.claude/handoff-doc" 2>/dev/null || echo none)" "none"

finish
