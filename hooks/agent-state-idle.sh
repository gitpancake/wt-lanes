#!/usr/bin/env bash
# Stop hook: agent finished a turn cleanly. Mark IDLE so the board greys it out.
# Sibling: precheck-stop.sh runs after this and may overwrite to DONE / FAILED.

set -u

source "$HOME/.claude/hooks/_state-write.sh"

write_state "IDLE"
exit 0
