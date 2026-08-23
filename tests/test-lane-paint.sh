#!/usr/bin/env bash
# lane-windows.sh: state -> class mapping, and the paint cache's ack contract.
# tmux is stubbed, so this runs headless with no server.
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

source "$REPO_DIR/share/lane-windows.sh"

# --- classification --------------------------------------------------------

assert_eq "idle"                  "$(lane_class 'IDLE')"                      "idle"
assert_eq "active is busy"        "$(lane_class 'ACTIVE:Bash')"               "busy"
assert_eq "precheck is busy"      "$(lane_class 'RUNNING:precheck')"          "busy"
assert_eq "done"                  "$(lane_class 'DONE')"                      "done"
assert_eq "failed precheck blocks" "$(lane_class 'FAILED:typecheck')"         "blocked"
assert_eq "handoff is external"   "$(lane_class 'HANDOFF:/tmp/doc.md')"       "ext"
assert_eq "bare waiting blocks"   "$(lane_class 'WAITING')"                   "blocked"
assert_eq "untagged input blocks" "$(lane_class 'WAITING:input')"             "blocked"
assert_eq "ambiguity blocks"      "$(lane_class 'WAITING:ambiguity:which db')" "blocked"
assert_eq "external is yellow"    "$(lane_class 'WAITING:external:vendor')"   "ext"
assert_eq "review is blue"        "$(lane_class 'WAITING:review:PR #12')"     "review"
# An unknown code must fail toward red — the same safe direction the board takes.
assert_eq "unknown code blocks"   "$(lane_class 'WAITING:bogus:huh')"         "blocked"

assert_eq "blocked outranks ext"     "$(lane_prio blocked)" "0"
assert_eq "busy sorts below review"  "$(lane_prio busy)"    "4"
assert_eq "only attention classes paint" "$(lane_class_style busy)" ""

# --- tag / detail split ----------------------------------------------------

assert_eq "tag from tagged pause"    "$(lane_state_tag 'WAITING:creds:need EASYPOST_KEY')" "creds"
assert_eq "detail from tagged pause" "$(lane_state_detail 'WAITING:creds:need EASYPOST_KEY')" "need EASYPOST_KEY"
assert_eq "detail keeps inner colons" "$(lane_state_detail 'WAITING:ambiguity:pick: a or b')" "pick: a or b"
assert_eq "tool name keeps its case"  "$(lane_state_tag 'ACTIVE:Bash')" "Bash"
assert_eq "untagged pause has no detail" "$(lane_state_detail 'WAITING:input')" ""

# --- paint cache + ack -----------------------------------------------------

lane="$TEST_TMP/repo/.claude/worktrees/some-lane"
mkdir -p "$lane/.claude"
printf 'WAITING:ambiguity:which db\n' > "$lane/.claude/agent-state"

# Stub the two tmux touchpoints: window lookup and style application.
applied="$TEST_TMP/applied"
lane_window_id() { printf '@1'; }
lane_paint_apply() { printf '%s\n' "$2" >> "$applied"; }

lane_paint_one "$lane"
assert_eq "blocked lane paints red"     "$(tail -n1 "$applied")"            "blocked"
assert_eq "cache records what shows"    "$(cat "$lane/.claude/tmux-paint")" "blocked"

before=$(wc -l < "$applied")
lane_paint_one "$lane"
assert_eq "unchanged class does not repaint" "$(wc -l < "$applied")" "$before"

lane_paint_ack "$lane"
assert_eq "ack clears the tab"          "$(tail -n1 "$applied")"            "idle"
assert_eq "ack is recorded"             "$(cat "$lane/.claude/tmux-paint")" "ack:blocked"

# Still blocked, but already acknowledged — nothing may relight it.
lane_paint_one "$lane"
assert_eq "ack survives a repaint"      "$(cat "$lane/.claude/tmux-paint")" "ack:blocked"

# A sweep recovers closed tabs without resurrecting an acknowledged flag.
lane_windows() { printf '@1\ts:1\tsome-lane\t%s\n' "$lane"; }
lane_paint_all
assert_eq "sweep honours the ack"       "$(tail -n1 "$applied")"            "idle"
assert_eq "sweep leaves the ack intact" "$(cat "$lane/.claude/tmux-paint")" "ack:blocked"

# The lane moves on and blocks again on something new: the flag must come back.
printf 'ACTIVE:Bash\n' > "$lane/.claude/agent-state"
lane_paint_one "$lane"
printf 'WAITING:creds:need a key\n' > "$lane/.claude/agent-state"
lane_paint_one "$lane"
assert_eq "a fresh block relights"      "$(tail -n1 "$applied")"            "blocked"
assert_eq "cache follows the new block" "$(cat "$lane/.claude/tmux-paint")" "blocked"

# Acking a working lane would write a cache entry that swallows its first block.
printf 'ACTIVE:Bash\n' > "$lane/.claude/agent-state"
lane_paint_one "$lane"
lane_paint_ack "$lane"
assert_eq "busy lanes are not acked"    "$(cat "$lane/.claude/tmux-paint")" "busy"

finish
