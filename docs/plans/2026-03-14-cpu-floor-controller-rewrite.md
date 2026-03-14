# CPU Floor Controller Rewrite Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rewrite the CPU occupier so it keeps total machine CPU above 21% on a 4-core machine by filling only the missing CPU gap.

**Architecture:** Replace the current `dd`/`cpulimit` hybrid with a single closed-loop PWM controller in `cpu-limit.sh`. The new controller keeps four permanent workers alive, measures total machine CPU once per second, and adjusts each worker's duty cycle gradually to maintain a total CPU floor while avoiding spikes.

**Tech Stack:** Bash, systemd, Linux CPU stats (`top` or `vmstat`), short-sleep PWM worker loops.

---

### Task 1: Add pure control-logic tests for floor controller math

**Files:**
- Modify: `tests/cpu_limit_test.sh`
- Modify: `cpu-limit.sh`

**Step 1: Write the failing test**

Add tests for pure helpers that do not exist yet:

```bash
test_compute_next_output() {
  [ "$(compute_next_output 8 0 21 24 8)" = "8" ]
  [ "$(compute_next_output 18 8 21 24 8)" = "11" ]
  [ "$(compute_next_output 24 12 21 24 8)" = "9" ]
}
```

**Step 2: Run test to verify it fails**

Run: `bash tests/cpu_limit_test.sh`
Expected: FAIL with `compute_next_output: command not found`

**Step 3: Write minimal implementation**

Add helpers in `cpu-limit.sh`:

```bash
compute_next_output() {
  local cpu="$1" current="$2" floor="$3" cap="$4" max_step="$5"
  # minimal clamped step logic
}
```

Also add:

- `clamp_output`
- `compute_error`
- `limit_step`

**Step 4: Run test to verify it passes**

Run: `bash tests/cpu_limit_test.sh`
Expected: `PASS`

**Step 5: Commit**

```bash
git add cpu-limit.sh tests/cpu_limit_test.sh
git commit -m "test: add cpu floor control math tests"
```

### Task 2: Add worker duty distribution tests

**Files:**
- Modify: `tests/cpu_limit_test.sh`
- Modify: `cpu-limit.sh`

**Step 1: Write the failing test**

Add test for splitting total output across 4 workers:

```bash
test_distribute_output() {
  [ "$(distribute_output 0 4)" = "0 0 0 0" ]
  [ "$(distribute_output 20 4)" = "5 5 5 5" ]
  [ "$(distribute_output 22 4)" = "6 6 5 5" ]
}
```

**Step 2: Run test to verify it fails**

Run: `bash tests/cpu_limit_test.sh`
Expected: FAIL with `distribute_output: command not found`

**Step 3: Write minimal implementation**

Implement `distribute_output` to spread total output across worker slots as evenly as possible.

**Step 4: Run test to verify it passes**

Run: `bash tests/cpu_limit_test.sh`
Expected: `PASS`

**Step 5: Commit**

```bash
git add cpu-limit.sh tests/cpu_limit_test.sh
git commit -m "test: add worker duty distribution tests"
```

### Task 3: Replace runtime control loop with permanent PWM workers

**Files:**
- Modify: `cpu-limit.sh`

**Step 1: Write the failing test**

Extend tests with worker target state helper:

```bash
test_target_mode() {
  [ "$(target_mode_for_cpu 18 21 24)" = "raise" ]
  [ "$(target_mode_for_cpu 22 21 24)" = "hold" ]
  [ "$(target_mode_for_cpu 27 21 24)" = "lower" ]
}
```

**Step 2: Run test to verify it fails**

Run: `bash tests/cpu_limit_test.sh`
Expected: FAIL with `target_mode_for_cpu: command not found`

**Step 3: Write minimal implementation**

Rewrite `cpu-limit.sh` runtime architecture:

- Create 4 permanent worker processes on startup
- Each worker reads its own target duty from a state file or shared file
- Worker loop:

```bash
while true; do
  duty=$(read_worker_duty "$idx")
  busy_ms=$(( duty * PWM_WINDOW_MS / 100 ))
  idle_ms=$(( PWM_WINDOW_MS - busy_ms ))
  busy_spin "$busy_ms"
  sleep_ms "$idle_ms"
done
```

- Controller loop:
  - reads total CPU
  - computes next total output
  - distributes output across 4 workers
  - writes worker duties

Remove runtime use of:

- `dd`
- `cpulimit`
- pause/stop worker toggling logic

**Step 4: Run test to verify it passes**

Run: `bash tests/cpu_limit_test.sh`
Expected: `PASS`

**Step 5: Commit**

```bash
git add cpu-limit.sh tests/cpu_limit_test.sh
git commit -m "feat: rewrite cpu occupier as pwm floor controller"
```

### Task 4: Simplify systemd service around new controller

**Files:**
- Modify: `cpu-limit.service`
- Modify: `oalive.sh`

**Step 1: Write the failing test**

Create a lightweight service regression expectation in shell test style:

```bash
grep -q 'CPUQuota=' cpu-limit.service && exit 1
```

**Step 2: Run test to verify it fails**

Run: `grep -q 'CPUQuota=' cpu-limit.service`
Expected: match found (current file still has quota)

**Step 3: Write minimal implementation**

- Remove `CPUQuota=35%` from `cpu-limit.service`
- Remove `cpulimit` install dependency from `oalive.sh`
- Keep service only for start/stop/restart lifecycle

**Step 4: Run test to verify it passes**

Run:

```bash
! grep -q 'CPUQuota=' cpu-limit.service
```

Expected: success

**Step 5: Commit**

```bash
git add cpu-limit.service oalive.sh
git commit -m "refactor: remove legacy cpu limiter dependencies"
```

### Task 5: Verify runtime behavior and cleanup behavior

**Files:**
- Modify: `tests/oalive_uninstall_test.sh` if uninstall paths need updating

**Step 1: Write the failing test**

Define manual runtime verification checklist and first run it against old behavior.

Commands:

```bash
systemctl restart cpu-limit.service
sleep 15
journalctl -u cpu-limit.service -n 50 --no-pager
```

Expected before rewrite: unstable output or wrong total CPU floor.

**Step 2: Run test to verify it fails**

Also run stop verification:

```bash
systemctl stop cpu-limit.service
pgrep -fa cpu-limit.sh
```

Expected before fix: stale behavior or non-obvious worker cleanup.

**Step 3: Write minimal implementation**

No extra code beyond rewrite unless uninstall/cleanup path needs final adjustment.

**Step 4: Run test to verify it passes**

Run:

```bash
bash tests/cpu_limit_test.sh
bash tests/oalive_uninstall_test.sh
bash tests/oalive_source_urls_test.sh
```

Then on Linux host:

```bash
systemctl daemon-reload
systemctl restart cpu-limit.service
```

Expected:

- total CPU trends above 21%
- no repeated process churn
- stop/uninstall clears worker activity

**Step 5: Commit**

```bash
git add cpu-limit.sh cpu-limit.service oalive.sh tests/*.sh
git commit -m "fix: stabilize cpu floor controller behavior"
```
