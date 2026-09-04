#!/usr/bin/env bash
# Report bonus-drain work that is in flight right now for one provider, one line per run.
#
# The app-server probe (`codex-inflight.sh`) sees every turn the app-server itself is
# running, which is why it is the primary Codex signal. It cannot see work a dispatcher
# launched outside that daemon, and it does not exist at all on the Claude side. A
# dispatcher that keeps its own durable record can be asked directly, and bonus-drain keeps
# exactly that record: a run row is `dispatched` until a terminal event replaces it, so a
# dispatch with no terminal event is a job still running. Ask for it and the gate covers
# work the daemon never saw.
#
# Contract expected by INFLIGHT_CMD / CODEX_INFLIGHT_CMD:
#   stdout non-empty, exit 0 -> work is in flight, do not swap
#   stdout empty,     exit 0 -> the coast is clear
#   exit non-zero            -> unknown, which the rotator treats as in flight
set -uo pipefail

provider="${1:-}"
if [ -z "$provider" ]; then
    echo "usage: drain-inflight.sh <provider-id>" >&2
    exit 2
fi

# A box with no bonus-drain has no drain work, which is a real answer, not an unknown.
# Only a dispatcher that exists and then fails to answer is unknown.
bin="${BONUS_DRAIN_BIN:-$(command -v bonus-drain 2>/dev/null || true)}"
[ -n "$bin" ] && [ -x "$bin" ] || exit 0

out=$("$bin" inflight --provider "$provider" --json 2>/dev/null) || exit 1
[ -n "$out" ] || exit 1

BONUS_DRAIN_INFLIGHT_JSON="$out" python3 - <<'PY'
import json, os, sys

try:
    payload = json.loads(os.environ["BONUS_DRAIN_INFLIGHT_JSON"])
    runs = payload["runs"]
    if not isinstance(runs, list):
        raise TypeError("runs must be a list")
except Exception:
    # A reply we cannot parse is not an absence of work. Exit non-zero so the
    # rotator reads it as in flight and holds.
    sys.exit(1)

for run in runs:
    if not isinstance(run, dict):
        sys.exit(1)
    task = run.get("task") or "?"
    account = run.get("account_id") or "?"
    age = run.get("age_seconds")
    age = f"{age}s" if isinstance(age, (int, float)) else "?"
    print(f"{task} account={account} age={age}")
PY
