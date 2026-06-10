#!/usr/bin/env bash
# Shared helper: source-and-call from every state-writing hook.
#
# Writes <project>/.claude/agent-state and refreshes <project>/.claude/agent-pid
# with the parent Claude process PID (walks up the process tree). The board
# uses agent-pid to detect orphaned lanes.
#
# Usage in a hook:
#   source "$HOME/.claude/hooks/_state-write.sh"
#   write_state "ACTIVE:Bash"

write_state() {
  local state=$1
  local dir="${CLAUDE_PROJECT_DIR:-$PWD}"
  [[ -z "$dir" ]] && return 0

  mkdir -p "$dir/.claude"
  printf '%s\n' "$state" > "$dir/.claude/agent-state"

  # Walk up to find the parent claude process. Hook script's $$ is bash; one or
  # two parents up is claude. Cap depth so we don't loop forever on weird trees.
  local pid=$$ comm
  local i
  for i in 1 2 3 4 5; do
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -z "$pid" || "$pid" == "1" ]] && break
    comm=$(ps -o comm= -p "$pid" 2>/dev/null)
    if [[ "$comm" == *claude* ]]; then
      printf '%s\n' "$pid" > "$dir/.claude/agent-pid"
      mkdir -p "$dir/.claude/sessions"
      printf '%s\n' "$state" > "$dir/.claude/sessions/$pid"
      return 0
    fi
  done

  # Couldn't find claude in the tree — clear stale pid so board doesn't trust it.
  rm -f "$dir/.claude/agent-pid"
  return 0
}
