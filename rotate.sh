#!/usr/bin/env bash
# Token rotator tick. Default: poll every bootstrapped account and swap the live
# credentials file if the active account is under 5h pressure (Trigger A) or the
# weekly usage across accounts is too divergent (Trigger B). `rotate.sh status`
# is a dry read-out that computes and prints, but never writes or swaps.
#
# Utilization is on a 0-100 scale (Anthropic OAuth usage endpoint). Thresholds
# come from config.env; see config.env.example.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

# Config: thresholds + account list. Real config.env is gitignored.
# shellcheck source=/dev/null
[ -f "${ROTATOR_CONFIG:-$HERE/config.env}" ] && source "${ROTATOR_CONFIG:-$HERE/config.env}"
: "${FIVE_HOUR_PCT:=80}"
: "${WEEKLY_DIVERGENCE_PCT:=10}"
: "${INTERVAL_MIN:=15}"

# Test hook: warn (stderr only, no store writes) when the usage mock is active so
# a real run can never silently poll a mock instead of the real endpoint.
if [ -n "${ROTATOR_USAGE_MOCK_DIR:-}" ]; then
    printf '[warn] usage mock active (ROTATOR_USAGE_MOCK_DIR set); not polling the real endpoint\n' >&2
fi

DRY=0
[ "${1:-}" = "status" ] && DRY=1

# ENABLED gate: skip in dry mode so status always works. When live and the
# sentinel is absent, exit immediately writing NOTHING (no log, no swap).
if [ "$DRY" -eq 0 ] && [ ! -f "$STORE/ENABLED" ]; then
    exit 0
fi

# Require the active pointer.
if [ ! -f "$STORE/active" ]; then
    if [ "$DRY" -eq 1 ]; then
        echo "status: no active account set (store empty or not bootstrapped)"
    else
        log "no active account set"
    fi
    exit 0
fi
ACTIVE=$(cat "$STORE/active")

# Account list comes only from config (ACCOUNTS). No store-derivation fallback.
read -ra ACCT_ARR <<< "${ACCOUNTS:-}"
N=${#ACCT_ARR[@]}

# N=0: nothing configured. Log (or print in DRY) and exit; never swap.
if [ "$N" -eq 0 ]; then
    if [ "$DRY" -eq 1 ]; then
        echo "status: no accounts configured (ACCOUNTS empty)"
    else
        log "no accounts configured"
    fi
    exit 0
fi
# N=1 is a monitored no-op: it flows through poll + decision + log below and
# naturally never swaps (the only account equals ACTIVE, so target != ACTIVE
# can never hold => HOLD).

# PIN sentinel: an operator (bonus drain) can force the rotator onto a specific
# account by writing its label to $STORE/PIN. While present we force
# active=<label> by swapping in its stored token and SUSPEND Trigger A/B,
# emitting decision=PINNED. A stale PIN pins forever by design; the writer owns
# cleanup. PINNED is distinct from the HOLD decision, which means a trigger did
# not fire this tick. PINNED means swap decisions are operator driven.
PINNED=0
PIN_LABEL=""
if [ -f "$STORE/PIN" ]; then
    PINNED=1
    PIN_LABEL=$(cat "$STORE/PIN" 2>/dev/null)
fi

# sync-out (live only): capture any refresh/rotation of the active account's
# tokens back into the store before we might swap it away. Never overwrite the
# store from a partial/invalid live file.
if [ "$DRY" -eq 0 ]; then
    if valid_cred "$CRED"; then
        # Identity guard: if the live cred's accessToken matches a DIFFERENT
        # configured account's stored token, the pointer is desynced (someone
        # /login'd out of band). Syncing out here would overwrite ACTIVE's slot
        # with another account's creds, so bail without touching the store. A
        # legitimate token refresh is a new token and matches no stored account.
        live_tok=$(jq -r '.claudeAiOauth.accessToken' "$CRED")
        for label in "${ACCT_ARR[@]}"; do
            [ "$label" = "$ACTIVE" ] && continue
            valid_cred "$STORE/$label.json" || continue
            stored_tok=$(jq -r '.claudeAiOauth.accessToken' "$STORE/$label.json")
            if [ "$stored_tok" = "$live_tok" ]; then
                log "pointer desync: live cred matches $label but active=$ACTIVE; skipping tick (not syncing out or swapping)"
                exit 0
            fi
        done
        # Token-only sync-out: capture just the account token into ACTIVE's slot
        # (MCP tokens live permanently in the live file and are never moved).
        if ! capture_token "$CRED" "$STORE/$ACTIVE.json"; then
            log "sync-out failed, skipping tick to avoid swapping on stale state"
            exit 0
        fi
        # Also refresh the canonical shared MCP set from the live file. No-op if
        # the live MCP set is empty; a failure here is non-fatal.
        if ! capture_mcp "$CRED" "$STORE/mcp.json"; then
            log "sync-out: failed to refresh canonical mcp.json (continuing)"
        fi
    else
        log "live cred unreadable, skipping tick"
        exit 0
    fi
fi

# Poll usage for every account. ACTIVE uses the live file's token (freshest);
# every other account uses its stored token. Parallel maps: value = utilization
# string, empty string = UNKNOWN. Unknown values never fire a trigger.
declare -A FIVE WEEK
for label in "${ACCT_ARR[@]}"; do
    FIVE[$label]=""
    WEEK[$label]=""
    token=""
    if [ "$label" = "$ACTIVE" ]; then
        if valid_cred "$CRED"; then
            token=$(jq -r '.claudeAiOauth.accessToken' "$CRED")
        fi
    else
        if valid_cred "$STORE/$label.json"; then
            token=$(jq -r '.claudeAiOauth.accessToken' "$STORE/$label.json")
        fi
    fi

    resp=""
    [ -n "$token" ] && resp=$(fetch_usage "$token")

    if [ -n "$resp" ] && printf '%s' "$resp" | jq -e '.five_hour' >/dev/null 2>&1; then
        FIVE[$label]=$(printf '%s' "$resp" | jq -r '.five_hour.utilization // empty')
        WEEK[$label]=$(printf '%s' "$resp" | jq -r '.seven_day.utilization // empty')
        [ "$DRY" -eq 0 ] && write_usage "$label" "$resp"
    elif [ -f "$STORE/$label.usage.json" ]; then
        # Fetch failed (401/idle token): fall back to last-known stored usage.
        FIVE[$label]=$(jq -r '.five_hour.utilization // empty' "$STORE/$label.usage.json" 2>/dev/null)
        WEEK[$label]=$(jq -r '.seven_day.utilization // empty' "$STORE/$label.usage.json" 2>/dev/null)
    fi
done

trigA=0
targetA=""
bestFive=""
bestWeek=""
minWeek=""
maxWeek=""
minEligLabel=""
minEligWeek=""
trigB=0
targetB=""
target=""
reason=""
if [ "$PINNED" -eq 0 ]; then
    # Trigger A: ACTIVE 5h is KNOWN and >= FIVE_HOUR_PCT. Target = the
    # non-ACTIVE account with a KNOWN 5h and a valid stored cred that has the
    # LOWEST 5h; ties broken by lowest weekly.
    if [ -n "${FIVE[$ACTIVE]:-}" ] && num_ge "${FIVE[$ACTIVE]}" "$FIVE_HOUR_PCT"; then
        trigA=1
    fi
    if [ "$trigA" -eq 1 ]; then
        for label in "${ACCT_ARR[@]}"; do
            [ "$label" = "$ACTIVE" ] && continue
            [ -n "${FIVE[$label]:-}" ] || continue
            valid_cred "$STORE/$label.json" || continue
            f=${FIVE[$label]}
            w=${WEEK[$label]:-}
            wc=$w
            [ -z "$wc" ] && wc=999999
            if [ -z "$targetA" ]; then
                targetA=$label; bestFive=$f; bestWeek=$wc
            elif num_lt "$f" "$bestFive"; then
                targetA=$label; bestFive=$f; bestWeek=$wc
            elif num_eq "$f" "$bestFive" && num_lt "$wc" "$bestWeek"; then
                targetA=$label; bestFive=$f; bestWeek=$wc
            fi
        done
    fi

    # Trigger B firing condition: among accounts with KNOWN weekly, the spread
    # (max - min) over ALL of them is >= WEEKLY_DIVERGENCE_PCT.
    for label in "${ACCT_ARR[@]}"; do
        w=${WEEK[$label]:-}
        [ -n "$w" ] || continue
        if [ -z "$minWeek" ]; then
            minWeek=$w; maxWeek=$w
        else
            num_lt "$w" "$minWeek" && minWeek=$w
            num_lt "$maxWeek" "$w" && maxWeek=$w
        fi
    done
    if [ -n "$minWeek" ] && \
       awk -v mx="$maxWeek" -v mn="$minWeek" -v t="$WEEKLY_DIVERGENCE_PCT" 'BEGIN { exit ((mx - mn) >= t) ? 0 : 1 }'; then
        trigB=1
    fi
    # Trigger B target: the MIN-weekly account among the ELIGIBLE set only, i.e.
    # accounts whose KNOWN 5h is NOT >= FIVE_HOUR_PCT. A 5h-pressured account is not
    # a valid rebalance destination: parking the pointer on it just trips Trigger A
    # next tick and bounces it right back, a stateless per-tick flap between the two
    # triggers. Do NOT drop this exclusion. Unknown 5h counts as NOT pressured (same
    # convention as "unknown never fires a trigger"), so it stays eligible. Picking
    # the min over the eligible set (not the global min used for divergence above)
    # is what keeps Trigger B from chasing a pressured min-weekly account.
    for label in "${ACCT_ARR[@]}"; do
        w=${WEEK[$label]:-}
        [ -n "$w" ] || continue
        if [ -n "${FIVE[$label]:-}" ] && num_ge "${FIVE[$label]}" "$FIVE_HOUR_PCT"; then
            continue
        fi
        if [ -z "$minEligWeek" ]; then
            minEligWeek=$w; minEligLabel=$label
        elif num_lt "$w" "$minEligWeek"; then
            minEligWeek=$w; minEligLabel=$label
        fi
    done
    if [ "$trigB" -eq 1 ] && [ -n "$minEligLabel" ] && [ "$minEligLabel" != "$ACTIVE" ] \
        && valid_cred "$STORE/$minEligLabel.json"; then
        targetB=$minEligLabel
    fi

    # Decide. Trigger A wins over Trigger B when both fire.
    if [ "$trigA" -eq 1 ] && [ -n "$targetA" ]; then
        target=$targetA
        reason="5h pressure (active=${FIVE[$ACTIVE]} >= $FIVE_HOUR_PCT) -> $target"
    elif [ "$trigB" -eq 1 ] && [ -n "$targetB" ]; then
        target=$targetB
        reason="weekly divergence ($maxWeek-$minWeek >= $WEEKLY_DIVERGENCE_PCT) -> $target"
    fi
else
    # PIN: swaps are operator driven; autonomous triggers are suspended. Only a CONFIGURED
    # account (present in ACCOUNTS) may become the target; pinning a label the rotator does
    # not manage would strand `active` on an account later ticks never poll, so an
    # unconfigured or empty PIN holds on ACTIVE (still decision=PINNED).
    trigA=0
    trigB=0
    target=""
    for _pl in "${ACCT_ARR[@]}"; do
        [ "$_pl" = "$PIN_LABEL" ] && { target="$PIN_LABEL"; break; }
    done
    reason="pinned to ${PIN_LABEL:-<empty>}"
fi

SHOULD_SWAP=0
if [ -n "$target" ] && [ "$target" != "$ACTIVE" ] && valid_cred "$STORE/$target.json"; then
    SHOULD_SWAP=1
fi
if [ "$SHOULD_SWAP" -eq 0 ]; then
    if [ "$PINNED" -eq 1 ]; then
        if [ "$target" = "$ACTIVE" ]; then
            reason="pinned to $PIN_LABEL (already active)"
        else
            reason="pinned to ${PIN_LABEL:-<empty>} but target invalid; holding on $ACTIVE"
        fi
    elif [ "$trigA" -eq 1 ] || [ "$trigB" -eq 1 ]; then
        reason="trigger fired but no valid target; holding on $ACTIVE"
    else
        reason="no trigger"
    fi
fi

# One decision line with every account's (5h, weekly).
usages=""
for label in "${ACCT_ARR[@]}"; do
    usages="$usages $label(5h=${FIVE[$label]:-?},wk=${WEEK[$label]:-?})"
done
decision=HOLD
[ "$SHOULD_SWAP" -eq 1 ] && decision=SWAP
[ "$PINNED" -eq 1 ] && decision=PINNED
line="active=$ACTIVE trigA=$trigA trigB=$trigB target=${target:-none} decision=$decision reason=$reason usages:$usages"

if [ "$DRY" -eq 1 ]; then
    echo "status: $line"
    exit 0
fi

log "$line"

if [ "$SHOULD_SWAP" -eq 1 ]; then
    # Token-only swap: replace only the live .claudeAiOauth from the target's
    # store file, preserving the live .mcpOAuth. Aborts (no write) if the result
    # would be invalid, so the live cred is never torn or invalid.
    if swap_in_token "$STORE/$target.json" "$CRED"; then
        write_active "$target"
        log "SWAP $ACTIVE -> $target: $reason (usages:$usages)"
    else
        log "SWAP FAILED ($ACTIVE -> $target): live cred and pointer unchanged"
    fi
fi

exit 0
