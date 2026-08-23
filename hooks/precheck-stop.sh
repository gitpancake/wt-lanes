#!/usr/bin/env bash
# Stop hook: run project-defined precheck if .claude/precheck.sh exists.
#
# Per-project contract: each repo opts in by dropping an executable
# .claude/precheck.sh that exits non-zero on failure. Recommended contents:
#   #!/usr/bin/env bash
#   set -e
#   bun type-check     # fast; fine to run every turn
#   # bun test         # SLOW — do NOT add unless you really want every turn to wait
#
# Behavior:
#   - The check runs in the BACKGROUND so it never blocks an agent turn.
#   - agent-state flips to RUNNING:precheck immediately, then DONE / FAILED
#     when the background job finishes. agent-board picks it up on next refresh.
#   - If a new Stop fires while a precheck is already running, the old one is
#     killed and replaced. Caller never has to wait.
#   - The worker only publishes DONE/FAILED while the state file still reads
#     RUNNING:precheck. If the agent started a new turn meanwhile (state is
#     ACTIVE:* again), the stale result is dropped — the next Stop reruns it.

set -u

dir="${CLAUDE_PROJECT_DIR:-$PWD}"
[[ -z "$dir" ]] && exit 0

# Lane-only: DONE/FAILED are lane state-machine vocab, and the board's
# cockpit rows never read agent-state — running prechecks for cockpit
# sessions burned CPU to write repo litter nothing rendered.
[[ "$dir" == */.claude/worktrees/* ]] || exit 0

script="$dir/.claude/precheck.sh"
[[ -x "$script" ]] || exit 0

mkdir -p "$dir/.claude"

state_file="$dir/.claude/agent-state"
log="$dir/.claude/precheck.log"
pid_file="$dir/.claude/precheck.pid"

# Terminal/tagged states win: a lane that just declared DONE (lane-done.sh),
# HANDOFF:<doc> (lane-handoff.sh — the runner reads it to respawn), or a
# tagged pause (lane-pause.sh) must not have its exit reason replaced by a
# precheck verdict.
case "$(tail -n1 "$state_file" 2>/dev/null || true)" in
  DONE|HANDOFF:*|WAITING:*:*) exit 0 ;;
esac

# Atomic (tmp + mv): the state file has multiple writers + 2s-tick readers.
put_state() {
  local tmp="$state_file.tmp.precheck.$$"
  printf '%s\n' "$1" > "$tmp" && mv -f "$tmp" "$state_file"
  # FAILED must reach the tab bar: a red tab is the whole point of a lane
  # whose typecheck just broke. Spawned rather than sourced — this runs in a
  # detached worker that already paid for a full precheck.
  "$HOME/.claude/scripts/lane-paint.sh" "$dir" 2>/dev/null || true
}

# Kill any previously running precheck for this project.
if [[ -f "$pid_file" ]]; then
  prev=$(cat "$pid_file" 2>/dev/null || true)
  if [[ -n "$prev" ]] && kill -0 "$prev" 2>/dev/null; then
    kill "$prev" 2>/dev/null || true
  fi
fi

put_state "RUNNING:precheck"

# Fully detach the worker. Stop hook returns immediately; no blocking.
(
  finish() {
    # Drop the result if anything else (a new turn's ACTIVE, a WAITING tag)
    # has written the state since we claimed it — never move the machine
    # backwards from a fresher state.
    [[ "$(tail -n1 "$state_file" 2>/dev/null)" == "RUNNING:precheck" ]] || return 0
    put_state "$1"
  }
  if "$script" >"$log" 2>&1; then
    finish "DONE"
  else
    step=$(grep -oE '^(typecheck|test|lint|build)' "$log" 2>/dev/null | head -n1)
    finish "FAILED:${step:-precheck}"
  fi
  rm -f "$pid_file"
) </dev/null >/dev/null 2>&1 &
worker_pid=$!
disown 2>/dev/null || true
echo "$worker_pid" > "$pid_file"

exit 0
