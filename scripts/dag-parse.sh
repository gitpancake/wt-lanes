#!/bin/bash
# dag-parse.sh <TICKET>
#
# Parses the slice DAG block out of ~/.claude/plans/<TICKET>.md.
# Block format (between markers, inside an HTML comment is fine):
#
#   <!-- slice-dag:start -->
#   slices:
#     - id: s1
#       name: schema migration
#       needs: []
#       touches: [packages/db/schema.ts]
#       user-visible: no
#       merge-safety: additive column
#     - id: s2
#       ...
#   <!-- slice-dag:end -->
#
# Emits one TSV row per slice:
#   id<TAB>name<TAB>needs(comma)<TAB>touches(comma)<TAB>user-visible<TAB>branch
#
# branch = <type>/<slug>-<id>, slug = lowercased ticket, type from WT_TYPE
# env (default: feature).
#
# Exit codes:
#   0  parsed OK, ≥1 slice
#   2  usage / no plan
#   3  no DAG block (old-format plan)
#   4  malformed DAG block

set -u

if [ $# -lt 1 ]; then
  printf 'usage: dag-parse.sh <TICKET-or-plan-path>\n' >&2
  exit 2
fi

arg=$1

# Allow either a ticket ID or an explicit plan path (for tests).
if [ -f "$arg" ]; then
  plan="$arg"
  base=$(basename "$arg" .md)
  ticket=$(printf '%s' "$base" | tr '[:lower:]' '[:upper:]')
else
  ticket=$(printf '%s' "$arg" | tr '[:lower:]' '[:upper:]')
  plan="$HOME/.claude/plans/${ticket}.md"
fi

slug=$(printf '%s' "$ticket" | tr '[:upper:]' '[:lower:]')
type_prefix="${WT_TYPE:-feature}"
type_prefix=$(printf '%s' "$type_prefix" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]//g')
[ -z "$type_prefix" ] && type_prefix="feature"

if [ ! -f "$plan" ]; then
  printf 'dag-parse: no plan at %s\n' "$plan" >&2
  exit 2
fi

# Extract block between markers. If absent, exit 3 (caller falls back).
block=$(awk '
  /<!-- slice-dag:start -->/ { inblock=1; next }
  /<!-- slice-dag:end -->/   { inblock=0; next }
  inblock { print }
' "$plan")

if [ -z "$block" ]; then
  exit 3
fi

# Minimal YAML parser: walk lines, track current slice record, flush on
# new "- id:" or EOF. Bash 3.2 — no associative arrays, just scalars.
out=$(printf '%s\n' "$block" | awk -v slug="$slug" -v type_prefix="$type_prefix" '
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  function strip_brackets(s) {
    s = trim(s)
    if (substr(s,1,1) == "[" && substr(s,length(s),1) == "]") s = substr(s, 2, length(s)-2)
    gsub(/[ \t]+/, "", s)
    return s
  }
  function flush() {
    if (id != "") {
      branch = type_prefix "/" slug "-" id
      # Empty fields → "-" sentinel so callers can use whitespace-IFS read.
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", id, name,
        (needs == "" ? "-" : needs),
        (touches == "" ? "-" : touches),
        (uv == "" ? "-" : uv),
        branch
    }
    id=""; name=""; needs=""; touches=""; uv=""
  }
  BEGIN { id=""; name=""; needs=""; touches=""; uv="" }
  /^[ \t]*#/  { next }       # comment
  /^[ \t]*$/  { next }       # blank
  /^slices:/  { next }       # header
  {
    line = $0
    # New slice record starts with "- id:"
    if (match(line, /^[ \t]*-[ \t]*id:[ \t]*/)) {
      flush()
      v = substr(line, RSTART+RLENGTH)
      id = trim(v)
      next
    }
    if (match(line, /^[ \t]*name:[ \t]*/))         { name = trim(substr(line, RSTART+RLENGTH)); next }
    if (match(line, /^[ \t]*needs:[ \t]*/))        { needs = strip_brackets(substr(line, RSTART+RLENGTH)); next }
    if (match(line, /^[ \t]*touches:[ \t]*/))      { touches = strip_brackets(substr(line, RSTART+RLENGTH)); next }
    if (match(line, /^[ \t]*user-visible:[ \t]*/)) { uv = trim(substr(line, RSTART+RLENGTH)); next }
    if (match(line, /^[ \t]*merge-safety:[ \t]*/)) { next }
  }
  END { flush() }
')

if [ -z "$out" ]; then
  printf 'dag-parse: malformed DAG block in %s\n' "$plan" >&2
  exit 4
fi

# Sanity: every row must have an id.
bad=$(printf '%s\n' "$out" | awk -F'\t' 'NF<6 || $1=="" { print NR }')
if [ -n "$bad" ]; then
  printf 'dag-parse: malformed rows in DAG block: %s\n' "$bad" >&2
  exit 4
fi

printf '%s\n' "$out"
