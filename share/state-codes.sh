# Pause/wait reason-code vocab, grouped by tab/board colour class.
#
# Single source of truth for machine consumers — installed at
# ~/.claude/state-codes.sh and sourced by lane-pause.sh (validation),
# lane-windows.sh (tab paint), lane-holds.sh (hold watcher) and agent-board
# (classification). Human-facing docs: agent-state-vocab.md.
#
# red    = blocked on the cockpit: the lane asked you something
# yellow = waiting on something outside you and outside any named person
# hold   = the PR is complete from the lane's side; a named person must release it

WT_CODES_RED="ambiguity creds test-loop merge-conflict verify scope input"
WT_CODES_YELLOW="external review"
WT_CODES_HOLD="holland human prompt-owner"
WT_CODES_ALL="$WT_CODES_RED $WT_CODES_YELLOW $WT_CODES_HOLD"
