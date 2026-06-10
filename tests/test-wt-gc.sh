#!/usr/bin/env bash
# wt-gc safety gates: age threshold, dirty skip, unpushed skip, clean reap.
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

GC="$REPO_DIR/bin/wt-gc"
export WT_GC_LOG_DIR="$TEST_TMP/logs"

root="$TEST_TMP/code"
origin="$TEST_TMP/origin.git"
repo="$root/proj"
mkdir -p "$root"
git init -q --bare -b main "$origin"
git clone -q "$origin" "$repo" 2>/dev/null
gitc() { git -C "$repo" -c user.email=t@t -c user.name=t "$@"; }
printf '# proj\n' > "$repo/README.md"
gitc add README.md
gitc commit -q -m init
gitc push -q -u origin main

lanes="$repo/.claude/worktrees"
mk_lane() {
  local name=$1 branch=$2
  gitc worktree add -q "$lanes/$name" -b "$branch"
  mkdir -p "$lanes/$name/.claude"
  echo IDLE > "$lanes/$name/.claude/agent-state"
}
age_lane() { touch -t 202001010000 "$lanes/$1/.claude/agent-state"; }
age_lane_24h() {
  local ts
  ts=$(date -v-24H '+%Y%m%d%H%M' 2>/dev/null || date -d '24 hours ago' '+%Y%m%d%H%M')
  touch -t "$ts" "$lanes/$1/.claude/agent-state"
}

mk_lane young feature/young

mk_lane old-clean feature/old-clean
age_lane old-clean

# Past the gc threshold (10h) but inside the notify-dirty window (120h) -> SKIP.
mk_lane old-dirty feature/old-dirty
echo "real user work" > "$lanes/old-dirty/wip.txt"
age_lane_24h old-dirty

# Way past the notify-dirty window -> NOTIFY (still never removed).
mk_lane ancient-dirty feature/ancient-dirty
echo "real user work" > "$lanes/ancient-dirty/wip.txt"
age_lane ancient-dirty

mk_lane old-unpushed feature/old-unpushed
git -C "$lanes/old-unpushed" push -q -u origin feature/old-unpushed
git -C "$lanes/old-unpushed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m wip
age_lane old-unpushed

# Old + clean (reapable) but a live process whose comm matches *claude* holds
# the lane — Safety 0 must keep it, even with --force.
mk_lane old-live feature/old-live
age_lane old-live
# Symlink, not copy — macOS AMFI SIGKILLs copied platform binaries. Exec via
# the symlink makes comm carry "claude" on both macOS (full exec path) and
# Linux (basename of the execve path).
ln -s "$(command -v sleep)" "$TEST_TMP/claude"
"$TEST_TMP/claude" 300 &
live_pid=$!
echo "$live_pid" > "$lanes/old-live/.claude/agent-pid"
touch -t 202001010000 "$lanes/old-live/.claude/agent-state"

out=$(WT_ROOTS="$root" "$GC" --dry-run)
assert_contains "dry-run reports the reapable lane" "$out" "DRY-RUN would remove old-clean"
assert_dir "dry-run removes nothing" "$lanes/old-clean"

out=$(WT_ROOTS="$root" "$GC")
assert_no_dir "old + clean + merged -> reaped" "$lanes/old-clean"
assert_dir  "young lane untouched" "$lanes/young"
assert_dir  "dirty lane kept" "$lanes/old-dirty"
assert_dir  "ancient dirty lane kept" "$lanes/ancient-dirty"
assert_dir  "unpushed lane kept" "$lanes/old-unpushed"
assert_contains "dirty skip logged" "$out" "SKIP old-dirty — uncommitted changes"
assert_contains "ancient dirty notifies, never removes" "$out" "NOTIFY ancient-dirty"
assert_contains "unpushed skip logged" "$out" "1 unpushed commit(s)"
assert_contains "branch survives the reap" "$(gitc branch --list feature/old-clean)" "feature/old-clean"
assert_dir "live-session lane kept" "$lanes/old-live"
assert_contains "live-session skip logged" "$out" "SKIP old-live — live claude session (pid $live_pid"

out=$(WT_ROOTS="$root" "$GC" --force)
assert_dir "live-session lane survives --force" "$lanes/old-live"

kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
out=$(WT_ROOTS="$root" "$GC")
assert_no_dir "dead pid -> lane reaped normally" "$lanes/old-live"

finish
