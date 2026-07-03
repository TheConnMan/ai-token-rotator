# claude-token-rotator

Automatically rotate the active Claude Code OAuth account across N logged-in Max
accounts by hot-swapping `~/.claude/.credentials.json` on a systemd user timer,
so unattended background work keeps running against whichever account has budget.

Claude Code re-reads `.credentials.json` on nearly every API call, so atomically
replacing the whole file redirects even already-running jobs within seconds. With
one account this is a monitored no-op; it starts rotating the moment a second
account is bootstrapped. See `SPEC.md` for the full behavior and acceptance
criteria.

## How it works

Each account's complete credential file (account token plus per-MCP tokens) is
copied into a store outside the repo. A pointer file tracks which account is
currently live. On each timer tick `rotate.sh`:

1. Syncs the live credential file back into the active account's stored copy,
   capturing any token refresh (never overwriting the store from a partial file).
2. Polls the Anthropic OAuth usage endpoint for every account.
3. Decides whether to swap, and if so atomically copies the target account's
   stored file over the live credential file and updates the pointer.

The store lives at `$ROTATOR_STORE` (default `~/.claude/accounts`, dir 0700):

- `<label>.json`       full copy of that account's `.credentials.json` (0600)
- `<label>.usage.json` last-known usage snapshot
- `active`             label currently occupying the live credential file
- `ENABLED`            sentinel; rotate is a no-op unless this exists
- `rotate.log`         append-only, ISO-8601 timestamps

The store must live OUTSIDE the repo (default `~/.claude/accounts`) so the full
credential copies it holds are never committable. The real `config.env` also
lives outside version control (gitignored).

## Bootstrap flow

Do this once per account. For each account:

1. In `claude`, `/login` to the account you want to capture.
2. Re-authenticate EVERY MCP server on that account so its credential file is
   complete.
3. Run `./bootstrap.sh <label>` (labels are alphanumeric/dash only). This copies
   the live credential file into the store, best-effort captures its usage, and
   sets the `active` pointer to `<label>` (the account you just captured).
4. Repeat 1-3 for each account.

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
- `WEEKLY_DIVERGENCE_PCT` (default 20): swap when the spread between the highest
  and lowest weekly utilization across accounts is at or above this.
- `INTERVAL_MIN` (default 15): timer cadence in minutes.
- `ACCOUNTS` (required): space-separated labels, one per bootstrapped account.

## Decision rule

Utilization is on a 0-100 scale. On each tick:

- Trigger A (5h pressure): if the ACTIVE account's 5h utilization is at or above
  `FIVE_HOUR_PCT`, swap to the other account with the LOWEST 5h utilization (ties
  broken by lowest weekly).
- Trigger B (weekly divergence): if the spread between the maximum and minimum
  weekly utilization is at or above `WEEKLY_DIVERGENCE_PCT`, swap to the account
  with the MINIMUM weekly utilization.
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
# ...now /login to the other account and re-auth its MCPs...
./bootstrap.sh <label>            # recapture + realign the pointer
touch "$ROTATOR_STORE/ENABLED"    # resume rotation
```
