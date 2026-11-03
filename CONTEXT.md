# Glossary

Terms the lane system uses. Concepts only; where each one is implemented moves.

- **Lane** — one autonomous agent session working one brief in its own worktree and tmux window.
- **Cockpit** — the human's own session, where every lane is watched from.
- **Pause code** — the one word a lane gives for why it stopped. A lane stops in exactly one of three ways: done, paused with a code, or handed off.
- **Hold** — a pause where the PR is complete from the lane's side and a named person outside the cockpit must release it. Three holds: the Holland case (`holland`), the maintainer approval (`human`), and the prompt owner's approval (`prompt-owner`). A hold is released by that person, never by the cockpit, and the tab keeps asking until it is.
- **Blocked** — a pause where the cockpit itself owes the lane an answer or an action.
- **External wait** — a pause on something outside both the cockpit and any named person: a vendor outage, reviewers that never settled.
- **Handoff** — a lane swapping sessions to continue the same brief with fresh context. Not a pause; nobody is owed anything.
- **Ack** — the cockpit has looked at a tab's flag. Clears a blocked, external, or done flag; never a hold.
