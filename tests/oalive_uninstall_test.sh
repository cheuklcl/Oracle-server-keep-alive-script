#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OALIVE="${SCRIPT_DIR}/../oalive.sh"

if grep -q 'if \[ -f "/etc/systemd/system/cpu-limit.service" \]' "$OALIVE"; then
  echo "FAIL: uninstall still gated by cpu service file existence"
  exit 1
fi

if grep -q 'systemctl stop bandwidth_occupier$' "$OALIVE"; then
  echo "FAIL: uninstall still uses bandwidth_occupier without .service"
  exit 1
fi

if ! grep -q 'systemctl stop cpu-limit.service memory-limit.service bandwidth_occupier.service bandwidth_occupier.timer' "$OALIVE"; then
  echo "FAIL: unified stop command missing"
  exit 1
fi

if ! grep -q 'pkill -f "/usr/local/bin/cpu-limit.sh"' "$OALIVE"; then
  echo "FAIL: robust process cleanup missing"
  exit 1
fi

echo "PASS"
