# ai-token-rotator

Systemd-timer utility that hot-swaps the active account of an AI coding tool across N
bootstrapped accounts. Two independent providers: Claude Code (`rotate.sh`,
`~/.claude/.credentials.json`) and Codex (`codex-rotate.sh`, `~/.codex/auth.json`).
Unprefixed scripts are the Claude provider. Read `SPEC.md` for the full behavior
contract and `README.md` for setup before changing anything.

## Git workflow

**Work in a worktree, then merge straight to `main`. No PR.**

```bash
git fetch origin main
git worktree add ../ctr-<desc> -b task/<desc> "$(git rev-parse origin/main)"
```

Cut from the freshest `origin/main`, never the local checkout. Commit on the branch,
merge into `main` locally once the gates below are green, then remove the worktree.
Do not open a pull request. Do not push; pushing is the maintainer's call.

This repo has a remote, but that does not make it PR gated. It is also not the
commit-straight-to-main pattern: the work happens on a branch, and `main` only ever
receives the merge.

## Gates

Both must pass before any merge, and both are fast:

```bash
bash tests/run_tests.sh
shellcheck *.sh
```

The gate runs the Claude and Codex provider suites. They run the real rotators as
subprocesses against temporary sandboxes and mock external usage, OAuth refresh,
and systemctl boundaries only. They never touch real provider homes, and a hard
`guard_tmp` abort enforces that. Keep it that way: do not add a test that points at a
real home path, and do not mock a file operation.

## Invariants that must not regress

Each of these exists because it broke something. Do not "simplify" one away.

* **Token-only swap.** Replace only `.claudeAiOauth` in the live credentials file and
  leave `.mcpOAuth` in place. MCP tokens live permanently in the live file and are
  never moved between accounts.
* **Never write a partial or invalid live credentials file.** `swap_in_token` aborts
  before writing if the result would be invalid. A torn credentials file logs every
  running session out at once.
* **Never refresh the ACTIVE account's token.** The live client owns its refresh-token
  rotation, and racing it can invalidate a running session. Poll the active account
  with the live file's token, or with the statusline mirror when it is fresh.
* **Unknown usage never fires a trigger and is never a trigger target.** A failed poll,
  or a missing/non-numeric/out-of-range utilization, leaves an account empty, not zero.
  Zero would read as maximum headroom and win every comparison. The statusline mirror
  is ignored unless it is owned by this uid, not world-writable, and both percentages
  are numeric 0-100.
* **Trigger B excludes 5h-pressured accounts from its target set.** Parking the pointer
  on a pressured account trips Trigger A on the next tick and bounces straight back, a
  stateless per-tick flap. This exclusion is the fix; do not drop it.
* **The pointer desync guard.** If the live token matches a different configured
  account's stored token, someone ran `/login` out of band. Bail without syncing out,
  or the sync overwrites the active slot with another account's credentials.
* **`ENABLED` sentinel gates live runs.** Without it, a live tick exits writing nothing.
  `rotate.sh status` is always a dry read and must never write or swap.
* **Codex usage: a real window beats the `credits` object.** `credits.has_credits=false`
  is normal on a ChatGPT Plus/Pro plan (it means no pay-as-you-go top-up) and says nothing
  about the included weekly quota. Reading credits first reported a brand-new subscription
  at 1% as fully spent, so the rotator would never swap onto it. Credits decide only in the
  windowless `premium` shape, where no window exists to read.
* **A missing usage window is unknown, never zero.** These plans ship no 5h window at all,
  and the weekly window can arrive in either the `primary_window` or `secondary_window`
  slot, so match on `limit_window_seconds`. Requiring both windows made every healthy
  account read as unknown; defaulting a missing one to zero would make it win every
  comparison.
* **A swap must restart the app-server.** The app-server reads `auth.json` once at
  startup and caches that account forever, so a swap alone reaches no Codex work at
  all. It is spawned unmanaged by Codex Desktop over SSH, so `codex app-server daemon
  restart` cannot manage it, and it ignores SIGTERM. SIGKILL plus Desktop's respawn is
  the only lever, verified 2026-08-19 in both directions.
* **Never swap while Codex work is in flight.** The restart above interrupts every
  running turn, proven by a live mid-turn kill. `CODEX_INFLIGHT_CMD` gates it, and an
  unanswerable probe counts as in flight. Waiting one tick is cheap; killing a running
  job is not. The gate covers PIN forced swaps too.
* **The in-flight probe asks the app-server, not a dispatcher's database.** Only the
  app-server sees every running turn, so `codex-inflight.sh` covers every Codex client
  on the box at once. A probe scoped to one dispatcher's own records would leave every
  other dispatcher's jobs invisible and killable.
* **`idle` is quiet, and the quiet set is what gets matched.** A completed turn leaves
  its thread loaded as `idle`, not evicted. An early version reported anything that
  was not `notLoaded` as in flight, which held every swap forever once any job had
  run. Match the quiet set so an unrecognised status holds instead of killing.
* **Only a fully successful swap kills the app-server.** On the rollback path the live
  auth is back on the account the app-server already serves, so a kill there would
  interrupt work to change nothing.
* **N=1 is a monitored no-op**, reached naturally through the normal decision path
  rather than by an early return.

## PIN, and the external-controller coupling

`$STORE/PIN` holds an account label. While present, the rotator forces `active` to that
account and suspends Triggers A and B, emitting `decision=PINNED`. `PINNED` is distinct
from `HOLD`, which only means no trigger fired this tick.

* An unconfigured or empty PIN holds on `active` and still reports `PINNED`. Pinning a
  label this rotator does not manage would strand `active` on an account later ticks
  never poll.
* **The writer owns ordinary PIN cleanup.** `rotate.sh` retains the file when the
  pinned account reaches its own `WEEKLY_CEIL_<label>` and the tick degrades to normal
  rotation, but clears it on a live tick when known weekly usage reaches 100%.
* The writer is whatever external controller you point at the store. A batch runner that
  wants its work kept on one account pins that label before each batch and clears the pin
  between batches. Nothing in this repo ever writes `PIN`.

When an external controller has its own drain ceiling, **keep it equal to this rotator's
`WEEKLY_CEIL_<label>` for the same account.** When the two diverge, a mid-drain account
reads as exhausted to one system and as healthy to the other, and work gets routed away
from accounts that still have budget.
