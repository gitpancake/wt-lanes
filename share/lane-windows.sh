# Lane ↔ tmux window resolution, state classification, and the tab palette.
#
# Single source for machine consumers — installed at ~/.claude/lane-windows.sh
# and sourced by lane-paint.sh (painting), lane-done.sh (its green flash), and
# tmux/lane-menu.sh (the jump menu). Pause-code vocab comes from the sibling
# state-codes.sh; this file maps that vocab onto colours and ordering.
#
# bash 3.2 compatible (CLAUDE.md invariant 4) — no assoc arrays, no ${x^^}.

# --- pause-code vocab ------------------------------------------------------
# Repo copy wins over the installed copy, so editing the repo is the truth.
_lw_self="${BASH_SOURCE[0]}"
[ -L "$_lw_self" ] && _lw_self=$(readlink "$_lw_self")
_lw_dir=$(cd "$(dirname "$_lw_self")" && pwd)
if [ -f "$_lw_dir/state-codes.sh" ]; then
  . "$_lw_dir/state-codes.sh"
elif [ -f "$HOME/.claude/state-codes.sh" ]; then
  . "$HOME/.claude/state-codes.sh"
fi
: "${WT_CODES_RED:=}" "${WT_CODES_YELLOW:=}" "${WT_CODES_DIM:=}"

# lane_class <raw-state> -> blocked|ext|review|done|busy|idle
#
# blocked = act now (red). ext = waiting on something outside (yellow).
# review  = expected pause (blue). Unknown pause codes fall to blocked, the
# safe direction — same rule the board uses.
lane_class() {
  local raw=$1 code
  case "$raw" in
    DONE)        printf 'done';   return ;;
    FAILED*)     printf 'blocked';return ;;
    HANDOFF*)    printf 'ext';    return ;;
    ACTIVE*|RUNNING*) printf 'busy'; return ;;
    WAITING:*:*) code=${raw#WAITING:}; code=${code%%:*} ;;
    WAITING:*)   code=${raw#WAITING:} ;;
    WAITING)     code=input ;;
    *)           printf 'idle';   return ;;
  esac
  case " $WT_CODES_YELLOW " in *" $code "*) printf 'ext';    return ;; esac
  case " $WT_CODES_DIM "    in *" $code "*) printf 'review'; return ;; esac
  printf 'blocked'
}

# lane_class_style <class> -> a tmux window-status-style, or empty for
# "leave the tab alone". Gruvbox Material Medium Dark, matching ~/.tmux.conf.
lane_class_style() {
  case "$1" in
    blocked) printf 'fg=#1d2021,bg=#ea6962,bold' ;;
    ext)     printf 'fg=#1d2021,bg=#d8a657,bold' ;;
    review)  printf 'fg=#1d2021,bg=#7daea3,bold' ;;
    done)    printf 'fg=#1d2021,bg=#a9b665,bold' ;;
    *)       printf '' ;;
  esac
}

lane_class_glyph() {
  case "$1" in
    blocked) printf '\xe2\x97\x8f' ;;
    ext)     printf '\xe2\x97\x90' ;;
    review)  printf '\xe2\x97\x8b' ;;
    done)    printf '\xe2\x9c\x93' ;;
    busy)    printf '\xe2\x96\xb6' ;;
    *)       printf '\xc2\xb7' ;;
  esac
}

# Menu ordering: the lane that needs you sorts to the top.
lane_prio() {
  case "$1" in
    blocked) printf '0' ;;
    ext)     printf '1' ;;
    review)  printf '2' ;;
    done)    printf '3' ;;
    busy)    printf '4' ;;
    *)       printf '5' ;;
  esac
}

lane_state() {
  tail -n1 "$1/.claude/agent-state" 2>/dev/null || printf ''
}

# lane_state_tag <raw-state>  -> short tag  ("ambiguity", "active:Bash", ...)
# lane_state_detail <raw-state> -> the free-text half of a tagged pause, which
# is the actual question the lane stopped on.
lane_state_tag() {
  local raw=$1
  case "$raw" in
    WAITING:*:*) raw=${raw#WAITING:}; printf '%s' "${raw%%:*}" ;;
    WAITING:*)   printf '%s' "${raw#WAITING:}" ;;
    WAITING)     printf 'input' ;;
    HANDOFF:*)   printf 'handoff' ;;
    RUNNING:*)   printf '%s' "${raw#RUNNING:}" ;;
    ACTIVE:*)    printf '%s' "${raw#ACTIVE:}" ;;
    *)           printf '%s' "$(printf '%s' "$raw" | tr 'A-Z' 'a-z')" ;;
  esac
}

lane_state_detail() {
  local raw=$1
  case "$raw" in
    WAITING:*:*) raw=${raw#WAITING:}; printf '%s' "${raw#*:}" ;;
    *)           printf '' ;;
  esac
}

# lane_windows -> "<window_id>\t<session:index>\t<window_name>\t<lane-worktree>"
# per live lane window, one line each. Field 2 is a tab-bar sort key, so a menu
# can break priority ties in the order the tabs actually sit on screen.
#
# Resolution is by pane cwd: wt launches every lane pane with `-c <worktree>`,
# so the worktree is right there in pane_current_path and no sentinel glob or
# pid walk is needed. A lane spawned with WT_LAYOUT=pane shares the cockpit's
# window and is deliberately absent — there is no tab of its own to paint.
lane_windows() {
  command -v tmux >/dev/null 2>&1 || return 0
  local panes seen wid wpos wname wpath rest slug dir
  panes=$(tmux list-panes -a -F '#{window_id}|#{session_name}:#{window_index}|#{window_name}|#{pane_current_path}' 2>/dev/null) || return 0
  [ -n "$panes" ] || return 0
  seen=""
  while IFS='|' read -r wid wpos wname wpath; do
    [ -n "$wid" ] || continue
    case "$wpath" in */.claude/worktrees/*) ;; *) continue ;; esac
    case " $seen " in *" $wid "*) continue ;; esac
    rest=${wpath#*/.claude/worktrees/}
    slug=${rest%%/*}
    dir="${wpath%%/.claude/worktrees/*}/.claude/worktrees/$slug"
    [ -d "$dir" ] || continue
    seen="$seen $wid"
    printf '%s\t%s\t%s\t%s\n' "$wid" "$wpos" "$wname" "$dir"
  done <<EOF
$panes
EOF
}

# lane_window_id <lane-worktree> -> the window id, or empty if the lane has no
# tab of its own.
lane_window_id() {
  local target=${1%/} wid wpos wname dir
  while IFS=$(printf '\t') read -r wid wpos wname dir; do
    [ "$dir" = "$target" ] && { printf '%s' "$wid"; return 0; }
  done <<EOF
$(lane_windows)
EOF
  return 1
}

# --- painting --------------------------------------------------------------
# Colouring the tab is a side effect of a state write, never a state write
# itself — nothing below may touch agent-state (CLAUDE.md invariant 2).
#
# These live here rather than only in scripts/lane-paint.sh so the state-write
# hooks can paint by sourcing, with no extra process per tool call: the cached
# class is a builtin read, and an unchanged class returns before tmux is
# forked at all.

lane_paint_apply() {
  local wid=$1 class=$2 style
  style=$(lane_class_style "$class")
  if [ -n "$style" ]; then
    tmux set-option -w -t "$wid" window-status-style "$style" 2>/dev/null
  else
    tmux set-option -w -t "$wid" -u window-status-style 2>/dev/null
  fi
}

# <lane>/.claude/tmux-paint records what the tab was last shown as. A bare
# class means "showing it"; an "ack:<class>" means "you have seen this one,
# keep the tab clear until the lane's state actually moves on".
lane_paint_shown() {
  cat "$1/.claude/tmux-paint" 2>/dev/null || printf ''
}

lane_paint_one() {
  local dir=${1%/} class wid
  [ -d "$dir" ] || return 0
  class=$(lane_class "$(lane_state "$dir")")
  case "$(lane_paint_shown "$dir")" in
    "$class"|"ack:$class") return 0 ;;
  esac
  wid=$(lane_window_id "$dir") || return 0
  lane_paint_apply "$wid" "$class" || return 0
  printf '%s\n' "$class" > "$dir/.claude/tmux-paint" 2>/dev/null || true
}

# Acknowledge: you are looking at this lane, so stop flagging it. Fires on every
# window switch, which is why it clears before you have even answered the
# prompt — a tab you just left should not still be shouting. The lane's next
# genuine state change repaints as normal, so a lane that blocks again on
# something new goes red again.
#
# Only attention classes are acked. Acking `busy`/`idle` would write cache
# entries that suppress the first real block.
lane_paint_ack() {
  local dir=${1%/} class wid
  [ -d "$dir" ] || return 0
  class=$(lane_class "$(lane_state "$dir")")
  case "$class" in
    blocked|ext|review|done) ;;
    *) return 0 ;;
  esac
  [ "$(lane_paint_shown "$dir")" = "ack:$class" ] && return 0
  wid=$(lane_window_id "$dir") || return 0
  lane_paint_apply "$wid" idle || return 0
  printf 'ack:%s\n' "$class" > "$dir/.claude/tmux-paint" 2>/dev/null || true
}

# Sweep every live lane tab. Recovers tabs that were closed and respawned, or
# that a writer painted while the window did not yet exist, without resurrecting
# a flag you already acknowledged.
lane_paint_all() {
  local wid wpos wname dir class shown
  while IFS=$(printf '\t') read -r wid wpos wname dir; do
    [ -n "$wid" ] || continue
    class=$(lane_class "$(lane_state "$dir")")
    shown=$(lane_paint_shown "$dir")
    if [ "$shown" = "ack:$class" ]; then
      lane_paint_apply "$wid" idle
      continue
    fi
    lane_paint_apply "$wid" "$class" || continue
    printf '%s\n' "$class" > "$dir/.claude/tmux-paint" 2>/dev/null || true
  done <<EOF
$(lane_windows)
EOF
}

# lane_dir_for_window <window_id> -> the lane worktree that tab belongs to.
lane_dir_for_window() {
  local target=$1 wid wpos wname dir
  while IFS=$(printf '\t') read -r wid wpos wname dir; do
    [ "$wid" = "$target" ] && { printf '%s' "$dir"; return 0; }
  done <<EOF
$(lane_windows)
EOF
  return 1
}
