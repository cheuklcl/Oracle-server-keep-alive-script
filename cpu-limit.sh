#!/bin/bash
# by spiritlhl
# rewritten floor controller

if [[ -d "/usr/share/locale/en_US.UTF-8" ]]; then
  export LANG=en_US.UTF-8
  export LC_ALL=en_US.UTF-8
  export LANGUAGE=en_US.UTF-8
else
  export LANG=C.UTF-8
  export LC_ALL=C.UTF-8
  export LANGUAGE=C.UTF-8
fi

pid_file=/tmp/cpu-limit.pid
state_dir=/tmp/cpu-floor-controller
TARGET_FLOOR=21
TARGET_CAP=24
CONTROL_INTERVAL=1
PWM_WINDOW_MS=200
MAX_STEP_PER_TICK=8
MAX_OUTPUT=100
WORKER_COUNT=4
CORE_COUNT=4

clamp_output() {
  local value="$1"
  local min="$2"
  local max="$3"

  if [ "$value" -lt "$min" ]; then
    echo "$min"
  elif [ "$value" -gt "$max" ]; then
    echo "$max"
  else
    echo "$value"
  fi
}

limit_step() {
  local current="$1"
  local desired="$2"
  local max_step="$3"
  local diff=$((desired - current))

  if [ "$diff" -gt "$max_step" ]; then
    echo $((current + max_step))
  elif [ "$diff" -lt $((-max_step)) ]; then
    echo $((current - max_step))
  else
    echo "$desired"
  fi
}

target_mode_for_cpu() {
  local cpu="$1"
  local floor="$2"
  local cap="$3"

  if [ "$cpu" -lt "$floor" ]; then
    echo "raise"
  elif [ "$cpu" -gt "$cap" ]; then
    echo "lower"
  else
    echo "hold"
  fi
}

compute_next_output() {
  local cpu="$1"
  local current="$2"
  local floor="$3"
  local cap="$4"
  local max_step="$5"
  local desired="$current"

  if [ "$cpu" -lt "$floor" ]; then
    desired=$((current + floor - cpu))
  elif [ "$cpu" -gt "$cap" ]; then
    desired=$((current - (cpu - cap)))
  fi

  desired="$(clamp_output "$desired" 0 "$MAX_OUTPUT")"
  limit_step "$current" "$desired" "$max_step"
}

distribute_output() {
  local total="$1"
  local count="$2"
  local per_core_total=$((total * CORE_COUNT))
  local base=$((per_core_total / count))
  local remainder=$((per_core_total % count))
  local result=""
  local i

  for ((i = 0; i < count; i++)); do
    local value="$base"
    if [ "$i" -lt "$remainder" ]; then
      value=$((value + 1))
    fi
    result="$result $value"
  done

  echo "${result# }"
}

sleep_ms() {
  local ms="$1"
  if [ "$ms" -le 0 ]; then
    return 0
  fi
  python3 - "$ms" <<'PY'
import sys, time
time.sleep(int(sys.argv[1]) / 1000)
PY
}

busy_spin() {
  local ms="$1"
  if [ "$ms" -le 0 ]; then
    return 0
  fi
  python3 - "$ms" <<'PY'
import sys, time
deadline = time.perf_counter() + int(sys.argv[1]) / 1000
while time.perf_counter() < deadline:
    pass
PY
}

worker_state_file() {
  local idx="$1"
  echo "$state_dir/worker_${idx}.duty"
}

read_worker_duty() {
  local idx="$1"
  local file
  file="$(worker_state_file "$idx")"
  if [ -f "$file" ]; then
    cat "$file"
  else
    echo 0
  fi
}

write_worker_duty() {
  local idx="$1"
  local duty="$2"
  printf '%s\n' "$duty" >"$(worker_state_file "$idx")"
}

spawn_worker() {
  local idx="$1"
  (
    while true; do
      duty="$(read_worker_duty "$idx")"
      busy_ms=$((duty * PWM_WINDOW_MS / 100))
      idle_ms=$((PWM_WINDOW_MS - busy_ms))
      busy_spin "$busy_ms"
      sleep_ms "$idle_ms"
    done
  ) &
  echo "$!"
}

kill_all_workers() {
  local pid
  for pid in "$state_dir"/worker_*.pid; do
    [ -e "$pid" ] || continue
    kill "$(cat "$pid")" >/dev/null 2>&1 || true
  done
  rm -f "$state_dir"/worker_*.pid
}

get_cpu_usage() {
  local idle
  idle="$(top -bn1 2>/dev/null | awk -F',' '/Cpu\(s\)|CPU:/ {for(i=1;i<=NF;i++){if($i ~ /id/){gsub(/[^0-9.]/, "", $i); print $i; exit}}}')"
  if [ -z "$idle" ]; then
    idle="$(vmstat 1 2 2>/dev/null | awk 'NF && $1 ~ /^[0-9]+$/ {idle=$15} END {print idle}')"
  fi
  [ -n "$idle" ] || return 1
  awk -v i="$idle" 'BEGIN {u=100-i; if (u<0) u=0; if (u>100) u=100; printf "%.0f", u}'
}

log_status() {
  local cpu_usage="$1"
  local output="$2"
  local mode
  mode="$(target_mode_for_cpu "$cpu_usage" "$TARGET_FLOOR" "$TARGET_CAP")"
  echo "cpu=${cpu_usage}% output=${output}% mode=${mode}"
}

ensure_single_instance() {
  if [ -e "$pid_file" ]; then
    local pid
    pid="$(cat "$pid_file")"
    if [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1; then
      echo "Error: Another instance of cpu-limit.sh is already running with PID ${pid}"
      exit 1
    fi
    rm -f "$pid_file"
  fi
  echo $$ >"$pid_file"
}

setup_workers() {
  mkdir -p "$state_dir"
  local i pid
  for ((i = 0; i < WORKER_COUNT; i++)); do
    write_worker_duty "$i" 0
    spawn_worker "$i"
    pid="$!"
    printf '%s\n' "$pid" >"$state_dir/worker_${i}.pid"
  done
}

cleanup() {
  kill_all_workers
  rm -rf "$state_dir"
  rm -f "$pid_file"
}

run_controller() {
  trap cleanup INT TERM EXIT

  local current_output=0
  while true; do
    local cpu_usage
    cpu_usage="$(get_cpu_usage)"
    if [ -z "$cpu_usage" ]; then
      sleep "$CONTROL_INTERVAL"
      continue
    fi

    current_output="$(compute_next_output "$cpu_usage" "$current_output" "$TARGET_FLOOR" "$TARGET_CAP" "$MAX_STEP_PER_TICK")"
    local duties
    duties="$(distribute_output "$current_output" "$WORKER_COUNT")"

    local idx=0 duty
    for duty in $duties; do
      write_worker_duty "$idx" "$duty"
      idx=$((idx + 1))
    done

    log_status "$cpu_usage" "$current_output"
    sleep "$CONTROL_INTERVAL"
  done
}

main() {
  CORE_COUNT="$(nproc 2>/dev/null || echo 4)"
  ensure_single_instance
  setup_workers
  run_controller
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi
