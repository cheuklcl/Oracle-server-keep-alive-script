# CPU Feedback Control Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make CPU occupier stop when host CPU >21% and resume when host CPU <19%, keeping total CPU around 20%-25%.

**Architecture:** Replace static all-core `dd` launch with a single feedback controller loop in `cpu-limit.sh`. The loop samples host CPU and scales worker count by one step per cycle using hysteresis (`19/21`) to avoid oscillation. Keep systemd service flow, but harden stop path and avoid conflicting static quota control.

**Tech Stack:** Bash, systemd (`cpu-limit.service`), Linux tools (`top`, `vmstat`, `nproc`, `ps`, `kill`).

---

### Task 1: Add test harness for CPU controller logic

**Files:**
- Create: `tests/cpu_limit_test.sh`
- Modify: `cpu-limit.sh`

**Step 1: Write the failing test**

Create `tests/cpu_limit_test.sh` with isolated unit-style checks for pure logic helpers to be added in `cpu-limit.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../cpu-limit.sh"

test_scale_decision() {
  [ "$(decide_action 22 3 4 19 21)" = "scale_down" ]
  [ "$(decide_action 18 3 4 19 21)" = "scale_up" ]
  [ "$(decide_action 20 3 4 19 21)" = "hold" ]
}

test_scale_decision
echo "PASS"
```

**Step 2: Run test to verify it fails**

Run: `bash tests/cpu_limit_test.sh`
Expected: FAIL with `decide_action: command not found` (or equivalent missing function error)

**Step 3: Write minimal implementation**

Add a `decide_action` helper to `cpu-limit.sh`:

```bash
decide_action() {
  local usage=$1 workers=$2 max_workers=$3 low=$4 high=$5
  if [ "$usage" -ge "$high" ] && [ "$workers" -gt 0 ]; then
    echo "scale_down"
  elif [ "$usage" -lt "$low" ] && [ "$workers" -lt "$max_workers" ]; then
    echo "scale_up"
  else
    echo "hold"
  fi
}
```

**Step 4: Run test to verify it passes**

Run: `bash tests/cpu_limit_test.sh`
Expected: `PASS`

**Step 5: Commit**

```bash
git add tests/cpu_limit_test.sh cpu-limit.sh
git commit -m "test: add cpu feedback decision tests"
```

### Task 2: Implement worker pool lifecycle in cpu-limit.sh

**Files:**
- Modify: `cpu-limit.sh`
- Test: `tests/cpu_limit_test.sh`

**Step 1: Write the failing test**

Extend `tests/cpu_limit_test.sh` with worker list behavior checks (logic-only):

```bash
test_prune_pid_list() {
  local out
  out="$(prune_pid_list "100 200 300" "100 300")"
  [ "$out" = "100 300" ]
}
```

**Step 2: Run test to verify it fails**

Run: `bash tests/cpu_limit_test.sh`
Expected: FAIL with `prune_pid_list: command not found`

**Step 3: Write minimal implementation**

Add in `cpu-limit.sh`:
- `workers=()` array
- `spawn_worker`, `kill_last_worker`, `prune_workers`
- `cleanup` trap to stop all workers and remove pid file

Minimal function sketch:

```bash
spawn_worker() { dd if=/dev/zero of=/dev/null & workers+=("$!"); }
kill_last_worker() { local idx=$(( ${#workers[@]} - 1 )); kill "${workers[$idx]}" 2>/dev/null || true; unset 'workers[$idx]'; }
```

**Step 4: Run test to verify it passes**

Run: `bash tests/cpu_limit_test.sh`
Expected: `PASS`

**Step 5: Commit**

```bash
git add cpu-limit.sh tests/cpu_limit_test.sh
git commit -m "feat: add dd worker pool lifecycle"
```

### Task 3: Implement CPU sampling + control loop

**Files:**
- Modify: `cpu-limit.sh`
- Test: `tests/cpu_limit_test.sh`

**Step 1: Write the failing test**

Add test for action transitions:

```bash
test_boundaries() {
  [ "$(decide_action 21 2 4 19 21)" = "scale_down" ]
  [ "$(decide_action 19 2 4 19 21)" = "hold" ]
}
```

**Step 2: Run test to verify it fails**

Run: `bash tests/cpu_limit_test.sh`
Expected: FAIL on boundary mismatch

**Step 3: Write minimal implementation**

Implement in `cpu-limit.sh`:
- `get_cpu_usage` with `top` primary and `vmstat` fallback
- constants:
  - `LOW_WATERMARK=19`
  - `HIGH_WATERMARK=21`
  - `CHECK_INTERVAL=2`
  - `MAX_WORKERS=$(nproc)`
- loop:
  - read CPU
  - `action=$(decide_action ...)`
  - scale one step per iteration
  - print concise log line
  - sleep

**Step 4: Run test to verify it passes**

Run: `bash tests/cpu_limit_test.sh`
Expected: `PASS`

**Step 5: Commit**

```bash
git add cpu-limit.sh tests/cpu_limit_test.sh
git commit -m "feat: add cpu feedback scaling loop"
```

### Task 4: Harden systemd service stop behavior

**Files:**
- Modify: `cpu-limit.service`

**Step 1: Write the failing test**

Run a stop simulation before fix:

Run: `bash -lc 'rm -f /tmp/cpu-limit.pid; /bin/bash -c "kill $(cat /tmp/cpu-limit.pid)"'`
Expected: FAIL due empty/missing pid

**Step 2: Run test to verify it fails**

Run: `systemd-analyze verify cpu-limit.service`
Expected: service verifies, but stop command still unsafe by manual simulation

**Step 3: Write minimal implementation**

Change `ExecStop` to guarded command:

```ini
ExecStop=/bin/bash -c '[ -f /tmp/cpu-limit.pid ] && kill "$(cat /tmp/cpu-limit.pid)" 2>/dev/null || true; rm -f /tmp/cpu-limit.pid'
```

**Step 4: Run test to verify it passes**

Run: `systemd-analyze verify cpu-limit.service`
Expected: no errors

**Step 5: Commit**

```bash
git add cpu-limit.service
git commit -m "fix: guard cpu-limit service stop path"
```

### Task 5: End-to-end runtime verification

**Files:**
- Modify: `README.md` (optional notes if behavior docs updated)

**Step 1: Write the failing test**

Define acceptance checks script/commands and run before deploy (expected fail on old behavior):

```bash
systemctl restart cpu-limit.service
sleep 60
top -bn1 | head -n 5
```

Expected before fix: CPU control does not react to external load thresholds reliably.

**Step 2: Run test to verify it fails**

Run with external load:

```bash
stress --cpu 2 --timeout 90
```

Expected before fix: occupier keeps running aggressively.

**Step 3: Write minimal implementation**

No additional code. Use implemented controller.

**Step 4: Run test to verify it passes**

Run:

```bash
systemctl restart cpu-limit.service
journalctl -u cpu-limit.service -n 80 --no-pager
```

Expected:
- Logs show `scale_down` when CPU >= 21
- Logs show `scale_up` when CPU < 19
- CPU trends near 20%-25% under idle baseline

**Step 5: Commit**

```bash
git add README.md
git commit -m "docs: describe cpu feedback thresholds"
```
