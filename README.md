# claude-token-rotator

**Seamlessly pool multiple Claude subscriptions as one.** If you have two or more
Claude accounts, each with its own subscription, this rotates the account Claude
Code is actively using so your work automatically runs against whichever account
still has budget. When one account hits its 5-hour or weekly limit, the rotator
hot-swaps to a fresher one within seconds, with no manual `/login` and no
interruption to running jobs. It is built for unattended, long-running background
work that would otherwise stall the moment a single account runs out.

It works by rotating the active Claude Code OAuth account across your logged-in
accounts, hot-swapping `~/.claude/.credentials.json` on a systemd user timer.
Claude Code re-reads `.credentials.json` on nearly every API call, so atomically
rewriting the account token in that file redirects even already-running jobs
within seconds. With one account this is a monitored no-op; it starts rotating
the moment a second account is bootstrapped. See `SPEC.md` for the full behavior
and acceptance criteria.

## Requirements

- **Linux with systemd** (the scheduler is a systemd *user* timer).
- **Claude Code** installed and working.
- **Codex** installed and working when rotating Codex accounts.
- **Two or more Claude accounts**, each with an active subscription, that you can
  `/login` to in Claude Code. (One account works too; it just runs as a monitored
  no-op until you add a second.)
- **`jq`**, **`curl`**, and **`flock`** on `PATH` (`bash`, `awk`, `date`, `stat`, `mktemp` are
  standard). On Debian/Ubuntu: `sudo apt install jq curl`.

## Quick start

Pointing an agent at this repo? Hand it this README plus `SPEC.md` (the SPEC is the
full behavioral contract) and it has everything it needs. To set up by hand:

```
# 1. Clone and enter the repo
git clone https://github.com/TheConnMan/claude-token-rotator.git
cd claude-token-rotator

# 2. Create your config and list the account labels you will use
cp config.env.example config.env
$EDITOR config.env          # set ACCOUNTS="acctA acctB" (your labels) + thresholds

# 3. Capture each account (see "Bootstrap flow" below for the MCP details).
#    In claude, /login to the account, then bootstrap it with a matching label:
./bootstrap.sh acctA
./bootstrap.sh acctB        # repeat /login + bootstrap for each account

# 4. Go live: create the master-switch sentinel
touch ~/.claude/accounts/ENABLED

# 5. Install and start the timer (the scheduled runner)
./install.sh

# 6. (Headless boxes only) keep the user timer running while logged out:
loginctl enable-linger "$USER"
```

The labels you bootstrap in step 3 MUST match the `ACCOUNTS` list in `config.env`.
Confirm the current decision at any time with `./rotate.sh status`. Installing the
timer is safe at any point: `rotate.sh` no-ops until the `ENABLED` sentinel exists.

## Codex account rotation

Codex rotation runs beside Claude rotation, with its own credentials, store, active
pointer, sentinel, service, and timer. It rotates `~/.codex/auth.json`; it does not
share credential material with the Claude store. The Codex store is
`$CODEX_ROTATOR_STORE`, defaulting to `~/.codex/accounts`.

Labels are shared human names across providers, not shared credentials. For example,
`Personal` may identify one Claude credential and a different Codex credential. List
Codex labels separately in `CODEX_ACCOUNTS` in `config.env`, even when the labels
match `ACCOUNTS`.

The Codex store contains the following raw files:

```
<label>.tokens      stored Codex token object
<label>.usage.json  last usage snapshot
active              label currently stored in the live Codex auth file
ENABLED             rotation sentinel
PIN                 optional operator selected label
rotate.log          timestamped decisions
rotate.lock         shared operation lock
```

Like the Claude store, it is outside the repository and has restrictive permissions.

## Codex setup

For each Codex account, run `codex login`, then capture that account with
`./codex-bootstrap.sh <label>`. Repeat for every `CODEX_ACCOUNTS` label. Bootstrap
sets the Codex active pointer to the account just captured. After all accounts are
captured, enable Codex rotation:

```
touch ~/.codex/accounts/ENABLED
```

`./codex-rotate.sh status` prints the current decision without changing credentials.
`./install.sh` installs and starts both the Claude and Codex systemd user timers.
Each service remains inactive until its own `ENABLED` file exists.

## Codex usage, PIN, and ceilings

Each tick polls every stored Codex account directly through the authenticated WHAM
usage request, using that account's bearer token and ChatGPT Account Id header. This
keeps idle accounts observable. If an idle poll fails because its access token has
expired, the rotator refreshes it once through `auth.openai.com` and retries the poll.
It does not synthesize a Codex run. When a reported five hour or weekly reset time is
already past, that window is treated as zero usage because the backend can retain the
previous window until a real Codex run. An explicit `credits.has_credits=false` still
means the account is exhausted.

Writing a configured label to the Codex store `PIN` holds that label selected while it
is usable. A PIN for an account at its weekly ceiling is released for the current
decision, while the PIN file remains for the next weekly window.

Codex uses the existing shared `WEEKLY_CEIL_<label>` resolver for both its PIN and
Trigger C ceiling decisions. The same label therefore has the same configured ceiling
for Claude and Codex. Separate provider ceilings remain a future design decision.
With one Codex account, `codex-rotate.sh` still polls and logs but never swaps.

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
- `WEEKLY_CEIL_DEFAULT` (default 98) and per-account `WEEKLY_CEIL_<label>`: the weekly
  ceiling each account is held to. See "Per-account ceilings" below.
- `ACCOUNTS` (required): space-separated labels, one per bootstrapped account.

## Per-account ceilings

Each account has its own weekly ceiling, and at or above it the account is **capped**:
the rotator moves the pointer off it, never swaps onto it, and releases an operator PIN
held on it.

The point is to reserve budget for surfaces this rotator does not control. The Claude
mobile and desktop apps spend the **same** `seven_day` allowance the rotator polls, and
they spend it whether or not the CLI is pointed at that account. Without a ceiling,
unattended background work will drain an account to the limit and your phone stops
working mid-week. So give an account you also use interactively a ceiling below 100, and
let an account reserved for background work sit near 100:

```sh
WEEKLY_CEIL_acctA=95   # keep 5% for the mobile and desktop apps
WEEKLY_CEIL_acctB=99   # background work only, drain it
```

Do not set a ceiling of exactly 100. Consumers treat it as an admission check and nothing
meters mid-job, so work admitted at 99 runs past 100 and fails hard.

## Decision rule

Utilization is on a 0-100 scale. On each tick:

- Trigger A (5h pressure): if the ACTIVE account's 5h utilization is at or above
  `FIVE_HOUR_PCT`, swap to the other account with the LOWEST 5h utilization (ties
  broken by lowest weekly).
- Trigger C (weekly ceiling): if the ACTIVE account is at or above its own ceiling,
  swap to the account with the most headroom under ITS own ceiling. Headroom rather
  than raw weekly, because an account at 60 against a ceiling of 95 has less left to
  give than one at 60 against 99.
- Trigger B (weekly divergence): if the spread between the maximum and minimum
  weekly utilization is at or above the effective dead zone, swap to the account
  with the MINIMUM weekly utilization. The dead zone is `WEEKLY_DIVERGENCE_PCT` by
  default, tightening to 5 when the floor (min weekly) is at or above 80 and to 2.5
  when it is at or above 90.
- Precedence is A, then C, then B. A and C both mean the active account is unusable,
  so they outrank B, which only expresses a preference between two usable accounts.
- A capped account is never a target, whichever trigger is choosing.

Trigger C is not redundant with B. Divergence only approximates a ceiling by
coincidence: when two accounts both sit near their respective ceilings the spread
between them collapses below the dead zone, B goes quiet, and the pointer would stay
parked on the capped account spending its reserve.

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
