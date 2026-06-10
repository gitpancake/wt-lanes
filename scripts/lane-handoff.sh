#!/usr/bin/env bash
# Mark the lane handed off: agent-state → HANDOFF:<doc-path>. The lane agent
# runs this as its FINAL tool call, right after /handoff writes the doc, when
# context forces a session swap mid-brief. lane-run.sh (the lane runner) sees
# the state when the agent process exits and respawns a fresh session that
# /resumes the doc — this script is what makes "the next session resumes"
# true instead of aspirational.
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

dir="${CLAUDE_PROJECT_DIR:-$PWD}"
mkdir -p "$dir/.claude"
# Atomic (tmp + mv): the state file has multiple writers + 2s-tick readers.
tmp="$dir/.claude/agent-state.tmp.$$"
printf 'HANDOFF:%s\n' "$doc" > "$tmp" && mv -f "$tmp" "$dir/.claude/agent-state"

printf 'lane-handoff: state set, runner will respawn with %s\n' "$doc"
exit 0
