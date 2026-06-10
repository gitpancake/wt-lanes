# Pause/wait reason-code vocab, grouped by board color class.
#
# Single source of truth for machine consumers — installed at
# ~/.claude/state-codes.sh and sourced by lane-pause.sh (validation) and
# agent-board (classification). Human-facing docs: agent-state-vocab.md.
#
# red    = lane is blocked on the human, act now
# yellow = blocked on an external dependency
# dim    = expected pause (e.g. waiting on PR review)

WT_CODES_RED="ambiguity creds test-loop merge-conflict verify scope input"
WT_CODES_YELLOW="external"
WT_CODES_DIM="review"
WT_CODES_ALL="$WT_CODES_RED $WT_CODES_YELLOW $WT_CODES_DIM"
