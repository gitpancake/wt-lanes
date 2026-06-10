#!/usr/bin/env bash
# Stop hook: agent finished a turn cleanly. Mark IDLE so the board greys it out.
# Sibling: precheck-stop.sh runs after this and may overwrite to DONE / FAILED.
#
# Terminal/tagged states survive: DONE (lane-done.sh), HANDOFF:<doc>
# (lane-handoff.sh — the runner reads it to respawn), and tagged pauses
# WAITING:<code>:<detail> (lane-pause.sh). All three are deliberate final
# tool calls; clobbering them to IDLE erases the lane's exit reason.

set -u

source "$HOME/.claude/hooks/_state-write.sh"

dir="${CLAUDE_PROJECT_DIR:-$PWD}"
existing=$(tail -n1 "$dir/.claude/agent-state" 2>/dev/null || true)
case "$existing" in
  DONE|HANDOFF:*|WAITING:*:*) exit 0 ;;
esac

write_state "IDLE"
exit 0
