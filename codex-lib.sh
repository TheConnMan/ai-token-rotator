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
: "${CODEX_APPSERVER_RESTART:=1}"
: "${CODEX_APPSERVER_SOCKET:=${CODEX_HOME:-$HOME/.codex}/app-server-control/app-server-control.sock}"
# Unset uses the bundled probe. Empty is the operator/test escape that
# disables the gate. Use +x, not :=, because := treats empty as unset and
# would launch the real probe from the test suite.
if [ -z "${CODEX_INFLIGHT_CMD+x}" ]; then
    CODEX_INFLIGHT_CMD="$CODEX_LIB_DIR/codex-inflight.sh"
fi

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

    # Window-first, credits-last. A real rate-limit window ALWAYS wins over the credits
    # object: on a ChatGPT Plus/Pro plan `has_credits:false` with `balance:"0"` means no
    # pay-as-you-go top-up, which says nothing about the plan's included weekly quota.
    # Reading it as "exhausted" reports a fresh account at 0% as fully spent, and the
    # rotator then refuses to ever swap onto it. Credits are authoritative only in the
    # windowless `premium` shape, where there is no window anywhere to read instead.
    #
    # A missing window is UNKNOWN (null), never 0. These plans ship no 5h window at all -
    # the weekly arrives alone, and in either the primary or the secondary slot - so a
    # zero would read as maximum headroom and win every comparison.
    printf '%s' "$resp" | jq -ce --argjson now "$now" '
        def maybe_number:
            if type == "number" then .
            elif type == "string" then (try tonumber catch null)
            else null
            end;
        def read_window($w; $now):
            if ($w | type) != "object" then {utilization: null, resets_at: null}
            else
                ($w.used_percent? | maybe_number) as $used
                | ($w.reset_at? | maybe_number) as $reset
                | if $used == null or $reset == null or $used < 0 or $used > 100 then
                      {utilization: null, resets_at: null}
                  else
                      {
                          utilization: (if $reset <= $now then 0 else $used end),
                          resets_at: $reset
                      }
                  end
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
        | if $five == null and $weekly == null then
              if $has_credits == "false" then
                  {
                      five_hour: {utilization: null, resets_at: null},
                      seven_day: {utilization: 100, resets_at: null}
                  }
              else
                  empty
              end
          else
              read_window($five; $now) as $five_out
              | read_window($weekly; $now) as $weekly_out
              | if $five_out.utilization == null and $weekly_out.utilization == null then
                    empty
                else
                    {five_hour: $five_out, seven_day: $weekly_out}
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

# The app-server reads auth.json once, at startup, and caches the account for its
# whole lifetime. A token swap therefore reaches no Codex work at all until the
# process is replaced.
#
# How to replace it depends on who owns it, and getting that wrong strands the box
# with no app-server at all. When a systemd user unit owns the process, that unit
# is the only thing that will bring it back, and a bare signal is not enough: the
# unit that ships the daemon is `Type=oneshot` with `RemainAfterExit=yes`, so its
# main pid has already exited successfully and systemd keeps reporting `active`
# over a corpse. Nothing respawns it, and every later dispatch fails. Restart the
# unit in that case. Only fall back to the signal when no unit owns the process,
# which is the older arrangement where Codex Desktop respawns it on its next SSH
# connect. It ignores SIGTERM, hence SIGKILL.
codex_appserver_pid() {
    if [ -n "${CODEX_APPSERVER_MOCK_DIR:-}" ]; then
        [ -s "$CODEX_APPSERVER_MOCK_DIR/pid" ] || return 0
        cat "$CODEX_APPSERVER_MOCK_DIR/pid"
        return 0
    fi
    [ -n "$CODEX_APPSERVER_SOCKET" ] || return 0
    ss -xlp 2>/dev/null | awk -v sock="$CODEX_APPSERVER_SOCKET" '
        index($0, sock) > 0 && match($0, /pid=[0-9]+/) {
            print substr($0, RSTART + 4, RLENGTH - 4)
            exit
        }'
}

# The systemd user unit that owns the app-server, empty when none does.
# An explicit CODEX_APPSERVER_UNIT wins; set it empty to force the signal path.
codex_appserver_unit() {
    local pid=$1 unit
    if [ -n "${CODEX_APPSERVER_UNIT+x}" ]; then
        codex_restartable_unit "$CODEX_APPSERVER_UNIT"
        return 0
    fi
    # Never read the real cgroup tree from the test sandbox. A mock pid is an
    # arbitrary number that may belong to a live unrelated unit on this box, and
    # resolving it would point a restart at something the test never named.
    [ -z "${CODEX_APPSERVER_MOCK_DIR:-}" ] || return 0
    [ -r "/proc/$pid/cgroup" ] || return 0
    unit=$(codex_unit_from_cgroup "$(cat "/proc/$pid/cgroup" 2>/dev/null)") || return 0
    printf '%s' "$unit"
}

# The restartable unit named by a cgroup listing, empty when there is none.
# Kept separate from the /proc read so the parse is exercised directly.
codex_unit_from_cgroup() {
    local unit
    # The owning unit is the last path component of the cgroup line. A process
    # parked directly in a scope has no service to restart.
    unit=$(printf '%s\n' "$1" \
        | sed -n 's#^.*/\([A-Za-z0-9@:_.-]*\.service\)$#\1#p' \
        | head -1)
    codex_restartable_unit "$unit"
}

# The unit if it is safe to restart, empty otherwise. user@N.service is the
# per-user session manager, not the app-server's own unit: restarting it would
# tear down every user service on the box, this rotator's own timer included, to
# swap one token. Every route to a unit name goes through here, an explicit
# CODEX_APPSERVER_UNIT included, because an override that could still name it
# would just be the same accident with an extra step.
codex_restartable_unit() {
    case "$1" in
        ""|user@*.service) return 0 ;;
    esac
    printf '%s' "$1"
}

# Wait briefly for an app-server to be listening again, 1 if none turns up.
# The daemon is spawned detached, so it is up a moment after the unit reports
# started, not at the instant it does.
codex_await_appserver() {
    local waited=0 limit="${CODEX_APPSERVER_WAIT_SECS:-15}"
    while :; do
        [ -z "$(codex_appserver_pid)" ] || return 0
        [ "$waited" -lt "$limit" ] || return 1
        sleep 1
        waited=$((waited + 1))
    done
}

# Record for the tests, which cannot observe a signal or a systemctl call.
codex_appserver_record() {
    [ -n "${CODEX_APPSERVER_MOCK_DIR:-}" ] || return 0
    printf '%s\n' "$1" >> "$CODEX_APPSERVER_MOCK_DIR/killed" || return 1
    printf '%s %s\n' "$1" "$2" >> "$CODEX_APPSERVER_MOCK_DIR/replaced" || return 1
}

# 0 replaced, 2 nothing was running, 1 the replacement failed.
# Sets CODEX_APPSERVER_METHOD to the lever used, so the caller can log honestly
# about whether the daemon is already back or is waiting on an external respawn.
codex_kill_appserver() {
    local pid unit dropped=0
    CODEX_APPSERVER_METHOD=""
    pid=$(codex_appserver_pid) || return 1
    [ -n "$pid" ] || return 2

    unit=$(codex_appserver_unit "$pid")
    if [ -n "$unit" ]; then
        # Drop the unit's processes first, then bring the unit back. Two reasons
        # this is not a plain `systemctl restart`. The swap has already moved
        # auth.json and the in-flight probe has already run, so every second the
        # old daemon stays up is a second a new turn can start on the account we
        # just moved away from and then be killed anyway. And this unit stops by
        # waiting on the daemon's pid, which ignores SIGTERM, so `restart` alone
        # sits through that whole timeout: 70s, observed 2026-08-24. Signalling
        # the cgroup also takes out the supervisor that would otherwise hold the
        # killed daemon as an unreaped zombie, which is what the stop was stuck
        # waiting on.
        "${CODEX_SYSTEMCTL:-systemctl}" --user kill --signal=KILL "$unit" >/dev/null 2>&1 \
            && dropped=1
        if "${CODEX_SYSTEMCTL:-systemctl}" --user restart "$unit" >/dev/null 2>&1; then
            CODEX_APPSERVER_METHOD="unit:$unit"
            # A restart that reports success is not proof of a running daemon.
            # This unit is Type=oneshot: ExecStart exits 0 once it has spawned the
            # app-server and systemd reports active either way. Taking that at its
            # word is how the box ends up with no app-server at all, and nothing
            # repairs it later, because a tick that finds no listening pid
            # concludes there is nothing to restart and returns 2. So confirm a
            # daemon is actually listening again before calling this a success.
            codex_await_appserver || return 1
            codex_appserver_record "$pid" "$CODEX_APPSERVER_METHOD" || return 1
            return 0
        fi
        # The restart failed. If the kill above landed, the daemon is already
        # gone: there is nothing left to signal, and falling through would
        # report that Codex work carries on using the old account when in fact
        # nothing is running at all. Keep the unit failure, which says that.
        if [ "$dropped" = 1 ]; then
            CODEX_APPSERVER_METHOD="unit:$unit"
            return 1
        fi
        # The unit would neither kill nor restart, so the daemon may well still
        # be up and serving the stale account. The signal is still worth trying.
    fi

    CODEX_APPSERVER_METHOD="signal"
    if [ -n "${CODEX_APPSERVER_MOCK_DIR:-}" ]; then
        codex_appserver_record "$pid" "$CODEX_APPSERVER_METHOD" || return 1
        return 0
    fi
    kill -9 "$pid" 2>/dev/null || return 1
}

# 0 work is in flight, 1 the coast is clear, 2 the probe could not answer.
# Callers must treat 2 exactly like 0: killing the app-server interrupts every
# running turn, so an unanswerable probe is never a licence to swap, in the same
# way an unknown usage reading never fires a trigger.
codex_work_in_flight() {
    local out rc
    # Empty (set, but blank) is the explicit disable. Unset is filled in
    # above with the bundled probe, so it never reaches this check.
    [ -n "$CODEX_INFLIGHT_CMD" ] || return 1
    # Deliberately unquoted so the configured value may carry arguments.
    # shellcheck disable=SC2086
    out=$($CODEX_INFLIGHT_CMD 2>/dev/null)
    rc=$?
    [ "$rc" -ne 0 ] && return 2
    [ -n "$out" ]
}
