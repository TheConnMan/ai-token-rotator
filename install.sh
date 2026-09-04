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
: "${CODEX_ROTATOR_STORE:=$HOME/.codex/accounts}"

UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"

cat > "$UNIT_DIR/cc-token-rotator.service" <<EOF
[Unit]
Description=Claude Code token rotator tick

[Service]
Type=oneshot
ExecStart=$HERE/rotate.sh
Environment=INFLIGHT_CMD=$HERE/drain-inflight.sh claude
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

cat > "$UNIT_DIR/cc-codex-token-rotator.service" <<EOF
[Unit]
Description=Codex token rotator tick

[Service]
Type=oneshot
ExecStart=$HERE/codex-rotate.sh
Environment=CODEX_INFLIGHT_CMD=$HERE/codex-inflight-all.sh
EOF

cat > "$UNIT_DIR/cc-codex-token-rotator.timer" <<EOF
[Unit]
Description=Run the Codex token rotator on a timer

[Timer]
OnBootSec=5min
OnActiveSec=1min
OnUnitActiveSec=${INTERVAL_MIN}min
Persistent=true

[Install]
WantedBy=timers.target
EOF

if ! systemctl --user daemon-reload; then
  echo "Could not reload systemd user units." >&2
  exit 1
fi

if ! systemctl --user enable --now cc-token-rotator.timer cc-codex-token-rotator.timer; then
  echo "Could not enable token rotator timers." >&2
  exit 1
fi

echo "installed and started both token rotator timers (interval ${INTERVAL_MIN}min)"
echo "SAFE: each rotator does nothing until its own ENABLED sentinel exists."
echo "Enable Claude rotation with: touch $STORE/ENABLED"
echo "Enable Codex rotation with: touch $CODEX_ROTATOR_STORE/ENABLED"
