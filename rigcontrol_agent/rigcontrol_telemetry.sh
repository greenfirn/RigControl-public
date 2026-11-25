sudo tee /usr/local/bin/rigcontrol_telemetry.py > /dev/null <<'EOF'
import os
import subprocess
import datetime
import urllib.request
import json
import time
import socket
import re
import shlex
import requests
import threading
import shutil
# ===== USER FLAG DESCRIPTION (defaults; most are overridden live from /etc/rigcontrol/rigcontrol-agent.conf) =====
# EXCLUDE_FROM_TOTALS: True: leave this rig out of the dashboard totals
# OVERRIDE_LIST: docker image keywords that are GPU-stats safe (keyword match anywhere in the image name)
# CUSTOM_MINER_BASE_DIR: where custom miners are installed (miner_paths.env lives here)
# CPU_SERVICE_NAME: CPU service name the dashboard controls
# GPU_SERVICE_NAME: GPU service name the dashboard controls
# WATCHDOG_SERVICE_NAME: watchdog service name the dashboard controls
# AUX_SERVICE_NAME: AUX service name the dashboard controls
# GPU_TOOL_PAUSE_SECONDS: pause after a failed GPU tool call
# GPU_TOOL_TIMEOUT_SECONDS: max seconds per GPU tool call; a timeout blocks the tool until restart
# AGENT_CONF_PATH: agent config file, read live
# OSN_URL: OctaSpace osn metrics endpoint (env OSN_METRICS_URL)
# OSN_UNIT: OctaSpace osn service name (env OSN_SERVICE_NAME)
# Conf keys (rigcontrol-agent.conf, read live):
# BROKER_HOST / BROKER_PORT / BROKER_USER / BROKER_PASS: MQTT broker the agent connects to
# MIN_TELEMETRY_PULL_INTERVAL_SECONDS: minimum seconds between telemetry pulls
# MQTT_TLS (default 1): 1 = encrypted broker connection (BROKER_PORT = broker TLS port, 8883), 0 = plain MQTT; MQTT_CA_FILE, MQTT_CLIENT_CERT / MQTT_CLIENT_KEY, MQTT_TLS_INSECURE
# OSN_PRIMARY (default 1): 1 = GPU + CPU/memory from OctaSpace osn only, no local GPU fallback; 0 = ignore osn, collect locally
# OSN_ALLOW_MISSING_GPU_STATS (default 1): with osn, also fetch what it leaves out without nvidia-smi (mem temp, lspci/proc); the start-up read happens regardless
# DOCKER_SKIP_GPU_STATS (default 0): 1 = skip GPU stats while a non-miner docker container is running
# BLOCK_LIST: docker image keywords that ALWAYS skip GPU stats while running (same match, values report 0)
# STATS_DB_ENABLED / STATS_DB_MAX_HISTORY_DAYS / STATS_DB_INTERVAL_SECONDS: local stats history on/off, days kept, seconds between samples
# CUSTOM_MINER_BIN_GPU / _CPU / _AUX: custom miner binary per slot
# <NAME>_BIN / _API_HOST / _API_PORT / _LOG_PATH / _LOG_STYLE: per custom miner, NAME = miner name as A-Z0-9_ (LOG_STYLE=blocks counts "Accepted N blocks")
# Env: OSN_METRICS_URL / OSN_SERVICE_NAME override the osn endpoint and unit
# ===== END USER FLAG DESCRIPTION =====
# ===== USER FLAGS =====
EXCLUDE_FROM_TOTALS = False
OVERRIDE_LIST = []
CUSTOM_MINER_BASE_DIR = "/opt/miners"
CPU_SERVICE_NAME = os.environ.get("CPU_SERVICE_NAME", "docker_events_cpu.service")
GPU_SERVICE_NAME = os.environ.get("GPU_SERVICE_NAME", "docker_events_gpu.service")
WATCHDOG_SERVICE_NAME = os.environ.get("WATCHDOG_SERVICE_NAME", "rigcontrol_watchdog.service")
AUX_SERVICE_NAME = os.environ.get("AUX_SERVICE_NAME", "docker_events_aux.service")
GPU_TOOL_PAUSE_SECONDS = 30
GPU_TOOL_TIMEOUT_SECONDS = 5
AGENT_CONF_PATH = "/etc/rigcontrol/rigcontrol-agent.conf"
OSN_URL = os.environ.get("OSN_METRICS_URL", "http://127.0.0.1:18888/metrics")
OSN_UNIT = os.environ.get("OSN_SERVICE_NAME", "osn")
# ===== END USER FLAGS =====
gpu_present  = False
gpu_type     = "None"
_gpu_detected = False
_last_gpu_count = 0
def _read_miner_paths_env(key):
    """Reads <key>='...' from CUSTOM_MINER_BASE_DIR/miner_paths.env (written by 01-miner_install.sh for"""
    path = f"{CUSTOM_MINER_BASE_DIR}/miner_paths.env"
    try:
        with open(path) as f:
            for line in f:
                m = re.match(rf'^{re.escape(key)}="(.*)"$', line.strip())
                if m:
                    return m.group(1).replace("$BASE_DIR", CUSTOM_MINER_BASE_DIR)
    except Exception:
        pass
    return ""
RIG_NAME = socket.gethostname()
def run(cmd: str):
    proc = subprocess.run(
        cmd,
        shell=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
def extract_pool_host(pool_str: str) -> str:
    """Extract the bare host:port from any pool URL string (strips only the scheme prefix, e.g"""
    if not pool_str:
        return ""
    if "://" in pool_str:
        return pool_str.split("://")[1]
    return pool_str
def normalize_to_hs(value, unit=None):
    """Convert any hash-rate unit to H/s"""
    if value is None:
        return None
    try:
        val = float(value)
        if unit is None:
            if val >= 1e12:
                return val
            elif val >= 1e9:
                return val * 1e9
            elif val >= 1e6:
                return val * 1e6
            elif val >= 1e3:
                return val * 1e3
            return val
        unit = unit.lower().strip()
        multipliers = {
            'h/s': 1, 'hs': 1, 'hash': 1, 'hashes': 1,
            'kh/s': 1e3, 'khs': 1e3, 'kilo': 1e3,
            'mh/s': 1e6, 'mhs': 1e6, 'mega': 1e6,
            'gh/s': 1e9, 'ghs': 1e9, 'giga': 1e9,
            'th/s': 1e12, 'ths': 1e12, 'tera': 1e12,
            'ph/s': 1e15, 'phs': 1e15, 'peta': 1e15,
        }
        return val * multipliers.get(unit, 1)
    except (ValueError, TypeError):
        return None
def service_status(service):
    rc, out, _ = run(f"systemctl is-active {service}")
    return out.strip() if rc == 0 else "unknown"
_gpu_tool_state = {}
def _gpu_tool_allowed(tool):
    """Safety guard shared by every local GPU tool call (nvidia-smi, rocm-smi, gputemps)"""
    st = _gpu_tool_state.get(tool)
    if not st:
        return True
    if st["blocked"]:
        return False
    return time.time() >= st["paused_until"]
def _gpu_tool_record(tool, ok, why="", timed_out=False):
    st = _gpu_tool_state.setdefault(tool, {"fails": 0, "paused_until": 0.0, "blocked": False})
    if ok:
        st["fails"] = 0
        return
    if timed_out:
        st["fails"] += 1
        st["blocked"] = True
        print(f"[Telemetry] GPU tool guard: {tool} call TIMED OUT ({why or 'no detail'}) - driver assumed stuck, BLOCKED until the agent restarts")
        return
    st["fails"] += 1
    if st["fails"] == 1:
        st["paused_until"] = time.time() + GPU_TOOL_PAUSE_SECONDS
        print(f"[Telemetry] GPU tool guard: {tool} call failed ({why or 'no detail'}) - paused for {GPU_TOOL_PAUSE_SECONDS}s")
    else:
        st["blocked"] = True
        print(f"[Telemetry] GPU tool guard: {tool} failed again ({why or 'no detail'}) - BLOCKED until the agent restarts")
def _gpu_failure_placeholders(reason):
    """When a GPU stats source FAILS (tool paused/blocked/failed/timed out, or osn unreachable) report"""
    idxs = sorted(_gpu_static_cache["by_index"]) or list(range(_last_gpu_count or 0))
    out = []
    for i in idxs:
        st = _gpu_static_cache["by_index"].get(i, {})
        out.append({
            "index": i, "name": st.get("name") or f"GPU {i}", "vendor": st.get("vendor") or "NVIDIA",
            "uuid": st.get("uuid"),
            "temp": -1, "mem_temp": -1, "util": -1, "mem_util": -1, "power_watts": -1, "fan_percent": -1,
            "sm_clock": -1, "mem_clock": -1, "vram_used": -1, "vram_total": -1,
            "stats_failed": True, "stats_error": reason,
        })
    return out
def _gpu_passthrough_zeros(reason, pci_list=()):
    """GPU passthrough (GPUs belong to a VM): nothing is read, every known GPU reports 0 in all numeric"""
    idxs = sorted(_gpu_static_cache["by_index"]) or list(range(_last_gpu_count or 0)) or list(range(len(pci_list)))
    out = []
    for i in idxs:
        st = _gpu_static_cache["by_index"].get(i, {})
        out.append({
            "index": i, "name": st.get("name") or f"GPU {i}", "vendor": st.get("vendor") or "NVIDIA",
            "uuid": st.get("uuid"),
            "temp": 0, "mem_temp": 0, "util": 0, "mem_util": 0, "power_watts": 0, "fan_percent": 0,
            "sm_clock": 0, "mem_clock": 0, "vram_used": 0, "vram_total": 0,
            "passthrough": True, "stats_skipped": reason,
        })
    return out
def detect_gpu_once():
    """Detect GPU vendor once; cache result in module globals"""
    global gpu_present, gpu_type, _gpu_detected
    if _gpu_detected:
        return gpu_present, gpu_type
    try:
        if _gpu_tool_allowed("nvidia-smi"):
            rc = subprocess.run(
                ["nvidia-smi", "-L"],
                capture_output=True, text=True, timeout=1.0
            )
            _gpu_tool_record("nvidia-smi", rc.returncode == 0, f"nvidia-smi -L rc={rc.returncode}")
            if rc.returncode == 0 and "GPU" in rc.stdout:
                gpu_present, gpu_type, _gpu_detected = True, "NVIDIA", True
                return gpu_present, gpu_type
    except Exception as e:
        _gpu_tool_record("nvidia-smi", False, f"nvidia-smi -L {type(e).__name__}", timed_out=isinstance(e, subprocess.TimeoutExpired))
    try:
        if _gpu_tool_allowed("rocm-smi"):
            rc = subprocess.run(
                ["rocm-smi", "--showuniqueid"],
                capture_output=True, text=True, timeout=1.0
            )
            _gpu_tool_record("rocm-smi", rc.returncode == 0, f"rocm-smi --showuniqueid rc={rc.returncode}")
            if rc.returncode == 0:
                gpu_present, gpu_type, _gpu_detected = True, "AMD", True
                return gpu_present, gpu_type
    except Exception as e:
        _gpu_tool_record("rocm-smi", False, f"rocm-smi --showuniqueid {type(e).__name__}", timed_out=isinstance(e, subprocess.TimeoutExpired))
    try:
        rc = subprocess.run(
            "lspci | grep -iE 'VGA.*(NVIDIA|AMD|Radeon)'",
            shell=True, capture_output=True, text=True, timeout=1.0
        )
        if rc.returncode == 0 and rc.stdout.strip():
            output = rc.stdout.upper()
            if "NVIDIA" in output:
                gpu_present, gpu_type = True, "NVIDIA_NO_DRIVER"
            elif "AMD" in output or "RADEON" in output:
                gpu_present, gpu_type = True, "AMD_NO_DRIVER"
    except Exception:
        pass
    _gpu_detected = True
    return gpu_present, gpu_type
def collect_gpu_stats(skip=False):
    """Top-level dispatcher; returns list of GPU dicts"""
    global gpu_present, gpu_type, _last_gpu_count
    if skip:
        return []
    detect_gpu_once()
    if not gpu_present:
        _last_gpu_count = 0
        return []
    tool = "nvidia-smi" if gpu_type == "NVIDIA" else ("rocm-smi" if gpu_type == "AMD" else "")
    if tool and not _gpu_tool_allowed(tool):
        return _gpu_failure_placeholders(f"{tool} paused/blocked by the GPU tool guard")
    if gpu_type == "NVIDIA":
        try:
            gpus = collect_nvidia_gpu_stats()
        except Exception as e:
            _gpu_tool_record(tool, False, f"{type(e).__name__}: {e}", timed_out=isinstance(e, subprocess.TimeoutExpired))
            return _gpu_failure_placeholders(f"{tool} {type(e).__name__}")
    elif gpu_type == "AMD":
        try:
            gpus = collect_amd_gpu_stats()
        except Exception as e:
            _gpu_tool_record(tool, False, f"{type(e).__name__}: {e}", timed_out=isinstance(e, subprocess.TimeoutExpired))
            return _gpu_failure_placeholders(f"{tool} {type(e).__name__}")
    else:
        gpus = collect_basic_gpu_info()
    if tool:
        _gpu_tool_record(tool, bool(gpus), "no GPU data returned")
        if not gpus:
            return _gpu_failure_placeholders(f"{tool} returned no GPU data")
    _last_gpu_count = len(gpus)
    return gpus
def collect_basic_gpu_info():
    """Minimal GPU record from lspci when no driver is installed"""
    try:
        rc = subprocess.run(
            "lspci | grep -i 'VGA\\|3D' | head -1",
            shell=True, capture_output=True, text=True, timeout=2.0
        )
        if rc.returncode != 0 or not rc.stdout.strip():
            return []
        line = rc.stdout.strip()
        vendor = "Unknown"
        if "nvidia" in line.lower():
            vendor = "NVIDIA"
        elif "amd" in line.lower() or "radeon" in line.lower():
            vendor = "AMD"
        elif "intel" in line.lower():
            vendor = "Intel"
        pci_match = re.match(r'^(\S+)', line)
        pci_id    = pci_match.group(1) if pci_match else "unknown"
        pci_bus   = f"0000:{pci_id}" if ":" in pci_id else f"0000:00:{pci_id}"
        gpu_name = re.sub(r'^.*VGA compatible controller:\s*', '', line)
        gpu_name = re.sub(r'^.*3D controller:\s*', '', gpu_name)
        return [{
            "index": 0, "uuid": f"{vendor.upper()}-{pci_id}",
            "name": gpu_name.strip() or f"{vendor} Graphics",
            "board_partner": "", "vendor": vendor, "architecture": "Unknown",
            "temp": 0, "mem_temp": 0, "util": 0, "mem_util": 0,
            "power_watts": 0.0, "fan_percent": 0,
            "sm_clock": 0, "mem_clock": 0,
            "vram_used": 0, "vram_total": 0,
            "driver_version": "none", "vbios_version": "none",
            "power_limit_min": None, "power_limit_default": None, "power_limit_max": None,
            "pci_bus_id": pci_bus, "pci_slot": pci_id,
        }]
    except Exception:
        return []
def _parse_float_or_none(raw):
    """nvidia-smi prints '[Not Supported]' for some fields on some GPUs/drivers; treat that as unknown"""
    try:
        return float(raw)
    except ValueError:
        return None
def _gpu_architecture_from_name(name):
    """Best-effort NVIDIA architecture guess from the GPU name string"""
    n = name.upper()
    if re.search(r"RTX\s?50\d{2}", n):
        return "Blackwell"
    if re.search(r"RTX\s?40\d{2}", n):
        return "Ada Lovelace"
    if re.search(r"RTX\s?30\d{2}", n) or re.search(r"\bA[2456]000\b", n) or "A100" in n:
        return "Ampere"
    if re.search(r"RTX\s?20\d{2}", n) or re.search(r"GTX\s?16\d{2}", n):
        return "Turing"
    if re.search(r"GTX\s?10\d{2}", n) or "TITAN X" in n or "TITAN XP" in n:
        return "Pascal"
    if re.search(r"GTX\s?9\d{2}", n):
        return "Maxwell"
    if re.search(r"GTX\s?7\d{2}", n) or re.search(r"GTX\s?6\d{2}", n):
        return "Kepler"
    if "TITAN V" in n or "V100" in n:
        return "Volta"
    if "H100" in n or "H200" in n:
        return "Hopper"
    return "Unknown"
_GPUTEMPS_BIN = None
_GPUTEMPS_CHECKED = False
def _find_gputemps_binary():
    """Locates the optional 'gputemps' binary (github.com/ThomasBaruzier/gddr6-core-junction-vram-temps)"""
    global _GPUTEMPS_BIN, _GPUTEMPS_CHECKED
    if _GPUTEMPS_CHECKED:
        return _GPUTEMPS_BIN
    _GPUTEMPS_CHECKED = True
    _GPUTEMPS_BIN = None
    for path in (shutil.which("gputemps"), "/usr/local/bin/gputemps", "/usr/local/sbin/gputemps"):
        if path and os.path.isfile(path) and os.access(path, os.X_OK):
            _GPUTEMPS_BIN = path
            break
    return _GPUTEMPS_BIN
def _collect_gputemps_vram(indexes):
    """Batch-reads VRAM temps for the given NVML device indexes via gputemps --json"""
    binpath = _find_gputemps_binary()
    if not binpath or not indexes or not _gpu_tool_allowed("gputemps"):
        return {}
    try:
        proc = subprocess.run(
            [binpath, "--once", "--json", "--device", ",".join(str(i) for i in indexes)],
            capture_output=True, text=True, timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        _gpu_tool_record("gputemps", False, type(e).__name__, timed_out=isinstance(e, subprocess.TimeoutExpired))
        return {}
    _gpu_tool_record("gputemps", proc.returncode == 0, f"gputemps rc={proc.returncode}")
    if proc.returncode != 0:
        return {}
    results = {}
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            data = json.loads(line)
        except ValueError:
            continue
        for gpu in data.get("gpus", []):
            vram = gpu.get("vram")
            if isinstance(vram, (int, float)):
                results[gpu.get("index")] = vram
    return results
def collect_nvidia_gpu_stats():
    """Collect NVIDIA GPU stats via a single nvidia-smi call"""
    cmd = (
        "nvidia-smi --query-gpu=index,uuid,temperature.gpu,temperature.memory,"
        "utilization.gpu,utilization.memory,power.draw,"
        "clocks.sm,clocks.mem,fan.speed,"
        "memory.total,memory.used,driver_version,"
        "name,pci.bus_id,vbios_version,"
        "power.min_limit,power.default_limit,power.max_limit,power.limit"
        " --format=csv,noheader,nounits"
    )
    rc = subprocess.run(shlex.split(cmd), capture_output=True, text=True, timeout=GPU_TOOL_TIMEOUT_SECONDS)
    if rc.returncode != 0:
        return []
    gpus = []
    for line in rc.stdout.strip().split("\n"):
        fields = [x.strip() for x in line.split(",")]
        if len(fields) < 14:
            continue
        try:
            (idx, uuid, temp, memtemp, util, memutil, watts,
             smclk, memclk, fan, memtotal, memused,
             driver_version, name) = fields[:14]
            pci_bus = fields[14] if len(fields) > 14 else ""
            vbios_version = fields[15] if len(fields) > 15 else ""
            pwr_min_raw = fields[16] if len(fields) > 16 else ""
            pwr_default_raw = fields[17] if len(fields) > 17 else ""
            pwr_max_raw = fields[18] if len(fields) > 18 else ""
            pwr_cur_raw = fields[19] if len(fields) > 19 else ""
            try:
                mem_temp_val = int(memtemp)
            except ValueError:
                mem_temp_val = None
            power_limit_min = _parse_float_or_none(pwr_min_raw)
            power_limit_default = _parse_float_or_none(pwr_default_raw)
            power_limit_max = _parse_float_or_none(pwr_max_raw)
            board_partner = ""
            pci_slot = ""
            if pci_bus:
                pci_slot = ":".join(pci_bus.split(":")[-2:]).lower()
                try:
                    rc2 = subprocess.run(
                        f"lspci -nnv -s {pci_slot}",
                        shell=True, capture_output=True, text=True, timeout=1.0
                    )
                    if rc2.returncode == 0:
                        subsystem_line = ""
                        for line in rc2.stdout.splitlines():
                            if "subsystem:" in line.lower():
                                subsystem_line = line.lower()
                                break
                        subsys_id_match = re.search(r"\[([0-9a-f]{4}):([0-9a-f]{4})\]", subsystem_line)
                        if subsys_id_match:
                            board_partner = {
                                "1043": "ASUS", "3842": "EVGA", "1462": "MSI",
                                "1458": "Gigabyte", "19da": "Zotac", "196e": "PNY",
                                "10b0": "Palit", "19f1": "Gainward", "1b4c": "Galax",
                                "196d": "Colorful", "1c5c": "Inno3D",
                                "10de": "NVIDIA Founders Edition",
                            }.get(subsys_id_match.group(1), "")
                        if not board_partner and subsystem_line:
                            for pattern, partner in [
                                ("asus", "ASUS"), ("evga", "EVGA"), ("msi", "MSI"),
                                ("gigabyte", "Gigabyte"), ("zotac", "Zotac"),
                                ("pny", "PNY"), ("galax", "Galax"),
                                ("colorful", "Colorful"), ("inno3d", "Inno3D"),
                                ("palit", "Palit"), ("gainward", "Gainward"),
                            ]:
                                if pattern in subsystem_line:
                                    board_partner = partner
                                    break
                except Exception:
                    pass
            if not board_partner:
                for pattern, partner in [
                    ("asus", "ASUS"), ("rog ", "ASUS ROG"), ("strix", "ASUS ROG Strix"),
                    ("tuf", "ASUS TUF"), ("evga", "EVGA"), ("ftw", "EVGA FTW"),
                    ("xc3", "EVGA XC3"), ("msi", "MSI"), ("gaming x", "MSI Gaming X"),
                    ("ventus", "MSI Ventus"), ("gigabyte", "Gigabyte"),
                    ("aorus", "Gigabyte AORUS"), ("eagle", "Gigabyte Eagle"),
                    ("zotac", "Zotac"), ("amp", "Zotac AMP"),
                    ("trinity", "Zotac Trinity"), ("founder", "NVIDIA Founders Edition"),
                    ("fe ", "NVIDIA Founders Edition"),
                ]:
                    if pattern in name.lower():
                        board_partner = partner
                        break
            gpus.append({
                "index": int(idx), "uuid": uuid,
                "name": name, "board_partner": board_partner,
                "vendor": "NVIDIA", "architecture": _gpu_architecture_from_name(name),
                "temp": int(temp), "mem_temp": mem_temp_val, "util": int(util),
                "mem_util": int(memutil), "power_watts": float(watts),
                "fan_percent": int(fan),
                "sm_clock": int(smclk), "mem_clock": int(memclk),
                "vram_used": int(memused), "vram_total": int(memtotal),
                "driver_version": driver_version, "vbios_version": vbios_version,
                "power_limit_min": power_limit_min,
                "power_limit_default": power_limit_default,
                "power_limit_max": power_limit_max,
                "power_limit": _parse_float_or_none(pwr_cur_raw),
                "pci_bus_id": pci_bus, "pci_slot": pci_slot,
            })
        except (ValueError, IndexError):
            continue
    missing_mem_temp = [g["index"] for g in gpus if g.get("mem_temp") is None]
    if missing_mem_temp:
        vram_fallback = _collect_gputemps_vram(missing_mem_temp)
        for g in gpus:
            if g["index"] in vram_fallback:
                g["mem_temp"] = vram_fallback[g["index"]]
    return gpus
def collect_amd_gpu_stats():
    """Collects AMD GPU stats via a single 'rocm-smi --json' call, falling back to the text-parsing path"""
    try:
        rc = subprocess.run(
            ["rocm-smi", "--json"],
            capture_output=True, text=True, timeout=3.0
        )
        if rc.returncode != 0 or not rc.stdout.strip():
            raise RuntimeError("rocm-smi --json failed")
        data = json.loads(rc.stdout)
        gpus = []
        for card_key, card in data.items():
            if not card_key.startswith("card"):
                continue
            idx_str = card_key.replace("card", "")
            idx = int(idx_str) if idx_str.isdigit() else 0
            def fval(key, default=0.0):
                v = card.get(key, default)
                try:
                    return float(str(v).replace("°C", "").replace("W", "")
                                       .replace("MHz", "").replace("Mhz", "")
                                       .replace("%", "").strip())
                except (ValueError, TypeError):
                    return default
            temp         = fval("Temperature (Sensor edge) (C)")
            power        = fval("Current Socket Graphics Package Power (W)")
            gpu_util     = fval("GPU use (%)")
            vram_util    = fval("GPU memory use (%)")
            fan          = fval("Fan speed (%)")
            core_clock   = fval("Current Clock Speed (MHz)")
            mem_clock    = fval("Current Memory Clock Speed (MHz)")
            vram_total   = fval("VRAM Total Memory (B)", 0)
            vram_used    = fval("VRAM Total Used Memory (B)", 0)
            driver_ver   = str(card.get("Driver version", "")).strip()
            gpu_name     = str(card.get("Card series",
                            card.get("Card model", "AMD GPU"))).strip()
            pci_bus      = str(card.get("PCI Bus", "")).strip()
            if vram_total > 1024 * 1024:
                vram_total = int(vram_total / (1024 * 1024))
                vram_used  = int(vram_used  / (1024 * 1024))
            else:
                vram_total = int(vram_total)
                vram_used  = int(vram_used)
            board_partner = determine_amd_board_partner(pci_bus, gpu_name)
            gpus.append({
                "index": idx,
                "uuid": f"AMD-{pci_bus}" if pci_bus else f"AMD-GPU-{idx}",
                "name": gpu_name[:50],
                "board_partner": board_partner,
                "vendor": "AMD",
                "temp": int(temp),
                "util": int(gpu_util),
                "mem_util": int(vram_util),
                "power_watts": power,
                "fan_percent": int(fan),
                "sm_clock": int(core_clock),
                "mem_clock": int(mem_clock),
                "vram_used": vram_used,
                "vram_total": vram_total,
                "driver_version": driver_ver,
                "pci_bus_id": pci_bus,
                "pci_slot": pci_bus,
            })
        return gpus
    except Exception:
        return _collect_amd_gpu_stats_text_fallback()
def _collect_amd_gpu_stats_text_fallback():
    """Text-format fallback for ROCm versions without --json support, using a single 'rocm-smi' call"""
    try:
        rc = subprocess.run(
            ["rocm-smi"], capture_output=True, text=True, timeout=3.0
        )
        if rc.returncode != 0 or not rc.stdout.strip():
            return []
        lines = rc.stdout.strip().split('\n')
        data_line = None
        name_line = ""
        for i, line in enumerate(lines):
            stripped = line.strip()
            if re.match(r'^\d+\s+\[', stripped):
                data_line = stripped
                if i + 1 < len(lines):
                    nxt = lines[i + 1].strip()
                    if nxt and not nxt.startswith('='):
                        name_line = nxt
                break
        if not data_line:
            return []
        parts = re.split(r'\s{2,}', data_line)
        temp = power = core_clock = mem_clock = fan = vram_percent = gpu_percent = 0.0
        for part in parts:
            if '°C' in part:
                temp = float(part.replace('°C', ''))
            elif 'W' in part and 'Mhz' not in part and 'PwrCap' not in part:
                if power == 0:
                    power = float(part.replace('W', ''))
            elif 'Mhz' in part:
                if core_clock == 0:
                    core_clock = float(part.replace('Mhz', ''))
                else:
                    mem_clock = float(part.replace('Mhz', ''))
            elif '%' in part:
                if fan == 0:
                    fan = float(part.replace('%', ''))
                elif vram_percent == 0:
                    vram_percent = float(part.replace('%', ''))
                elif gpu_percent == 0:
                    gpu_percent = float(part.replace('%', ''))
        gpu_name = name_line.strip() if name_line else "AMD GPU"
        vram_total = _amd_vram_mb_from_name(gpu_name)
        vram_used  = int(vram_total * (vram_percent / 100))
        pci_id = _get_amd_pci_id_via_lspci()
        board_partner = determine_amd_board_partner(pci_id, gpu_name)
        driver_ver = _read_amdgpu_driver_version()
        return [{
            "index": 0,
            "uuid": f"AMD-{pci_id}" if pci_id else "AMD-GPU-0",
            "name": gpu_name[:50],
            "board_partner": board_partner,
            "vendor": "AMD",
            "temp": int(temp),
            "util": int(gpu_percent),
            "mem_util": int(vram_percent),
            "power_watts": power,
            "fan_percent": int(fan),
            "sm_clock": int(core_clock),
            "mem_clock": int(mem_clock),
            "vram_used": vram_used,
            "vram_total": vram_total,
            "driver_version": driver_ver,
            "pci_bus_id": f"0000:{pci_id}" if pci_id else "",
            "pci_slot": pci_id,
        }]
    except Exception:
        return []
def _amd_vram_mb_from_name(name: str) -> int:
    """Return VRAM in MB for common AMD RDNA cards; default 8 GB"""
    n = name.upper()
    for model, mb in [
        ("6950 XT", 16384), ("6900 XT", 16384), ("6900", 16384),
        ("6800 XT", 16384), ("6800", 16384),
        ("6750 XT", 12288), ("6700 XT", 12288), ("6700", 12288),
        ("6650 XT", 8192),  ("6600 XT", 8192),  ("6600", 8192),
        ("7900 XTX", 24576),("7900 XT", 20480), ("7900", 20480),
        ("7800 XT", 16384), ("7700 XT", 12288), ("7600 XT", 16384),
        ("7600", 8192),
    ]:
        if model in n:
            return mb
    return 8192
def _get_amd_pci_id_via_lspci() -> str:
    """Single lspci call to find AMD GPU PCI slot"""
    try:
        rc = subprocess.run(
            "lspci | grep -iE 'VGA.*AMD|VGA.*Radeon|3D.*AMD' | head -1",
            shell=True, capture_output=True, text=True, timeout=1.0
        )
        if rc.returncode == 0 and rc.stdout.strip():
            m = re.match(r'^([0-9a-f:\.]+)', rc.stdout.strip())
            if m:
                return m.group(1)
    except Exception:
        pass
    return ""
def _read_amdgpu_driver_version() -> str:
    """Read amdgpu driver version from sysfs — no subprocess needed"""
    try:
        with open("/sys/module/amdgpu/version") as f:
            return f.read().strip()
    except Exception:
        pass
    return "unknown"
def get_amd_driver_version() -> str:
    """Public wrapper around _read_amdgpu_driver_version()"""
    return _read_amdgpu_driver_version()
def determine_amd_board_partner(pci_id: str, gpu_name: str) -> str:
    """Identify AIB partner from lspci subsystem info, then GPU name"""
    board_partner = ""
    if pci_id:
        try:
            rc = subprocess.run(
                f"lspci -v -s {pci_id}",
                shell=True, capture_output=True, text=True, timeout=1.0
            )
            if rc.returncode == 0:
                subsystem_line = ""
                for line in rc.stdout.splitlines():
                    if "subsystem:" in line.lower():
                        subsystem_line = line.lower()
                        break
                for pattern, name in [
                    ("asus", "ASUS"), ("msi", "MSI"),
                    ("gigabyte", "Gigabyte"), ("sapphire", "Sapphire"),
                    ("xfx", "XFX"), ("powercolor", "PowerColor"),
                    ("his", "HIS"), ("visiontek", "VisionTek"),
                    ("club 3d", "Club 3D"), ("biostar", "Biostar"),
                    ("asrock", "ASRock"),
                ]:
                    if pattern in subsystem_line:
                        board_partner = name
                        break
                if not board_partner and "advanced micro devices" in subsystem_line:
                    board_partner = "AMD (Reference)"
        except Exception:
            pass
    if not board_partner:
        for pattern, name in [
            ("asus", "ASUS"), ("rog ", "ASUS ROG"), ("strix", "ASUS ROG Strix"),
            ("tuf", "ASUS TUF"), ("msi", "MSI"), ("gaming x", "MSI Gaming X"),
            ("mech", "MSI Mech"), ("gigabyte", "Gigabyte"),
            ("aorus", "Gigabyte AORUS"), ("eagle", "Gigabyte Eagle"),
            ("sapphire", "Sapphire"), ("nitro+", "Sapphire Nitro+"),
            ("pulse", "Sapphire Pulse"), ("xfx", "XFX"),
            ("merc", "XFX MERC"), ("swft", "XFX SWFT"),
            ("powercolor", "PowerColor"), ("red devil", "PowerColor Red Devil"),
            ("red dragon", "PowerColor Red Dragon"),
            ("asrock", "ASRock"), ("phantom gaming", "ASRock Phantom Gaming"),
            ("taichi", "ASRock Taichi"),
        ]:
            if pattern in gpu_name.lower():
                board_partner = name
                break
    return board_partner
def collect_cpu_temp():
    """Single-pass hwmon scan checking AMD k10temp first, then Intel coretemp/pch"""
    hwmon_base = "/sys/class/hwmon"
    try:
        for hw in os.listdir(hwmon_base):
            name_path = os.path.join(hwmon_base, hw, "name")
            if not os.path.isfile(name_path):
                continue
            with open(name_path) as f:
                sensor_name = f.read().strip().lower()
            if sensor_name == "k10temp":
                temp_path = os.path.join(hwmon_base, hw, "temp1_input")
                if os.path.isfile(temp_path):
                    with open(temp_path) as t:
                        return int(t.read().strip()) / 1000.0
            if "coretemp" in sensor_name or "pch" in sensor_name:
                for fname in os.listdir(os.path.join(hwmon_base, hw)):
                    if fname.startswith("temp") and fname.endswith("_input"):
                        try:
                            with open(os.path.join(hwmon_base, hw, fname)) as t:
                                return int(t.read().strip()) / 1000.0
                        except Exception:
                            continue
    except Exception:
        pass
    return None
def collect_cpu_usage():
    with open("/proc/stat") as f:
        s1 = f.readline().split()
    idle1  = int(s1[4])
    total1 = sum(map(int, s1[1:]))
    time.sleep(0.1)
    with open("/proc/stat") as f:
        s2 = f.readline().split()
    idle2  = int(s2[4])
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
    used  = total - avail if total and avail else 0
    return {
        "total_mb": total // 1024,
        "used_mb":  used  // 1024,
        "free_mb":  avail // 1024,
        "percent":  round((used / total * 100), 1) if total else 0.0,
    }
def collect_system_uptime():
    """Reads uptime from /proc/uptime"""
    with open("/proc/uptime") as f:
        return float(f.read().split()[0])
_NETWORK_IGNORE_PREFIXES = ("lo", "docker", "veth", "br-", "virbr", "tun", "tap", "wg", "podman")
def _read_network_bytes():
    """Sums RX/TX byte counters from /proc/net/dev across all non-virtual interfaces at this instant"""
    rx_total = 0
    tx_total = 0
    try:
        with open("/proc/net/dev") as f:
            lines = f.readlines()[2:]
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
            rx_total += int(fields[0])
            tx_total += int(fields[8])
    except Exception:
        pass
    return rx_total, tx_total
def collect_network():
    """rx_bytes/tx_bytes are the raw cumulative counters (reset on reboot/link reset) - used for the Stats"""
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
    rc, out, _ = run(
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
                ts    = started_raw.strip().replace("Z", "")
                base, frac = (ts.split(".", 1) + [""])[:2]
                frac  = (frac + "000000")[:6]
                clean = f"{base}.{frac}+00:00"
                try:
                    dt = datetime.datetime.fromisoformat(clean)
                    uptime_seconds = int(
                        (datetime.datetime.now(datetime.timezone.utc) - dt).total_seconds()
                    )
                except Exception:
                    pass
            containers.append({
                "name": name, "image": image,
                "state": state, "uptime_seconds": uptime_seconds,
            })
        except Exception:
            continue
    podman_exists = any(c["name"] == "podman" for c in containers)
    if podman_exists:
        rc3, podman_out, _ = run(
            'docker exec podman podman ps '
            '--format "{{.Names}}|{{.Image}}|{{.ID}}|{{.Status}}" 2>/dev/null || echo ""'
        )
        if rc3 == 0 and podman_out.strip():
            for line in podman_out.strip().splitlines():
                try:
                    name, image, cid, status = line.split("|", 3)
                    state = "paused" if "Paused" in status else "running"
                    rc4, started_raw, _ = run(
                        f'docker exec podman podman inspect -f '
                        f'"{{{{.State.StartedAt}}}}" {cid} 2>/dev/null || echo ""'
                    )
                    uptime_seconds = None
                    if rc4 == 0 and started_raw.strip():
                        ts    = started_raw.strip().replace("Z", "")
                        base, frac = (ts.split(".", 1) + [""])[:2]
                        frac  = (frac + "000000")[:6]
                        clean = f"{base}.{frac}+00:00"
                        try:
                            dt = datetime.datetime.fromisoformat(clean)
                            uptime_seconds = int(
                                (datetime.datetime.now(datetime.timezone.utc) - dt).total_seconds()
                            )
                        except Exception:
                            pass
                    containers.append({
                        "name": f"podman-{name}", "image": image,
                        "state": state, "uptime_seconds": uptime_seconds,
                    })
                except Exception:
                    continue
    return containers
def collect_service_uptime(service):
    """Checks systemd unit `service` and echoes that same name back as 'service' in the returned dict so"""
    try:
        rc, out, _ = run(f"systemctl is-active {service}")
        state = out.strip().lower()
        if state != "active":
            return {"state": state, "uptime_seconds": 0, "service": service}
        rc, ts, _ = run(
            f"systemctl show {service} -p ExecMainStartTimestamp --value"
        )
        ts = ts.strip()
        if not ts:
            return {"state": state, "uptime_seconds": 0, "service": service}
        rc2, start_txt, _ = run(f'date -u -d "{ts}" +"%s"')
        rc3, now_txt,   _ = run('date -u +"%s"')
        return {
            "state": state,
            "uptime_seconds": max(0, int(now_txt) - int(start_txt)),
            "service": service,
        }
    except Exception:
        return {"state": "unknown", "uptime_seconds": 0, "service": service}
_BUILTIN_MINER_PROCESS_MAP = {
    "xmrig":        "xmrig",
    "lolminer":     "lolminer",
    "bzminer":      "bzminer",
    "rigel":        "rigel",
    "srbminer":     "srbminer",
    "SRBMiner":     "srbminer",
    "gminer":       "gminer",
    "onezerominer": "onezerominer",
    "wildrig":      "wildrig",
    "wildrig-ng":   "wildrig",
    "teamredminer": "teamredminer",
    "t-rex":        "trex",
    "peakminer":    "peakminer",
}
_custom_miner_lock = threading.Lock()
_CUSTOM_MINER_PROCESS_NAMES = {"cpu": "", "gpu": "", "aux": ""}
def set_custom_miner_process_name(slot, name):
    """Sets/replaces the currently-registered custom-miner process name for one slot ('cpu'/'gpu'/'aux')"""
    global _CUSTOM_MINER_PROCESS_NAMES
    with _custom_miner_lock:
        _CUSTOM_MINER_PROCESS_NAMES[slot] = (name or "").strip().lower()
_MINER_DOCKER_MAP = {
    "xmrig":        "xmrig",
    "lolminer":     "lolminer",
    "bzminer":      "bzminer",
    "rigel":        "rigel",
    "srbminer":     "srbminer",
    "srbminer-multi":"srbminer",
    "gminer":       "gminer",
    "onezerominer": "onezerominer",
    "wildrig":      "wildrig",
    "wildrig-ng":   "wildrig",
    "teamredminer": "teamredminer",
    "team-red-miner":"teamredminer",
    "t-rex":        "trex",
    "trex":         "trex",
    "peakminer":    "peakminer",
}
def _docker_published_miners():
    """Returns {miner_name: True} for running Docker containers matching a known miner image that publish"""
    found = {}
    try:
        result = subprocess.run(
            'docker ps --format "{{.Image}}|{{.Names}}|{{.Ports}}"',
            shell=True, capture_output=True, text=True, timeout=3
        )
        if result.returncode == 0 and result.stdout.strip():
            for line in result.stdout.strip().split('\n'):
                parts = line.split('|', 2)
                if len(parts) < 3:
                    continue
                image, name, ports = parts
                if not ports.strip() or '->' not in ports:
                    continue
                line_lower = (image + '|' + name).lower()
                for image_pattern, miner_name in _MINER_DOCKER_MAP.items():
                    if image_pattern in line_lower:
                        found[miner_name] = True
                        break
    except Exception as e:
        print(f"Error detecting Docker miner containers: {e}")
    return found
def _docker_known_miner_running():
    """True if any running Docker container's image/name matches a known miner name in _MINER_DOCKER_MAP -"""
    try:
        result = subprocess.run(
            'docker ps --format "{{.Image}}|{{.Names}}"',
            shell=True, capture_output=True, text=True, timeout=3
        )
        if result.returncode == 0 and result.stdout.strip():
            for line in result.stdout.strip().split('\n'):
                line_lower = line.lower()
                for image_pattern in _MINER_DOCKER_MAP:
                    if image_pattern in line_lower:
                        return True
    except Exception as e:
        print(f"Error detecting Docker miner containers: {e}")
    return False
_DEFAULT_IGNORED_DOCKER_IMAGES = (
    "cloreai/monitoring",
    "vastai/test:bandwidth-test-nvidia",
    "vastai/test:speedtest",
    "vastai/test:common",
)
def _is_ignored_docker_image(image):
    """True if `image` is a 'gpu stats safe' sidecar - a platform rental/monitoring container (the"""
    image_lower = (image or "").strip().lower()
    if not image_lower:
        return False
    for prefix in _DEFAULT_IGNORED_DOCKER_IMAGES:
        if image_lower.startswith(prefix.lower()):
            return True
    for prefix in OVERRIDE_LIST:
        if prefix and prefix.strip().lower() in image_lower:
            return True
    return False
def docker_containers_running():
    """True if any Docker container is currently running whose image isn't a known 'gpu stats safe'"""
    rc, out, _ = run('docker ps --format "{{.Image}}"')
    if rc != 0 or not out.strip():
        return False
    for image in out.strip().splitlines():
        if not _is_ignored_docker_image(image):
            return True
    return False
_last_detected_miners_set = frozenset()
_miners_set_changed_flag = False
_custom_miner_last_pid = {}
_miner_pid_changed_this_poll = set()
_RIG_CONF_SLOT_PATHS = (
    ("cpu", "/etc/rigcontrol/rig-cpu.conf"),
    ("gpu", "/etc/rigcontrol/rig-gpu.conf"),
    ("aux", "/etc/rigcontrol/rig-aux.conf"),
)
def _read_conf_key(path, *keys, gpu_id="0"):
    """Reads a KEY GPU_ID 'value' row from rig-gpu.conf/rig-cpu.conf's 3-column format (or a 2-column KEY"""
    if not os.path.isfile(path):
        return ""
    def _strip_quotes(v):
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
            v = v[1:-1]
        return v
    try:
        rows = {}
        with open(path, "r") as f:
            for line in f:
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                parts = line.split(None, 2)
                if len(parts) < 2:
                    continue
                file_key = parts[0]
                if len(parts) == 2:
                    rows.setdefault(file_key, {})["ALL"] = _strip_quotes(parts[1])
                else:
                    file_gpu = parts[1]
                    value = _strip_quotes(parts[2])
                    rows.setdefault(file_key, {})[file_gpu] = value
        for key in keys:
            entry = rows.get(key, {})
            val = entry.get(gpu_id)
            if not val:
                val = entry.get("ALL")
            if val:
                return val
    except Exception as e:
        print(f"Error reading {path}: {e}")
    return ""
def _read_conf_key_json(path, *keys):
    """JSON counterpart to _read_conf_key() - see that function's docstring for why this is duplicated"""
    if not os.path.isfile(path):
        return ""
    try:
        with open(path, "r") as f:
            data = json.load(f)
        items = data.get("items") or []
        if not items:
            return ""
        it = items[0]
        miner = (it.get("miner") or "").strip()
        miner_alt = (it.get("miner_alt") or "").strip()
        mc = it.get("miner_config") or {}
        mc_miner = (mc.get("miner") or "").strip()
        is_custom = miner.lower() == "custom"
        resolved = {
            "CUSTOM_MINER": (miner_alt or mc_miner) if is_custom else "",
            "MINER": "" if is_custom else (miner_alt or miner),
        }
        for key in keys:
            val = resolved.get(key, "")
            if val:
                return val
    except Exception as e:
        print(f"Error reading {path}: {e}")
    return ""
_rig_slot_conf_cache = {"cpu": {"mtime": None, "name": ""}, "gpu": {"mtime": None, "name": ""}, "aux": {"mtime": None, "name": ""}}
def _resolve_custom_name_for_slot(slot, conf_path):
    """Returns the flightsheet-configured custom-miner process name for one slot ('cpu'/'gpu'/'aux'), or"""
    override_bin = _read_agent_conf_val(f"CUSTOM_MINER_BIN_{slot.upper()}").strip()
    if override_bin:
        return os.path.basename(override_bin.rstrip("/"))
    json_path = conf_path[:-len(".conf")] + ".json"
    try:
        mtime = max(
            os.path.getmtime(json_path) if os.path.isfile(json_path) else 0,
            os.path.getmtime(conf_path) if os.path.isfile(conf_path) else 0,
        )
    except OSError:
        mtime = 0
    cache = _rig_slot_conf_cache[slot]
    if mtime and cache["mtime"] == mtime:
        return cache["name"]
    resolved = _read_conf_key_json(json_path, "CUSTOM_MINER", "MINER") or _read_conf_key(conf_path, "CUSTOM_MINER", "MINER")
    resolved_lower = resolved.strip().lower()
    if resolved_lower in _BUILTIN_MINER_PROCESS_MAP or resolved_lower in set(_BUILTIN_MINER_PROCESS_MAP.values()):
        resolved = ""
    cache["mtime"] = mtime
    cache["name"] = resolved
    return resolved
def consume_miners_changed_flag():
    """Returns True if detect_running_miners() has observed the running-miner set change since this was"""
    global _miners_set_changed_flag
    changed = _miners_set_changed_flag
    _miners_set_changed_flag = False
    return changed
def detect_running_miners():
    """Returns a deduplicated list of currently-running miner identifiers, checking native processes via"""
    global _last_detected_miners_set, _miners_set_changed_flag
    found = {}
    _miner_pid_changed_this_poll.clear()
    try:
        custom_names = {}
        for _slot, _path in _RIG_CONF_SLOT_PATHS:
            _cname = _resolve_custom_name_for_slot(_slot, _path)
            custom_names[_slot] = _cname
            with _custom_miner_lock:
                if _CUSTOM_MINER_PROCESS_NAMES.get(_slot) != _cname:
                    _CUSTOM_MINER_PROCESS_NAMES[_slot] = _cname
        name_pattern = re.compile("(xmrig|lolminer|bzminer|rigel|srbminer|"
                                   "gminer|onezerominer|wildrig|teamredminer|t-rex|keryx-miner|keryxd|peakminer"
                                   + "".join(f"|{re.escape(_cname)}" for _cname in custom_names.values() if _cname)
                                   + ")", re.IGNORECASE)
        result = subprocess.run(
            ["bash", "-c", "ps -eo pid=,args="],
            capture_output=True, text=True, timeout=2
        )
        if result.returncode == 0 and result.stdout.strip():
            for line in result.stdout.strip().split('\n'):
                line = line.strip()
                if not line:
                    continue
                _pid, _, _args = line.partition(' ')
                if not _pid.isdigit() or not _args:
                    continue
                _exe_token = _args.split(None, 1)[0]
                _exe_name = os.path.basename(_exe_token).lower()
                if not name_pattern.search(_exe_name):
                    continue
                _matched_slot = None
                _matched_name = None
                for _slot, _cname in custom_names.items():
                    if _cname and _cname in _exe_name:
                        _matched_slot = _slot
                        _matched_name = _cname
                        break
                if _matched_name is None:
                    for _hint_name in ("keryx-miner", "keryxd"):
                        if _hint_name in _exe_name:
                            _matched_name = _hint_name
                            break
                if _matched_name:
                    if _matched_slot:
                        found[f"custom_log_{_matched_slot}"] = True
                    if _custom_miner_last_pid.get(_matched_name) != _pid:
                        _custom_miner_last_pid[_matched_name] = _pid
                        _miner_pid_changed_this_poll.add(_matched_name)
                        _agent_conf_cache["mtime"] = None
                        for _c in _rig_slot_conf_cache.values():
                            _c["mtime"] = None
                        _named_miner_version(_matched_name, force=True)
                    continue
                for proc_name, miner_name in _BUILTIN_MINER_PROCESS_MAP.items():
                    if proc_name in _exe_name:
                        found[miner_name] = True
                        break
    except Exception as e:
        print(f"Error detecting native miner processes: {e}")
    found.update(_docker_published_miners())
    new_set = frozenset(found.keys())
    if new_set != _last_detected_miners_set:
        _last_detected_miners_set = new_set
        _miners_set_changed_flag = True
    return list(found.keys())
def collect_miner_stats_based_on_processes():
    """Collect stats only for miners currently running"""
    collectors = {
        "xmrig":        collect_xmrig_stats,
        "lolminer":     collect_lolminer_stats,
        "bzminer":      collect_bzminer_stats,
        "rigel":        collect_rigel_stats,
        "srbminer":     collect_srbminer_stats,
        "gminer":       collect_gminer_stats,
        "onezerominer": collect_onezerominer_stats,
        "wildrig":      collect_wildrig_stats,
        "teamredminer": collect_teamredminer_stats,
        "trex":         collect_trex_stats,
        "peakminer":    collect_peakminer_stats,
        "custom_log_cpu": lambda: collect_named_custom_miner_stats("cpu"),
        "custom_log_gpu": lambda: collect_named_custom_miner_stats("gpu"),
        "custom_log_aux": lambda: collect_named_custom_miner_stats("aux"),
    }
    stats = {}
    for miner in detect_running_miners():
        if miner in collectors:
            try:
                stats[f"miner_{miner}"] = collectors[miner]()
            except Exception as e:
                stats[f"miner_{miner}"] = {"status": "error", "error": str(e)}
    return stats
def _build_algo_entry(algorithm, hashrate_hs=None, accepted_shares=None, rejected_shares=None,
                       stale_shares=None, invalid_shares=None, cpu_hashrate_hs=None,
                       gpu_hashrate_hs=None, mining_type=None, pool=None, pool_url=None,
                       pool_latency_ms=None, difficulty=None, workers=None, thread_hashrates=None,
                       **extra):
    """Canonical per-algorithm entry - every key below is present on every miner's algorithms[] entries"""
    entry = {
        "algorithm":        algorithm,
        "hashrate_hs":      hashrate_hs,
        "cpu_hashrate_hs":  cpu_hashrate_hs,
        "gpu_hashrate_hs":  gpu_hashrate_hs,
        "mining_type":      mining_type,
        "accepted_shares":  accepted_shares,
        "rejected_shares":  rejected_shares,
        "stale_shares":     stale_shares,
        "invalid_shares":   invalid_shares,
        "pool":             pool,
        "pool_url":         pool_url,
        "pool_latency_ms":  pool_latency_ms,
        "difficulty":       difficulty,
        "workers":          workers,
        "thread_hashrates": thread_hashrates,
    }
    entry.update(extra)
    return entry
def _build_gpu_entry(index, name=None, hashrate_hs=None, accepted_shares=None, rejected_shares=None,
                      stale_shares=None, invalid_shares=None, power=None, core_clock=None,
                      mem_clock=None, temperature=None, mem_temp=None, fan_speed=None, **extra):
    """Canonical per-GPU entry"""
    entry = {
        "gpu_id":          index,
        "index":           index,
        "name":            name if name else f"GPU {index}",
        "hashrate_hs":     hashrate_hs if hashrate_hs is not None else 0,
        "accepted_shares": accepted_shares,
        "rejected_shares": rejected_shares,
        "stale_shares":    stale_shares,
        "invalid_shares":  invalid_shares,
        "power":           power,
        "core_clock":      core_clock,
        "mem_clock":       mem_clock,
        "temperature":     temperature,
        "mem_temp":        mem_temp,
        "fan_speed":       fan_speed,
    }
    entry.update(extra)
    return entry
def _build_miner_result(status, miner, miner_version=None, uptime_s=None, algorithms=None, gpus=None,
                         error=None, total_hashrate_hs=None, total_accepted_shares=None,
                         total_rejected_shares=None, **extra):
    """Canonical top-level shape for every collect_*_stats() return value"""
    algorithms = algorithms or []
    result = {
        "status":        status,
        "miner":         miner,
        "miner_version": miner_version or "unknown",
        "uptime_s":      uptime_s if uptime_s is not None else 0,
        "algorithms":    algorithms,
        "gpus":          gpus if gpus is not None else [],
        "total_hashrate_hs":     total_hashrate_hs if total_hashrate_hs is not None
                                  else sum((a.get("hashrate_hs") or 0) for a in algorithms),
        "total_accepted_shares": total_accepted_shares if total_accepted_shares is not None
                                  else sum((a.get("accepted_shares") or 0) for a in algorithms),
        "total_rejected_shares": total_rejected_shares if total_rejected_shares is not None
                                  else sum((a.get("rejected_shares") or 0) for a in algorithms),
    }
    if error is not None:
        result["error"] = error
    result.update(extra)
    return result
def collect_bzminer_stats():
    host = os.environ.get("BZMINER_API_HOST", "127.0.0.1")
    port = int(os.environ.get("BZMINER_API_PORT", "4014"))
    try:
        with urllib.request.urlopen(
            f"http://{host}:{port}/status", timeout=2.0
        ) as resp:
            data = json.loads(resp.read().decode())
    except Exception as e:
        return _build_miner_result("offline", "bzminer", error=str(e))
    if data.get("method") != "fullstatus":
        return _build_miner_result("unexpected_format", "bzminer", error="unexpected API response shape", data=data)
    pools   = data.get("pools", [])
    devices = data.get("devices", [])
    algorithms = []
    for pool in pools:
        if pool.get("status", 0) <= 0:
            continue
        pool_id = pool.get("id", -1)
        gpu_hr = 0.0
        cpu_hr = 0.0
        for dev in devices:
            dev_pools = dev.get("pool", [])
            dev_hrs   = dev.get("hashrate", [])
            for i, p_id in enumerate(dev_pools):
                if p_id == pool_id and i < len(dev_hrs) and dev_hrs[i] is not None:
                    hr = float(dev_hrs[i])
                    if dev.get("vendor") == 1:
                        gpu_hr += hr
                    else:
                        cpu_hr += hr
        total_hr = gpu_hr + cpu_hr
        def _bz_algo_entry(hr, mtype):
            return _build_algo_entry(
                pool.get("algorithm", "unknown").lower(),
                hashrate_hs=hr,
                gpu_hashrate_hs=hr if mtype == "GPU" else 0,
                cpu_hashrate_hs=hr if mtype == "CPU" else 0,
                mining_type=mtype,
                accepted_shares=pool.get("valid_solutions", 0),
                rejected_shares=pool.get("rejected_solutions", 0),
                stale_shares=pool.get("stale_solutions", 0),
                difficulty=pool.get("difficulty", 0),
                pool=extract_pool_host(pool.get("current_url", "")),
                invalid_solutions=pool.get("invalid_solutions", 0),
                pool_status=pool.get("status", 0),
                uptime_s=pool.get("uptime_s", 0),
            )
        if gpu_hr > 0 and cpu_hr > 0:
            total = gpu_hr + cpu_hr
            gpu_ratio = gpu_hr / total
            cpu_ratio = cpu_hr / total
            valid = pool.get("valid_solutions", 0)
            rejected = pool.get("rejected_solutions", 0)
            gpu_entry = _bz_algo_entry(gpu_hr, "GPU")
            gpu_entry["accepted_shares"] = round(valid    * gpu_ratio)
            gpu_entry["rejected_shares"] = round(rejected * gpu_ratio)
            cpu_entry = _bz_algo_entry(cpu_hr, "CPU")
            cpu_entry["accepted_shares"] = round(valid    * cpu_ratio)
            cpu_entry["rejected_shares"] = round(rejected * cpu_ratio)
            algorithms.append(gpu_entry)
            algorithms.append(cpu_entry)
        elif gpu_hr > 0:
            algorithms.append(_bz_algo_entry(gpu_hr, "GPU"))
        elif cpu_hr > 0:
            algorithms.append(_bz_algo_entry(cpu_hr, "CPU"))
        else:
            algorithms.append(_bz_algo_entry(total_hr, "GPU"))
    cpu_devices, gpu_devices = [], []
    for i, dev in enumerate(devices):
        dev_hr_list = dev.get("hashrate", []) or []
        hashrate_hs = sum(float(h) for h in dev_hr_list if isinstance(h, (int, float)))
        entry = _build_gpu_entry(
            i, name=dev.get("name", "Unknown"), hashrate_hs=hashrate_hs,
            power=dev.get("power", 0), temperature=dev.get("core_temp", 0),
            mem_temp=dev.get("mem_temp", 0), fan_speed=dev.get("fan", 0),
            core_clock=dev.get("clock_rate", 0), mem_clock=dev.get("memory_rate", 0),
            vendor=dev.get("vendor", 0), status=dev.get("status", [0])[0] if dev.get("status") else 0,
        )
        (gpu_devices if dev.get("vendor") == 1 else cpu_devices).append(entry)
    return _build_miner_result(
        "ok", "bzminer",
        miner_version=data.get("bzminer_version", "unknown"),
        uptime_s=data.get("uptime_s", 0),
        algorithms=algorithms,
        gpus=gpu_devices,
        rig_name=data.get("rig_name", RIG_NAME),
        cuda_driver_version=data.get("cuda_driver_version", 0),
        cpu_devices=cpu_devices,
        total_devices=len(devices),
        watchdog_enabled=data.get("watchdog_enabled", False),
    )
def collect_rigel_stats():
    host = os.environ.get("RIGEL_API_HOST", "127.0.0.1")
    port = int(os.environ.get("RIGEL_API_PORT", "5000"))
    try:
        with urllib.request.urlopen(
            f"http://{host}:{port}", timeout=2.0
        ) as resp:
            data = json.loads(resp.read().decode())
    except Exception as e:
        return _build_miner_result("offline", "rigel", error=str(e))
    algo             = data.get("algorithm", "unknown")
    hashrate_data    = data.get("hashrate", {})
    hashrate_hs      = hashrate_data.get(algo, 0) if isinstance(hashrate_data, dict) else 0
    pool_hashrate_hs = (data.get("pool_hashrate", {}) or {}).get(algo, 0)
    sol = (data.get("solution_stat") or {}).get(algo, {})
    accepted, rejected, invalid = sol.get("accepted", 0), sol.get("rejected", 0), sol.get("invalid", 0)
    pools       = data.get("pools", {})
    pool_host   = ""
    pool_latency= None
    pool_state  = "unknown"
    if isinstance(pools, dict) and algo in pools:
        for p in pools[algo]:
            if not isinstance(p, dict):
                continue
            pool_state = "connected" if p.get("state") != "disconnected" else "disconnected"
            cd = p.get("connection_details", {})
            if cd:
                pool_host    = cd.get("hostname", "")
                pool_latency = p.get("average_latency_ms")
            if pool_state == "connected":
                break
    gpus = []
    for device in data.get("devices", []):
        mon = device.get("monitoring_info", {})
        dhr = device.get("hashrate", {})
        ds  = (device.get("solution_stat") or {}).get(algo, {})
        gpus.append(_build_gpu_entry(
            device.get("id", 0), name=device.get("name", "Unknown GPU"),
            hashrate_hs=dhr.get(algo, 0) if isinstance(dhr, dict) else 0,
            accepted_shares=ds.get("accepted", 0), rejected_shares=ds.get("rejected", 0),
            temperature=mon.get("core_temperature", 0), mem_temp=mon.get("memory_temperature", 0),
            fan_speed=mon.get("fan_speed", 0), power=mon.get("power_usage", 0),
            core_clock=mon.get("core_clock", 0), mem_clock=mon.get("memory_clock", 0),
            state=device.get("state", "unknown"), pci_address=device.get("pci_address", ""),
            total_memory=device.get("total_mem", 0),
        ))
    return _build_miner_result(
        "ok", "rigel",
        miner_version=data.get("version", "unknown"),
        uptime_s=data.get("uptime", 0),
        algorithms=[_build_algo_entry(
            algo.lower(),
            hashrate_hs=hashrate_hs,
            accepted_shares=accepted,
            rejected_shares=rejected,
            invalid_shares=invalid,
            pool=pool_host,
            pool_latency_ms=pool_latency,
            pool_hashrate_hs=pool_hashrate_hs,
            pool_state=pool_state,
        )],
        gpus=gpus,
        cuda_driver=data.get("cuda_driver", "unknown"),
        algorithm=algo,
        power_usage=data.get("power_usage", 0),
        watchdog=data.get("watchdog", "off"),
        total_pool_hashrate_hs=pool_hashrate_hs,
    )
def collect_srbminer_stats():
    gpu_host = os.environ.get("SRBMINER_MULTI_API_HOST",
               os.environ.get("SRBMINER_API_HOST",
               os.environ.get("SRBMINER_GPU_API_HOST", "127.0.0.1")))
    gpu_port = int(os.environ.get("SRBMINER_MULTI_API_PORT",
               os.environ.get("SRBMINER_API_PORT",
               os.environ.get("SRBMINER_GPU_API_PORT", "21550"))))
    cpu_host = os.environ.get("SRBMINER_CPU_API_HOST", "127.0.0.1")
    cpu_port = int(os.environ.get("SRBMINER_CPU_API_PORT", "21551"))
    gpu_data, cpu_data = {}, {}
    gpu_status = cpu_status = "offline"
    try:
        with urllib.request.urlopen(f"http://{gpu_host}:{gpu_port}", timeout=2.0) as r:
            gpu_data   = json.loads(r.read().decode())
        gpu_status = "ok"
    except Exception:
        pass
    try:
        with urllib.request.urlopen(f"http://{cpu_host}:{cpu_port}", timeout=2.0) as r:
            cpu_data   = json.loads(r.read().decode())
        cpu_status = "ok"
    except Exception:
        pass
    if gpu_status == "offline" and cpu_status == "offline":
        return _build_miner_result("offline", "srbminer", error="Both GPU and CPU ports unavailable")
    _MIN_HS = 1.0
    algorithms = []
    def _parse_srbminer_algo(algo_data, mining_type, source_port):
        name = algo_data.get("name")
        if not name:
            return
        hr    = algo_data.get("hashrate", {}) if isinstance(algo_data.get("hashrate"), dict) else {}
        block = hr.get(mining_type.lower(), {}) if isinstance(hr, dict) else {}
        try:
            hs = float(block.get("total") or 0)
        except (TypeError, ValueError):
            hs = 0.0
        if hs < _MIN_HS:
            return
        pool_info = algo_data.get("pool") or {}
        pool_str  = pool_info.get("pool", "")
        shares    = algo_data.get("shares", {})
        if mining_type == "GPU":
            gpu_accepted_map = algo_data.get("gpu_accepted_shares", {})
            gpu_rejected_map = algo_data.get("gpu_rejected_shares", {})
            accepted = sum(v for v in gpu_accepted_map.values() if isinstance(v, (int, float)))
            rejected = sum(v for v in gpu_rejected_map.values() if isinstance(v, (int, float)))
            gpu_hashrates      = {k: v for k, v in block.items()
                                  if k != "total" and isinstance(v, (int, float))}
            gpu_compute_errors = algo_data.get("gpu_compute_errors", {})
            gpu_efficiency     = algo_data.get("gpu_efficiency", {})
            algorithms.append(_build_algo_entry(
                name.lower(),
                hashrate_hs=hs, gpu_hashrate_hs=hs, cpu_hashrate_hs=0,
                accepted_shares=accepted, rejected_shares=rejected,
                pool=extract_pool_host(pool_str), difficulty=pool_info.get("difficulty", 0),
                pool_latency_ms=pool_info.get("latency", 0), mining_type="GPU",
                avg_find_time=shares.get("avg_find_time", 0), pool_uptime=pool_info.get("uptime", 0),
                source_port=source_port, gpu_hashrates=gpu_hashrates or None,
                gpu_accepted_shares=gpu_accepted_map or None, gpu_rejected_shares=gpu_rejected_map or None,
                gpu_compute_errors=gpu_compute_errors or None, gpu_efficiency=gpu_efficiency or None,
            ))
        else:
            threads = {k: v for k, v in block.items()
                       if k.startswith("thread") and isinstance(v, (int, float))}
            algorithms.append(_build_algo_entry(
                name.lower(),
                hashrate_hs=hs, cpu_hashrate_hs=hs, gpu_hashrate_hs=0,
                accepted_shares=shares.get("accepted", 0), rejected_shares=shares.get("rejected", 0),
                pool=extract_pool_host(pool_str), difficulty=pool_info.get("difficulty", 0),
                pool_latency_ms=pool_info.get("latency", 0), mining_type="CPU",
                thread_hashrates=threads or None,
                avg_find_time=shares.get("avg_find_time", 0), pool_uptime=pool_info.get("uptime", 0),
                source_port=source_port,
            ))
    if gpu_status == "ok":
        has_cpu_workers = int(gpu_data.get("total_cpu_workers", 0)) > 0
        for algo_data in gpu_data.get("algorithms", []):
            _parse_srbminer_algo(algo_data, "GPU", gpu_port)
            if has_cpu_workers:
                _parse_srbminer_algo(algo_data, "CPU", gpu_port)
    cpu_is_separate = (cpu_host != gpu_host or cpu_port != gpu_port)
    if cpu_status == "ok" and cpu_is_separate:
        for algo_data in cpu_data.get("algorithms", []):
            _parse_srbminer_algo(algo_data, "CPU", cpu_port)
    source = gpu_data if gpu_status == "ok" else cpu_data
    gpu_algos = [a for a in algorithms if a.get("mining_type") == "GPU"]
    cpu_algos = [a for a in algorithms if a.get("mining_type") == "CPU"]
    total_hashrate_hs     = sum(a["hashrate_hs"]    for a in algorithms)
    total_accepted_shares = (sum(a["accepted_shares"] for a in gpu_algos)
                             or sum(a["accepted_shares"] for a in algorithms))
    total_rejected_shares = (sum(a["rejected_shares"] for a in gpu_algos)
                             or sum(a["rejected_shares"] for a in algorithms))
    gpus = []
    for a in gpu_algos:
        gh = a.get("gpu_hashrates")
        if gh:
            for k, v in gh.items():
                m = re.search(r"(\d+)", k)
                idx = int(m.group(1)) if m else len(gpus)
                gpus.append(_build_gpu_entry(idx, hashrate_hs=v))
            break
    return _build_miner_result(
        "ok" if algorithms else "offline", "srbminer",
        miner_version=source.get("miner_version", "unknown"),
        uptime_s=source.get("mining_time", 0),
        algorithms=algorithms,
        gpus=gpus,
        rig_name=source.get("rig_name", RIG_NAME),
        cpu_port_active=cpu_status == "ok",
        gpu_port_active=gpu_status == "ok",
        total_gpu_workers=source.get("total_gpu_workers", 0),
        total_cpu_workers=source.get("total_cpu_workers", 0),
    )
def collect_wildrig_stats():
    host = os.environ.get("WILDRIG_API_HOST", "127.0.0.1")
    port = int(os.environ.get("WILDRIG_API_PORT", "4000"))
    try:
        with urllib.request.urlopen(f"http://{host}:{port}", timeout=2.0) as r:
            data = json.loads(r.read().decode())
    except Exception as e:
        return _build_miner_result("offline", "wildrig", error=str(e))
    algo         = data.get("algo", "unknown")
    hr_info      = data.get("hashrate", {})
    total_list   = hr_info.get("total", [0])
    hashrate_hs  = total_list[0] if isinstance(total_list, list) and total_list else 0
    threads_hr   = hr_info.get("threads", [])
    thread_hr    = {f"thread_{i}": t[0] for i, t in enumerate(threads_hr)
                    if isinstance(t, list) and t}
    results      = data.get("results", {})
    acc_list     = results.get("shares_accepted", [0])
    rej_list     = results.get("shares_rejected", [0])
    ign_list     = results.get("shares_ignored", [0])
    def _sum_list(lst):
        return sum(v for v in lst if isinstance(v, (int, float))) if isinstance(lst, list) else (lst or 0)
    accepted     = _sum_list(acc_list)
    rejected     = _sum_list(rej_list)
    ignored      = _sum_list(ign_list)
    connection   = data.get("connection", {})
    hwmon        = data.get("hwmon", {})
    bus_ids      = hwmon.get("busID", [])
    temps        = hwmon.get("temp", [])
    fans         = hwmon.get("fan", [])
    powers       = hwmon.get("power", [])
    cclks        = hwmon.get("cclk", [])
    mclks        = hwmon.get("mclk", [])
    gpus = [
        _build_gpu_entry(
            i, hashrate_hs=thread_hr.get(f"thread_{i}", 0),
            accepted_shares=acc_list[i] if i < len(acc_list) else 0,
            rejected_shares=rej_list[i] if i < len(rej_list) else 0,
            invalid_shares=ign_list[i] if i < len(ign_list) else 0,
            power=powers[i] if i < len(powers) else 0,
            core_clock=cclks[i] if i < len(cclks) else 0,
            mem_clock=mclks[i] if i < len(mclks) else 0,
            temperature=temps[i] if i < len(temps) else 0,
            fan_speed=fans[i] if i < len(fans) else 0,
            bus_id=bus_ids[i] if i < len(bus_ids) else 0,
        )
        for i in range(max(len(bus_ids), 1))
    ]
    return _build_miner_result(
        "ok", "wildrig",
        miner_version=data.get("version", "unknown"),
        uptime_s=data.get("uptime", 0),
        algorithms=[_build_algo_entry(
            algo.lower(),
            hashrate_hs=hashrate_hs,
            accepted_shares=accepted,
            rejected_shares=rejected,
            difficulty=results.get("diff_current", 0),
            pool=extract_pool_host(connection.get("pool", "")),
            pool_latency_ms=connection.get("ping", 0),
            thread_hashrates=thread_hr or None,
            ignored_shares=ignored, shares_good=results.get("shares_good", 0),
            total_shares=results.get("shares_total", 0), avg_time=results.get("avg_time", 0),
            pool_uptime=connection.get("uptime", 0),
        )],
        gpus=gpus,
        worker_id=data.get("worker_id", RIG_NAME),
        algo=algo,
        connection_failures=connection.get("failures", 0),
    )
def collect_lolminer_stats():
    host = os.environ.get("LOLMINER_API_HOST", "127.0.0.1")
    port = int(os.environ.get("LOLMINER_API_PORT", "8020"))
    try:
        with urllib.request.urlopen(f"http://{host}:{port}", timeout=2.0) as r:
            data = json.loads(r.read().decode())
    except Exception as e:
        return _build_miner_result("offline", "lolminer", error=str(e))
    algorithms = []
    combined_gpu_hr = {}
    for algo_data in data.get("Algorithms", []):
        name   = algo_data.get("Algorithm", "unknown")
        appendix = algo_data.get("Algorithm_Appendix", "")
        if appendix:
            name = f"{name} {appendix}"
        factor = algo_data.get("Performance_Factor", 1_000_000)
        total  = algo_data.get("Total_Performance", 0)
        hr_hs  = total * factor
        worker_perf = algo_data.get("Worker_Performance", [])
        thread_hr   = {
            f"gpu_{i}": p * factor
            for i, p in enumerate(worker_perf)
            if isinstance(p, (int, float))
        }
        combined_gpu_hr.update(thread_hr)
        algorithms.append(_build_algo_entry(
            name.lower(),
            hashrate_hs=hr_hs,
            accepted_shares=algo_data.get("Total_Accepted", 0),
            rejected_shares=algo_data.get("Total_Rejected", 0),
            stale_shares=algo_data.get("Total_Stales", 0),
            pool=extract_pool_host(algo_data.get("Pool", "")),
            workers=algo_data.get("Worker", ""),
            thread_hashrates=thread_hr or None,
            error_shares=algo_data.get("Total_Errors", 0), user=algo_data.get("User", ""),
            performance_unit=algo_data.get("Performance_Unit", "Mh/s"), performance_factor=factor,
            worker_accepted=algo_data.get("Worker_Accepted", []), worker_rejected=algo_data.get("Worker_Rejected", []),
            worker_stales=algo_data.get("Worker_Stales", []), worker_errors=algo_data.get("Worker_Errors", []),
        ))
    gpus = [
        _build_gpu_entry(
            w.get("Index", 0), name=w.get("Name", "Unknown GPU"),
            hashrate_hs=combined_gpu_hr.get(f"gpu_{w.get('Index', 0)}", 0),
            power=w.get("Power", 0), core_clock=w.get("CCLK", 0), mem_clock=w.get("MCLK", 0),
            temperature=w.get("Core_Temp", 0), mem_temp=w.get("Mem_Temp", 0), fan_speed=w.get("Fan_Speed", 0),
            junction_temp=w.get("Juc_Temp", 0), lhr_unlock=w.get("LHR_Unlock_Pct", 0),
            dual_factor=w.get("Dual_Factor", 0), pci_address=w.get("PCIE_Address", ""),
        )
        for w in data.get("Workers", [])
    ]
    session = data.get("Session", {})
    return _build_miner_result(
        "ok", "lolminer",
        miner_version=data.get("Software", "unknown"),
        uptime_s=session.get("Uptime", 0),
        algorithms=algorithms,
        gpus=gpus,
        total_hashrate_hs=algorithms[0]["hashrate_hs"] if algorithms else 0,
        total_accepted_shares=algorithms[0]["accepted_shares"] if algorithms else 0,
        total_rejected_shares=algorithms[0]["rejected_shares"] if algorithms else 0,
        rig_name=RIG_NAME,
        start_time=session.get("Startup", 0), start_time_str=session.get("Startup_String", ""),
        last_update=session.get("Last_Update", 0), num_workers=data.get("Num_Workers", 0),
        num_algorithms=data.get("Num_Algorithms", 0),
    )
def collect_onezerominer_stats():
    host = os.environ.get("ONEZEROMINER_API_HOST", "127.0.0.1")
    port = int(os.environ.get("ONEZEROMINER_API_PORT", "3001"))
    try:
        with urllib.request.urlopen(f"http://{host}:{port}", timeout=2.0) as r:
            data = json.loads(r.read().decode())
    except Exception as e:
        return _build_miner_result("offline", "onezerominer", error=str(e))
    algorithms = []
    combined_gpu_hr = {}
    dev_accepted, dev_rejected, dev_invalid = {}, {}, {}
    def _add_dev_shares(target, values):
        for i, v in enumerate(values or []):
            if isinstance(v, (int, float)):
                target[i] = target.get(i, 0) + v
    for algo_data in data.get("algos", []):
        _add_dev_shares(dev_accepted, algo_data.get("devices_accepted_shares"))
        _add_dev_shares(dev_rejected, algo_data.get("devices_rejected_shares"))
        _add_dev_shares(dev_invalid,  algo_data.get("devices_invalid_shares"))
        name        = algo_data.get("name", "unknown")
        total_hr    = algo_data.get("total_hashrate", 0)
        device_hr   = algo_data.get("hashrates", [])
        thread_hr   = {f"gpu_{i}": v for i, v in enumerate(device_hr)
                       if isinstance(v, (int, float))}
        combined_gpu_hr.update(thread_hr)
        pool_str    = algo_data.get("pool", "")
        session     = algo_data.get("session", {})
        algorithms.append(_build_algo_entry(
            name.lower(),
            hashrate_hs=total_hr,
            accepted_shares=algo_data.get("total_accepted_shares", 0),
            rejected_shares=algo_data.get("total_rejected_shares", 0),
            invalid_shares=algo_data.get("total_invalid_shares", 0),
            pool=extract_pool_host(pool_str), pool_url=pool_str,
            thread_hashrates=thread_hr or None,
            pool_status=algo_data.get("pool_status", "unknown"), split=algo_data.get("split", False),
            session_active=session.get("active", False), next_session=session.get("next_session", 0),
            devices_accepted_shares=algo_data.get("devices_accepted_shares", []),
            devices_rejected_shares=algo_data.get("devices_rejected_shares", []),
            devices_invalid_shares=algo_data.get("devices_invalid_shares", []),
        ))
    gpus = [
        _build_gpu_entry(
            d.get("id", i), name=d.get("name", "Unknown GPU"),
            hashrate_hs=combined_gpu_hr.get(f"gpu_{i}", 0),
            accepted_shares=dev_accepted.get(i, 0), rejected_shares=dev_rejected.get(i, 0),
            invalid_shares=dev_invalid.get(i, 0),
            power=d.get("power", 0), core_clock=d.get("cclk", 0), mem_clock=d.get("mclk", 0),
            temperature=d.get("temp", 0), mem_temp=d.get("mem_temp"), fan_speed=d.get("fan", 0),
            bus_id=d.get("bus_id", 0),
        )
        for i, d in enumerate(data.get("devices", []))
    ]
    return _build_miner_result(
        "ok", "onezerominer",
        miner_version=data.get("version", "unknown"),
        uptime_s=data.get("uptime_seconds", 0),
        algorithms=algorithms,
        gpus=gpus,
        total_hashrate_hs=algorithms[0]["hashrate_hs"] if algorithms else 0,
        total_accepted_shares=algorithms[0]["accepted_shares"] if algorithms else 0,
        total_rejected_shares=algorithms[0]["rejected_shares"] if algorithms else 0,
        name=data.get("name", "OneZeroMiner"), start_time=data.get("start_time", 0),
        last_update=data.get("last_update", 0),
    )
def collect_gminer_stats():
    host = os.environ.get("GMINER_API_HOST", "127.0.0.1")
    port = int(os.environ.get("GMINER_API_PORT", "10050"))
    try:
        with urllib.request.urlopen(f"http://{host}:{port}/stat", timeout=2.0) as r:
            data = json.loads(r.read().decode())
    except Exception as e:
        return _build_miner_result("offline", "gminer", error=str(e))
    algo     = data.get("algorithm", "unknown")
    devices  = data.get("devices", [])
    total_hs = 0
    thread_hr, device_details = {}, []
    for i, d in enumerate(devices):
        speed = d.get("speed", 0)
        if isinstance(speed, (int, float)):
            total_hs += speed
            thread_hr[f"gpu_{i}"] = speed
        device_details.append({
            "gpu_id":                    d.get("gpu_id", i),
            "bus_id":                    d.get("bus_id", ""),
            "name":                      d.get("name", f"GPU {i}"),
            "speed":                     speed,
            "accepted_shares":           d.get("accepted_shares", 0),
            "rejected_shares":           d.get("rejected_shares", 0),
            "stale_shares":              d.get("stale_shares", 0),
            "invalid_shares":            d.get("invalid_shares", 0),
            "fan":                       d.get("fan", 0),
            "temperature":               d.get("temperature", 0),
            "temperature_limit":         d.get("temperature_limit", 0),
            "memory_temperature":        d.get("memory_temperature", 0),
            "memory_temperature_limit":  d.get("memory_temperature_limit", 0),
            "core_clock":                d.get("core_clock", 0),
            "memory_clock":              d.get("memory_clock", 0),
            "power_usage":               d.get("power_usage", 0),
        })
    algorithms = [_build_algo_entry(
        algo.lower(),
        hashrate_hs=total_hs,
        accepted_shares=data.get("total_accepted_shares", 0),
        rejected_shares=data.get("total_rejected_shares", 0),
        stale_shares=data.get("total_stale_shares", 0),
        invalid_shares=data.get("total_invalid_shares", 0),
        pool=extract_pool_host(data.get("server", "")), pool_url=data.get("server", ""),
        thread_hashrates=thread_hr or None,
        user=data.get("user", ""), shares_per_minute=data.get("shares_per_minute", 0),
        pool_speed=data.get("pool_speed", 0), device_details=device_details,
    )]
    gpus = [
        _build_gpu_entry(
            i, name=d.get("name", "Unknown GPU"), hashrate_hs=d.get("speed", 0),
            accepted_shares=d.get("accepted_shares", 0), rejected_shares=d.get("rejected_shares", 0),
            stale_shares=d.get("stale_shares", 0), invalid_shares=d.get("invalid_shares", 0),
            temperature=d.get("temperature", 0), mem_temp=d.get("memory_temperature", 0),
            fan_speed=d.get("fan", 0), power=d.get("power_usage", 0),
            core_clock=d.get("core_clock", 0), mem_clock=d.get("memory_clock", 0),
            bus_id=d.get("bus_id", ""),
        )
        for i, d in enumerate(devices)
    ]
    return _build_miner_result(
        "ok", "gminer",
        miner_version=data.get("miner", "unknown"),
        uptime_s=data.get("uptime", 0),
        algorithms=algorithms,
        gpus=gpus,
        total_stale_shares=data.get("total_stale_shares", 0),
        shares_per_minute=data.get("shares_per_minute", 0),
        pool_speed=data.get("pool_speed", 0),
    )
def collect_xmrig_stats():
    """Collect XMRig stats from CPU and/or GPU instances"""
    cpu_host = os.environ.get("XMRIG_CPU_API_HOST",
               os.environ.get("XMRIG_API_HOST", "127.0.0.1"))
    cpu_port = int(os.environ.get("XMRIG_CPU_API_PORT",
               os.environ.get("XMRIG_API_PORT", "18080")))
    gpu_host = os.environ.get("XMRIG_GPU_API_HOST", "127.0.0.1")
    gpu_port = int(os.environ.get("XMRIG_GPU_API_PORT", "18081"))
    cpu_data, gpu_data = {}, {}
    cpu_status = gpu_status = "offline"
    try:
        with urllib.request.urlopen(
            f"http://{cpu_host}:{cpu_port}/2/summary", timeout=2.0
        ) as r:
            cpu_data   = json.loads(r.read().decode())
        cpu_status = "ok"
    except Exception:
        pass
    try:
        with urllib.request.urlopen(
            f"http://{gpu_host}:{gpu_port}/2/summary", timeout=2.0
        ) as r:
            gpu_data   = json.loads(r.read().decode())
        gpu_status = "ok"
    except Exception:
        pass
    if cpu_status == "offline" and gpu_status == "offline":
        return _build_miner_result("offline", "xmrig", error="Both XMRig instances unavailable")
    def _xmrig_algo(instance_data, instance_type, port):
        algo    = instance_data.get("algo", "unknown")
        hr_info = instance_data.get("hashrate", {})
        totals  = hr_info.get("total", [0, 0, 0])
        hr_hs   = float(totals[0]) if totals and totals[0] is not None else 0
        res     = instance_data.get("results", {})
        good    = res.get("shares_good", 0)
        total_s = res.get("shares_total", 0)
        conn    = instance_data.get("connection", {})
        entry = _build_algo_entry(
            algo.lower(),
            hashrate_hs=hr_hs,
            accepted_shares=good,
            rejected_shares=total_s - good if total_s and good else 0,
            difficulty=res.get("diff_current", 0), pool_latency_ms=conn.get("ping", 0),
            pool=extract_pool_host(conn.get("pool", "")), pool_url=conn.get("pool", ""),
            mining_type=instance_type,
            hashrate_1m=totals[0] if len(totals) > 0 else 0, hashrate_5m=totals[1] if len(totals) > 1 else 0,
            hashrate_15m=totals[2] if len(totals) > 2 else 0, total_shares=total_s,
            avg_time_ms=res.get("avg_time_ms", 0), instance_type=instance_type, source_port=port,
        )
        if instance_type == "CPU":
            entry["cpu_threads"] = instance_data.get("cpu", {}).get("threads", 0)
        return entry
    algorithms = []
    if cpu_status == "ok":
        algorithms.append(_xmrig_algo(cpu_data, "CPU", cpu_port))
    if gpu_status == "ok":
        algorithms.append(_xmrig_algo(gpu_data, "GPU", gpu_port))
    source   = cpu_data if cpu_status == "ok" else gpu_data
    res      = source.get("resources", {})
    mem      = res.get("memory", {})
    load_avg = res.get("load_average", [0, 0, 0])
    cpu_info = source.get("cpu", {})
    return _build_miner_result(
        "ok", "xmrig",
        miner_version=source.get("version", "unknown"),
        uptime_s=source.get("uptime", 0),
        algorithms=algorithms,
        worker_id=source.get("worker_id", RIG_NAME),
        cpu_instance_active=cpu_status == "ok", gpu_instance_active=gpu_status == "ok",
        cpu={
            "brand":   cpu_info.get("brand", ""),
            "cores":   cpu_info.get("cores", 0),
            "threads": cpu_info.get("threads", 0),
            "aes":     cpu_info.get("aes", False),
            "avx2":    cpu_info.get("avx2", False),
        },
        system={
            "memory_total": mem.get("total", 0),
            "memory_free":  mem.get("free", 0),
            "load_1m":  load_avg[0] if len(load_avg) > 0 else 0,
            "load_5m":  load_avg[1] if len(load_avg) > 1 else 0,
            "load_15m": load_avg[2] if len(load_avg) > 2 else 0,
        },
    )
def collect_teamredminer_stats():
    """TeamRedMiner uses HTTP/0.9 text protocol on port 4028"""
    algorithm = pool_name = "unknown"
    try:
        result = subprocess.run(
            "ps aux | grep -w teamredminer | grep -v grep | head -1",
            shell=True, capture_output=True, text=True, timeout=2
        )
        if result.returncode == 0 and result.stdout.strip():
            try:
                args = shlex.split(result.stdout.strip())
            except Exception:
                args = result.stdout.strip().split()
            for i, arg in enumerate(args):
                if arg in ('-a', '--algo') and i + 1 < len(args):
                    algorithm = args[i + 1].lower()
                elif arg.startswith('-a=') or arg.startswith('--algo='):
                    algorithm = arg.split('=', 1)[1].lower()
                if arg in ('-o', '--pool') and i + 1 < len(args):
                    parts = args[i + 1].split("://", 1)[-1].split(":")[0].split("/")[0].split(".")
                    pool_name = parts[-2] if len(parts) >= 2 else parts[0]
    except Exception:
        pass
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(2)
        s.connect(("127.0.0.1", 4028))
        s.sendall(b"summary\n")
        response = b""
        try:
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                response += chunk
        except socket.timeout:
            pass
        s.close()
    except Exception as e:
        return _build_miner_result("error", "teamredminer", error=str(e))
    response_text = response.decode('utf-8', errors='ignore')
    parts         = response_text.split('|')
    if len(parts) < 2:
        return _build_miner_result("error", "teamredminer", error="Invalid response format")
    parsed = {}
    for item in parts[1].split(','):
        if '=' in item:
            k, v = item.split('=', 1)
            parsed[k] = v
    def safe_int(v, d=0):
        try:
            return int(float(v))
        except Exception:
            return d
    def safe_float(v, d=None):
        try:
            return float(v)
        except Exception:
            return d
    mhs       = parsed.get('MHS 30s')
    hr_hs     = safe_float(mhs, 0) * 1e6 if mhs else None
    version   = "0.10.21"
    if 'TeamRedMiner' in parts[0]:
        m = re.search(r'TeamRedMiner\s+([\d.]+)', parts[0])
        if m:
            version = m.group(1)
    return _build_miner_result(
        "ok", "teamredminer",
        miner_version=version,
        uptime_s=safe_int(parsed.get('Elapsed', 0)),
        algorithms=[_build_algo_entry(
            algorithm.lower(),
            hashrate_hs=hr_hs,
            accepted_shares=safe_int(parsed.get('Accepted', 0)),
            rejected_shares=safe_int(parsed.get('Rejected', 0)),
            pool=pool_name,
            hardware_errors=safe_int(parsed.get('Hardware Errors', 0)),
            utility=safe_float(parsed.get('Utility')),
        )],
    )
def collect_trex_stats():
    host = os.environ.get("TREX_API_HOST", "127.0.0.1")
    port = int(os.environ.get("TREX_API_PORT", "4067"))
    response = requests.get(f"http://{host}:{port}/summary", timeout=5)
    data     = response.json()
    algo         = data.get("algorithm", "").lower()
    pool         = data.get("active_pool", {})
    pool_url     = pool.get("url", "")
    gpus = [
        _build_gpu_entry(
            g.get("device_id", g.get("gpu_id", 0)), name=g.get("name", f"GPU {g.get('gpu_id', 0)}"),
            hashrate_hs=int(g.get("hashrate", 0)),
            accepted_shares=g.get("shares", {}).get("accepted_count", 0),
            rejected_shares=g.get("shares", {}).get("rejected_count", 0),
            power=g.get("power", 0), core_clock=g.get("cclock", 0), mem_clock=g.get("mclock", 0),
            temperature=g.get("temperature", 0), fan_speed=g.get("fan_speed", 0),
            uuid=g.get("uuid", ""), pci_bus=g.get("pci_bus", 0),
            hashrate_minute=int(g.get("hashrate_minute", 0)), hashrate_hour=int(g.get("hashrate_hour", 0)),
            hashrate_day=int(g.get("hashrate_day", 0)), efficiency=g.get("efficiency", "0"),
            paused=g.get("paused", False),
        )
        for g in data.get("gpus", [])
    ]
    watchdog = data.get("watchdog_stat", {})
    return _build_miner_result(
        "ok", "trex",
        miner_version=data.get("version", ""),
        uptime_s=data.get("uptime", 0),
        algorithms=[_build_algo_entry(
            algo,
            hashrate_hs=int(data.get("hashrate", 0)),
            accepted_shares=data.get("accepted_count", 0),
            rejected_shares=data.get("rejected_count", 0),
            difficulty=pool.get("difficulty", "0"), pool_latency_ms=pool.get("ping", 0),
            pool=extract_pool_host(pool_url), pool_url=pool_url,
            workers=pool.get("worker", ""),
            hashrate_minute=int(data.get("hashrate_minute", 0)), hashrate_hour=int(data.get("hashrate_hour", 0)),
            hashrate_day=int(data.get("hashrate_day", 0)), user=pool.get("user", ""),
        )],
        gpus=gpus,
        cuda_driver=data.get("driver", ""), rig_name=RIG_NAME,
        paused=data.get("paused", False), gpu_total=data.get("gpu_total", 0),
        watchdog={
            "built_in":      watchdog.get("built_in", True),
            "version":       watchdog.get("wd_version", ""),
            "uptime":        watchdog.get("uptime", 0),
            "total_restarts":watchdog.get("total_restarts", 0),
        },
    )
def collect_peakminer_stats():
    """Reads PeakMiner's /summary HTTP endpoint; reports invalid_shares as its own field since PeakMiner"""
    host = os.environ.get("PEAKMINER_API_HOST", "127.0.0.1")
    port = int(os.environ.get("PEAKMINER_API_PORT", "4068"))
    try:
        with urllib.request.urlopen(f"http://{host}:{port}/summary", timeout=2.0) as r:
            data = json.loads(r.read().decode())
    except Exception as e:
        return _build_miner_result("offline", "peakminer", error=str(e))
    algo     = data.get("algo", "unknown")
    pool     = data.get("pool", {}) or {}
    pool_url = pool.get("url", "")
    gpus = [
        _build_gpu_entry(
            g.get("id", 0), name=g.get("name", f"GPU {g.get('id', 0)}"),
            hashrate_hs=g.get("hashrate", 0), accepted_shares=g.get("accepted_shares", 0),
            rejected_shares=0, invalid_shares=g.get("invalid_shares", 0),
            temperature=g.get("temperature_c", 0), fan_speed=g.get("fan_pct", 0),
            power=g.get("power_w", 0), core_clock=g.get("core_clock_mhz", 0),
            mem_clock=g.get("mem_clock_mhz", 0),
            pci_bus_id=g.get("pci_bus_id", ""), hashrate_per_watt=g.get("hashrate_per_watt", 0),
            status=g.get("status"),
        )
        for g in data.get("gpus", [])
    ]
    return _build_miner_result(
        "ok", "peakminer",
        miner_version=data.get("version", "unknown"),
        uptime_s=data.get("uptime", 0),
        algorithms=[_build_algo_entry(
            algo.lower(),
            hashrate_hs=data.get("hashrate", 0),
            accepted_shares=data.get("accepted_shares", 0),
            rejected_shares=0,
            invalid_shares=data.get("invalid_shares", 0),
            difficulty=pool.get("difficulty", 0), pool_latency_ms=pool.get("ping_ms", 0),
            pool=extract_pool_host(pool_url), pool_url=pool_url,
            hashrate_per_watt=data.get("hashrate_per_watt", 0), efficiency_pct=data.get("efficiency_pct", 0),
            effort_pct=data.get("effort_pct", 0), eta_share_secs=data.get("eta_share_secs", 0),
            last_share_at=data.get("last_share_at"), pool_connected=pool.get("connected", False),
        )],
        gpus=gpus,
        total_rejected_shares=0,
        rig_name=RIG_NAME, dev_fee_percent=data.get("dev_fee_percent", 0),
        power_w=data.get("power_w", 0), total_invalid_shares=data.get("invalid_shares", 0),
    )
def _query_binary_version(bin_path):
    """Runs `<bin_path> --version` and returns its first line, or '' on any failure; generic helper also"""
    try:
        out = subprocess.run(
            [bin_path, "--version"], capture_output=True, text=True, timeout=2.0
        )
        text = (out.stdout or out.stderr or "").strip()
        return text.splitlines()[0] if text else ""
    except Exception:
        return ""
def _sanitize_miner_key(name):
    """Converts a miner name into a valid rigcontrol-agent.conf variable prefix, e.g"""
    base = (name or "").strip()
    base = re.sub(r"-linux-x86_64$", "", base, flags=re.IGNORECASE)
    base = re.sub(r"-[0-9][0-9A-Za-z_.]*$", "", base)
    return re.sub(r"[^A-Za-z0-9]+", "_", base).strip("_").upper()
def _named_miner_bin(name):
    """Resolves a named custom miner's binary path via <NAME>_BIN in rigcontrol-agent.conf, falling back"""
    if not name:
        return ""
    bin_path = os.environ.get(f"{_sanitize_miner_key(name)}_BIN", "").strip()
    if bin_path:
        return bin_path
    return f"{CUSTOM_MINER_BASE_DIR}/custom/{name}/current/{name}"
_named_miner_version_cache = {}
def _named_miner_version(name, force=False):
    """Caches and returns `<name> --version`'s first line, re-querying only when forced (e.g"""
    cache = _named_miner_version_cache.setdefault(name, {"version": "", "queried": False, "last_uptime_s": None})
    if force or not cache["queried"]:
        cache["version"] = _query_binary_version(_named_miner_bin(name))
        cache["queried"] = True
    return cache["version"]
def _tail_file(path, max_bytes=131072):
    """Read the last max_bytes of a file as text (cheap tail, no deps)"""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - max_bytes))
            data = f.read()
        return data.decode("utf-8", errors="ignore")
    except Exception:
        return None
_log_event_state = {}
def _read_new_log_bytes(path, state, restart_threshold_bytes=1048576):
    """Reads only what's been appended to path since the last call"""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            if size < state.get("offset", 0):
                fp = state.get("tail_fp")
                f.seek(0)
                whole = f.read()
                idx = whole.find(fp) if fp else -1
                if idx != -1:
                    resume_at = idx + len(fp)
                    state["offset"] = size
                    state["reset"] = False
                    new_tail = whole[resume_at:]
                    if new_tail:
                        state["tail_fp"] = new_tail[-256:]
                    return new_tail.decode("utf-8", errors="ignore")
                elif size < restart_threshold_bytes:
                    state["offset"] = 0
                    state["reset"] = True
                else:
                    state["offset"] = size
                    state["reset"] = False
                    return ""
            else:
                state["reset"] = False
            f.seek(state.get("offset", 0))
            data = f.read()
            state["offset"] = size
        if data:
            state["tail_fp"] = data[-256:]
        return data.decode("utf-8", errors="ignore")
    except Exception:
        return None
_agent_conf_cache = {"mtime": None, "data": {}}
def _read_agent_conf_val(key):
    """Reads a KEY=value from rigcontrol-agent.conf, only re-reading/re-parsing the file when its mtime"""
    try:
        mtime = os.path.getmtime(AGENT_CONF_PATH)
    except OSError:
        return ""
    if _agent_conf_cache["mtime"] != mtime:
        data = {}
        try:
            with open(AGENT_CONF_PATH) as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    k, v = line.split("=", 1)
                    data[k.strip()] = v.strip()
        except Exception:
            data = {}
        _agent_conf_cache["mtime"] = mtime
        _agent_conf_cache["data"] = data
    return _agent_conf_cache["data"].get(key, "")
def _find_slot_miner_pid(slot):
    """Finds the PID/cmdline of the miner process running inside the detached `screen -S <slot>` session"""
    try:
        result = subprocess.run(["screen", "-list"], capture_output=True, text=True, timeout=2)
    except Exception:
        return None, None
    screen_pid = None
    for line in (result.stdout or "").splitlines():
        m = re.search(rf"(\d+)\.{re.escape(slot)}(?:\s|\t|$)", line.strip())
        if m:
            screen_pid = m.group(1)
            break
    if not screen_pid:
        return None, None
    skip_names = {"bash", "sh", "screen", "sed", "tee", "SCREEN", "awk", "grep"}
    frontier = [screen_pid]
    seen = set()
    for _ in range(5):
        if not frontier:
            break
        next_frontier = []
        for pid in frontier:
            if pid in seen:
                continue
            seen.add(pid)
            try:
                children = subprocess.run(
                    ["pgrep", "-P", pid], capture_output=True, text=True, timeout=2
                ).stdout.split()
            except Exception:
                children = []
            for cpid in children:
                try:
                    with open(f"/proc/{cpid}/cmdline", "rb") as f:
                        cmdline = f.read().replace(b"\x00", b" ").decode(errors="ignore").strip()
                except Exception:
                    cmdline = ""
                bin_name = os.path.basename(cmdline.split(" ", 1)[0]) if cmdline else ""
                if bin_name and bin_name not in skip_names:
                    return cpid, cmdline
                next_frontier.append(cpid)
        frontier = next_frontier
    return None, None
def resolve_active_miner_api(slot):
    """Resolves the real HTTP/TCP stats-API endpoint for whichever miner is actually running under the"""
    pid, cmdline = _find_slot_miner_pid(slot)
    if not cmdline:
        return {"method": "none", "reason": f"no active miner process found under the '{slot}' screen session"}
    bin_name = os.path.basename(cmdline.split(" ", 1)[0])
    lc = cmdline.lower()
    def _port(*keys, default=None):
        for k in keys:
            v = os.environ.get(k, "").strip()
            if v:
                return v
        return str(default)
    if "xmrig" in lc:
        if slot == "cpu":
            host = os.environ.get("XMRIG_CPU_API_HOST", "").strip() or os.environ.get("XMRIG_API_HOST", "127.0.0.1")
            port = _port("XMRIG_CPU_API_PORT", "XMRIG_API_PORT", default=18080)
        else:
            host = os.environ.get("XMRIG_GPU_API_HOST", "127.0.0.1")
            port = _port("XMRIG_GPU_API_PORT", default=18081)
        return {"method": "http", "url": f"http://{host}:{port}/2/summary", "miner": "xmrig"}
    if "lolminer" in lc:
        port = _port("LOLMINER_API_PORT", default=8020)
        return {"method": "http", "url": f"http://127.0.0.1:{port}/", "miner": "lolminer"}
    if "bzminer" in lc:
        port = _port("BZMINER_API_PORT", default=4014)
        return {"method": "http", "url": f"http://127.0.0.1:{port}/", "miner": "bzminer"}
    if "rigel" in lc:
        port = _port("RIGEL_API_PORT", default=5000)
        return {"method": "http", "url": f"http://127.0.0.1:{port}/", "miner": "rigel"}
    if "srbminer" in lc:
        if slot == "cpu":
            port = _port("SRBMINER_CPU_API_PORT", default=21551)
        else:
            port = _port("SRBMINER_MULTI_API_PORT", "SRBMINER_API_PORT", "SRBMINER_GPU_API_PORT", default=21550)
        return {"method": "http", "url": f"http://127.0.0.1:{port}/", "miner": "srbminer"}
    if "wildrig" in lc:
        port = _port("WILDRIG_API_PORT", default=4000)
        return {"method": "http", "url": f"http://127.0.0.1:{port}/", "miner": "wildrig"}
    if "onezerominer" in lc:
        port = _port("ONEZEROMINER_API_PORT", default=3001)
        return {"method": "http", "url": f"http://127.0.0.1:{port}/", "miner": "onezerominer"}
    if "gminer" in lc:
        port = _port("GMINER_API_PORT", default=10050)
        return {"method": "http", "url": f"http://127.0.0.1:{port}/stat", "miner": "gminer"}
    if "t-rex" in lc or re.search(r"\btrex\b", lc):
        port = _port("TREX_API_PORT", default=4067)
        return {"method": "http", "url": f"http://127.0.0.1:{port}/summary", "miner": "t-rex"}
    if "peakminer" in lc:
        port = _port("PEAKMINER_API_PORT", default=4068)
        return {"method": "http", "url": f"http://127.0.0.1:{port}/summary", "miner": "peakminer"}
    if "teamredminer" in lc:
        return {"method": "tcp", "host": "127.0.0.1", "port": 4028, "payload": "summary\n", "miner": "teamredminer"}
    key = _sanitize_miner_key(bin_name)
    api_host = _read_agent_conf_val(f"{key}_API_HOST") or os.environ.get(f"{key}_API_HOST", "").strip()
    api_port = _read_agent_conf_val(f"{key}_API_PORT") or os.environ.get(f"{key}_API_PORT", "").strip()
    if api_host and api_port:
        return {
            "method": "http",
            "url": f"http://{api_host}:{api_port}/stats",
            "url_fallback": f"http://{api_host}:{api_port}/v1/miner/stats",
            "miner": bin_name,
        }
    return {
        "method": "none",
        "reason": f"detected '{bin_name}' but no known API port for it (set {key}_API_HOST / {key}_API_PORT in rigcontrol-agent.conf)",
    }
def collect_named_custom_miner_stats(slot):
    """Telemetry for the custom miner registered for this slot ('cpu'/'gpu'/'aux', via"""
    with _custom_miner_lock:
        name = _CUSTOM_MINER_PROCESS_NAMES.get(slot, "")
    if not name:
        return _build_miner_result("error", f"custom_{slot}", error=f"no custom miner registered for slot '{slot}'")
    key = _sanitize_miner_key(name)
    mining_type = {"cpu": "CPU", "gpu": "GPU"}.get((slot or "").lower(), "AUX")
    api_host = _read_agent_conf_val(f"{key}_API_HOST") or os.environ.get(f"{key}_API_HOST", "").strip()
    api_port = _read_agent_conf_val(f"{key}_API_PORT") or os.environ.get(f"{key}_API_PORT", "").strip()
    if api_host and api_port:
        return _collect_named_miner_api_stats(name, api_host, int(api_port), mining_type)
    log_path = _read_agent_conf_val(f"{key}_LOG_PATH") or os.environ.get(f"{key}_LOG_PATH", "").strip()
    log_style = _read_agent_conf_val(f"{key}_LOG_STYLE") or os.environ.get(f"{key}_LOG_STYLE", "").strip()
    if log_style.lower() == "blocks":
        return _collect_named_miner_block_log_stats(name, log_path, mining_type)
    return _collect_named_miner_generic_log_stats(name, key, log_path, mining_type)
def _parse_hive_style_miner_stats(name, data, mining_type="GPU"):
    """Parses HiveOS-format miner stats (suprminer-neptune), e.g"""
    mult = {"hs": 1, "khs": 1e3, "mhs": 1e6, "ghs": 1e9}.get(str(data.get("hs_units", "hs")).lower(), 1)
    hs = [float(x or 0) * mult for x in (data.get("hs") or [])]
    total_hr = sum(hs)
    if not total_hr and data.get("total_khs"):
        total_hr = float(data["total_khs"]) * 1e3
    ar = list(data.get("ar") or [])
    ar += [0] * (3 - len(ar))
    accepted, rejected, invalid = int(ar[0] or 0), int(ar[1] or 0), int(ar[2] or 0)
    single = len(hs) == 1
    def _at(key, i):
        v = data.get(key)
        return v[i] if isinstance(v, list) and i < len(v) else None
    gpus = [
        _build_gpu_entry(
            i, hashrate_hs=h,
            accepted_shares=accepted if single else None,
            rejected_shares=rejected if single else None,
            invalid_shares=invalid if single else None,
        )
        for i, h in enumerate(hs)
    ]
    cache = _named_miner_version_cache.setdefault(name, {"version": "", "queried": False, "last_uptime_s": None})
    if data.get("ver"):
        cache["version"] = f"{name} {data['ver']}"
        cache["queried"] = True
    cache["last_uptime_s"] = data.get("uptime", 0)
    pool = data.get("pool")
    return _build_miner_result(
        "ok", name,
        miner_version=cache["version"],
        uptime_s=data.get("uptime", 0),
        algorithms=[_build_algo_entry(
            str(data.get("algo") or "unknown").lower(),
            hashrate_hs=total_hr,
            cpu_hashrate_hs=total_hr if mining_type == "CPU" else 0,
            gpu_hashrate_hs=total_hr if mining_type == "GPU" else 0,
            mining_type=mining_type,
            accepted_shares=accepted, rejected_shares=rejected, invalid_shares=invalid,
            pool=pool, pool_url=pool, difficulty=data.get("diff"),
        )],
        gpus=gpus,
    )
def _collect_named_miner_api_stats(name, api_host, api_port, mining_type="AUX"):
    """Reads a keryx-style JSON /stats API for hashrate, accepted/rejected OPoI SHARE counts, and (on"""
    data = None
    last_err = None
    for path in ("/stats", "/v1/miner/stats", "/"):
        try:
            with urllib.request.urlopen(f"http://{api_host}:{api_port}{path}", timeout=2.0) as r:
                data = json.loads(r.read().decode())
            break
        except Exception as e:
            last_err = e
    if data is None:
        return _build_miner_result(
            "error", name,
            error=f"{name} API unreachable at {api_host}:{api_port} (/stats, /v1/miner/stats): {last_err}",
            miner_version=_named_miner_version(name),
        )
    if isinstance(data, dict) and isinstance(data.get("hs"), list) and "ar" in data:
        return _parse_hive_style_miner_stats(name, data, mining_type)
    device_re = re.compile(r"#(\d+)\s*\(([^)]+)\)")
    raw_devices = data.get("devices", []) or []
    parsed_devices = []
    for i, dev in enumerate(raw_devices):
        dev_id = dev.get("id") or dev.get("name") or ""
        m = device_re.search(dev_id)
        idx  = int(m.group(1)) if m else i
        gname = m.group(2).strip() if m else dev_id
        parsed_devices.append((idx, gname, dev))
    parsed_devices.sort(key=lambda d: d[0])
    total_hr_hs = data.get("total_hashrate_hs", 0)
    if "accepted_blocks" in data or "rejected_blocks" in data:
        accepted_shares = data.get("accepted_blocks", 0)
        rejected_shares = data.get("rejected_blocks", 0)
    else:
        shares = data.get("shares") or {}
        accepted_shares = shares.get("accepted", 0)
        rejected_shares = shares.get("rejected", 0)
    uptime_s = data.get("uptime_s", 0)
    cache = _named_miner_version_cache.setdefault(name, {"version": "", "queried": False, "last_uptime_s": None})
    if data.get("version"):
        cache["version"] = f"{name} {data['version']}"
        cache["queried"] = True
    elif cache.get("last_uptime_s") is None or uptime_s < cache["last_uptime_s"]:
        _named_miner_version(name, force=True)
    cache["last_uptime_s"] = uptime_s
    single_gpu = len(parsed_devices) == 1
    gpus = [
        _build_gpu_entry(
            idx, name=gname, hashrate_hs=dev.get("hashrate_hs", 0),
            accepted_shares=dev.get("blocks_accepted", accepted_shares if single_gpu else None),
            rejected_shares=dev.get("blocks_rejected", rejected_shares if single_gpu else None),
        )
        for idx, gname, dev in parsed_devices
    ]
    return _build_miner_result(
        "ok", data.get("miner") or name,
        miner_version=_named_miner_version_cache[name]["version"],
        uptime_s=uptime_s,
        algorithms=[_build_algo_entry(
            "keryxhash",
            hashrate_hs=total_hr_hs,
            cpu_hashrate_hs=total_hr_hs if mining_type == "CPU" else 0,
            gpu_hashrate_hs=total_hr_hs if mining_type == "GPU" else 0,
            mining_type=mining_type,
            accepted_shares=accepted_shares,
            rejected_shares=rejected_shares,
        )],
        gpus=gpus,
        synced=data.get("synced"),
        mining_address=data.get("mining_address", ""),
    )
_NAMED_MINER_BLOCK_MAX_PLAUSIBLE_BATCH = 1000
def _collect_named_miner_block_log_stats(name, log_path, mining_type="AUX"):
    """Tails a keryxd-style log for 'Accepted N blocks' lines and sums the counts since the last poll"""
    line_re = re.compile(
        r"^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}\.\d+[+-]\d{2}:\d{2}[ \t]+"
        r"\[[A-Za-z]+\s*\][ \t]+Accepted[ \t]+(\d+)[ \t]+blocks?"
        r"(?:[^\n]*?[ \t](\d+)[ \t]+via[ \t]+submit[ \t]+blocks?)?",
        re.MULTILINE,
    )
    miner_restarted = name in _miner_pid_changed_this_poll
    share_state = _log_event_state.setdefault(
        log_path, {"offset": 0, "accepted_shares": 0, "submit_block_shares": 0}
    )
    new_text = _read_new_log_bytes(log_path, share_state)
    if new_text is None:
        return _build_miner_result(
            "error", name, error=f"could not read log file '{log_path}'",
            miner_version=_named_miner_version(name),
        )
    if share_state.get("reset") or miner_restarted:
        share_state["accepted_shares"] = 0
        share_state["submit_block_shares"] = 0
    for match in line_re.finditer(new_text):
        total_n = int(match.group(1))
        if total_n <= _NAMED_MINER_BLOCK_MAX_PLAUSIBLE_BATCH:
            share_state["accepted_shares"] += total_n
        submit_n = int(match.group(2)) if match.group(2) else 0
        if submit_n <= _NAMED_MINER_BLOCK_MAX_PLAUSIBLE_BATCH:
            share_state["submit_block_shares"] += submit_n
    accepted_shares = share_state["accepted_shares"]
    submit_block_shares = share_state["submit_block_shares"]
    _named_miner_version(name, force=(share_state.get("reset") or miner_restarted))
    return _build_miner_result(
        "ok", name,
        miner_version=_named_miner_version_cache[name]["version"],
        uptime_s=0,
        algorithms=[_build_algo_entry(
            f"{name}-node",
            hashrate_hs=accepted_shares,
            cpu_hashrate_hs=accepted_shares if mining_type == "CPU" else 0,
            gpu_hashrate_hs=accepted_shares if mining_type == "GPU" else 0,
            mining_type=mining_type,
            accepted_shares=submit_block_shares,
        )],
        gpus=[],
        total_hashrate_hs=accepted_shares,
        total_accepted_shares=submit_block_shares,
    )
_CUSTOM_HASHRATE_RE = re.compile(
    r"([\d]+(?:\.\d+)?)\s*([kKmMgGtTpP]?)h(?:ash(?:es)?)?\s*/\s*s(?!\s*/\s*[Ww])", re.IGNORECASE
)
_CUSTOM_ACCEPTED_RE = re.compile(r"accepted[^\d\n]{0,10}(\d+)", re.IGNORECASE)
_CUSTOM_REJECTED_RE = re.compile(r"rejected[^\d\n]{0,10}(\d+)", re.IGNORECASE)
_CUSTOM_HASHRATE_UNIT_MULTIPLIER = {"": 1, "k": 1e3, "m": 1e6, "g": 1e9, "t": 1e12, "p": 1e15}
def _collect_named_miner_generic_log_stats(name, key, log_path, mining_type="AUX"):
    """Best-effort telemetry scraped from a custom miner's own log, taking the last matching"""
    tail_bytes = int(os.environ.get(f"{key}_LOG_TAIL_BYTES", "65536"))
    text = _tail_file(log_path, max_bytes=tail_bytes)
    if text is None:
        return _build_miner_result(
            "error", name or "custom_log", error=f"could not read log file '{log_path}'",
        )
    hashrate_hs = 0.0
    hr_matches = list(_CUSTOM_HASHRATE_RE.finditer(text))
    if hr_matches:
        value, unit = hr_matches[-1].groups()
        hashrate_hs = float(value) * _CUSTOM_HASHRATE_UNIT_MULTIPLIER.get(unit.lower(), 1)
    accepted_shares = 0
    acc_matches = list(_CUSTOM_ACCEPTED_RE.finditer(text))
    if acc_matches:
        accepted_shares = int(acc_matches[-1].group(1))
    rejected_shares = 0
    rej_matches = list(_CUSTOM_REJECTED_RE.finditer(text))
    if rej_matches:
        rejected_shares = int(rej_matches[-1].group(1))
    return _build_miner_result(
        "ok", name or "custom_log",
        miner_version=_named_miner_version(name),
        uptime_s=0,
        algorithms=[_build_algo_entry(
            "unknown",
            hashrate_hs=hashrate_hs,
            cpu_hashrate_hs=hashrate_hs if mining_type == "CPU" else 0,
            gpu_hashrate_hs=hashrate_hs if mining_type == "GPU" else 0,
            mining_type=mining_type,
            accepted_shares=accepted_shares,
            rejected_shares=rejected_shares,
        )],
        gpus=[],
        total_hashrate_hs=hashrate_hs,
        total_accepted_shares=accepted_shares,
        total_rejected_shares=rejected_shares,
    )
ALL_TELEMETRY_GROUPS = {
    "cpu_temp", "cpu_usage", "load", "memory", "uptime", "gpu", "miner", "docker", "network",
    "cpu_service", "gpu_service", "aux_service", "watchdog_service",
}
_OSN_LINE = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(.*)\})?\s+(\S+)')
_OSN_LABEL = re.compile(r'(\w+)="((?:[^"\\]|\\.)*)"')
_OSN_ID_KEYS = ("index", "gpu", "uuid", "bus_id", "pci", "device", "iface", "interface", "name")
def _osn_parse(text):
    for line in text.splitlines():
        if not line or line[0] == "#":
            continue
        m = _OSN_LINE.match(line)
        if not m:
            continue
        name, raw_labels, raw_val = m.groups()
        labels = {k: v.encode().decode("unicode_escape") for k, v in _OSN_LABEL.findall(raw_labels or "")}
        try:
            val = float(raw_val)
        except ValueError:
            continue
        yield name, labels, val
def _osn_num(v):
    try:
        return int(v) if v is not None and v == int(v) else v
    except (ValueError, OverflowError):
        return v
def _osn_service_active():
    try:
        r = subprocess.run(["systemctl", "is-active", OSN_UNIT], capture_output=True, text=True, timeout=2)
        return r.stdout.strip() == "active"
    except Exception:
        return None
def _osn_group(samples, prefix):
    """osn_gpu_temp{index='0'} -> {'0': {'temp': ...}}"""
    out = {}
    for name, labels, val in samples:
        if not name.startswith(prefix):
            continue
        key = next((labels[k] for k in _OSN_ID_KEYS if k in labels), "_")
        field = name[len(prefix):]
        extra = {k: v for k, v in labels.items() if k not in _OSN_ID_KEYS}
        if extra:
            field += "_" + "_".join(extra.values())
        out.setdefault(key, {})[field] = _osn_num(val)
    return out
def _osn_gpus(samples):
    """Per-GPU dict keyed by GPU index (str), already in the universal gpus[] field names, built from"""
    gpus = {}
    def g(labels):
        return gpus.setdefault(str(labels.get("gpu", "0")), {})
    for name, labels, val in samples:
        if not name.startswith("osn_gpu_") or "gpu" not in labels:
            continue
        d = g(labels)
        if labels.get("model"):
            d["name"] = labels["model"]
        if labels.get("uuid"):
            d["uuid"] = labels["uuid"]
        if labels.get("bus_id"):
            d["pci_bus_id"] = labels["bus_id"]
            d["pci_slot"] = labels["bus_id"].lower()
        f = name[len("osn_gpu_"):]
        clk = labels.get("clock")
        if f == "utilization_percent":            d["util"] = int(val)
        elif f == "temperature_celsius":          d["temp"] = int(val)
        elif f == "fan_percent":                  d["fan_percent"] = int(val)
        elif f == "memory_temperature_celsius":   d["mem_temp"] = int(val)
        elif f == "hotspot_temperature_celsius":  d["hotspot_temp"] = int(val)
        elif f == "power_draw_watts":             d["power_watts"] = val
        elif f == "power_limit_watts":            d["power_limit"] = val
        elif f == "power_default_limit_watts":    d["power_limit_default"] = val
        elif f == "clock_hertz" and clk == "graphics":        d["sm_clock"] = int(val / 1e6)
        elif f == "clock_hertz" and clk == "memory":          d["mem_clock"] = int(val / 1e6)
        elif f == "clock_limit_hertz" and clk == "graphics":  d["sm_clock_max"] = int(val / 1e6)
        elif f == "clock_limit_hertz" and clk == "memory":    d["mem_clock_max"] = int(val / 1e6)
        elif f == "memory_total_bytes":           d["vram_total"] = int(val / 1048576)
        elif f == "memory_used_bytes":            d["vram_used"] = int(val / 1048576)
        elif f == "pcie_link_gen":                d["pcie_gen"] = int(val)
        elif f == "pcie_link_gen_max":            d["pcie_gen_max"] = int(val)
        elif f == "pcie_link_width":              d["pcie_width"] = int(val)
        elif f == "pcie_link_width_max":          d["pcie_width_max"] = int(val)
        elif f == "energy_joules_total":          d["energy_joules"] = val
        elif f == "clocks_event_reason" and val:  d.setdefault("throttle_reasons", []).append(labels.get("reason"))
        elif f == "info":
            d["pstate"] = labels.get("pstate")
    return gpus
def collect_osn(timeout=2):
    """Returns the osn stats dict, or None if osn's metrics endpoint isn't reachable"""
    try:
        text = urllib.request.urlopen(OSN_URL, timeout=timeout).read().decode()
    except Exception:
        return None
    samples = list(_osn_parse(text))
    flat = {n: v for n, l, v in samples if not l}
    res = {"up": 1, "service_active": _osn_service_active()}
    info = next((l for n, l, v in samples if n == "osn_info"), {})
    res["version"] = info.get("version")
    res["driver"] = info.get("gpu_driver")
    res["cuda"] = info.get("cuda")
    start = flat.get("osn_start_time_seconds")
    res["uptime_s"] = int(time.time() - start) if start else None
    res["activity"] = _osn_num(flat.get("osn_activity", 0))
    res["link"] = {
        "connected": _osn_num(flat.get("osn_link_connected", 0)),
        "heartbeat_age_s": _osn_num(flat.get("osn_link_heartbeat_age_seconds")),
        "reconnects": _osn_num(flat.get("osn_link_reconnects_total")),
        "rejected": _osn_num(flat.get("osn_link_rejected", 0)),
    }
    res["collect_failed"] = [l.get("part") for n, l, v in samples if n == "osn_collect_failed" and v]
    res["containers_running"] = _osn_num(flat.get("osn_containers_running"))
    res["cpu_load_pct"] = _osn_num(flat.get("osn_cpu_load_percent"))
    res["mem_used"] = _osn_num(flat.get("osn_memory_used_bytes"))
    res["mem_total"] = _osn_num(flat.get("osn_memory_total_bytes"))
    res["disk_free"] = _osn_num(flat.get("osn_docker_disk_free_bytes"))
    res["disk_total"] = _osn_num(flat.get("osn_docker_disk_total_bytes"))
    res["gpu_passthrough"] = _osn_num(flat.get("osn_gpu_passthrough_active", 0))
    if res["gpu_passthrough"] or "gpus" in res["collect_failed"]:
        res["gpus"] = {}
    else:
        res["gpus"] = _osn_gpus(samples)
    res["gpu_vendor"] = info.get("gpu_vendor")
    res["net"] = _osn_group(samples, "osn_network_")
    return res
def _gpu_passthrough_local(base="/sys/bus/pci/devices"):
    """Universal GPU-passthrough check, independent of osn: returns the PCI addresses of every NVIDIA/AMD"""
    try:
        entries = os.listdir(base)
    except OSError:
        return []
    bound = []
    for e in sorted(entries):
        d = os.path.join(base, e)
        try:
            with open(os.path.join(d, "class")) as f:
                cls = f.read().strip()
            if not cls.startswith("0x03"):
                continue
            with open(os.path.join(d, "vendor")) as f:
                vendor = f.read().strip()
            if vendor not in ("0x10de", "0x1002"):
                continue
            drv_link = os.path.join(d, "driver")
            drv = os.path.basename(os.path.realpath(drv_link)) if os.path.exists(drv_link) else ""
        except OSError:
            continue
        if drv == "vfio-pci":
            bound.append(e)
    return bound
def _docker_skip_gpu_enabled():
    """Safety flag DOCKER_SKIP_GPU_STATS (rigcontrol-agent.conf or env), OFF by default"""
    v = (_read_agent_conf_val("DOCKER_SKIP_GPU_STATS") or os.environ.get("DOCKER_SKIP_GPU_STATS", "")).strip().strip("\"'").lower()
    return v in ("1", "true", "yes", "on")
def _block_list_match():
    """BLOCK_LIST (rigcontrol-agent.conf or env, comma separated, default empty): if any running docker"""
    raw = (_read_agent_conf_val("BLOCK_LIST") or os.environ.get("BLOCK_LIST", "")).strip().strip("\"'")
    entries = [e.strip().strip("\"'").lower() for e in raw.split(",") if e.strip().strip("\"'")]
    if not entries:
        return ""
    try:
        rc, out, _ = run('docker ps --format "{{.Image}}"')
    except Exception:
        return ""
    if rc != 0 or not out.strip():
        return ""
    for image in out.strip().splitlines():
        il = image.strip().lower()
        for e in entries:
            if e in il:
                return f"{image.strip()} (BLOCK_LIST '{e}')"
    return ""
def _osn_primary_enabled():
    """OctaSpace node (osn) is the primary source of GPU and system stats (default ON)"""
    v = (_read_agent_conf_val("OSN_PRIMARY") or os.environ.get("OSN_PRIMARY", "")).strip().strip("\"'").lower()
    return v not in ("0", "false", "no", "off")
def _apply_osn_stats(stats, osn, active_groups):
    """osn -> the SAME universal fields the dashboard already reads (gpus[], cpu_usage, memory), so no"""
    if "cpu_usage" in active_groups and osn.get("cpu_load_pct") is not None:
        stats["cpu_usage"] = round(float(osn["cpu_load_pct"]), 1)
    if "memory" in active_groups and osn.get("mem_total"):
        total = float(osn["mem_total"]); used = float(osn.get("mem_used") or 0)
        stats["memory"] = {
            "total_mb": int(total // 1048576),
            "used_mb":  int(used // 1048576),
            "free_mb":  int(max(total - used, 0) // 1048576),
            "percent":  round(used / total * 100, 1),
        }
    if "gpu" not in active_groups or not osn.get("gpus"):
        return
    base = {g.get("index"): g for g in (stats.get("gpus") or [])}
    for key, og in osn["gpus"].items():
        if not str(key).isdigit():
            continue
        idx = int(key)
        g = base.get(idx)
        if g is None:
            g = {"index": idx, "name": f"GPU {idx}", "vendor": (osn.get("gpu_vendor") or "NVIDIA").upper()}
            base[idx] = g
        g.update({k: v for k, v in og.items() if v is not None})
        if not g.get("architecture") and g.get("name"):
            try:
                g["architecture"] = _gpu_architecture_from_name(g["name"])
            except Exception:
                pass
        if osn.get("driver"):
            g["driver_version"] = osn["driver"]
    stats["gpus"] = [base[k] for k in sorted(base)]
    stats["gpu_count"] = len(stats["gpus"])
    stats["gpu_present"] = True
    stats["gpu_stats_skipped"] = False
def _osn_allow_missing_gpu_stats():
    """Agent flag OSN_ALLOW_MISSING_GPU_STATS (default ON)"""
    v = (_read_agent_conf_val("OSN_ALLOW_MISSING_GPU_STATS") or os.environ.get("OSN_ALLOW_MISSING_GPU_STATS", "")).strip().strip("\"'").lower()
    return v not in ("0", "false", "no", "off")
_OSN_STATIC_NO_SMI_CACHE = {}
_BOARD_PARTNER_SUBSYS = {
    "1043": "ASUS", "3842": "EVGA", "1462": "MSI", "1458": "Gigabyte", "19da": "Zotac",
    "196e": "PNY", "10b0": "Palit", "19f1": "Gainward", "1b4c": "Galax", "196d": "Colorful",
    "1c5c": "Inno3D", "10de": "NVIDIA Founders Edition",
}
_BOARD_PARTNER_NAME_HINTS = [
    ("asus", "ASUS"), ("rog ", "ASUS ROG"), ("strix", "ASUS ROG Strix"), ("tuf", "ASUS TUF"),
    ("evga", "EVGA"), ("msi", "MSI"), ("gigabyte", "Gigabyte"), ("aorus", "Gigabyte AORUS"),
    ("zotac", "Zotac"), ("pny", "PNY"), ("galax", "Galax"), ("colorful", "Colorful"),
    ("inno3d", "Inno3D"), ("palit", "Palit"), ("gainward", "Gainward"),
    ("founder", "NVIDIA Founders Edition"),
]
def _board_partner_no_smi(pci_slot, name):
    """Board partner from the card's PCI subsystem ID via lspci (no nvidia-smi), else a guess from the"""
    try:
        if pci_slot:
            slot = ":".join(str(pci_slot).split(":")[-2:]).lower()
            r = subprocess.run(f"lspci -nnv -s {slot}", shell=True, capture_output=True, text=True, timeout=1.0)
            if r.returncode == 0:
                line = next((l.lower() for l in r.stdout.splitlines() if "subsystem:" in l.lower()), "")
                m = re.search(r"\[([0-9a-f]{4}):([0-9a-f]{4})\]", line)
                if m and m.group(1) in _BOARD_PARTNER_SUBSYS:
                    return _BOARD_PARTNER_SUBSYS[m.group(1)]
                for pattern, partner in _BOARD_PARTNER_NAME_HINTS:
                    if pattern in line:
                        return partner
    except Exception:
        pass
    lname = (name or "").lower()
    for pattern, partner in _BOARD_PARTNER_NAME_HINTS:
        if pattern in lname:
            return partner
    return ""
def _vbios_no_smi(pci_slot):
    """Video BIOS version from /proc/driver/nvidia/gpus/<domain:bus:dev.fn>/information (no nvidia-smi)"""
    if not pci_slot:
        return ""
    slot = str(pci_slot).lower()
    candidates = [slot] if slot.count(":") >= 2 else [f"0000:{slot}"]
    for cand in candidates:
        try:
            with open(f"/proc/driver/nvidia/gpus/{cand}/information") as f:
                for line in f:
                    if line.lower().startswith("video bios"):
                        return line.split(":", 1)[1].strip()
        except OSError:
            continue
    return ""
_GPU_STATIC_KEYS = ("name", "uuid", "vendor", "architecture", "board_partner", "vbios_version",
                    "power_limit_min", "power_limit_default", "power_limit_max",
                    "pci_bus_id", "pci_slot", "vram_total", "driver_version")
_gpu_static_cache = {"by_index": {}, "by_uuid": {}, "done": False}
def _ensure_gpu_static_cache():
    """ONE full local GPU read on the first collection after agent start - ALWAYS, regardless of"""
    if _gpu_static_cache["done"]:
        return
    _gpu_static_cache["done"] = True
    try:
        local = collect_gpu_stats()
    except Exception as e:
        print(f"[Telemetry] static GPU cache start-up read failed: {e}")
        return
    for g in local:
        static = {k: g[k] for k in _GPU_STATIC_KEYS if g.get(k) not in (None, "")}
        if g.get("uuid"):
            _gpu_static_cache["by_uuid"][g["uuid"]] = static
        if g.get("index") is not None:
            _gpu_static_cache["by_index"][g["index"]] = static
    print(f"[Telemetry] Cached static GPU stats for {len(local)} gpu(s) from one full start-up read "
          f"(power limits, vbios, board partner, ...) - reused on every poll/refresh")
def _osn_fill_static_from_cache(stats):
    """Always on while osn is primary (independent of OSN_ALLOW_MISSING_GPU_STATS): the start-up full"""
    gpus = stats.get("gpus") or []
    filled = 0
    for g in gpus:
        cached = _gpu_static_cache["by_uuid"].get(g.get("uuid")) or _gpu_static_cache["by_index"].get(g.get("index")) or {}
        for k, v in cached.items():
            if g.get(k) is None:
                g[k] = v
                filled += 1
    return filled
def _osn_fill_without_smi(stats):
    """OSN_ALLOW_MISSING_GPU_STATS=1 only: extra collection that never runs nvidia-smi - board_partner /"""
    gpus = stats.get("gpus") or []
    filled = 0
    for g in gpus:
        key = g.get("uuid") or g.get("index")
        nosmi = _OSN_STATIC_NO_SMI_CACHE.get(key)
        if nosmi is None and (g.get("board_partner") is None or g.get("vbios_version") is None):
            nosmi = {
                "board_partner": _board_partner_no_smi(g.get("pci_slot") or g.get("pci_bus_id"), g.get("name")),
                "vbios_version": _vbios_no_smi(g.get("pci_slot") or g.get("pci_bus_id")),
            }
            _OSN_STATIC_NO_SMI_CACHE[key] = nosmi
        for k, v in (nosmi or {}).items():
            if v and g.get(k) is None:
                g[k] = v
                filled += 1
    need = [g["index"] for g in gpus if g.get("mem_temp") is None and isinstance(g.get("index"), int)]
    if need:
        try:
            temps = _collect_gputemps_vram(need)
        except Exception:
            temps = {}
        for g in gpus:
            if g.get("mem_temp") is None and g.get("index") in temps:
                g["mem_temp"] = temps[g["index"]]
                filled += 1
    return filled
_nvml_state = {"lib": None, "tried": False, "warned": set()}
_NVML_ERR_NAMES = {1: "UNINITIALIZED", 2: "INVALID_ARGUMENT", 3: "NOT_SUPPORTED", 4: "NO_PERMISSION", 6: "NOT_FOUND", 13: "FUNCTION_NOT_FOUND", 999: "UNKNOWN"}
def _nvml_warn_once(msg):
    """Core-offset problems are logged once each (not every poll) so a missing value is explainable"""
    if msg not in _nvml_state["warned"]:
        _nvml_state["warned"].add(msg)
        print(f"[Telemetry] core offset: {msg}")
def _nvml_lib():
    """Lazily loads libnvidia-ml (NVML) once via ctypes and initialises it"""
    if _nvml_state["tried"]:
        return _nvml_state["lib"]
    _nvml_state["tried"] = True
    try:
        import ctypes
        lib = ctypes.CDLL("libnvidia-ml.so.1")
        rc = lib.nvmlInit_v2()
        if rc != 0:
            _nvml_warn_once(f"nvmlInit_v2 failed (rc={rc})")
            return None
        _nvml_state["lib"] = lib
    except Exception as e:
        _nvml_state["lib"] = None
        _nvml_warn_once(f"libnvidia-ml.so.1 load error: {e}")
    return _nvml_state["lib"]
def _nvml_core_offsets(indexes):
    """{gpu_index: core clock offset in MHz} via nvmlDeviceGetGpcClkVfOffset (the offset the driver has"""
    out = {}
    lib = _nvml_lib()
    if lib is None:
        return out
    if not hasattr(lib, "nvmlDeviceGetGpcClkVfOffset"):
        _nvml_warn_once("this NVML/driver has no nvmlDeviceGetGpcClkVfOffset")
        return out
    import ctypes
    for idx in indexes:
        try:
            handle = ctypes.c_void_p()
            rc = lib.nvmlDeviceGetHandleByIndex_v2(ctypes.c_uint(int(idx)), ctypes.byref(handle))
            if rc != 0:
                _nvml_warn_once(f"GPU {idx}: nvmlDeviceGetHandleByIndex_v2 returned {rc} ({_NVML_ERR_NAMES.get(rc, '?')})")
                continue
            off = ctypes.c_int()
            rc = lib.nvmlDeviceGetGpcClkVfOffset(handle, ctypes.byref(off))
            if rc == 0:
                out[idx] = off.value
            else:
                _nvml_warn_once(f"GPU {idx}: nvmlDeviceGetGpcClkVfOffset returned {rc} ({_NVML_ERR_NAMES.get(rc, '?')})")
        except Exception as e:
            _nvml_warn_once(f"GPU {idx}: read error {e}")
            continue
    return out
def _apply_gpu_core_offsets(gpus):
    """Adds 'coreoffset' (MHz, from NVML nvmlDeviceGetGpcClkVfOffset) to each NVIDIA GPU entry in the"""
    idxs = [g["index"] for g in gpus if isinstance(g.get("index"), int) and not g.get("stats_failed") and str(g.get("vendor", "NVIDIA")).upper() == "NVIDIA"]
    if not idxs:
        return
    offsets = _nvml_core_offsets(idxs)
    for g in gpus:
        if g.get("index") in offsets:
            g["coreoffset"] = offsets[g["index"]]
def _stats_source_summary(osn_primary, osn, stats, fill_note="", gpu_skip_reason=""):
    """One-line description of where this poll's stats came from (logged every collection)"""
    n_gpu = len(stats.get("gpus") or [])
    if gpu_skip_reason:
        gpu = f"GPU=NONE ({gpu_skip_reason})"
        sysrc = "CPU/mem=osn" if (osn_primary and osn is not None) else "CPU/mem=local (/proc)"
    elif not osn_primary:
        gpu = f"GPU=local (nvidia-smi/amd, OSN_PRIMARY=0) [{n_gpu} gpus]"
        sysrc = "CPU/mem=local (/proc)"
    elif osn is None:
        gpu = "GPU=-1 values (osn unreachable, no local GPU fallback)"
        sysrc = "CPU/mem=local (/proc, osn unreachable)"
    else:
        if osn.get("gpu_passthrough"):
            gpu = "GPU=NONE (osn reports GPU passthrough - readings stale, no fallback)"
        elif "gpus" in (osn.get("collect_failed") or []):
            gpu = "GPU=-1 values (osn GPU read failed, no fallback)"
        else:
            gpu = f"GPU=osn v{osn.get('version') or '?'} [{n_gpu} gpus]{fill_note}"
        sysrc = "CPU/mem=osn"
    return f"[Telemetry] Stats source: {gpu} | {sysrc} | miners=local API/logs | load/net/uptime/docker=local"
def collect_full_stats(visible_groups=None):
    global gpu_present, gpu_type
    if visible_groups is None:
        active_groups = set(ALL_TELEMETRY_GROUPS)
        requested_label = "ALL (no filter)"
    else:
        active_groups = set(visible_groups) & ALL_TELEMETRY_GROUPS
        requested_label = sorted(active_groups) if active_groups else "NONE"
    telemetry_filtered = active_groups != set(ALL_TELEMETRY_GROUPS)
    stats = {
        "rig":                   RIG_NAME,
        "timestamp":             int(time.time()),
        "exclude_from_totals":   EXCLUDE_FROM_TOTALS,
        "telemetry_filtered":    telemetry_filtered,
        "cpu_temp":              collect_cpu_temp() if "cpu_temp" in active_groups else None,
        "cpu_usage":             collect_cpu_usage() if "cpu_usage" in active_groups else None,
        "load":                  collect_load() if "load" in active_groups else None,
        "memory":                collect_memory() if "memory" in active_groups else None,
        "system_uptime_seconds": collect_system_uptime() if "uptime" in active_groups else None,
        "network":               collect_network() if "network" in active_groups else None,
    }
    _local_pt = _gpu_passthrough_local()
    _osn = None
    try:
        _osn = collect_osn()
    except Exception as e:
        print(f"[Telemetry] osn collection failed: {e}")
    _gpu_passthrough = bool(_local_pt) or bool(_osn and _osn.get("gpu_passthrough"))
    _osn_primary = _osn_primary_enabled()
    _osn_src = _osn if _osn_primary else None
    _docker_gpu_skip = False
    if "gpu" in active_groups and not _gpu_passthrough and _docker_skip_gpu_enabled():
        try:
            _docker_gpu_skip = bool(docker_containers_running() and not _docker_known_miner_running())
        except Exception:
            _docker_gpu_skip = False
    _block_hit = ""
    if "gpu" in active_groups and not _gpu_passthrough:
        try:
            _block_hit = _block_list_match()
        except Exception:
            _block_hit = ""
    _gpu_skip_reason = ""
    if _local_pt:
        _gpu_skip_reason = f"GPU passthrough: {', '.join(_local_pt)} bound to vfio-pci (local check) - no GPU stats collected at all"
    elif _gpu_passthrough:
        _gpu_skip_reason = "osn reports GPU passthrough - no GPU stats collected at all"
    elif _block_hit:
        _gpu_skip_reason = f"docker container {_block_hit} - GPU stats always skipped"
    elif _docker_gpu_skip:
        _gpu_skip_reason = "docker container running that isn't a known miner - GPU stats skipped"
    _gpu_blocked = bool(_gpu_skip_reason)
    if not _gpu_blocked:
        try:
            _ensure_gpu_static_cache()
        except Exception as e:
            print(f"[Telemetry] static GPU cache start-up read failed: {e}")
    if "gpu" in active_groups:
        skip_gpu = _gpu_blocked or _osn_primary
        stats["gpus"] = collect_gpu_stats(skip=skip_gpu)
        if _gpu_passthrough or _block_hit:
            stats["gpus"] = _gpu_passthrough_zeros(_gpu_skip_reason, _local_pt)
        stats["gpu_present"] = gpu_present
        stats["gpu_stats_skipped"] = skip_gpu
        stats["gpu_count"] = len(stats["gpus"]) if stats["gpus"] else _last_gpu_count
    else:
        stats["gpus"] = []
        stats["gpu_present"] = gpu_present
        stats["gpu_stats_skipped"] = True
        stats["gpu_count"] = _last_gpu_count
    if "miner" in active_groups:
        detected_miners = detect_running_miners()
        stats["detected_miners"] = detected_miners
        stats.update(collect_miner_stats_based_on_processes())
        print("\n" + "=" * 60)
        print("CURRENT MINER HASHRATES:")
        print("=" * 60)
        print(f"Detected miner processes: {detected_miners or '(none)'}")
        for key, miner_data in stats.items():
            if key.startswith("miner_") and isinstance(miner_data, dict):
                if miner_data.get("status") == "ok":
                    miner_name = miner_data.get("miner", key[6:])
                    for algo in miner_data.get("algorithms", []):
                        hr = algo.get("hashrate_hs", 0)
                        if hr and hr > 0:
                            print(f"{miner_name.upper()}: {hr:,.0f} H/s - {algo.get('algorithm', 'Unknown')} (miner_version={miner_data.get('miner_version', 'unknown')!r})")
                else:
                    print(f"{key[6:].upper()}: status={miner_data.get('status')} - {miner_data.get('error', miner_data.get('reason', ''))}")
        print("=" * 60)
    else:
        stats["detected_miners"] = []
    stats.update({
        "docker": collect_docker_containers() if "docker" in active_groups else [],
    })
    try:
        if _osn_src is not None:
            _apply_osn_stats(stats, _osn_src, (active_groups - {"gpu"}) if _gpu_blocked else active_groups)
    except Exception as e:
        print(f"[Telemetry] osn apply failed: {e}")
    stats["cpu_service"] = collect_service_uptime(CPU_SERVICE_NAME) if "cpu_service" in active_groups else None
    stats["gpu_service"] = collect_service_uptime(GPU_SERVICE_NAME) if "gpu_service" in active_groups else None
    stats["aux_service"] = collect_service_uptime(AUX_SERVICE_NAME) if "aux_service" in active_groups else None
    stats["watchdog_service"] = collect_service_uptime(WATCHDOG_SERVICE_NAME) if "watchdog_service" in active_groups else None
    _fill_note = ""
    try:
        if _osn_primary and _osn and not _gpu_blocked and _osn.get("gpus") and "gpu" in active_groups:
            _n_static = _osn_fill_static_from_cache(stats)
            _fill_note = f" +{_n_static} static values from start-up cache"
            if _osn_allow_missing_gpu_stats():
                _n = _osn_fill_without_smi(stats)
                _fill_note += f" +{_n} live/no-smi values (gputemps/lspci/proc)"
    except Exception as e:
        print(f"[Telemetry] osn missing-field fill failed: {e}")
    if "gpu" in active_groups and not _gpu_blocked and _osn_primary and not stats.get("gpus"):
        _ph = _gpu_failure_placeholders("osn unreachable" if _osn is None else "osn GPU read failed")
        if _ph:
            stats["gpus"] = _ph
            stats["gpu_count"] = len(_ph)
            stats["gpu_stats_skipped"] = False
    if "gpu" in active_groups and not _gpu_blocked and stats.get("gpus"):
        try:
            _apply_gpu_core_offsets(stats["gpus"])
        except Exception as e:
            print(f"[Telemetry] core offset read failed: {e}")
    print(_stats_source_summary(_osn_primary, _osn, stats, _fill_note, _gpu_skip_reason))
    print(f"[Telemetry] Requested groups: {requested_label} | Collected: {sorted(active_groups) if active_groups else 'NONE'}")
    return stats
EOF
