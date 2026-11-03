#!/usr/bin/env bash
# Notification hook: agent paused, needs human input.
#
# A deliberate final state survives (state_is_final): DONE, HANDOFF:<doc>, a
# tagged pause, or a turn parked on a Monitor. Claude Code raises an
# idle_prompt notification ~60s after any turn ends, so without this guard
# every finished lane turned red a minute after it went green.
#
# Otherwise the lane stopped without saying why — a protocol breach — and the
# tab goes red with that as the detail, so the jump menu says so.

set -u

source "$HOME/.claude/hooks/_state-write.sh"

input=$(cat 2>/dev/null || true)
kind=$(printf '%s' "$input" | jq -r '.notification_type // empty' 2>/dev/null || true)
[[ "$kind" == "auth_success" ]] && exit 0

dir="${CLAUDE_PROJECT_DIR:-$PWD}"
existing=$(tail -n1 "$dir/.claude/agent-state" 2>/dev/null || true)
state_is_final "$existing" && exit 0

case "$kind" in
  permission_prompt|elicitation_dialog) write_state "WAITING:input:$kind" ;;
  *) write_state "WAITING:input:stopped without a pause code" ;;
esac
exit 0
