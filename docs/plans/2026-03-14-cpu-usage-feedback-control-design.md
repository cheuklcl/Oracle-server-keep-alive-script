# CPU Usage Feedback Control Design

**Date:** 2026-03-14
**Project:** `Oracle-server-keep-alive-script`
**Scope:** CPU keep-alive behavior in `cpu-limit.sh` and related service integration

---

## Context

Current CPU mode starts one `dd if=/dev/zero of=/dev/null` worker per core and relies on systemd `CPUQuota` to cap total usage. This does not react to external workload in real time and cannot strictly enforce the behavior: stop occupying when machine CPU is above threshold, occupy when below threshold.

User requirement (confirmed):

- Metric: total machine CPU usage only
- Hysteresis: stop occupying when CPU > 21%, resume occupying when CPU < 19%
- Goal band: keep total CPU around 20%-25%

---

## Approaches Considered

### A) Dynamic worker controller in `cpu-limit.sh` (selected)

- Supervisor loop reads host CPU every fixed interval
- Adds/removes `dd` workers one-by-one based on thresholds
- Maintains worker PID list and cleans up on exit

Why selected:

- Best match for requirement (real-time and host-level feedback)
- No dependence on static `CPUQuota` behavior
- Stable control using hysteresis + single-step adjustment

### B) Keep static workers + pause/resume only

- Start fixed worker set, stop all at high threshold, restart at low threshold
- Simpler, but coarse and oscillatory

Not selected because:

- Poor precision for 20%-25% goal
- Larger swings and slower convergence

### C) systemd timer-based periodic on/off

- Duty-cycle approximation via periodic start/stop

Not selected because:

- No closed-loop control
- Weak adaptation to changing external load

---

## Selected Design

### Runtime model

- Single supervisor process (`cpu-limit.sh`)
- Worker pool of background `dd` processes
- Polling interval: 2 seconds
- Thresholds:
  - `LOW_WATERMARK=19`
  - `HIGH_WATERMARK=21`

### Control behavior

- If `cpu_usage >= HIGH_WATERMARK`: reduce 1 worker (down to 0)
- If `cpu_usage < LOW_WATERMARK`: add 1 worker (up to `nproc`)
- Else: hold current worker count

### CPU measurement

- Primary: parse `top -bn1` CPU line and derive usage
- Fallback: parse `vmstat 1 2` idle percentage
- Clamp/validate values to avoid malformed input causing runaway scaling

### Process safety

- Existing pid file uniqueness retained (`/tmp/cpu-limit.pid`)
- On start: clear stale pid file if process is dead
- `trap` on `INT TERM EXIT` to kill all workers and remove pid file
- Periodic pruning of dead worker PIDs

### systemd integration

- Keep `cpu-limit.service` lifecycle and auto-restart behavior
- Harden `ExecStop` command to avoid failure on missing pid file
- Avoid relying on `CPUQuota` for this mode to prevent dual-control conflict

---

## Error Handling

- If CPU read fails in one cycle, skip adjustment and retry next interval
- If worker spawn fails, log and continue loop
- If kill fails for one PID, continue cleanup for others
- Do not exit loop for transient parsing failures

---

## Observability

Emit concise logs for:

- Current CPU percent
- Worker count
- Action per cycle (`scale_up`, `scale_down`, `hold`)

This supports runtime checks with:

- `journalctl -u cpu-limit.service -f`

---

## Verification Criteria

1. Under idle baseline, service ramps up and keeps total CPU near 20%-25%.
2. When external workload pushes CPU above 21%, service scales down and can reach 0 workers.
3. After external load is removed and CPU drops below 19%, service scales up again.
4. `systemctl stop cpu-limit.service` leaves no orphan worker and no stale pid file.
5. `systemctl restart cpu-limit.service` cleanly replaces process/workers.

---

## Out of Scope

- Memory and bandwidth occupier behavior
- New user-facing installer prompts
- Rewriting architecture beyond CPU script/service touchpoints
