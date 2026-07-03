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

if ! atomic_replace "$CRED" "$STORE/$label.json"; then
    echo "error: failed to capture live cred into $STORE/$label.json" >&2
    exit 1
fi
echo "captured account '$label' -> $STORE/$label.json"

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
  1. In claude, run /logout, then /login to the NEXT account.
  2. Re-authenticate EVERY MCP server on that account.
  3. Run: $HERE/bootstrap.sh <next-label>
  4. Repeat 1-3 for each account you want to rotate.
  5. When all accounts are captured, go live with:
       touch $STORE/ENABLED
EOF
