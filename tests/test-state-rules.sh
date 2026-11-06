#!/usr/bin/env bash
# State rules in share/state-codes.sh: which states use a WT_MAX_LANES slot,
# which are final, and that lane_state_write is atomic and readable back.
source "$(dirname "$0")/harness.sh"
source "$REPO_DIR/share/state-codes.sh"

uses_slot() { lane_state_uses_slot "$1" && printf 'slot' || printf 'free'; }
is_final() { state_is_final "$1" && printf 'final' || printf 'open'; }

assert_eq "working lane uses a slot" "$(uses_slot 'ACTIVE:Bash')" "slot"
assert_eq "idle lane uses a slot" "$(uses_slot 'IDLE')" "slot"
assert_eq "red pause uses a slot" "$(uses_slot 'WAITING:ambiguity:which slice first')" "slot"
assert_eq "handoff respawn uses a slot" "$(uses_slot 'HANDOFF:/tmp/doc.md')" "slot"
assert_eq "gate monitor frees the slot" "$(uses_slot 'RUNNING:monitor')" "free"
assert_eq "hold frees the slot" "$(uses_slot 'WAITING:holland:PR #1')" "free"
assert_eq "review wait frees the slot" "$(uses_slot 'WAITING:review:PR #1')" "free"
assert_eq "done frees the slot" "$(uses_slot 'DONE')" "free"

assert_eq "done is final" "$(is_final 'DONE')" "final"
assert_eq "pause is final" "$(is_final 'WAITING:review:PR #1')" "final"
assert_eq "active is not final" "$(is_final 'ACTIVE:Bash')" "open"

laneDir="$TEST_TMP/lane"
lane_state_write "$laneDir" "WAITING:human:PR #2"
assert_eq "write creates the state file" "$(cat "$laneDir/.claude/agent-state")" "WAITING:human:PR #2"
lane_state_write "$laneDir" DONE
assert_eq "write replaces the state" "$(cat "$laneDir/.claude/agent-state")" "DONE"
assert_eq "write leaves no temp file" "$(ls "$laneDir/.claude" | grep -c tmp)" "0"

finish
