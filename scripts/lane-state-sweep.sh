#!/usr/bin/env bash
# lane-state-sweep — clear wedged lane state files so the board stays honest.
#
# A lane killed without its SessionEnd/Stop hooks (OOM, tmux kill, reboot)
# leaves .claude/agent-state stuck on ACTIVE/WAITING/HANDOFF forever. The
# board, worker-status, and lane-revive --capped then report blockers that
# died weeks ago (2026-08-23 audit: 426 of 686 lanes wedged, some 72d old).
#
# A lane is wedged when ALL hold:
#   - agent-state is non-terminal (not DONE)
#   - the state file hasn't been touched in N days (default 7)
#   - the recorded agent-pid is dead or absent
#   - no tmux window carries the lane's label
#
# Resolution: branch's PR merged -> DONE; anything else -> IDLE. The old
# state is logged to ~/.claude/logs/lane-state-sweep.log, never silently lost.
# tmux-paint is cleared so a repaint can't resurrect a stale flag.
#
# Usage: lane-state-sweep.sh [--days N] [--dry-run] [--no-pr]
#   --no-pr  skip the gh merged-PR lookup (fast; everything resolves to IDLE)
# macOS bash 3.2 compatible.

set -u

days=7
dry_run=0
check_pr=1
while (( $# )); do
  case "$1" in
    --days) days=${2:?}; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --no-pr) check_pr=0; shift ;;
    *) printf 'usage: lane-state-sweep.sh [--days N] [--dry-run] [--no-pr]\n' >&2; exit 2 ;;
  esac
done

log_file="$HOME/.claude/logs/lane-state-sweep.log"
mkdir -p "$HOME/.claude/logs"
now=$(date +%s)
cutoff=$(( now - days * 86400 ))

open_windows=$(tmux list-windows -a -F '#{window_name}' 2>/dev/null || true)

swept=0
scanned=0
for root in $(printf '%s' "${WT_ROOTS:-$HOME/Documents/code}" | tr ':' ' '); do
  for lane in "$root"/*/.claude/worktrees/*/; do
    lane=${lane%/}
    state_file="$lane/.claude/agent-state"
    [[ -f "$state_file" ]] || continue
    scanned=$((scanned + 1))

    state=$(head -n1 "$state_file" 2>/dev/null || true)
    case "$state" in DONE*|"") continue ;; esac

    mtime=$(stat -f %m "$state_file" 2>/dev/null || echo 0)
    (( mtime > cutoff )) && continue

    pid=$(head -n1 "$lane/.claude/agent-pid" 2>/dev/null || true)
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      continue
    fi

    label=$(head -n1 "$lane/.claude/tmux-window" 2>/dev/null || true)
    if [[ -n "$label" ]] && printf '%s\n' "$open_windows" | grep -qx "$label"; then
      continue
    fi

    resolved="IDLE"
    if (( check_pr )) && command -v gh >/dev/null 2>&1; then
      branch=$(git -C "$lane" branch --show-current 2>/dev/null || true)
      if [[ -n "$branch" ]]; then
        merged=$(cd "$lane" && gh pr list --head "$branch" --state merged \
          --json number --jq 'length' 2>/dev/null || echo 0)
        [[ "${merged:-0}" -ge 1 ]] && resolved="DONE"
      fi
    fi

    case "$state" in IDLE*)
      [[ "$resolved" == "IDLE" ]] && continue ;;
    esac

    age_days=$(( (now - mtime) / 86400 ))
    if (( dry_run )); then
      printf 'would sweep %-55s %-28s -> %s (%dd)\n' \
        "$(basename "$lane")" "$state" "$resolved" "$age_days"
      continue
    fi

    tmp="$state_file.tmp.$$"
    printf '%s\n' "$resolved" > "$tmp" && mv -f "$tmp" "$state_file"
    rm -f "$lane/.claude/tmux-paint" "$lane/.claude/agent-pid"
    printf '[%s] %s: %s -> %s (%dd stale)\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$lane" "$state" "$resolved" "$age_days" >> "$log_file"
    printf 'swept %-55s %-28s -> %s (%dd)\n' \
      "$(basename "$lane")" "$state" "$resolved" "$age_days"
    swept=$((swept + 1))
  done
done

printf 'lane-state-sweep: %d scanned, %d swept (threshold %dd)\n' "$scanned" "$swept" "$days"
