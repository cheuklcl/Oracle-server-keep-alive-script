#!/bin/bash
# by spiritlhl
# from https://github.com/spiritLHLS/Oracle-server-keep-alive-script

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
LOW_WATERMARK=19
HIGH_WATERMARK=21
THROTTLE_HIGH=30
THROTTLE_RESUME=21
CHECK_INTERVAL=1
MAX_WORKERS=1
CPU_CORES=1
NORMAL_LIMIT_PER_WORKER=6
LOW_LIMIT_PER_WORKER=1
STARTUP_LOW_CYCLES=6
workers=()
limiter_pids=()
current_mode="normal"
current_limit=0
workers_paused=0

decide_action() {
  local usage="$1"
  local current_workers="$2"
  local max_workers="$3"
  local low="$4"
  local high="$5"

  if [ "$usage" -ge "$high" ] && [ "$current_workers" -gt 0 ]; then
    echo "scale_down"
  elif [ "$usage" -lt "$low" ] && [ "$current_workers" -lt "$max_workers" ]; then
    echo "scale_up"
  else
    echo "hold"
  fi
}

prune_pid_list() {
  local pids="$1"
  local alive="$2"
  local result=""
  local pid

  for pid in $pids; do
    case " $alive " in
      *" $pid "*) result="$result $pid" ;;
    esac
  done

  echo "${result# }"
}

worker_count() {
  echo "${#workers[@]}"
}

log_status() {
  local cpu_usage="$1"
  local action="$2"
  echo "cpu=${cpu_usage}% workers=$(worker_count) mode=${current_mode} limit=${current_limit}% action=${action}"
}

spawn_worker() {
  dd if=/dev/zero of=/dev/null >/dev/null 2>&1 &
  workers+=("$!")
}

kill_last_worker() {
  local count
  count="$(worker_count)"
  if [ "$count" -le 0 ]; then
    return 0
  fi

  local idx=$((count - 1))
  local pid="${workers[$idx]}"
  kill "$pid" >/dev/null 2>&1 || true
  unset 'workers[idx]'
  workers=("${workers[@]}")
}

kill_all_limiters() {
  local pid
  for pid in "${limiter_pids[@]}"; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  limiter_pids=()
}

start_limiter() {
  local pid="$1"
  local limit="$2"
  cpulimit -p "$pid" -l "$limit" >/dev/null 2>&1 &
  limiter_pids+=("$!")
}

apply_limiters() {
  local limit="$1"
  local pid

  current_limit="$limit"
  kill_all_limiters
  if ! command -v cpulimit >/dev/null 2>&1; then
    return 0
  fi

  for pid in "${workers[@]}"; do
    if ps -p "$pid" >/dev/null 2>&1; then
      start_limiter "$pid" "$limit"
    fi
  done
}

pause_workers() {
  local pid
  for pid in "${workers[@]}"; do
    kill -STOP "$pid" >/dev/null 2>&1 || true
  done
  workers_paused=1
}

resume_workers() {
  local pid
  for pid in "${workers[@]}"; do
    kill -CONT "$pid" >/dev/null 2>&1 || true
  done
  workers_paused=0
}

ensure_worker_count() {
  local target="$1"
  local count
  count="$(worker_count)"

  while [ "$count" -lt "$target" ]; do
    spawn_worker
    count="$(worker_count)"
  done

  while [ "$count" -gt "$target" ]; do
    kill_last_worker
    count="$(worker_count)"
  done
}

prune_workers() {
  local alive=""
  local pid

  for pid in "${workers[@]}"; do
    if ps -p "$pid" >/dev/null 2>&1; then
      alive="$alive $pid"
    fi
  done

  local pruned
  pruned="$(prune_pid_list "${workers[*]}" "${alive# }")"
  workers=()
  for pid in $pruned; do
    workers+=("$pid")
  done
}

cleanup() {
  kill_all_workers
  kill_all_limiters
  rm -f "${pid_file}"
}

kill_all_workers() {
  local pid
  for pid in "${workers[@]}"; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  workers=()
}

decide_throttle_state() {
  local usage="$1"
  local mode="$2"
  local high="$3"
  local resume="$4"

  if [ "$usage" -gt "$high" ]; then
    echo "throttle_on"
  elif [ "$mode" -eq 1 ] && [ "$usage" -ge "$resume" ]; then
    echo "throttle_hold"
  else
    echo "normal"
  fi
}

decide_protection_level() {
  local usage="$1"
  local protect_low="$2"
  if [ "$usage" -gt "$protect_low" ]; then
    echo "low"
  else
    echo "normal"
  fi
}

resolve_max_workers() {
  local cores="$1"
  if [ "$cores" -eq 4 ]; then
    echo 4
  else
    echo "$cores"
  fi
}

has_cpulimit() {
  if command -v cpulimit >/dev/null 2>&1; then
    echo "yes"
  else
    echo "no"
  fi
}

resolve_safe_worker_target() {
  local target="$1"
  local limiter_available="$2"

  if [ "$target" -eq 4 ] && [ "$limiter_available" = "no" ]; then
    echo 1
  else
    echo "$target"
  fi
}

get_cpu_usage() {
  local idle
  idle="$(top -bn1 2>/dev/null | awk -F',' '/Cpu\(s\)|CPU:/ {for(i=1;i<=NF;i++){if($i ~ /id/){gsub(/[^0-9.]/, "", $i); print $i; exit}}}')"
  if [ -z "$idle" ]; then
    idle="$(vmstat 1 2 2>/dev/null | awk 'NF && $1 ~ /^[0-9]+$/ {idle=$15} END {print idle}')"
  fi

  if [ -z "$idle" ]; then
    return 1
  fi

  awk -v i="$idle" 'BEGIN {u=100-i; if (u<0) u=0; if (u>100) u=100; printf "%.0f", u}'
}

ensure_single_instance() {
  if [ -e "${pid_file}" ]; then
    local pid
    pid="$(cat "${pid_file}")"
    if [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1; then
      echo "Error: Another instance of cpu-limit.sh is already running with PID ${pid}"
      exit 1
    fi
    rm -f "${pid_file}"
  fi
  echo $$ >"${pid_file}"
}

run_controller() {
  trap cleanup INT TERM EXIT

  local protection_mode="normal"
  local startup_left="$STARTUP_LOW_CYCLES"

  while true; do
    prune_workers

    local cpu_usage
    cpu_usage="$(get_cpu_usage)"
    if [ -z "$cpu_usage" ]; then
      sleep "$CHECK_INTERVAL"
      continue
    fi

    local action="hold"

    if [ "$CPU_CORES" -eq 4 ]; then
      local limiter_available
      limiter_available="$(has_cpulimit)"

      local level
      level="$(decide_protection_level "$cpu_usage" "$THROTTLE_HIGH")"

      if [ "$startup_left" -gt 0 ]; then
        protection_mode="low"
        startup_left=$((startup_left - 1))
      elif [ "$protection_mode" != "normal" ] && [ "$cpu_usage" -lt "$THROTTLE_RESUME" ]; then
        protection_mode="normal"
      elif [ "$level" = "low" ]; then
        protection_mode="low"
      fi

      case "$protection_mode" in
        normal)
          current_mode="normal"
          if [ "$workers_paused" -eq 1 ]; then
            resume_workers
          fi
          local safe_target
          safe_target="$(resolve_safe_worker_target "$MAX_WORKERS" "$limiter_available")"
          ensure_worker_count "$safe_target"
          if [ "$limiter_available" = "yes" ]; then
            apply_limiters "$NORMAL_LIMIT_PER_WORKER"
            action="normal_cap"
          else
            kill_all_limiters
            current_limit=0
            action="normal_nolimiter"
          fi
          ;;
        low)
          current_mode="protect_low"
          if [ "$limiter_available" = "yes" ]; then
            ensure_worker_count "$MAX_WORKERS"
            apply_limiters "$LOW_LIMIT_PER_WORKER"
            if [ "$workers_paused" -eq 0 ]; then
              pause_workers
            fi
            action="protect_low"
          else
            if [ "$workers_paused" -eq 0 ]; then
              pause_workers
            fi
            current_limit=0
            action="protect_low_nolimiter"
          fi
          ;;
      esac
    else
      action="$(decide_action "$cpu_usage" "$(worker_count)" "$MAX_WORKERS" "$LOW_WATERMARK" "$HIGH_WATERMARK")"
      case "$action" in
        scale_up)
          spawn_worker
          ;;
        scale_down)
          kill_last_worker
          ;;
        hold)
          ;;
      esac
      current_mode="legacy"
      current_limit=0
    fi

    log_status "$cpu_usage" "$action"
    sleep "$CHECK_INTERVAL"
  done
}

main() {
  ulimit -u 128
  CPU_CORES="$(nproc)"
  MAX_WORKERS="$(resolve_max_workers "$CPU_CORES")"
  ensure_single_instance
  run_controller
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi
