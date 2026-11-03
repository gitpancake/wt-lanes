#!/usr/bin/env bash
# Stop hook: agent finished a turn cleanly. Mark IDLE so the board greys it out.
# Sibling: precheck-stop.sh runs after this and may overwrite to DONE / FAILED.
#
# A turn that ends with a Monitor still pending is parked on RUNNING:monitor
# instead: the lane is on a timer, not stalled, and the Monitor re-invokes it.
# The next turn end without a fresh Monitor call returns it to IDLE.
#
# A deliberate final state survives (state_is_final): clobbering it to IDLE
# erases the lane's exit reason.

set -u

source "$HOME/.claude/hooks/_state-write.sh"

dir="${CLAUDE_PROJECT_DIR:-$PWD}"
existing=$(tail -n1 "$dir/.claude/agent-state" 2>/dev/null || true)

marker="$dir/.claude/monitor-pending"
if [[ -e "$marker" ]]; then
  rm -f "$marker"
  write_state "RUNNING:monitor"
  exit 0
fi

if [[ "$existing" == "RUNNING:monitor" ]]; then
  write_state "IDLE"
  exit 0
fi

state_is_final "$existing" && exit 0

write_state "IDLE"
exit 0
