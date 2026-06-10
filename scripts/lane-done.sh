#!/usr/bin/env bash
# Mark the lane finished: agent-state → DONE, lane's tmux window flashes then
# stays green. The lane agent runs this as its FINAL tool call, after the PR's
# review feedback is fully addressed + pushed (or review skipped per repo
# policy). Safe outside tmux — the state write still happens.
#
# Window resolution: $TMUX_PANE (authoritative — the lane agent's own pane),
# falling back to the .claude/tmux-window label wt stamped at spawn.
# macOS bash 3.2 compatible.

set -u

dir="${CLAUDE_PROJECT_DIR:-$PWD}"
mkdir -p "$dir/.claude"
printf 'DONE\n' > "$dir/.claude/agent-state"

[[ -z "${TMUX:-}" ]] && exit 0

win=""
if [[ -n "${TMUX_PANE:-}" ]]; then
  win=$(tmux display-message -t "$TMUX_PANE" -p '#{window_id}' 2>/dev/null || true)
fi
if [[ -z "$win" && -f "$dir/.claude/tmux-window" ]]; then
  label=$(head -n1 "$dir/.claude/tmux-window")
  win=$(tmux list-windows -a -F '#{window_id} #{window_name}' 2>/dev/null \
    | awk -v l="$label" '$2 == l { print $1; exit }')
fi
[[ -z "$win" ]] && exit 0

green='fg=colour232,bg=colour46,bold'
(
  i=0
  while [[ $i -lt 6 ]]; do
    tmux set-option -w -t "$win" window-status-style "$green" 2>/dev/null
    sleep 0.35
    tmux set-option -w -t "$win" -u window-status-style 2>/dev/null
    sleep 0.35
    i=$((i + 1))
  done
  tmux set-option -w -t "$win" window-status-style "$green" 2>/dev/null
) </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true

printf '\a'
exit 0
