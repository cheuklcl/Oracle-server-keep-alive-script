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
CHECK_INTERVAL=2
MAX_WORKERS=1
workers=()
throttle_mode=0

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
  local mode="normal"
  if [ "$throttle_mode" -eq 1 ]; then
    mode="throttle"
  fi
  echo "cpu=${cpu_usage}% workers=$(worker_count) mode=${mode} action=${action}"
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
  local pid
  for pid in "${workers[@]}"; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  workers=()
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

resolve_max_workers() {
  local cores="$1"
  if [ "$cores" -eq 4 ]; then
    echo 1
  else
    echo "$cores"
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

  local tick=0

  while true; do
    prune_workers

    local cpu_usage
    cpu_usage="$(get_cpu_usage)"
    if [ -z "$cpu_usage" ]; then
      sleep "$CHECK_INTERVAL"
      continue
    fi

    local action
    local throttle_state
    throttle_state="$(decide_throttle_state "$cpu_usage" "$throttle_mode" "$THROTTLE_HIGH" "$THROTTLE_RESUME")"

    case "$throttle_state" in
      throttle_on)
        throttle_mode=1
        kill_all_workers
        action="throttle_on"
        log_status "$cpu_usage" "$action"
        sleep "$CHECK_INTERVAL"
        continue
        ;;
      throttle_hold)
        throttle_mode=1
        kill_all_workers
        action="throttle_hold"
        log_status "$cpu_usage" "$action"
        sleep "$CHECK_INTERVAL"
        continue
        ;;
      normal)
        throttle_mode=0
        ;;
    esac

    action="$(decide_action "$cpu_usage" "$(worker_count)" "$MAX_WORKERS" "$LOW_WATERMARK" "$HIGH_WATERMARK")"

    if [ "$MAX_WORKERS" -eq 1 ] && [ "$action" = "hold" ]; then
      tick=$((tick + 1))
      if [ "$cpu_usage" -lt 20 ] && [ $((tick % 5)) -eq 0 ]; then
        if [ "$(worker_count)" -eq 0 ]; then
          spawn_worker
          action="pulse_on"
        fi
      elif [ "$cpu_usage" -ge 24 ] && [ $((tick % 2)) -eq 0 ]; then
        if [ "$(worker_count)" -gt 0 ]; then
          kill_last_worker
          action="pulse_off"
        fi
      fi
    fi

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

    log_status "$cpu_usage" "$action"
    sleep "$CHECK_INTERVAL"
  done
}

main() {
  ulimit -u 128
  MAX_WORKERS="$(resolve_max_workers "$(nproc)")"
  ensure_single_instance
  run_controller
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi
