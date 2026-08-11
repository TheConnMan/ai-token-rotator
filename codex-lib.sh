#!/usr/bin/env bash
# Shared helpers for Codex account rotation.
set -uo pipefail

CODEX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load the shared thresholds before importing the numeric decision helpers.
# shellcheck source=/dev/null
[ -f "${ROTATOR_CONFIG:-$CODEX_LIB_DIR/config.env}" ] \
    && source "${ROTATOR_CONFIG:-$CODEX_LIB_DIR/config.env}"

: "${FIVE_HOUR_PCT:=80}"
: "${WEEKLY_DIVERGENCE_PCT:=10}"
: "${WEEKLY_DIVERGENCE_HI_FLOOR:=80}"
: "${WEEKLY_DIVERGENCE_HI_PCT:=5}"
: "${WEEKLY_DIVERGENCE_VHI_FLOOR:=90}"
: "${WEEKLY_DIVERGENCE_VHI_PCT:=2.5}"
: "${WEEKLY_CEIL_DEFAULT:=98}"
: "${INTERVAL_MIN:=15}"
: "${CODEX_ACCOUNTS:=}"
: "${CODEX_ROTATOR_AUTH:=$HOME/.codex/auth.json}"
: "${CODEX_ROTATOR_STORE:=$HOME/.codex/accounts}"

# Only weekly_ceil, weekly_dead_zone, and the numeric helpers are reused from
# the Claude library. Codex credentials use the functions below exclusively.
# shellcheck source=lib.sh
source "$CODEX_LIB_DIR/lib.sh"

codex_log() {
    local msg="$*"
    local stamp
    stamp=$(date -Iseconds)
    codex_prepare_store || return 1
    printf '[%s] %s\n' "$stamp" "$msg" >> "$CODEX_ROTATOR_STORE/rotate.log" || return 1
    chmod 600 "$CODEX_ROTATOR_STORE/rotate.log" 2>/dev/null || return 1
    printf '[%s] %s\n' "$stamp" "$msg" >&2
}

codex_prepare_store() {
    local owner mode
    [ ! -L "$CODEX_ROTATOR_STORE" ] || return 1
    mkdir -p "$CODEX_ROTATOR_STORE" 2>/dev/null || return 1
    [ -d "$CODEX_ROTATOR_STORE" ] && [ ! -L "$CODEX_ROTATOR_STORE" ] || return 1
    owner=$(stat -c '%u' "$CODEX_ROTATOR_STORE" 2>/dev/null) || return 1
    [ "$owner" = "$(id -u)" ] || return 1
    chmod 700 "$CODEX_ROTATOR_STORE" 2>/dev/null || return 1
    mode=$(stat -c '%a' "$CODEX_ROTATOR_STORE" 2>/dev/null) || return 1
    [ "$mode" = "700" ]
}

codex_take_rotate_lock() {
    local lock="$CODEX_ROTATOR_STORE/rotate.lock" mode
    [ ! -L "$lock" ] || return 1
    exec 9>>"$lock" || return 1
    [ ! -L "$lock" ] || return 1
    chmod 600 "$lock" 2>/dev/null || return 1
    mode=$(stat -c '%a' "$lock" 2>/dev/null) || return 1
    [ "$mode" = "600" ] || return 1
    flock -n 9
}

codex_valid_auth() {
    local path="$1"
    [ -f "$path" ] || return 1
    jq -se '
        length == 1
        and (.[0] | type == "object")
        and (.[0].tokens | type == "object")
        and (.[0].tokens.id_token | type == "string" and length > 0)
        and (.[0].tokens.access_token | type == "string" and length > 0)
        and (.[0].tokens.refresh_token | type == "string" and length > 0)
        and (.[0].tokens.account_id | type == "string" and length > 0)
    ' "$path" >/dev/null 2>&1
}

codex_valid_tokens() {
    local path="$1"
    [ -f "$path" ] || return 1
    jq -se '
        length == 1
        and (.[0] | type == "object")
        and (.[0].id_token | type == "string" and length > 0)
        and (.[0].access_token | type == "string" and length > 0)
        and (.[0].refresh_token | type == "string" and length > 0)
        and (.[0].account_id | type == "string" and length > 0)
    ' "$path" >/dev/null 2>&1
}

codex_capture_tokens() {
    [ "$#" -eq 3 ] || return 1
    local auth="$1" dst="$2" expected_account="$3"
    local dir tmp captured_account
    dir=$(dirname "$dst")
    tmp=$(mktemp "$dir/.codexrot.XXXXXX") || return 1
    if ! jq '.tokens' "$auth" > "$tmp" 2>/dev/null \
        || ! codex_valid_tokens "$tmp" \
        || ! captured_account=$(jq -r '.account_id' "$tmp") \
        || [ "$captured_account" != "$expected_account" ] \
        || ! chmod 600 "$tmp" \
        || ! mv -f "$tmp" "$dst"; then
        rm -f "$tmp"
        return 1
    fi
}

codex_swap_in_tokens() {
    [ "$#" -eq 3 ] || return 1
    local target="$1" auth="$2" expected="$3"
    local dir tmp
    codex_valid_tokens "$target" || return 1
    codex_valid_auth "$auth" || return 1
    codex_valid_tokens "$expected" || return 1
    dir=$(dirname "$auth")
    tmp=$(mktemp "$dir/.codexrot.XXXXXX") || return 1
    if ! jq --slurpfile target "$target" --slurpfile expected "$expected" \
        'select(.tokens == $expected[0]) | .tokens = $target[0]' "$auth" > "$tmp" 2>/dev/null \
        || ! codex_valid_auth "$tmp" \
        || ! chmod 600 "$tmp" \
        || ! mv -f "$tmp" "$auth"; then
        rm -f "$tmp"
        return 1
    fi
}

codex_write_active() {
    local label="$1"
    local tmp="$CODEX_ROTATOR_STORE/active.tmp"
    if ! printf '%s' "$label" > "$tmp" 2>/dev/null \
        || ! chmod 600 "$tmp" \
        || ! mv -f "$tmp" "$CODEX_ROTATOR_STORE/active"; then
        rm -f "$tmp"
        return 1
    fi
}

codex_refresh_access_token() {
    local tokens_file="$1" refresh_token response dir tmp
    codex_valid_tokens "$tokens_file" || return 1
    refresh_token=$(jq -r '.refresh_token // empty' "$tokens_file")
    [ -n "$refresh_token" ] || return 1

    if [ -n "${CODEX_REFRESH_MOCK_DIR:-}" ]; then
        [ -f "$CODEX_REFRESH_MOCK_DIR/$refresh_token.json" ] || return 1
        response=$(< "$CODEX_REFRESH_MOCK_DIR/$refresh_token.json") || return 1
    else
        response=$(printf '%s' "$refresh_token" \
            | jq -Rsc --arg client_id 'app_EMoamEEZ73f0CkXaXp7hrann' \
                '{grant_type: "refresh_token", client_id: $client_id, refresh_token: .}' \
            | curl --fail --silent --show-error --max-time 6 -X POST -H 'Content-Type: application/json' \
                --data-binary @- 'https://auth.openai.com/oauth/token' 2>/dev/null) || return 1
    fi

    dir=$(dirname "$tokens_file")
    tmp=$(mktemp "$dir/.codexrot.XXXXXX") || return 1
    if ! {
        cat "$tokens_file"
        printf '\n%s\n' "$response"
    } | jq -se '
        .[0] as $tokens
        | .[1] as $response
        | $tokens
        | .access_token = $response.access_token
        | .refresh_token = (
            if ($response.refresh_token? | type == "string" and length > 0)
            then $response.refresh_token else .refresh_token end
        )
        | .id_token = (
            if ($response.id_token? | type == "string" and length > 0)
            then $response.id_token else .id_token end
        )
    ' > "$tmp" 2>/dev/null \
        || ! codex_valid_tokens "$tmp" \
        || ! chmod 600 "$tmp" \
        || ! mv -f "$tmp" "$tokens_file"; then
        rm -f "$tmp"
        return 1
    fi
}

codex_fetch_usage() {
    local access="${1:-}" account="${2:-}"
    local resp
    [ -n "$access" ] && [ -n "$account" ] || return 1

    if [ -n "${CODEX_USAGE_MOCK_DIR:-}" ]; then
        [ -f "$CODEX_USAGE_MOCK_DIR/$access.$account.json" ] || return 1
        cat < "$CODEX_USAGE_MOCK_DIR/$access.$account.json" || return 1
        return
    fi

    resp=$(
        printf 'Authorization: Bearer %s\nchatgpt-account-id: %s\nContent-Type: application/json\n' \
            "$access" "$account" \
            | curl -f -sS --max-time 6 -H @- \
                "https://chatgpt.com/backend-api/wham/usage" 2>/dev/null
    ) || return 1
    [ -n "$resp" ] || return 1
    printf '%s' "$resp"
}

codex_normalize_usage() {
    local resp="${1:-}"
    local now
    [ -n "$resp" ] || return 1
    now=$(date +%s)

    printf '%s' "$resp" | jq -ce --argjson now "$now" '
        def maybe_number:
            if type == "number" then .
            elif type == "string" then (try tonumber catch null)
            else null
            end;
        . as $root
        | ($root.rate_limit.primary_window? // null) as $primary
        | ($root.rate_limit.secondary_window? // null) as $secondary
        | ([$primary, $secondary]) as $windows
        | ($windows
            | map(select(type == "object" and (.limit_window_seconds? == 18000)))
            | .[0] // null) as $five
        | ($windows
            | map(select(type == "object" and (.limit_window_seconds? == 604800)))
            | .[0] // null) as $weekly
        | ($root.credits.has_credits? | tostring) as $has_credits
        | if $has_credits == "false" then
              {
                  five_hour: {
                      utilization: 100,
                      resets_at: ($five.reset_at? | maybe_number)
                  },
                  seven_day: {
                      utilization: 100,
                      resets_at: ($weekly.reset_at? | maybe_number)
                  }
              }
          elif ($five | type) != "object" or ($weekly | type) != "object" then
              empty
          else
              ($five.used_percent? | maybe_number) as $five_used
              | ($weekly.used_percent? | maybe_number) as $weekly_used
              | ($five.reset_at? | maybe_number) as $five_reset
              | ($weekly.reset_at? | maybe_number) as $weekly_reset
              | if $five_used == null or $weekly_used == null
                    or $five_reset == null or $weekly_reset == null
                    or $five_used < 0 or $five_used > 100
                    or $weekly_used < 0 or $weekly_used > 100 then
                    empty
                else
                    {
                        five_hour: {
                            utilization: (if $five_reset <= $now then 0 else $five_used end),
                            resets_at: $five_reset
                        },
                        seven_day: {
                            utilization: (if $weekly_reset <= $now then 0 else $weekly_used end),
                            resets_at: $weekly_reset
                        }
                    }
                end
          end
    ' 2>/dev/null
}

codex_write_usage() {
    local label="$1" normalized="$2"
    local captured_at tmp
    captured_at=$(date +%s)
    tmp="$CODEX_ROTATOR_STORE/$label.usage.json.tmp"
    if ! printf '%s' "$normalized" \
        | jq --argjson captured_at "$captured_at" \
            '. + {captured_at: $captured_at}' > "$tmp" 2>/dev/null \
        || ! chmod 600 "$tmp" \
        || ! mv -f "$tmp" "$CODEX_ROTATOR_STORE/$label.usage.json"; then
        rm -f "$tmp"
        return 1
    fi
}
