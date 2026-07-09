#!/usr/bin/env bash
# Install the token-rotator systemd user units and start the timer.
# Idempotent: safe to run repeatedly.
#
# Installing the timer is SAFE even before you bootstrap accounts: rotate.sh
# no-ops until the ENABLED sentinel exists in the store.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

# Config: read the timer cadence. Real config.env is gitignored.
# shellcheck source=/dev/null
[ -f "${ROTATOR_CONFIG:-$HERE/config.env}" ] && source "${ROTATOR_CONFIG:-$HERE/config.env}"
: "${INTERVAL_MIN:=15}"

UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"

cat > "$UNIT_DIR/cc-token-rotator.service" <<EOF
[Unit]
Description=Claude Code token rotator tick

[Service]
Type=oneshot
ExecStart=$HERE/rotate.sh
EOF

cat > "$UNIT_DIR/cc-token-rotator.timer" <<EOF
[Unit]
Description=Run the Claude Code token rotator on a timer

[Timer]
OnBootSec=5min
OnActiveSec=1min
OnUnitActiveSec=${INTERVAL_MIN}min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now cc-token-rotator.timer

echo "installed and started cc-token-rotator.timer (interval ${INTERVAL_MIN}min)"
echo "SAFE: rotate.sh no-ops until the ENABLED sentinel exists in the store."
echo "Bootstrap your accounts, then 'touch $STORE/ENABLED' to go live."
