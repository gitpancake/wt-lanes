#!/usr/bin/env bash
# Lane runner: keeps "the next session /resumes the handoff doc" honest, and
# keeps the lane alive when something outside it kills the agent.
#
# wt launches every lane through this wrapper instead of the raw agent
# command. When the agent process exits, the runner checks the lane's
# handoff sentinel (.claude/handoff-doc, written by lane-handoff.sh as the
# agent's final tool call) → consume it and respawn a fresh agent session
# prompted to /resume the doc; no sentinel and a clean exit (DONE, WAITING:*,
# quit) → exit and let the tmux window close as before. Without this, the
# ctx-cap doctrine's "next lane session resumes" was fiction — a lane that
# handed off mid-brief just died silently.
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
# External kills: this runner's argv carries the kickoff prompt, and that
# prompt names `bun test`, jest and tsc. A cockpit `pkill -f "bun test"`
# (2026-11-03, seven lanes) and lane-sweeper's whole-cmdline match
# (2026-11-02, six lanes) each TERMed the runner, which closed the tmux
# window and took the lane with it. So SIGTERM at the runner is handled, not
# fatal — the agent child keeps its default disposition because the trap is
# a command, not an ignore — and an agent that exits non-zero with no handoff
# sentinel is revived IN PLACE on the same session (`--resume <id>`), capped
# at WT_MAX_REVIVES (default 3). Exit 0 and 130 (Ctrl-C) are a person
# quitting and still close the window. The runner mints the session id
# (`--session-id`) so a revive can name it; a runner launched with
# `--resume <id>` adopts that id. Only an agent whose command is claude*
# gets a session id; Pi lanes exit as before.
#
# Usage: lane-run.sh <worktree> <agent_cmd> <initial_prompt> [resume_template]
#   agent_cmd:       shell string (may carry args, e.g. WT_AGENT_CMD='pi ...')
#   resume_template: prompt for respawned sessions; {DOC} {N} {MAX} are
#                    substituted. Empty → never respawn (Pi lanes).
#
# Respawn cap: WT_MAX_RESPAWNS (default 3). Hitting it re-tags the lane
# WAITING:input via lane-pause.sh so the board flags it red for a human.
# Revive cap: WT_MAX_REVIVES (default 3), same re-tag, reset by a handoff.
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
max_revives=${WT_MAX_REVIVES:-3}
doc_file="$wt_path/.claude/handoff-doc"

cd "$wt_path" || exit 1

trap 'printf "lane-run: SIGTERM ignored — the lane stays up; close the tmux window to stop it\n" >&2' TERM

agent_is_claude() {
  local head=${agent_cmd%% *}
  case "$(basename "$head")" in claude*) return 0 ;; *) return 1 ;; esac
}

strip_session_flags() {
  printf '%s' "$1" | sed -E 's/[[:space:]]+(--resume|-r|--session-id)[[:space:]]+[^[:space:]]+//g; s/[[:space:]]+--continue([[:space:]]|$)/\1/g'
}

mint_session_id() { uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]'; }

session_id=""
session_flags=""
if [[ "$agent_cmd" =~ (^|[[:space:]])(--resume|-r)[[:space:]]+([^[:space:]]+) ]]; then
  session_id=${BASH_REMATCH[3]}
elif agent_is_claude; then
  session_id=$(mint_session_id)
  [[ -n "$session_id" ]] && session_flags="--session-id $session_id"
fi

# Lanes that ship cleanly keep forgetting lane-done.sh as their final tool
# call, so the session ends IDLE and a finished lane is indistinguishable from
# a crashed one (2026-08-23: ENGH-867/868/873, three-for-three). On exit with
# no handoff pending and no WAITING tag: if the lane's PR is merged, or an open
# PR's local HEAD sha carries arbiter success, stamp DONE for it. Network or
# gh failure → leave the state alone; this only upgrades certainty, never
# invents it.
finalize_if_shipped() {
  local state branch merged sha repo arb
  state=$(head -n1 "$wt_path/.claude/agent-state" 2>/dev/null || true)
  case "$state" in DONE*|WAITING*|HANDOFF*) return 0 ;; esac
  command -v gh >/dev/null 2>&1 || return 0
  branch=$(git -C "$wt_path" branch --show-current 2>/dev/null)
  [[ -n "$branch" ]] || return 0

  merged=$(gh pr list --head "$branch" --state merged --json number --jq 'length' 2>/dev/null)
  if [[ "${merged:-0}" -ge 1 ]]; then
    "$HOME/.claude/scripts/lane-done.sh"
    return 0
  fi

  [[ "$(gh pr list --head "$branch" --state open --json number --jq 'length' 2>/dev/null)" -ge 1 ]] || return 0
  sha=$(git -C "$wt_path" rev-parse HEAD 2>/dev/null)
  repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)
  [[ -n "$sha" && -n "$repo" ]] || return 0
  arb=$(gh api "repos/$repo/commits/$sha/status" \
    --jq '[.statuses[] | select(.context == "arbiter")][0].state' 2>/dev/null)
  [[ "$arb" == "success" ]] && "$HOME/.claude/scripts/lane-done.sh"
  return 0
}

# Non-zero agent exit with no handoff pending. A DONE or WAITING lane that
# got killed has nothing in flight, so it closes as before; anything else is
# resumed on the same session. Returns 1 when there is no session to resume.
revive_in_place() {
  local state
  state=$(head -n1 "$wt_path/.claude/agent-state" 2>/dev/null || true)
  case "$state" in DONE*|WAITING*) exit 0 ;; esac
  [[ -n "$session_id" ]] || return 1
  agent_is_claude || return 1

  if (( revives >= max_revives )); then
    "$HOME/.claude/scripts/lane-pause.sh" input \
      "agent exited $rc after $max_revives in-place revives — resume manually: claude --resume $session_id"
    exit 0
  fi

  revives=$((revives + 1))
  printf 'lane-run: agent exited %d with no handoff — reviving session %s in place (%d/%d)\n' \
    "$rc" "$session_id" "$revives" "$max_revives"
  agent_cmd=$(strip_session_flags "$agent_cmd")
  session_flags="--resume $session_id"
  prompt="Autonomous mode, resumed IN PLACE after your session process exited unexpectedly (exit $rc; revive $revives/$max_revives). This is the SAME session with full prior context, not a handoff, and nothing you did caused it. Anything in flight died with it — a Bash call, a Monitor, a subagent — so re-establish its outcome instead of trusting a partial result: re-run the command; re-run a mid-poll review gate as the same single push+gate call. Then continue the work end-to-end and finish with exactly one of lane-done.sh, lane-pause.sh, or lane-handoff.sh."
  return 0
}

respawns=0
revives=0
while :; do
  if [[ -n "$prompt" ]]; then
    eval "$agent_cmd $session_flags $(printf '%q' "$prompt")"
  else
    eval "$agent_cmd $session_flags"
  fi
  rc=$?

  doc=$(head -n1 "$doc_file" 2>/dev/null || true)
  if [[ -z "$doc" ]]; then
    if (( rc == 0 || rc == 130 )); then
      finalize_if_shipped
      exit 0
    fi
    revive_in_place && continue
    finalize_if_shipped
    exit 0
  fi
  [[ -n "$resume_template" ]] || exit 0

  rm -f "$doc_file"
  # A respawn is a FRESH session. An outage revive launches this runner with
  # `--resume <id>`; replaying that verbatim reopened the same session on every
  # handoff (2026-10-15: one lane ran to 760K ctx across three "handoffs").
  agent_cmd=$(strip_session_flags "$agent_cmd")
  if (( respawns >= max_respawns )); then
    "$HOME/.claude/scripts/lane-pause.sh" input \
      "handoff respawn cap ($max_respawns) hit — /resume manually: $doc"
    exit 0
  fi

  respawns=$((respawns + 1))
  revives=0
  printf 'lane-run: HANDOFF detected, respawning (%d/%d) with %s\n' \
    "$respawns" "$max_respawns" "$doc"
  prompt=$resume_template
  prompt=${prompt//\{DOC\}/$doc}
  prompt=${prompt//\{N\}/$respawns}
  prompt=${prompt//\{MAX\}/$max_respawns}
  session_id=""
  session_flags=""
  if agent_is_claude; then
    session_id=$(mint_session_id)
    [[ -n "$session_id" ]] && session_flags="--session-id $session_id"
  fi
done
