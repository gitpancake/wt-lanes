#!/usr/bin/env bash
# Thin launcher preserving the installed path contract
# (`watch -tcn2 ~/.tmux/agent-board.sh`). The board lives in agent-board.py;
# resolve through the install symlink to find it next to this file.
self="${BASH_SOURCE[0]}"
[[ -L "$self" ]] && self=$(readlink "$self")
exec python3 "$(cd "$(dirname "$self")" && pwd)/agent-board.py" "$@"
