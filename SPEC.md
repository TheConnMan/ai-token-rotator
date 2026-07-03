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
  (measured: 24 reads in 90s), so atomically replacing the whole file redirects
  even already-running jobs within seconds.
- The file is a regular file (mode 0600) with `.claudeAiOauth` (account token) and
  `.mcpOAuth.*` (per-MCP tokens). We swap the WHOLE file. The user logs into all
  MCPs on every account, so each account's file is independently complete and valid.
- Access token lifetime is about 6h and is auto-refreshed by the active process
  (which rewrites the file). An idle account is frozen: nothing refreshes it, so its
  stored copy stays valid and refreshes on first use when swapped back in.
- The access token is opaque (not a JWT), so there is no embedded account identity.
  The active account is tracked by an `active` pointer file.
- Do NOT use a symlink for `.credentials.json`. Claude's atomic refresh-write
  (temp file + rename) would replace the symlink with a regular file on the first
  refresh and orphan the store. Use a whole-file copy plus sync-out (below).

## Store (outside the repo, never committed): `$ROTATOR_STORE` (default `$HOME/.claude/accounts`, dir 0700)

- `<label>.json`        full copy of `.credentials.json` for that account (0600)
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
- `WEEKLY_DIVERGENCE_PCT=20`    swap when (max weekly - min weekly across accounts) >= this
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
3. atomic-copy live cred file to `<label>.json` (0600).
4. best-effort fetch that account's usage now and write `<label>.usage.json`.
5. if the `active` pointer is absent, set it to `<label>`.
6. print next steps (login the next account, re-auth its MCPs, repeat; then `touch ENABLED`).

### `rotate.sh [status]`
Default is the tick. `status` is a dry read-out: compute and print, never write or swap.
1. `status` arg => DRY mode.
2. not DRY: `[ -f "$STORE/ENABLED" ] || exit 0`.
3. require the `active` pointer; read ACTIVE. Read ACCOUNTS. If only one account,
   it is a monitored no-op: still poll and log, never swap.
4. sync-out (skip if DRY): if the live cred file is valid, atomic-copy it to
   `<ACTIVE>.json` (captures any refresh/rotation of account + MCP tokens). If the
   live file is currently invalid (Claude mid-write), log and exit 0. NEVER write a
   partial/invalid file into the store.
5. poll usage for EVERY account: use each account's stored accessToken (ACTIVE uses
   the live file, which is freshest). On success update `<label>.usage.json` (skip
   write if DRY). On 401/failure (idle token expired), fall back to that label's last
   `<label>.usage.json`; treat a missing weekly as unknown (exclude from min /
   divergence), and never let an unknown value fire a trigger.
6. decide:
   - Trigger A (5h pressure): ACTIVE `five_hour.utilization >= FIVE_HOUR_PCT`.
     Target = the account other than ACTIVE with the LOWEST `five_hour.utilization`.
   - Trigger B (weekly divergence): across accounts with known weekly,
     `(max - min) >= WEEKLY_DIVERGENCE_PCT`. Target = the account with MIN weekly.
   - If both fire, Trigger A target wins (relieving 5h pressure is urgent); use weekly
     as a tie-break among equal-headroom candidates.
   - SHOULD_SWAP only if a valid target exists, `target != ACTIVE`, and
     `valid_cred(<target>.json)`.
7. always emit one decision line: ACTIVE, every account's (5h, weekly), trigger
   states, chosen target, decision. In `status` mode print to stdout and exit 0.
8. swap (SHOULD_SWAP and not DRY): atomic-copy `<target>.json` to the live cred file
   (0600), set `active` = target, log `SWAP <ACTIVE> -> <target>: <reason> (usages)`.

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

## Invariants (MUST)

- `set -uo pipefail`; `bash -n` clean; `shellcheck` clean (justify any ignores in a comment).
- Whole-file ATOMIC swap (temp + rename on one filesystem). Never a torn write.
- sync-out-before-swap-in ALWAYS (preserves rotated refresh + MCP tokens).
- Never overwrite the store from an invalid/partial live file.
- Store dir 0700; every written file 0600.
- Copy, NOT symlink.
- N=1 => monitored no-op. Target must never equal ACTIVE.
- Config thresholds honored; utilization scale 0-100.
- Real tokens never committed; real `config.env` and the store are gitignored.

## Tests (test-first, bats or plain-bash asserts)

Use a temp `ROTATOR_STORE` and temp `ROTATOR_CRED` (fixtures), and a stubbed
`fetch_usage` (inject usage JSON via env or a mock function) so decisions are
deterministic. NEVER touch the real `~/.claude`. Cover:
- ENABLED gate absent => exit 0, no writes; cred fixture byte-identical (sha256).
- N=1 never swaps regardless of usage.
- Trigger A: active 5h >= threshold => swaps to lowest-5h other; correct target among 3.
- Trigger B: weekly spread >= threshold => swaps to min-weekly; below threshold => no swap.
- Both triggers => A priority.
- sync-out copies live cred to `<active>.json` before swap (assert store updated).
- invalid live cred => skip tick, store untouched.
- target missing/invalid => no swap.
- atomic swap leaves the cred file valid JSON with target content.
- `status` mode mutates nothing.
Mock ONLY the external usage HTTP call (and the clock if needed). Do NOT mock file ops.

## Done when

- All scripts + units + `config.env.example` + README.md + tests exist.
- Test suite passes (show the command and output).
- Safety proof: `rotate.sh` with no ENABLED exits 0 and leaves a sha256-identical cred fixture.
- README documents: bootstrap flow (login acct -> bootstrap.sh -> repeat per account
  -> touch ENABLED), enable/disable via the ENABLED sentinel, the decision rule, N=1
  behavior, and active-pointer desync recovery (re-run bootstrap if you /login out of band).
- No dashes or emdashes in prose, no emojis.

## Reference

`reference/prototype/` holds an earlier 2-account prototype (hardcoded thresholds,
no config, no per-account polling). Use it as a design crib for the atomic-swap and
usage-fetch shapes only. The deliverable is the generalized N-account, config-driven
version in the repo root, built test-first.
