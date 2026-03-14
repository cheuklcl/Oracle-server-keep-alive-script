# CPU Floor Controller Rewrite Design

**Date:** 2026-03-14
**Project:** `Oracle-server-keep-alive-script`
**Scope:** Full rewrite of CPU occupier behavior in `cpu-limit.sh`

---

## Problem

The current CPU occupier has been patched multiple times and still does not satisfy the actual goal. It often only keeps total machine CPU near 10%, while the user needs total machine CPU to stay above 21%. The existing design mixes `dd`, `cpulimit`, service-level quotas, and threshold logic. These controls interact poorly and are hard to reason about.

---

## Actual Goal

The CPU occupier should act as a **floor controller** for total machine CPU usage.

- If total machine CPU is below 21%, occupier adds load.
- If total machine CPU is already above 21%, occupier reduces its own load.
- Occupier should only fill the gap needed to keep total CPU above 21%.
- The occupier should avoid creating spikes or oscillation.

Secondary preference:

- Keep total CPU roughly in the 21%-24% range when possible.

---

## Selected Approach

### PWM worker controller (selected)

Rewrite `cpu-limit.sh` as a small closed-loop controller using 4 permanent workers.

- No `dd`
- No `cpulimit`
- No systemd quota dependence for normal control
- Workers stay alive and follow duty-cycle commands from the controller

Why selected:

- Directly controls total machine CPU instead of stacking unrelated mechanisms
- No startup spikes from killing/recreating `dd`
- Easier to reason about and tune
- Matches user intent: fill the CPU gap, do not hard-switch behavior

### Alternatives considered

#### A) Keep `dd` + tune `cpulimit`

Rejected because:

- `cpulimit` semantics are per-process and easy to mis-tune
- Interacts badly with multi-worker total CPU goals
- Existing attempts already showed unstable/incorrect outcomes

#### B) `stress-ng --cpu-load`

Rejected because:

- Adds heavier external dependency
- Behavior varies by version/platform
- Less transparent than a local controller loop

---

## Architecture

### Components

1. **Controller loop**
   - Runs every 1 second
   - Measures current total machine CPU
   - Computes occupier output needed to maintain the CPU floor
   - Smooths changes to avoid oscillation

2. **4 permanent workers**
   - Lightweight busy-loop workers implemented in bash
   - Each worker receives a duty-cycle value
   - Workers are created once and terminated only on service stop

3. **PWM scheduler**
   - Worker window: 200ms
   - Within each window, worker spends part of the time busy and the rest sleeping
   - This gives controllable average CPU output without rapid process churn

---

## Control Model

### Targets

- `TARGET_FLOOR=21`
- `TARGET_CAP=24`
- `CONTROL_INTERVAL=1s`
- `PWM_WINDOW_MS=200`
- `MAX_STEP_PER_TICK=8` total output points

### Behavior

- Let `current_cpu` be measured total machine CPU usage.
- Compute `needed = TARGET_FLOOR - current_cpu`.
- If `needed > 0`, raise occupier output.
- If `current_cpu >= TARGET_FLOOR`, reduce occupier output.
- If `current_cpu > TARGET_CAP`, reduce output more aggressively.
- Never drop below 0 output.
- Never exceed 100 total output points.

Occupier output is represented as a total percentage budget and distributed evenly across 4 workers.

Examples:

- Machine at 8% -> occupier adds about 13%+
- Machine at 18% -> occupier adds about 3%+
- Machine at 24% -> occupier output trends toward 0

---

## Stability Rules

- Workers stay alive for the full service lifetime.
- Controller changes output gradually, not instantly.
- Do not use hard stop/restart thresholds for normal control.
- Avoid secondary control mechanisms during runtime.

This is the key correction versus earlier designs.

---

## systemd Role

Keep `cpu-limit.service` only for:

- start/stop lifecycle
- restart on failure
- cleanup integration

Do not rely on `CPUQuota` for the actual CPU control logic.

---

## Testing Strategy

### Logic tests

Add bash tests for pure helpers:

- translating CPU readings to desired output delta
- clamping output range
- smoothing step limits
- distributing total output across 4 workers

### Runtime verification

1. Idle machine:
   - Start service
   - Observe total CPU stabilizing around 21%-24%

2. Existing external load:
   - Add synthetic load
   - Confirm occupier output falls but total CPU remains at or above 21% where possible

3. External load removed:
   - Confirm occupier increases smoothly without spike

4. Service stop:
   - All workers exit
   - No stale pid files remain

---

## Success Criteria

- On a mostly idle 4-core machine, total CPU stays above 21% and usually under 24%-25%.
- No repeated worker creation/destruction under normal operation.
- No dependency on `cpulimit`.
- No dependence on `dd`.
- Service stop removes all worker activity.
