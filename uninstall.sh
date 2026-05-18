#!/usr/bin/env bash
# wt-lanes uninstaller — reverses install.sh. Only removes symlinks that point
# at this repo; leaves user-edited files and unrelated symlinks alone.
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROG=${0##*/}

unlink_if_ours() {
  local path=$1
  [[ -L "$path" ]] || return 0
  local target
  target=$(readlink "$path")
  case "$target" in
    "$REPO_DIR"/*) rm -f "$path"; printf '  removed %s\n' "$path" ;;
    *) printf '  skipped %s (points elsewhere)\n' "$path" ;;
  esac
}

for f in "$REPO_DIR"/bin/*;     do [[ -e "$f" ]] && unlink_if_ours "$HOME/.local/bin/$(basename "$f")";    done
for f in "$REPO_DIR"/scripts/*; do [[ -e "$f" ]] && unlink_if_ours "$HOME/.claude/scripts/$(basename "$f")"; done
for f in "$REPO_DIR"/hooks/*;   do [[ -e "$f" ]] && unlink_if_ours "$HOME/.claude/hooks/$(basename "$f")";   done
unlink_if_ours "$HOME/.claude/ralph"
unlink_if_ours "$HOME/.claude/agent-state-vocab.md"
unlink_if_ours "$HOME/.tmux/agent-board.sh"

cat <<'POST'

[uninstall complete]

Manual cleanup still needed (this script does not edit your settings):
  - Remove the hook registrations from ~/.claude/settings.json
  - Remove the `bind A new-window …` line from ~/.tmux.conf
  - Restart Claude Code sessions
POST
