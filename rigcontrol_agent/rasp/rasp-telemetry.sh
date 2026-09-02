sudo tee /usr/local/bin/rigcontrol_telemetry.py > /dev/null <<'EOF'
import os
import subprocess
import datetime
import time
import socket
RIG_NAME = socket.gethostname()
EXCLUDE_FROM_TOTALS = True
def run(cmd: str):
    proc = subprocess.run(
        cmd,
        shell=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
def service_status(service):
    rc, out, _ = run(f"systemctl is-active {service}")
    return out.strip() if rc == 0 else "unknown"
def collect_gpu_stats():
    """Collect GPU statistics - empty for Pi"""
    return []
def has_nvidia_gpu():
    """Check if NVIDIA GPU is present - always false for Pi"""
    return False
def collect_system_uptime():
    try:
        with open("/proc/uptime", "r") as f:
            return int(float(f.read().split()[0]))
    except:
        return 0
def collect_cpu_temp():
    try:
        with open('/sys/class/thermal/thermal_zone0/temp', 'r') as f:
            temp = int(f.read().strip())
            return temp / 1000.0
    except:
        return None
def collect_cpu_usage():
    with open("/proc/stat") as f:
        s1 = f.readline().split()
    idle1 = int(s1[4])
    total1 = sum(map(int, s1[1:]))
    time.sleep(0.1)
    with open("/proc/stat") as f:
        s2 = f.readline().split()
    idle2 = int(s2[4])
    total2 = sum(map(int, s2[1:]))
    if total2 == total1:
        return 0.0
    return round(100 * (1 - (idle2 - idle1) / (total2 - total1)), 1)
def collect_load():
    with open("/proc/loadavg") as f:
        l1, l5, l15, *_ = f.read().split()
    return {"1m": float(l1), "5m": float(l5), "15m": float(l15)}
def collect_memory():
    mem = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, v = line.split(":")
            mem[k] = int(v.strip().split()[0])
    total = mem.get("MemTotal", 0)
    avail = mem.get("MemAvailable", 0)
    used = total - avail if total and avail else 0
    return {
        "total_mb": total // 1024,
        "used_mb": used // 1024,
        "free_mb": avail // 1024,
        "percent": round((used / total * 100), 1) if total else 0.0
    }
_NETWORK_IGNORE_PREFIXES = ("lo", "docker", "veth", "br-", "virbr", "tun", "tap", "wg", "podman")
def _read_network_bytes():
    """Sums RX/TX byte counters from /proc/net/dev across all non-virtual interfaces at this instant
    - same shape and interface-filtering as the main rig telemetry collector."""
    rx_total = 0
    tx_total = 0
    try:
        with open("/proc/net/dev") as f:
            lines = f.readlines()[2:]  # first two lines are headers
        for line in lines:
            if ":" not in line:
                continue
            iface, rest = line.split(":", 1)
            iface = iface.strip()
            if any(iface.startswith(p) for p in _NETWORK_IGNORE_PREFIXES):
                continue
            fields = rest.split()
            if len(fields) < 9:
                continue
            rx_total += int(fields[0])  # bytes column
            tx_total += int(fields[8])  # bytes column
    except Exception:
        pass
    return rx_total, tx_total
def collect_network():
    """rx_bytes/tx_bytes are raw cumulative counters; rx_mbps/tx_mbps are a live throughput figure
    measured over a short window right now (read, sleep briefly, read again) rather than averaged
    across the gap since the previous stored history sample - same approach as the main rig
    telemetry collector, so the Stats page network chart works identically for a Pi controller."""
    rx1, tx1 = _read_network_bytes()
    sample_window_s = 0.5
    time.sleep(sample_window_s)
    rx2, tx2 = _read_network_bytes()
    rx_mbps = max(0.0, (rx2 - rx1) * 8 / (sample_window_s * 1_000_000))
    tx_mbps = max(0.0, (tx2 - tx1) * 8 / (sample_window_s * 1_000_000))
    return {
        "rx_bytes": rx2, "tx_bytes": tx2,
        "rx_mbps": round(rx_mbps, 3), "tx_mbps": round(tx_mbps, 3),
    }
def collect_docker_containers():
    containers = []
    rc, out, err = run(
        'docker ps --filter "status=running" --filter "status=paused" '
        '--format "{{.Names}}|{{.Image}}|{{.ID}}|{{.Status}}"'
    )
    if rc != 0 or not out.strip():
        return containers
    for line in out.strip().splitlines():
        try:
            name, image, cid, status = line.split("|", 3)
            state = "paused" if "Paused" in status else "running"
            rc2, started_raw, _ = run(
                f'docker inspect -f "{{{{.State.StartedAt}}}}" {cid}'
            )
            uptime_seconds = None
            if rc2 == 0 and started_raw.strip():
                ts = started_raw.strip()
                clean = ts.replace("Z", "")
                if "." in clean:
                    base, frac = clean.split(".", 1)
                    frac = (frac + "000000")[:6]
                    clean = f"{base}.{frac}"
                clean += "+00:00"
                try:
                    dt = datetime.datetime.fromisoformat(clean)
                    now = datetime.datetime.now(datetime.timezone.utc)
                    uptime_seconds = int((now - dt).total_seconds())
                except:
                    uptime_seconds = None
            containers.append({
                "name": name,
                "image": image,
                "state": state,
                "uptime_seconds": uptime_seconds
            })
        except:
            continue
    return containers
def collect_service_uptime(service):
    try:
        rc, out, _ = run(f"systemctl is-active {service}")
        state = out.strip().lower()
        if state != "active":
            return {"state": state, "uptime_seconds": 0}
        rc, ts, _ = run(
            f"systemctl show {service} -p ExecMainStartTimestamp --value"
        )
        ts = ts.strip()
        if not ts:
            return {"state": state, "uptime_seconds": 0}
        rc2, start_unix_txt, _ = run(f"date -u -d \"{ts}\" +\"%s\"")
        start_unix = int(start_unix_txt.strip())
        rc3, now_txt, _ = run("date -u +\"%s\"")
        now_unix = int(now_txt.strip())
        return {
            "state": state,
            "uptime_seconds": max(0, now_unix - start_unix)
        }
    except:
        return {"state": "unknown", "uptime_seconds": 0}
def collect_bzminer_stats():
    return {"status": "offline"}
def collect_rigel_stats():
    return {"status": "offline"}
def collect_srbminer_stats():
    return {"status": "offline"}
def collect_wildrig_stats():
    return {"status": "offline"}
def collect_lolminer_stats():
    return {"status": "offline"}
def collect_onezerominer_stats():
    return {"status": "offline"}
def collect_gminer_stats():
    return {"status": "offline"}
def collect_xmrig_stats():
    return {"status": "offline"}
def collect_full_stats():
    gpu_present = has_nvidia_gpu()
    stats = {
        "rig": RIG_NAME,
        "timestamp": int(time.time()),
        "exclude_from_totals": EXCLUDE_FROM_TOTALS,
        "system_uptime_seconds": collect_system_uptime(),
        "cpu_temp": collect_cpu_temp(),
        "cpu_usage": collect_cpu_usage(),
        "load": collect_load(),
        "memory": collect_memory(),
        "network": collect_network(),
        "gpu_present": gpu_present,
        "gpus": collect_gpu_stats() if gpu_present else [],
    }
    stats.update({
        "miner_rigel": collect_rigel_stats(),
        "miner_bzminer": collect_bzminer_stats(),
        "miner_lolminer": collect_lolminer_stats(),
        "miner_srbminer": collect_srbminer_stats(),
        "miner_wildrig": collect_wildrig_stats(),
        "miner_onezerominer": collect_onezerominer_stats(),
        "miner_gminer": collect_gminer_stats(),
        "miner_xmrig": collect_xmrig_stats(),
        "docker": collect_docker_containers(),
        "cpu_service": collect_service_uptime("docker_events_cpu.service"),
        "gpu_service": collect_service_uptime("docker_events_gpu.service"),
    })
    return stats
if __name__ == "__main__":
    import json
    stats = collect_full_stats()
    print(json.dumps(stats, indent=2))
EOF
sudo chmod +x /usr/local/bin/rigcontrol_telemetry.py
sudo systemctl restart rigcontrol-agent 2>/dev/null || true
sudo systemctl is-active rigcontrol-agent 2>/dev/null || echo "Service not found"
