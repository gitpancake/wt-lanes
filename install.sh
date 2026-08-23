#!/usr/bin/env bash
# wt-lanes installer.
#
# Symlinks bins, scripts, hooks, and the agent-board script into their canonical
# locations so the lane state machine works end-to-end:
#
#   bin/*                   →  ~/.local/bin/                (on PATH)
#   scripts/*               →  ~/.claude/scripts/           (called by absolute path)
#   hooks/*                 →  ~/.claude/hooks/             (registered in settings.json)
#   share/agent-state-vocab →  ~/.claude/agent-state-vocab.md
#   share/lane-windows.sh   →  ~/.claude/lane-windows.sh    (tab palette + lookup)
#   tmux/agent-board.sh     →  ~/.tmux/agent-board.sh       (pinned status board)
#   tmux/lane-menu.sh       →  ~/.tmux/lane-menu.sh         (lane jump menu)
#
# Then prints the Claude Code hook registration block to merge into
# ~/.claude/settings.json, plus a tmux snippet for the agent-board pane.
#
# Re-running is safe — every link is `ln -sfn`. Uninstall with ./uninstall.sh.
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROG=${0##*/}

log()  { printf '\033[1m[%s]\033[0m %s\n' "$PROG" "$*"; }
warn() { printf '\033[33m[%s]\033[0m %s\n' "$PROG" "$*" >&2; }

# Dependency probe — fail fast if anything mandatory is missing.
require() {
  local name=$1 hint=$2
  command -v "$name" >/dev/null 2>&1 || {
    warn "missing required dependency: $name"
    warn "  install hint: $hint"
    exit 1
  }
}
optional() {
  local name=$1 hint=$2
  command -v "$name" >/dev/null 2>&1 || warn "optional dep '$name' not found ($hint) — some features will degrade gracefully"
}

require git "https://git-scm.com"
require tmux "brew install tmux  /  apt install tmux"
require bash "shipped with your OS"
optional jq "brew install jq  /  apt install jq — used by the PreToolUse state hook to extract tool names; degrades to 'thinking'"
optional terminal-notifier "brew install terminal-notifier — macOS lane notifications"
optional notify-send "apt install libnotify-bin — linux lane notifications"

log "installing from $REPO_DIR"

link() {
  local src=$1 dst=$2
  mkdir -p "$(dirname "$dst")"
  ln -sfn "$src" "$dst"
  printf '  %s → %s\n' "$dst" "$src"
}

# bins → ~/.local/bin
for f in "$REPO_DIR"/bin/*; do
  [[ -e "$f" ]] || continue
  chmod +x "$f"
  link "$f" "$HOME/.local/bin/$(basename "$f")"
done

# scripts → ~/.claude/scripts
for f in "$REPO_DIR"/scripts/*; do
  [[ -e "$f" ]] || continue
  chmod +x "$f"
  link "$f" "$HOME/.claude/scripts/$(basename "$f")"
done

# hooks → ~/.claude/hooks
for f in "$REPO_DIR"/hooks/*; do
  [[ -e "$f" ]] || continue
  chmod +x "$f"
  link "$f" "$HOME/.claude/hooks/$(basename "$f")"
done

# share
link "$REPO_DIR/share/agent-state-vocab.md" "$HOME/.claude/agent-state-vocab.md"
link "$REPO_DIR/share/state-codes.sh" "$HOME/.claude/state-codes.sh"
link "$REPO_DIR/share/lane-windows.sh" "$HOME/.claude/lane-windows.sh"

# tmux agent-board + lane jump menu
link "$REPO_DIR/tmux/agent-board.sh" "$HOME/.tmux/agent-board.sh"
link "$REPO_DIR/tmux/lane-menu.sh" "$HOME/.tmux/lane-menu.sh"

cat <<'POST'

[install complete]

Two manual steps remain — these touch files wt-lanes shouldn't auto-edit:

1) Register the lane hooks in ~/.claude/settings.json
   ────────────────────────────────────────────────────
   Merge this block into the top-level "hooks" object (create it if absent):

   {
     "hooks": {
       "PreToolUse":     [{ "matcher": "*", "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/agent-state-active.sh" }] }],
       "Stop":           [
         { "matcher": "*", "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/agent-state-idle.sh" }] },
         { "matcher": "*", "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/precheck-stop.sh" }] }
       ],
       "Notification":   [{ "matcher": "*", "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/agent-state-waiting.sh" }] }]
     }
   }

   Restart any open Claude Code sessions for the registration to take effect.

2) Pin the agent-board pane in tmux
   ─────────────────────────────────
   Add to ~/.tmux.conf (or run as an interactive tmux command):

       bind A new-window -n agent-board 'watch -tcn2 ~/.tmux/agent-board.sh'
       bind a run-shell '~/.tmux/lane-menu.sh #{pane_id}'
       bind b run-shell '~/.tmux/lane-menu.sh --next'

   The after-select-window hook clears a lane's flag the moment you switch to
   its tab, instead of leaving it lit until that lane's next hook fires:

       set-hook -g after-select-window 'run-shell -b "~/.claude/scripts/lane-paint.sh --ack #{window_id}"'

   Reload tmux config:  tmux source-file ~/.tmux.conf
   Open the board:      prefix + A
   Jump to a lane:      prefix + a
   Next blocked lane:   prefix + b

[smoke test]
   wt --help
   ~/.tmux/agent-board.sh            # one-shot render
POST
