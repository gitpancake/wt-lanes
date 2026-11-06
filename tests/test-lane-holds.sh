#!/usr/bin/env bash
# lane-holds.sh: the hold daemon's three outcomes, with tmux and gh stubbed on
# PATH. The tmux stub keeps one window's @lane_class in a file so the daemon's
# own exit condition (no held tabs) is exercised for real.
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

export HOME="$TEST_TMP/home"
mkdir -p "$HOME/.claude/scripts" "$TEST_TMP/bin"
ln -s "$REPO_DIR/share/lane-windows.sh" "$HOME/.claude/lane-windows.sh"
ln -s "$REPO_DIR/share/state-codes.sh" "$HOME/.claude/state-codes.sh"
for s in lane-holds.sh lane-done.sh lane-paint.sh; do
  ln -s "$REPO_DIR/scripts/$s" "$HOME/.claude/scripts/$s"
done

lane="$TEST_TMP/repo/.claude/worktrees/held-lane"
mkdir -p "$lane/.claude"
git -C "$lane" init -q
printf 'held-lane\n' > "$lane/.claude/tmux-window"
class_file="$TEST_TMP/class"
status_file="$TEST_TMP/gate-status"
red_checks_file="$TEST_TMP/red-checks"
: > "$red_checks_file"

cat > "$TEST_TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "list-windows -a")
    case "\$*" in
      *lane_class*) printf '@1 %s\n' "\$(cat "$class_file")" ;;
      *)            printf '@1 held-lane\n' ;;
    esac ;;
  "list-panes -a") printf '@1|s:1|held-lane|$lane\n' ;;
  "list-panes -t") ;;
  "set-option -w")
    shift 4
    [[ "\$1" == "@lane_class" ]] && printf '%s\n' "\$2" > "$class_file"
    ;;
  "display-message -t") printf '@1\n' ;;
esac
exit 0
EOF
cat > "$TEST_TMP/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$1" in
  pr)
    case "\$*" in
      *statusCheckRollup*) cat "$red_checks_file" ;;
      *)                   printf '12\tabc123\n' ;;
    esac ;;
  repo) printf 'o/r\n' ;;
  api)  cat "$status_file" ;;
esac
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/bin/osascript"
chmod +x "$TEST_TMP/bin/"*
export PATH="$TEST_TMP/bin:$PATH"
export TMUX="stub"
export LANE_HOLDS_TICK=0.01 LANE_HOLDS_POLL_TICKS=2

run_daemon() {
  bash "$REPO_DIR/scripts/lane-holds.sh" >/dev/null 2>&1 &
  local pid=$! i=0
  while kill -0 "$pid" 2>/dev/null && (( i < 300 )); do sleep 0.05; i=$((i + 1)); done
  kill -0 "$pid" 2>/dev/null && { kill "$pid"; return 1; }
  return 0
}
state() { head -n1 "$lane/.claude/agent-state"; }

# --- no held tab: exits at once ------------------------------------------------
printf 'busy\n' > "$class_file"
run_daemon
assert_rc "exits when nothing is held" $? 0

# --- hold released: lane is DONE and the tab class is done ------------------------
printf 'WAITING:holland:PR #12 answered\n' > "$lane/.claude/agent-state"
printf 'hold\n' > "$class_file"
printf 'success\tapproved: ok\n' > "$status_file"
run_daemon
assert_rc "exits after the release" $? 0
assert_eq "released hold becomes DONE" "$(state)" "DONE"
assert_eq "tab class follows to done" "$(cat "$class_file")" "done"

# --- released on red CI: lane-done refuses, so the hold stands -------------------
printf 'WAITING:holland:PR #12 answered\n' > "$lane/.claude/agent-state"
printf 'hold\n' > "$class_file"
printf 'success\tapproved: ok\n' > "$status_file"
printf 'pr-checks\n' > "$red_checks_file"
bash "$REPO_DIR/scripts/lane-holds.sh" >/dev/null 2>&1 &
dpid=$!
sleep 0.5
kill "$dpid" 2>/dev/null; wait "$dpid" 2>/dev/null
assert_eq "a release on red CI keeps the hold" "$(state)" "WAITING:holland:PR #12 answered"
: > "$red_checks_file"

# --- hold still held: untouched --------------------------------------------------
printf 'WAITING:human:PR #12 schema\n' > "$lane/.claude/agent-state"
printf 'hold\n' > "$class_file"
printf 'failure\tneeds-human: schema change\n' > "$status_file"
bash "$REPO_DIR/scripts/lane-holds.sh" >/dev/null 2>&1 &
dpid=$!
sleep 0.5
kill "$dpid" 2>/dev/null; wait "$dpid" 2>/dev/null
assert_eq "a standing hold keeps its state" "$(state)" "WAITING:human:PR #12 schema"
assert_eq "a standing hold keeps its class" "$(cat "$class_file")" "hold"

# --- findings posted: red, acked on visit, and the daemon leaves ------------------
printf 'WAITING:prompt-owner:PR #12 awaiting abdul\n' > "$lane/.claude/agent-state"
printf 'hold\n' > "$class_file"
rm -f "$lane/.claude/tmux-paint"
printf 'failure\trevise: see comment\n' > "$status_file"
run_daemon
assert_rc "exits after findings land" $? 0
assert_eq "findings turn the hold red" "$(state)" "WAITING:input:prompt-owner-review posted findings on PR #12"
assert_eq "tab class follows to blocked" "$(cat "$class_file")" "blocked"

finish
