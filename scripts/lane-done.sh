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

# A lane is done only when its PR's CI is green. The review gate never read CI, so
# "arbiter success" alone marked lanes done on red pr-checks (PR #10460, 2026-11-04).
# LANE_DONE_FORCE=1 skips the check for a repo whose PR has no checks to read.
red_checks=""
if [[ "${LANE_DONE_FORCE:-}" != "1" ]] && command -v gh >/dev/null 2>&1; then
  red_checks=$(cd "$dir" && gh pr view --json statusCheckRollup \
    --jq '[.statusCheckRollup[] | select((.conclusion // .state) | test("^(FAILURE|TIMED_OUT|ERROR)$")) | (.name // .context)] | join(", ")' 2>/dev/null || true)
fi
if [[ -n "$red_checks" ]]; then
  printf 'lane-done.sh: refusing — CI is red on this PR (%s). Fix, push, gate once more; never done on a red sha.\n' "$red_checks" >&2
  exit 1
fi

source "$HOME/.claude/state-codes.sh"
lane_state_write "$dir" DONE
# A finished lane must never respawn off an earlier handoff in this session.
rm -f "$dir/.claude/handoff-doc"

# Pre-ship review telemetry: the protocol caps reviewer rounds at 3. Surface a
# breach where the cockpit reads it (stdout + a sidecar /worker-status picks up).
if [[ -f "$dir/.claude/preship-rounds" ]]; then
  rounds=$(head -n1 "$dir/.claude/preship-rounds" | tr -dc '0-9')
  if [[ -n "$rounds" && "$rounds" -gt 3 ]]; then
    printf 'WARN: pre-ship review ran %s rounds (cap 3) — protocol breach, see lane-protocol §Pre-ship\n' "$rounds"
    printf '%s\n' "$rounds" > "$dir/.claude/preship-rounds.breach"
  fi
fi

# Shared palette, so the steady green a finished lane keeps is the same green
# `lane-paint.sh --all` would repaint it. Guarded — an older install without
# lane-windows.sh must still mark the lane DONE.
green='fg=#1d2021,bg=#a9b665,bold'
if [[ -f "$HOME/.claude/lane-windows.sh" ]]; then
  source "$HOME/.claude/lane-windows.sh"
  green=$(lane_class_style done)
  printf 'done\n' > "$dir/.claude/tmux-paint" 2>/dev/null || true
fi

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
tmux set-option -w -t "$win" @lane_class done 2>/dev/null

(
  i=0
  while [[ $i -lt 6 ]]; do
    tmux set-option -w -t "$win" window-status-style "$green" 2>/dev/null
    sleep 0.35
    tmux set-option -w -t "$win" -u window-status-style 2>/dev/null
    sleep 0.35
    i=$((i + 1))
  done
  if type lane_paint_apply >/dev/null 2>&1; then
    lane_paint_apply "$win" done
  else
    tmux set-option -w -t "$win" window-status-style "$green" 2>/dev/null
  fi
) </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true

printf '\a'
exit 0
