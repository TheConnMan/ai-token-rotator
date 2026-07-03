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
