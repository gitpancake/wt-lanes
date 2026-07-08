#!/usr/bin/env bash
# Lane runner: keeps "the next session /resumes the handoff doc" honest.
#
# wt launches every lane through this wrapper instead of the raw agent
# command. When the agent process exits, the runner checks the lane's
# handoff sentinel (.claude/handoff-doc, written by lane-handoff.sh as the
# agent's final tool call) → consume it and respawn a fresh agent session
# prompted to /resume the doc; no sentinel (DONE, WAITING:*, quit, crash) →
# exit and let the tmux window close as before. Without this, the ctx-cap
# doctrine's "next lane session resumes" was fiction — a lane that handed
# off mid-brief just died silently.
#
# Why a sentinel and not agent-state: the state file has five writers, and
# the ACTIVE hooks write unconditionally. A hook still in flight when
# lane-handoff's delayed kill landed could clobber HANDOFF between the
# watcher's re-assert and this loop's read — the runner then exited instead
# of respawning and the tmux window vanished mid-handoff. The sentinel has
# exactly one writer (lane-handoff.sh) and one consumer (this loop), so kill
# timing can't race it. agent-state still carries HANDOFF for the board.
#
# Exit trigger: an interactive claude session never exits when its turn ends
# (it idles at the REPL prompt), so lane-handoff.sh kills the session after a
# grace period — that's what makes this loop's eval return on the handoff
# path. DONE/WAITING lanes keep their session alive; the window stays
# interactive until the human closes it.
#
# Usage: lane-run.sh <worktree> <agent_cmd> <initial_prompt> [resume_template]
#   agent_cmd:       shell string (may carry args, e.g. WT_AGENT_CMD='pi ...')
#   resume_template: prompt for respawned sessions; {DOC} {N} {MAX} are
#                    substituted. Empty → never respawn (Pi lanes).
#
# Respawn cap: WT_MAX_RESPAWNS (default 3). Hitting it re-tags the lane
# WAITING:input via lane-pause.sh so the board flags it red for a human.
# macOS bash 3.2 compatible.

set -u

if (( $# < 3 )); then
  printf 'usage: lane-run.sh <worktree> <agent_cmd> <initial_prompt> [resume_template]\n' >&2
  exit 2
fi

wt_path=$1
agent_cmd=$2
prompt=$3
resume_template=${4:-}
max_respawns=${WT_MAX_RESPAWNS:-3}
doc_file="$wt_path/.claude/handoff-doc"

cd "$wt_path" || exit 1

respawns=0
while :; do
  if [[ -n "$prompt" ]]; then
    eval "$agent_cmd $(printf '%q' "$prompt")"
  else
    eval "$agent_cmd"
  fi

  doc=$(head -n1 "$doc_file" 2>/dev/null || true)
  [[ -n "$doc" ]] || exit 0
  [[ -n "$resume_template" ]] || exit 0

  rm -f "$doc_file"
  if (( respawns >= max_respawns )); then
    "$HOME/.claude/scripts/lane-pause.sh" input \
      "handoff respawn cap ($max_respawns) hit — /resume manually: $doc"
    exit 0
  fi

  respawns=$((respawns + 1))
  printf 'lane-run: HANDOFF detected, respawning (%d/%d) with %s\n' \
    "$respawns" "$max_respawns" "$doc"
  prompt=$resume_template
  prompt=${prompt//\{DOC\}/$doc}
  prompt=${prompt//\{N\}/$respawns}
  prompt=${prompt//\{MAX\}/$max_respawns}
done
