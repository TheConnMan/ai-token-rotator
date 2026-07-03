#!/usr/bin/env bash
# One-time per-account capture. Run while logged into the account you want to
# store, with every MCP server re-authenticated for that account. Copies the
# live credentials file into the store under the given label.
#
# Usage: bootstrap.sh <label>
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

label="${1:-}"
if [ -z "$label" ]; then
    echo "usage: bootstrap.sh <label>" >&2
    exit 1
fi
case "$label" in
    *[!a-zA-Z0-9-]*)
        echo "error: label must be alphanumeric/dash only (got '$label')" >&2
        exit 1
        ;;
esac

mkdir -p "$STORE"
chmod 700 "$STORE"

if ! valid_cred "$CRED"; then
    echo "error: $CRED is missing or has no access token." >&2
    echo "Log into the account first (run claude, /login), then re-run: bootstrap.sh $label" >&2
    exit 1
fi

if ! capture_token "$CRED" "$STORE/$label.json"; then
    echo "error: failed to capture live cred into $STORE/$label.json" >&2
    exit 1
fi
echo "captured account token '$label' -> $STORE/$label.json (token-only)"

# MCP handling. The shared MCP set (.mcpOAuth) is account-independent and lives
# permanently in the live credentials file, so it is stored once in the canonical
# mcp.json and restored into any account whose live MCP set was wiped by /login.
if ! mcp_is_empty "$CRED"; then
    # Live cred carries an MCP set: this is a fully-authed account. Capture it as
    # the canonical shared set ("copy everything once").
    if capture_mcp "$CRED" "$STORE/mcp.json"; then
        echo "captured shared MCP set -> $STORE/mcp.json"
    else
        echo "warning: failed to capture shared MCP set into $STORE/mcp.json" >&2
    fi
elif [ -f "$STORE/mcp.json" ]; then
    # Live MCP set is empty (a /login just wiped it) but a canonical set exists:
    # restore it into the live cred so this account regains MCP access.
    if restore_mcp "$STORE/mcp.json" "$CRED"; then
        echo "restored shared MCP set from $STORE/mcp.json into live credentials"
    else
        echo "warning: failed to restore shared MCP set into live credentials" >&2
    fi
else
    echo "warning: no shared MCP set captured yet and live MCP set is empty." >&2
    echo "  Auth your MCP servers on the account that has them, then bootstrap THAT account first." >&2
fi

# Best-effort: capture this account's usage now using the live token.
token=$(jq -r '.claudeAiOauth.accessToken' "$CRED")
resp=$(fetch_usage "$token")
if [ -n "$resp" ] && printf '%s' "$resp" | jq -e '.five_hour' >/dev/null 2>&1; then
    write_usage "$label" "$resp"
fi

# The live cred we just captured IS this account, so the pointer must name it.
# Set it unconditionally: this realigns a desynced pointer after an out-of-band
# /login, and makes the last account bootstrapped the active one.
write_active "$label"
echo "set active account to '$label'"

cat <<EOF

Next steps:
  First account (the one with your MCP servers authed):
    1. Auth EVERY MCP server on this account, then bootstrap it (done if you
       just ran this on a fully-authed account: the shared MCP set is captured).
  Each additional account:
    2. In claude, run /login to the NEXT account.
    3. Run: $HERE/bootstrap.sh <next-label>
       If that /login happened to clear the MCP tokens, bootstrap restores the
       shared set into the live credentials; if the MCP tokens survived the login
       (often the case), bootstrap just refreshes the shared set. Either way the
       account ends up with MCP access. Only claude.ai connectors need a per-account
       reconnect in the UI.
    4. Repeat 2-3 for each account you want to rotate.
    5. When all accounts are captured, go live with:
         touch $STORE/ENABLED
EOF
