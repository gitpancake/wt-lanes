#!/usr/bin/env bash
# lane-menu — one keystroke to see every lane's state and jump straight to one.
#
# Usage (from ~/.tmux.conf):
#   bind a    run-shell '~/.tmux/lane-menu.sh #{pane_id}'   # the menu
#   bind -n M-b run-shell '~/.tmux/lane-menu.sh --next'     # next blocked lane
#
# Replaces cycling prefix+<number> through tabs to find out who needs you:
# rows are sorted blockers-first and carry the pause code plus the free-text
# detail the lane stopped on, so the menu usually answers the question without
# a jump at all. Arrow keys navigate; the per-row letter jumps directly.
#
# --next cycles through blocked lanes only, skipping the one you are on, so
# holding the key walks the queue and never sticks on the current tab.
#
# Opening the menu resyncs every lane tab's colour first — a cheap moment to
# recover tabs that were closed and respawned behind lane-paint's cache.

set -u

source "$HOME/.claude/lane-windows.sh"

# Lane rows as "<prio>|<sortkey>|<window_id>|<class>|<name>|<tag>|<detail>",
# sorted so the lane that needs you is first.
lane_rows() {
  local wid wpos wname dir raw class
  while IFS=$(printf '\t') read -r wid wpos wname dir; do
    [ -n "$wid" ] || continue
    raw=$(lane_state "$dir")
    class=$(lane_class "$raw")
    printf '%s|%s|%s|%s|%s|%s|%s\n' \
      "$(lane_prio "$class")" "$wpos" "$wid" "$class" "$wname" \
      "$(lane_state_tag "$raw")" "$(lane_state_detail "$raw")"
  done <<EOF
$(lane_windows)
EOF
}

sorted_rows() { lane_rows | sort -t'|' -k1,1n -k2,2V; }

class_colour() {
  case "$1" in
    blocked) printf '#ea6962' ;;
    ext)     printf '#d8a657' ;;
    review)  printf '#7daea3' ;;
    done)    printf '#a9b665' ;;
    busy)    printf '#d4be98' ;;
    *)       printf '#7c6f64' ;;
  esac
}

truncate_to() {
  local text=$1 max=$2
  if [ ${#text} -gt "$max" ]; then
    printf '%s...' "$(printf '%s' "$text" | cut -c1-$((max - 3)))"
  else
    printf '%s' "$text"
  fi
}

# --- next blocked lane -----------------------------------------------------

jump_next() {
  local current first target prio wpos wid rest
  current=$(tmux display-message -p '#{window_id}' 2>/dev/null || printf '')
  first=""; target=""
  while IFS='|' read -r prio wpos wid rest; do
    [ "$prio" = "0" ] || continue
    [ -n "$first" ] || first=$wid
    if [ -z "$target" ] && [ "$wid" != "$current" ]; then
      target=$wid
    fi
  done <<EOF
$(sorted_rows)
EOF
  [ -n "$target" ] || target=$first
  if [ -z "$target" ]; then
    tmux display-message "no lane is blocked on you" 2>/dev/null
    return 0
  fi
  tmux select-window -t "$target" 2>/dev/null
}

# --- menu ------------------------------------------------------------------

show_menu() {
  local target_pane=${1:-} keys="asdfghjklqweruiopvnm" ki=0
  local args prio wpos wid class wname tag detail key label colour
  args=""
  lane_paint_all

  while IFS='|' read -r prio wpos wid class wname tag detail; do
    [ -n "$wid" ] || continue
    key=${keys:$ki:1}
    [ -n "$key" ] || key="-"
    ki=$((ki + 1))
    colour=$(class_colour "$class")
    label=$(printf '%s %-22s %-11s %s' \
      "$(lane_class_glyph "$class")" \
      "$(truncate_to "$wname" 22)" \
      "$(truncate_to "$tag" 11)" \
      "$(truncate_to "$detail" 42)")
    args="$args $(printf '%q' "#[fg=$colour]$label") $(printf '%q' "$key") $(printf '%q' "select-window -t $wid")"
  done <<EOF
$(sorted_rows)
EOF

  if [ -z "$args" ]; then
    tmux display-message "no lanes running" 2>/dev/null
    return 0
  fi

  local target_arg=""
  [ -n "$target_pane" ] && target_arg="-t $(printf '%q' "$target_pane")"
  eval tmux display-menu -x C -y C $target_arg \
    -T "'#[align=centre,fg=#d4be98,bold] lanes '" "$args"
}

case "${1:-}" in
  --next) jump_next ;;
  *)      show_menu "${1:-}" ;;
esac
exit 0
