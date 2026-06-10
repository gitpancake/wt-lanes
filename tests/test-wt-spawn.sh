#!/usr/bin/env bash
# wt single-lane spawn (dry-run): slug/branch derivation + kickoff selection.
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

WT="$REPO_DIR/bin/wt"
export TICKETS_DIR="$TEST_TMP/tickets"
export WT_DRY_RUN=1 WT_NO_FETCH=1
unset WT_TICKET_SYNC WT_TYPE 2>/dev/null || true

repo="$TEST_TMP/repo"
git init -q -b main "$repo"
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
repo=$(cd "$repo" && pwd -P)

out=$(cd "$repo" && "$WT" --type fix my-feature)
assert_contains "dry-run banner" "$out" "wt[dry-run]"
assert_contains "--type stamps branch prefix" "$out" "branch:   fix/my-feature"
assert_contains "slug passthrough" "$out" "slug:     my-feature"
assert_contains "worktree under .claude/worktrees" "$out" "$repo/.claude/worktrees/my-feature"

out=$(cd "$repo" && "$WT" MixedCase)
assert_contains "slug lowercased" "$out" "slug:     mixedcase"
assert_contains "default type prefix" "$out" "branch:   feature/mixedcase"

out=$(cd "$repo" && "$WT" TEAM-9999)
assert_contains "ticket without brief -> scope-first kickoff" "$out" "No brief found for TEAM-9999"
assert_contains "ticket slug lowercased" "$out" "slug:     team-9999"

mkdir -p "$TICKETS_DIR/area"
printf -- '---\ntitle: My feature\n---\nbody\n' > "$TICKETS_DIR/area/my-feature.md"
out=$(cd "$repo" && "$WT" my-feature)
assert_contains "brief found -> brief-driven kickoff" "$out" "Brief at $TICKETS_DIR/area/my-feature.md"

out=$(cd "$repo" && "$WT" --branch feature/existing-pr my-feature)
assert_contains "--branch overrides derived branch" "$out" "branch:   feature/existing-pr"

cd "$TEST_TMP"
"$WT" --branch x --dag TEAM-1 >/dev/null 2>&1
assert_rc "--branch + --dag rejected" $? 1

finish
