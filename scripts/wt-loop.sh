#!/usr/bin/env bash
# wt-loop.sh — outer shell loop wrapping `claude` for single-ticket autonomous
# lanes. Same shape as ralph.sh but driven by a ticket brief + auto-handoff
# bridge instead of a prd.json story list.
#
# Iteration N:
#   N=1   → kick off with the brief + slice plan instructions.
#   N>1   → /resume the most recent handoff for this branch and keep going.
#
# Between iterations Claude exits naturally (Stop event); auto-handoff.sh has
# already written ~/.claude/handoffs/<UTC>-auto-<branch>.md, so iter N+1
# starts with a fresh context that reads back that doc.
#
# Exit conditions:
#   - PR open on this branch AND reviewDecision == APPROVED  → success
#   - <wt>/.claude/agent-state starts with WAITING: or FAILED: → blocked
#   - Max iterations reached → bail with non-zero
#
# Usage:
#   wt-loop.sh <wt_path> <ticket_brief_path>
#   wt-loop.sh                       # defaults: cwd, brief from .claude/brief.md if present
#
# Env:
#   WT_LOOP_MAX_ITERS  (default 8)
#   WT_LOOP_SLEEP      (default 2)   pause between iterations
#   WT_CLAUDE          override claude command

set -u

WT="${1:-$PWD}"
BRIEF="${2:-}"
MAX_ITERS="${WT_LOOP_MAX_ITERS:-8}"
SLEEP_SECS="${WT_LOOP_SLEEP:-2}"
CLAUDE_BIN="${WT_CLAUDE:-claude --dangerously-skip-permissions --model ${WT_MODEL:-opus}}"

[[ ! -d "$WT" ]] && { echo "wt-loop: not a directory: $WT" >&2; exit 1; }
cd "$WT"

# Resolve brief: argv → <wt>/.claude/brief.md → fail.
if [[ -z "$BRIEF" && -f "$WT/.claude/brief.md" ]]; then
  BRIEF="$WT/.claude/brief.md"
fi
[[ -z "$BRIEF" || ! -f "$BRIEF" ]] && {
  echo "wt-loop: no brief found. Pass a path or drop one at $WT/.claude/brief.md" >&2
  exit 1
}

branch=$(git -C "$WT" branch --show-current 2>/dev/null || echo "")
[[ -z "$branch" ]] && { echo "wt-loop: not a git worktree?" >&2; exit 1; }
branchSlug=$(echo "$branch" | tr '/' '-' | tr -cd 'a-zA-Z0-9-')

HANDOFF_DIR="$HOME/.claude/handoffs"
mkdir -p "$HANDOFF_DIR"

review_rule="Review findings: apply blocker/major fixes directly in the PR branch (commit + push), do NOT post them as PR comments."

latest_handoff_for_branch() {
  ls -1t "$HANDOFF_DIR"/*"$branchSlug"*.md 2>/dev/null | head -1
}

pr_approved() {
  # Exits 0 if PR for this branch is OPEN + APPROVED. Quiet on no PR.
  local state decision
  read -r state decision < <(gh pr view "$branch" --json state,reviewDecision \
    -q '"\(.state) \(.reviewDecision // "PENDING")"' 2>/dev/null || echo "")
  [[ "$state" == "OPEN" && "$decision" == "APPROVED" ]]
}

blocked() {
  local state
  state=$(cat "$WT/.claude/agent-state" 2>/dev/null || echo "")
  [[ "$state" == WAITING:* || "$state" == FAILED:* ]]
}

echo "wt-loop: branch=$branch  brief=$BRIEF  max=$MAX_ITERS"

for i in $(seq 1 "$MAX_ITERS"); do
  echo ""
  echo "======================================================================="
  echo "  wt-loop iteration $i / $MAX_ITERS  ($branch)"
  echo "======================================================================="

  if (( i == 1 )); then
    prompt="Autonomous mode — wt-loop iteration 1.
Brief at $BRIEF. Read it.
Plan slices inline — no separate scoping pass.
Per slice: type-check + tests, commit per layer (schema → backend → frontend).
The session will hard-halt at turn 20; before then, commit current progress.
auto-handoff.sh will capture state. wt-loop will spawn iteration 2 to /resume.
When all slices land, run /ship. ${review_rule}
Stop only on: PR open + review-driven fixes pushed, or a genuine blocker
(ambiguity not in brief, repeated test failure same root cause, missing credential)."
  else
    handoff=$(latest_handoff_for_branch)
    if [[ -z "$handoff" ]]; then
      echo "wt-loop: iter $i but no handoff doc for branch $branchSlug found — bailing." >&2
      exit 2
    fi
    prompt="Autonomous mode — wt-loop iteration $i. /resume $handoff
Continue from where the prior iteration left off — the handoff doc carries
state, active files, and next-steps. Same slice protocol + commit cadence.
The session will hard-halt at turn 20; commit progress before then.
When all slices land, /ship. ${review_rule}"
  fi

  set +e
  echo "$prompt" | $CLAUDE_BIN --print 2>&1 | tee /dev/stderr
  rc=$?
  set -e

  if pr_approved; then
    echo ""
    echo "wt-loop: PR open + APPROVED on $branch — done at iter $i."
    exit 0
  fi

  if blocked; then
    echo ""
    echo "wt-loop: lane state shows blocker — stopping at iter $i."
    cat "$WT/.claude/agent-state" 2>/dev/null
    exit 3
  fi

  if (( rc != 0 )); then
    echo "wt-loop: claude exited rc=$rc — continuing to next iter."
  fi

  sleep "$SLEEP_SECS"
done

echo ""
echo "wt-loop: hit max iterations ($MAX_ITERS) without an approved PR."
exit 4
