#!/usr/bin/env bash
# Shared helpers for the N-account Claude Code OAuth token rotator.
# Sourced by rotate.sh, bootstrap.sh, and install.sh. Not executable on its own.
#
# Honors ROTATOR_CRED / ROTATOR_STORE env overrides (default to the real paths)
# so the test suite can point at throwaway temp fixtures and never touch the
# real ~/.claude.
set -uo pipefail
# Every file this tool writes must be 0600 and every dir 0700 (SPEC); a global
# umask enforces it even where an explicit chmod is missed.
umask 077

# shellcheck disable=SC2034  # CRED is consumed by the scripts that source this lib
CRED="${ROTATOR_CRED:-$HOME/.claude/.credentials.json}"
STORE="${ROTATOR_STORE:-$HOME/.claude/accounts}"

# log <msg> - append an ISO-8601 stamped line to the rotate log and echo to
# stderr. Creates the store dir only when we actually log.
log() {
    local msg="$*"
    local stamp
    stamp=$(date -Iseconds)
    # SC2174: -m applies only to the deepest dir, which is exactly $STORE (the
    # one that must be 0700); its parents (~/.claude) already exist.
    # shellcheck disable=SC2174
    mkdir -m 700 -p "$STORE" 2>/dev/null
    printf '[%s] %s\n' "$stamp" "$msg" >> "$STORE/rotate.log"
    printf '[%s] %s\n' "$stamp" "$msg" >&2
}

# fetch_usage <token> - echo the usage JSON for that account, empty on failure.
# Test hook first: when ROTATOR_USAGE_MOCK_DIR is set, read <token>.json from it
# (absent file simulates a 401/failure) instead of hitting the network.
fetch_usage() {
    local token="${1:-}"
    [ -z "$token" ] && return 0
    if [ -n "${ROTATOR_USAGE_MOCK_DIR:-}" ]; then
        if [ -f "$ROTATOR_USAGE_MOCK_DIR/$token.json" ]; then
            cat "$ROTATOR_USAGE_MOCK_DIR/$token.json"
        fi
        return 0
    fi
    # Keep the bearer token OUT of the curl argv (visible in ps / proc cmdline):
    # pass the Authorization header via stdin with -H @-. The other two headers
    # are not secret and stay as literal args.
    local resp
    resp=$(printf 'Authorization: Bearer %s' "$token" \
        | curl -s --max-time 6 "https://api.anthropic.com/api/oauth/usage" -H @- \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "Content-Type: application/json" 2>/dev/null)
    if printf '%s' "$resp" | jq -e '.five_hour' >/dev/null 2>&1; then
        printf '%s' "$resp"
    fi
}

# read_active_mirror <active_label> - echo a fetch_usage-shaped usage response for
# the ACTIVE account sourced from the statusline usage mirror, but ONLY when that
# mirror is safe to trust; echo nothing otherwise (caller then polls the endpoint).
#
# Why: the statusline (a live session) already fetches the active account's usage
# and mirrors it to $ROTATOR_MIRROR_FILE on every render. Reusing it lets the
# rotator skip a redundant poll on the token most likely to be rate-limited, and
# keeps the rotator informed even while oauth/usage is 429ing that token (the exact
# blind-out that parks rotation). The mirror is trusted only when ALL hold:
#   1. it exists and its mtime is within $ROTATOR_MIRROR_TTL (fresh);
#   2. it carries a numeric five_hour_pct;
#   3. its seven_day_reset matches the active account's KNOWN weekly reset (from
#      $STORE/<active>.usage.json, written only by real polls). The reset is a
#      stable per-account identifier, so this proves the mirror describes the
#      active account -- a lingering old-account session (post-swap, still on its
#      in-memory token) writes a DIFFERENT reset and is rejected, preventing the
#      mislabel-driven ping-pong the mirror otherwise risks.
# Utilization is never sourced from stored usage.json (only the reset anchor is),
# so the deliberate no-stale-usage rule is preserved: a decision never runs on a
# stale utilization reading.
read_active_mirror() {
    local active="$1"
    local mirror="${ROTATOR_MIRROR_FILE:-/tmp/claude-usage-starship.json}"
    local ttl="${ROTATOR_MIRROR_TTL:-900}"
    [ -f "$mirror" ] || return 0

    local now mmod age
    now=$(date +%s)
    mmod=$(stat -c %Y "$mirror" 2>/dev/null || echo 0)
    age=$(( now - mmod ))
    [ "$age" -le "$ttl" ] || return 0

    local m5 m7 mreset
    m5=$(jq -r '.five_hour_pct // empty' "$mirror" 2>/dev/null)
    m7=$(jq -r '.seven_day_pct // empty' "$mirror" 2>/dev/null)
    mreset=$(jq -r '.seven_day_reset // empty' "$mirror" 2>/dev/null)
    [ -n "$m5" ] || return 0
    [ -n "$mreset" ] && [ "$mreset" != "null" ] || return 0

    # Identity anchor: the active account's last real-poll weekly reset.
    local ustore="$STORE/$active.usage.json"
    [ -f "$ustore" ] || return 0
    local s5reset s7reset s7epoch
    s7reset=$(jq -r '.seven_day.resets_at // empty' "$ustore" 2>/dev/null)
    [ -n "$s7reset" ] || return 0
    s7epoch=$(date -d "$s7reset" +%s 2>/dev/null) || return 0
    [ -n "$s7epoch" ] || return 0
    local diff=$(( mreset - s7epoch ))
    [ "$diff" -lt 0 ] && diff=$(( -diff ))
    [ "$diff" -le 300 ] || return 0

    # Identity proven. Emit the mirror's utilization in fetch_usage's shape,
    # reusing the anchor's stored resets_at (informational; keeps the anchor set
    # only by real polls, never overwritten by mirror data).
    s5reset=$(jq -r '.five_hour.resets_at // empty' "$ustore" 2>/dev/null)
    printf '{"five_hour":{"utilization":%s,"resets_at":"%s"},"seven_day":{"utilization":%s,"resets_at":"%s"}}' \
        "$m5" "$s5reset" "${m7:-0}" "$s7reset"
}

# write_usage <label> <resp> - atomically write $STORE/<label>.usage.json from a
# usage response, normalized to the SPEC shape with a captured_at epoch. Temp
# file in $STORE + chmod 600 + mv -f; removes the temp on failure.
write_usage() {
    local label="$1" resp="$2"
    local captured_at tmp
    captured_at=$(date +%s)
    tmp="$STORE/$label.usage.json.tmp"
    if printf '%s' "$resp" | jq --argjson ts "$captured_at" \
        '{five_hour: {utilization: .five_hour.utilization, resets_at: .five_hour.resets_at}, seven_day: {utilization: .seven_day.utilization, resets_at: .seven_day.resets_at}, captured_at: $ts}' \
        > "$tmp" 2>/dev/null; then
        chmod 600 "$tmp"
        mv -f "$tmp" "$STORE/$label.usage.json"
    else
        rm -f "$tmp"
        return 1
    fi
}

# write_active <label> - atomically write the $STORE/active pointer (temp in
# $STORE + chmod 600 + mv -f) so it is never a torn/truncated read.
write_active() {
    local label="$1"
    local tmp="$STORE/active.tmp"
    if printf '%s' "$label" > "$tmp" 2>/dev/null; then
        chmod 600 "$tmp"
        mv -f "$tmp" "$STORE/active"
    else
        rm -f "$tmp"
        return 1
    fi
}

# atomic_replace <src> <dst> - copy src to a temp file in dst's OWN directory,
# chmod 600, then atomically rename over dst. Same filesystem => atomic mv.
# Returns non-zero on any failure and cleans up the temp file.
atomic_replace() {
    local src="$1" dst="$2"
    local dir tmp
    dir=$(dirname "$dst")
    tmp=$(mktemp "$dir/.tokrot.XXXXXX") || return 1
    if ! cp "$src" "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! chmod 600 "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv -f "$tmp" "$dst"; then
        rm -f "$tmp"
        return 1
    fi
}

# valid_cred <path> - return 0 iff the file exists and has a non-null
# .claudeAiOauth.accessToken. Rejects torn/partial files written mid-flight.
valid_cred() {
    local path="$1"
    [ -f "$path" ] || return 1
    jq -e '.claudeAiOauth.accessToken' "$path" >/dev/null 2>&1
}

# capture_token <cred> <dst> - atomically write a TOKEN-ONLY store file:
# {"claudeAiOauth": (<cred>.claudeAiOauth)}. Temp in dst's dir + chmod 600 +
# mv -f. Returns non-zero and cleans up on failure. This is the store write for
# <label>.json under the token-only swap (MCP tokens are never stored here).
capture_token() {
    local cred="$1" dst="$2"
    local dir tmp
    dir=$(dirname "$dst")
    tmp=$(mktemp "$dir/.tokrot.XXXXXX") || return 1
    if ! jq '{claudeAiOauth: .claudeAiOauth}' "$cred" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    if ! chmod 600 "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv -f "$tmp" "$dst"; then
        rm -f "$tmp"
        return 1
    fi
}

# mcp_is_empty <cred> - return 0 (true) iff <cred> has no .mcpOAuth or it is an
# empty object. Used to decide whether there is any MCP set to capture/restore.
mcp_is_empty() {
    local cred="$1"
    jq -e '((.mcpOAuth // {}) | length) == 0' "$cred" >/dev/null 2>&1
}

# capture_mcp <cred> <dst> - GROW-merge the live .mcpOAuth INTO the canonical
# shared mcp.json at <dst>, never shrinking it. If the live .mcpOAuth is
# empty/absent, do nothing and return 0 (never write from an empty live set).
# If <dst> exists, write {"mcpOAuth": (dst.mcpOAuth * cred.mcpOAuth)} so live
# refreshes overlapping server tokens while canonical-only servers are PRESERVED;
# if <dst> is absent, write {"mcpOAuth": (cred.mcpOAuth)} (first capture). This is
# grow-only by design: removing a canonical server requires a manual reset (delete
# mcp.json and re-bootstrap). Atomic: temp in dst's dir + chmod 600 + mv -f.
capture_mcp() {
    local cred="$1" dst="$2"
    mcp_is_empty "$cred" && return 0
    local dir tmp
    dir=$(dirname "$dst")
    tmp=$(mktemp "$dir/.tokrot.XXXXXX") || return 1
    if [ -f "$dst" ]; then
        if ! jq -n --slurpfile d "$dst" --slurpfile c "$cred" \
            '{mcpOAuth: (($d[0].mcpOAuth // {}) * ($c[0].mcpOAuth // {}))}' \
            > "$tmp" 2>/dev/null; then
            rm -f "$tmp"
            return 1
        fi
    elif ! jq '{mcpOAuth: .mcpOAuth}' "$cred" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    if ! chmod 600 "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv -f "$tmp" "$dst"; then
        rm -f "$tmp"
        return 1
    fi
}

# NOTE: this uses a stored-wins merge (stored overwrites overlapping live keys),
# which is only safe because its sole caller (bootstrap.sh) invokes it exclusively
# when the live .mcpOAuth is empty; a future caller with a non-empty live set could
# discard a fresher live token.
# restore_mcp <mcp_store_file> <cred> - deep-merge the stored .mcpOAuth INTO the
# live cred, preserving any live entries: .mcpOAuth = (live.mcpOAuth * stored).
# Write atomically over <cred>. ABORT (return 1, leave <cred> untouched) if the
# result is not valid JSON with .claudeAiOauth.accessToken.
restore_mcp() {
    local mcp_store="$1" cred="$2"
    local dir tmp
    dir=$(dirname "$cred")
    tmp=$(mktemp "$dir/.tokrot.XXXXXX") || return 1
    if ! jq --slurpfile m "$mcp_store" \
        '.mcpOAuth = ((.mcpOAuth // {}) * ($m[0].mcpOAuth // {}))' \
        "$cred" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    if ! jq -e '.claudeAiOauth.accessToken' "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        return 1
    fi
    if ! chmod 600 "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv -f "$tmp" "$cred"; then
        rm -f "$tmp"
        return 1
    fi
}

# swap_in_token <target_store_file> <cred> - atomically set the live cred's
# .claudeAiOauth from the target store file, preserving ALL other live fields
# (including .mcpOAuth). Reads the LIVE cred at swap time, builds a temp in the
# cred's dir, chmods 600, and VALIDATES the temp has .claudeAiOauth.accessToken
# before mv -f. ABORT (return 1, remove temp, leave <cred> untouched) if jq fails
# or the temp is invalid, so the live file is never torn and never invalid.
swap_in_token() {
    local target="$1" cred="$2"
    local dir tmp
    dir=$(dirname "$cred")
    tmp=$(mktemp "$dir/.tokrot.XXXXXX") || return 1
    if ! jq --slurpfile t "$target" \
        '.claudeAiOauth = $t[0].claudeAiOauth' \
        "$cred" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    if ! jq -e '.claudeAiOauth.accessToken' "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        return 1
    fi
    if ! chmod 600 "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv -f "$tmp" "$cred"; then
        rm -f "$tmp"
        return 1
    fi
}

# token_expired <file> - return 0 (true) if the stored .claudeAiOauth.expiresAt
# (epoch MS) is missing/null, or is at/under now + a 60s skew; return 1 otherwise.
# Used to decide whether an idle NON-active account needs a token refresh before
# polling. now_ms is date +%s (epoch seconds) * 1000.
token_expired() {
    local file="$1"
    local exp now_ms
    exp=$(jq -r '.claudeAiOauth.expiresAt // empty' "$file" 2>/dev/null)
    [ -z "$exp" ] && return 0
    now_ms=$(( $(date +%s) * 1000 ))
    awk -v e="$exp" -v n="$now_ms" 'BEGIN { exit (e <= n + 60000) ? 0 : 1 }'
}

# refresh_access_token <store_file> - refresh an idle account's OAuth access token
# using its stored refresh token, persist the result atomically into <store_file>
# (updating accessToken, expiresAt, and a ROTATED refreshToken while PRESERVING all
# other .claudeAiOauth fields), and echo the new access token. Returns 1 (echoing
# nothing, leaving <store_file> untouched) on any failure: no refresh token, HTTP
# error, a response without .access_token, or any jq/validation failure.
#
# Test hook: when ROTATOR_REFRESH_MOCK_DIR is set, read <refreshToken>.json from it
# as the simulated token-endpoint response (absent file simulates a 401/429/failure)
# instead of hitting the network, mirroring fetch_usage's ROTATOR_USAGE_MOCK_DIR hook.
refresh_access_token() {
    local store_file="$1"
    local rt resp new_tok new_rt expires_in new_exp now_ms dir tmp
    rt=$(jq -r '.claudeAiOauth.refreshToken // empty' "$store_file" 2>/dev/null)
    [ -z "$rt" ] && return 1

    if [ -n "${ROTATOR_REFRESH_MOCK_DIR:-}" ]; then
        [ -f "$ROTATOR_REFRESH_MOCK_DIR/$rt.json" ] || return 1
        resp=$(cat "$ROTATOR_REFRESH_MOCK_DIR/$rt.json")
    else
        # Keep the refresh token OUT of the curl argv (visible in ps / proc
        # cmdline): build the JSON body with jq and pass it via stdin (--data @-),
        # consistent with how fetch_usage keeps the bearer out of argv.
        # console.anthropic.com/v1/oauth/token sits behind Cloudflare bot
        # protection that 429s the default curl User-Agent BEFORE OAuth
        # validation; send a real client UA so the refresh request reaches the
        # OAuth layer (verified 2026-07-09). The usage endpoint (api.anthropic.com)
        # has no such gate, so fetch_usage does not need this.
        resp=$(jq -cn --arg rt "$rt" --arg cid "9d1c250a-e61b-44d9-88ed-5944d1962f5e" \
            '{grant_type: "refresh_token", refresh_token: $rt, client_id: $cid}' \
            | curl -s --max-time 10 "https://console.anthropic.com/v1/oauth/token" \
                -A "anthropic-sdk-typescript/0.0.0 userOAuthProvider" \
                -H "Content-Type: application/json" --data @- 2>/dev/null)
    fi

    new_tok=$(printf '%s' "$resp" | jq -r '.access_token // empty' 2>/dev/null)
    [ -z "$new_tok" ] && return 1

    expires_in=$(printf '%s' "$resp" | jq -r '.expires_in // empty' 2>/dev/null)
    [ -z "$expires_in" ] && expires_in=0
    now_ms=$(( $(date +%s) * 1000 ))
    new_exp=$(( now_ms + expires_in * 1000 ))

    # Refresh tokens ROTATE; persist a rotated one if present, else keep the old one.
    new_rt=$(printf '%s' "$resp" | jq -r '.refresh_token // empty' 2>/dev/null)
    [ -z "$new_rt" ] && new_rt=$rt

    dir=$(dirname "$store_file")
    tmp=$(mktemp "$dir/.tokrot.XXXXXX") || return 1
    if ! jq --arg at "$new_tok" --argjson ea "$new_exp" --arg rtok "$new_rt" \
        '.claudeAiOauth.accessToken = $at
         | .claudeAiOauth.expiresAt = $ea
         | .claudeAiOauth.refreshToken = $rtok' \
        "$store_file" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    if ! jq -e '.claudeAiOauth.accessToken' "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        return 1
    fi
    if ! chmod 600 "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv -f "$tmp" "$store_file"; then
        rm -f "$tmp"
        return 1
    fi
    printf '%s' "$new_tok"
}

# num_ge <a> <b> - return 0 if a >= b (fractional-safe via awk).
num_ge() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit (a >= b) ? 0 : 1 }'
}

# num_lt <a> <b> - return 0 if a < b (fractional-safe via awk).
num_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit (a < b) ? 0 : 1 }'
}

# num_eq <a> <b> - return 0 if a == b (fractional-safe via awk).
num_eq() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit (a == b) ? 0 : 1 }'
}

# weekly_dead_zone <floor> - echo Trigger B's effective divergence threshold. The
# dead zone shrinks as the lowest account's weekly usage (the floor) approaches 100,
# so the rotator keeps rebalancing tightly near the weekly ceiling. Tiers/values are
# config knobs. Invariant: the zone only ever TIGHTENS, never widens above the base -
# a tier applies only when its value is smaller than the running zone, so if an
# operator sets the base below a tier value the effective zone stays at the base.
weekly_dead_zone() {
    awk -v m="$1" \
        -v base="${WEEKLY_DIVERGENCE_PCT}" \
        -v hf="${WEEKLY_DIVERGENCE_HI_FLOOR}"  -v hp="${WEEKLY_DIVERGENCE_HI_PCT}" \
        -v vf="${WEEKLY_DIVERGENCE_VHI_FLOOR}" -v vp="${WEEKLY_DIVERGENCE_VHI_PCT}" \
        'BEGIN { z = base; if (m >= hf && hp < z) z = hp; if (m >= vf && vp < z) z = vp; print z }'
}
