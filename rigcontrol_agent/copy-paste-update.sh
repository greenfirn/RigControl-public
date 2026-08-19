sudo systemctl stop rigcloud-agent.service
sudo systemctl disable rigcloud-agent.service
sudo mkdir -p /etc/rigcontrol /var/lib/rigcontrol /run/rigcontrol
sudo tee /etc/rigcontrol/rigcontrol-agent.conf > /dev/null <<'EOF'
BROKER_HOST=10.10.0.10
BROKER_PORT=1883
BROKER_USER=admin
BROKER_PASS=**************
# comma seperated list of gpu stats safe images
OVERRIDE_LIST="miner/miner:latest"
STATS_DB_ENABLED=true
# How many days of local telemetry history to keep before old rows are pruned
STATS_DB_MAX_HISTORY_DAYS=7
STATS_DB_INTERVAL_SECONDS=90
# Minimum seconds between telemetry pulls, prevents overlapping collection calls
MIN_TELEMETRY_PULL_INTERVAL_SECONDS=5
EOF
sudo systemctl restart rigcontrol-agent.service
sudo tee /usr/local/bin/rigcontrol_telemetry.py > /dev/null <<'EOF'
# ========== TELEMETRY ===================================
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
gpu_present  = False
gpu_type     = "None"
_gpu_detected = False
_last_gpu_count = 0
EXCLUDE_FROM_TOTALS = False
CUSTOM_MINER_BASE_DIR = "/opt/miners"
def _read_miner_paths_env(key):
    """Reads <key>="..." from CUSTOM_MINER_BASE_DIR/miner_paths.env (written by 01-miner_install.sh for each confirmed-installed miner), substituting $BASE_DIR back into the literal path; returns "" if the file or key doesn't exist."""
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
CPU_SERVICE_NAME = os.environ.get("CPU_SERVICE_NAME", "docker_events_cpu.service")
GPU_SERVICE_NAME = os.environ.get("GPU_SERVICE_NAME", "docker_events_gpu.service")
WATCHDOG_SERVICE_NAME = os.environ.get("WATCHDOG_SERVICE_NAME", "rigcontrol_watchdog.service")
AUX_SERVICE_NAME = os.environ.get("AUX_SERVICE_NAME", "docker_events_aux.service")
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
    """Extract bare hostname from any pool URL string."""
    if not pool_str:
        return ""
    if "://" in pool_str:
        return pool_str.split("://")[1].split(":")[0]
    return pool_str.split(":")[0]
def normalize_to_hs(value, unit=None):
    """Convert any hash-rate unit to H/s."""
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
def detect_gpu_once():
    """Detect GPU vendor once; cache result in module globals."""
    global gpu_present, gpu_type, _gpu_detected
    if _gpu_detected:
        return gpu_present, gpu_type
    try:
        rc = subprocess.run(
            ["nvidia-smi", "-L"],
            capture_output=True, text=True, timeout=1.0
        )
        if rc.returncode == 0 and "GPU" in rc.stdout:
            gpu_present, gpu_type, _gpu_detected = True, "NVIDIA", True
            return gpu_present, gpu_type
    except Exception:
        pass
    try:
        rc = subprocess.run(
            ["rocm-smi", "--showuniqueid"],
            capture_output=True, text=True, timeout=1.0
        )
        if rc.returncode == 0:
            gpu_present, gpu_type, _gpu_detected = True, "AMD", True
            return gpu_present, gpu_type
    except Exception:
        pass
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
    """Top-level dispatcher; returns list of GPU dicts."""
    global gpu_present, gpu_type, _last_gpu_count
    if skip:
        return []
    detect_gpu_once()
    if not gpu_present:
        _last_gpu_count = 0
        return []
    if gpu_type == "NVIDIA":
        gpus = collect_nvidia_gpu_stats()
    elif gpu_type == "AMD":
        gpus = collect_amd_gpu_stats()
    else:
        gpus = collect_basic_gpu_info()
    _last_gpu_count = len(gpus)
    return gpus
def collect_basic_gpu_info():
    """Minimal GPU record from lspci when no driver is installed."""
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
    """nvidia-smi prints '[Not Supported]' for some fields on some GPUs/drivers; treat that as
    unknown rather than crashing or defaulting to a misleading 0."""
    try:
        return float(raw)
    except ValueError:
        return None
def _gpu_architecture_from_name(name):
    """Best-effort NVIDIA architecture guess from the GPU name string. nvidia-smi's --query-gpu
    has no 'architecture' field (confirmed against --help-query-gpu), and the real way to get it
    (NVML nvmlDeviceGetArchitecture) needs the full ctypes NVML bindings for one label - not worth
    it for a mining-rig-scale set of known GPU names."""
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
def collect_nvidia_gpu_stats():
    """Collect NVIDIA GPU stats via a single nvidia-smi call."""
    cmd = (
        "nvidia-smi --query-gpu=index,uuid,temperature.gpu,temperature.memory,"
        "utilization.gpu,utilization.memory,power.draw,"
        "clocks.sm,clocks.mem,fan.speed,"
        "memory.total,memory.used,driver_version,"
        "name,pci.bus_id,vbios_version,"
        "power.min_limit,power.default_limit,power.max_limit"
        " --format=csv,noheader,nounits"
    )
    rc = subprocess.run(cmd, shell=True, capture_output=True, text=True)
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
                        f"lspci -v -s {pci_slot}",
                        shell=True, capture_output=True, text=True, timeout=1.0
                    )
                    if rc2.returncode == 0:
                        pci_info = rc2.stdout.lower()
                        for pattern, partner in [
                            ("asus", "ASUS"), ("evga", "EVGA"), ("msi", "MSI"),
                            ("gigabyte", "Gigabyte"), ("zotac", "Zotac"),
                            ("pny", "PNY"), ("galax", "Galax"),
                            ("colorful", "Colorful"), ("inno3d", "Inno3D"),
                            ("palit", "Palit"), ("gainward", "Gainward"),
                        ]:
                            if pattern in pci_info:
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
                "pci_bus_id": pci_bus, "pci_slot": pci_slot,
            })
        except (ValueError, IndexError):
            continue
    return gpus
def collect_amd_gpu_stats():
    """Collects AMD GPU stats via a single 'rocm-smi --json' call, falling back to the text-parsing path if --json fails."""
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
    """Text-format fallback for ROCm versions without --json support, using a single 'rocm-smi' call."""
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
    """Return VRAM in MB for common AMD RDNA cards; default 8 GB."""
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
    """Single lspci call to find AMD GPU PCI slot."""
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
    """Read amdgpu driver version from sysfs — no subprocess needed."""
    try:
        with open("/sys/module/amdgpu/version") as f:
            return f.read().strip()
    except Exception:
        pass
    return "unknown"
def get_amd_driver_version() -> str:
    """Public wrapper around _read_amdgpu_driver_version()."""
    return _read_amdgpu_driver_version()
def determine_amd_board_partner(pci_id: str, gpu_name: str) -> str:
    """Identify AIB partner from lspci subsystem info, then GPU name."""
    board_partner = ""
    if pci_id:
        try:
            rc = subprocess.run(
                f"lspci -v -s {pci_id}",
                shell=True, capture_output=True, text=True, timeout=1.0
            )
            if rc.returncode == 0:
                pci_info = rc.stdout.lower()
                for pattern, name in [
                    ("asus", "ASUS"), ("msi", "MSI"),
                    ("gigabyte", "Gigabyte"), ("sapphire", "Sapphire"),
                    ("xfx", "XFX"), ("powercolor", "PowerColor"),
                    ("his", "HIS"), ("visiontek", "VisionTek"),
                    ("club 3d", "Club 3D"), ("biostar", "Biostar"),
                    ("asrock", "ASRock"),
                ]:
                    if pattern in pci_info:
                        board_partner = name
                        break
                if not board_partner and "advanced micro devices" in pci_info:
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
    """Single-pass hwmon scan checking AMD k10temp first, then Intel coretemp/pch."""
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
    """Reads uptime from /proc/uptime."""
    with open("/proc/uptime") as f:
        return float(f.read().split()[0])
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
    """Checks systemd unit `service` and echoes that same name back as "service" in the returned dict so the dashboard knows which unit this rig is reporting against."""
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
_MINER_PROCESS_MAP = {
    "xmrig":        "xmrig",
    "lolminer":     "lolminer",
    "bzminer":      "bzminer",
    "rigel":        "rigel",
    "srbminer":     "srbminer",
    "SRBMiner":     "srbminer",
    "gminer":       "gminer",
    "onezerominer": "onezerominer",
    "wildrig":      "wildrig",
    "teamredminer": "teamredminer",
    "t-rex":        "trex",
    "peakminer":    "peakminer",
}
_BUILTIN_MINER_PROCESS_MAP = dict(_MINER_PROCESS_MAP)
_CUSTOM_MINER_PROCESS_NAME = os.environ.get("CUSTOM_MINER_PROCESS_NAME", "").strip().lower()
if _CUSTOM_MINER_PROCESS_NAME:
    _MINER_PROCESS_MAP = {_CUSTOM_MINER_PROCESS_NAME: "custom_log", **_MINER_PROCESS_MAP}
_custom_miner_lock = threading.Lock()
def set_custom_miner_process_name(name):
    """Sets/replaces the custom-miner process name after module import, since rigcontrol-agent.conf loads after this module does; safe to call more than once, and safe to call while detect_running_miners() is reading the same state on another thread (both take _custom_miner_lock) so a re-resolve can never be read half-applied."""
    global _CUSTOM_MINER_PROCESS_NAME, _MINER_PROCESS_MAP
    with _custom_miner_lock:
        if _CUSTOM_MINER_PROCESS_NAME:
            _MINER_PROCESS_MAP = {
                k: v for k, v in _MINER_PROCESS_MAP.items()
                if not (k == _CUSTOM_MINER_PROCESS_NAME and v == "custom_log")
            }
        _CUSTOM_MINER_PROCESS_NAME = (name or "").strip().lower()
        if _CUSTOM_MINER_PROCESS_NAME:
            _MINER_PROCESS_MAP = {_CUSTOM_MINER_PROCESS_NAME: "custom_log", **_MINER_PROCESS_MAP}
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
    "teamredminer": "teamredminer",
    "team-red-miner":"teamredminer",
    "t-rex":        "trex",
    "trex":         "trex",
    "peakminer":    "peakminer",
}
def _docker_published_miners():
    """Returns {miner_name: True} for running Docker containers matching a known miner image that publish at least one host port."""
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
def docker_containers_running():
    """True if any Docker container is currently running (any image)."""
    rc, out, _ = run("docker ps -q")
    return rc == 0 and bool(out.strip())
_last_detected_miners_set = frozenset()
_miners_set_changed_flag = False
def consume_miners_changed_flag():
    """Returns True if detect_running_miners() has observed the running-miner
    set change since this was last called, then clears the flag (one-shot).
    Lets callers (e.g. custom-miner re-resolution in the agent) react only
    when the running set actually changed instead of re-checking blindly
    on every cycle."""
    global _miners_set_changed_flag
    changed = _miners_set_changed_flag
    _miners_set_changed_flag = False
    return changed
def detect_running_miners():
    """Returns a deduplicated list of currently-running miner identifiers, checking native processes via ps aux and Docker containers via docker ps. Caches the result and flags (see consume_miners_changed_flag) when it differs from the previous call."""
    global _last_detected_miners_set, _miners_set_changed_flag
    found = {}
    try:
        with _custom_miner_lock:
            grep_pattern = ("(xmrig|lolminer|bzminer|rigel|srbminer|"
                             "gminer|onezerominer|wildrig|teamredminer|t-rex|keryx-miner|keryxd|peakminer")
            if _CUSTOM_MINER_PROCESS_NAME:
                grep_pattern += "|" + re.escape(_CUSTOM_MINER_PROCESS_NAME)
            grep_pattern += ")"
            miner_process_map_snapshot = dict(_MINER_PROCESS_MAP)
        result = subprocess.run(
            ["bash", "-c", f"ps aux | grep -E {shlex.quote(grep_pattern)} | grep -v grep"],
            capture_output=True, text=True, timeout=2
        )
        if result.returncode == 0 and result.stdout.strip():
            for line in result.stdout.strip().split('\n'):
                for proc_name, miner_name in miner_process_map_snapshot.items():
                    if proc_name in line.lower():
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
    """Collect stats only for miners currently running."""
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
        "custom_log":   collect_named_custom_miner_stats,
    }
    stats = {}
    for miner in detect_running_miners():
        if miner in collectors:
            try:
                stats[f"miner_{miner}"] = collectors[miner]()
            except Exception as e:
                stats[f"miner_{miner}"] = {"status": "error", "error": str(e)}
    return stats
def collect_bzminer_stats():
    host = os.environ.get("BZMINER_API_HOST", "127.0.0.1")
    port = int(os.environ.get("BZMINER_API_PORT", "4014"))
    try:
        with urllib.request.urlopen(
            f"http://{host}:{port}/status", timeout=2.0
        ) as resp:
            data = json.loads(resp.read().decode())
    except Exception as e:
        return {"status": "offline", "error": str(e)}
    if data.get("method") != "fullstatus":
        return {"status": "unexpected_format", "data": data}
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
            return {
                "algorithm":         pool.get("algorithm", "unknown").lower(),
                "pool":              extract_pool_host(pool.get("current_url", "")),
                "hashrate_hs":       hr,
                "gpu_hashrate_hs":   hr if mtype == "GPU" else 0,
                "cpu_hashrate_hs":   hr if mtype == "CPU" else 0,
                "mining_type":       mtype,
                "accepted_shares":   pool.get("valid_solutions", 0),
                "rejected_shares":   pool.get("rejected_solutions", 0),
                "stale_shares":      pool.get("stale_solutions", 0),
                "invalid_solutions": pool.get("invalid_solutions", 0),
                "difficulty":        pool.get("difficulty", 0),
                "pool_status":       pool.get("status", 0),
                "uptime_s":          pool.get("uptime_s", 0),
            }
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
    for dev in devices:
        dev_hr_list = dev.get("hashrate", []) or []
        hashrate_hs = sum(float(h) for h in dev_hr_list if isinstance(h, (int, float)))
        info = {
            "name":        dev.get("name", "Unknown"),
            "vendor":      dev.get("vendor", 0),
            "status":      dev.get("status", [0])[0] if dev.get("status") else 0,
            "hashrate_hs": hashrate_hs,
            "power":       dev.get("power", 0),
            "temperature": dev.get("core_temp", 0),
            "mem_temp":    dev.get("mem_temp", 0),
            "fan_speed":   dev.get("fan", 0),
            "core_clock":  dev.get("clock_rate", 0),
            "mem_clock":   dev.get("memory_rate", 0),
        }
        (gpu_devices if dev.get("vendor") == 1 else cpu_devices).append(info)
    return {
        "status": "ok", "miner": "bzminer",
        "miner_version":       data.get("bzminer_version", "unknown"),
        "rig_name":            data.get("rig_name", RIG_NAME),
        "uptime_s":            data.get("uptime_s", 0),
        "cuda_driver_version": data.get("cuda_driver_version", 0),
        "cpu_devices": cpu_devices, "gpus": gpu_devices,
        "total_devices": len(devices),
        "algorithms":  algorithms,
        "watchdog_enabled": data.get("watchdog_enabled", False),
    }
def collect_rigel_stats():
    host = os.environ.get("RIGEL_API_HOST", "127.0.0.1")
    port = int(os.environ.get("RIGEL_API_PORT", "5000"))
    try:
        with urllib.request.urlopen(
            f"http://{host}:{port}", timeout=2.0
        ) as resp:
            data = json.loads(resp.read().decode())
    except Exception as e:
        return {"status": "offline", "error": str(e)}
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
        gpus.append({
            "id":               device.get("id", 0),
            "name":             device.get("name", "Unknown GPU"),
            "hashrate_hs":      dhr.get(algo, 0) if isinstance(dhr, dict) else 0,
            "accepted_shares":  ds.get("accepted", 0),
            "rejected_shares":  ds.get("rejected", 0),
            "temperature":      mon.get("core_temperature", 0),
            "mem_temp":         mon.get("memory_temperature", 0),
            "fan_speed":        mon.get("fan_speed", 0),
            "power_usage":      mon.get("power_usage", 0),
            "core_clock":       mon.get("core_clock", 0),
            "mem_clock":        mon.get("memory_clock", 0),
            "state":            device.get("state", "unknown"),
            "pci_address":      device.get("pci_address", ""),
            "total_memory":     device.get("total_mem", 0),
        })
    return {
        "status": "ok", "miner": "rigel",
        "miner_version":       data.get("version", "unknown"),
        "cuda_driver":         data.get("cuda_driver", "unknown"),
        "uptime_s":            data.get("uptime", 0),
        "algorithm":           algo,
        "algorithms": [{
            "algorithm":          algo.lower(),
            "hashrate_hs":        hashrate_hs,
            "pool_hashrate_hs":   pool_hashrate_hs,
            "accepted_shares":    accepted,
            "rejected_shares":    rejected,
            "invalid_shares":     invalid,
            "pool":               pool_host,
            "pool_latency_ms":    pool_latency,
            "pool_state":         pool_state,
        }],
        "gpus":                    gpus,
        "power_usage":             data.get("power_usage", 0),
        "watchdog":                data.get("watchdog", "off"),
        "total_hashrate_hs":       hashrate_hs,
        "total_pool_hashrate_hs":  pool_hashrate_hs,
        "total_accepted_shares":   accepted,
        "total_rejected_shares":   rejected,
    }
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
        return {"status": "offline", "error": "Both GPU and CPU ports unavailable"}
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
            algorithms.append({
                "algorithm":           name.lower(),
                "hashrate_hs":         hs,
                "gpu_hashrate_hs":     hs,
                "cpu_hashrate_hs":     0,
                "accepted_shares":     accepted,
                "rejected_shares":     rejected,
                "avg_find_time":       shares.get("avg_find_time", 0),
                "pool":                extract_pool_host(pool_str),
                "difficulty":          pool_info.get("difficulty", 0),
                "pool_latency_ms":     pool_info.get("latency", 0),
                "pool_uptime":         pool_info.get("uptime", 0),
                "mining_type":         "GPU",
                "source_port":         source_port,
                "gpu_hashrates":       gpu_hashrates or None,
                "gpu_accepted_shares": gpu_accepted_map or None,
                "gpu_rejected_shares": gpu_rejected_map or None,
                "gpu_compute_errors":  gpu_compute_errors or None,
                "gpu_efficiency":      gpu_efficiency or None,
            })
        else:
            threads = {k: v for k, v in block.items()
                       if k.startswith("thread") and isinstance(v, (int, float))}
            algorithms.append({
                "algorithm":        name.lower(),
                "hashrate_hs":      hs,
                "cpu_hashrate_hs":  hs,
                "gpu_hashrate_hs":  0,
                "accepted_shares":  shares.get("accepted", 0),
                "rejected_shares":  shares.get("rejected", 0),
                "avg_find_time":    shares.get("avg_find_time", 0),
                "pool":             extract_pool_host(pool_str),
                "difficulty":       pool_info.get("difficulty", 0),
                "pool_latency_ms":  pool_info.get("latency", 0),
                "pool_uptime":      pool_info.get("uptime", 0),
                "mining_type":      "CPU",
                "source_port":      source_port,
                "thread_hashrates": threads or None,
            })
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
                gpus.append({"index": idx, "hashrate_hs": v})
            break
    return {
        "status":                "ok" if algorithms else "offline",
        "miner":                 "srbminer",
        "miner_version":         source.get("miner_version", "unknown"),
        "rig_name":              source.get("rig_name", RIG_NAME),
        "cpu_port_active":       cpu_status == "ok",
        "gpu_port_active":       gpu_status == "ok",
        "uptime_s":              source.get("mining_time", 0),
        "total_gpu_workers":     source.get("total_gpu_workers", 0),
        "total_cpu_workers":     source.get("total_cpu_workers", 0),
        "algorithms":            algorithms,
        "gpus":                  gpus,
        "total_hashrate_hs":     total_hashrate_hs,
        "total_accepted_shares": total_accepted_shares,
        "total_rejected_shares": total_rejected_shares,
    }
def collect_wildrig_stats():
    host = os.environ.get("WILDRIG_API_HOST", "127.0.0.1")
    port = int(os.environ.get("WILDRIG_API_PORT", "4000"))
    try:
        with urllib.request.urlopen(f"http://{host}:{port}", timeout=2.0) as r:
            data = json.loads(r.read().decode())
    except Exception as e:
        return {"status": "offline", "error": str(e)}
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
        {
            "bus_id":          bus_ids[i] if i < len(bus_ids) else 0,
            "temperature":     temps[i]   if i < len(temps)   else 0,
            "fan_speed":       fans[i]    if i < len(fans)     else 0,
            "power":           powers[i]  if i < len(powers)   else 0,
            "core_clock":      cclks[i]   if i < len(cclks)    else 0,
            "mem_clock":       mclks[i]   if i < len(mclks)    else 0,
            "hashrate_hs":     thread_hr.get(f"thread_{i}", 0),
            "accepted_shares": acc_list[i] if i < len(acc_list) else 0,
            "rejected_shares": rej_list[i] if i < len(rej_list) else 0,
            "invalid_shares":  ign_list[i] if i < len(ign_list) else 0,
        }
        for i in range(max(len(bus_ids), 1))
    ]
    return {
        "status": "ok", "miner": "wildrig",
        "miner_version":     data.get("version", "unknown"),
        "worker_id":         data.get("worker_id", RIG_NAME),
        "uptime_s":          data.get("uptime", 0),
        "algo":              algo,
        "algorithms": [{
            "algorithm":        algo.lower(),
            "hashrate_hs":      hashrate_hs,
            "accepted_shares":  accepted,
            "rejected_shares":  rejected,
            "ignored_shares":   ignored,
            "shares_good":      results.get("shares_good", 0),
            "total_shares":     results.get("shares_total", 0),
            "avg_time":         results.get("avg_time", 0),
            "difficulty":       results.get("diff_current", 0),
            "pool":             extract_pool_host(connection.get("pool", "")),
            "pool_uptime":      connection.get("uptime", 0),
            "pool_latency_ms":  connection.get("ping", 0),
            "thread_hashrates": thread_hr or None,
        }],
        "gpus":                  gpus,
        "connection_failures":   connection.get("failures", 0),
        "total_hashrate_hs":     hashrate_hs,
        "total_accepted_shares": accepted,
        "total_rejected_shares": rejected,
    }
def collect_lolminer_stats():
    host = os.environ.get("LOLMINER_API_HOST", "127.0.0.1")
    port = int(os.environ.get("LOLMINER_API_PORT", "8020"))
    try:
        with urllib.request.urlopen(f"http://{host}:{port}", timeout=2.0) as r:
            data = json.loads(r.read().decode())
    except Exception as e:
        return {"status": "offline", "error": str(e)}
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
        algorithms.append({
            "algorithm":          name.lower(),
            "hashrate_hs":        hr_hs,
            "accepted_shares":    algo_data.get("Total_Accepted", 0),
            "rejected_shares":    algo_data.get("Total_Rejected", 0),
            "stale_shares":       algo_data.get("Total_Stales", 0),
            "error_shares":       algo_data.get("Total_Errors", 0),
            "pool":               extract_pool_host(algo_data.get("Pool", "")),
            "user":               algo_data.get("User", ""),
            "worker":             algo_data.get("Worker", ""),
            "performance_unit":   algo_data.get("Performance_Unit", "Mh/s"),
            "performance_factor": factor,
            "thread_hashrates":   thread_hr or None,
            "worker_accepted":    algo_data.get("Worker_Accepted", []),
            "worker_rejected":    algo_data.get("Worker_Rejected", []),
            "worker_stales":      algo_data.get("Worker_Stales", []),
            "worker_errors":      algo_data.get("Worker_Errors", []),
        })
    gpus = [
        {
            "index":        w.get("Index", 0),
            "name":         w.get("Name", "Unknown GPU"),
            "power":        w.get("Power", 0),
            "core_clock":   w.get("CCLK", 0),
            "mem_clock":    w.get("MCLK", 0),
            "temperature":  w.get("Core_Temp", 0),
            "junction_temp":w.get("Juc_Temp", 0),
            "mem_temp":     w.get("Mem_Temp", 0),
            "fan_speed":    w.get("Fan_Speed", 0),
            "lhr_unlock":   w.get("LHR_Unlock_Pct", 0),
            "dual_factor":  w.get("Dual_Factor", 0),
            "pci_address":  w.get("PCIE_Address", ""),
            "hashrate_hs":  combined_gpu_hr.get(f"gpu_{w.get('Index', 0)}", 0),
        }
        for w in data.get("Workers", [])
    ]
    session = data.get("Session", {})
    return {
        "status": "ok", "miner": "lolminer",
        "miner_version":         data.get("Software", "unknown"),
        "rig_name":              RIG_NAME,
        "uptime_s":              session.get("Uptime", 0),
        "start_time":            session.get("Startup", 0),
        "start_time_str":        session.get("Startup_String", ""),
        "last_update":           session.get("Last_Update", 0),
        "num_workers":           data.get("Num_Workers", 0),
        "num_algorithms":        data.get("Num_Algorithms", 0),
        "algorithms":            algorithms,
        "gpus":                  gpus,
        "total_hashrate_hs":     algorithms[0]["hashrate_hs"]    if algorithms else 0,
        "total_accepted_shares": algorithms[0]["accepted_shares"] if algorithms else 0,
        "total_rejected_shares": algorithms[0]["rejected_shares"] if algorithms else 0,
    }
def collect_onezerominer_stats():
    host = os.environ.get("ONEZEROMINER_API_HOST", "127.0.0.1")
    port = int(os.environ.get("ONEZEROMINER_API_PORT", "3001"))
    try:
        with urllib.request.urlopen(f"http://{host}:{port}", timeout=2.0) as r:
            data = json.loads(r.read().decode())
    except Exception as e:
        return {"status": "offline", "error": str(e)}
    algorithms = []
    combined_gpu_hr = {}
    for algo_data in data.get("algos", []):
        name        = algo_data.get("name", "unknown")
        total_hr    = algo_data.get("total_hashrate", 0)
        device_hr   = algo_data.get("hashrates", [])
        thread_hr   = {f"gpu_{i}": v for i, v in enumerate(device_hr)
                       if isinstance(v, (int, float))}
        combined_gpu_hr.update(thread_hr)
        pool_str    = algo_data.get("pool", "")
        session     = algo_data.get("session", {})
        algorithms.append({
            "algorithm":             name.lower(),
            "hashrate_hs":           total_hr,
            "accepted_shares":       algo_data.get("total_accepted_shares", 0),
            "rejected_shares":       algo_data.get("total_rejected_shares", 0),
            "pool":                  extract_pool_host(pool_str),
            "pool_status":           algo_data.get("pool_status", "unknown"),
            "pool_url":              pool_str,
            "split":                 algo_data.get("split", False),
            "session_active":        session.get("active", False),
            "next_session":          session.get("next_session", 0),
            "thread_hashrates":      thread_hr or None,
            "devices_accepted_shares": algo_data.get("devices_accepted_shares", []),
            "devices_rejected_shares": algo_data.get("devices_rejected_shares", []),
        })
    gpus = [
        {
            "id":          d.get("id", 0),
            "bus_id":      d.get("bus_id", 0),
            "name":        d.get("name", "Unknown GPU"),
            "core_clock":  d.get("cclk", 0),
            "mem_clock":   d.get("mclk", 0),
            "temperature": d.get("temp", 0),
            "mem_temp":    d.get("mem_temp"),
            "fan_speed":   d.get("fan", 0),
            "power":       d.get("power", 0),
            "hashrate_hs": combined_gpu_hr.get(f"gpu_{i}", 0),
        }
        for i, d in enumerate(data.get("devices", []))
    ]
    return {
        "status": "ok", "miner": "onezerominer",
        "miner_version":         data.get("version", "unknown"),
        "name":                  data.get("name", "OneZeroMiner"),
        "start_time":            data.get("start_time", 0),
        "uptime_s":              data.get("uptime_seconds", 0),
        "last_update":           data.get("last_update", 0),
        "algorithms":            algorithms,
        "gpus":                  gpus,
        "total_hashrate_hs":     algorithms[0]["hashrate_hs"]    if algorithms else 0,
        "total_accepted_shares": algorithms[0]["accepted_shares"] if algorithms else 0,
        "total_rejected_shares": algorithms[0]["rejected_shares"] if algorithms else 0,
    }
def collect_gminer_stats():
    host = os.environ.get("GMINER_API_HOST", "127.0.0.1")
    port = int(os.environ.get("GMINER_API_PORT", "10050"))
    try:
        with urllib.request.urlopen(f"http://{host}:{port}/stat", timeout=2.0) as r:
            data = json.loads(r.read().decode())
    except Exception as e:
        return {"status": "offline", "error": str(e)}
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
    algorithms = [{
        "algorithm":          algo.lower(),
        "hashrate_hs":        total_hs,
        "accepted_shares":    data.get("total_accepted_shares", 0),
        "rejected_shares":    data.get("total_rejected_shares", 0),
        "stale_shares":       data.get("total_stale_shares", 0),
        "invalid_shares":     data.get("total_invalid_shares", 0),
        "pool":               extract_pool_host(data.get("server", "")),
        "pool_url":           data.get("server", ""),
        "user":               data.get("user", ""),
        "shares_per_minute":  data.get("shares_per_minute", 0),
        "pool_speed":         data.get("pool_speed", 0),
        "thread_hashrates":   thread_hr or None,
        "device_details":     device_details,
    }]
    gpus = [
        {
            "name":          d.get("name", "Unknown GPU"),
            "hashrate_hs":   d.get("speed", 0),
            "temperature":   d.get("temperature", 0),
            "mem_temp":      d.get("memory_temperature", 0),
            "fan_speed":     d.get("fan", 0),
            "power":         d.get("power_usage", 0),
            "core_clock":    d.get("core_clock", 0),
            "mem_clock":     d.get("memory_clock", 0),
            "accepted_shares":d.get("accepted_shares", 0),
            "rejected_shares":d.get("rejected_shares", 0),
            "bus_id":        d.get("bus_id", ""),
        }
        for d in devices
    ]
    return {
        "status": "ok", "miner": "gminer",
        "miner_version":         data.get("miner", "unknown"),
        "uptime_s":              data.get("uptime", 0),
        "algorithms":            algorithms,
        "gpus":                  gpus,
        "total_hashrate_hs":     total_hs,
        "total_accepted_shares": data.get("total_accepted_shares", 0),
        "total_rejected_shares": data.get("total_rejected_shares", 0),
        "total_stale_shares":    data.get("total_stale_shares", 0),
        "shares_per_minute":     data.get("shares_per_minute", 0),
        "pool_speed":            data.get("pool_speed", 0),
    }
def collect_xmrig_stats():
    """Collect XMRig stats from CPU and/or GPU instances."""
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
        return {"status": "offline", "error": "Both XMRig instances unavailable"}
    def _xmrig_algo(instance_data, instance_type, port):
        algo    = instance_data.get("algo", "unknown")
        hr_info = instance_data.get("hashrate", {})
        totals  = hr_info.get("total", [0, 0, 0])
        hr_hs   = float(totals[0]) if totals and totals[0] is not None else 0
        res     = instance_data.get("results", {})
        good    = res.get("shares_good", 0)
        total_s = res.get("shares_total", 0)
        conn    = instance_data.get("connection", {})
        entry = {
            "algorithm":       algo.lower(),
            "hashrate_hs":     hr_hs,
            "hashrate_1m":     totals[0] if len(totals) > 0 else 0,
            "hashrate_5m":     totals[1] if len(totals) > 1 else 0,
            "hashrate_15m":    totals[2] if len(totals) > 2 else 0,
            "accepted_shares": good,
            "rejected_shares": total_s - good if total_s and good else 0,
            "total_shares":    total_s,
            "avg_time_ms":     res.get("avg_time_ms", 0),
            "difficulty":      res.get("diff_current", 0),
            "pool_latency_ms": conn.get("ping", 0),
            "pool":            extract_pool_host(conn.get("pool", "")),
            "pool_url":        conn.get("pool", ""),
            "instance_type":   instance_type,
            "mining_type":     instance_type,
            "source_port":     port,
        }
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
    return {
        "status": "ok", "miner": "xmrig",
        "miner_version":         source.get("version", "unknown"),
        "worker_id":             source.get("worker_id", RIG_NAME),
        "uptime_s":              source.get("uptime", 0),
        "cpu_instance_active":   cpu_status == "ok",
        "gpu_instance_active":   gpu_status == "ok",
        "algorithms":            algorithms,
        "cpu": {
            "brand":   cpu_info.get("brand", ""),
            "cores":   cpu_info.get("cores", 0),
            "threads": cpu_info.get("threads", 0),
            "aes":     cpu_info.get("aes", False),
            "avx2":    cpu_info.get("avx2", False),
        },
        "system": {
            "memory_total": mem.get("total", 0),
            "memory_free":  mem.get("free", 0),
            "load_1m":  load_avg[0] if len(load_avg) > 0 else 0,
            "load_5m":  load_avg[1] if len(load_avg) > 1 else 0,
            "load_15m": load_avg[2] if len(load_avg) > 2 else 0,
        },
        "total_hashrate_hs":     sum(a["hashrate_hs"]    for a in algorithms),
        "total_accepted_shares": sum(a["accepted_shares"] for a in algorithms),
        "total_rejected_shares": sum(a["rejected_shares"] for a in algorithms),
    }
def collect_teamredminer_stats():
    """TeamRedMiner uses HTTP/0.9 text protocol on port 4028."""
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
        return {"status": "error", "error": str(e)}
    response_text = response.decode('utf-8', errors='ignore')
    parts         = response_text.split('|')
    if len(parts) < 2:
        return {"status": "error", "error": "Invalid response format"}
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
    return {
        "status": "ok", "miner": "teamredminer",
        "miner_version": version,
        "uptime_s":      safe_int(parsed.get('Elapsed', 0)),
        "algorithms": [{
            "algorithm":      algorithm.lower(),
            "hashrate_hs":    hr_hs,
            "accepted_shares":safe_int(parsed.get('Accepted', 0)),
            "rejected_shares":safe_int(parsed.get('Rejected', 0)),
            "hardware_errors":safe_int(parsed.get('Hardware Errors', 0)),
            "utility":        safe_float(parsed.get('Utility')),
            "pool":           pool_name,
        }],
    }
def collect_trex_stats():
    host = os.environ.get("TREX_API_HOST", "127.0.0.1")
    port = int(os.environ.get("TREX_API_PORT", "4067"))
    response = requests.get(f"http://{host}:{port}/summary", timeout=5)
    data     = response.json()
    algo         = data.get("algorithm", "").lower()
    pool         = data.get("active_pool", {})
    pool_url     = pool.get("url", "")
    gpus = [
        {
            "gpu_id":          g.get("device_id", g.get("gpu_id", 0)),
            "index":           g.get("gpu_id", 0),
            "name":            g.get("name", f"GPU {g.get('gpu_id', 0)}"),
            "uuid":            g.get("uuid", ""),
            "pci_bus":         g.get("pci_bus", 0),
            "hashrate_hs":     int(g.get("hashrate", 0)),
            "hashrate_minute": int(g.get("hashrate_minute", 0)),
            "hashrate_hour":   int(g.get("hashrate_hour", 0)),
            "hashrate_day":    int(g.get("hashrate_day", 0)),
            "temperature":     g.get("temperature", 0),
            "fan_speed":       g.get("fan_speed", 0),
            "power_usage":     g.get("power", 0),
            "core_clock":      g.get("cclock", 0),
            "mem_clock":       g.get("mclock", 0),
            "efficiency":      g.get("efficiency", "0"),
            "accepted_shares": g.get("shares", {}).get("accepted_count", 0),
            "rejected_shares": g.get("shares", {}).get("rejected_count", 0),
            "paused":          g.get("paused", False),
        }
        for g in data.get("gpus", [])
    ]
    watchdog = data.get("watchdog_stat", {})
    return {
        "status": "ok", "miner": "trex",
        "miner_version":  data.get("version", ""),
        "cuda_driver":    data.get("driver", ""),
        "rig_name":       RIG_NAME,
        "uptime_s":       data.get("uptime", 0),
        "paused":         data.get("paused", False),
        "gpu_total":      data.get("gpu_total", 0),
        "algorithms": [{
            "algorithm":        algo,
            "hashrate_hs":      int(data.get("hashrate", 0)),
            "hashrate_minute":  int(data.get("hashrate_minute", 0)),
            "hashrate_hour":    int(data.get("hashrate_hour", 0)),
            "hashrate_day":     int(data.get("hashrate_day", 0)),
            "accepted_shares":  data.get("accepted_count", 0),
            "rejected_shares":  data.get("rejected_count", 0),
            "pool":             extract_pool_host(pool_url),
            "pool_url":         pool_url,
            "difficulty":       pool.get("difficulty", "0"),
            "pool_latency_ms":  pool.get("ping", 0),
            "user":             pool.get("user", ""),
            "worker":           pool.get("worker", ""),
        }],
        "gpus": gpus,
        "watchdog": {
            "built_in":      watchdog.get("built_in", True),
            "version":       watchdog.get("wd_version", ""),
            "uptime":        watchdog.get("uptime", 0),
            "total_restarts":watchdog.get("total_restarts", 0),
        },
        "total_hashrate_hs":     int(data.get("hashrate", 0)),
        "total_accepted_shares": data.get("accepted_count", 0),
        "total_rejected_shares": data.get("rejected_count", 0),
    }
def collect_peakminer_stats():
    """Reads PeakMiner's /summary HTTP endpoint; reports invalid_shares as its own field since PeakMiner has no separate rejected counter."""
    host = os.environ.get("PEAKMINER_API_HOST", "127.0.0.1")
    port = int(os.environ.get("PEAKMINER_API_PORT", "4068"))
    try:
        with urllib.request.urlopen(f"http://{host}:{port}/summary", timeout=2.0) as r:
            data = json.loads(r.read().decode())
    except Exception as e:
        return {"status": "offline", "error": str(e)}
    algo     = data.get("algo", "unknown")
    pool     = data.get("pool", {}) or {}
    pool_url = pool.get("url", "")
    gpus = [
        {
            "gpu_id":            g.get("id", 0),
            "index":             g.get("id", 0),
            "name":              g.get("name", f"GPU {g.get('id', 0)}"),
            "pci_bus_id":        g.get("pci_bus_id", ""),
            "hashrate_hs":       g.get("hashrate", 0),
            "hashrate_per_watt": g.get("hashrate_per_watt", 0),
            "accepted_shares":   g.get("accepted_shares", 0),
            "rejected_shares":   0,
            "invalid_shares":    g.get("invalid_shares", 0),
            "temperature":       g.get("temperature_c", 0),
            "fan_speed":         g.get("fan_pct", 0),
            "power_usage":       g.get("power_w", 0),
            "core_clock":        g.get("core_clock_mhz", 0),
            "mem_clock":         g.get("mem_clock_mhz", 0),
            "status":            g.get("status"),
        }
        for g in data.get("gpus", [])
    ]
    return {
        "status": "ok", "miner": "peakminer",
        "miner_version":         data.get("version", "unknown"),
        "rig_name":              RIG_NAME,
        "uptime_s":              data.get("uptime", 0),
        "dev_fee_percent":       data.get("dev_fee_percent", 0),
        "algorithms": [{
            "algorithm":         algo.lower(),
            "hashrate_hs":       data.get("hashrate", 0),
            "hashrate_per_watt": data.get("hashrate_per_watt", 0),
            "accepted_shares":   data.get("accepted_shares", 0),
            "rejected_shares":   0,
            "invalid_shares":    data.get("invalid_shares", 0),
            "efficiency_pct":    data.get("efficiency_pct", 0),
            "effort_pct":        data.get("effort_pct", 0),
            "eta_share_secs":    data.get("eta_share_secs", 0),
            "last_share_at":     data.get("last_share_at"),
            "pool":              extract_pool_host(pool_url),
            "pool_url":          pool_url,
            "difficulty":        pool.get("difficulty", 0),
            "pool_latency_ms":   pool.get("ping_ms", 0),
            "pool_connected":    pool.get("connected", False),
        }],
        "gpus":                  gpus,
        "power_w":               data.get("power_w", 0),
        "total_hashrate_hs":     data.get("hashrate", 0),
        "total_accepted_shares": data.get("accepted_shares", 0),
        "total_rejected_shares": 0,
        "total_invalid_shares":  data.get("invalid_shares", 0),
    }
def _query_binary_version(bin_path):
    """Runs `<bin_path> --version` and returns its first line, or "" on any failure; generic helper also used by _named_miner_version()."""
    try:
        out = subprocess.run(
            [bin_path, "--version"], capture_output=True, text=True, timeout=2.0
        )
        text = (out.stdout or out.stderr or "").strip()
        return text.splitlines()[0] if text else ""
    except Exception:
        return ""
def _sanitize_miner_key(name):
    """Converts a miner name into a valid rigcontrol-agent.conf variable prefix, e.g. "keryx-miner" -> "KERYX_MINER"."""
    return re.sub(r"[^A-Za-z0-9]+", "_", (name or "").strip()).strip("_").upper()
def _named_miner_bin(name):
    """Resolves a named custom miner's binary path via <NAME>_BIN in rigcontrol-agent.conf, falling back to CUSTOM_MINER_BASE_DIR/<name>/current/<name>."""
    if not name:
        return ""
    bin_path = os.environ.get(f"{_sanitize_miner_key(name)}_BIN", "").strip()
    if bin_path:
        return bin_path
    return f"{CUSTOM_MINER_BASE_DIR}/{name}/current/{name}"
_named_miner_version_cache = {}
def _named_miner_version(name, force=False):
    """Caches and returns `<name> --version`'s first line, re-querying only when forced (e.g. on a detected restart)."""
    cache = _named_miner_version_cache.setdefault(name, {"version": "", "queried": False, "last_uptime_s": None})
    if force or not cache["queried"]:
        cache["version"] = _query_binary_version(_named_miner_bin(name))
        cache["queried"] = True
    return cache["version"]
def _tail_file(path, max_bytes=131072):
    """Read the last max_bytes of a file as text (cheap tail, no deps)."""
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
    """Reads only what's been appended to path since the last call, resetting the offset on a real restart (tiny file) but fast-forwarding without re-reading on a size-based trim (large file), distinguished by restart_threshold_bytes."""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            if size < state.get("offset", 0):
                if size < restart_threshold_bytes:
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
        return data.decode("utf-8", errors="ignore")
    except Exception:
        return None
AGENT_CONF_PATH = "/etc/rigcontrol/rigcontrol-agent.conf"
_agent_conf_cache = {"mtime": None, "data": {}}
def _read_agent_conf_val(key):
    """Reads a KEY=value from rigcontrol-agent.conf, only re-reading/re-parsing the file when its mtime has changed since the last call - same live-read intent as docker_events_universal.sh (edited custom-miner settings apply on the next poll, no agent restart needed) without hitting disk on every single call."""
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
def collect_named_custom_miner_stats():
    """Telemetry for the configured custom miner (CUSTOM_MINER_PROCESS_NAME); every setting is looked up fresh in rigcontrol-agent.conf on each call under a prefix derived from the miner's own name - <NAME>_BIN for the binary, <NAME>_API_HOST/<NAME>_API_PORT for a keryx-style JSON stats API, or <NAME>_LOG_PATH for log scraping (add <NAME>_LOG_STYLE=blocks for keryxd-style "Accepted N blocks" counting instead of generic hashrate scraping)."""
    name = _CUSTOM_MINER_PROCESS_NAME
    key = _sanitize_miner_key(name)
    api_host = _read_agent_conf_val(f"{key}_API_HOST") or os.environ.get(f"{key}_API_HOST", "").strip()
    api_port = _read_agent_conf_val(f"{key}_API_PORT") or os.environ.get(f"{key}_API_PORT", "").strip()
    if api_host and api_port:
        return _collect_named_miner_api_stats(name, api_host, int(api_port))
    log_path = _read_agent_conf_val(f"{key}_LOG_PATH") or os.environ.get(f"{key}_LOG_PATH", "").strip()
    log_style = _read_agent_conf_val(f"{key}_LOG_STYLE") or os.environ.get(f"{key}_LOG_STYLE", "").strip()
    if log_style.lower() == "blocks":
        return _collect_named_miner_block_log_stats(name, log_path)
    return _collect_named_miner_generic_log_stats(name, key, log_path)
def _collect_named_miner_api_stats(name, api_host, api_port):
    """Reads a keryx-style JSON /stats API for hashrate and accepted/rejected block counts; temp/fan/power still come from collect_nvidia_gpu_stats()."""
    data = None
    last_err = None
    for path in ("/stats", "/v1/miner/stats"):
        try:
            with urllib.request.urlopen(f"http://{api_host}:{api_port}{path}", timeout=2.0) as r:
                data = json.loads(r.read().decode())
            break
        except Exception as e:
            last_err = e
    if data is None:
        return {
            "status": "error",
            "error": f"{name} API unreachable at {api_host}:{api_port} (/stats, /v1/miner/stats): {last_err}",
            "miner_version": _named_miner_version(name),
        }
    device_re = re.compile(r"#(\d+)\s*\(([^)]+)\)")
    gpus = []
    for i, dev in enumerate(data.get("devices", []) or []):
        m = device_re.search(dev.get("id", "") or "")
        idx  = int(m.group(1)) if m else i
        gname = m.group(2).strip() if m else (dev.get("id") or "")
        gpus.append({
            "gpu_id":      idx,
            "index":       idx,
            "name":        gname,
            "hashrate_hs": dev.get("hashrate_hs", 0),
        })
    gpus.sort(key=lambda g: g["index"])
    total_hr_hs     = data.get("total_hashrate_hs", 0)
    accepted_blocks = data.get("accepted_blocks", 0)
    rejected_blocks = data.get("rejected_blocks", 0)
    uptime_s        = data.get("uptime_s", 0)
    cache = _named_miner_version_cache.setdefault(name, {"version": "", "queried": False, "last_uptime_s": None})
    if cache.get("last_uptime_s") is None or uptime_s < cache["last_uptime_s"]:
        _named_miner_version(name, force=True)
    cache["last_uptime_s"] = uptime_s
    return {
        "status": "ok", "miner": name,
        "miner_version":  _named_miner_version_cache[name]["version"],
        "uptime_s":       uptime_s,
        "synced":         data.get("synced"),
        "mining_address": data.get("mining_address", ""),
        "algorithms": [{
            "algorithm":       "keryxhash",
            "hashrate_hs":     total_hr_hs,
            "accepted_shares": accepted_blocks,
            "rejected_shares": rejected_blocks,
        }],
        "gpus": gpus,
        "total_hashrate_hs":     total_hr_hs,
        "total_accepted_shares": accepted_blocks,
        "total_rejected_shares": rejected_blocks,
    }
def _collect_named_miner_block_log_stats(name, log_path):
    """Tails a keryxd-style log for "Accepted N blocks" lines and sums the counts since the last poll, offset-tracked via _read_new_log_bytes."""
    accepted_re = re.compile(r"Accepted\s+(\d+)\s+blocks?", re.IGNORECASE)
    share_state = _log_event_state.setdefault(log_path, {"offset": 0, "accepted_shares": 0})
    new_text = _read_new_log_bytes(log_path, share_state)
    if new_text is None:
        return {
            "status": "error",
            "error": f"could not read log file '{log_path}'",
            "miner_version": _named_miner_version(name),
        }
    if share_state.get("reset"):
        share_state["accepted_shares"] = 0
    for match in accepted_re.finditer(new_text):
        share_state["accepted_shares"] += int(match.group(1))
    accepted_shares = share_state["accepted_shares"]
    _named_miner_version(name, force=share_state.get("reset", False))
    return {
        "status": "ok", "miner": name,
        "miner_version": _named_miner_version_cache[name]["version"],
        "uptime_s": 0,
        "algorithms": [{
            "algorithm":   f"{name}-node",
            "hashrate_hs": accepted_shares,
        }],
        "gpus": [],
        "total_hashrate_hs": accepted_shares,
    }
_CUSTOM_HASHRATE_RE = re.compile(
    r"([\d]+(?:\.\d+)?)\s*([kKmMgGtTpP]?)h(?:ash(?:es)?)?\s*/\s*s(?!\s*/\s*[Ww])", re.IGNORECASE
)
_CUSTOM_ACCEPTED_RE = re.compile(r"accepted[^\d\n]{0,10}(\d+)", re.IGNORECASE)
_CUSTOM_REJECTED_RE = re.compile(r"rejected[^\d\n]{0,10}(\d+)", re.IGNORECASE)
_CUSTOM_HASHRATE_UNIT_MULTIPLIER = {"": 1, "k": 1e3, "m": 1e6, "g": 1e9, "t": 1e12, "p": 1e15}
def _collect_named_miner_generic_log_stats(name, key, log_path):
    """Best-effort telemetry scraped from a custom miner's own log, taking the last matching hashrate/accepted/rejected line in the tail window; tail size configurable via <NAME>_LOG_TAIL_BYTES."""
    tail_bytes = int(os.environ.get(f"{key}_LOG_TAIL_BYTES", "65536"))
    text = _tail_file(log_path, max_bytes=tail_bytes)
    if text is None:
        return {"status": "error", "error": f"could not read log file '{log_path}'"}
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
    return {
        "status": "ok", "miner": name or "custom_log",
        "miner_version": _named_miner_version(name),
        "uptime_s": 0,
        "algorithms": [{
            "algorithm":       "unknown",
            "hashrate_hs":     hashrate_hs,
            "accepted_shares": accepted_shares,
            "rejected_shares": rejected_shares,
        }],
        "gpus": [],
        "total_hashrate_hs":     hashrate_hs,
        "total_accepted_shares": accepted_shares,
        "total_rejected_shares": rejected_shares,
    }
ALL_TELEMETRY_GROUPS = {
    "cpu_temp", "cpu_usage", "load", "memory", "uptime", "gpu", "miner", "docker",
    "cpu_service", "gpu_service", "aux_service", "watchdog_service",
}
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
    }
    if "gpu" in active_groups:
        skip_gpu = docker_containers_running() and not _docker_published_miners()
        stats["gpus"] = collect_gpu_stats(skip=skip_gpu)
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
        for key, miner_data in stats.items():
            if key.startswith("miner_") and isinstance(miner_data, dict):
                if miner_data.get("status") == "ok":
                    miner_name = miner_data.get("miner", key[6:])
                    for algo in miner_data.get("algorithms", []):
                        hr = algo.get("hashrate_hs", 0)
                        if hr and hr > 0:
                            print(f"{miner_name.upper()}: {hr:,.0f} H/s - {algo.get('algorithm', 'Unknown')}")
        print("=" * 60)
    else:
        stats["detected_miners"] = []
    stats.update({
        "docker": collect_docker_containers() if "docker" in active_groups else [],
    })
    stats["cpu_service"] = collect_service_uptime(CPU_SERVICE_NAME) if "cpu_service" in active_groups else None
    stats["gpu_service"] = collect_service_uptime(GPU_SERVICE_NAME) if "gpu_service" in active_groups else None
    stats["aux_service"] = collect_service_uptime(AUX_SERVICE_NAME) if "aux_service" in active_groups else None
    stats["watchdog_service"] = collect_service_uptime(WATCHDOG_SERVICE_NAME) if "watchdog_service" in active_groups else None
    print(f"[Telemetry] Requested groups: {requested_label} | Collected: {sorted(active_groups) if active_groups else 'NONE'}")
    return stats
EOF
sudo tee /usr/local/bin/rigcontrol_cmd.sh > /dev/null <<'EOF'
#!/bin/bash
set -e
LOG="/var/lib/rigcontrol/rigcontrol_cmd.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
GPU_SERVICE="${GPU_SERVICE_NAME:-docker_events_gpu.service}"
CPU_SERVICE="${CPU_SERVICE_NAME:-docker_events_cpu.service}"
AUX_SERVICE="${AUX_SERVICE_NAME:-docker_events_aux.service}"
WATCHDOG_SERVICE="${WATCHDOG_SERVICE_NAME:-rigcontrol_watchdog.service}"
# Read entire command from STDIN (multi-line safe)
RAW_CMD="$(cat)"
if [[ -z "$RAW_CMD" ]]; then
    echo "No command received"
    exit 1
fi
echo "==================================================" >> "$LOG"
echo "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"
echo "$RAW_CMD" >> "$LOG"
# Parse first line for structured commands
FIRST_LINE="$(echo "$RAW_CMD" | head -n1)"
CMD="$(echo "$FIRST_LINE" | awk '{print $1}')"
ARG="$(echo "$FIRST_LINE" | cut -d' ' -f2-)"
case "$CMD" in
    # GPU Miner Controls
    gpu.start)
        systemctl start "$GPU_SERVICE"
        echo "Started $GPU_SERVICE"
        ;;
    gpu.stop)
        systemctl stop "$GPU_SERVICE"
        echo "Stopped $GPU_SERVICE"
        ;;
    gpu.restart)
        systemctl restart "$GPU_SERVICE"
        echo "Restarted $GPU_SERVICE"
        ;;
    # CPU Miner Controls
    cpu.start)
        systemctl start "$CPU_SERVICE"
        echo "Started $CPU_SERVICE"
        ;;
    cpu.stop)
        systemctl stop "$CPU_SERVICE"
        echo "Stopped $CPU_SERVICE"
        ;;
    cpu.restart)
        systemctl restart "$CPU_SERVICE"
        echo "Restarted $CPU_SERVICE"
        ;;
    # AUX Service Controls
    aux.start)
        systemctl start "$AUX_SERVICE"
        echo "Started $AUX_SERVICE"
        ;;
    aux.stop)
        systemctl stop "$AUX_SERVICE"
        echo "Stopped $AUX_SERVICE"
        ;;
    aux.restart)
        systemctl restart "$AUX_SERVICE"
        echo "Restarted $AUX_SERVICE"
        ;;
    # Watchdog Controls (single unified service - see WATCHDOG_SERVICE)
    watchdog.start)
        systemctl enable "$WATCHDOG_SERVICE"
        systemctl start "$WATCHDOG_SERVICE"
        echo "Enabled + started $WATCHDOG_SERVICE"
        ;;
    watchdog.stop)
        systemctl disable "$WATCHDOG_SERVICE"
        systemctl stop "$WATCHDOG_SERVICE"
        echo "Disabled + stopped $WATCHDOG_SERVICE"
        ;;
    watchdog.restart)
        systemctl restart "$WATCHDOG_SERVICE"
        echo "Restarted $WATCHDOG_SERVICE"
        ;;
    # MODE SWITCHING
    mode.set)
        MODE="$(echo "$ARG" | tr '[:lower:]' '[:upper:]')"
        systemctl stop "$CPU_SERVICE" "$GPU_SERVICE"
        systemctl disable "$CPU_SERVICE" "$GPU_SERVICE"
        if [[ "$MODE" == "CPU" ]]; then
            systemctl enable "$CPU_SERVICE"
            systemctl start "$CPU_SERVICE"
            echo "Mode changed -> CPU"
        elif [[ "$MODE" == "GPU" ]]; then
            systemctl enable "$GPU_SERVICE"
            systemctl start "$GPU_SERVICE"
            echo "Mode changed -> GPU"
        else
            echo "Invalid mode: $ARG"
            exit 1
        fi
        ;;
    # SYSTEM REBOOT
    reboot)
        echo "Rebooting system..."
        systemctl reboot
        ;;
    # RAW MULTI-LINE SHELL COMMAND (DEFAULT)
    *)
        echo "[RAW EXECUTION]"
        bash -c "$RAW_CMD"
        ;;
esac
EOF
sudo chmod +x /usr/local/bin/rigcontrol_cmd.sh
sudo tee /usr/local/bin/rigcontrol_agent.py > /dev/null <<'EOF'
import rigcontrol_telemetry as telemetry
import asyncio
import json
import socket
import sqlite3
import subprocess
import time
import urllib.request
import os
import datetime
from aiomqtt import Client, MqttError
# GLOBAL SETTINGS
BROKER_HOST = "127.0.0.1"
BROKER_PORT = 1883
BROKER_USER = None
BROKER_PASS = None
CMD_SCRIPT = "/usr/local/bin/rigcontrol_cmd.sh"
STATS_DB_PATH = "/var/lib/rigcontrol/rigcontrol_stats.db"
os.makedirs(os.path.dirname(STATS_DB_PATH), exist_ok=True)
STATS_DB_ENABLED = True
STATS_DB_MAX_HISTORY_DAYS = 7
STATS_DB_INTERVAL_SECONDS = 90
MIN_TELEMETRY_PULL_INTERVAL_SECONDS = 5
# LOGGING
def log(msg):
    print(f"[RigControl] {msg}", flush=True)
# CONFIG - load
def load_broker_config():
    path = "/etc/rigcontrol/rigcontrol-agent.conf"
    cfg = {}
    if not os.path.isfile(path):
        return cfg
    try:
        with open(path, "r") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    k, v = line.split("=", 1)
                    v = v.strip()
                    if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
                        v = v[1:-1]
                    cfg[k.strip().upper()] = v
    except Exception as e:
        log(f"Config load error: {e}")
    return cfg
# CONFIG - LOCAL MQTT OR AWS
cfg = load_broker_config()
USE_AWS = "AWS_MQTT_HOST" in cfg
if USE_AWS:
    BROKER_HOST = cfg["AWS_MQTT_HOST"]
    BROKER_PORT = int(cfg.get("AWS_MQTT_PORT", 8883))
    AWS_CERT = cfg["AWS_MQTT_CERT"]
    AWS_KEY  = cfg["AWS_MQTT_KEY"]
    AWS_CA   = cfg["AWS_MQTT_CA"]
    log("[Config] MQTT Mode = AWS IoT Core")
    log(f"[Config] Endpoint = {BROKER_HOST}:{BROKER_PORT}")
else:
    BROKER_HOST = cfg.get("BROKER_HOST", BROKER_HOST)
    BROKER_PORT = int(cfg.get("BROKER_PORT", BROKER_PORT))
    BROKER_USER = cfg.get("BROKER_USER")
    BROKER_PASS = cfg.get("BROKER_PASS")
    log("[Config] MQTT Mode = LOCAL")
    log(f"[Config] Broker = {BROKER_HOST}:{BROKER_PORT}")
telemetry.OVERRIDE_LIST = [
    s.strip().lower()
    for s in cfg.get("OVERRIDE_LIST", "").split(",")
    if s.strip()
]
if telemetry.OVERRIDE_LIST:
    log(f"[Config] OVERRIDE_LIST = {telemetry.OVERRIDE_LIST}")
# CONFIG - CUSTOM MINER (unknown-API log-scraper) DETECTION
def _read_conf_key(path, *keys, gpu_id="0"):
    """Reads a KEY GPU_ID "value" row from rig-gpu.conf/rig-cpu.conf's 3-column format (or a 2-column KEY "value" variant, stored under an ALL fallback), returning the first key in priority order with a resolved value."""
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
        log(f"[Config] Error reading {path}: {e}")
    return ""
def _read_conf_key_json(path, *keys):
    """JSON counterpart to _read_conf_key() for rigs with only rig-gpu.json/rig-cpu.json, mirroring 00-get_rig_conf.sh's miner/custom-miner resolution and returning the first key in priority order with a resolved value."""
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
        log(f"[Config] Error reading {path}: {e}")
    return ""
_custom_miner_slot = ""
_custom_miner_conf_path = ""
_resolved_name = ""
def resolve_custom_miner():
    """Re-resolves the custom-miner slot/name/env vars. Called once at
    startup, then re-run whenever telemetry.consume_miners_changed_flag()
    reports the running-miner process set changed (see publish_status /
    stats_db_periodic_loop) so a miner binary/version change picked up
    while the agent is already running doesn't require an agent restart
    to be detected."""
    global _custom_miner_slot, _custom_miner_conf_path, _resolved_name
    _custom_miner_slot = ""
    _custom_miner_conf_path = ""
    _resolved_name = ""
    for _rig_conf_path in ("/etc/rigcontrol/rig-gpu.conf", "/etc/rigcontrol/rig-cpu.conf", "/etc/rigcontrol/rig-aux.conf"):
        _slot_name = "gpu" if "rig-gpu" in _rig_conf_path else ("cpu" if "rig-cpu" in _rig_conf_path else "aux")
        _override_bin = cfg.get(f"CUSTOM_MINER_BIN_{_slot_name.upper()}", "").strip()
        if _override_bin:
            _resolved_name = os.path.basename(_override_bin.rstrip("/"))
            _rig_conf_path = ""
        else:
            _rig_json_path = _rig_conf_path[:-len(".conf")] + ".json"
            _resolved_name = _read_conf_key_json(_rig_json_path, "CUSTOM_MINER", "MINER")
            if _resolved_name:
                _rig_conf_path = _rig_json_path
            else:
                _resolved_name = _read_conf_key(_rig_conf_path, "CUSTOM_MINER", "MINER")
        if not _resolved_name:
            continue
        _resolved_lower = _resolved_name.strip().lower()
        _already_known = (
            _resolved_lower in telemetry._BUILTIN_MINER_PROCESS_MAP
            or _resolved_lower in set(telemetry._BUILTIN_MINER_PROCESS_MAP.values())
        )
        if _already_known:
            _source_desc = f"CUSTOM_MINER_BIN_{_slot_name.upper()} basename" if _override_bin else str(_rig_conf_path)
            log(f"[Config] {_source_desc} MINER='{_resolved_name}' already has a known collector - not treating as custom")
            continue
        telemetry.set_custom_miner_process_name(_resolved_name)
        _custom_miner_slot = _slot_name
        _custom_miner_conf_path = _rig_conf_path
        if _override_bin:
            log(f"[Config] CUSTOM_MINER_PROCESS_NAME (manual, from CUSTOM_MINER_BIN_{_slot_name.upper()} basename, conf/json skipped) = {_resolved_name}")
        else:
            log(f"[Config] CUSTOM_MINER_PROCESS_NAME (auto-detected from {_rig_conf_path}) = {_resolved_name}")
        break
    else:
        telemetry.set_custom_miner_process_name("")
    if _custom_miner_slot:
        _miner_key = telemetry._sanitize_miner_key(_resolved_name)
        for _cfg_key, _cfg_val in cfg.items():
            if _cfg_key.startswith(f"{_miner_key}_") and _cfg_val.strip():
                os.environ[_cfg_key] = _cfg_val.strip()
                log(f"[Config] {_cfg_key} (rigcontrol-agent.conf) = {_cfg_val.strip()}")
        _custom_bin_override = cfg.get(f"CUSTOM_MINER_BIN_{_custom_miner_slot.upper()}", "").strip()
        if _custom_bin_override and f"{_miner_key}_BIN" not in os.environ:
            os.environ[f"{_miner_key}_BIN"] = _custom_bin_override
            log(f"[Config] {_miner_key}_BIN (from CUSTOM_MINER_BIN_{_custom_miner_slot.upper()}) = {_custom_bin_override}")
        if f"{_miner_key}_LOG_PATH" not in os.environ:
            os.environ[f"{_miner_key}_LOG_PATH"] = f"/run/rigcontrol/{_custom_miner_slot}_miner.log"
            log(f"[Config] {_miner_key}_LOG_PATH (auto-derived from {_custom_miner_slot} slot) = {os.environ[f'{_miner_key}_LOG_PATH']}")
resolve_custom_miner()
# CONFIG - LOCAL STATS DB
STATS_DB_ENABLED = cfg.get("STATS_DB_ENABLED", "true").strip().lower() not in ("false", "0", "no", "off")
try:
    STATS_DB_MAX_HISTORY_DAYS = int(cfg.get("STATS_DB_MAX_HISTORY_DAYS", STATS_DB_MAX_HISTORY_DAYS))
except (TypeError, ValueError):
    STATS_DB_MAX_HISTORY_DAYS = 7
try:
    STATS_DB_INTERVAL_SECONDS = int(cfg.get("STATS_DB_INTERVAL_SECONDS", STATS_DB_INTERVAL_SECONDS))
    if STATS_DB_INTERVAL_SECONDS < 5:
        STATS_DB_INTERVAL_SECONDS = 5
except (TypeError, ValueError):
    STATS_DB_INTERVAL_SECONDS = 90
try:
    MIN_TELEMETRY_PULL_INTERVAL_SECONDS = int(cfg.get("MIN_TELEMETRY_PULL_INTERVAL_SECONDS", MIN_TELEMETRY_PULL_INTERVAL_SECONDS))
    if MIN_TELEMETRY_PULL_INTERVAL_SECONDS < 0:
        MIN_TELEMETRY_PULL_INTERVAL_SECONDS = 0
except (TypeError, ValueError):
    MIN_TELEMETRY_PULL_INTERVAL_SECONDS = 5
log(f"[Config] Local stats DB enabled = {STATS_DB_ENABLED}")
log(f"[Config] Local stats DB max history days = {STATS_DB_MAX_HISTORY_DAYS}")
log(f"[Config] Local stats DB periodic save interval = {STATS_DB_INTERVAL_SECONDS}s")
log(f"[Config] Minimum telemetry pull interval = {MIN_TELEMETRY_PULL_INTERVAL_SECONDS}s")
# CONFIG - SERVICE NAMES
CPU_SERVICE_NAME = cfg.get("CPU_SERVICE_NAME", "").strip() or "docker_events_cpu.service"
GPU_SERVICE_NAME = cfg.get("GPU_SERVICE_NAME", "").strip() or "docker_events_gpu.service"
WATCHDOG_SERVICE_NAME = cfg.get("WATCHDOG_SERVICE_NAME", "").strip() or "rigcontrol_watchdog.service"
AUX_SERVICE_NAME = cfg.get("AUX_SERVICE_NAME", "").strip() or "docker_events_aux.service"
log(f"[Config] CPU_SERVICE_NAME = {CPU_SERVICE_NAME}")
log(f"[Config] GPU_SERVICE_NAME = {GPU_SERVICE_NAME}")
log(f"[Config] WATCHDOG_SERVICE_NAME = {WATCHDOG_SERVICE_NAME}")
log(f"[Config] AUX_SERVICE_NAME = {AUX_SERVICE_NAME}")
telemetry.CPU_SERVICE_NAME = CPU_SERVICE_NAME
telemetry.GPU_SERVICE_NAME = GPU_SERVICE_NAME
telemetry.WATCHDOG_SERVICE_NAME = WATCHDOG_SERVICE_NAME
telemetry.AUX_SERVICE_NAME = AUX_SERVICE_NAME
# TOPICS
TOPIC_PREFIX = "rigcontrol"
RIG_NAME = socket.gethostname()
STATUS_TOPIC = f"{TOPIC_PREFIX}/{RIG_NAME}/status"
CMD_TOPIC_DIRECT = f"{TOPIC_PREFIX}/{RIG_NAME}/cmd"
CMD_TOPIC_ALL = f"{TOPIC_PREFIX}/all/cmd"
CHECK_TOPIC_DIRECT = f"{TOPIC_PREFIX}/{RIG_NAME}/check"
CHECK_TOPIC_ALL = f"{TOPIC_PREFIX}/all/check"
STATS_CONTROL_TOPIC_DIRECT = f"{TOPIC_PREFIX}/{RIG_NAME}/stats_control"
STATS_CONTROL_TOPIC_ALL = f"{TOPIC_PREFIX}/all/stats_control"
STATS_REQUEST_TOPIC_DIRECT = f"{TOPIC_PREFIX}/{RIG_NAME}/stats_request"
STATS_REQUEST_TOPIC_ALL = f"{TOPIC_PREFIX}/all/stats_request"
STATS_RESPONSE_TOPIC = f"{TOPIC_PREFIX}/{RIG_NAME}/stats_response"
RESP_TOPIC   = f"{TOPIC_PREFIX}/{RIG_NAME}/cmd_response"
# RUN SHELL HELPERS (unchanged)
def run(cmd):
    proc = subprocess.run(cmd, shell=True, text=True,
                          stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE)
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
_stats_db_last_cleanup = 0.0
_stats_db_last_save = 0.0
_last_telemetry_pull_ts = 0.0
_telemetry_pull_in_progress = False
def _stats_db_connect():
    conn = sqlite3.connect(STATS_DB_PATH)
    conn.execute('''
        CREATE TABLE IF NOT EXISTS rig_telemetry (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            telemetry_data TEXT NOT NULL
        )
    ''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_telemetry_timestamp ON rig_telemetry(timestamp DESC)')
    return conn
def _stats_db_cleanup(conn, days_to_keep):
    cursor = conn.cursor()
    cursor.execute(
        "DELETE FROM rig_telemetry WHERE timestamp < datetime('now', ?)",
        (f'-{days_to_keep} days',)
    )
    deleted = cursor.rowcount
    conn.commit()
    if deleted:
        log(f"[StatsDB] Cleanup: removed {deleted} entries older than {days_to_keep} days")
def save_stats_locally(payload):
    """Writes one telemetry snapshot to the local SQLite history and prunes rows past the retention window at most once per day, using its own short-lived connection via asyncio.to_thread."""
    global _stats_db_last_cleanup, _stats_db_last_save
    try:
        conn = _stats_db_connect()
        try:
            conn.execute(
                "INSERT INTO rig_telemetry (telemetry_data) VALUES (?)",
                (json.dumps(payload),)
            )
            conn.commit()
            now = time.time()
            _stats_db_last_save = now
            if now - _stats_db_last_cleanup > 86400:
                _stats_db_cleanup(conn, STATS_DB_MAX_HISTORY_DAYS)
                _stats_db_last_cleanup = now
        finally:
            conn.close()
    except Exception as e:
        log(f"[StatsDB] Error saving local telemetry: {e}")
def _iso_to_sqlite_utc(iso_str):
    """Converts an ISO 8601 timestamp to the UTC "YYYY-MM-DD HH:MM:SS" format SQLite writes into rig_telemetry.timestamp."""
    s = iso_str.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    dt = datetime.datetime.fromisoformat(s)
    if dt.tzinfo is not None:
        dt = dt.astimezone(datetime.timezone.utc).replace(tzinfo=None)
    return dt.strftime("%Y-%m-%d %H:%M:%S")
def query_stats_history(days, limit=None, start_date=None):
    """Reads back locally-stored telemetry oldest first, either the last N days or a fixed window starting at start_date if given."""
    conn = _stats_db_connect()
    try:
        cursor = conn.cursor()
        start_sql = None
        if start_date:
            try:
                start_sql = _iso_to_sqlite_utc(start_date)
            except (ValueError, TypeError) as e:
                log(f"[StatsDB] Ignoring unparseable start_date {start_date!r}: {e}")
        if start_sql:
            query = (
                "SELECT timestamp, telemetry_data FROM rig_telemetry "
                "WHERE timestamp >= ? AND timestamp < datetime(?, ?) "
                "ORDER BY timestamp ASC"
            )
            cursor.execute(query, (start_sql, start_sql, f'+{days} days'))
        else:
            query = (
                "SELECT timestamp, telemetry_data FROM rig_telemetry "
                "WHERE timestamp >= datetime('now', ?) ORDER BY timestamp ASC"
            )
            cursor.execute(query, (f'-{days} days',))
        rows = cursor.fetchall()
    finally:
        conn.close()
    if limit is not None and len(rows) > limit > 0:
        n = len(rows)
        if limit == 1:
            rows = [rows[0]]
        else:
            rows = [rows[round(i * (n - 1) / (limit - 1))] for i in range(limit)]
    entries = []
    for ts, data in rows:
        try:
            entries.append({"timestamp": ts, "data": json.loads(data)})
        except Exception:
            continue
    return entries
def _conf_set_line(lines, key, value):
    """Finds KEY= in a list of conf lines and updates it in place, appending a new line if the key isn't present."""
    prefix = f"{key}="
    for i, line in enumerate(lines):
        if line.strip().upper().startswith(prefix.upper()):
            lines[i] = f"{key}={value}\n"
            return lines
    lines.append(f"{key}={value}\n")
    return lines
def set_stats_config(enabled=None, max_history_days=None, interval_seconds=None):
    """Live-updates stats DB settings and persists the new values back into rigcontrol-agent.conf in a single write."""
    global STATS_DB_ENABLED, STATS_DB_MAX_HISTORY_DAYS, STATS_DB_INTERVAL_SECONDS
    changed_keys = {}
    if enabled is not None:
        STATS_DB_ENABLED = bool(enabled)
        log(f"[StatsDB] Local stats DB {'enabled' if STATS_DB_ENABLED else 'disabled'} via MQTT")
        changed_keys["STATS_DB_ENABLED"] = "true" if STATS_DB_ENABLED else "false"
    if max_history_days is not None:
        try:
            days = int(max_history_days)
            if days < 1:
                raise ValueError("must be >= 1")
            STATS_DB_MAX_HISTORY_DAYS = days
            log(f"[StatsDB] Max history days set to {STATS_DB_MAX_HISTORY_DAYS} via MQTT")
            changed_keys["STATS_DB_MAX_HISTORY_DAYS"] = str(STATS_DB_MAX_HISTORY_DAYS)
        except (TypeError, ValueError):
            log(f"[StatsDB] Ignoring invalid max_history_days value: {max_history_days!r}")
    if interval_seconds is not None:
        try:
            secs = int(interval_seconds)
            if secs < 5:
                raise ValueError("must be >= 5")
            STATS_DB_INTERVAL_SECONDS = secs
            log(f"[StatsDB] Periodic save interval set to {STATS_DB_INTERVAL_SECONDS}s via MQTT")
            changed_keys["STATS_DB_INTERVAL_SECONDS"] = str(STATS_DB_INTERVAL_SECONDS)
        except (TypeError, ValueError):
            log(f"[StatsDB] Ignoring invalid interval_seconds value: {interval_seconds!r}")
    if not changed_keys:
        return
    path = "/etc/rigcontrol/rigcontrol-agent.conf"
    try:
        if os.path.isfile(path):
            with open(path, "r") as f:
                lines = f.readlines()
            for key, value in changed_keys.items():
                lines = _conf_set_line(lines, key, value)
            with open(path, "w") as f:
                f.writelines(lines)
    except Exception as e:
        log(f"[StatsDB] Error persisting stats config to conf: {e}")
# RESILIENT PUBLISH HELPER
async def mqtt_publish_resilient(mqtt, topic, payload_str, context):
    """Wraps mqtt.publish() with one retry on a transient disconnect, logging which request failed and waiting briefly for the client's automatic reconnect before retrying."""
    try:
        await mqtt.publish(topic, payload_str)
        return True
    except Exception as e:
        log(f"[MQTT] Publish failed for {context} (topic={topic}): {e} - retrying in 4s")
        await asyncio.sleep(4)
        try:
            await mqtt.publish(topic, payload_str)
            log(f"[MQTT] Retry succeeded for {context}")
            return True
        except Exception as e2:
            log(f"[MQTT] Retry failed for {context}: {e2} - giving up, response lost")
            return False
# ASYNC PUBLISH
async def publish_status(mqtt, reason="periodic", visible_groups=None):
    global _last_telemetry_pull_ts, _telemetry_pull_in_progress
    if _telemetry_pull_in_progress:
        log(f"[Telemetry] Pull already in progress - skipping ({reason})")
        return
    now = time.time()
    elapsed = now - _last_telemetry_pull_ts
    if elapsed < MIN_TELEMETRY_PULL_INTERVAL_SECONDS:
        log(f"[Telemetry] Skipped ({reason}) - {elapsed:.1f}s since last pull, minimum is {MIN_TELEMETRY_PULL_INTERVAL_SECONDS}s")
        return
    _telemetry_pull_in_progress = True
    _last_telemetry_pull_ts = now
    try:
        effective_visible_groups = visible_groups
        if STATS_DB_ENABLED and (time.time() - _stats_db_last_save) >= STATS_DB_INTERVAL_SECONDS:
            effective_visible_groups = None
        try:
            if telemetry.consume_miners_changed_flag():
                await asyncio.to_thread(resolve_custom_miner)
        except Exception as e:
            log(f"[Config] custom miner re-resolve error (continuing with existing state): {e}")
        payload = await asyncio.to_thread(
            telemetry.collect_full_stats, effective_visible_groups
        )
        payload["event"] = reason
        payload["stats_db_enabled"] = STATS_DB_ENABLED
        payload["stats_db_max_history_days"] = STATS_DB_MAX_HISTORY_DAYS
        payload["stats_db_interval_seconds"] = STATS_DB_INTERVAL_SECONDS
        if STATS_DB_ENABLED and not payload.get("telemetry_filtered", False):
            asyncio.create_task(asyncio.to_thread(save_stats_locally, payload))
        status_payload_str = await asyncio.to_thread(json.dumps, payload)
        await mqtt_publish_resilient(mqtt, STATUS_TOPIC, status_payload_str, f"telemetry ({reason})")
        log(f"Telemetry sent ({reason})")
    finally:
        _telemetry_pull_in_progress = False
# ASYNC COMMAND HANDLER (EXTERNAL SCRIPT)
async def handle_command(raw, mqtt):
    log(f"Command received RAW: {raw}")
    try:
        data = json.loads(raw)
    except Exception:
        log("Invalid JSON received")
        return
    cmd_id  = data.get("id", "unknown")
    command = data.get("command")
    if not command:
        log("Command missing 'command'")
        return
    if command.strip() == "refresh":
        visible_groups = data.get("visible_groups")
        await publish_status(mqtt, "refresh-request", visible_groups=visible_groups)
        return
    try:
        proc = await asyncio.to_thread(
            subprocess.run,
            [CMD_SCRIPT],
            input=command,
            capture_output=True,
            text=True,
            env={
                **os.environ,
                "CPU_SERVICE_NAME": CPU_SERVICE_NAME,
                "GPU_SERVICE_NAME": GPU_SERVICE_NAME,
                "WATCHDOG_SERVICE_NAME": WATCHDOG_SERVICE_NAME,
                "AUX_SERVICE_NAME": AUX_SERVICE_NAME,
            }
        )
        response = {
            "id": cmd_id,
            "rig": RIG_NAME,
            "timestamp": int(time.time()),
            "returncode": proc.returncode,
            "stdout": proc.stdout.strip(),
            "stderr": proc.stderr.strip(),
        }
        cmd_response_str = await asyncio.to_thread(json.dumps, response)
        await mqtt_publish_resilient(mqtt, RESP_TOPIC, cmd_response_str, f"cmd response ({cmd_id})")
        log(f"Command executed ({cmd_id})")
        await publish_status(mqtt, "cmd-run")
    except Exception as e:
        log(f"Command execution error: {e}")
# ASYNC STATS CONTROL HANDLER
async def handle_stats_control(raw, mqtt):
    log(f"Stats control message received: {raw}")
    try:
        data = json.loads(raw)
    except Exception:
        log("Invalid JSON received on stats_control topic")
        return
    if not any(k in data for k in ("enabled", "max_history_days", "interval_seconds")):
        log("stats_control message missing 'enabled', 'max_history_days', and 'interval_seconds' - ignoring")
        return
    await asyncio.to_thread(
        set_stats_config,
        data.get("enabled"),
        data.get("max_history_days"),
        data.get("interval_seconds"),
    )
    await publish_status(mqtt, "stats-control")
# ASYNC STATS HISTORY REQUEST HANDLER
async def handle_stats_request(raw, mqtt):
    log(f"Stats history request received: {raw}")
    try:
        data = json.loads(raw)
    except Exception:
        log("Invalid JSON received on stats_request topic")
        return
    req_id = data.get("id", "unknown")
    try:
        days = int(data.get("days"))
        if days < 1:
            raise ValueError("must be >= 1")
    except (TypeError, ValueError):
        log(f"stats_request missing/invalid 'days' value: {data.get('days')!r}")
        error_payload_str = await asyncio.to_thread(json.dumps, {
            "id": req_id,
            "rig": RIG_NAME,
            "error": "missing or invalid 'days' (must be a positive integer)",
        })
        await mqtt_publish_resilient(mqtt, STATS_RESPONSE_TOPIC, error_payload_str, f"stats error response ({req_id})")
        return
    limit = data.get("limit")
    try:
        limit = int(limit) if limit is not None else None
        if limit is not None and limit < 1:
            limit = None
    except (TypeError, ValueError):
        limit = None
    start_date = data.get("start_date")
    entries = await asyncio.to_thread(query_stats_history, days, limit, start_date)
    CHUNK_MAX_BYTES = 150_000
    CHUNK_ENVELOPE_BYTES = 512
    def _build_chunk_payloads():
        chunks = []
        current = []
        current_bytes = CHUNK_ENVELOPE_BYTES
        for entry in entries:
            entry_bytes = len(json.dumps(entry).encode("utf-8")) + 1
            if current and current_bytes + entry_bytes > CHUNK_MAX_BYTES:
                chunks.append(current)
                current = []
                current_bytes = CHUNK_ENVELOPE_BYTES
            current.append(entry)
            current_bytes += entry_bytes
        chunks.append(current)
        total_entries = len(entries)
        chunk_count = len(chunks)
        payloads = []
        for idx, chunk in enumerate(chunks):
            resp = {
                "id": req_id,
                "rig": RIG_NAME,
                "timestamp": int(time.time()),
                "days": days,
                "limit": limit,
                "start_date": start_date,
                "count": total_entries,
                "chunk_index": idx,
                "chunk_count": chunk_count,
                "entries": chunk,
            }
            payloads.append(json.dumps(resp))
        return payloads, total_entries, chunk_count
    chunk_payloads, total_entries, chunk_count = await asyncio.to_thread(_build_chunk_payloads)
    total_bytes = sum(len(p.encode("utf-8")) for p in chunk_payloads)
    log(f"[StatsDB] Sending stats response for {req_id} as {chunk_count} chunk(s): {total_entries} entries, {total_bytes} bytes total")
    publish_started = time.time()
    for i, chunk_payload_str in enumerate(chunk_payloads):
        await mqtt_publish_resilient(
            mqtt, STATS_RESPONSE_TOPIC, chunk_payload_str,
            f"stats response ({req_id}) chunk {i + 1}/{chunk_count}"
        )
        if i < chunk_count - 1:
            await asyncio.sleep(0.02)
    log(f"[StatsDB] Finished publishing {chunk_count} chunk(s) for {req_id} in {time.time() - publish_started:.3f}s")
    if start_date:
        log(f"Stats history sent: {total_entries} entries covering {days} day(s) from {start_date} ({req_id}) in {chunk_count} chunk(s)")
    else:
        log(f"Stats history sent: {total_entries} entries covering last {days} day(s) ({req_id}) in {chunk_count} chunk(s)")
# Publish check
async def publish_check(mqtt, want_docker: bool = False):
    docker_containers = None
    if want_docker:
        docker_containers = await asyncio.to_thread(telemetry.collect_docker_containers)
    payload = {
        "rig": RIG_NAME,
        "type": "check",
        "timestamp": int(time.time()),
        "uptime": int(time.monotonic()),
        "state": "online"
    }
    if docker_containers is not None:
        payload["docker"] = docker_containers
    check_payload_str = await asyncio.to_thread(json.dumps, payload)
    await mqtt_publish_resilient(mqtt, STATUS_TOPIC, check_payload_str, "offline check ping")
    if docker_containers is not None:
        log(f"Offline ping check received - replied online ({len(docker_containers)} docker container(s), no other telemetry collected)")
    else:
        log("Offline ping check received - replied online (no telemetry collected)")
# STATS DB PERIODIC SAVE LOOP
async def stats_db_periodic_loop():
    """Background loop that tops up the local stats DB on its own cadence (STATS_DB_INTERVAL_SECONDS) independent of refresh/cmd-triggered publishes, skipping a cycle if a more recent row already exists."""
    CHECK_EVERY = 5
    while True:
        await asyncio.sleep(CHECK_EVERY)
        if not STATS_DB_ENABLED:
            continue
        elapsed = time.time() - _stats_db_last_save
        if elapsed < STATS_DB_INTERVAL_SECONDS:
            continue
        try:
            try:
                if telemetry.consume_miners_changed_flag():
                    await asyncio.to_thread(resolve_custom_miner)
            except Exception as e:
                log(f"[Config] custom miner re-resolve error (continuing with existing state): {e}")
            payload = await asyncio.to_thread(telemetry.collect_full_stats)
            payload["event"] = "stats-db-periodic"
            payload["stats_db_enabled"] = STATS_DB_ENABLED
            payload["stats_db_max_history_days"] = STATS_DB_MAX_HISTORY_DAYS
            payload["stats_db_interval_seconds"] = STATS_DB_INTERVAL_SECONDS
            await asyncio.to_thread(save_stats_locally, payload)
            log(f"[StatsDB] Periodic save ({STATS_DB_INTERVAL_SECONDS}s interval)")
        except Exception as e:
            log(f"[StatsDB] Periodic collection error: {e}")
# MQTT LOOP (LOCAL BROKER, AUTH OPTIONAL)
async def mqtt_loop():
    while True:
        try:
            log(f"Connecting to MQTT {BROKER_HOST}:{BROKER_PORT}")
            client_kwargs = {
                "hostname": BROKER_HOST,
                "port": BROKER_PORT,
            }
            if USE_AWS:
                client_kwargs["tls_params"] = {
                    "ca_certs": AWS_CA,
                    "certfile": AWS_CERT,
                    "keyfile": AWS_KEY,
                }
            else:
                if BROKER_USER:
                    client_kwargs["username"] = BROKER_USER
                    client_kwargs["password"] = BROKER_PASS
            async with Client(**client_kwargs) as mqtt:
                await mqtt.subscribe(CMD_TOPIC_ALL)
                await mqtt.subscribe(CMD_TOPIC_DIRECT)
                await mqtt.subscribe(CHECK_TOPIC_ALL)
                await mqtt.subscribe(CHECK_TOPIC_DIRECT)
                await mqtt.subscribe(STATS_CONTROL_TOPIC_ALL)
                await mqtt.subscribe(STATS_CONTROL_TOPIC_DIRECT)
                await mqtt.subscribe(STATS_REQUEST_TOPIC_ALL)
                await mqtt.subscribe(STATS_REQUEST_TOPIC_DIRECT)
                log(f"Subscribed → {CMD_TOPIC_ALL}")
                log(f"Subscribed → {CMD_TOPIC_DIRECT}")
                log(f"Subscribed → {CHECK_TOPIC_ALL}")
                log(f"Subscribed → {CHECK_TOPIC_DIRECT}")
                log(f"Subscribed → {STATS_CONTROL_TOPIC_ALL}")
                log(f"Subscribed → {STATS_CONTROL_TOPIC_DIRECT}")
                log(f"Subscribed → {STATS_REQUEST_TOPIC_ALL}")
                log(f"Subscribed → {STATS_REQUEST_TOPIC_DIRECT}")
                async for msg in mqtt.messages:
                    topic = str(msg.topic)
                    payload = msg.payload.decode(errors="ignore")
                    if topic.endswith("/check"):
                        log(f"Offline ping received on {topic}")
                        try:
                            check_data = json.loads(payload) if payload else {}
                        except Exception:
                            check_data = {}
                        want_docker = bool(check_data.get("want_docker", False))
                        asyncio.create_task(publish_check(mqtt, want_docker))
                        continue
                    if topic.endswith("/stats_control"):
                        asyncio.create_task(handle_stats_control(payload, mqtt))
                        continue
                    if topic.endswith("/stats_request"):
                        asyncio.create_task(handle_stats_request(payload, mqtt))
                        continue
                    if topic.endswith("/cmd"):
                        asyncio.create_task(handle_command(payload, mqtt))
                        continue
                    log(f"Ignoring message on unexpected topic: {topic}")
        except MqttError as e:
            log(f"MQTT error: {e} — retrying in 3s")
            await asyncio.sleep(3)
# MAIN
async def main():
    await asyncio.gather(
        mqtt_loop(),
        stats_db_periodic_loop(),
    )
if __name__ == "__main__":
    asyncio.run(main())
EOF
AGENT_VENV="/usr/local/lib/rigcontrol-agent/.venv"
if [ ! -x "$AGENT_VENV/bin/pip" ]; then
    echo "Creating rigcontrol-agent virtual environment at $AGENT_VENV ..."
    sudo mkdir -p "$(dirname "$AGENT_VENV")"
    sudo apt-get update
    sudo apt-get install -y python3-venv
    sudo python3 -m venv --clear "$AGENT_VENV"
    if [ ! -x "$AGENT_VENV/bin/pip" ]; then
        echo "ERROR: $AGENT_VENV/bin/pip still doesn't exist after venv creation - see any ensurepip/apt-get error above. Not starting the agent under a broken interpreter; fix the venv (apt-get install python3-venv) and re-run this script."
        exit 1
    fi
    sudo "$AGENT_VENV/bin/pip" install --upgrade pip
    sudo "$AGENT_VENV/bin/pip" install aiomqtt typing_extensions paho-mqtt requests
    echo "Virtual environment created and dependencies installed."
else
    echo "rigcontrol-agent virtual environment already exists at $AGENT_VENV - skipping dependency install."
fi
sudo tee /etc/systemd/system/rigcontrol-agent.service > /dev/null <<EOF
[Unit]
Description=RigControl MQTT Agent
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$AGENT_VENV/bin/python3 /usr/local/bin/rigcontrol_agent.py
Restart=always
RestartSec=5
User=root
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable rigcontrol-agent.service
sudo systemctl restart rigcontrol-agent.service
