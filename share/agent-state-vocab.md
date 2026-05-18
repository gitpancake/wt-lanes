# Lane Pause Reason Codes

Canonical vocab for `WAITING:<code>:<detail>` agent-state values. Set via
`~/.claude/scripts/lane-pause.sh <code> <detail>` before pausing for human input.

The board (`~/.tmux/agent-board.sh`) parses the code and colors the row by class.

| Code             | Class  | When to use                                                   |
|------------------|--------|---------------------------------------------------------------|
| `ambiguity`      | red    | Plan unclear, scope question can't be resolved from context.  |
| `creds`          | red    | Missing env var, auth token, login, or API key.               |
| `test-loop`      | red    | Same test fails N+ times on the same root cause; stuck.       |
| `merge-conflict` | red    | Rebase or merge needs a human call.                           |
| `verify`         | red    | verify-subagent rejected evidence; can't claim done.          |
| `scope`          | red    | Scope creep detected; needs rescope decision.                 |
| `external`       | yellow | External service / API down or rate-limited.                  |
| `review`         | dim    | PR is up; awaiting human review. Not a blocker, just paused.  |
| `input`          | red    | Fallback. Notification fired with no explicit code.           |

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
```

## Detail field

- Free text, single line.
- Truncated to keep total state-file line under 200 chars.
- Should answer "why is this lane red?" at a glance — not a full explanation.
