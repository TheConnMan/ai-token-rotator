#!/usr/bin/env bash
# Poll Codex usage and rotate the live token object when a trigger fires.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=codex-lib.sh
source "$HERE/codex-lib.sh"

if [ -n "${CODEX_USAGE_MOCK_DIR:-}" ]; then
    printf '[warn] Codex usage mock active; the real endpoint will not be polled\n' >&2
fi

DRY=0
[ "${1:-}" = "status" ] && DRY=1

if [ "$DRY" -eq 0 ] && [ ! -f "$CODEX_ROTATOR_STORE/ENABLED" ]; then
    exit 0
fi

if [ "$DRY" -eq 0 ]; then
    codex_prepare_store || exit 0
    codex_take_rotate_lock || exit 0
fi

if [ ! -f "$CODEX_ROTATOR_STORE/active" ]; then
    if [ "$DRY" -eq 1 ]; then
        echo "status: no active Codex account set"
    else
        codex_log "no active Codex account set"
    fi
    exit 0
fi
ACTIVE=$(cat "$CODEX_ROTATOR_STORE/active")

read -ra ACCT_ARR <<< "$CODEX_ACCOUNTS"
N=${#ACCT_ARR[@]}
if [ "$N" -eq 0 ]; then
    if [ "$DRY" -eq 1 ]; then
        echo "status: no Codex accounts configured"
    else
        codex_log "no Codex accounts configured"
    fi
    exit 0
fi

PINNED=0
PIN_LABEL=""
if [ -f "$CODEX_ROTATOR_STORE/PIN" ]; then
    PINNED=1
    PIN_LABEL=$(cat "$CODEX_ROTATOR_STORE/PIN" 2>/dev/null)
fi

if [ "$DRY" -eq 0 ]; then
    if ! codex_valid_auth "$CODEX_ROTATOR_AUTH"; then
        codex_log "live Codex auth unreadable, skipping tick"
        exit 0
    fi

    live_access=$(jq -r '.tokens.access_token' "$CODEX_ROTATOR_AUTH")
    live_account=$(jq -r '.tokens.account_id' "$CODEX_ROTATOR_AUTH")
    active_store="$CODEX_ROTATOR_STORE/$ACTIVE.tokens"
    if codex_valid_tokens "$active_store"; then
        expected_active_account=$(jq -r '.account_id' "$active_store")
        if [ "$expected_active_account" != "$live_account" ]; then
            codex_log "pointer desync: live Codex account does not match active=$ACTIVE; skipping tick"
            exit 0
        fi
    else
        expected_active_account=$live_account
    fi
    for label in "${ACCT_ARR[@]}"; do
        [ "$label" = "$ACTIVE" ] && continue
        token_file="$CODEX_ROTATOR_STORE/$label.tokens"
        codex_valid_tokens "$token_file" || continue
        stored_access=$(jq -r '.access_token' "$token_file")
        stored_account=$(jq -r '.account_id' "$token_file")
        if [ "$stored_access" = "$live_access" ] || [ "$stored_account" = "$live_account" ]; then
            codex_log "pointer desync: live Codex auth matches $label but active=$ACTIVE; skipping tick"
            exit 0
        fi
    done

    if ! codex_capture_tokens "$CODEX_ROTATOR_AUTH" "$active_store" "$expected_active_account"; then
        codex_log "Codex sync out failed, skipping tick"
        exit 0
    fi
fi

declare -A FIVE WEEK
for label in "${ACCT_ARR[@]}"; do
    FIVE[$label]=""
    WEEK[$label]=""
    access=""
    account=""
    raw_usage=""
    normalized_usage=""
    if [ "$label" = "$ACTIVE" ]; then
        if codex_valid_auth "$CODEX_ROTATOR_AUTH"; then
            access=$(jq -r '.tokens.access_token' "$CODEX_ROTATOR_AUTH")
            account=$(jq -r '.tokens.account_id' "$CODEX_ROTATOR_AUTH")
        fi
    elif codex_valid_tokens "$CODEX_ROTATOR_STORE/$label.tokens"; then
        access=$(jq -r '.access_token' "$CODEX_ROTATOR_STORE/$label.tokens")
        account=$(jq -r '.account_id' "$CODEX_ROTATOR_STORE/$label.tokens")
    fi

    if [ -n "$access" ] && [ -n "$account" ]; then
        if raw_usage=$(codex_fetch_usage "$access" "$account"); then
            normalized_usage=$(codex_normalize_usage "$raw_usage") || normalized_usage=""
        elif [ "$label" != "$ACTIVE" ] && [ "$DRY" -eq 0 ] \
            && codex_refresh_access_token "$CODEX_ROTATOR_STORE/$label.tokens"; then
            access=$(jq -r '.access_token' "$CODEX_ROTATOR_STORE/$label.tokens")
            account=$(jq -r '.account_id' "$CODEX_ROTATOR_STORE/$label.tokens")
            if raw_usage=$(codex_fetch_usage "$access" "$account"); then
                normalized_usage=$(codex_normalize_usage "$raw_usage") || normalized_usage=""
            fi
        fi
        if [ -n "$normalized_usage" ]; then
            FIVE[$label]=$(printf '%s' "$normalized_usage" | jq -r '.five_hour.utilization // empty')
            WEEK[$label]=$(printf '%s' "$normalized_usage" | jq -r '.seven_day.utilization // empty')
            if [ "$DRY" -eq 0 ]; then
                codex_write_usage "$label" "$normalized_usage" \
                    || codex_log "failed to write Codex usage for $label"
            fi
        fi
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
trigC=0
targetC=""
bestRoom=""
target=""
reason=""
effZone=""
pin_released=0
pin_clear_on_live=0

declare -A CEIL
for label in "${ACCT_ARR[@]}"; do
    CEIL[$label]=$(weekly_ceil "$label")
done

codex_capped() {
    local label="${1:-}"
    [ -n "${WEEK[$label]:-}" ] || return 1
    num_ge "${WEEK[$label]}" "${CEIL[$label]}"
}

PIN_ACTIVE=$PINNED
if [ "$PINNED" -eq 1 ] && [ -n "$PIN_LABEL" ] && [ -n "${WEEK[$PIN_LABEL]:-}" ] \
    && [ -n "${CEIL[$PIN_LABEL]:-}" ] \
    && num_ge "${WEEK[$PIN_LABEL]}" "${CEIL[$PIN_LABEL]}"; then
    PIN_ACTIVE=0
    pin_released=1
    num_ge "${WEEK[$PIN_LABEL]}" 100 && pin_clear_on_live=1
fi

if [ "$PIN_ACTIVE" -eq 0 ]; then
    if [ -n "${FIVE[$ACTIVE]:-}" ] && num_ge "${FIVE[$ACTIVE]}" "$FIVE_HOUR_PCT"; then
        trigA=1
    fi
    if [ "$trigA" -eq 1 ]; then
        for label in "${ACCT_ARR[@]}"; do
            [ "$label" = "$ACTIVE" ] && continue
            [ -n "${FIVE[$label]:-}" ] || continue
            codex_valid_tokens "$CODEX_ROTATOR_STORE/$label.tokens" || continue
            codex_capped "$label" && continue
            f=${FIVE[$label]}
            w=${WEEK[$label]:-}
            wc=$w
            [ -z "$wc" ] && wc=999999
            if [ -z "$targetA" ]; then
                targetA=$label
                bestFive=$f
                bestWeek=$wc
            elif num_lt "$f" "$bestFive"; then
                targetA=$label
                bestFive=$f
                bestWeek=$wc
            elif num_eq "$f" "$bestFive" && num_lt "$wc" "$bestWeek"; then
                targetA=$label
                bestFive=$f
                bestWeek=$wc
            fi
        done
    fi

    for label in "${ACCT_ARR[@]}"; do
        w=${WEEK[$label]:-}
        [ -n "$w" ] || continue
        if [ -z "$minWeek" ]; then
            minWeek=$w
            maxWeek=$w
        else
            num_lt "$w" "$minWeek" && minWeek=$w
            num_lt "$maxWeek" "$w" && maxWeek=$w
        fi
    done
    if [ -n "$minWeek" ]; then
        effZone=$(weekly_dead_zone "$minWeek")
        if awk -v mx="$maxWeek" -v mn="$minWeek" -v t="$effZone" \
            'BEGIN { exit ((mx - mn) >= t) ? 0 : 1 }'; then
            trigB=1
        fi
    fi

    for label in "${ACCT_ARR[@]}"; do
        w=${WEEK[$label]:-}
        [ -n "$w" ] || continue
        if [ -n "${FIVE[$label]:-}" ] && num_ge "${FIVE[$label]}" "$FIVE_HOUR_PCT"; then
            continue
        fi
        codex_capped "$label" && continue
        if [ -z "$minEligWeek" ]; then
            minEligWeek=$w
            minEligLabel=$label
        elif num_lt "$w" "$minEligWeek"; then
            minEligWeek=$w
            minEligLabel=$label
        fi
    done
    if [ "$trigB" -eq 1 ] && [ -n "$minEligLabel" ] && [ "$minEligLabel" != "$ACTIVE" ] \
        && codex_valid_tokens "$CODEX_ROTATOR_STORE/$minEligLabel.tokens"; then
        targetB=$minEligLabel
    fi

    if [ -n "${WEEK[$ACTIVE]:-}" ] && codex_capped "$ACTIVE"; then
        for label in "${ACCT_ARR[@]}"; do
            [ "$label" = "$ACTIVE" ] && continue
            [ -n "${WEEK[$label]:-}" ] || continue
            codex_valid_tokens "$CODEX_ROTATOR_STORE/$label.tokens" || continue
            codex_capped "$label" && continue
            if [ -n "${FIVE[$label]:-}" ] && num_ge "${FIVE[$label]}" "$FIVE_HOUR_PCT"; then
                continue
            fi
            room=$(awk -v c="${CEIL[$label]}" -v w="${WEEK[$label]}" 'BEGIN { print c - w }')
            if [ -z "$bestRoom" ] || num_lt "$bestRoom" "$room"; then
                bestRoom=$room
                targetC=$label
            fi
        done
        [ -n "$targetC" ] && trigC=1
    fi

    if [ "$trigA" -eq 1 ] && [ -n "$targetA" ]; then
        target=$targetA
        reason="5h pressure active=${FIVE[$ACTIVE]} threshold=$FIVE_HOUR_PCT target=$target"
    elif [ "$trigC" -eq 1 ] && [ -n "$targetC" ]; then
        target=$targetC
        reason="weekly ceiling active=${WEEK[$ACTIVE]} ceiling=${CEIL[$ACTIVE]} target=$target"
    elif [ "$trigB" -eq 1 ] && [ -n "$targetB" ]; then
        target=$targetB
        reason="weekly divergence max=$maxWeek min=$minWeek zone=$effZone target=$target"
    fi
else
    trigA=0
    trigB=0
    trigC=0
    target=""
    for configured_label in "${ACCT_ARR[@]}"; do
        if [ "$configured_label" = "$PIN_LABEL" ]; then
            target=$PIN_LABEL
            break
        fi
    done
    reason="pinned to ${PIN_LABEL:-<empty>}"
fi

SHOULD_SWAP=0
if [ -n "$target" ] && [ "$target" != "$ACTIVE" ] \
    && codex_valid_tokens "$CODEX_ROTATOR_STORE/$target.tokens"; then
    SHOULD_SWAP=1
fi
if [ "$SHOULD_SWAP" -eq 0 ]; then
    if [ "$PIN_ACTIVE" -eq 1 ]; then
        if [ "$target" = "$ACTIVE" ]; then
            reason="pinned to $PIN_LABEL and already active"
        else
            reason="pinned target ${PIN_LABEL:-<empty>} is invalid, holding on $ACTIVE"
        fi
    elif [ "$trigA" -eq 1 ] || [ "$trigB" -eq 1 ] || [ "$trigC" -eq 1 ]; then
        if [ "$trigA" -eq 0 ] && [ "$trigB" -eq 1 ] && [ "$minEligLabel" = "$ACTIVE" ]; then
            reason="weekly divergence but $ACTIVE is already the lowest weekly account"
        else
            reason="trigger fired but no valid target, holding on $ACTIVE"
        fi
    elif [ -n "${WEEK[$ACTIVE]:-}" ] && codex_capped "$ACTIVE"; then
        reason="$ACTIVE is at its ceiling but no uncapped target exists"
    else
        reason="no trigger"
    fi
fi

# A swap restarts the app-server, which interrupts every running turn, so no
# swap may fire while Codex work is in flight. An unanswerable probe counts as
# in flight; the cost of waiting one tick is far below the cost of killing a job.
if [ "$SHOULD_SWAP" -eq 1 ]; then
    codex_work_in_flight
    inflight_rc=$?
    if [ "$inflight_rc" -eq 0 ]; then
        SHOULD_SWAP=0
        reason="Codex work in flight; holding on $ACTIVE rather than restarting the app-server"
    elif [ "$inflight_rc" -eq 2 ]; then
        SHOULD_SWAP=0
        reason="Codex in-flight probe failed, assuming work in flight; holding on $ACTIVE"
    fi
fi

if [ "$pin_released" -eq 1 ]; then
    reason="pin released for $PIN_LABEL at ceiling ${CEIL[$PIN_LABEL]}; $reason"
    [ "$pin_clear_on_live" -eq 1 ] && reason="pin-clear-pending (weekly fully exhausted); $reason"
fi

usages=""
for label in "${ACCT_ARR[@]}"; do
    usages="$usages $label(5h=${FIVE[$label]:-?},wk=${WEEK[$label]:-?}/${CEIL[$label]})"
done
decision=HOLD
[ "$SHOULD_SWAP" -eq 1 ] && decision=SWAP
[ "$PIN_ACTIVE" -eq 1 ] && decision=PINNED
line="active=$ACTIVE trigA=$trigA trigB=$trigB trigC=$trigC target=${target:-none} decision=$decision reason=$reason usages:$usages"

if [ "$DRY" -eq 1 ]; then
    echo "status: $line"
    exit 0
fi

codex_log "$line"
if [ "$pin_clear_on_live" -eq 1 ]; then
    if rm -f -- "$CODEX_ROTATOR_STORE/PIN"; then
        codex_log "PIN cleared for $PIN_LABEL: weekly usage is fully exhausted (${WEEK[$PIN_LABEL]}%)"
    else
        codex_log "PIN clear FAILED for $PIN_LABEL: weekly usage is fully exhausted (${WEEK[$PIN_LABEL]}%)"
    fi
fi
APPSERVER_REPLACED=0
if [ "$SHOULD_SWAP" -eq 1 ]; then
    if ! codex_capture_tokens "$CODEX_ROTATOR_AUTH" "$active_store" "$expected_active_account"; then
        codex_log "live Codex auth changed during poll, skipping swap"
    elif codex_swap_in_tokens "$CODEX_ROTATOR_STORE/$target.tokens" "$CODEX_ROTATOR_AUTH" "$active_store"; then
        if codex_write_active "$target"; then
            codex_log "SWAP $ACTIVE to $target: $reason usages:$usages"
            if [ "$CODEX_APPSERVER_RESTART" = "1" ]; then
                codex_kill_appserver
                case $? in
                    0)
                        APPSERVER_REPLACED=1
                        case "$CODEX_APPSERVER_METHOD" in
                            unit:*)
                                codex_log "app-server restarted via ${CODEX_APPSERVER_METHOD#unit:} to pick up $target" ;;
                            *)
                                codex_log "app-server killed to pick up $target; it respawns on the next Codex Desktop connect" ;;
                        esac
                        ;;
                    2) codex_log "no app-server running; nothing to restart for $target" ;;
                    *)
                        case "$CODEX_APPSERVER_METHOD" in
                            unit:*)
                                codex_log "app-server did NOT come back after restarting ${CODEX_APPSERVER_METHOD#unit:}; no Codex work can run until it does" ;;
                            *)
                                codex_log "app-server restart FAILED; Codex work keeps using $ACTIVE until the process is replaced" ;;
                        esac
                        ;;
                esac
            fi
        else
            codex_log "SWAP FAILED to update active pointer after moving $ACTIVE to $target; restoring live Codex auth"
            if codex_swap_in_tokens "$active_store" "$CODEX_ROTATOR_AUTH" "$CODEX_ROTATOR_STORE/$target.tokens"; then
                codex_log "SWAP rollback restored live Codex auth to $ACTIVE; active pointer remains $ACTIVE"
            else
                codex_log "SWAP rollback FAILED: live Codex auth remains $target; active pointer remains $ACTIVE"
            fi
        fi
    else
        codex_log "SWAP FAILED from $ACTIVE to $target; live auth and pointer unchanged"
    fi
fi

# Deliberately skipped on a tick that replaced the process itself: that tick's
# signal path has just handed the respawn to Codex Desktop, and starting a unit
# in the same breath would race it for the socket. Desktop gets until the next
# tick, and this repairs the box only if it never showed up.
if [ "$CODEX_APPSERVER_RESTART" = "1" ] && [ "$APPSERVER_REPLACED" -eq 0 ]; then
    codex_ensure_appserver
    case $? in
        0) codex_log "no app-server was running; started one via $CODEX_APPSERVER_BACKSTOP_UNIT_USED" ;;
        1) codex_log "no app-server was running and $CODEX_APPSERVER_BACKSTOP_UNIT_USED produced none; no Codex work can run until one is up" ;;
    esac
fi

exit 0
