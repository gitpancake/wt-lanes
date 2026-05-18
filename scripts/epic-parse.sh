#!/bin/bash
# epic-parse.sh <epic-slug-or-_epic.md-path>
#
# Projects the epic-stories block of an _epic.md into a Ralph prd.json on stdout.
# _epic.md is the durable source of truth; prd.json is generated, never authored.
# Mirrors dag-parse.sh in shape + exit-code discipline.
#
# Block format (between markers, plain text in the markdown — not inside a comment):
#
#   <!-- epic-stories:start -->
#   stories:
#     - id: 01-error-mapping
#       title: Adapter — typed error code mapping
#       needs: []
#       context: 01-error-mapping.md
#     - id: 02-attachment-handling
#       title: Adapter — attachment passthrough
#       needs: [01-error-mapping]
#       context: 02-attachment-handling.md
#   <!-- epic-stories:end -->
#
# For each story, acceptanceCriteria + description are read from the child file
# named by `context:` (resolved relative to the _epic.md directory). "Typecheck
# passes" is appended to acceptanceCriteria if no criterion mentions a typecheck.
# `needs` is preserved into the story's `notes` so ordering intent survives.
#
# Output: a prd.json object on stdout — {project, branchName, description,
# userStories[]} — exactly the schema ralph.sh consumes. branchName is left ""
# for the lane to stamp.
#
# Exit codes (mirrors dag-parse.sh):
#   0  parsed OK, >=1 story
#   2  usage / no epic file / jq missing
#   3  no epic-stories block
#   4  malformed block, or a story's context child file is missing

set -u

if [ $# -lt 1 ]; then
  printf 'usage: epic-parse.sh <epic-slug-or-_epic.md-path>\n' >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'epic-parse: jq is required but not on PATH\n' >&2
  exit 2
fi

arg=$1
tickets_dir="${TICKETS_DIR:-$HOME/.claude/tickets}"

# Accept either an explicit path to an _epic.md or a bare epic folder slug.
if [ -f "$arg" ]; then
  epic_file="$arg"
else
  epic_dir=$(find "$tickets_dir" -type d -name "$arg" 2>/dev/null | head -1)
  epic_file="$epic_dir/_epic.md"
fi

if [ ! -f "$epic_file" ]; then
  printf 'epic-parse: no _epic.md found for %s\n' "$arg" >&2
  exit 2
fi

epic_dir=$(cd "$(dirname "$epic_file")" && pwd)
slug=$(basename "$epic_dir")

# Epic-level description: the ## Goal section, falling back to frontmatter title.
description=$(awk '
  /^## Goal/        { f=1; next }
  /^## /            { f=0 }
  f && NF           { print }
' "$epic_file" | paste -sd' ' - | sed -E 's/^[ \t]+//; s/[ \t]+$//')
if [ -z "$description" ]; then
  description=$(awk '
    /^---[ \t]*$/   { fm++; next }
    fm == 1 && /^title:/ { sub(/^title:[ \t]*/, ""); print; exit }
    fm >= 2         { exit }
  ' "$epic_file")
fi

# Extract the epic-stories block. Absent → exit 3.
block=$(awk '
  /<!-- epic-stories:start -->/ { inblock=1; next }
  /<!-- epic-stories:end -->/   { inblock=0; next }
  inblock { print }
' "$epic_file")

if [ -z "$block" ]; then
  exit 3
fi

# Minimal YAML parse: one TSV row per story — id <TAB> title <TAB> needs <TAB> context.
# Bash 3.2 — scalars only, flush on each new "- id:".
rows=$(printf '%s\n' "$block" | awk '
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  function strip_brackets(s) {
    s = trim(s)
    if (substr(s,1,1) == "[" && substr(s,length(s),1) == "]") s = substr(s, 2, length(s)-2)
    gsub(/[ \t]+/, "", s)
    return s
  }
  function flush() {
    if (id != "") {
      printf "%s\t%s\t%s\t%s\n", id, title, (needs == "" ? "-" : needs), context
    }
    id=""; title=""; needs=""; context=""
  }
  BEGIN { id=""; title=""; needs=""; context="" }
  /^[ \t]*#/ { next }
  /^[ \t]*$/ { next }
  /^stories:/ { next }
  {
    line = $0
    if (match(line, /^[ \t]*-[ \t]*id:[ \t]*/))    { flush(); id = trim(substr(line, RSTART+RLENGTH)); next }
    if (match(line, /^[ \t]*title:[ \t]*/))        { title = trim(substr(line, RSTART+RLENGTH)); next }
    if (match(line, /^[ \t]*needs:[ \t]*/))        { needs = strip_brackets(substr(line, RSTART+RLENGTH)); next }
    if (match(line, /^[ \t]*context:[ \t]*/))      { context = trim(substr(line, RSTART+RLENGTH)); next }
  }
  END { flush() }
')

if [ -z "$rows" ]; then
  printf 'epic-parse: malformed epic-stories block in %s\n' "$epic_file" >&2
  exit 4
fi

# Build userStories[] one jq object at a time — jq handles all the escaping.
stories="[]"
priority=0
while IFS=$'\t' read -r id title needs context; do
  [ -z "$id" ] && continue
  priority=$((priority + 1))

  if [ -z "$context" ]; then
    printf 'epic-parse: story %s has no context: child file\n' "$id" >&2
    exit 4
  fi
  child="$epic_dir/$context"
  if [ ! -f "$child" ]; then
    printf 'epic-parse: story %s context child not found: %s\n' "$id" "$child" >&2
    exit 4
  fi

  # Acceptance criteria: bullet lines under "## Acceptance criteria", with
  # wrapped continuation lines joined back into their bullet.
  ac_lines=$(awk '
    function flush() { if (item != "") { print item; item = "" } }
    /^## Acceptance criteria/          { f=1; item=""; next }
    /^## /                             { flush(); f=0; next }
    f && /^[-*][ \t]+/                 { flush(); line=$0; sub(/^[-*][ \t]+/, "", line); item=line; next }
    f && /^[ \t]+[^ \t]/ && item != "" { line=$0; sub(/^[ \t]+/, "", line); item = item " " line; next }
    f && /^[ \t]*$/                    { flush(); next }
    END { flush() }
  ' "$child")
  ac_json=$(printf '%s\n' "$ac_lines" \
    | jq -R 'select(length > 0)' \
    | jq -s 'if any(.[]; test("[Tt]ypecheck")) then . else . + ["Typecheck passes"] end')

  # Description: the child's ## Context section, collapsed to one line.
  desc=$(awk '
    /^## Context/ { f=1; next }
    /^## /        { f=0 }
    f && NF       { print }
  ' "$child" | paste -sd' ' - | sed -E 's/^[ \t]+//; s/[ \t]+$//')

  [ "$needs" = "-" ] && notes="" || notes="needs: $needs"

  story=$(jq -n \
    --arg id "$id" \
    --arg title "$title" \
    --arg description "$desc" \
    --argjson acceptanceCriteria "$ac_json" \
    --argjson priority "$priority" \
    --arg notes "$notes" \
    '{
      id: $id,
      title: $title,
      description: $description,
      acceptanceCriteria: $acceptanceCriteria,
      priority: $priority,
      passes: false,
      notes: $notes
    }')
  stories=$(printf '%s' "$stories" | jq --argjson s "$story" '. + [$s]')
done <<< "$rows"

jq -n \
  --arg project "$slug" \
  --arg description "$description" \
  --argjson userStories "$stories" \
  '{
    project: $project,
    branchName: "",
    description: $description,
    userStories: $userStories
  }'
