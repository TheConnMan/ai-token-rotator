# ai-token-rotator SPEC

This file is the full acceptance criteria and the behavioral contract. Build it test-first.

## Purpose

Automatically rotate the active account of an AI coding tool across N logged-in
accounts, so unattended background work keeps running against whichever account has
budget. Driven by a systemd user timer. With one account it is a monitored no-op; it
starts rotating the moment a second account is bootstrapped.

Two providers are in scope and rotate independently, sharing decision logic and
`config.env` but no credential material: Claude Code (hot-swapping
`~/.claude/.credentials.json`) and Codex (hot-swapping `~/.codex/auth.json`). Every
section below specifies the Claude provider unless it says Codex.

## Verified mechanism (do not re-litigate)

- Claude Code re-reads `~/.claude/.credentials.json` on nearly every API call
  (measured: 24 reads in 90s), so atomically rewriting the file redirects even
  already-running jobs within seconds.
- The file is a regular file (mode 0600) with `.claudeAiOauth` (account token) and
  `.mcpOAuth.*` (per-MCP tokens). A swap replaces ONLY `.claudeAiOauth`, preserving
  the live `.mcpOAuth`. MCP tokens are account-independent, so they live permanently
  in the live credentials file and rotation never moves them.
- The swap-in is a read-modify-write: read the live cred, replace its
  `.claudeAiOauth` from the target's stored token, build a temp in the cred's dir,
  validate the temp has `.claudeAiOauth.accessToken`, and rename over the live file.
  ABORT rather than write if the result would be invalid, so the live file is never
  torn and never invalid.
- Access token lifetime is about 6h. The ACTIVE account is auto-refreshed by the
  live Claude client (which rewrites the credentials file); the rotator never
  refreshes the active account out of band. Idle NON-active accounts are no longer
  frozen: on a LIVE tick the rotator refreshes an idle account's stored token via its
  stored refresh token before polling that account's usage, so an idle account's
  usage stays observable and its slot stays valid for a later swap-in. DRY/status
  never refreshes (refresh rotates the server-side refresh token and must not persist
  on a dry run).
- The access token is opaque (not a JWT), so there is no embedded account identity.
  The active account is tracked by an `active` pointer file.
- Do NOT use a symlink for `.credentials.json`. Claude's atomic refresh-write
  (temp file + rename) would replace the symlink with a regular file on the first
  refresh and orphan the store. Use the read-modify-write swap plus sync-out (below).

## Store (outside the repo, never committed): `$ROTATOR_STORE` (default `$HOME/.claude/accounts`, dir 0700)

- `<label>.json`        TOKEN-ONLY copy for that account: `{"claudeAiOauth": {...}}`, no `.mcpOAuth` (0600)
- `mcp.json`            the shared canonical MCP set: `{"mcpOAuth": {...}}` (0600)
- `<label>.usage.json`  `{"five_hour":{"utilization":N,"resets_at":"..."},"seven_day":{...},"captured_at":EPOCH}`
- `active`              text file: the label currently occupying `.credentials.json`
- `ENABLED`             sentinel; rotate is a no-op unless this exists
- `rotate.log`          append-only, ISO-8601 timestamps

## Path overrides (REQUIRED for safe testing)

`lib.sh` MUST honor two env overrides, defaulting to the real paths, so the test
suite never touches the real `~/.claude`:
- `ROTATOR_CRED`  default `$HOME/.claude/.credentials.json`
- `ROTATOR_STORE` default `$HOME/.claude/accounts`

## Config (`config.env`; commit `config.env.example`, gitignore the real `config.env`)

- `FIVE_HOUR_PCT=80`            swap when the active account's 5h utilization >= this
- `WEEKLY_DIVERGENCE_PCT=10`    base dead zone; swap when (max weekly - min weekly across accounts) >= this. Tightens adaptively as the floor (min weekly) climbs: to `WEEKLY_DIVERGENCE_HI_PCT=5` at floor >= `WEEKLY_DIVERGENCE_HI_FLOOR=80`, and to `WEEKLY_DIVERGENCE_VHI_PCT=2.5` at floor >= `WEEKLY_DIVERGENCE_VHI_FLOOR=90` (all configurable)
- `INTERVAL_MIN=15`            systemd timer cadence
- `WEEKLY_CEIL_DEFAULT=98`     weekly ceiling for any account with no explicit entry
- `WEEKLY_CEIL_<label>`        per-account override, 0-100. An account at or above its own
  ceiling is CAPPED: Trigger C moves the pointer off it, no trigger may target it, and a PIN
  held on it releases. The gap below 100 reserves budget for surfaces the rotator does not
  control (the Claude mobile and desktop apps spend the same `seven_day` allowance, whether
  or not the CLI points at that account). Never set 100: consumers treat the ceiling as an
  admission check and nothing meters mid-job, so work admitted at 99 overruns and hard-fails
- `ACCOUNTS="acctA acctB"`     space-separated labels; N accounts

## Usage endpoint (reuse this exact shape; see `reference/prototype`)

`GET https://api.anthropic.com/api/oauth/usage`
Headers: `Authorization: Bearer <that account's accessToken>`,
`anthropic-beta: oauth-2025-04-20`, `Content-Type: application/json`; `curl --max-time 6`.
Utilization scale is 0-100. Fields: `.five_hour.utilization` / `.five_hour.resets_at`,
`.seven_day.utilization` / `.seven_day.resets_at`.

## Commands

### `bootstrap.sh <label>`
One-time per account. Precondition: you are currently logged into that account.
1. `mkdir -p` store (0700).
2. valid-cred check on the live cred file, else abort with a clear message.
3. capture TOKEN-ONLY (`{"claudeAiOauth": {...}}`) into `<label>.json` (0600).
4. MCP handling. A `/login` MAY clear the live `.mcpOAuth`, though in practice the
   MCP tokens often survive it; bootstrap handles both cases. If the live `.mcpOAuth`
   is non-empty, capture the shared MCP set from this fully-authed account into
   `mcp.json` (grow-merging the live set into the shared set). If the live `.mcpOAuth`
   is empty (a `/login` cleared it) and `mcp.json` exists, restore the shared MCP
   set into the live cred so this account regains MCP access; if `mcp.json` does
   not exist yet, warn to auth the MCP servers on the account that has them and
   bootstrap THAT account first.
5. best-effort fetch that account's usage now and write `<label>.usage.json`.
6. set the `active` pointer to `<label>` unconditionally (realigns after an
   out-of-band `/login`).
7. print next steps (auth all MCPs on the first account then bootstrap it; for each
   other account `/login` then bootstrap it to restore the shared MCP set; then
   `touch ENABLED`).

### `rotate.sh [status]`
Default is the tick. `status` is a dry read-out: compute and print, never write or swap.
1. `status` arg => DRY mode.
2. not DRY: `[ -f "$STORE/ENABLED" ] || exit 0`.
3. require the `active` pointer; read ACTIVE. Read ACCOUNTS. If only one account,
   it is a monitored no-op: still poll and log, never swap.
4. sync-out (skip if DRY): if the live cred file is valid, capture its token
   (token-only) into `<ACTIVE>.json` and refresh the shared `mcp.json` from its
   live `.mcpOAuth` (no-op if empty; a failure here is non-fatal). If the live file
   is currently invalid (Claude mid-write), log and exit 0. NEVER write a
   partial/invalid file into the store. If the token capture fails, log and exit 0
   (do not proceed to swap).
5. poll usage for EVERY account: use each account's stored accessToken (ACTIVE uses
   the live file, which is freshest). On success update `<label>.usage.json` (skip
   write if DRY). On a failed poll of a NON-active account (idle token expired or
   rejected), in LIVE mode only, refresh that account's stored token via its stored
   refresh token and retry the poll once (never refresh twice for one account in one
   tick). If the refresh or the retried poll still fails, the value is UNKNOWN: there
   is NO stale-usage fallback, so a stale `<label>.usage.json` is never read into a
   decision (it stays only as an informational record). The ACTIVE account is never
   refreshed out of band (the live client owns its refresh-token rotation), and
   DRY/status never refreshes. Treat a missing, non-numeric, or out-of-range
   utilization (not a number in 0-100 inclusive) as unknown (exclude from min /
   divergence), and never let an unknown value fire or be targeted by a trigger.
   Unknown is empty, never 0: zero reads as maximum headroom and wins every
   comparison.
6. decide:
   - Trigger A (5h pressure): ACTIVE `five_hour.utilization >= FIVE_HOUR_PCT`.
     Target = the account other than ACTIVE with the LOWEST `five_hour.utilization`.
   - Trigger B (weekly divergence): across accounts with known weekly,
     `(max - min) >= effective dead zone`. The dead zone is `WEEKLY_DIVERGENCE_PCT`
     by default, tightening to 5 when the floor (min weekly) is >= 80 and to 2.5 when
     it is >= 90 (configurable). Target = the account with MIN weekly.
   - Trigger C (weekly ceiling): ACTIVE weekly is known and `>= weekly_ceil(ACTIVE)`.
     Target = the account with the most headroom under ITS OWN ceiling
     (`ceil - weekly`), which is the correct comparison when ceilings differ. Requires
     a known weekly on the candidate; if none has one, C does not fire and B still runs.
   - No trigger may target a CAPPED account (known weekly `>= ` its own ceiling).
     Unknown weekly is NOT capped, matching the rule that an unread number never fires
     a trigger and never disqualifies an account.
   - Precedence: A, then C, then B. A and C both say the active account is unusable, so
     they outrank B, which only prefers between two usable accounts. Use weekly as a
     tie-break among equal-headroom candidates.
   - Trigger C is NOT redundant with B. Divergence approximates a ceiling only by
     coincidence: when accounts sit near their respective ceilings the spread collapses
     below the dead zone, B goes quiet, and the pointer stays parked on the capped
     account spending its reserve.
   - SHOULD_SWAP only if a valid target exists, `target != ACTIVE`, and
     `valid_cred(<target>.json)`.
7. always emit one decision line: ACTIVE, every account's (5h, weekly), trigger
   states, chosen target, decision. In `status` mode print to stdout and exit 0.
8. swap (SHOULD_SWAP and not DRY): swap in the token only, replacing the live
   `.claudeAiOauth` from `<target>.json` while preserving the live `.mcpOAuth`
   (read-modify-write, abort if invalid). On success set `active` = target and log
   `SWAP <ACTIVE> -> <target>: <reason> (usages)`; on failure log SWAP FAILED and
   leave the live cred and pointer unchanged.

### `install.sh`
Generate the timer unit from `INTERVAL_MIN`, copy the service + timer into
`~/.config/systemd/user/`, `daemon-reload`, `enable --now` the timer. Idempotent.
State clearly that installing is safe because rotate is a no-op until `ENABLED`
exists. Do NOT create `ENABLED`.

## systemd units

- service: `Type=oneshot`, `ExecStart=<repo>/rotate.sh`, a short Description.
- timer: `OnBootSec=5min`, `OnUnitActiveSec=${INTERVAL_MIN}min`, `Persistent=true`,
  `[Install] WantedBy=timers.target`.

## lib.sh helpers

`log`, `fetch_usage(token)`, `atomic_replace(src,dst)` (temp file in the same dir +
chmod 600 + `mv -f`), `valid_cred(path)` (`jq -e '.claudeAiOauth.accessToken'`),
ACCOUNTS parsing, usage-json read/write. Honor `ROTATOR_CRED` / `ROTATOR_STORE`.

Refresh helpers (for the idle-account refresh path):
- `token_expired(file)` return 0 (true) iff `.claudeAiOauth.expiresAt` (epoch MS) is
  missing/null or is at/under `now_ms + 60000` (60s skew); now_ms is `date +%s` * 1000.
- `refresh_access_token(store_file)` POST the stored `.claudeAiOauth.refreshToken` to
  `https://console.anthropic.com/v1/oauth/token` (`grant_type=refresh_token`, the
  known client_id), body via stdin (`--data @-`, keeping the refresh token out of
  argv). On success (response has `.access_token`) atomically rewrite `store_file`'s
  `.claudeAiOauth` accessToken, expiresAt (`now_ms + expires_in*1000`), and refreshToken
  (persisting a ROTATED one, else keeping the existing), preserving all other fields;
  echo the new access token, return 0. Any failure => return 1, echo nothing,
  `store_file` untouched. Test hook: `ROTATOR_REFRESH_MOCK_DIR` reads
  `<refreshToken>.json` from that dir as the simulated response (absent => failure),
  mirroring `fetch_usage`'s `ROTATOR_USAGE_MOCK_DIR`.

Token-only helpers (all atomic: temp in the destination dir + chmod 600 + `mv -f`):
- `capture_token(cred,dst)`  write `{"claudeAiOauth": (cred.claudeAiOauth)}` to `<label>.json`.
- `capture_mcp(cred,dst)`    grow-merge the live `.mcpOAuth` into `mcp.json` (`dst.mcpOAuth * cred.mcpOAuth`, so live refreshes overlapping server tokens while canonical-only servers are preserved); first capture writes the live set as-is; no-op if the live MCP set is empty.
- `mcp_is_empty(cred)`       true iff `cred` has no `.mcpOAuth` or it is an empty object.
- `restore_mcp(mcp,cred)`    deep-merge the stored `.mcpOAuth` into the live cred (`live * stored`), preserving live entries; abort if the result is not valid with `.claudeAiOauth.accessToken`.
- `swap_in_token(target,cred)` read the live cred, replace `.claudeAiOauth` from `target`, preserve all other live fields; validate the temp before rename, abort otherwise.

## Invariants (MUST)

- `set -uo pipefail`; `bash -n` clean; `shellcheck` clean (justify any ignores in a comment).
- ATOMIC token swap (temp + rename on one filesystem). Never a torn write; abort
  rather than write an invalid live file. MCP tokens are never moved by a swap.
- sync-out-before-swap-in ALWAYS (preserves the rotated account-token refresh).
- Never overwrite the store from an invalid/partial live file.
- Store dir 0700; every written file 0600.
- Read-modify-write over the live cred, NOT a symlink.
- N=1 => monitored no-op. Target must never equal ACTIVE.
- Config thresholds honored; utilization scale 0-100.
- Real tokens never committed; real `config.env` and the store are gitignored.
- Account-SCOPED connectors (e.g. claude.ai UI connectors) are explicitly OUT of
  rotation scope: the token-only swap preserves the shared third-party `.mcpOAuth`
  but does not carry per-account connector identity, so those need a per-account
  reconnect (matches the README note).
- Swap-in is a lock-free read-modify-write: it builds a temp and renames, aborting
  if the merged result is invalid, so it never writes a torn/invalid live file. The
  residual is that a concurrent MCP-token refresh landing in the read-then-rename
  window can be lost (self-healing on next use, except for MCP providers that rotate
  refresh tokens). This is an accepted residual: Claude Code offers no flock
  cooperation, so there is no lock to take.

## Tests (test-first, bats or plain-bash asserts)

Use a temp `ROTATOR_STORE` and temp `ROTATOR_CRED` (fixtures), a stubbed
`fetch_usage` (`ROTATOR_USAGE_MOCK_DIR`), and a stubbed token refresh
(`ROTATOR_REFRESH_MOCK_DIR`) so decisions are deterministic. NEVER touch the real
`~/.claude`. Cover:
- ENABLED gate absent => exit 0, no writes; cred fixture byte-identical (sha256).
- N=1 never swaps regardless of usage.
- Trigger A: active 5h >= threshold => swaps to lowest-5h other; correct target among 3.
- Trigger B: weekly spread >= threshold => swaps to min-weekly; below threshold => no swap.
- Both triggers => A priority.
- sync-out captures the live account token into `<active>.json` before swap.
- invalid live cred => skip tick, store untouched.
- target missing/invalid => no swap.
- token-only swap leaves the cred file valid JSON with the target's account token
  and the PRESERVED live `.mcpOAuth`.
- bootstrap captures a token-only `<label>.json` plus the canonical `mcp.json`, and
  restores the shared MCP set into the live cred after a `/login` wipe.
- `status` mode mutates nothing.
- Non-active EXPIRED token + refresh mock present => the account is refreshed before
  polling; `<label>.json` gets the new accessToken + a future expiresAt and the polled
  usage drives the decision.
- Non-active EXPIRED token + refresh mock MISSING => the account is UNKNOWN, fires/targets
  no trigger, and `<label>.json` is byte-unchanged.
- Non-active failed poll with a stale `<label>.usage.json` on disk => the account is
  UNKNOWN; the stale usage is NOT read into the decision (no stale-usage fallback).
- Non-numeric utilization (e.g. `n/a`) is UNKNOWN, never 0, and is never a Trigger A
  target. A fresh identity-matched mirror missing `seven_day_pct`, or a world-writable
  (0666) mirror, is ignored in favor of the endpoint poll.
- The ACTIVE account is never refreshed out of band even with an expired live token and
  a refresh mock present.
- DRY/status never refreshes: `status` over an expired non-active token leaves
  `<label>.json` byte-unchanged.
- Refresh-token rotation is persisted: a rotated `refresh_token` in the response updates
  `<label>.json`'s refreshToken.
Mock ONLY the external usage + token-refresh HTTP calls (and the clock if needed). Do
NOT mock file ops.

## Done when

- All scripts + units + `config.env.example` + README.md + tests exist.
- Test suite passes (show the command and output).
- Safety proof: `rotate.sh` with no ENABLED exits 0 and leaves a sha256-identical cred fixture.
- README documents: bootstrap flow (auth all MCPs on the first account -> bootstrap
  it -> for each other account /login -> bootstrap it to restore the shared MCP set
  -> touch ENABLED), enable/disable via the ENABLED sentinel, the decision rule, N=1
  behavior, and active-pointer desync recovery (re-run bootstrap if you /login out of band).
- No dashes or emdashes in prose, no emojis.

## Reference

`reference/prototype/` holds an earlier 2-account prototype (hardcoded thresholds,
no config, no per-account polling). Use it as a design crib for the atomic-swap and
usage-fetch shapes only. The deliverable is the generalized N-account, config-driven
version in the repo root, built test-first.

## Codex extension

Codex rotation is a separate provider surface. It uses `~/.codex/auth.json`,
`CODEX_ROTATOR_STORE` (default `~/.codex/accounts`), and `CODEX_ACCOUNTS`. Labels
are shared human identifiers only: matching Claude and Codex labels identify separate
provider credentials. See `README.md` for operator setup.

### Codex store and swap

1. `<label>.tokens` stores the complete raw Codex token object from that account's
  live auth file. The store is outside the repository, mode 0700, and written files
  are mode 0600.
2. Bootstrap captures the currently logged in Codex account under its configured
  label and sets the separate Codex `active` pointer.
3. A swap atomically replaces only `.tokens` in the live Codex auth object from the
  target `<label>.tokens`, preserving every other live auth field. It validates the
  target and merged result before rename, so invalid input never replaces live auth.

### Codex tick

1. The Codex rotator is gated by its own `ENABLED` sentinel. Installation creates an
  independent Codex service and timer beside the Claude units. Neither provider
  sentinel enables the other provider.
2. Every tick polls each Codex account directly through the authenticated WHAM usage
  endpoint, including idle accounts. It does not create a synthetic Codex run.
3. If a nonactive poll fails during a live tick, refresh that stored account once and
  retry its WHAM poll once. Do not refresh the active account out of band. A failed
  refresh or retry leaves usage unknown and never eligible to fire or target a normal
  trigger swap.
4. If a returned five hour or weekly reset is already past, normalize that window to
  zero usage without a synthetic run. A real rate limit window always wins over the
  `credits` object: on a ChatGPT Plus or Pro plan `credits.has_credits=false` means no
  pay as you go top up balance and says nothing about the plan's included weekly quota.
  `credits.has_credits=false` marks the account exhausted ONLY in the windowless shape,
  where neither window is present and no other signal exists.
4a. A window that is absent or unreadable is UNKNOWN, never zero. These plans ship no
  five hour window at all, and the weekly window arrives in either the primary or the
  secondary slot, so identify windows by `limit_window_seconds` across both slots. A
  zero would read as maximum headroom and win every comparison.
5. The existing `weekly_ceil` resolver and `WEEKLY_CEIL_<label>` configuration govern
  Codex Trigger C and PIN ceiling behavior too. Matching labels therefore use the
  same weekly ceiling across providers.
6. A configured `PIN` with valid stored tokens forces that label active, suspends
  normal triggers, and reports `PINNED`. PIN force selection may choose the configured
  label even when its usage is unknown. An empty or unconfigured PIN holds the active
  label. A PIN is released for the current decision only when its known weekly usage
  reaches that label's weekly ceiling, while the PIN file remains for the next weekly
  window.
7. With one configured Codex account, the tick still polls and logs but never swaps.
8. Codex status is read only. It never refreshes, writes usage or logs,
  swaps auth, updates the pointer, or otherwise mutates provider state.
9. A swap alone reaches no Codex work. The app-server reads `auth.json` once at
  startup and caches that account for its whole lifetime, so the rotator kills the
  app-server after a swap that fully succeeded. It respawns on the next Codex
  Desktop connect and reads the new account then. `CODEX_APPSERVER_RESTART=0`
  disables the kill. The process ignores SIGTERM, so the kill is SIGKILL, and it is
  located by the pid listening on `CODEX_APPSERVER_SOCKET`.
10. Killing the app-server interrupts every running turn, so no swap fires while
  Codex work is in flight. `CODEX_INFLIGHT_CMD` is the probe: non-empty stdout means
  work is in flight. An unset probe disables the gate. A probe that exits non-zero is
  UNKNOWN and counts as in flight, because an unanswerable probe is never a licence
  to kill a job. The gate covers PIN forced swaps too.
10a. `codex-inflight.sh` is that probe. It asks the app-server itself, via
  `thread/list`, which threads are running. The app-server is the only component that
  sees every turn, so one probe covers Codex Desktop, the CLI, and any external
  dispatcher without any of them registering work anywhere. This matters most for
  dispatchers that keep no record the rotator could otherwise read.
  A thread counts as quiet only when its status is `idle` or `notLoaded`; every other
  status, known or not, holds the swap. Matching the quiet set rather than matching
  `active` is deliberate: an unrecognised status must hold rather than authorise a
  kill. A completed turn stays loaded as `idle`, so `idle` MUST be in the quiet set,
  or rotation wedges permanently. No app-server at all means nothing can be running,
  which is a real answer and not an unknown.
11. The app-server is killed only after the pointer write succeeds. An aborted or
  rolled back swap leaves it running, since the live auth is back on the account it
  was already serving.
