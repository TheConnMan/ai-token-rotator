# ai-token-rotator

**Seamlessly pool multiple AI coding subscriptions as one.** If you have two or more
accounts with an AI coding tool, each with its own subscription, this rotates the
account the tool is actively using so your work automatically runs against whichever
account still has budget. When one account hits its 5-hour or weekly limit, the
rotator hot-swaps to a fresher one within seconds, with no manual re-login and no
interruption to running jobs. It is built for unattended, long-running background
work that would otherwise stall the moment a single account runs out.

## Supported providers

Each provider rotates independently, with its own credential file, store, active
pointer, `ENABLED` sentinel, systemd service, and timer. Enable one or both.

| Provider | Rotates | Store | Scripts |
| --- | --- | --- | --- |
| Claude Code | `~/.claude/.credentials.json` | `$ROTATOR_STORE` (default `~/.claude/accounts`) | `rotate.sh`, `bootstrap.sh` |
| Codex | `~/.codex/auth.json` | `$CODEX_ROTATOR_STORE` (default `~/.codex/accounts`) | `codex-rotate.sh`, `codex-bootstrap.sh` |

The unprefixed scripts are the Claude provider; every Codex counterpart carries a
`codex-` prefix. The two share only `config.env` and this repo's decision logic, never
credential material. Labels are shared human names across providers, not shared
credentials: `acctA` may name one Claude account and a different Codex account.

Both providers work the same way. A pointer file records which account is live, a
systemd user timer ticks every `INTERVAL_MIN` minutes, and a tick swaps the stored
token for another account into the live credential file when a trigger fires. Claude
Code re-reads `.credentials.json` on nearly every API call, so a swap redirects even
already-running Claude jobs within seconds; Codex caches its account in a long-lived
app-server, so a Codex swap additionally restarts that app-server once no work is in
flight (see "Codex account rotation"). With one account a provider is a monitored
no-op; it starts rotating the moment a second account is bootstrapped. See `SPEC.md`
for the full behavior and acceptance criteria.

## Requirements

- **Linux with systemd** (the scheduler is a systemd *user* timer).
- **At least one supported tool** installed and working: Claude Code, Codex, or both.
- **Two or more accounts for that tool**, each with an active subscription, that you
  can log into normally (`/login` in Claude Code, `codex login` for Codex). One
  account works too; that provider just runs as a monitored no-op until you add a
  second.
- **`jq`**, **`curl`**, and **`flock`** on `PATH` (`bash`, `awk`, `date`, `stat`, `mktemp` are
  standard). On Debian/Ubuntu: `sudo apt install jq curl`.

## Quick start

This walks through the Claude provider; "Codex setup" below is the same shape with
`codex-` prefixed scripts. Pointing an agent at this repo? Hand it this README plus
`SPEC.md` (the SPEC is the full behavioral contract) and it has everything it needs.

```
# 1. Clone and enter the repo
git clone https://github.com/TheConnMan/ai-token-rotator.git
cd ai-token-rotator

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

Codex rotation is fully independent of Claude rotation and can be run on its own.
It rotates `~/.codex/auth.json` and shares no credential material with the Claude
store. List Codex labels separately in `CODEX_ACCOUNTS` in `config.env`, even when
those labels match `ACCOUNTS`.

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

A Codex swap restarts the app-server, so the rotator will not swap while a turn is
running. Unset `CODEX_INFLIGHT_CMD` uses the bundled `codex-inflight.sh`; set it to
empty to disable that gate. `./install.sh` also pins the Codex service unit to the
bundled probe.

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
decision, while the PIN file remains for the next weekly window; a known 100% weekly
reading clears the file on a live tick.

Codex uses the existing shared `WEEKLY_CEIL_<label>` resolver for both its PIN and
Trigger C ceiling decisions. The same label therefore has the same configured ceiling
for Claude and Codex. Separate provider ceilings remain a future design decision.
With one Codex account, `codex-rotate.sh` still polls and logs but never swaps.

## How it works: Claude

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

## Bootstrap flow: Claude

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
WEEKLY_CEIL_acctA=95   # also used interactively; keep 5% for the mobile and desktop apps
WEEKLY_CEIL_acctB=99   # background work only, drain it
```

Do not set a ceiling of exactly 100. Consumers treat it as an admission check and nothing
meters mid-job, so work admitted at 99 runs past 100 and fails hard.

## Pinning an account

Writing a configured label into `$ROTATOR_STORE/PIN` forces the rotator onto that
account and suspends Triggers A and B, so an external controller can keep a batch of
work on one account for as long as it needs:

```
echo acctB > "$ROTATOR_STORE/PIN"   # force acctB
rm "$ROTATOR_STORE/PIN"             # release
```

While the file exists the tick reports `decision=PINNED`, which is distinct from
`HOLD` (no trigger fired). Details worth knowing:

- **The writer owns ordinary cleanup.** `rotate.sh` retains `PIN` at the configured
  reserve ceiling, but clears it on a live tick once known weekly usage reaches 100%.
  This prevents a fully exhausted bonus-drain subscription from being repinned after
  its weekly window resets.
- **A pin on a capped account is released for that tick.** If the pinned account is at
  or above its own `WEEKLY_CEIL_<label>`, the tick degrades to normal rotation. The
  `PIN` file is left in place, so the pin resumes once that account's weekly resets;
  at 100% weekly utilization the file is instead cleared.
- **An unconfigured or empty pin holds on the current account** and still reports
  `PINNED`, rather than stranding the pointer on an account the rotator never polls.
- Codex has its own independent `PIN` in `$CODEX_ROTATOR_STORE`.

If an external controller enforces its own drain ceiling, keep it equal to this
rotator's ceiling for the same account. When the two disagree, one system reads a
mid-drain account as exhausted while the other reads it as healthy, and work gets
routed away from an account that still has budget.

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
fetch fails (idle token expired, 401) is UNKNOWN: unknown never fires a
trigger and is never a target. There is no stale-usage fallback;
`<label>.usage.json` is informational only.

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

## Logs and troubleshooting

Every tick appends one timestamped decision line to `$ROTATOR_STORE/rotate.log`
(Codex writes to `$CODEX_ROTATOR_STORE/rotate.log`):

```
tail -f ~/.claude/accounts/rotate.log
tail -f ~/.codex/accounts/rotate.log
./rotate.sh status                      # dry read-out, never writes or swaps
./codex-rotate.sh status
systemctl --user list-timers 'cc-*token-rotator*'
journalctl --user -u cc-token-rotator.service -n 50
```

Common cases:

- **Nothing in the log at all.** The `ENABLED` sentinel is missing, so every tick
  exits immediately. `touch "$ROTATOR_STORE/ENABLED"`.
- **`Trigger:n/a`, or the log stops for hours.** The timer is not firing. Check
  `systemctl --user list-timers`, and on a headless box confirm
  `loginctl enable-linger "$USER"` so user units survive logout.
- **An account's usage reads as unknown.** Its idle token could not be refreshed or
  polled. Unknown is never treated as zero: the account fires no trigger and is never
  a swap target, so rotation continues safely on the accounts that do report.
- **The pointer disagrees with reality** after an out-of-band `/login`. See
  "Active-pointer desync recovery" above.
- **A Codex swap did not reach running work.** The Codex app-server caches its account
  at startup, so `CODEX_APPSERVER_RESTART=1` is what makes a swap take effect. The
  restart is deliberately blocked while `CODEX_INFLIGHT_CMD` reports work in flight,
  so a busy box can hold on the same account for several ticks.
- **No Codex job can start at all after a swap.** The rotator restarts the app-server's
  systemd user unit when one owns the process, and only signals the process when none
  does. If the daemon is run from a unit the rotator cannot see or restart, a swap can
  kill it with nothing left to bring it back. Check with
  `systemctl --user status codex-remote-control.service`, and note that a `Type=oneshot`
  unit reports `active (exited)` even when its daemon is gone; confirm against
  `pgrep -af "app-server --remote-control"`. Restarting that unit is the recovery, and
  setting `CODEX_APPSERVER_BACKSTOP_UNIT` to it makes a later tick do that recovery
  for you instead of leaving the box stranded until someone notices.

## Uninstall

```
rm -f "$ROTATOR_STORE/ENABLED" "$CODEX_ROTATOR_STORE/ENABLED"   # stop rotating
systemctl --user disable --now cc-token-rotator.timer cc-codex-token-rotator.timer
rm -f ~/.config/systemd/user/cc-token-rotator.{service,timer} \
      ~/.config/systemd/user/cc-codex-token-rotator.{service,timer}
systemctl --user daemon-reload
```

The store is left alone; delete `~/.claude/accounts` and `~/.codex/accounts` yourself
once you are sure you no longer want the captured credentials.

## Security

This tool moves real OAuth credentials around your machine. What that means in
practice:

- **The store holds live credentials.** `<label>.json`, `mcp.json`, and the Codex
  `<label>.tokens` files contain usable access and refresh tokens. The store is
  created outside the repository (default `~/.claude/accounts` and `~/.codex/accounts`)
  with directory mode 0700 and file mode 0600. Every live Claude tick and bootstrap
  re-asserts the store: refuse a symlink, require owner == the current uid,
  `chmod 700` and verify that mode, and `chmod 600` `rotate.log` on append.
  Writes also use explicit `chmod`s plus a `umask 077`. An unsafe store skips
  the tick without writing credentials.
- **Never move the store inside the repository.** Point `ROTATOR_STORE` at a path a
  git working tree does not cover. `.gitignore` blocks the obvious names as a
  backstop, not as the primary control.
- **The real `config.env` is gitignored** because it names your accounts. Only
  `config.env.example` is committed.
- **Nothing is sent anywhere but the provider.** The only network calls are the
  Anthropic OAuth usage endpoint, the Codex usage endpoint, and `auth.openai.com` for
  a Codex token refresh, each with that account's own bearer token.
- **This runs on your own logged-in accounts.** It performs no login, bypasses no
  limit, and creates no accounts: it swaps between accounts you already authenticated
  yourself. Check that pooling your own subscriptions this way is consistent with the
  terms you agreed to.
