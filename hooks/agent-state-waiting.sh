#!/usr/bin/env bash
# Notification hook: agent paused, needs human input.
# Sibling: tmux-bell.sh (visual bell). Both fire on Notification.
#
# If the lane already tagged its pause reason via lane-pause.sh, leave it.
# Otherwise default to WAITING:input — vocab in ~/.claude/agent-state-vocab.md.

set -u

source "$HOME/.claude/hooks/_state-write.sh"

dir="${CLAUDE_PROJECT_DIR:-$PWD}"
existing=$(tail -n1 "$dir/.claude/agent-state" 2>/dev/null || true)

KNOWN='ambiguity|creds|test-loop|merge-conflict|verify|scope|external|review|input'
if [[ "$existing" =~ ^WAITING:($KNOWN): ]]; then
  exit 0
fi

write_state "WAITING:input"
exit 0
