#!/usr/bin/env bash
# lane-watch — live monitor pane for a worktree lane.
#
# Usage:
#   lane-watch <worktree-path>            # poll forever
#   lane-watch <worktree-path> --once     # render one frame, exit
#
# Renders agent-state + ctx tokens + recent commits + git status.
#
# Auto-spawned alongside every wt lane (split-pane). See
# ~/.dotfiles/claude/CLAUDE.md "Lane observability".

set -u

wt="${1:?usage: lane-watch <worktree-path> [--once]}"
mode="${2:-loop}"

[[ -d "$wt" ]] || { echo "lane-watch: not a directory: $wt" >&2; exit 1; }

slug=$(basename "$wt")
notify() {
  local msg=$1
  if command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier -title "lane: $slug" -message "$msg" >/dev/null 2>&1 || true
  elif command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$msg\" with title \"lane: $slug\"" >/dev/null 2>&1 || true
  fi
}

# Ctx tokens from newest jsonl session for this worktree.
ctx_tokens() {
  local enc=${wt//\//-}
  enc=${enc//./-}
  local sess_dir="$HOME/.claude/projects/$enc"
  local latest
  latest=$(ls -t "$sess_dir"/*.jsonl 2>/dev/null | head -n1)
  [[ -n "$latest" && -f "$latest" ]] || { printf ''; return; }
  tail -r "$latest" 2>/dev/null | grep -m1 '"usage"' | python3 -c '
import json,sys
try:
  d=json.loads(sys.stdin.read())
  u=(d.get("message") or {}).get("usage") or {}
  print((u.get("input_tokens") or 0)+(u.get("cache_read_input_tokens") or 0)+(u.get("cache_creation_input_tokens") or 0))
except Exception:
  print("")
' 2>/dev/null
}

fmt_ctx() {
  local n=${1:-0}
  [[ -z "$n" || "$n" == 0 ]] && { printf '—'; return; }
  if   (( n < 1000 ));    then printf '%d' "$n"
  elif (( n < 1000000 )); then printf '%dK' $((n/1000))
  else
    local tenths=$((n/100000))
    printf '%d.%dM' $((tenths/10)) $((tenths%10))
  fi
}

render_lane() {
  printf '\033[1mlane — %s\033[0m\n' "$slug"
  printf '\033[2m%s\033[0m\n\n' "$wt"

  local state
  state=$(tail -n1 "$wt/.claude/agent-state" 2>/dev/null || echo "—")
  local ctx
  ctx=$(fmt_ctx "$(ctx_tokens)")
  local branch
  branch=$(git -C "$wt" branch --show-current 2>/dev/null || echo "?")

  printf 'STATE:  %s\n' "$state"
  printf 'CTX:    %s\n' "$ctx"
  printf 'BRANCH: %s\n\n' "$branch"

  printf '\033[2m--- last 5 commits ---\033[0m\n'
  git -C "$wt" log --oneline -n 5 2>/dev/null || echo "(no commits)"

  echo
  printf '\033[2m--- git status (short) ---\033[0m\n'
  git -C "$wt" status -s 2>/dev/null | head -n 10 || echo "(clean)"
}

render_once() {
  clear
  render_lane
}

if [[ "$mode" == "--once" ]]; then
  render_once
  exit 0
fi

last_state=""
while true; do
  render_once

  cur_state=$(tail -n1 "$wt/.claude/agent-state" 2>/dev/null || echo "")
  if [[ "$cur_state" =~ ^WAITING ]] && [[ "$cur_state" != "$last_state" ]]; then
    notify "$cur_state"
  fi
  last_state=$cur_state

  sleep 10
done
