#!/usr/bin/env bash
# agent-state hooks: a lane's deliberate final state survives the idle
# notification and the Stop hook, and a Monitor-backed turn end parks the lane
# on RUNNING:monitor. Runs the real hook scripts against a fake lane worktree;
# no Claude, no tmux.
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

lane="$TEST_TMP/repo/.claude/worktrees/some-lane"
mkdir -p "$lane/.claude"
export CLAUDE_PROJECT_DIR="$lane"
export HOME="$TEST_TMP/home"
mkdir -p "$HOME/.claude/hooks"
ln -s "$REPO_DIR/hooks/_state-write.sh" "$HOME/.claude/hooks/_state-write.sh"
ln -s "$REPO_DIR/share/lane-windows.sh" "$HOME/.claude/lane-windows.sh"

run_hook() {
  local hook=$1 payload=${2:-'{}'}
  printf '%s' "$payload" | bash "$REPO_DIR/hooks/$hook" >/dev/null 2>&1
}
state() { head -n1 "$lane/.claude/agent-state"; }
set_state() { printf '%s\n' "$1" > "$lane/.claude/agent-state"; }

# --- final states survive ----------------------------------------------------

for final in 'DONE' 'HANDOFF:/tmp/doc.md' 'WAITING:review:PR #12 pending' 'WAITING:holland:PR #12 answered'; do
  set_state "$final"
  run_hook agent-state-waiting.sh '{"notification_type":"idle_prompt"}'
  assert_eq "idle notification keeps $final" "$(state)" "$final"
  run_hook agent-state-idle.sh
  assert_eq "stop keeps $final" "$(state)" "$final"
done

set_state 'RUNNING:monitor'
run_hook agent-state-waiting.sh '{"notification_type":"idle_prompt"}'
assert_eq "idle notification keeps a parked monitor" "$(state)" "RUNNING:monitor"

# --- precheck never replaces a final state -----------------------------------

printf '#!/usr/bin/env bash\nexit 0\n' > "$lane/.claude/precheck.sh"
chmod +x "$lane/.claude/precheck.sh"
for final in 'DONE' 'RUNNING:monitor' 'WAITING:human:PR #12'; do
  set_state "$final"
  run_hook precheck-stop.sh
  assert_eq "precheck keeps $final" "$(state)" "$final"
done
rm -f "$lane/.claude/precheck.sh"

# --- untagged stops ------------------------------------------------------------

set_state 'IDLE'
run_hook agent-state-waiting.sh '{"notification_type":"idle_prompt"}'
assert_eq "untagged idle names the breach" "$(state)" "WAITING:input:stopped without a pause code"

set_state 'ACTIVE:Bash'
run_hook agent-state-waiting.sh '{"notification_type":"auth_success"}'
assert_eq "auth_success is not a pause" "$(state)" "ACTIVE:Bash"

set_state 'ACTIVE:Bash'
run_hook agent-state-waiting.sh '{"notification_type":"permission_prompt"}'
assert_eq "permission prompt pauses" "$(state)" "WAITING:input:permission_prompt"

# --- Monitor marker ------------------------------------------------------------

set_state 'ACTIVE:Bash'
run_hook agent-state-active.sh '{"tool_name":"Monitor"}'
assert_eq "monitor call leaves a marker" "$([[ -e "$lane/.claude/monitor-pending" ]] && echo yes || echo no)" "yes"
run_hook agent-state-active.sh '{"tool_name":"Bash"}'
assert_eq "a later tool call keeps the marker" "$([[ -e "$lane/.claude/monitor-pending" ]] && echo yes || echo no)" "yes"
run_hook agent-state-idle.sh
assert_eq "turn end with a monitor pending parks the lane" "$(state)" "RUNNING:monitor"
assert_eq "stop consumes the marker" "$([[ -e "$lane/.claude/monitor-pending" ]] && echo yes || echo no)" "no"
run_hook agent-state-idle.sh
assert_eq "next turn end without a monitor is idle" "$(state)" "IDLE"

cockpit="$TEST_TMP/plain-repo"
mkdir -p "$cockpit"
CLAUDE_PROJECT_DIR="$cockpit" run_hook agent-state-active.sh '{"tool_name":"Monitor"}'
assert_eq "cockpit repos get no marker" "$([[ -e "$cockpit/.claude/monitor-pending" ]] && echo yes || echo no)" "no"

finish
