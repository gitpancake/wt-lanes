#!/usr/bin/env bash
# wt --print-brief: the slug/linear-id/epic/tombstone resolution table.
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

WT="$REPO_DIR/bin/wt"
export TICKETS_DIR="$TEST_TMP/tickets"
mkdir -p "$TICKETS_DIR/auth"

brief="$TICKETS_DIR/auth/auth-refactor.md"
printf -- '---\ntitle: Auth refactor\nlinear: TEAM-1234\n---\nbody\n' > "$brief"

out=$("$WT" --print-brief auth-refactor)
assert_rc "slug hit -> rc 0" $? 0
assert_eq "slug -> brief path" "$out" "$brief"

out=$("$WT" --print-brief TEAM-1234)
assert_eq "linear id (frontmatter) -> brief path" "$out" "$brief"

out=$("$WT" --print-brief team-1234)
assert_eq "linear id is case-insensitive" "$out" "$brief"

mkdir -p "$TICKETS_DIR/billing/billing-epic"
printf '# epic\n' > "$TICKETS_DIR/billing/billing-epic/_epic.md"
out=$("$WT" --print-brief billing-epic)
assert_eq "epic folder -> _epic.md" "$out" "$TICKETS_DIR/billing/billing-epic/_epic.md"

mkdir -p "$TICKETS_DIR/new"
target="$TICKETS_DIR/new/auth-refactor-v2.md"
printf '# moved brief\n' > "$target"
printf 'moved -> %s\n' "$target" > "$TICKETS_DIR/auth/old-name.md"
out=$("$WT" --print-brief old-name)
assert_eq "tombstone followed to target" "$out" "$target"

"$WT" --print-brief nothing-matches-this >/dev/null 2>&1
assert_rc "miss -> rc 1" $? 1

finish
