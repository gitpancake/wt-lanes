# CLAUDE.md

## Project

`wt-lanes` is the parallel-lane infrastructure for Claude Code. Shell-only.
Three roles in the system:

1. **Producer** — `bin/wt` spawns a worktree + branch + tmux pane + Claude
   session. Seeds `<wt>/.claude/agent-state` to `IDLE` and writes
   `<wt>/.claude/tmux-window` for the board to label the lane.
2. **State machine** — hooks (`hooks/agent-state-*.sh`, `hooks/precheck-stop.sh`)
   are the *only* writers of `<wt>/.claude/agent-state`. They run inside
   Claude Code, registered in the user's `~/.claude/settings.json`.
   `_state-write.sh` routes by cwd: lanes get the in-worktree files; cockpit
   sessions write only `~/.claude/wt-sessions/<pid>` so ordinary repos never
   accumulate `.claude/` state churn.
3. **Consumer** — `tmux/agent-board.py` (via the `agent-board.sh` launcher)
   and `scripts/lane-watch.sh` read the state file and render. One sanctioned
   write: the board's stale-reap resets ACTIVE/WAITING/RUNNING to IDLE when
   the recorded agent pid is dead (writer crashed without firing Stop).

## Invariants

1. **The state file is the contract.** Every reader assumes it follows the
   vocab in `share/agent-state-vocab.md`. New states require updates in
   vocab + every reader.
2. **Hooks are the only writers.** `lane-pause.sh` is the one exception
   (manual writer for WAITING states) and goes through the same
   `_state-write.sh` helper.
3. **Bins resolve scripts/hooks via absolute paths** to `~/.claude/scripts`
   and `~/.claude/hooks`. install.sh symlinks files there. Do not
   `dirname $0`-relative — bins are symlinked onto PATH and would lose
   their repo location.
4. **Bash for glue, python for the board.** Spawner, gc, hooks, and lane
   scripts stay bash 3.2-compatible (scriptable in any tmux pane, no
   startup cost on hooks). The agent-board is python (`tmux/agent-board.py`)
   — it outgrew bash (assoc-array workarounds, awk scans per lane per tick;
   the port renders ~27x faster). Don't add python to the hooks.
5. **Cockpit is a structural concept.** The agent-board has a LANES
   section (worktree-backed) and a COCKPIT section (live Claude sessions
   outside worktrees). The two are distinct rendering paths — don't merge.

## Coupling boundaries

- **Tickets:** soft. `wt <slug>` resolves against `$TICKETS_DIR` if set,
  otherwise expects `--branch`. No hard dep on tix.
- **Slash commands / subagents / skills:** none. Those belong in a separate
  doctrine repo.
- **`WT_TICKET_SYNC`:** the one optional callback. Lets users plug in
  `tix-sync` or any other slug-aware status reconciler.

## Reserved tmux window names

`agent-board.sh` ignores these when walking pid → window for lane labels,
because lanes routinely run inside them:

- `cockpit` (the user's primary tmux window)
- `agent-board` (the board pane itself)
- `agents` (legacy)

Lane labels use `<wt>/.claude/tmux-window` (written by wt at spawn) as the
authoritative source. The pid → window walk is a fallback.

## Install / runtime layout

| Repo path | Installed at |
|---|---|
| `bin/*` | `~/.local/bin/` |
| `scripts/*` | `~/.claude/scripts/` |
| `hooks/*` | `~/.claude/hooks/` |
| `share/agent-state-vocab.md` | `~/.claude/agent-state-vocab.md` |
| `share/state-codes.sh` | `~/.claude/state-codes.sh` |
| `tmux/agent-board.sh` | `~/.tmux/agent-board.sh` |

All symlinks. Edits in the clone land immediately. `agent-board.py` is not
linked — the `.sh` launcher resolves it next to its own symlink target.
Runtime state the hooks own: `~/.claude/wt-sessions/<pid>` (cockpit per-pid
states, pruned on write).

## Editing rules

- Run `tests/run.sh` after touching `bin/` or `scripts/` — plain bash + git,
  no test deps.
- `bin/wt` is the spawn contract. Adding flags is fine; changing existing
  flag semantics is breaking.
- `tmux/agent-board.py` runs every 2s inside `watch` (launched through
  `agent-board.sh`). Keep render fast — any per-lane data must cache via
  mtime+size keyed files (see `<wt>/.claude/ctx-cache`).
- Hooks run on every Claude tool call. Keep them <10ms. If you need
  network or heavy IO, fork.
- `_state-write.sh` walks the process tree to find the Claude pid and
  writes it to `<wt>/.claude/agent-pid`. The board uses agent-pid to
  detect orphans. Don't change the walk depth without auditing the board.

## Non-goals

- No Windows support.
- No GUI.
- No remote lanes — lanes are local worktrees only.
- No bundled prompt library — Claude Code prompts/agents/skills are out of
  scope. This bundle is infrastructure.
