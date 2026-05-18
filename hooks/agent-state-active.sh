#!/usr/bin/env bash
# UserPromptSubmit + PreToolUse hook: agent currently working.
# State machine:
#   UserPromptSubmit → ACTIVE:thinking
#   PreToolUse       → ACTIVE:<tool-name>
#   Notification     → WAITING:<msg>   (agent-state-waiting.sh)
#   Stop             → IDLE → maybe DONE/FAILED via precheck-stop.sh

set -u

source "$HOME/.claude/hooks/_state-write.sh"

input=$(cat 2>/dev/null || true)
context=$(printf '%s' "$input" | jq -r '.tool_name // "thinking"' 2>/dev/null || echo "thinking")
short=$(printf '%s' "$context" | tr -d '\n' | cut -c1-14)

write_state "ACTIVE:$short"
exit 0
