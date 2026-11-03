#!/usr/bin/env bash
# lane-sweeper candidate selection: build tools are judged on the argv head,
# so a lane runner whose kickoff prompt names every build tool is never a
# candidate, and neither is a claude process or anything the deny net covers.
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

SWEEPER="$REPO_DIR/bin/lane-sweeper"
export LANE_SWEEP_LOG_FILE="$TEST_TMP/sweeper.log"
export LANE_SWEEP_FIXTURE_LANE="$TEST_TMP/code/proj/.claude/worktrees/lane-a"

prompt='Autonomous mode. Verification: `bun type-check` and scoped tests (`bun test <path>`, jest, eslint, tsc --noEmit) run foreground. Never kill build tools by pattern.'

fixture="$TEST_TMP/ps.txt"
cat > "$fixture" <<EOF
101 100 5120 0.0 01:00:00 bash /Users/h/.claude/scripts/lane-run.sh /Users/h/code/proj/.claude/worktrees/lane-a claude --dangerously-skip-permissions --strict-mcp-config --mcp-config /Users/h/.claude/mcp.lane.json $prompt
102 101 409600 12.0 01:00:00 claude --dangerously-skip-permissions --strict-mcp-config --mcp-config /Users/h/.claude/mcp.lane.json --model claude-sonnet-5 $prompt
103 102 2960 0.0 01:00:00 /bin/zsh -c source /Users/h/.claude/shell-snapshots/snap.sh && eval 'bun test src/foo.test.ts'
104 103 466944 105.0 00:50:00 node /Users/h/code/proj/node_modules/.bin/tsc --noEmit
105 1 232448 10.0 00:02:00 /Users/h/.bun/bin/bun test src/server/foo.test.ts
106 102 6976 0.0 00:05:00 bash /Users/h/.claude/lane-bin/bun run type-check
107 102 1744 0.0 00:50:00 sh -c NODE_OPTIONS=--max_old_space_size=8192 node_modules/.bin/tsc --noEmit > /tmp/tc.log 2>&1
108 102 102400 95.0 02:00:00 bun install
109 102 1024000 0.0 00:50:00 node /Users/h/code/proj/node_modules/next/dist/compiled/jest-worker/processChild.js
110 102 5242880 50.0 00:20:00 node /Users/h/code/proj/node_modules/.bin/eslint src
EOF

out=$(LANE_SWEEP_PS_FILE="$fixture" bash "$SWEEPER" --dry-run)
rc=$?
assert_rc "dry run exits 0" "$rc" 0

killed() { printf '%s\n' "$out" | grep -c "pid=$1 " ; }

assert_eq "lane-run.sh runner is never a candidate" "$(killed 101)" 0
assert_eq "claude lane process is never a candidate" "$(killed 102)" 0
assert_eq "Bash-tool shell wrapping bun test is not a candidate" "$(killed 103)" 0
assert_eq "wedged tsc --noEmit is reaped" "$(killed 104)" 1
assert_contains "wedged reason names the age cap" "$out" 'pid=104 lane=lane-a rss=456MB cpu=105.0% age=3000s reason="wedged 3000s > 2700s"'
assert_eq "orphaned bun test is reaped" "$(killed 105)" 1
assert_contains "orphan reason" "$out" 'pid=105 lane=lane-a rss=227MB cpu=10.0% age=120s reason="orphaned (lane agent gone)"'
assert_eq "young type-check under MIN_AGE is left alone" "$(killed 106)" 0
assert_eq "sh -c tsc --noEmit wrapper is reaped on age" "$(killed 107)" 1
assert_eq "bun install is denied regardless of age" "$(killed 108)" 0
assert_eq "jest worker past age cap is reaped" "$(killed 109)" 1
assert_eq "eslint over the RSS cap is reaped" "$(killed 110)" 1
assert_contains "rss reason" "$out" 'pid=110 lane=lane-a rss=5120MB cpu=50.0% age=1200s reason="rss 5120MB for 1200s"'

log_lines=$(grep -c 'DRY-RUN would kill' "$LANE_SWEEP_LOG_FILE")
assert_eq "every verdict is logged" "$log_lines" 5

finish
