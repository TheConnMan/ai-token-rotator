#!/usr/bin/env bash
# Token rotator tick. Default: evaluate the two bootstrapped accounts and swap the
# live credentials file if the active account is under 5h pressure or the weekly
# usage is lopsided. `rotate.sh status` does a dry read-out and never writes/swaps.
#
# Utilization is on a 0-100 scale (Anthropic OAuth usage endpoint, matching
# background drain tooling). Trigger A: active 5h utilization >= 80. Trigger B: active weekly
# minus other weekly >= 10 percentage points.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=services/token-rotator/lib.sh
source "$HERE/lib.sh"

FIVE_HOUR_TRIGGER=80   # Trigger A: 5h utilization at/above this (0-100)
WEEKLY_GAP_TRIGGER=10  # Trigger B: active-minus-other weekly gap in points

# num <value> - echo a numeric value, defaulting empty/null to 0.
num() {
    case "${1:-}" in
        ""|null) echo 0 ;;
        *) echo "$1" ;;
    esac
}

DRY=0
if [ "${1:-}" = "status" ]; then
    DRY=1
fi

# Enabled gate (skip in dry mode so status always works).
if [ "$DRY" -eq 0 ] && [ ! -f "$STORE/ENABLED" ]; then
    exit 0
fi

if [ ! -f "$STORE/active" ]; then
    if [ "$DRY" -eq 1 ]; then
        echo "status: no active account set (store empty or not bootstrapped)"
        exit 0
    fi
    log "no active account set"
    exit 0
fi
ACTIVE=$(cat "$STORE/active")

if ! OTHER=$(other_label "$ACTIVE"); then
    if [ "$DRY" -eq 1 ]; then
        echo "status: need exactly 2 bootstrapped accounts (active=$ACTIVE)"
        exit 0
    fi
    log "need exactly 2 bootstrapped accounts"
    exit 0
fi

# sync-out: capture any refresh/rotation of the active account's tokens back into
# the store before we might swap it away. Never overwrite the store with a partial
# file (Claude may be mid-write).
if [ "$DRY" -eq 0 ]; then
    if valid_cred "$CRED"; then
        atomic_replace "$CRED" "$STORE/$ACTIVE.json"
    else
        log "live cred unreadable, skipping tick"
        exit 0
    fi
fi

# Read the active account's live usage. Prefer a fresh endpoint read; fall back to
# the last-known stored usage on any failure.
a5=""; aw=""
if valid_cred "$CRED"; then
    token=$(jq -r '.claudeAiOauth.accessToken' "$CRED")
    resp=$(fetch_usage "$token")
    if [ -n "$resp" ] && echo "$resp" | jq -e '.five_hour' >/dev/null 2>&1; then
        a5=$(echo "$resp" | jq -r '.five_hour.utilization // empty')
        aw=$(echo "$resp" | jq -r '.seven_day.utilization // empty')
        if [ "$DRY" -eq 0 ]; then
            captured_at=$(date +%s)
            echo "$resp" | jq --argjson ts "$captured_at" \
                '{five_hour: {utilization: .five_hour.utilization, resets_at: .five_hour.resets_at}, seven_day: {utilization: .seven_day.utilization, resets_at: .seven_day.resets_at}, captured_at: $ts}' \
                > "$STORE/$ACTIVE.usage.json.tmp" 2>/dev/null \
                && chmod 600 "$STORE/$ACTIVE.usage.json.tmp" \
                && mv -f "$STORE/$ACTIVE.usage.json.tmp" "$STORE/$ACTIVE.usage.json"
        fi
    fi
fi
# Fall back to stored usage if the live read gave us nothing.
if [ -z "$a5" ] && [ -f "$STORE/$ACTIVE.usage.json" ]; then
    a5=$(jq -r '.five_hour.utilization // empty' "$STORE/$ACTIVE.usage.json" 2>/dev/null)
    aw=$(jq -r '.seven_day.utilization // empty' "$STORE/$ACTIVE.usage.json" 2>/dev/null)
fi

# Other account weekly (last known; absent -> 0).
ow=""
if [ -f "$STORE/$OTHER.usage.json" ]; then
    ow=$(jq -r '.seven_day.utilization // empty' "$STORE/$OTHER.usage.json" 2>/dev/null)
fi

a5=$(num "$a5"); aw=$(num "$aw"); ow=$(num "$ow")

# Decide. awk handles the numeric (possibly fractional) comparisons.
reason=""
SHOULD_SWAP=0
trigA=$(awk -v v="$a5" -v t="$FIVE_HOUR_TRIGGER" 'BEGIN { print (v >= t) ? 1 : 0 }')
trigB=$(awk -v a="$aw" -v o="$ow" -v g="$WEEKLY_GAP_TRIGGER" 'BEGIN { print ((a - o) >= g) ? 1 : 0 }')
if [ "$trigA" = "1" ]; then
    reason="5h pressure (a5=$a5 >= $FIVE_HOUR_TRIGGER)"
    SHOULD_SWAP=1
fi
if [ "$trigB" = "1" ]; then
    if [ -n "$reason" ]; then
        reason="$reason; weekly imbalance (aw-ow=$aw-$ow >= $WEEKLY_GAP_TRIGGER)"
    else
        reason="weekly imbalance (aw-ow=$aw-$ow >= $WEEKLY_GAP_TRIGGER)"
    fi
    SHOULD_SWAP=1
fi
[ "$SHOULD_SWAP" -eq 0 ] && reason="no trigger"

# Guard: never swap to an other account whose stored file is missing or invalid.
if [ "$SHOULD_SWAP" -eq 1 ] && ! valid_cred "$STORE/$OTHER.json"; then
    SHOULD_SWAP=0
    reason="$reason BUT other account file ($OTHER) missing/invalid; holding"
    [ "$DRY" -eq 0 ] && log "swap wanted but $OTHER.json missing/invalid; holding on $ACTIVE"
fi

line="active=$ACTIVE a5=$a5 aw=$aw other=$OTHER ow=$ow decision=$([ "$SHOULD_SWAP" -eq 1 ] && echo SWAP || echo HOLD) reason=$reason"

if [ "$DRY" -eq 1 ]; then
    echo "status: $line"
    exit 0
fi

log "$line"

if [ "$SHOULD_SWAP" -eq 1 ]; then
    atomic_replace "$STORE/$OTHER.json" "$CRED"
    echo "$OTHER" > "$STORE/active"
    log "SWAP $ACTIVE -> $OTHER: $reason (a5=$a5 aw=$aw ow=$ow)"
fi

exit 0
