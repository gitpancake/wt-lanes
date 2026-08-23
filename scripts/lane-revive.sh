#!/usr/bin/env bash
# lane-revive — restart a lane that stopped, resuming from its handoff doc.
#
# Usage:
#   lane-revive.sh <lane-worktree> [handoff-doc]
#   lane-revive.sh --capped            # every lane the respawn cap stopped
#   lane-revive.sh --capped --dry-run
#
# A lane that hits WT_MAX_RESPAWNS is tagged
# `WAITING:input:handoff respawn cap (N) hit — /resume manually: <doc>` and its
# window closes. Respawning it through `wt` would restart from the brief and
# redo everything the handoff chain already covers, so this reopens the window
# on the SAME worktree and hands the agent the resume prompt instead.
#
# The prompt fragments are lifted out of `bin/wt` at run time rather than
# copied, so the resume contract can only ever have one wording.

set -u

source "$HOME/.claude/lane-windows.sh"

WT_BIN=$(command -v wt) || { printf 'lane-revive: wt not on PATH\n' >&2; exit 1; }
[[ -L "$WT_BIN" ]] && WT_BIN=$(readlink "$WT_BIN")

# Pull `review_rule` / `test_rule` / `stop_rule` / `harness_rule` /
# `resume_template` out of wt's fragment block. They are plain assignments, so
# sourcing the slice is safe and keeps wt the single source of the wording.
load_fragments() {
  local frag
  frag=$(sed -n '/^# ---- lane kickoff prompt fragments/,/^# ---- single-lane mode/p' "$WT_BIN")
  [[ -n "$frag" ]] || { printf 'lane-revive: could not find wt prompt fragments\n' >&2; exit 1; }
  eval "$frag"
  [[ -n "${resume_template:-}" ]] || { printf 'lane-revive: wt produced no resume template (Pi lane?)\n' >&2; exit 1; }
}

# The doc the lane was told to resume from: explicit arg, else the path
# lane-pause recorded in the state line.
resolve_doc() {
  local dir=$1 explicit=${2:-} state
  if [[ -n "$explicit" ]]; then printf '%s' "$explicit"; return 0; fi
  state=$(lane_state "$dir")
  case "$state" in
    *"/resume manually: "*) printf '%s' "${state##*/resume manually: }" ;;
    *) return 1 ;;
  esac
}

revive_one() {
  local dir=${1%/} explicit=${2:-} doc label prompt agent_cmd lane_cmd

  [[ -d "$dir" ]] || { printf 'lane-revive: no such worktree: %s\n' "$dir" >&2; return 1; }

  doc=$(resolve_doc "$dir" "$explicit") || {
    printf 'lane-revive: %s has no resume doc in its state line; pass one explicitly\n' "$(basename "$dir")" >&2
    return 1
  }
  [[ -f "$doc" ]] || { printf 'lane-revive: handoff doc missing: %s\n' "$doc" >&2; return 1; }

  label=$(head -n1 "$dir/.claude/tmux-window" 2>/dev/null)
  [[ -n "$label" ]] || label=$(basename "$dir")

  if tmux list-windows -a -F '#{window_name}' 2>/dev/null | grep -qx "$label"; then
    printf 'lane-revive: window %s is already open — skipping\n' "$label" >&2
    return 1
  fi

  agent_cmd="${WT_AGENT_CMD:-${WT_CLAUDE:-claude}}"
  if [[ "${WT_ULTRACODE:-1}" != "0" && "$agent_cmd" == *claude* ]]; then
    agent_cmd="$agent_cmd --effort ultracode"
  fi

  # Resumed lanes re-enter the chain at 1, with the raised cap as the ceiling.
  prompt=$resume_template
  prompt=${prompt//\{DOC\}/$doc}
  prompt=${prompt//\{N\}/1}
  prompt=${prompt//\{MAX\}/${WT_MAX_RESPAWNS:-3}}

  if [[ "${WT_DRY_RUN:-}" == "1" ]]; then
    printf 'would revive %-12s window=%-12s doc=%s\n' "$(basename "$dir")" "$label" "$doc"
    return 0
  fi

  # The lane stopped on a WAITING tag. Clear it before the window opens, or the
  # tab reopens still flagged and the board keeps reporting a blocker that the
  # revive just resolved.
  printf 'IDLE\n' > "$dir/.claude/agent-state"
  rm -f "$dir/.claude/tmux-paint" "$dir/.claude/handoff-doc"

  lane_cmd="$HOME/.claude/scripts/lane-run.sh $(printf '%q' "$dir") $(printf '%q' "$agent_cmd") $(printf '%q' "$prompt") $(printf '%q' "$resume_template")"
  tmux new-window -n "$label" -c "$dir" "$lane_cmd" || return 1
  printf 'revived %-12s window=%-12s doc=%s\n' "$(basename "$dir")" "$label" "$doc"
}

capped_lanes() {
  local root d st
  for root in $(printf '%s' "${WT_ROOTS:-$HOME/Documents/code}" | tr ':' ' '); do
    for d in "$root"/*/.claude/worktrees/*/; do
      [[ -d "$d" ]] || continue
      st=$(lane_state "${d%/}")
      case "$st" in *"respawn cap"*) printf '%s\n' "${d%/}" ;; esac
    done
  done
}

case "${1:-}" in
  "")
    printf 'usage: lane-revive.sh <lane-worktree> [handoff-doc] | --capped [--dry-run]\n' >&2
    exit 2 ;;
  --capped)
    [[ "${2:-}" == "--dry-run" ]] && export WT_DRY_RUN=1
    load_fragments
    found=0
    while read -r lane; do
      [[ -n "$lane" ]] || continue
      found=1
      revive_one "$lane" || true
    done <<EOF
$(capped_lanes)
EOF
    (( found )) || printf 'lane-revive: no lane is sitting at the respawn cap\n'
    ;;
  *)
    load_fragments
    revive_one "$1" "${2:-}"
    ;;
esac
