#!/usr/bin/env bash
# wt-lanes installer.
#
# Symlinks bins, scripts, hooks, and the agent-board script into their canonical
# locations so the lane state machine works end-to-end:
#
#   bin/*                   →  ~/.local/bin/                (on PATH)
#   scripts/*               →  ~/.claude/scripts/           (called by absolute path)
#   hooks/*                 →  ~/.claude/hooks/             (registered in settings.json)
#   share/ralph             →  ~/.claude/ralph              (read by ralph-bootstrap)
#   share/agent-state-vocab →  ~/.claude/agent-state-vocab.md
#   tmux/agent-board.sh     →  ~/.tmux/agent-board.sh       (pinned status board)
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
optional jq "brew install jq  /  apt install jq — needed for the settings.json auto-merger"
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
link "$REPO_DIR/share/ralph" "$HOME/.claude/ralph"
link "$REPO_DIR/share/agent-state-vocab.md" "$HOME/.claude/agent-state-vocab.md"

# tmux agent-board
link "$REPO_DIR/tmux/agent-board.sh" "$HOME/.tmux/agent-board.sh"

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

   Reload tmux config:  tmux source-file ~/.tmux.conf
   Open the board:      prefix + A

[smoke test]
   wt --help
   ~/.tmux/agent-board.sh            # one-shot render
POST
