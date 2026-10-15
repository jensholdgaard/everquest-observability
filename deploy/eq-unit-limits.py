#!/usr/bin/env python3
"""What each service may use, next to what it uses (2026-10-15).

The host_metrics and systemd receivers say how much memory and CPU the box and its units
use, but nothing says where the ceiling is: ourios.service runs under MemoryMax=1536M
(ourios-memory.conf) and LimitNOFILE=65536 (ourios-limits.conf), and neither number was
visible anywhere, so "541 MB and climbing" could not be read as near or far from a kill.
No receiver in the collector reads cgroup limits, so this does, from the files the kernel
publishes for every unit, and posts them as OTLP to the gateway's localhost-only
otlp/local listener (collector/gateway.yaml).

Run every 30 s by eq-unit-limits.timer, as a dynamic user: every file read here is
world-readable (cgroup v2 under /sys/fs/cgroup, /proc/<pid>/limits).

There are no semantic conventions for a systemd unit's limits (container.* and
k8s.container.* are the nearest), so the names extend the collector systemd receiver's
systemd.service.* namespace and follow the general naming rules: .limit is the ceiling,
.usage what is in use out of it, .utilization the ratio.
"""
import json
import os
import sys
import time
import urllib.request

ENDPOINT = "http://127.0.0.1:4322/v1/metrics"
UNITS = [
    "ourios.service",
    "nocturnal.service",
    "eq-gateway.service",
    "jaeger.service",
    "prometheus.service",
    "perses.service",
    "caddy.service",
]
# The unit whose numbers belong to a service that reports its own telemetry: its resource
# carries that service's name, so the limits sit next to its own process.* metrics (and pass
# filter/only_ourios on the way to Dash0). Every other unit is the box's (eq-perses).
SERVICE_NAMES = {"ourios.service": "ourios-server"}
CGROUP = "/sys/fs/cgroup/system.slice/"


def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def keyed(path):
    """'key value' lines (memory.events, pids.events) as a dict of ints."""
    out = {}
    for line in (read(path) or "").splitlines():
        k, _, v = line.partition(" ")
        if v.isdigit():
            out[k] = int(v)
    return out


def pressure(path):
    """PSI 'some/full ... total=<us>' lines as {kind: seconds stalled since the cgroup began}."""
    out = {}
    for line in (read(path) or "").splitlines():
        parts = line.split()
        total = next((p[6:] for p in parts if p.startswith("total=")), None)
        if parts and total and total.isdigit():
            out[parts[0]] = int(total) / 1e6
    return out


def unit_main(base):
    """The unit's oldest process and when it started, in ns since the epoch - from the cgroup and
    /proc, not systemctl: under DynamicUser the system bus is not reachable ("Transport endpoint
    is not connected", 2026-10-15), which left the fd limit missing and every cumulative series
    restarting each run. The oldest process in the cgroup is the one systemd started."""
    pids = [int(p) for p in (read(base + "cgroup.procs") or "").split() if p.isdigit()]
    if not pids:
        return 0, None
    pid = min(pids)
    stat = read(f"/proc/{pid}/stat") or ""
    btime = next((int(l.split()[1]) for l in (read("/proc/stat") or "").splitlines() if l.startswith("btime ")), None)
    try:
        ticks = int(stat.rsplit(")", 1)[1].split()[19])  # field 22, starttime, after the comm field
    except (IndexError, ValueError):
        return pid, None
    if btime is None:
        return pid, None
    return pid, btime * 10**9 + ticks * 10**9 // os.sysconf("SC_CLK_TCK")


def nofile_limit(pid):
    for line in (read(f"/proc/{pid}/limits") or "").splitlines():
        if line.startswith("Max open files"):
            soft = line.split()[3]  # the soft limit is the one that binds
            return int(soft) if soft.isdigit() else None
    return None


def attrs(d):
    return [{"key": k, "value": {"stringValue": v}} for k, v in d.items()]


def gauge(name, unit, desc, points):
    return {"name": name, "unit": unit, "description": desc, "gauge": {"dataPoints": points}}


def updown(name, unit, desc, points):
    return {"name": name, "unit": unit, "description": desc,
            "sum": {"dataPoints": points, "aggregationTemporality": 2, "isMonotonic": False}}


def counter(name, unit, desc, points):
    return {"name": name, "unit": unit, "description": desc,
            "sum": {"dataPoints": points, "aggregationTemporality": 2, "isMonotonic": True}}


def unit_metrics(unit, now_ns):
    base = CGROUP + unit + "/"
    current = read(base + "memory.current")
    if current is None:
        return None  # not running, or no such unit: nothing to say
    pid, started_ns = unit_main(base)
    start_ns = str(started_ns) if started_ns else now_ns

    def pt(value, a=None, cumulative=False):
        p = {"timeUnixNano": now_ns, "attributes": attrs(a or {})}
        if cumulative:
            p["startTimeUnixNano"] = start_ns
        p["asDouble" if isinstance(value, float) else "asInt"] = value if isinstance(value, float) else str(value)
        return p

    usage = int(current)
    metrics = [updown("systemd.service.memory.usage", "By",
                      "Memory charged to the unit's cgroup (memory.current): anonymous memory and page cache.",
                      [pt(usage)])]

    limits = []
    hard = read(base + "memory.max")
    soft = read(base + "memory.high")
    if hard and hard.isdigit():
        limits.append(pt(int(hard), {"systemd.service.memory.limit.kind": "hard"}))
    if soft and soft.isdigit():
        limits.append(pt(int(soft), {"systemd.service.memory.limit.kind": "soft"}))
    if limits:
        metrics.append(updown("systemd.service.memory.limit", "By",
                              "The unit's memory ceiling: hard is MemoryMax (the OOM kill), soft is MemoryHigh (throttling). Absent when unlimited.",
                              limits))
    if hard and hard.isdigit():
        metrics.append(gauge("systemd.service.memory.utilization", "1",
                             "memory.current over MemoryMax; at 1 the kernel kills the unit.",
                             [pt(usage / int(hard))]))
    peak = read(base + "memory.peak")
    if peak and peak.isdigit():
        metrics.append(gauge("systemd.service.memory.peak", "By",
                             "Highest memory.current since the unit's cgroup was created (its last start).",
                             [pt(int(peak))]))

    events = keyed(base + "memory.events")
    ev = [pt(events[k], {"systemd.service.memory.event": k}, cumulative=True)
          for k in ("high", "max", "oom", "oom_kill") if k in events]
    if ev:
        metrics.append(counter("systemd.service.memory.events", "{event}",
                               "memory.events since the unit started: high = throttled at MemoryHigh, max = hit MemoryMax, oom_kill = a process killed for it.",
                               ev))

    stall = []
    for resource in ("cpu", "memory", "io"):
        for kind, seconds in pressure(base + f"{resource}.pressure").items():
            stall.append(pt(seconds, {"systemd.service.pressure.resource": resource,
                                      "systemd.service.pressure.stall": kind}, cumulative=True))
    if stall:
        metrics.append(counter("systemd.service.pressure.stall.time", "s",
                               "Pressure stall (PSI) time: some = at least one task waited on the resource, full = all did.",
                               stall))

    tasks = read(base + "pids.current")
    if tasks and tasks.isdigit():
        metrics.append(updown("systemd.service.task.count", "{task}", "Tasks (threads) in the unit's cgroup.",
                              [pt(int(tasks))]))
    task_max = read(base + "pids.max")
    if task_max and task_max.isdigit():
        metrics.append(updown("systemd.service.task.limit", "{task}", "TasksMax: the most tasks the unit may hold.",
                              [pt(int(task_max))]))
    fds = nofile_limit(pid) if pid else None
    if fds:
        metrics.append(updown("systemd.service.file_descriptor.limit", "{file_descriptor}",
                              "The main process's soft RLIMIT_NOFILE (LimitNOFILE): past it, no socket or file opens.",
                              [pt(fds)]))

    resource = {
        "service.name": SERVICE_NAMES.get(unit, "eq-perses"),
        "service.instance.id": "eq-perses",
        "systemd.unit.name": unit,
    }
    return {"resource": {"attributes": attrs(resource)},
            "scopeMetrics": [{"scope": {"name": "eq-unit-limits"}, "metrics": metrics}]}


def main():
    now_ns = str(time.time_ns())
    resources = [r for r in (unit_metrics(u, now_ns) for u in UNITS) if r]
    body = json.dumps({"resourceMetrics": resources}).encode()
    req = urllib.request.Request(ENDPOINT, data=body, headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=10).read()
    except Exception as e:  # the gateway restarting is not this unit's failure
        print(f"post to {ENDPOINT} failed: {e}", file=sys.stderr)
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
