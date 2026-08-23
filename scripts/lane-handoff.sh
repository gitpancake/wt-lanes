#!/usr/bin/env bash
# Mark the lane handed off: agent-state → HANDOFF:<doc-path> (board display)
# and .claude/handoff-doc → <doc-path> (the respawn contract). The lane agent
# runs this as its FINAL tool call, right after /handoff writes the doc, when
# context forces a session swap mid-brief. lane-run.sh (the lane runner) sees
# the sentinel when the agent process exits and respawns a fresh session that
# /resumes the doc — this script is what makes "the next session resumes"
# true instead of aspirational.
#
# An interactive claude session never exits on its own — after the final
# message it sits at the REPL prompt, so lane-run.sh would block in its eval
# forever and the HANDOFF state would never be read (this stranded the first
# real handoff, 2026-06-10). So this script also schedules the session's
# death: a detached watcher waits WT_HANDOFF_KILL_GRACE seconds (default 20,
# enough for the agent's final message), re-asserts the HANDOFF state in case
# a stray hook overwrote it, then TERMs (and if needed KILLs) the lane's
# claude. The runner's eval returns, reads HANDOFF, respawns.
#
# Kill target is the pid in <lane>/.claude/agent-pid (refreshed by every
# state hook) — NEVER a parent-process walk: a manual cockpit invocation
# walks to the COCKPIT's claude and kills the wrong session (it did,
# 2026-06-10). Cockpit pids never land in agent-pid, so this can only ever
# hit the lane's own session.
#
# Usage: lane-handoff.sh <handoff-doc-path>
# macOS bash 3.2 compatible.

set -u

doc="${1:-}"
if [[ -z "$doc" ]]; then
  printf 'usage: lane-handoff.sh <handoff-doc-path>\n' >&2
  exit 2
fi

# Absolute path — the runner resumes from the worktree root, the agent may
# have written the doc relative to a deeper cwd.
case "$doc" in
  /*) ;;
  *) doc="$PWD/$doc" ;;
esac

if [[ ! -f "$doc" ]]; then
  printf 'lane-handoff: handoff doc not found: %s\n' "$doc" >&2
  printf 'run /handoff first, then pass the doc it wrote.\n' >&2
  exit 2
fi

# Auto-prune spent handoffs: nothing else ever deletes them (the /handoff
# skill, /resume, and this runner only write/read), so the dir grew unbounded
# (331 docs back to May). A lane consumes its handoff within minutes of the
# respawn, so anything older than the window is provably spent — and the doc
# we just handed off is far younger than the window, so this never eats it.
find "$HOME/.claude/handoffs" -maxdepth 1 -name '*.md' -mtime +"${HANDOFF_RETENTION_DAYS:-14}" -delete 2>/dev/null || true

dir="${CLAUDE_PROJECT_DIR:-$PWD}"
mkdir -p "$dir/.claude"
state_file="$dir/.claude/agent-state"
# Atomic (tmp + mv): the state file has multiple writers + 2s-tick readers.
tmp="$state_file.tmp.$$"
printf 'HANDOFF:%s\n' "$doc" > "$tmp" && mv -f "$tmp" "$state_file"
"$HOME/.claude/scripts/lane-paint.sh" "$dir" 2>/dev/null || true

case "$dir" in
  */.claude/worktrees/*) ;;
  *)
    printf 'lane-handoff: state set (not a lane worktree, no session to recycle): %s\n' "$doc"
    exit 0 ;;
esac

# The respawn contract rides on this sentinel, not on agent-state: the state
# file's ACTIVE hooks write unconditionally, so a hook in flight when the
# delayed kill landed could clobber HANDOFF and make lane-run exit (closing
# the tmux window) instead of respawning. One writer (here), one consumer
# (lane-run, which deletes it before respawning); lane-done/lane-pause clear
# it so a later deliberate final call always wins over a stale handoff.
doc_file="$dir/.claude/handoff-doc"
doc_tmp="$doc_file.tmp.$$"
printf '%s\n' "$doc" > "$doc_tmp" && mv -f "$doc_tmp" "$doc_file"

lane_pid=$(tr -d ' \n' < "$dir/.claude/agent-pid" 2>/dev/null || true)
if [[ -z "$lane_pid" || "$lane_pid" == *[!0-9]* ]]; then
  printf 'lane-handoff: state set, but no agent-pid recorded — kill the lane session yourself so lane-run.sh can respawn with %s\n' "$doc"
  exit 0
fi
case "$(ps -o comm= -p "$lane_pid" 2>/dev/null)" in
  *claude*) ;;
  *)
    printf 'lane-handoff: state set, but agent-pid %s is not a live claude — kill the lane session yourself so lane-run.sh can respawn with %s\n' "$lane_pid" "$doc"
    exit 0 ;;
esac

grace=${WT_HANDOFF_KILL_GRACE:-20}
(
  sleep "$grace"
  # The lane may have kept working past the contract and even declared DONE.
  # DONE wins — never kill a finished lane into a respawn; drop the sentinel
  # so a later session exit can't resurrect the spent handoff. Anything else:
  # re-assert HANDOFF so the board shows the truth while the runner recycles
  # (the respawn itself keys off the sentinel, immune to hook clobbers).
  [[ "$(tail -n1 "$state_file" 2>/dev/null)" == "DONE" ]] && { rm -f "$doc_file"; exit 0; }
  retmp="$state_file.tmp.handoff.$$"
  printf 'HANDOFF:%s\n' "$doc" > "$retmp" && mv -f "$retmp" "$state_file"
  kill -TERM "$lane_pid" 2>/dev/null
  for _ in 1 2 3 4 5; do
    kill -0 "$lane_pid" 2>/dev/null || exit 0
    sleep 2
  done
  kill -KILL "$lane_pid" 2>/dev/null
) </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true

printf 'lane-handoff: state set; lane session %s terminates in ~%ss, runner respawns with %s\n' "$lane_pid" "$grace" "$doc"
exit 0
