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
import shutil
gpu_present  = False
gpu_type     = "None"
_gpu_detected = False
_last_gpu_count = 0
EXCLUDE_FROM_TOTALS = True
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
    """Extract the bare host:port from any pool URL string (strips only the scheme prefix, e.g. "stratum+ssl://", if present)."""
    if not pool_str:
        return ""
    if "://" in pool_str:
        return pool_str.split("://")[1]
    return pool_str
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
_GPUTEMPS_BIN = None
_GPUTEMPS_CHECKED = False
def _find_gputemps_binary():
    """Locates the optional 'gputemps' binary (github.com/ThomasBaruzier/gddr6-core-junction-vram-temps),
    used as a fallback VRAM temp source since nvidia-smi's temperature.memory is unsupported on
    virtually all GeForce cards. Cached lookup; returns None if it isn't installed - fully optional."""
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
    """Batch-reads VRAM temps for the given NVML device indexes via gputemps --json. Returns
    {index: celsius} for whichever devices it could read - missing entries mean N/A (binary
    absent, no root, or the sensor unsupported for that GPU/driver)."""
    binpath = _find_gputemps_binary()
    if not binpath or not indexes:
        return {}
    try:
        proc = subprocess.run(
            [binpath, "--once", "--json", "--device", ",".join(str(i) for i in indexes)],
            capture_output=True, text=True, timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {}
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
    missing_mem_temp = [g["index"] for g in gpus if g.get("mem_temp") is None]
    if missing_mem_temp:
        vram_fallback = _collect_gputemps_vram(missing_mem_temp)
        for g in gpus:
            if g["index"] in vram_fallback:
                g["mem_temp"] = vram_fallback[g["index"]]
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
    "teamredminer": "teamredminer",
    "t-rex":        "trex",
    "peakminer":    "peakminer",
}
_custom_miner_lock = threading.Lock()
_CUSTOM_MINER_PROCESS_NAMES = {"cpu": "", "gpu": "", "aux": ""}
def set_custom_miner_process_name(slot, name):
    """Sets/replaces the currently-registered custom-miner process name for
    one slot ("cpu"/"gpu"/"aux"). Safe to call more than once per slot, and
    safe to call while detect_running_miners() is reading it on another
    thread (both take _custom_miner_lock).
    _BUILTIN_MINER_PROCESS_MAP is a permanent registry that is never mutated
    anywhere - this function only ever touches
    _CUSTOM_MINER_PROCESS_NAMES[slot], kept in a completely separate dict so
    the two can never be merged/confused the way a shared dict could be.
    Each of the three slots tracks its own custom-miner name independently
    so more than one unrecognized miner can be collected at once (e.g. GPU
    running keryx-miner while AUX runs keryxd) instead of the first one
    found stealing a single shared name/slot."""
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
            custom_names = dict(_CUSTOM_MINER_PROCESS_NAMES)
        grep_pattern = ("(xmrig|lolminer|bzminer|rigel|srbminer|"
                         "gminer|onezerominer|wildrig|teamredminer|t-rex|keryx-miner|keryxd|peakminer")
        for _slot, _cname in custom_names.items():
            if _cname:
                grep_pattern += "|" + re.escape(_cname)
        grep_pattern += ")"
        result = subprocess.run(
            ["bash", "-c", f"ps aux | grep -E {shlex.quote(grep_pattern)} | grep -v grep"],
            capture_output=True, text=True, timeout=2
        )
        if result.returncode == 0 and result.stdout.strip():
            for line in result.stdout.strip().split('\n'):
                line_lower = line.lower()
                _matched_slot = None
                for _slot, _cname in custom_names.items():
                    if _cname and _cname in line_lower:
                        _matched_slot = _slot
                        break
                if _matched_slot:
                    found[f"custom_log_{_matched_slot}"] = True
                    continue
                for proc_name, miner_name in _BUILTIN_MINER_PROCESS_MAP.items():
                    if proc_name in line_lower:
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
    """Reads only what's been appended to path since the last call. A shrink is checked
    against a small fingerprint of the last bytes we actually read (state['tail_fp']): if
    that fingerprint still appears in the shrunk file, it's an in-place trim (e.g.
    tail -c N > file, same fd the writer still holds) - resume right after the fingerprint
    so an already-seen/already-matched line never gets read (and re-actioned) twice, while
    any genuinely new bytes appended in that same window still come through. If the
    fingerprint isn't found, it's a real restart - start over from byte 0. (Inode alone
    isn't reliable here - a freed inode can be reused immediately by the fresh log, so a
    genuine restart can land on the very same inode number.) Falls back to the old
    size-threshold guess only before we have any fingerprint yet."""
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
def collect_named_custom_miner_stats(slot):
    """Telemetry for the custom miner registered for this slot ("cpu"/"gpu"/"aux",
    via set_custom_miner_process_name()); every setting is looked up fresh in
    rigcontrol-agent.conf on each call under a prefix derived from the
    miner's own name - <NAME>_BIN for the binary, <NAME>_API_HOST/<NAME>_API_PORT
    for a keryx-style JSON stats API, or <NAME>_LOG_PATH for log scraping
    (add <NAME>_LOG_STYLE=blocks for keryxd-style "Accepted N blocks"
    counting instead of generic hashrate scraping). Each slot is resolved
    independently so more than one unrecognized miner (e.g. keryx-miner on
    gpu and keryxd on aux) can be collected at the same time."""
    with _custom_miner_lock:
        name = _CUSTOM_MINER_PROCESS_NAMES.get(slot, "")
    if not name:
        return {"status": "error", "error": f"no custom miner registered for slot '{slot}'"}
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
    """Tails a keryxd-style log for "Accepted N blocks" lines and sums the
    counts since the last poll, offset-tracked via _read_new_log_bytes -
    same as before, this total still feeds hashrate_hs/total_hashrate_hs.

    Newer keryxd builds additionally break that count down by how each
    block was accepted, e.g.:
      2026-08-22 00:41:02.115-04:00 [INFO ] Accepted 4 blocks ...591275976f18aeb3d5d9c3ddce13dc85908597b578c9855caa84b21cee5ccfeb, 2 via relay and 2 via submit block
    "via relay" blocks are just other nodes' finds propagating through -
    they say nothing about this rig's own mining. "via submit block" is
    this node actually submitting a block itself, the real accepted-share
    signal - that sub-count is tracked as a second, separate running
    total and surfaced as accepted_shares/total_accepted_shares,
    alongside (not instead of) the existing hashrate_hs/total_hashrate_hs
    total-blocks-accepted metric above.
    """
    accepted_re = re.compile(r"Accepted\s+(\d+)\s+blocks?", re.IGNORECASE)
    submit_block_re = re.compile(r"(\d+)\s+via\s+submit\s+blocks?", re.IGNORECASE)
    share_state = _log_event_state.setdefault(
        log_path, {"offset": 0, "accepted_shares": 0, "submit_block_shares": 0}
    )
    new_text = _read_new_log_bytes(log_path, share_state)
    if new_text is None:
        return {
            "status": "error",
            "error": f"could not read log file '{log_path}'",
            "miner_version": _named_miner_version(name),
        }
    if share_state.get("reset"):
        share_state["accepted_shares"] = 0
        share_state["submit_block_shares"] = 0
    for match in accepted_re.finditer(new_text):
        share_state["accepted_shares"] += int(match.group(1))
    for match in submit_block_re.finditer(new_text):
        share_state["submit_block_shares"] += int(match.group(1))
    accepted_shares = share_state["accepted_shares"]
    submit_block_shares = share_state["submit_block_shares"]
    _named_miner_version(name, force=share_state.get("reset", False))
    return {
        "status": "ok", "miner": name,
        "miner_version": _named_miner_version_cache[name]["version"],
        "uptime_s": 0,
        "algorithms": [{
            "algorithm":       f"{name}-node",
            "hashrate_hs":     accepted_shares,
            "accepted_shares": submit_block_shares,
        }],
        "gpus": [],
        "total_hashrate_hs":     accepted_shares,
        "total_accepted_shares": submit_block_shares,
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
