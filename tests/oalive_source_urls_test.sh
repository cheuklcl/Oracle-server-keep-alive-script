#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OALIVE="${SCRIPT_DIR}/../oalive.sh"

if grep -q "gitlab.com/spiritysdx/Oracle-server-keep-alive-script/-/raw/main/" "$OALIVE"; then
  echo "FAIL: old gitlab raw source still exists"
  exit 1
fi

expected=10
actual="$(grep -c "raw.githubusercontent.com/cheuklcl/Oracle-server-keep-alive-script/main/" "$OALIVE")"
if [ "$actual" -ne "$expected" ]; then
  echo "FAIL: expected $expected github raw URLs, got $actual"
  exit 1
fi

if grep -q "CPUQuota=" "$OALIVE"; then
  echo "FAIL: CPUQuota injection still exists in oalive.sh"
  exit 1
fi

echo "PASS"
