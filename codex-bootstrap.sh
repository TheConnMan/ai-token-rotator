#!/usr/bin/env bash
# Capture the currently logged in Codex account under one configured label.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=codex-lib.sh
source "$HERE/codex-lib.sh"

label="${1:-}"
if [ -z "$label" ]; then
    echo "usage: codex-bootstrap.sh <label>" >&2
    exit 1
fi
case "$label" in
    *[!a-zA-Z0-9-]*)
        echo "error: label must contain only letters, numbers, or a hyphen" >&2
        exit 1
        ;;
esac

if [ -e "$CODEX_ROTATOR_STORE/ENABLED" ] || [ -L "$CODEX_ROTATOR_STORE/ENABLED" ]; then
    echo "error: Codex rotation is enabled" >&2
    exit 1
fi

if ! codex_prepare_store; then
    echo "error: failed to prepare Codex account store" >&2
    exit 1
fi
if ! codex_take_rotate_lock; then
    echo "error: failed to acquire Codex rotation lock" >&2
    exit 1
fi
if [ -e "$CODEX_ROTATOR_STORE/ENABLED" ] || [ -L "$CODEX_ROTATOR_STORE/ENABLED" ]; then
    echo "error: Codex rotation is enabled" >&2
    exit 1
fi

if ! codex_valid_auth "$CODEX_ROTATOR_AUTH"; then
    echo "error: $CODEX_ROTATOR_AUTH is missing valid Codex tokens" >&2
    echo "Log into the Codex account first, then run this command again" >&2
    exit 1
fi

account=$(jq -r '.tokens.account_id' "$CODEX_ROTATOR_AUTH")
if ! codex_capture_tokens "$CODEX_ROTATOR_AUTH" "$CODEX_ROTATOR_STORE/$label.tokens" "$account"; then
    echo "error: failed to capture Codex tokens for $label" >&2
    exit 1
fi
echo "captured Codex account $label"

access=$(jq -r '.tokens.access_token' "$CODEX_ROTATOR_AUTH")
if raw_usage=$(codex_fetch_usage "$access" "$account") \
    && normalized_usage=$(codex_normalize_usage "$raw_usage"); then
    codex_write_usage "$label" "$normalized_usage" || true
fi

if ! codex_write_active "$label"; then
    echo "error: failed to set the active Codex account" >&2
    exit 1
fi
echo "set active Codex account to $label"
echo "Bootstrap each remaining Codex account, then enable rotation with:"
echo "  touch $CODEX_ROTATOR_STORE/ENABLED"
