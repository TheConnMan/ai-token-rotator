#!/usr/bin/env bash
# Shared helpers for the two-account Claude Max OAuth token rotator.
# Sourced by rotate.sh and bootstrap.sh. Not executable on its own.
set -uo pipefail

CRED="$HOME/.claude/.credentials.json"
STORE="$HOME/.claude/accounts"

# log <msg> - append an ISO-8601 stamped line to the rotate log and echo to stderr.
log() {
    local msg="$*"
    local stamp
    stamp=$(date -Iseconds)
    mkdir -p "$STORE" 2>/dev/null
    printf '[%s] %s\n' "$stamp" "$msg" >> "$STORE/rotate.log"
    printf '[%s] %s\n' "$stamp" "$msg" >&2
}

# fetch_usage <token> - call the Anthropic OAuth usage endpoint. Echo the JSON
# response on success (must contain .five_hour), empty string on any failure.
fetch_usage() {
    local token="$1"
    local resp
    [ -z "$token" ] && return 0
    resp=$(curl -s --max-time 6 "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" 2>/dev/null)
    if echo "$resp" | jq -e '.five_hour' >/dev/null 2>&1; then
        echo "$resp"
    fi
}

# atomic_replace <src> <dst> - copy src to a temp file in dst's own directory,
# chmod 600, then atomically rename over dst (same filesystem = atomic mv).
atomic_replace() {
    local src="$1" dst="$2"
    local dir tmp
    dir=$(dirname "$dst")
    tmp=$(mktemp "$dir/.tokrot.XXXXXX") || return 1
    if ! cp "$src" "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod 600 "$tmp"
    mv -f "$tmp" "$dst"
}

# valid_cred <path> - return 0 iff the file has a non-empty .claudeAiOauth.accessToken.
# Rejects torn or partial files written mid-flight by Claude.
valid_cred() {
    local path="$1"
    [ -f "$path" ] || return 1
    jq -e '.claudeAiOauth.accessToken' "$path" >/dev/null 2>&1
}

# other_label <active> - there must be exactly two <label>.json files in $STORE.
# Echo the label whose name is not <active>. Return non-zero if not exactly two.
other_label() {
    local active="$1"
    local f base labels=() other=""
    for f in "$STORE"/*.json; do
        [ -e "$f" ] || continue
        base=$(basename "$f" .json)
        # skip usage sidecars (<label>.usage.json -> base ends in .usage)
        case "$base" in
            *.usage) continue ;;
        esac
        labels+=("$base")
        [ "$base" != "$active" ] && other="$base"
    done
    [ "${#labels[@]}" -eq 2 ] || return 1
    [ -n "$other" ] || return 1
    echo "$other"
}
