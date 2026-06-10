#!/usr/bin/env bash
# agent-board — single-pane status board for parallel worktree agents.
#
# Pin in a tmux pane with:
#   watch -tcn2 ~/.tmux/agent-board.sh
#
# Reads <worktree>/.claude/agent-state (written by hook scripts) and prints
# one row per worktree, color-coded by state. Goes red when an agent needs
# attention; otherwise stays out of your way.

set -u

# Optional: pin the tmux window name so the cockpit pane stays labelled
# regardless of what foreground command (watch, etc.) is rendering it.
# Opt-in via $AGENT_BOARD_WINDOW_NAME so dev environments keep custom names.
if [[ -n "${TMUX:-}" && -n "${TMUX_PANE:-}" && -n "${AGENT_BOARD_WINDOW_NAME:-}" ]]; then
  tmux rename-window -t "$TMUX_PANE" "$AGENT_BOARD_WINDOW_NAME" 2>/dev/null || true
fi

# Roots scanned for worktrees. Add more as needed.
ROOTS=("${HOME}/Documents/code")

reset=$'\033[0m'
red=$'\033[31m'
green=$'\033[32m'
yellow=$'\033[33m'
dim=$'\033[2m'
bold=$'\033[1m'

# Cross-platform stat helpers (macOS -f vs Linux -c).
_stat_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
_stat_size()  { stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null || echo 0; }

# Reverse-cat: BSD has tail -r, GNU has tac. Probe once.
if tail -r /dev/null >/dev/null 2>&1; then
  _tail_reverse() { tail -r "$1" 2>/dev/null; }
else
  _tail_reverse() { tac "$1" 2>/dev/null; }
fi

# Named Python parsers for jsonl extraction.
_extract_ctx_tokens() {
  python3 -c '
import json,sys
try:
  d=json.loads(sys.stdin.read())
  u=(d.get("message") or {}).get("usage") or {}
  # Claude Code transcripts use Anthropic snake_case usage keys; Pi sessions
  # store provider-normalized camel-ish keys on the same message object.
  if any(k in u for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")):
    print((u.get("input_tokens") or 0)+(u.get("cache_read_input_tokens") or 0)+(u.get("cache_creation_input_tokens") or 0))
  else:
    print((u.get("input") or 0)+(u.get("cacheRead") or 0)+(u.get("cacheWrite") or 0))
except Exception:
  print("")
' 2>/dev/null
}

# Infer a compact state from a live Pi jsonl session. Pi does not currently
# write ~/.claude/sessions-style status JSON, so use the transcript tail plus
# jsonl freshness:
# tool call => RUNNING:<tool>, tool result/user prompt => ACTIVE, recently
# modified assistant message => ACTIVE (model is streaming/thinking), otherwise IDLE.
pi_state_from_jsonl() {
  local jsonl=$1
  [[ -f "$jsonl" ]] || { printf 'IDLE'; return; }
  python3 - "$jsonl" "${PI_ACTIVE_MTIME_SECS:-30}" <<'PY' 2>/dev/null || printf 'IDLE'
import json, os, sys, time
from collections import deque
path = sys.argv[1]
fresh_after = int(sys.argv[2])
is_fresh = (time.time() - os.path.getmtime(path)) <= fresh_after
last = None
with open(path, errors="ignore") as f:
    for line in deque(f, maxlen=80):
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("type") == "message":
            last = d.get("message") or {}
if not last:
    print("ACTIVE" if is_fresh else "IDLE")
    raise SystemExit
role = last.get("role")
content = last.get("content") or []
if role == "assistant":
    for part in content:
        if isinstance(part, dict) and part.get("type") == "toolCall":
            print("RUNNING:" + str(part.get("name") or "tool"))
            raise SystemExit
    print("ACTIVE" if is_fresh else "IDLE")
elif role in ("toolResult", "user"):
    print("ACTIVE")
else:
    print("ACTIVE" if is_fresh else "IDLE")
PY
}


now=$(date +%s)

# Reason-code vocab. Mirrors ~/.claude/agent-state-vocab.md.
# Returns class (red|yellow|dim) for a code, empty if unknown.
class_for_code() {
  case "$1" in
    ambiguity|creds|test-loop|merge-conflict|verify|scope|input) printf 'red' ;;
    external) printf 'yellow' ;;
    review)   printf 'dim' ;;
    *)        printf '' ;;
  esac
}

# Sort priority: lower number = higher up the board.
priority_for() {
  local state=$1 class=$2
  case "$state" in
    WAITING*)
      case "$class" in
        red)    printf '0' ;;
        yellow) printf '2' ;;
        dim)    printf '5' ;;
        *)      printf '0' ;;
      esac
      ;;
    FAILED*)  printf '1' ;;
    RUNNING*) printf '3' ;;
    ACTIVE*)  printf '4' ;;
    STALE*)   printf '5' ;;
    DONE)     printf '6' ;;
    IDLE)     printf '6' ;;
    *)        printf '4' ;;
  esac
}

shopt -s nullglob 2>/dev/null || true

# Pick newest *.jsonl under a Claude Code session dir.
newest_jsonl() {
  local sess_dir=$1
  [[ -d "$sess_dir" ]] || { printf ''; return; }
  ls -t "$sess_dir"/*.jsonl 2>/dev/null | head -n1
}

# Sum input + cache_read + cache_creation tokens from the last usage block in a
# jsonl file. Cached by jsonl mtime+size at $cache_file so 2s ticks stay cheap.
_ctx_from_jsonl() {
  local latest=$1 cache_file=$2
  [[ -n "$latest" && -f "$latest" ]] || { printf ''; return; }
  local mtime size
  mtime=$(_stat_mtime "$latest")
  size=$(_stat_size "$latest")
  if [[ -f "$cache_file" ]]; then
    local cmtime csize ctokens
    IFS=: read -r cmtime csize ctokens < "$cache_file"
    if [[ "$cmtime" == "$mtime" && "$csize" == "$size" ]]; then
      printf '%s' "$ctokens"
      return
    fi
  fi
  local tokens
  tokens=$(_tail_reverse "$latest" | grep -m1 '"usage"' | _extract_ctx_tokens)
  [[ -n "$tokens" ]] || tokens=0
  mkdir -p "$(dirname "$cache_file")" 2>/dev/null
  printf '%s:%s:%s\n' "$mtime" "$size" "$tokens" > "$cache_file" 2>/dev/null
  printf '%s' "$tokens"
}

# Live context size for a lane (worktree).
# Maps lane_dir → encoded session dir (~/.claude/projects/<dir>).
get_ctx_tokens() {
  local lane_dir=$1
  local enc=${lane_dir//\//-}
  enc=${enc//./-}
  local sess_dir="$HOME/.claude/projects/$enc"
  local latest cache_file
  latest=$(newest_jsonl "$sess_dir")
  [[ -n "$latest" ]] || { printf ''; return; }
  cache_file="$lane_dir/.claude/ctx-cache"
  _ctx_from_jsonl "$latest" "$cache_file"
}

fmt_ctx() {
  local n=${1:-}
  [[ -z "$n" || "$n" == 0 ]] && return
  if   (( n < 1000 ));    then printf '%d' "$n"
  elif (( n < 1000000 )); then printf '%dK' $((n/1000))
  else
    local tenths=$((n/100000))
    printf '%d.%dM' $((tenths/10)) $((tenths%10))
  fi
}

# Stale threshold for transient states (ACTIVE/WAITING/RUNNING) when no live
# claude PID is recorded. 5 minutes — long enough to outlast normal tool calls.
STALE_AFTER_SECS=300

# Hide IDLE rows older than this. Override with BOARD_HIDE_IDLE_AFTER=<secs>
# or BOARD_SHOW_ALL=1 to disable hiding.
HIDE_IDLE_AFTER=${BOARD_HIDE_IDLE_AFTER:-1800}

# Render one row to stdout, prefixed with sort key + tab so callers can sort.
render_row() {
  local state_file=$1 label=$2
  [[ -f "$state_file" ]] || return

  local lane_dir pid_file raw state state_mtime age c pid is_stale
  lane_dir=$(dirname "$(dirname "$state_file")")
  pid_file="$lane_dir/.claude/agent-pid"

  raw=$(tail -n1 "$state_file" 2>/dev/null || echo "—")
  state_mtime=$(_stat_mtime "$state_file")
  age=$((now - state_mtime))

  # Hide stale IDLE rows. Active/waiting/failed/done always render.
  if [[ -z "${BOARD_SHOW_ALL:-}" && "$raw" == "IDLE" && $age -gt $HIDE_IDLE_AFTER ]]; then
    return
  fi

  # Parse WAITING into code. Detail is in the state file (cat it if you care).
  # Board shows compact `W:<code>` only.
  local state=$raw class=""
  if [[ "$raw" =~ ^WAITING:([^:]+):(.*)$ ]]; then
    local code=${BASH_REMATCH[1]}
    class=$(class_for_code "$code")
    if [[ -n "$class" ]]; then
      state="W:${code}"
    else
      class=red
      state="W:input"
    fi
  elif [[ "$raw" =~ ^WAITING:(.+)$ ]]; then
    class=red
    state="W:input"
  fi

  # Liveness check.
  is_stale=0
  case "$raw" in
    ACTIVE*|WAITING*|RUNNING*)
      if [[ -f "$pid_file" ]]; then
        pid=$(cat "$pid_file" 2>/dev/null)
        if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
          is_stale=1
        fi
      elif (( age > STALE_AFTER_SECS )); then
        is_stale=1
      fi
      ;;
  esac

  if (( is_stale )); then
    # Self-heal: claude exited without firing Stop (terminal close, kill, crash).
    # Reset state to IDLE but preserve mtime so the hide-idle threshold
    # measures from when the lane actually went quiet, not when the board noticed.
    echo "IDLE" > "$state_file"
    touch -t "$(date -r "$state_mtime" '+%Y%m%d%H%M.%S')" "$state_file" 2>/dev/null || true
    rm -f "$pid_file"
    state="IDLE"
    c=$dim
    class=""
  else
    case "$state" in
      WAITING*)
        case "$class" in
          red)    c=$red ;;
          yellow) c=$yellow ;;
          dim)    c=$dim ;;
          *)      c=$red ;;
        esac
        ;;
      FAILED*)  c=$red ;;
      ACTIVE*)  c=$green ;;
      DONE)     c=$green ;;
      RUNNING*) c=$yellow ;;
      IDLE)     c=$dim ;;
      *)        c=$yellow ;;
    esac
  fi

  # Lane label preference:
  #  1. wt-written sentinel (<lane>/.claude/tmux-window) — authoritative.
  #  2. tmux window name via pid walk — only when sentinel missing.
  #  3. basename(lane_dir) — last resort.
  # The sentinel exists because tmux_window_for_pid can mis-label lanes whose
  # Claude pid lives in the cockpit window (manual launch or pane layout).
  local display=""
  if [[ -f "$lane_dir/.claude/tmux-window" ]]; then
    display=$(cat "$lane_dir/.claude/tmux-window" 2>/dev/null)
  fi
  if [[ -z "$display" ]]; then
    local lane_pid
    lane_pid=$(cat "$pid_file" 2>/dev/null)
    [[ -n "$lane_pid" ]] && display=$(tmux_window_for_pid "$lane_pid")
  fi
  [[ -z "$display" ]] && display=$(basename "$lane_dir")
  [[ -z "$display" ]] && display="$label"

  [[ ${#display} -gt 28 ]] && display="${display:0:25}..."

  local prio
  if (( is_stale )); then
    prio=5
  else
    prio=$(priority_for "$raw" "$class")
  fi

  local ctx ctx_disp
  ctx=$(get_ctx_tokens "$lane_dir")
  ctx_disp=$(fmt_ctx "$ctx")

  printf '%s\t%s%-29s %-18s %s%s\n' \
    "$prio" "$c" "$display" "$(state_short "$state")" "$ctx_disp" "$reset"
}

# Tmux pane_pid → window_name map, built once per render. Lets cockpit rows
# inherit the human-meaningful tmux window name instead of the cwd basename
# (e.g. `rescope:false-fail` vs `code`).
tmux_pane_map=""
if command -v tmux >/dev/null 2>&1; then
  tmux_pane_map=$(tmux list-panes -a -F '#{pane_pid}|#{window_name}' 2>/dev/null)
fi

# Reserved tmux window names that must never be treated as a lane label.
# Cockpit/board panes regularly host lane Claude processes (manual launch or
# pane layout) and would otherwise overwrite the real lane label.
TMUX_WINDOW_RESERVED=$'\ncockpit\nagent-board\nagents\n'
[[ -n "${AGENT_BOARD_WINDOW_NAME:-}" ]] && \
  TMUX_WINDOW_RESERVED+="${AGENT_BOARD_WINDOW_NAME}"$'\n'

# Walk parent chain of $1 until a pid matches a tmux pane_pid; print its window
# name. Skips reserved names (cockpit, agent-board, etc.) — those mean the pid
# lives in a shared pane, not a dedicated lane window.
tmux_window_for_pid() {
  local pid=$1
  [[ -n "$tmux_pane_map" ]] || return
  local cur=$pid hops=0 win
  while [[ -n "$cur" && "$cur" != 0 && "$cur" != 1 && $hops -lt 16 ]]; do
    win=$(printf '%s\n' "$tmux_pane_map" | awk -F'|' -v p="$cur" '$1==p{print $2; exit}')
    if [[ -n "$win" ]]; then
      if [[ "$TMUX_WINDOW_RESERVED" != *$'\n'"$win"$'\n'* ]]; then
        printf '%s' "$win"
        return
      fi
    fi
    cur=$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d ' ')
    hops=$((hops + 1))
  done
}

# Render a session-derived row. `bucket` is "lane", "lane-child", or "cockpit".
# - lane: worktree-backed parent, prefer tmux-window sentinel.
# - lane-child: nested under parent w/ `└ ` prefix.
# - cockpit: standalone, no nesting.
render_session_row() {
  local cwd=$1 state=$2 ctx_disp=${3:-} spid=${4:-} bucket=${5:-cockpit} source=${6:-claude}
  local c
  case "$state" in
    ACTIVE*)  c=$green ;;
    WAITING*) c=$red; state="W:input" ;;
    DONE)     c=$green ;;
    RUNNING*) c=$yellow ;;
    FAILED*)  c=$red ;;
    *)        c=$dim ;;
  esac

  local label=""
  if [[ "$bucket" == "lane" && -f "$cwd/.claude/tmux-window" ]]; then
    label=$(cat "$cwd/.claude/tmux-window" 2>/dev/null)
  fi
  [[ -z "$label" && -n "$spid" ]] && label=$(tmux_window_for_pid "$spid")
  [[ -z "$label" ]] && label=$(basename "$cwd")
  [[ "$source" == "pi" ]] && label="π $label"

  local prefix=""
  local width=29
  case "$bucket" in
    lane)
      [[ ${#label} -gt 28 ]] && label="${label:0:25}..."
      ;;
    lane-child)
      prefix="└ "
      [[ ${#label} -gt 26 ]] && label="${label:0:23}..."
      ;;
    *)
      [[ ${#label} -gt 28 ]] && label="${label:0:25}..."
      ;;
  esac

  local prio
  case "$state" in
    ACTIVE*)  prio=4 ;;
    WAITING*) prio=0 ;;
    *)        prio=6 ;;
  esac
  # Children inherit parent priority floor so they cluster under it.
  [[ "$bucket" == "lane-child" ]] && prio=5

  printf '%s\t%s%s%-*s %-18s %s%s\n' \
    "$prio" "$c" "$prefix" "$((width - ${#prefix}))" "$label" "$(state_short "$state")" "$ctx_disp" "$reset"
}

# A path under `*/.claude/worktrees/*` is structurally a lane; surface it
# under LANES even when no agent-state hook has run yet.
is_worktree_path() {
  [[ "$1" == */.claude/worktrees/* ]]
}

# Strip the prefix before the first ":" — STATE column reads cleaner.
# "ACTIVE:Edit" → "Edit", "W:input" → "input", "IDLE" → "IDLE".
state_short() {
  local s=$1
  [[ "$s" == *:* ]] && printf '%s' "${s#*:}" || printf '%s' "$s"
}

print_section_header() {
  local title=$1
  printf '%s%-29s %-18s %s%s\n' \
    "$bold" "$title" "STATE" "CTX" "$reset"
}

# Build covered_cwds while iterating lanes so cockpit dedupes correctly.
# Use newline-delimited strings (bash 3.2 has no associative arrays).
covered_cwds=$'\n'
note_covered() { covered_cwds+="$1"$'\n'; }
is_covered()   { [[ "$covered_cwds" == *$'\n'"$1"$'\n'* ]]; }

# Track parent prio per cwd so child rows cluster under their parent in the
# lane bucket sort (sort key: parent_prio, cwd, sub).
parent_prios=$'\n'
record_parent_prio() { parent_prios+="$1|$2"$'\n'; }
get_parent_prio() {
  local m
  m=$(printf '%s' "$parent_prios" | awk -F'|' -v c="$1" '$1==c{print $2; exit}')
  [[ -n "$m" ]] && printf '%s' "$m" || printf '6'
}

# Compose lane row w/ grouping key. `pre_row` is "<prio>\t<rendered>" from
# render_row / render_session_row. We strip its prio prefix and re-emit with
# composite key for stable parent-then-children sorting.
add_lane_row() {
  local cwd=$1 sub=$2 pre_row=$3 prio_override=${4:-}
  local row_prio=${pre_row%%$'\t'*}
  local row_rest=${pre_row#*$'\t'}
  local group_prio=${prio_override:-$row_prio}
  if [[ "$sub" == "0" ]]; then
    record_parent_prio "$cwd" "$group_prio"
  fi
  lane_rows+="${group_prio}"$'\t'"${cwd}"$'\t'"${sub}"$'\t'"${row_rest}"$'\n'
}

# --- Pre-pass: collect every live Claude + Pi session, sorted by cwd then spid. ---
# Row schema: cwd<TAB>pid<TAB>session-file<TAB>source (claude|pi)
sessions_raw=$(python3 <<'PY' 2>/dev/null
import glob, json, os, signal, subprocess
from pathlib import Path
home = Path.home()

def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except Exception:
        return False

# Claude Code exposes a small live-session registry with pid/cwd/status.
for path in glob.glob(str(home / ".claude" / "sessions" / "*.json")):
    try:
        data = json.load(open(path))
        pid = int(data.get("pid") or 0)
        cwd = data.get("cwd") or ""
    except Exception:
        continue
    if pid and cwd and alive(pid):
        print(f"{cwd}\t{pid}\t{path}\tclaude")

# Pi currently only persists jsonl transcripts. Pair live `pi` processes with
# their cwd, then attach the newest jsonl whose session header has that cwd.
pi_sessions = {}
for path in glob.glob(str(home / ".pi" / "agent" / "sessions" / "*" / "*.jsonl")):
    try:
        with open(path, errors="ignore") as f:
            first = json.loads(f.readline() or "{}")
        cwd = first.get("cwd") or ""
        if first.get("type") != "session" or not cwd:
            continue
        mtime = os.path.getmtime(path)
    except Exception:
        continue
    old = pi_sessions.get(cwd)
    if not old or mtime > old[0]:
        pi_sessions[cwd] = (mtime, path)

try:
    ps = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True)
except Exception:
    ps = ""
for line in ps.splitlines():
    parts = line.strip().split(None, 1)
    if len(parts) != 2 or parts[1] != "pi":
        continue
    try:
        pid = int(parts[0])
        lsof = subprocess.check_output(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"], text=True, stderr=subprocess.DEVNULL)
        cwd = next((l[1:] for l in lsof.splitlines() if l.startswith("n")), "")
    except Exception:
        continue
    sess = pi_sessions.get(cwd)
    if cwd and sess and alive(pid):
        print(f"{cwd}\t{pid}\t{sess[1]}\tpi")
PY
)
sessions_sorted=$(printf '%s' "$sessions_raw" | grep -v '^$' | sort -t$'\t' -k1,1 -k2,2n)

live_cwds=$'\n'
while IFS=$'\t' read -r scwd _ _ _; do
  [[ -n "$scwd" ]] && live_cwds+="$scwd"$'\n'
done <<< "$sessions_sorted"
cwd_alive() { [[ "$live_cwds" == *$'\n'"$1"$'\n'* ]]; }

# --- Enumerate every lane cwd (worktree dir on disk OR live session in one). ---
lane_cwds=$'\n'
add_lane_cwd() {
  [[ "$lane_cwds" == *$'\n'"$1"$'\n'* ]] || lane_cwds+="$1"$'\n'
}
for root in "${ROOTS[@]}"; do
  for wt in "$root"/*/.claude/worktrees/*/; do
    [[ -d "$wt" ]] && add_lane_cwd "${wt%/}"
  done
done
while IFS=$'\t' read -r scwd _ _ _; do
  [[ -n "$scwd" ]] && is_worktree_path "$scwd" && add_lane_cwd "$scwd"
done <<< "$sessions_sorted"
is_lane_cwd() { [[ "$lane_cwds" == *$'\n'"$1"$'\n'* ]]; }

# Resolve a lane's parent via the `.claude/parent-cwd` sentinel written at
# `wt` spawn. Empty if no sentinel, parent isn't a known lane, or parent
# is the lane itself (defensive).
parent_lane_of() {
  local f="$1/.claude/parent-cwd"
  [[ -f "$f" ]] || return
  local p
  p=$(head -n1 "$f" 2>/dev/null | tr -d '\n')
  [[ -n "$p" && "$p" != "$1" ]] && is_lane_cwd "$p" && printf '%s' "$p"
}

# Render one lane's row data (prio-prefixed). Prefers state-file rendering;
# falls back to session-registry when no state file exists. Returns empty on
# no signal at all (no state file + no live session).
render_lane_for() {
  local lcwd=$1 bucket=$2
  local state_file="$lcwd/.claude/agent-state"
  local has_live_pi=""
  has_live_pi=$(printf '%s' "$sessions_sorted" | awk -F'\t' -v c="$lcwd" '$1==c && $4=="pi"{print 1; exit}')
  if [[ "$bucket" == "lane" && -f "$state_file" && -z "$has_live_pi" ]]; then
    local name repo
    name=$(basename "$lcwd")
    repo=$(basename "$(dirname "$(dirname "$(dirname "$lcwd")")")")
    render_row "$state_file" "$repo/$name"
    return
  fi

  # Session-derived path. Primary pid: agent-pid (if alive) else oldest spid.
  local pid sess_json source
  if [[ -n "$has_live_pi" ]]; then
    # Prefer the Pi process over a stale/alive Claude agent-pid sentinel for the
    # same lane; otherwise the old .claude/agent-state masks Pi activity.
    pid=$(printf '%s' "$sessions_sorted" | awk -F'\t' -v c="$lcwd" '$1==c && $4=="pi"{print $2; exit}')
  else
    pid=$(cat "$lcwd/.claude/agent-pid" 2>/dev/null)
  fi
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    pid=$(printf '%s' "$sessions_sorted" | awk -F'\t' -v c="$lcwd" '$1==c{print $2; exit}')
  fi
  [[ -z "$pid" ]] && return
  sess_json=$(printf '%s' "$sessions_sorted" | awk -F'\t' -v p="$pid" '$2==p{print $3; exit}')
  source=$(printf '%s' "$sessions_sorted" | awk -F'\t' -v p="$pid" '$2==p{print $4; exit}')
  [[ -z "$source" ]] && source=claude

  local sstate=""
  if [[ "$source" != "pi" ]]; then
    [[ -f "$lcwd/.claude/sessions/$pid" ]] && sstate=$(cat "$lcwd/.claude/sessions/$pid" 2>/dev/null)
    if [[ -z "$sstate" && -f "$state_file" ]]; then
      sstate=$(tail -n1 "$state_file" 2>/dev/null)
    fi
  fi
  if [[ -z "$sstate" && -f "$sess_json" ]]; then
    if [[ "$source" == "pi" ]]; then
      sstate=$(pi_state_from_jsonl "$sess_json")
    else
      local sstatus
      sstatus=$(grep -o '"status":"[^"]*"' "$sess_json" | head -1 | sed 's/"status":"//;s/"//')
      [[ "$sstatus" == "busy" ]] && sstate="ACTIVE" || sstate="IDLE"
    fi
  fi
  [[ -z "$sstate" ]] && sstate="IDLE"

  local ctx_disp=""
  if [[ -f "$sess_json" ]]; then
    local sid enc jsonl_path cache_file
    if [[ "$source" == "pi" ]]; then
      cache_file="$sess_json.ctx-cache"
      ctx_disp=$(fmt_ctx "$(_ctx_from_jsonl "$sess_json" "$cache_file")")
    else
      sid=$(grep -o '"sessionId":"[^"]*"' "$sess_json" | head -1 | sed 's/"sessionId":"//;s/"//')
      if [[ -n "$sid" ]]; then
        enc=${lcwd//\//-}; enc=${enc//./-}
        jsonl_path="$HOME/.claude/projects/$enc/$sid.jsonl"
        if [[ -f "$jsonl_path" ]]; then
          cache_file="$HOME/.claude/projects/$enc/.ctx-cache-$sid"
          ctx_disp=$(fmt_ctx "$(_ctx_from_jsonl "$jsonl_path" "$cache_file")")
        fi
      fi
    fi
  fi

  render_session_row "$lcwd" "$sstate" "$ctx_disp" "$pid" "$bucket" "$source"
}

# --- Phase 1: parent lanes (no parent-cwd sentinel pointing to another lane). ---
lane_rows=""
lane_count=0
while IFS= read -r lcwd; do
  [[ -z "$lcwd" ]] && continue
  [[ -n "$(parent_lane_of "$lcwd")" ]] && continue
  row=$(render_lane_for "$lcwd" lane)
  [[ -z "$row" ]] && continue
  note_covered "$lcwd"
  add_lane_row "$lcwd" "0" "$row"
  lane_count=$((lane_count + 1))
done <<< "${lane_cwds#$'\n'}"

# --- Phase 2: child lanes nest under their parent. ---
while IFS= read -r lcwd; do
  [[ -z "$lcwd" ]] && continue
  parent=$(parent_lane_of "$lcwd")
  [[ -z "$parent" ]] && continue
  row=$(render_lane_for "$lcwd" lane-child)
  [[ -z "$row" ]] && continue
  note_covered "$lcwd"
  # sub="1" places child after its sub="0" parent under the numeric sort.
  # Multiple children for the same parent are rare today; if needed, swap
  # to a numeric spid here for stable ordering.
  add_lane_row "$parent" "1" "$row" "$(get_parent_prio "$parent")"
  lane_count=$((lane_count + 1))
done <<< "${lane_cwds#$'\n'}"

# --- Phase 3: cockpit — live sessions whose cwd is not a lane. ---
cockpit_rows=""
cockpit_count=0
while IFS=$'\t' read -r scwd spid sess_json source; do
  [[ -n "$scwd" && -n "$spid" && -f "$sess_json" ]] || continue
  [[ -z "$source" ]] && source=claude
  is_lane_cwd "$scwd" && continue

  sstate=""
  [[ -f "$scwd/.claude/sessions/$spid" ]] && sstate=$(cat "$scwd/.claude/sessions/$spid" 2>/dev/null)
  if [[ -z "$sstate" ]]; then
    if [[ "$source" == "pi" ]]; then
      sstate=$(pi_state_from_jsonl "$sess_json")
    else
      sstatus=$(grep -o '"status":"[^"]*"' "$sess_json" | head -1 | sed 's/"status":"//;s/"//')
      [[ "$sstatus" == "busy" ]] && sstate="ACTIVE" || sstate="IDLE"
    fi
  fi

  ctx_disp=""
  if [[ "$source" == "pi" ]]; then
    cache_file="$sess_json.ctx-cache"
    ctx_disp=$(fmt_ctx "$(_ctx_from_jsonl "$sess_json" "$cache_file")")
  else
    sid=$(grep -o '"sessionId":"[^"]*"' "$sess_json" | head -1 | sed 's/"sessionId":"//;s/"//')
    if [[ -n "$sid" ]]; then
      enc=${scwd//\//-}; enc=${enc//./-}
      jsonl_path="$HOME/.claude/projects/$enc/$sid.jsonl"
      if [[ -f "$jsonl_path" ]]; then
        cache_file="$HOME/.claude/projects/$enc/.ctx-cache-$sid"
        ctx_disp=$(fmt_ctx "$(_ctx_from_jsonl "$jsonl_path" "$cache_file")")
      fi
    fi
  fi

  cockpit_count=$((cockpit_count + 1))
  cockpit_rows+=$(render_session_row "$scwd" "$sstate" "$ctx_disp" "$spid" cockpit "$source")$'\n'
done <<< "$sessions_sorted"

if (( lane_count == 0 && cockpit_count == 0 )); then
  printf '%s(no worktrees or active cockpit sessions)%s\n' "$dim" "$reset"
  exit 0
fi

print_section_header "LANES"
if (( lane_count > 0 )); then
  # Lane records: <prio>\t<cwd>\t<sub>\t<row>. Sort groups parent (sub=0)
  # with its children (sub=spid asc), and clusters cwds by parent prio.
  printf '%s' "$lane_rows" | grep -v '^$' \
    | sort -t$'\t' -k1,1n -k2,2 -k3,3n \
    | cut -f4-
else
  printf '%s(none)%s\n' "$dim" "$reset"
fi

if (( cockpit_count > 0 )); then
  printf '\n'
  print_section_header "COCKPIT"
  printf '%s' "$cockpit_rows" | grep -v '^$' | sort -k1,1n | cut -f2-
fi
