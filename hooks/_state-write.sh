#!/usr/bin/env bash
# Shared helper: source-and-call from every state-writing hook.
#
# Routing by cwd:
#   Lane (under .claude/worktrees/): writes <lane>/.claude/agent-state,
#   refreshes <lane>/.claude/agent-pid with the parent Claude pid (the board
#   uses it to detect orphans), and a per-pid state in <lane>/.claude/sessions/.
#
#   Cockpit (anywhere else): the repo is left untouched — the per-pid state
#   goes to ~/.claude/wt-sessions/<pid>, where the board's COCKPIT section
#   reads it. Stops every Claude session from churning .claude/agent-state +
#   sessions/ files into every repo you work in.
#
# All writes are atomic (tmp + mv): state files have multiple writers (hooks,
# precheck worker, lane-done, the board's stale reap) and readers tail them on
# a 2s tick.
#
# Usage in a hook:
#   source "$HOME/.claude/hooks/_state-write.sh"
#   write_state "ACTIVE:Bash"

WT_SESSIONS_DIR="$HOME/.claude/wt-sessions"

# Tab painting rides along with the write so a lane's tmux tab turns red the
# moment it blocks on you. Sourced, not spawned: an unchanged state class
# returns before tmux is forked, so the per-tool-call path stays fork-free.
# Guarded — an older install without lane-windows.sh must still write state.
if [[ -f "$HOME/.claude/lane-windows.sh" ]]; then
  source "$HOME/.claude/lane-windows.sh"
fi

_atomic_write() {
  local path=$1 content=$2 tmp="$1.tmp.$$"
  printf '%s\n' "$content" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp"
}

# Walk up to find the parent claude process. Hook script's $$ is bash; one or
# two parents up is claude. Cap depth so we don't loop forever on weird trees.
_find_claude_pid() {
  local pid=$$ comm i
  for i in 1 2 3 4 5; do
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -z "$pid" || "$pid" == "1" ]] && return 1
    comm=$(ps -o comm= -p "$pid" 2>/dev/null)
    [[ "$comm" == *claude* ]] && { printf '%s' "$pid"; return 0; }
  done
  return 1
}

# Drop central state files whose pid is gone (session over, crash, kill).
_prune_dead_sessions() {
  local f pid
  for f in "$WT_SESSIONS_DIR"/*; do
    [[ -f "$f" ]] || continue
    pid=$(basename "$f")
    [[ "$pid" == *[!0-9]* ]] && continue
    kill -0 "$pid" 2>/dev/null || rm -f "$f"
  done
}

write_state() {
  local state=$1
  local dir="${CLAUDE_PROJECT_DIR:-$PWD}"
  [[ -z "$dir" ]] && return 0

  local claude_pid
  claude_pid=$(_find_claude_pid) || claude_pid=""

  if [[ "$dir" == */.claude/worktrees/* ]]; then
    mkdir -p "$dir/.claude"
    _atomic_write "$dir/.claude/agent-state" "$state"
    if [[ -n "$claude_pid" ]]; then
      _atomic_write "$dir/.claude/agent-pid" "$claude_pid"
      mkdir -p "$dir/.claude/sessions"
      _atomic_write "$dir/.claude/sessions/$claude_pid" "$state"
    else
      # Couldn't find claude in the tree — clear stale pid so the board
      # doesn't trust it.
      rm -f "$dir/.claude/agent-pid"
    fi
    type lane_paint_one >/dev/null 2>&1 && lane_paint_one "$dir"
    return 0
  fi

  [[ -n "$claude_pid" ]] || return 0
  mkdir -p "$WT_SESSIONS_DIR"
  _atomic_write "$WT_SESSIONS_DIR/$claude_pid" "$state"
  _prune_dead_sessions
  return 0
}
