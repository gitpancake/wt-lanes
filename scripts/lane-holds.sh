#!/usr/bin/env bash
# lane-holds — blink every held lane's tab, and watch for the person releasing it.
#
# A hold (WAITING:holland|human|prompt-owner) means the PR is complete from the
# lane's side and someone outside the cockpit must release it. The lane has
# stopped, so nothing else is watching that PR. This daemon is the one thing
# that reads GitHub and writes lane state for a held lane:
#
#   gate status success                   -> lane-done.sh    (green)
#   gate status failure with new findings -> WAITING:input   (red, "<gate> posted findings")
#   anything else                         -> keep blinking
#
# Started by lane_paint_apply the moment a hold is painted; exits on its own
# when no tab carries @lane_class=hold. Single instance via ~/.claude/lane-holds.pid.
# The tab is blinked by toggling window-status-style against the default, so
# it keeps asking until the state moves — a visit never clears a hold.
#
# Which commit status releases which code lives here and nowhere else:
#   holland, human -> arbiter             (description starts with needs-holland / needs-human while held)
#   prompt-owner   -> prompt-owner-review (description starts with "awaiting " while held)
#
# Env knobs (tests): LANE_HOLDS_TICK (seconds between blinks, default 0.6),
# LANE_HOLDS_POLL_TICKS (ticks between GitHub polls, default 200 = ~2 min).
# macOS bash 3.2 compatible.

set -u

source "$HOME/.claude/lane-windows.sh"

pid_file="$HOME/.claude/lane-holds.pid"
old_pid=$(cat "$pid_file" 2>/dev/null || printf '')
if [[ -n "$old_pid" && "$old_pid" != "$$" ]] && kill -0 "$old_pid" 2>/dev/null; then
  exit 0
fi
mkdir -p "$(dirname "$pid_file")"
printf '%s\n' "$$" > "$pid_file"
trap 'rm -f "$pid_file"' EXIT

tick=${LANE_HOLDS_TICK:-0.6}
poll_every=${LANE_HOLDS_POLL_TICKS:-200}
hold_style=$(lane_class_style hold)

held_windows() {
  tmux list-windows -a -F '#{window_id} #{@lane_class}' 2>/dev/null | awk '$2 == "hold" { print $1 }'
}

gate_context_for() {
  case "$1" in
    holland|human) printf 'arbiter' ;;
    prompt-owner)  printf 'prompt-owner-review' ;;
    *)             printf '' ;;
  esac
}

held_description_prefix_for() {
  case "$1" in
    holland)      printf 'needs-holland' ;;
    human)        printf 'needs-human' ;;
    prompt-owner) printf 'awaiting ' ;;
  esac
}

notify() {
  osascript -e "display notification \"$2\" with title \"Lane $1\" sound name \"Pop\"" >/dev/null 2>&1 || true
}

write_lane_state() {
  local dir=$1 state=$2 tmp="$1/.claude/agent-state.tmp.holds.$$"
  printf '%s\n' "$state" > "$tmp" && mv -f "$tmp" "$dir/.claude/agent-state"
  "$HOME/.claude/scripts/lane-paint.sh" "$dir" 2>/dev/null || true
}

# <dir> -> "<number>\t<head sha>" for the branch's open PR, or nothing.
lane_pr() {
  local branch
  branch=$(git -C "$1" branch --show-current 2>/dev/null) || return 1
  [[ -n "$branch" ]] || return 1
  (cd "$1" && gh pr list --head "$branch" --state open --json number,headRefOid \
    --jq '.[0] | select(. != null) | "\(.number)\t\(.headRefOid)"' 2>/dev/null)
}

# <dir> <sha> <context> -> "<state>\t<description>" of the newest such status.
gate_status() {
  local repo
  repo=$(cd "$1" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || return 1
  (cd "$1" && gh api "repos/$repo/commits/$2/status" \
    --jq "[.statuses[] | select(.context == \"$3\")][0] | select(. != null) | \"\(.state)\t\(.description)\"" 2>/dev/null)
}

poll_one() {
  local dir=$1 raw code context label pr number sha line state desc prefix
  raw=$(lane_state "$dir")
  [[ "$(lane_class "$raw")" == hold ]] || return 0
  code=$(lane_state_tag "$raw")
  context=$(gate_context_for "$code")
  [[ -n "$context" ]] || return 0
  label=$(head -n1 "$dir/.claude/tmux-window" 2>/dev/null || basename "$dir")
  pr=$(lane_pr "$dir") || return 0
  [[ -n "$pr" ]] || return 0
  number=${pr%%	*}
  sha=${pr#*	}
  line=$(gate_status "$dir" "$sha" "$context") || return 0
  [[ -n "$line" ]] || return 0
  state=${line%%	*}
  desc=${line#*	}
  case "$state" in
    success)
      notify "$label" "PR #$number released by $context — ready to merge"
      CLAUDE_PROJECT_DIR="$dir" TMUX_PANE="" "$HOME/.claude/scripts/lane-done.sh" >/dev/null 2>&1 || true
      ;;
    failure|error)
      prefix=$(held_description_prefix_for "$code")
      case "$desc" in "$prefix"*) return 0 ;; esac
      notify "$label" "PR #$number: $context posted findings"
      write_lane_state "$dir" "WAITING:input:$context posted findings on PR #$number"
      ;;
  esac
}

poll_holds() {
  local wid dir
  for wid in $(held_windows); do
    dir=$(lane_dir_for_window "$wid") || continue
    poll_one "$dir"
  done
}

on=1
n=0
while :; do
  wins=$(held_windows)
  [[ -n "$wins" ]] || exit 0
  for wid in $wins; do
    if (( on )); then
      tmux set-option -w -t "$wid" window-status-style "$hold_style" 2>/dev/null
    else
      tmux set-option -w -t "$wid" -u window-status-style 2>/dev/null
    fi
  done
  on=$(( 1 - on ))
  n=$(( n + 1 ))
  if (( n % poll_every == 0 )); then
    poll_holds
  fi
  sleep "$tick"
done
