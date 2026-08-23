# wt-lanes

Parallel autonomous lanes for Pi — a worktree per ticket, a tmux pane
per lane, one status board that watches them all.

```
LANES                         STATE              CTX
teams-error-mapping r✓4/7     ACTIVE:Bash        74K
oauth-rotation                IDLE                51K
webhook-replay      r✓3/3     DONE                88K
sla-tracking                  WAITING:review     32K
```

## What it is

A small bundle of bash + tmux glue (plus a python status board) that turns
Pi from "one terminal window" into "an arbitrary number of fire-and-forget
lanes you can see at a glance." The unit of work is a git worktree on its own
branch, driven by its own Pi session, observable from a pinned status board.

The pieces:

| Piece | Role |
|---|---|
| `wt <slug>` | Spawner. Creates a worktree, a branch, an agent-state file, and a tmux window/pane running `pi --model openai-codex/gpt-5.5`. The lane is fire-and-forget from there. |
| `wt-gc` | Reaper. Cleans up lanes whose worktree is gone or whose agent pid is dead. |
| `agent-board` | The status board. Reads every lane's `agent-state` file, renders one row per lane, color-coded. Pin it in a tmux pane. |
| `lane-watch` | Per-lane monitor pane. Renders one lane's state + git status. Attached automatically by `wt`. |
| `lane-paint` | Tab painter. Colours each lane's tmux tab by state, so a lane that is blocked on you is visible from any window without opening anything. |
| `lane-menu` | Jump menu (`prefix + a`). Every live lane, sorted blockers-first, with the reason it stopped; pick one to jump straight to it. `prefix + b` goes to the next blocked lane. |
| `lane-pause` | Manual state writer. Call from inside a lane to record why you've paused (`review`, `ambiguity`, `creds`, etc.). |
| Hooks | `agent-state-active`, `agent-state-idle`, `agent-state-waiting`, `precheck-stop` — optional legacy Claude Code hooks that keep the state file in sync with what the agent is actually doing. |

## Install

```bash
git clone https://github.com/gitpancake/wt-lanes ~/.wt-lanes
~/.wt-lanes/install.sh
```

Then complete two one-time steps the installer prints:

1. Merge the hook registration block into `~/.claude/settings.json`.
2. Add the tmux keybinding for the agent-board pane.

Uninstall: `~/.wt-lanes/uninstall.sh`.

### Dependencies

Required: `bash`, `git`, `tmux`, [Pi](https://pi.dev).
Optional: `jq`, `terminal-notifier` (macOS) / `notify-send` (linux).

## Quickstart

```bash
wt my-feature                          # spawn a lane on a fresh branch
wt --branch existing-pr-branch         # spawn a lane on an existing branch
wt --dag epic-slug                     # spawn ready-set lanes from a plan DAG
wt-gc                                  # reap dead lanes
```

Open the status board:

```bash
# prefix + A  (after install.sh's tmux binding)
# or one-shot:
~/.tmux/agent-board.sh
```

Or skip the board entirely. Lane tabs carry their own state, so you never have
to walk `prefix + <number>` through them to find out who needs you:

| Tab colour | Meaning |
|---|---|
| red | Blocked on you — `ambiguity`, `creds`, `input`, `test-loop`, `merge-conflict`, `scope`, `verify`, or a failed precheck |
| yellow | Blocked on something external (`external`), or handed off mid-respawn |
| blue | Expected pause — waiting on PR review |
| green | Done |
| default | Working, or idle |

```bash
# prefix + a   the jump menu: every lane, blockers first, with why it stopped
# prefix + b   jump to the next blocked lane
```

Switching to a lane's tab acknowledges it and the colour clears, so a tab you
have already dealt with is not still lit on the way out. It lights again when
that lane blocks on something new.

## The state machine

Every lane writes to `<worktree>/.claude/agent-state` via the registered hooks:

| State | Written by | Meaning |
|---|---|---|
| `IDLE` | `agent-state-idle` (Stop) | Lane is between tool calls — at a chat prompt or done. |
| `ACTIVE:<tool>` | `agent-state-active` (PreToolUse) | Lane is mid-tool-use. The tool name lands in the suffix. |
| `WAITING:<code>:<detail>` | `agent-state-waiting` (Notification) and `lane-pause <code> <detail>` (manual) | Lane needs attention. See `share/agent-state-vocab.md` for the code vocabulary. |
| `RUNNING:precheck` / `DONE` / `FAILED:<step>` | `precheck-stop` | Lane just stopped — the precheck contract is running (typecheck, tests, etc.). |
| `HANDOFF:<doc-path>` | `lane-handoff.sh` (lane's final tool call after `/handoff`) | Context forced a session swap mid-brief. The script also TERMs the lane's claude (pid from `agent-pid`, ~20s grace — an interactive session never exits by itself) so `lane-run.sh` unblocks, reads the state, and respawns a fresh session that `/resume`s the doc; persists only if the respawn cap is hit. |

The board reads each lane's state file every 2 seconds and renders accordingly.
Red = needs attention, yellow = external dep, green = active or done.

## Configuration

| Env | Default | Purpose |
|---|---|---|
| `WT_ROOTS` | `~/Documents/code` | Colon-separated roots agent-board + wt-gc scan for worktrees. |
| `WT_LAYOUT` | `window` | `pane`, `window`, or `session` — how the lane attaches to tmux. |
| `WT_PI_MODEL` | `openai-codex/gpt-5.5` | Pi model the lane uses. |
| `WT_AGENT_CMD` | `pi --model $WT_PI_MODEL` | Full launch command override. |
| `WT_NO_WATCH` | (unset) | Set to `1` to skip the auto-attached monitor pane. |
| `WT_TMUX_SESSION` | `wt` | When run outside tmux, which session to target. |
| `WT_TICKET_SYNC` | (unset) | Optional executable invoked with the slug on lane spawn. Pair with [tix](https://github.com/gitpancake/tix). |
| `TICKETS_DIR` | `~/.claude/tickets` | Where `wt <slug>` resolves slugs to brief files. Optional — `wt --branch` works without tickets. |

## Integrations

- **[`tix`](https://github.com/gitpancake/tix)** — ticket TUI. `wt <slug>` resolves
  against `$TICKETS_DIR`. Tix's `p` key pickups call back into `wt`.
- **Linear** — `wt <linear-id>` resolves the ID against `linear:` frontmatter in
  your tickets and spawns a lane on it.

## Layout

```
wt-lanes/
├── bin/                  on-PATH executables
│   ├── wt                lane spawner
│   └── wt-gc             dead-lane reaper
├── scripts/              called by absolute path from wt + hooks
│   ├── lane-watch.sh     per-lane monitor pane
│   ├── lane-pause.sh     manual state writer
│   ├── lane-paint.sh     colours a lane's tmux tab by state
│   └── dag-parse.sh      DAG-mode plan parser
├── hooks/                Claude Code hooks
│   ├── _state-write.sh   shared helper (routes lane vs cockpit, atomic writes)
│   ├── agent-state-active.sh
│   ├── agent-state-idle.sh
│   ├── agent-state-waiting.sh
│   └── precheck-stop.sh
├── share/
│   ├── agent-state-vocab.md   reason-code vocab (human docs)
│   ├── state-codes.sh         reason-code vocab (machine source of truth)
│   └── lane-windows.sh        tab palette, state→class, window↔worktree lookup
├── tests/                     dependency-free bash suite — tests/run.sh
├── tmux/
│   ├── agent-board.py         the status board
│   ├── agent-board.sh         thin launcher (installed path contract)
│   └── lane-menu.sh           the lane jump menu
├── install.sh
└── uninstall.sh
```

## Tests

```bash
tests/run.sh        # whole suite; plain bash + git, no bats needed
```

Covers dag-parse's exit-code contract, `wt`'s slug/ticket/epic/tombstone
resolution and dry-run spawn derivation, and wt-gc's safety gates
(age / dirty / unpushed / notify).

## Non-goals

- Not a Pi prompt library. No slash commands, skills, or subagents
  here — that belongs in a separate doctrine repo.
- Not a ticket system. See `tix`.
- Not a windows-native tool. macOS + Linux only.

## License

MIT.
