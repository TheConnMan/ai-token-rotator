# Claude Max two-account OAuth token rotator

Swaps the live Claude Code credentials file between two logged-in Claude Max
accounts so a single machine can spread its work across both weekly limits.
Claude Code re-reads `~/.claude/.credentials.json` on nearly every API call, so
atomically replacing that whole file at its storage location redirects running
jobs within seconds. The file holds both the account token (`.claudeAiOauth`)
and every per-MCP-server token (`.mcpOAuth.*`), so we swap the WHOLE file: each
account has its own complete, valid credentials file captured in the store.

## One-time bootstrap

1. Log into account A (`claude`, then `/login`). Re-auth every MCP server.
2. `services/token-rotator/bootstrap.sh A`
3. In claude: `/logout`, then `/login` to account B. Re-auth every MCP server on B.
4. `services/token-rotator/bootstrap.sh B`
5. Go live: `touch ~/.claude/accounts/ENABLED`

Install the timer any time (before or after bootstrap):

    services/token-rotator/install.sh

Installing the timer is safe before bootstrap because `rotate.sh` no-ops until
`~/.claude/accounts/ENABLED` exists.

## Enable / disable

- Enable: `touch ~/.claude/accounts/ENABLED`
- Disable (pause instantly): `rm ~/.claude/accounts/ENABLED`

The timer keeps firing while disabled; each tick just exits early.

## Decision rule

Each tick reads the active account's live usage, then swaps to the other account
when either trigger fires:

- Trigger A (5h pressure): active 5-hour utilization is at or above 80 (0-100 scale).
- Trigger B (weekly imbalance): active weekly utilization minus the other
  account's last-known weekly utilization is at least 10 percentage points.

A swap only happens when the other account's stored credentials file is present
and valid; otherwise the tick holds on the current account and logs it.

Dry read-out (never swaps): `services/token-rotator/rotate.sh status`

## Notes

- The statusline and the drain controller usage percentages reflect whichever account is
  currently active, since they read the same live credentials file.

## Safety

- Whole-file atomic swap: the new file is written to a temp file in the same
  directory and `mv`-renamed over the target, so running jobs never see a torn file.
- Sync-out-before-swap-in: before each potential swap, the active account's live
  file is copied back into the store. Access tokens auto-refresh (~6h) and refresh
  tokens may be single-use/rotated, so this preserves the latest rotated tokens.
- A live file that is currently unreadable (Claude mid-write) is never allowed to
  overwrite the store; the tick skips instead.
- The runtime store lives OUTSIDE the repo at `~/.claude/accounts/` (dir mode
  0700, files mode 0600) and is never committed.
