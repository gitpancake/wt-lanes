#!/usr/bin/env bash
# agent-state hooks: a lane's deliberate final state survives the idle
# notification and the Stop hook. Runs the real hook scripts against a fake
# lane worktree; no Claude, no tmux.
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

lane="$TEST_TMP/repo/.claude/worktrees/some-lane"
mkdir -p "$lane/.claude"
export CLAUDE_PROJECT_DIR="$lane"
export HOME="$TEST_TMP/home"
mkdir -p "$HOME/.claude/hooks"
ln -s "$REPO_DIR/hooks/_state-write.sh" "$HOME/.claude/hooks/_state-write.sh"

run_hook() {
  local hook=$1 payload=${2:-'{}'}
  printf '%s' "$payload" | bash "$REPO_DIR/hooks/$hook" >/dev/null 2>&1
}
state() { head -n1 "$lane/.claude/agent-state"; }

for final in 'DONE' 'HANDOFF:/tmp/doc.md' 'WAITING:review:PR #12 pending'; do
  printf '%s\n' "$final" > "$lane/.claude/agent-state"
  run_hook agent-state-waiting.sh '{"notification_type":"idle_prompt"}'
  assert_eq "idle notification keeps $final" "$(state)" "$final"
  run_hook agent-state-idle.sh
  assert_eq "stop keeps $final" "$(state)" "$final"
done

printf 'IDLE\n' > "$lane/.claude/agent-state"
run_hook agent-state-waiting.sh '{"notification_type":"idle_prompt"}'
assert_eq "untagged idle becomes WAITING:input" "$(state)" "WAITING:input"

printf 'ACTIVE:Bash\n' > "$lane/.claude/agent-state"
run_hook agent-state-waiting.sh '{"notification_type":"auth_success"}'
assert_eq "auth_success is not a pause" "$(state)" "ACTIVE:Bash"

printf 'ACTIVE:Bash\n' > "$lane/.claude/agent-state"
run_hook agent-state-waiting.sh '{"notification_type":"permission_prompt"}'
assert_eq "permission prompt pauses" "$(state)" "WAITING:input"

finish
