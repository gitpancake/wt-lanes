#!/usr/bin/env bash
# dag-parse.sh: exit-code contract + TSV shape.
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

DP="$REPO_DIR/scripts/dag-parse.sh"

HOME="$TEST_TMP" "$DP" TEAM-1 >/dev/null 2>&1
assert_rc "missing plan -> rc 2" $? 2

plan="$TEST_TMP/noblock.md"
printf '# title\nno dag here\n' > "$plan"
"$DP" "$plan" >/dev/null 2>&1
assert_rc "no slice-dag block -> rc 3" $? 3

plan="$TEST_TMP/TEAM-7.md"
cat > "$plan" <<'EOF'
# TEAM-7 — Do the thing

<!-- slice-dag:start -->
slices:
  # a comment line
  - id: s1
    name: schema migration
    needs: []
    touches: [packages/db/schema.ts]
    user-visible: no
    merge-safety: additive column
  - id: s2
    name: api endpoint
    needs: [s1]
    touches: [apps/api/foo.ts, packages/db/schema.ts]
    user-visible: yes
<!-- slice-dag:end -->
EOF

out=$("$DP" "$plan")
assert_rc "well-formed -> rc 0" $? 0
assert_eq "two slices, two rows" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 2

row1=$(printf '%s\n' "$out" | sed -n 1p)
assert_eq "row1: empty needs -> '-' sentinel, branch from ticket" \
  "$row1" "$(printf 's1\tschema migration\t-\tpackages/db/schema.ts\tno\tfeature/team-7-s1')"

row2=$(printf '%s\n' "$out" | sed -n 2p)
assert_eq "row2: needs joined"   "$(printf '%s' "$row2" | cut -f3)" "s1"
assert_eq "row2: touches joined" "$(printf '%s' "$row2" | cut -f4)" "apps/api/foo.ts,packages/db/schema.ts"
assert_eq "row2: user-visible"   "$(printf '%s' "$row2" | cut -f5)" "yes"

out=$(WT_TYPE=fix "$DP" "$plan")
assert_contains "WT_TYPE stamps branch prefix" "$out" "fix/team-7-s1"

plan="$TEST_TMP/bad.md"
cat > "$plan" <<'EOF'
<!-- slice-dag:start -->
slices:
  - name: nameless slice without an id
    touches: [a.ts]
<!-- slice-dag:end -->
EOF
"$DP" "$plan" >/dev/null 2>&1
assert_rc "block with no ids -> rc 4" $? 4

finish
