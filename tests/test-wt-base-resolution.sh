#!/usr/bin/env bash
# wt lane-base resolution when cockpit is parked on the default branch (dry-run).
# Covers the three relationships between local HEAD and origin/<default>:
# behind-only, ahead-only (deliberately unpushed), and DIVERGED (2026-07-02:
# every pickup lane forked off a local main 11 commits behind origin because
# the diverged case fell through to the ahead-only "use HEAD" branch).
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

WT="$REPO_DIR/bin/wt"
export TICKETS_DIR="$TEST_TMP/tickets"
export WT_DRY_RUN=1 WT_NO_FETCH=1
unset WT_TICKET_SYNC WT_TYPE 2>/dev/null || true

origin="$TEST_TMP/origin.git"
git init -q --bare -b main "$origin"

seed="$TEST_TMP/seed"
git clone -q "$origin" "$seed"
git -C "$seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m A
git -C "$seed" push -q origin main

repo="$TEST_TMP/repo"
git clone -q "$origin" "$repo"
repo=$(cd "$repo" && pwd -P)

# --- behind-only: local main == origin/main, origin then advances ----------
git -C "$seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m B
git -C "$seed" push -q origin main
git -C "$repo" fetch -q origin
out=$(cd "$repo" && "$WT" behind-case)
assert_contains "behind-only bases off origin/main" "$out" "base:     origin/main"

# Bring local main level with origin/main before testing ahead-only — fetch
# alone only advances the remote-tracking ref, not the checked-out branch.
git -C "$repo" merge -q --ff-only origin/main

# --- ahead-only: local main gets a local-only commit, origin unchanged -----
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m local-ahead
out=$(cd "$repo" && "$WT" ahead-case)
assert_contains "ahead-only (deliberately unpushed) bases off HEAD" "$out" "base:     HEAD"

# --- diverged: origin advances again while local still has its own commit --
git -C "$seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m C
git -C "$seed" push -q origin main
git -C "$repo" fetch -q origin
err=$(cd "$repo" && "$WT" diverged-case 2>&1 >/dev/null)
out=$(cd "$repo" && "$WT" diverged-case 2>/dev/null)
assert_contains "diverged bases off origin/main, not stale local HEAD" "$out" "base:     origin/main"
assert_contains "diverged prints a DIVERGED warning" "$err" "DIVERGED"

finish
