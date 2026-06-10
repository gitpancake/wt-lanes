#!/usr/bin/env python3
"""agent-board — single-pane status board for parallel worktree agents.

Pin in a tmux pane with:
    watch -tcn2 ~/.tmux/agent-board.sh

Reads <worktree>/.claude/agent-state (written by the wt-lanes hooks) plus the
live Claude/Pi session registries, and prints one row per lane/cockpit
session, color-coded by state. Red = needs attention; otherwise it stays out
of your way.

Python port of the original bash board — same row format, priorities, and
sentinel contracts (.claude/tmux-window, .claude/parent-cwd,
.claude/agent-pid). Render flow: collect sessions -> enumerate lanes ->
reap stale states -> render LANES (parents, then nested children) ->
render COCKPIT.
"""

import glob
import json
import os
import re
import subprocess
import time
from pathlib import Path

HOME = Path.home()

RESET = "\033[0m"
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
DIM = "\033[2m"
BOLD = "\033[1m"

# Stale threshold for transient states (ACTIVE/WAITING/RUNNING) when no live
# claude PID is recorded. Long enough to outlast normal tool calls.
STALE_AFTER_SECS = 300
HIDE_IDLE_AFTER = int(os.environ.get("BOARD_HIDE_IDLE_AFTER", "1800"))
SHOW_ALL = bool(os.environ.get("BOARD_SHOW_ALL"))
PI_ACTIVE_MTIME_SECS = int(os.environ.get("PI_ACTIVE_MTIME_SECS", "30"))
NOW = time.time()

# Roots scanned for worktrees. Colon-separated, PATH-style; shared
# convention with wt-gc.
ROOTS = [p for p in os.environ.get("WT_ROOTS", str(HOME / "Documents/code")).split(":") if p]

# Reserved tmux window names that must never be treated as a lane label —
# cockpit/board panes routinely host lane Claude processes.
RESERVED_WINDOWS = {"cockpit", "agent-board", "agents"}
if os.environ.get("AGENT_BOARD_WINDOW_NAME"):
    RESERVED_WINDOWS.add(os.environ["AGENT_BOARD_WINDOW_NAME"])


def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return ""


def load_code_classes():
    """Pause-code vocab from the shared single source (share/state-codes.sh).

    Resolved relative to this file first (the repo is the truth), then the
    installed copy. Unknown/missing codes classify as '' and callers default
    to red — the safe direction.
    """
    candidates = (
        Path(__file__).resolve().parent.parent / "share" / "state-codes.sh",
        HOME / ".claude" / "state-codes.sh",
    )
    classes = {}
    for codes_file in candidates:
        try:
            text = codes_file.read_text()
        except OSError:
            continue
        for klass in ("RED", "YELLOW", "DIM"):
            m = re.search(rf'^WT_CODES_{klass}="([^"]*)"', text, re.M)
            if m:
                for code in m.group(1).split():
                    classes[code] = klass.lower()
        if classes:
            break
    return classes


CODE_CLASS = load_code_classes()


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except Exception:
        return False


def read_first_line(path):
    try:
        with open(path, errors="ignore") as f:
            return f.readline().rstrip("\n")
    except OSError:
        return ""


def read_last_line(path):
    try:
        with open(path, errors="ignore") as f:
            lines = f.read().splitlines()
        return lines[-1] if lines else ""
    except OSError:
        return ""


def tail_lines(path, max_bytes=512 * 1024):
    """Last lines of a (possibly huge) file without reading all of it."""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - max_bytes))
            return f.read().decode("utf-8", "ignore").splitlines()
    except OSError:
        return []


# ---- tmux label resolution ---------------------------------------------------

if os.environ.get("TMUX") and os.environ.get("TMUX_PANE") and os.environ.get("AGENT_BOARD_WINDOW_NAME"):
    run(["tmux", "rename-window", "-t", os.environ["TMUX_PANE"], os.environ["AGENT_BOARD_WINDOW_NAME"]])

PANE_MAP = {}
for _line in run(["tmux", "list-panes", "-a", "-F", "#{pane_pid}|#{window_name}"]).splitlines():
    _pid, _, _win = _line.partition("|")
    if _pid.isdigit():
        PANE_MAP[int(_pid)] = _win


def parent_pid(pid):
    out = run(["ps", "-o", "ppid=", "-p", str(pid)]).strip()
    return int(out) if out.isdigit() else 0


def tmux_window_for_pid(pid):
    """Walk the parent chain until a pid matches a tmux pane_pid; return its
    window name. Reserved names mean a shared pane, not a lane window — keep
    walking."""
    cur, hops = pid, 0
    while cur and cur > 1 and hops < 16:
        win = PANE_MAP.get(cur)
        if win and win not in RESERVED_WINDOWS:
            return win
        cur = parent_pid(cur)
        hops += 1
    return ""


# ---- ctx tokens ---------------------------------------------------------------


def extract_ctx_tokens(line):
    try:
        usage = (json.loads(line).get("message") or {}).get("usage") or {}
    except Exception:
        return None
    # Claude Code transcripts use Anthropic snake_case usage keys; Pi sessions
    # store provider-normalized camel-ish keys on the same message object.
    if any(k in usage for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")):
        return (
            (usage.get("input_tokens") or 0)
            + (usage.get("cache_read_input_tokens") or 0)
            + (usage.get("cache_creation_input_tokens") or 0)
        )
    return (usage.get("input") or 0) + (usage.get("cacheRead") or 0) + (usage.get("cacheWrite") or 0)


def ctx_from_jsonl(jsonl, cache_file):
    """Tokens from the last usage block, cached by mtime+size so 2s ticks
    stay cheap. Cache format matches the old bash board: mtime:size:tokens."""
    try:
        st = os.stat(jsonl)
    except OSError:
        return None
    key = f"{int(st.st_mtime)}:{st.st_size}"
    try:
        cached = Path(cache_file).read_text().strip().split(":")
        if len(cached) == 3 and f"{cached[0]}:{cached[1]}" == key:
            return int(cached[2]) if cached[2] else None
    except (OSError, ValueError):
        pass
    tokens = None
    for line in reversed(tail_lines(jsonl)):
        if '"usage"' in line:
            tokens = extract_ctx_tokens(line)
            break
    try:
        Path(cache_file).parent.mkdir(parents=True, exist_ok=True)
        Path(cache_file).write_text(f"{key}:{tokens if tokens is not None else 0}\n")
    except OSError:
        pass
    return tokens


def enc_project_dir(cwd):
    enc = cwd.replace("/", "-").replace(".", "-")
    return str(HOME / ".claude" / "projects" / enc)


def lane_ctx_tokens(lane_dir):
    files = glob.glob(os.path.join(enc_project_dir(lane_dir), "*.jsonl"))
    latest = max(files, key=os.path.getmtime, default="")
    if not latest:
        return None
    return ctx_from_jsonl(latest, os.path.join(lane_dir, ".claude", "ctx-cache"))


def fmt_ctx(n):
    if not n:
        return ""
    if n < 1000:
        return str(n)
    if n < 1_000_000:
        return f"{n // 1000}K"
    tenths = n // 100_000
    return f"{tenths // 10}.{tenths % 10}M"


# ---- state classification ------------------------------------------------------


def class_for_code(code):
    return CODE_CLASS.get(code, "")


def priority_for(raw, klass):
    """Sort priority: lower = higher up the board."""
    if raw.startswith("WAITING"):
        return {"red": 0, "yellow": 2, "dim": 5}.get(klass, 0)
    if raw.startswith("FAILED"):
        return 1
    if raw.startswith("HANDOFF"):
        return 2
    if raw.startswith("RUNNING"):
        return 3
    if raw.startswith("ACTIVE"):
        return 4
    if raw.startswith("STALE"):
        return 5
    if raw in ("DONE", "IDLE"):
        return 6
    return 4


def state_short(state):
    """'ACTIVE:Edit' -> 'Edit', 'W:input' -> 'input' — STATE column reads cleaner."""
    return state.split(":", 1)[1] if ":" in state else state


def pi_state_from_jsonl(path):
    """Infer a compact state from a live Pi jsonl session: tool call =>
    RUNNING:<tool>, tool result/user prompt => ACTIVE, fresh mtime => ACTIVE
    (streaming/thinking), otherwise IDLE."""
    try:
        is_fresh = (time.time() - os.path.getmtime(path)) <= PI_ACTIVE_MTIME_SECS
    except OSError:
        return "IDLE"
    last = None
    for line in tail_lines(path)[-80:]:
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("type") == "message":
            last = d.get("message") or {}
    if not last:
        return "ACTIVE" if is_fresh else "IDLE"
    role = last.get("role")
    if role == "assistant":
        for part in last.get("content") or []:
            if isinstance(part, dict) and part.get("type") == "toolCall":
                return "RUNNING:" + str(part.get("name") or "tool")
        return "ACTIVE" if is_fresh else "IDLE"
    if role in ("toolResult", "user"):
        return "ACTIVE"
    return "ACTIVE" if is_fresh else "IDLE"


# ---- session + lane collection --------------------------------------------------


def collect_sessions():
    """Every live Claude + Pi session: cwd, pid, session file, source.
    Sorted by (cwd, pid) so 'first session for a cwd' is deterministic."""
    rows = []
    # Claude Code exposes a small live-session registry with pid/cwd/status.
    for path in glob.glob(str(HOME / ".claude" / "sessions" / "*.json")):
        try:
            data = json.load(open(path))
            pid = int(data.get("pid") or 0)
            cwd = data.get("cwd") or ""
        except Exception:
            continue
        if pid and cwd and alive(pid):
            rows.append({"cwd": cwd, "pid": pid, "file": path, "source": "claude", "data": data})

    # Pi only persists jsonl transcripts. Pair live `pi` processes with the
    # newest jsonl whose session header has that cwd.
    pi_by_cwd = {}
    for path in glob.glob(str(HOME / ".pi" / "agent" / "sessions" / "*" / "*.jsonl")):
        try:
            with open(path, errors="ignore") as f:
                first = json.loads(f.readline() or "{}")
            cwd = first.get("cwd") or ""
            if first.get("type") != "session" or not cwd:
                continue
            mtime = os.path.getmtime(path)
        except Exception:
            continue
        old = pi_by_cwd.get(cwd)
        if not old or mtime > old[0]:
            pi_by_cwd[cwd] = (mtime, path)
    for line in run(["ps", "-axo", "pid=,comm="]).splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2 or parts[1] != "pi":
            continue
        try:
            pid = int(parts[0])
        except ValueError:
            continue
        lsof = run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"])
        cwd = next((l[1:] for l in lsof.splitlines() if l.startswith("n")), "")
        sess = pi_by_cwd.get(cwd)
        if cwd and sess and alive(pid):
            rows.append({"cwd": cwd, "pid": pid, "file": sess[1], "source": "pi", "data": None})

    rows.sort(key=lambda r: (r["cwd"], r["pid"]))
    return rows


def is_worktree_path(p):
    return "/.claude/worktrees/" in p


def collect_lane_cwds(sessions):
    """Every lane cwd: worktree dir on disk under a root, OR a live session
    whose cwd is structurally a lane."""
    lanes, seen = [], set()

    def add(p):
        p = p.rstrip("/")
        if p and p not in seen:
            seen.add(p)
            lanes.append(p)

    for root in ROOTS:
        for wt in sorted(glob.glob(os.path.join(root, "*", ".claude", "worktrees", "*/"))):
            if os.path.isdir(wt):
                add(wt)
    for s in sessions:
        if is_worktree_path(s["cwd"]):
            add(s["cwd"])
    return lanes


def parent_lane_of(lcwd, lane_set):
    """Parent via the .claude/parent-cwd sentinel written at wt spawn."""
    p = read_first_line(os.path.join(lcwd, ".claude", "parent-cwd")).strip()
    if p and p != lcwd and p in lane_set:
        return p
    return ""


# ---- per-pid session state ------------------------------------------------------


def session_pid_state(cwd, pid):
    """Granular per-pid state written by the wt-lanes hooks. Cockpit sessions
    write to the central ~/.claude/wt-sessions/<pid>; lanes write
    <lane>/.claude/sessions/<pid>. Legacy in-repo cockpit files are read as a
    fallback during transition."""
    state = read_first_line(str(HOME / ".claude" / "wt-sessions" / str(pid))).strip()
    if state:
        return state
    return read_first_line(os.path.join(cwd, ".claude", "sessions", str(pid))).strip()


# ---- rendering -------------------------------------------------------------------


def heal_stale_state(state_file, pid_file, state_mtime):
    """The hook writer exited without firing Stop (terminal close, kill,
    crash). Reset to IDLE but preserve mtime so the hide-idle threshold
    measures from when the lane actually went quiet."""
    try:
        tmp = state_file + ".tmp"
        with open(tmp, "w") as f:
            f.write("IDLE\n")
        os.replace(tmp, state_file)
        os.utime(state_file, (state_mtime, state_mtime))
    except OSError:
        pass
    try:
        os.remove(pid_file)
    except OSError:
        pass


def lane_row_from_state_file(state_file, lane_dir):
    """Render a state-file-backed lane row. Returns (prio, text) or None."""
    raw = read_last_line(state_file) or "—"
    try:
        state_mtime = os.path.getmtime(state_file)
    except OSError:
        return None
    age = NOW - state_mtime

    if not SHOW_ALL and raw == "IDLE" and age > HIDE_IDLE_AFTER:
        return None

    # Parse WAITING into a compact W:<code>. Detail stays in the state file.
    state, klass = raw, ""
    m = re.match(r"^WAITING:([^:]+):", raw)
    if m:
        klass = class_for_code(m.group(1))
        state = f"W:{m.group(1)}" if klass else "W:input"
        klass = klass or "red"
    elif raw.startswith("WAITING:") or raw == "WAITING":
        klass, state = "red", "W:input"
    elif raw.startswith("HANDOFF"):
        # Transient while lane-run respawns; persistent only when the respawn
        # cap is hit (the runner then re-tags via lane-pause). Doc path stays
        # in the state file.
        state = "HANDOFF"

    pid_file = os.path.join(lane_dir, ".claude", "agent-pid")
    is_stale = False
    if raw.startswith(("ACTIVE", "WAITING", "RUNNING")):
        if os.path.exists(pid_file):
            pid_txt = read_first_line(pid_file).strip()
            if pid_txt.isdigit() and not alive(int(pid_txt)):
                is_stale = True
        elif age > STALE_AFTER_SECS:
            is_stale = True

    if is_stale:
        heal_stale_state(state_file, pid_file, state_mtime)
        state, color, prio = "IDLE", DIM, 5
    else:
        if state.startswith("W:"):
            color = {"red": RED, "yellow": YELLOW, "dim": DIM}.get(klass, RED)
        elif raw.startswith("FAILED"):
            color = RED
        elif raw.startswith("ACTIVE") or raw == "DONE":
            color = GREEN
        elif raw == "IDLE":
            color = DIM
        else:
            color = YELLOW
        prio = priority_for(raw, klass)

    # Label preference: wt-written sentinel (authoritative) -> tmux window via
    # pid walk -> basename. The sentinel exists because the pid walk can
    # mis-label lanes whose Claude pid lives in the cockpit window.
    display = read_first_line(os.path.join(lane_dir, ".claude", "tmux-window")).strip()
    if not display:
        pid_txt = read_first_line(pid_file).strip()
        if pid_txt.isdigit():
            display = tmux_window_for_pid(int(pid_txt))
    if not display:
        display = os.path.basename(lane_dir)
    if len(display) > 28:
        display = display[:25] + "..."

    ctx = fmt_ctx(lane_ctx_tokens(lane_dir))
    return prio, f"{color}{display:<29} {state_short(state):<18} {ctx}{RESET}"


def session_row(cwd, state, ctx, spid, bucket, source):
    """Render a session-derived row. bucket: lane | lane-child | cockpit."""
    waiting = state.startswith("WAITING")
    if state.startswith("ACTIVE") or state == "DONE":
        color = GREEN
    elif waiting or state.startswith("FAILED"):
        color = RED
    elif state.startswith("RUNNING"):
        color = YELLOW
    else:
        color = DIM
    if waiting:
        state = "W:input"

    label = ""
    if bucket == "lane":
        label = read_first_line(os.path.join(cwd, ".claude", "tmux-window")).strip()
    if not label and spid:
        label = tmux_window_for_pid(spid)
    if not label:
        label = os.path.basename(cwd)
    if source == "pi":
        label = "π " + label

    prefix = ""
    max_len = 28
    if bucket == "lane-child":
        prefix = "└ "
        max_len = 26
    if len(label) > max_len:
        label = label[: max_len - 3] + "..."

    if waiting:
        prio = 0
    elif state.startswith("ACTIVE"):
        prio = 4
    else:
        prio = 6
    if bucket == "lane-child":
        prio = 5

    width = 29 - len(prefix)
    return prio, f"{color}{prefix}{label:<{width}} {state_short(state):<18} {ctx}{RESET}"


def render_lane_for(lcwd, bucket, sessions):
    """One lane's row. Prefers state-file rendering; falls back to the
    session registry. None = no signal at all."""
    state_file = os.path.join(lcwd, ".claude", "agent-state")
    mine = [s for s in sessions if s["cwd"] == lcwd]
    pi_mine = [s for s in mine if s["source"] == "pi"]

    if bucket == "lane" and os.path.isfile(state_file) and not pi_mine:
        return lane_row_from_state_file(state_file, lcwd)

    # Session-derived path. Prefer the Pi process over a Claude agent-pid
    # sentinel for the same lane; otherwise stale .claude/agent-state masks
    # Pi activity.
    pid = None
    if pi_mine:
        pid = pi_mine[0]["pid"]
    else:
        pid_txt = read_first_line(os.path.join(lcwd, ".claude", "agent-pid")).strip()
        if pid_txt.isdigit():
            pid = int(pid_txt)
    if pid is None or not alive(pid):
        pid = mine[0]["pid"] if mine else None
    if pid is None:
        return None

    row = next((s for s in sessions if s["pid"] == pid), None)
    source = row["source"] if row else "claude"

    sstate = ""
    if source != "pi":
        sstate = session_pid_state(lcwd, pid)
        if not sstate and os.path.isfile(state_file):
            sstate = read_last_line(state_file).strip()
    if not sstate and row:
        if source == "pi":
            sstate = pi_state_from_jsonl(row["file"])
        else:
            sstate = "ACTIVE" if (row["data"] or {}).get("status") == "busy" else "IDLE"
    sstate = sstate or "IDLE"

    ctx = session_ctx(row, lcwd) if row else ""
    return session_row(lcwd, sstate, ctx, pid, bucket, source)


def session_ctx(row, cwd):
    if row["source"] == "pi":
        return fmt_ctx(ctx_from_jsonl(row["file"], row["file"] + ".ctx-cache"))
    sid = (row["data"] or {}).get("sessionId") or ""
    if not sid:
        return ""
    jsonl = os.path.join(enc_project_dir(cwd), sid + ".jsonl")
    if not os.path.isfile(jsonl):
        return ""
    return fmt_ctx(ctx_from_jsonl(jsonl, os.path.join(enc_project_dir(cwd), ".ctx-cache-" + sid)))


def header(title):
    return f"{BOLD}{title:<29} {'STATE':<18} CTX{RESET}"


def main():
    sessions = collect_sessions()
    lane_cwds = collect_lane_cwds(sessions)
    lane_set = set(lane_cwds)

    # Lanes: parents first, children nested under their parent's priority.
    lane_records = []  # (group_prio, parent_cwd, sub, text)
    parent_prio = {}
    for lcwd in lane_cwds:
        if parent_lane_of(lcwd, lane_set):
            continue
        row = render_lane_for(lcwd, "lane", sessions)
        if not row:
            continue
        prio, text = row
        parent_prio[lcwd] = prio
        lane_records.append((prio, lcwd, 0, text))
    for lcwd in lane_cwds:
        parent = parent_lane_of(lcwd, lane_set)
        if not parent:
            continue
        row = render_lane_for(lcwd, "lane-child", sessions)
        if not row:
            continue
        lane_records.append((parent_prio.get(parent, 6), parent, 1, row[1]))

    # Cockpit: live sessions whose cwd is not a lane.
    cockpit_rows = []
    for s in sessions:
        if s["cwd"] in lane_set:
            continue
        sstate = session_pid_state(s["cwd"], s["pid"])
        if not sstate:
            if s["source"] == "pi":
                sstate = pi_state_from_jsonl(s["file"])
            else:
                sstate = "ACTIVE" if (s["data"] or {}).get("status") == "busy" else "IDLE"
        cockpit_rows.append(session_row(s["cwd"], sstate, session_ctx(s, s["cwd"]), s["pid"], "cockpit", s["source"]))

    if not lane_records and not cockpit_rows:
        print(f"{DIM}(no worktrees or active cockpit sessions){RESET}")
        return

    print(header("LANES"))
    if lane_records:
        for rec in sorted(lane_records, key=lambda r: (r[0], r[1], r[2])):
            print(rec[3])
    else:
        print(f"{DIM}(none){RESET}")

    if cockpit_rows:
        print()
        print(header("COCKPIT"))
        for _, text in sorted(cockpit_rows, key=lambda r: r[0]):
            print(text)


if __name__ == "__main__":
    main()
