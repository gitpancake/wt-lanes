# Lane Pause Reason Codes

Canonical vocab for `WAITING:<code>:<detail>` agent-state values. Set via
`~/.claude/scripts/lane-pause.sh <code> <detail>` as the lane's final tool call.

Every stop ends in exactly one of three final tool calls: `lane-done.sh` (DONE),
`lane-pause.sh <code> <detail>` (WAITING), or `lane-handoff.sh <doc>` (HANDOFF).
A turn that ends with none of them shows on the cockpit as
`WAITING:input:stopped without a pause code`, red, and counts as a breach.

The tab, the board (`~/.tmux/agent-board.sh`) and the jump menu colour by class.

| Code             | Class  | When to use                                                                 |
|------------------|--------|-----------------------------------------------------------------------------|
| `ambiguity`      | red    | Plan unclear, scope question can't be resolved from context.                |
| `creds`          | red    | Missing env var, auth token, login, or API key.                             |
| `test-loop`      | red    | Same test fails N+ times on the same root cause; stuck.                     |
| `merge-conflict` | red    | Rebase or merge needs a human call.                                         |
| `verify`         | red    | verify-subagent rejected evidence; can't claim done.                        |
| `scope`          | red    | Scope creep detected; needs rescope decision.                               |
| `input`          | red    | Fallback. A question with no better code, or a stop with no code at all.    |
| `external`       | yellow | External service / API down or rate-limited.                                |
| `review`         | yellow | PR up, reviewers never settled within the lane's poll window.               |
| `holland`        | hold   | Arbiter `needs-holland`: Holland's case is open; the lane has answered him. |
| `human`          | hold   | Arbiter `needs-human`: a maintainer must approve the head commit.           |
| `prompt-owner`   | hold   | `prompt-owner-review` is `awaiting` an owner's approval or label.           |

## Classes

- **red** — the lane asked you something. The tab stays red until you visit it.
- **yellow** — waiting on something outside you and outside any named person.
  Cleared by a visit.
- **hold** — the PR is complete from the lane's side and a named person must
  release it. The tab blinks purple and a visit never clears it. The
  `lane-holds.sh` daemon polls the gate every ~2 minutes: released → the lane is
  marked `DONE` (green); findings posted instead → `WAITING:input:<gate> posted
  findings on PR #N` (red), and you tell the lane to run the gate again.
- **green** — `DONE`. Arbiter success and `lane-done.sh` run.
- **nothing** — working, respawning after a handoff, or parked on a Monitor.

`wilson-runtime-owner-review` has no code: the lane's login is on its roster, so
`devin-review.sh gate` applies the override label itself.

## Examples

```
lane-pause.sh ambiguity "should slice 3 ship before slice 2?"
lane-pause.sh creds "missing OPENAI_API_KEY in .env.local"
lane-pause.sh test-loop "auth.test.ts fails on token refresh, 4 attempts"
lane-pause.sh merge-conflict "rebase onto main, 3 files in db/migrations"
lane-pause.sh verify "verify-subagent: build output didn't include new route"
lane-pause.sh scope "ticket asks for SSO, plan only covers password auth"
lane-pause.sh external "Linear MCP returning 503"
lane-pause.sh review "PR #1284 open, review pending"
lane-pause.sh holland "PR #1284: is the notifier delete reversible? answered at <comment url>"
lane-pause.sh human "PR #1284 needs-human: ShipmentDocSchema gains a field, maintainer must approve"
lane-pause.sh prompt-owner "PR #1284 awaiting abdul/kolby/beatriz on the head commit"
```

## HANDOFF (not a pause code)

`HANDOFF:<doc-path>` is a top-level state like `DONE`, written by
`lane-handoff.sh <doc-path>` as the lane's final tool call when context
forces a session swap mid-brief. It is not a `WAITING` code: the lane is not
blocked on a human — `lane-run.sh` respawns a fresh session that `/resume`s
the doc. The tab is not painted, because nothing needs you; the board lists
it. It persists only if the respawn cap is hit (the runner then re-tags via
`lane-pause.sh input ...`).

## RUNNING:monitor (not a pause code)

Written by the Stop hook when a turn ends with a Monitor still pending, so the
lane reads as busy rather than stalled. The board turns one older than 15
minutes into `WAITING:input:monitor never returned` (red).

## Detail field

- Free text, single line.
- Truncated to keep total state-file line under 200 chars.
- Should answer "why is this lane red?" at a glance — not a full explanation.
- A hold's detail names the gate's question and, for `holland`, links the
  lane's answer. Never "awaiting Holland".
