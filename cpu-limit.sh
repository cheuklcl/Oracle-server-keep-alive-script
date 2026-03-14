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
CHECK_INTERVAL=2
MAX_WORKERS=1
workers=()

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
  echo "cpu=${cpu_usage}% workers=$(worker_count) action=${action}"
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

  while true; do
    prune_workers

    local cpu_usage
    cpu_usage="$(get_cpu_usage)"
    if [ -z "$cpu_usage" ]; then
      sleep "$CHECK_INTERVAL"
      continue
    fi

    local action
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

    log_status "$cpu_usage" "$action"
    sleep "$CHECK_INTERVAL"
  done
}

main() {
  ulimit -u 128
  MAX_WORKERS="$(nproc)"
  ensure_single_instance
  run_controller
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi
