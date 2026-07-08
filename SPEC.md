# claude-token-rotator SPEC

This file is the full acceptance criteria. There is no Linear ticket. Build it test-first.

## Purpose

Automatically rotate the active Claude Code OAuth account across N logged-in Max
accounts by hot-swapping `~/.claude/.credentials.json`, so unattended background
work keeps running against whichever account has budget. Driven by a systemd user
timer. With one account it is a monitored no-op; it starts rotating the moment a
second account is bootstrapped.

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
- Access token lifetime is about 6h and is auto-refreshed by the active process
  (which rewrites the file). An idle account is frozen: nothing refreshes it, so its
  stored copy stays valid and refreshes on first use when swapped back in.
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
- `ACCOUNTS="acctA acctB"`     space-separated labels; N accounts

## Usage endpoint (reuse this exact shape; see reference/prototype and the drain controller usage.sh)

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
   write if DRY). On 401/failure (idle token expired), fall back to that label's last
   `<label>.usage.json`; treat a missing weekly as unknown (exclude from min /
   divergence), and never let an unknown value fire a trigger.
6. decide:
   - Trigger A (5h pressure): ACTIVE `five_hour.utilization >= FIVE_HOUR_PCT`.
     Target = the account other than ACTIVE with the LOWEST `five_hour.utilization`.
   - Trigger B (weekly divergence): across accounts with known weekly,
     `(max - min) >= effective dead zone`. The dead zone is `WEEKLY_DIVERGENCE_PCT`
     by default, tightening to 5 when the floor (min weekly) is >= 80 and to 2.5 when
     it is >= 90 (configurable). Target = the account with MIN weekly.
   - If both fire, Trigger A target wins (relieving 5h pressure is urgent); use weekly
     as a tie-break among equal-headroom candidates.
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

Use a temp `ROTATOR_STORE` and temp `ROTATOR_CRED` (fixtures), and a stubbed
`fetch_usage` (inject usage JSON via env or a mock function) so decisions are
deterministic. NEVER touch the real `~/.claude`. Cover:
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
Mock ONLY the external usage HTTP call (and the clock if needed). Do NOT mock file ops.

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
