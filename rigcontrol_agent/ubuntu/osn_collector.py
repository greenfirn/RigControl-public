"""OctaSpace node (osn) collector for rigcloud_telemetry.

Scrapes the osn agent's Prometheus endpoint and returns one compact dict
ready to drop into the MQTT payload. Stdlib only.

    from osn_collector import collect_osn
    payload["octaspace"] = collect_osn()
"""

import re
import subprocess
import time
import urllib.request

OSN_URL = "http://127.0.0.1:18888/metrics"
OSN_UNIT = "osn"

_LINE = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(.*)\})?\s+(\S+)')
_LABEL = re.compile(r'(\w+)="((?:[^"\\]|\\.)*)"')
# Label names that identify a GPU / NIC / disk, in order of preference.
_ID_KEYS = ("index", "gpu", "uuid", "bus_id", "pci", "device", "interface", "name")


def _parse(text):
    """Yield (name, labels, value) for every sample line."""
    for line in text.splitlines():
        if not line or line[0] == "#":
            continue
        m = _LINE.match(line)
        if not m:
            continue
        name, raw_labels, raw_val = m.groups()
        labels = {k: v.encode().decode("unicode_escape")
                  for k, v in _LABEL.findall(raw_labels or "")}
        try:
            val = float(raw_val)
        except ValueError:
            continue
        yield name, labels, val


def _num(v):
    return int(v) if v is not None and v == int(v) else v


def _service_active():
    try:
        r = subprocess.run(["systemctl", "is-active", OSN_UNIT],
                           capture_output=True, text=True, timeout=2)
        return r.stdout.strip() == "active"
    except Exception:
        return None


def _group(samples, prefix):
    """osn_gpu_temp{index="0"} -> {"0": {"temp": ...}}"""
    out = {}
    for name, labels, val in samples:
        if not name.startswith(prefix):
            continue
        key = next((labels[k] for k in _ID_KEYS if k in labels), "_")
        field = name[len(prefix):]
        extra = {k: v for k, v in labels.items() if k not in _ID_KEYS}
        if extra:  # e.g. a direction or state label -> suffix it
            field += "_" + "_".join(extra.values())
        out.setdefault(key, {})[field] = _num(val)
    return out


def collect_osn(timeout=2):
    res = {"up": 0, "service_active": _service_active()}
    try:
        text = urllib.request.urlopen(OSN_URL, timeout=timeout).read().decode()
    except Exception as e:
        res["error"] = str(e)
        return res

    samples = list(_parse(text))
    flat = {n: v for n, l, v in samples if not l}
    res["up"] = 1

    info = next((l for n, l, v in samples if n == "osn_info"), {})
    res["version"] = info.get("version")
    res["driver"] = info.get("gpu_driver")
    res["cuda"] = info.get("cuda")

    start = flat.get("osn_start_time_seconds")
    res["uptime_s"] = int(time.time() - start) if start else None

    # These two emit no sample when idle, so absent == 0.
    res["activity"] = _num(flat.get("osn_activity", 0))
    res["link"] = {
        "connected": _num(flat.get("osn_link_connected", 0)),
        "heartbeat_age_s": _num(flat.get("osn_link_heartbeat_age_seconds")),
        "reconnects": _num(flat.get("osn_link_reconnects_total")),
        "rejected": _num(flat.get("osn_link_rejected", 0)),
    }
    res["collect_failed"] = [l.get("part") for n, l, v in samples
                             if n == "osn_collect_failed" and v]

    res["containers_running"] = _num(flat.get("osn_containers_running"))
    res["cpu_load_pct"] = _num(flat.get("osn_cpu_load_percent"))
    res["mem_used"] = _num(flat.get("osn_memory_used_bytes"))
    res["mem_total"] = _num(flat.get("osn_memory_total_bytes"))
    res["disk_free"] = _num(flat.get("osn_docker_disk_free_bytes"))
    res["disk_total"] = _num(flat.get("osn_docker_disk_total_bytes"))

    res["gpus"] = _group(samples, "osn_gpu_")
    res["net"] = _group(samples, "osn_network_")
    return res


if __name__ == "__main__":
    import json
    print(json.dumps(collect_osn(), indent=2))
