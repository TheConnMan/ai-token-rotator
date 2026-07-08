# claude-token-rotator

Automatically rotate the active Claude Code OAuth account across N logged-in Max
accounts by hot-swapping `~/.claude/.credentials.json` on a systemd user timer,
so unattended background work keeps running against whichever account has budget.

Claude Code re-reads `.credentials.json` on nearly every API call, so atomically
rewriting the account token in that file redirects even already-running jobs
within seconds. With one account this is a monitored no-op; it starts rotating
the moment a second account is bootstrapped. See `SPEC.md` for the full behavior
and acceptance criteria.

## How it works

Only the Claude account token (`.claudeAiOauth`) is swapped. The third-party MCP
tokens (`.mcpOAuth`) are account-independent, so they live permanently in the live
credentials file and rotation never touches them: a swap is a read-modify-write
that replaces only `.claudeAiOauth` and preserves the live `.mcpOAuth`. Each
account's token is stored token-only, and one shared canonical MCP set is stored
once.

A pointer file tracks which account is currently live. On each timer tick
`rotate.sh`:

1. Syncs the live account token back into the active account's stored copy,
   capturing any token refresh (never overwriting the store from a partial file),
   and refreshes the shared MCP set from the live file.
2. Polls the Anthropic OAuth usage endpoint for every account.
3. Decides whether to swap, and if so swaps in the target account's stored token
   over the live credential file (preserving the live MCP tokens) and updates the
   pointer.

The store lives at `$ROTATOR_STORE` (default `~/.claude/accounts`, dir 0700):

- `<label>.json`       token-only copy: that account's `.claudeAiOauth`, no MCP tokens (0600)
- `mcp.json`           the shared canonical MCP set (`.mcpOAuth`, 0600)
- `<label>.usage.json` last-known usage snapshot
- `active`             label currently occupying the live credential file
- `ENABLED`            sentinel; rotate is a no-op unless this exists
- `rotate.log`         append-only, ISO-8601 timestamps

The store must live OUTSIDE the repo (default `~/.claude/accounts`) so the
credential material it holds is never committable. The real `config.env` also
lives outside version control (gitignored).

## Bootstrap flow

MCP tokens are account-independent, so you authenticate your MCP servers ONCE, on
your first account, and every other account reuses that shared set.

First account (the one that will hold your MCP servers):

1. In `claude`, `/login` to that account.
2. Re-authenticate EVERY MCP server on it so its credential file is complete.
3. Run `./bootstrap.sh <label>` (labels are alphanumeric/dash only). This captures
   the account token (token-only) into the store, captures the shared MCP set once
   into `mcp.json`, best-effort captures usage, and sets the `active` pointer.

Each additional account:

4. In `claude`, `/login` to the next account. In practice the MCP tokens usually
   persist across a `/login`, but a login MAY clear them.
5. Run `./bootstrap.sh <next-label>`. If the login cleared the live MCP set,
   bootstrap restores the shared set from `mcp.json` into the live credentials; if
   the MCP tokens survived, bootstrap just refreshes the shared set. Either way the
   account regains MCP access. Only claude.ai connectors need a per-account
   reconnect in the UI.
6. Repeat 4-5 for each account.

Each bootstrap sets `active` to the account it just captured, so the LAST
account you bootstrap is the active one when you go live. That is fine: rotation
takes over from whichever account is active on the first tick.

When all accounts are captured, go live:

```
touch "$ROTATOR_STORE/ENABLED"    # default: ~/.claude/accounts/ENABLED
```

Then install the timer:

```
./install.sh
```

Installing is SAFE at any time: `rotate.sh` no-ops until `ENABLED` exists.

## Enable and disable

The `ENABLED` sentinel is the master switch. `touch` it to go live; delete it to
pause all rotation (the timer keeps ticking but every tick exits immediately
writing nothing). No need to stop the timer to pause.

## Configuration

`config.env` (copy from `config.env.example`) sets the knobs:

- `FIVE_HOUR_PCT` (default 80): swap when the active account's 5h utilization is
  at or above this.
- `WEEKLY_DIVERGENCE_PCT` (default 10): base dead zone; swap when the spread
  between the highest and lowest weekly utilization across accounts is at or above
  this. The dead zone tightens adaptively as the lowest account's weekly usage (the
  floor) climbs: to 5 when the floor is at or above 80, and to 2.5 when it is at or
  above 90, so the rotator keeps rebalancing tightly near the weekly ceiling. The
  floor tiers and their tightened values are configurable via
  `WEEKLY_DIVERGENCE_HI_FLOOR` / `WEEKLY_DIVERGENCE_HI_PCT` (default 80 / 5) and
  `WEEKLY_DIVERGENCE_VHI_FLOOR` / `WEEKLY_DIVERGENCE_VHI_PCT` (default 90 / 2.5).
- `INTERVAL_MIN` (default 15): timer cadence in minutes.
- `ACCOUNTS` (required): space-separated labels, one per bootstrapped account.

## Decision rule

Utilization is on a 0-100 scale. On each tick:

- Trigger A (5h pressure): if the ACTIVE account's 5h utilization is at or above
  `FIVE_HOUR_PCT`, swap to the other account with the LOWEST 5h utilization (ties
  broken by lowest weekly).
- Trigger B (weekly divergence): if the spread between the maximum and minimum
  weekly utilization is at or above the effective dead zone, swap to the account
  with the MINIMUM weekly utilization. The dead zone is `WEEKLY_DIVERGENCE_PCT` by
  default, tightening to 5 when the floor (min weekly) is at or above 80 and to 2.5
  when it is at or above 90.
- If both trigger, Trigger A wins (relieving 5h pressure is urgent).

A swap only happens if a valid target exists, it is not already the active
account, and its stored credential file is valid. An account whose live usage
fetch fails (idle token expired, 401) falls back to its last stored usage; an
account with no known weekly is excluded from divergence and never fires a
trigger.

## Dry read-out

```
./rotate.sh status
```

Computes and prints the current decision line without writing or swapping
anything.

## N=1 monitored no-op

With a single bootstrapped account, `rotate.sh` still polls and logs but NEVER
swaps. A swap target can never equal the active account. Rotation begins
automatically once a second account is bootstrapped.

## Active-pointer desync recovery

If you `/login` to a different account out of band (outside the rotator), the
`active` pointer no longer matches the live credential file. Recover by re-running
`./bootstrap.sh <label>` for the account you are actually logged into: bootstrap
recaptures that account's credential file AND sets `active` to `<label>`, so the
store realigns with reality. From there rotation resumes normally. (A live tick
also detects this desync on its own and skips rather than clobbering a stored
slot, but re-bootstrapping is how you actually fix it.)

To change accounts out of band while the timer is live, pause first so a racing
tick cannot copy the new live cred over the old active account's stored file:

```
rm "$ROTATOR_STORE/ENABLED"       # pause rotation
# ...now /login to the other account (bootstrap restores its shared MCP set)...
./bootstrap.sh <label>            # recapture + realign the pointer
touch "$ROTATOR_STORE/ENABLED"    # resume rotation
```
