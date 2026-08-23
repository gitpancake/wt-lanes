#!/usr/bin/env bash
# lane-paint — colour a lane's tmux tab by its agent-state class.
#
# Usage:
#   lane-paint.sh <lane-worktree>   # paint one lane, skipping unchanged classes
#   lane-paint.sh --all             # resync every live lane tab
#   lane-paint.sh --ack <window_id> # you are on this tab: stop flagging it
#
# Red tab = blocked on you, act now. Yellow = blocked on something external.
# Blue = expected pause (review pending). Green = done. Anything else clears
# back to the default style, so the tab bar only shouts when a lane needs you.
#
# Thin CLI over lane_paint_one / lane_paint_all in ~/.claude/lane-windows.sh,
# which is also sourced directly by the state-write hooks. Colour palette and
# state classification live there.

set -u

source "$HOME/.claude/lane-windows.sh"

case "${1:-}" in
  --all) lane_paint_all ;;
  --ack)
    # Bound to tmux's window-switch hooks, so it runs on every tab change and
    # must cost nothing on the overwhelmingly common non-lane window.
    dir=$(lane_dir_for_window "${2:-}") || exit 0
    lane_paint_ack "$dir"
    ;;
  "")    printf 'usage: lane-paint.sh <lane-worktree> | --all | --ack <window_id>\n' >&2; exit 2 ;;
  *)     lane_paint_one "$1" ;;
esac
exit 0
