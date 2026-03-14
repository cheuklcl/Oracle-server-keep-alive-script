#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../cpu-limit.sh"

test_decide_action() {
  [ "$(decide_action 22 3 4 19 21)" = "scale_down" ]
  [ "$(decide_action 18 3 4 19 21)" = "scale_up" ]
  [ "$(decide_action 20 3 4 19 21)" = "hold" ]
  [ "$(decide_action 21 2 4 19 21)" = "scale_down" ]
  [ "$(decide_action 19 2 4 19 21)" = "hold" ]
}

test_prune_pid_list() {
  local out
  out="$(prune_pid_list "100 200 300" "100 300")"
  [ "$out" = "100 300" ]
}

test_decide_action
test_prune_pid_list
echo "PASS"
