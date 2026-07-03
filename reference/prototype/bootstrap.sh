#!/usr/bin/env bash
# One-time per-account capture. Run while logged into the account you want to
# store, with every MCP server re-authenticated for that account. Copies the live
# credentials file into the store under the given label.
#
# Usage: bootstrap.sh <label>
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=services/token-rotator/lib.sh
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

atomic_replace "$CRED" "$STORE/$label.json"
echo "captured account '$label' -> $STORE/$label.json"

if [ ! -f "$STORE/active" ]; then
    echo "$label" > "$STORE/active"
    echo "set active account to '$label'"
fi

cat <<EOF

Next steps:
  1. In claude, run /logout, then /login to the OTHER account.
  2. Re-authenticate EVERY MCP server on that account.
  3. Run: $HERE/bootstrap.sh <other-label>
  4. When both accounts are captured, go live with:
       touch $STORE/ENABLED
EOF
