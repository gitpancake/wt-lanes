#!/usr/bin/env bash
# Notification hook: agent paused, needs human input.
#
# A deliberate final state survives: DONE (lane-done.sh), HANDOFF:<doc>
# (lane-handoff.sh), and a tagged pause WAITING:<code>:<detail> (lane-pause.sh).
# Claude Code raises an idle_prompt notification ~60s after any turn ends, so
# without this guard every finished lane turned red a minute after it went
# green. Otherwise default to WAITING:input — vocab in ~/.claude/agent-state-vocab.md.

set -u

source "$HOME/.claude/hooks/_state-write.sh"

input=$(cat 2>/dev/null || true)
kind=$(printf '%s' "$input" | jq -r '.notification_type // empty' 2>/dev/null || true)
[[ "$kind" == "auth_success" ]] && exit 0

dir="${CLAUDE_PROJECT_DIR:-$PWD}"
existing=$(tail -n1 "$dir/.claude/agent-state" 2>/dev/null || true)
case "$existing" in
  DONE|HANDOFF:*|WAITING:*:*) exit 0 ;;
esac

write_state "WAITING:input"
exit 0
