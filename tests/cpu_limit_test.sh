#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../cpu-limit.sh"

test_clamp_output() {
  [ "$(clamp_output -5 0 100)" = "0" ]
  [ "$(clamp_output 44 0 100)" = "44" ]
  [ "$(clamp_output 120 0 100)" = "100" ]
}

test_limit_step() {
  [ "$(limit_step 0 20 8)" = "8" ]
  [ "$(limit_step 20 0 8)" = "12" ]
  [ "$(limit_step 10 15 8)" = "15" ]
}

test_target_mode() {
  [ "$(target_mode_for_cpu 18 21 24)" = "raise" ]
  [ "$(target_mode_for_cpu 22 21 24)" = "hold" ]
  [ "$(target_mode_for_cpu 27 21 24)" = "lower" ]
}

test_compute_next_output() {
  [ "$(compute_next_output 8 0 21 24 8)" = "8" ]
  [ "$(compute_next_output 18 8 21 24 8)" = "11" ]
  [ "$(compute_next_output 27 12 21 24 8)" = "9" ]
}

test_distribute_output() {
  [ "$(distribute_output 0 4)" = "0 0 0 0" ]
  [ "$(distribute_output 20 4)" = "5 5 5 5" ]
  [ "$(distribute_output 22 4)" = "6 6 5 5" ]
}

test_clamp_output
test_limit_step
test_target_mode
test_compute_next_output
test_distribute_output
echo "PASS"
