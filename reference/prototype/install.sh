#!/usr/bin/env bash
# Install the token-rotator systemd user units and start the timer.
# Idempotent: safe to run repeatedly.
#
# Installing the timer is SAFE even before you bootstrap accounts: rotate.sh
# no-ops until ~/.claude/accounts/ENABLED exists.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"

mkdir -p "$UNIT_DIR"
cp "$HERE/cc-token-rotator.service" "$UNIT_DIR/cc-token-rotator.service"
cp "$HERE/cc-token-rotator.timer" "$UNIT_DIR/cc-token-rotator.timer"

systemctl --user daemon-reload
systemctl --user enable --now cc-token-rotator.timer

echo "installed and started cc-token-rotator.timer"
echo "SAFE: rotate.sh no-ops until \$HOME/.claude/accounts/ENABLED exists."
echo "Bootstrap both accounts, then 'touch \$HOME/.claude/accounts/ENABLED' to go live."
