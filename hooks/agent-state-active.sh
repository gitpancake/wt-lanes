#!/usr/bin/env bash
# UserPromptSubmit + PreToolUse hook: agent currently working.
# State machine:
#   UserPromptSubmit → ACTIVE:thinking
#   PreToolUse       → ACTIVE:<tool-name>
#   Notification     → WAITING:<msg>   (agent-state-waiting.sh)
#   Stop             → IDLE, or RUNNING:monitor when a Monitor is still pending,
#                      then maybe DONE/FAILED via precheck-stop.sh
#
# A Monitor call leaves <lane>/.claude/monitor-pending behind: the turn will
# end while the monitor still runs, and the Stop hook reads the marker to park
# the lane on RUNNING:monitor (busy, unpainted) instead of IDLE (which the idle
# notification would turn into a red WAITING:input). The Stop hook consumes it.

set -u

source "$HOME/.claude/hooks/_state-write.sh"

input=$(cat 2>/dev/null || true)
context=$(printf '%s' "$input" | jq -r '.tool_name // "thinking"' 2>/dev/null || echo "thinking")
short=$(printf '%s' "$context" | tr -d '\n' | cut -c1-14)

dir="${CLAUDE_PROJECT_DIR:-$PWD}"
if [[ "$context" == "Monitor" && "$dir" == */.claude/worktrees/* ]]; then
  mkdir -p "$dir/.claude"
  : > "$dir/.claude/monitor-pending"
fi

write_state "ACTIVE:$short"
exit 0
