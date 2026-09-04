#!/usr/bin/env bash
# Union of every in-flight signal available for Codex: the app-server's own view of
# running turns, plus bonus-drain's record of dispatched work.
#
# Neither probe alone covers the ground. The app-server sees every turn it is running,
# whatever client started it, but not work a dispatcher launched outside that daemon.
# bonus-drain knows every job it dispatched, but nothing about Codex Desktop or a hand-run
# CLI. Holding on the union is the conservative read, and holding one extra tick costs far
# less than swapping the credential out from under a live job.
#
# Contract expected by CODEX_INFLIGHT_CMD, preserved here:
#   stdout non-empty, exit 0 -> work is in flight, do not swap
#   stdout empty,     exit 0 -> the coast is clear
#   exit non-zero            -> unknown, which the rotator treats as in flight
#
# Any probe reporting unknown makes the union unknown: one blind signal is enough to
# make "nothing is running" an unsupported claim.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

unknown=0
output=""

for probe in "$HERE/codex-inflight.sh" "$HERE/drain-inflight.sh codex"; do
    # Deliberately unquoted so a probe entry may carry arguments.
    # shellcheck disable=SC2086
    if out=$($probe 2>/dev/null); then
        [ -n "$out" ] && output="${output}${out}"$'\n'
    else
        unknown=1
    fi
done

[ "$unknown" -eq 1 ] && exit 1
printf '%s' "$output"
exit 0
