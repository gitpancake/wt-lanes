#!/usr/bin/env bash
# Tag a lane's pause reason before stopping for human input.
#
# Usage: lane-pause.sh <code> <detail>
#   code:   one of the codes in agent-state-vocab.md
#   detail: free text, single line, truncated to fit
#
# Writes WAITING:<code>:<detail> to <CLAUDE_PROJECT_DIR>/.claude/agent-state.

set -u

source "$HOME/.claude/hooks/_state-write.sh"

VALID_CODES=(ambiguity creds test-loop merge-conflict verify scope external review input)

usage() {
  printf 'usage: lane-pause.sh <code> <detail>\n' >&2
  printf 'codes: %s\n' "${VALID_CODES[*]}" >&2
  printf 'see ~/.claude/agent-state-vocab.md\n' >&2
}

if (( $# < 2 )); then
  usage
  exit 2
fi

code=$1
shift
detail=$*

valid=0
for c in "${VALID_CODES[@]}"; do
  [[ "$code" == "$c" ]] && valid=1 && break
done

if (( ! valid )); then
  printf 'lane-pause: unknown code %q\n' "$code" >&2
  printf 'valid: %s\n' "${VALID_CODES[*]}" >&2
  exit 2
fi

# Strip newlines, collapse whitespace, then truncate. Cap so the full
# "WAITING:<code>:<detail>" line stays under ~200 chars.
detail=$(printf '%s' "$detail" | tr '\n' ' ' | tr -s ' ')
max_detail=$((180 - ${#code}))
if (( ${#detail} > max_detail )); then
  detail="${detail:0:max_detail}"
fi

write_state "WAITING:${code}:${detail}"
