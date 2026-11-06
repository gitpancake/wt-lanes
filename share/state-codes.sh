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

# ---- state rules -----------------------------------------------------------
# Everything that depends on a lane's agent-state reads it through these
# functions: the tab paint, the hold watcher, the board, wt's lane cap and the
# hooks that must not overwrite a final state.

# lane_class <raw-state> -> blocked|hold|ext|done|busy|idle
#
# blocked = the lane asked you something (red, cleared by a visit).
# hold    = a named person must release the PR (purple, blinks until the
#           state moves; a visit never clears it).
# ext     = waiting on something outside you and outside any person (yellow).
# busy    = working, respawning after a handoff, or parked on a Monitor —
#           nothing is painted. Unknown pause codes fall to blocked, the safe
#           direction — same rule the board uses.
lane_class() {
  local raw=$1 code
  case "$raw" in
    DONE)        printf 'done';   return ;;
    FAILED*)     printf 'blocked';return ;;
    HANDOFF*)    printf 'busy';   return ;;
    ACTIVE*|RUNNING*) printf 'busy'; return ;;
    WAITING:*:*) code=${raw#WAITING:}; code=${code%%:*} ;;
    WAITING:*)   code=${raw#WAITING:} ;;
    WAITING)     code=input ;;
    *)           printf 'idle';   return ;;
  esac
  case " $WT_CODES_YELLOW " in *" $code "*) printf 'ext';  return ;; esac
  case " $WT_CODES_HOLD "   in *" $code "*) printf 'hold'; return ;; esac
  printf 'blocked'
}

# A deliberate final state: the lane's own last word (lane-done / lane-pause /
# lane-handoff) or a turn parked on a Monitor. The Stop, Notification and
# precheck hooks never overwrite one — clobbering it erases the exit reason.
state_is_final() {
  case "$1" in
    DONE|HANDOFF:*|WAITING:*:*|RUNNING:monitor) return 0 ;;
  esac
  return 1
}

# Lane classes that take one of the WT_MAX_LANES slots: the lane is working or
# waiting on you. hold, ext and done wait on someone else or are finished.
WT_CLASSES_USING_LANE_SLOT="blocked busy idle"

# Busy, but parked on the review-gate Monitor: waiting on reviewers, not on you.
WT_STATES_PARKED="RUNNING:monitor"

lane_state_uses_slot() {
  local raw=$1
  case " $WT_STATES_PARKED " in *" $raw "*) return 1 ;; esac
  case " $WT_CLASSES_USING_LANE_SLOT " in *" $(lane_class "$raw") "*) return 0 ;; esac
  return 1
}

# The one way to set a lane's state: atomic (tmp + mv), because the file has
# several writers and readers polling every 2s.
lane_state_write() {
  local laneDir=$1 laneState=$2 tmp
  mkdir -p "$laneDir/.claude"
  tmp="$laneDir/.claude/agent-state.tmp.$$"
  printf '%s\n' "$laneState" > "$tmp" && mv -f "$tmp" "$laneDir/.claude/agent-state"
}
