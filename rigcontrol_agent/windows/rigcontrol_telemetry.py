#!/usr/bin/env python3
import subprocess
import json
import urllib.request
import os
import re
import psutil
import time
import socket
import platform
from datetime import datetime
try:
    import wmi
    WMI_AVAILABLE = True
except ImportError:
    WMI_AVAILABLE = False
# ===== USER FLAGS (defaults; env vars / agent conf override where noted) =====
EXCLUDE_FROM_TOTALS = False  # True: leave this rig out of the dashboard totals
KERYX_MINER_BIN_DEFAULT      = r"C:\miners\keryx-miner\keryx-miner.exe"  # default keryx-miner path (env KERYX_MINER_BIN overrides)
KERYX_MINER_SUPR_BIN_DEFAULT = r"C:\miners\keryx-miner-supr-windows-nvidia-pom\keryx-miner-supr.exe"  # default keryx-miner-supr path (env KERYX_MINER_SUPR_BIN overrides)
KERYX_API_HOST_DEFAULT = "127.0.0.1"  # keryx miner stats API host (env KERYX_*_API_HOST overrides)
KERYX_API_PORT_DEFAULT = "3338"  # keryx miner stats API port; must match the miner's --api-bind
CUSTOM_MINER_LOG_PATH_DEFAULT = r"C:\Temp\gpu-miner.log"  # log file scraped for a custom miner without an API (env CUSTOM_MINER_LOG_PATH)
CUSTOM_LOG_MINER_DISPLAY_NAME = "quanpool-miner"  # dashboard name for the custom-log miner
CUSTOM_LOG_MINER_NAMES = ("quanpool-miner", "suprminer-neptune")  # miner names handled by the custom-log collector
GPU_TOOL_PAUSE_SECONDS = 30  # pause after a failed GPU tool call
GPU_TOOL_TIMEOUT_SECONDS = 5  # max seconds per GPU tool call; a timeout blocks the tool until restart
# ===== END USER FLAGS =====
RIG_NAME = socket.gethostname().lower()
def _keryx_bin_path_override():
    """Live read of KERYX_BIN_PATH - see _custom_miner_display_name() below for why this can't be a frozen"""
    return os.environ.get("KERYX_BIN_PATH", "").strip()
def _custom_miner_log_path():
    """Live read of CUSTOM_MINER_LOG_PATH - see _custom_miner_display_name() below for why this can't be a"""
    return os.environ.get("CUSTOM_MINER_LOG_PATH", CUSTOM_MINER_LOG_PATH_DEFAULT)
def _custom_miner_display_name():
    """Live read of CUSTOM_MINER_PROCESS_NAME (dashboard display name for the custom-log collector, e.g"""
    return os.environ.get("CUSTOM_MINER_PROCESS_NAME", "keryx-miner-supr")
MINER_PROCESSES = {
    "xmrig.exe": "xmrig",
    "xmrig": "xmrig",
    "t-rex.exe": "trex",
    "t-rex": "trex",
    "trex.exe": "trex",
    "nbminer.exe": "nbminer",
    "nbminer": "nbminer",
    "lolminer.exe": "lolminer",
    "lolminer": "lolminer",
    "bzminer.exe": "bzminer",
    "bzminer": "bzminer",
    "rigel.exe": "rigel",
    "rigel": "rigel",
    "srbminer.exe": "srbminer",
    "SRBMiner.exe": "srbminer",
    "SRBMiner-MULTI.exe": "srbminer",
    "SRBMiner": "srbminer",
    "SRBMiner-MULTI": "srbminer",
    "gminer.exe": "gminer",
    "gminer": "gminer",
    "onezerominer.exe": "onezerominer",
    "onezerominer": "onezerominer",
    "wildrig.exe": "wildrig",
    "wildrig": "wildrig",
    "keryx-miner-supr.exe": "keryx",
    "keryx-miner-supr": "keryx",
    "keryx-miner.exe": "keryx",
    "keryx-miner": "keryx",
    "keryxd.exe": "keryxd",
    "keryxd": "keryxd",
    "quanpool-miner.exe": "custom_log",
    "quanpool-miner": "custom_log",
    "suprminer-neptune.exe": "custom_log",
    "suprminer-neptune": "custom_log",
}
NON_MINER_PROCESS_EXCLUSIONS = {
    "lolminergui.exe",
    "lolminergui",
}
def detect_running_miners():
    running_miners = {}
    if platform.system() != "Windows":
        for proc in psutil.process_iter(['name']):
            try:
                proc_name = proc.info['name'].lower()
                if proc_name in NON_MINER_PROCESS_EXCLUSIONS:
                    continue
                for miner_proc, miner_name in MINER_PROCESSES.items():
                    if miner_proc.lower() in proc_name:
                        running_miners[miner_name] = True
                        break
            except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
                continue
        return list(running_miners.keys())
    try:
        result = subprocess.run(
            'tasklist /fo csv /nh',
            shell=True,
            capture_output=True,
            text=True,
            timeout=2,
            encoding='utf-8',
            errors='ignore'
        )
        if result.returncode == 0:
            lines = result.stdout.strip().split('\n')
            for line in lines:
                if line:
                    parts = line.strip('"').split('","')
                    if len(parts) >= 1:
                        process_name = parts[0].lower()
                        if process_name in NON_MINER_PROCESS_EXCLUSIONS:
                            continue
                        for miner_proc, miner_name in MINER_PROCESSES.items():
                            if miner_proc.lower() in process_name:
                                running_miners[miner_name] = True
                                break
    except Exception as e:
        print(f"Error detecting miners with tasklist: {e}")
    try:
        for proc in psutil.process_iter(['name']):
            try:
                proc_name = proc.info['name'].lower()
                if proc_name in NON_MINER_PROCESS_EXCLUSIONS:
                    continue
                for miner_proc, miner_name in MINER_PROCESSES.items():
                    if miner_proc.lower() in proc_name:
                        running_miners[miner_name] = True
                        break
            except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
                continue
    except Exception as e:
        print(f"Error detecting miners with psutil: {e}")
    return list(running_miners.keys())
def collect_miner_stats_based_on_processes():
    detected_miners = detect_running_miners()
    miner_stats = {}
    miner_collectors = {
        "xmrig": collect_xmrig_stats,
        "lolminer": collect_lolminer_stats,
        "bzminer": collect_bzminer_stats,
        "rigel": collect_rigel_stats,
        "srbminer": collect_srbminer_stats,
        "gminer": collect_gminer_stats,
        "onezerominer": collect_onezerominer_stats,
        "wildrig": collect_wildrig_stats,
        "keryx": collect_keryx_stats,
        "keryxd": collect_keryxd_stats,
        "custom_log": collect_custom_log_miner_stats,
    }
    for miner_name in detected_miners:
        if miner_name in miner_collectors:
            try:
                stats = miner_collectors[miner_name]()
                miner_stats[f"miner_{miner_name}"] = stats
            except Exception as e:
                miner_stats[f"miner_{miner_name}"] = {
                    "status": "error",
                    "error": f"Failed to collect stats: {str(e)}"
                }
    try:
        cpu_service_result = subprocess.run(
            'sc query CPU_Miner_Service',
            shell=True,
            capture_output=True,
            text=True
        )
        if cpu_service_result.returncode == 0 and "RUNNING" in cpu_service_result.stdout:
            miner_stats["cpu_miner_service"] = {
                "status": "running",
                "service": "CPU_Miner_Service"
            }
    except:
        pass
    try:
        gpu_service_result = subprocess.run(
            'sc query GPU_Miner_Service',
            shell=True,
            capture_output=True,
            text=True
        )
        if gpu_service_result.returncode == 0 and "RUNNING" in gpu_service_result.stdout:
            miner_stats["gpu_miner_service"] = {
                "status": "running",
                "service": "GPU_Miner_Service"
            }
    except:
        pass
    return miner_stats
def collect_service_uptime(service_name):
    try:
        result = subprocess.run(f"sc query {service_name}", shell=True, capture_output=True, text=True)
        if result.returncode != 0:
            return {"state": "unknown", "uptime_seconds": 0}
        state = "unknown"
        for line in result.stdout.splitlines():
            if "STATE" in line:
                if "RUNNING" in line:
                    state = "active"
                elif "STOPPED" in line:
                    state = "inactive"
                break
        uptime_seconds = 0
        if state == "active":
            try:
                ps_result = subprocess.run(
                    f'powershell -command "(Get-CimInstance -ClassName Win32_Service -Filter \'Name=\"{service_name}\"\').ProcessId | ForEach-Object {{ (Get-Process -Id $_).StartTime | Get-Date -UFormat %s }}"',
                    shell=True,
                    capture_output=True,
                    text=True,
                    timeout=3
                )
                if ps_result.returncode == 0 and ps_result.stdout.strip():
                    start_time_unix = float(ps_result.stdout.strip())
                    uptime_seconds = int(time.time() - start_time_unix)
            except:
                pass
        return {
            "state": state,
            "uptime_seconds": uptime_seconds
        }
    except:
        return {"state": "unknown", "uptime_seconds": 0}
def collect_docker_containers():
    containers = []
    try:
        result = subprocess.run("docker ps --format \"{{.Names}}|{{.Image}}|{{.ID}}|{{.Status}}\"",
                               shell=True, capture_output=True, text=True)
        if result.returncode == 0 and result.stdout.strip():
            for line in result.stdout.strip().splitlines():
                try:
                    name, image, cid, status = line.split("|", 3)
                    state = "paused" if "Paused" in status else "running"
                    start_result = subprocess.run(f'docker inspect -f "{{{{.State.StartedAt}}}}" {cid}', 
                                                 shell=True, capture_output=True, text=True)
                    uptime_seconds = None
                    if start_result.returncode == 0 and start_result.stdout.strip():
                        ts = start_result.stdout.strip()
                        try:
                            dt = datetime.fromisoformat(ts.replace('Z', '+00:00'))
                            now = datetime.now(dt.tzinfo)
                            uptime_seconds = int((now - dt).total_seconds())
                        except:
                            pass
                    containers.append({
                        "name": name,
                        "image": image,
                        "state": state,
                        "uptime_seconds": uptime_seconds
                    })
                except:
                    continue
    except:
        pass
    return containers
def collect_system_uptime():
    """Collect system uptime in seconds on Windows - matches Ubuntu version naming"""
    try:
        ps_result = subprocess.run(
            'powershell -command "[Environment]::TickCount / 1000"',
            shell=True,
            capture_output=True,
            text=True,
            timeout=3
        )
        if ps_result.returncode == 0 and ps_result.stdout.strip():
            uptime_seconds = float(ps_result.stdout.strip())
            return uptime_seconds
        if WMI_AVAILABLE:
            import pythoncom
            pythoncom.CoInitialize()
            try:
                w = wmi.WMI()
                os_info = w.Win32_OperatingSystem()[0]
                if hasattr(os_info, 'LastBootUpTime'):
                    boot_time = os_info.LastBootUpTime
                    if boot_time:
                        boot_datetime = datetime.strptime(boot_time.split('.')[0], '%Y%m%d%H%M%S')
                        now = datetime.now()
                        uptime_seconds = int((now - boot_datetime).total_seconds())
                        return uptime_seconds
            finally:
                pythoncom.CoUninitialize()
        result = subprocess.run(
            'net stats server | find "Statistics since"',
            shell=True,
            capture_output=True,
            text=True,
            timeout=3
        )
        if result.returncode == 0 and result.stdout.strip():
            line = result.stdout.strip()
            import re
            match = re.search(r'Statistics since\s+(.+)', line)
            if match:
                boot_time_str = match.group(1).strip()
                try:
                    boot_time = datetime.strptime(boot_time_str, '%m/%d/%Y %I:%M:%S %p')
                    uptime_seconds = int((datetime.now() - boot_time).total_seconds())
                    return uptime_seconds
                except:
                    pass
    except Exception as e:
        print(f"Error collecting system uptime: {e}")
    return 0
def normalize_to_hs(value, unit=None):
    """Convert any hash rate unit to H/s"""
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
            else:
                return val
        unit = unit.lower().strip()
        if unit in ['h/s', 'hs', 'hash', 'hashes']:
            return val
        elif unit in ['kh/s', 'khs', 'kilo']:
            return val * 1e3
        elif unit in ['mh/s', 'mhs', 'mega']:
            return val * 1e6
        elif unit in ['gh/s', 'ghs', 'giga']:
            return val * 1e9
        elif unit in ['th/s', 'ths', 'tera']:
            return val * 1e12
        elif unit in ['ph/s', 'phs', 'peta']:
            return val * 1e15
        else:
            return val
    except (ValueError, TypeError):
        return None
def detect_board_partner(gpu_name, pnp_device_id=None, power_watts=0):
    """Detect board partner from GPU name and/or PNPDeviceID"""
    name_lower = gpu_name.lower()
    board_partner = "NVIDIA"
    name_patterns = {
        "founders edition": "NVIDIA Founders Edition",
        "founder's edition": "NVIDIA Founders Edition",
        "fe ": "NVIDIA Founders Edition",
        "asus": "ASUS",
        "rog strix": "ASUS ROG Strix",
        "strix": "ASUS Strix",
        "rog ": "ASUS ROG",
        "tuf": "ASUS TUF",
        "dual": "ASUS Dual",
        "evga": "EVGA",
        "ftw3": "EVGA FTW3",
        "ftw": "EVGA FTW",
        "xc3": "EVGA XC3",
        "xc": "EVGA XC",
        "kingpin": "EVGA Kingpin",
        "msi": "MSI",
        "suprim x": "MSI Suprim X",
        "suprim": "MSI Suprim",
        "gaming x trio": "MSI Gaming X Trio",
        "ventus": "MSI Ventus",
        "gigabyte": "Gigabyte",
        "aorus": "Gigabyte AORUS",
        "gaming oc": "Gigabyte Gaming OC",
        "windforce": "Gigabyte Windforce",
        "eagle": "Gigabyte Eagle",
        "zotac": "Zotac",
        "amp": "Zotac AMP",
        "trinity": "Zotac Trinity",
        "pny": "PNY",
        "palit": "Palit",
        "gainward": "Gainward",
        "galax": "Galax",
        "inno3d": "Inno3D",
        "colorful": "Colorful",
    }
    for pattern, partner in name_patterns.items():
        if pattern in name_lower:
            return partner
    if pnp_device_id:
        import re
        pnp_lower = pnp_device_id.lower()
        subsys_match = re.search(r'subsys_([0-9a-f]{4})([0-9a-f]{4})', pnp_lower)
        if subsys_match:
            vendor_id = subsys_match.group(2)
            vendor_map = {
                "1043": "ASUS",
                "3842": "EVGA",
                "1462": "MSI",
                "1458": "Gigabyte",
                "19da": "Zotac",
                "196e": "PNY",
                "10b0": "Palit",
                "19f1": "Gainward",
                "1b4c": "Galax",
                "196d": "Colorful",
                "1c5c": "Inno3D",
                "10de": "NVIDIA Founders Edition",
            }
            if vendor_id in vendor_map:
                return vendor_map[vendor_id]
    if "nvidia" in name_lower and not any(brand in name_lower for brand in 
                                         ["asus", "evga", "msi", "gigabyte", "zotac"]):
        return "NVIDIA"
    return board_partner
def _parse_float_or_none(raw):
    """nvidia-smi prints '[N/A]' / '[Not Supported]' for fields a GPU/driver can't report; treat that as"""
    try:
        return float(str(raw).strip())
    except (TypeError, ValueError):
        return None
def _collect_nvidia_power_limits():
    """Returns {gpu_index: {"power_limit_min","power_limit_default","power_limit_max","vbios_version"}}"""
    limits = {}
    try:
        result = subprocess.run(
            'nvidia-smi --query-gpu=index,vbios_version,power.min_limit,power.default_limit,power.max_limit '
            '--format=csv,noheader,nounits',
            shell=True, capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            for line in result.stdout.strip().splitlines():
                f = [x.strip() for x in line.split(",")]
                if len(f) < 5 or not f[0].isdigit():
                    continue
                vb = f[1] if f[1] and not f[1].startswith("[") else None
                limits[int(f[0])] = {
                    "vbios_version": vb,
                    "power_limit_min": _parse_float_or_none(f[2]),
                    "power_limit_default": _parse_float_or_none(f[3]),
                    "power_limit_max": _parse_float_or_none(f[4]),
                }
    except Exception as e:
        print(f"Error querying GPU power limits (csv): {e}")
    try:
        missing = [i for i, v in limits.items()
                   if v["power_limit_min"] is None or v["power_limit_default"] is None or v["power_limit_max"] is None]
        if missing or not limits:
            result = subprocess.run("nvidia-smi -q -d POWER", shell=True, capture_output=True, text=True, timeout=8)
            if result.returncode == 0:
                sections = re.split(r"(?m)^GPU\s+[0-9A-Fa-f:.]+\s*$", result.stdout)[1:]
                keymap = (("power_limit_min", r"Min Power Limit\s*:\s*([0-9.]+)"),
                          ("power_limit_default", r"Default Power Limit\s*:\s*([0-9.]+)"),
                          ("power_limit_max", r"Max Power Limit\s*:\s*([0-9.]+)"))
                for pos, sec in enumerate(sections):
                    entry = limits.setdefault(pos, {"vbios_version": None, "power_limit_min": None,
                                                    "power_limit_default": None, "power_limit_max": None})
                    for key, rx in keymap:
                        if entry[key] is None:
                            m = re.search(rx, sec)
                            if m:
                                entry[key] = float(m.group(1))
    except Exception as e:
        print(f"Error querying GPU power limits (-q): {e}")
    return limits
def _collect_nvidia_power_draw():
    """Returns {gpu_index: watts} for GPUs whose plain "power.draw" came back [N/A]/0"""
    draw = {}
    try:
        result = subprocess.run(
            'nvidia-smi --query-gpu=index,power.draw.instant,power.draw.average --format=csv,noheader,nounits',
            shell=True, capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            for line in result.stdout.strip().splitlines():
                f = [x.strip() for x in line.split(",")]
                if len(f) < 3 or not f[0].isdigit():
                    continue
                for raw in (f[1], f[2]):
                    v = _parse_float_or_none(raw)
                    if v is not None and v > 0:
                        draw[int(f[0])] = v
                        break
    except Exception as e:
        print(f"Error querying GPU power draw (csv): {e}")
    try:
        result = subprocess.run("nvidia-smi -q -d POWER", shell=True, capture_output=True, text=True, timeout=8)
        if result.returncode == 0:
            sections = re.split(r"(?m)^GPU\s+[0-9A-Fa-f:.]+\s*$", result.stdout)[1:]
            for pos, sec in enumerate(sections):
                if pos in draw:
                    continue
                for label in ("Instantaneous Power Draw", "Average Power Draw", "Power Draw"):
                    m = re.search(r"(?m)^\s*" + label + r"\s*:\s*([0-9.]+)\s*W", sec)
                    if m and float(m.group(1)) > 0:
                        draw[pos] = float(m.group(1))
                        break
    except Exception as e:
        print(f"Error querying GPU power draw (-q): {e}")
    return draw
def _collect_nvidia_core_temps():
    """Returns {gpu_index: core_temp_c} read from the "nvidia-smi -q -d TEMPERATURE" text report ("GPU"""
    temps = {}
    try:
        result = subprocess.run("nvidia-smi -q -d TEMPERATURE", shell=True, capture_output=True, text=True, timeout=8)
        if result.returncode == 0:
            sections = re.split(r"(?m)^GPU\s+[0-9A-Fa-f:.]+\s*$", result.stdout)[1:]
            for pos, sec in enumerate(sections):
                m = re.search(r"(?m)^\s*GPU Current Temp\s*:\s*(-?\d+(?:\.\d+)?)", sec)
                if m and float(m.group(1)) > 0:
                    temps[pos] = int(round(float(m.group(1))))
    except Exception as e:
        print(f"Error querying GPU core temp (-q): {e}")
    return temps
_nvml_state = {"lib": None, "tried": False, "warned": set()}
_NVML_ERR_NAMES = {1: "UNINITIALIZED", 2: "INVALID_ARGUMENT", 3: "NOT_SUPPORTED", 4: "NO_PERMISSION", 6: "NOT_FOUND", 13: "FUNCTION_NOT_FOUND", 999: "UNKNOWN"}
def _nvml_warn_once(msg):
    """Core-offset problems are logged once each (not every poll) so a missing value is explainable"""
    if msg not in _nvml_state["warned"]:
        _nvml_state["warned"].add(msg)
        print(f"[Telemetry] core offset: {msg}")
def _nvml_lib():
    """Lazily loads nvml.dll (NVML) once via ctypes and initialises it"""
    if _nvml_state["tried"]:
        return _nvml_state["lib"]
    _nvml_state["tried"] = True
    try:
        import ctypes
        import glob
        sysroot = os.environ.get("SystemRoot", r"C:\Windows")
        progfiles = os.environ.get("ProgramFiles", r"C:\Program Files")
        store = sorted(glob.glob(os.path.join(sysroot, "System32", "DriverStore", "FileRepository", "nv*", "nvml.dll")),
                       key=lambda p: os.path.getmtime(p), reverse=True)
        for path in (["nvml.dll",
                      os.path.join(sysroot, "System32", "nvml.dll"),
                      os.path.join(progfiles, "NVIDIA Corporation", "NVSMI", "nvml.dll")] + store):
            try:
                lib = ctypes.CDLL(path)
            except OSError as e:
                _nvml_warn_once(f"could not load {path}: {e}")
                continue
            rc = lib.nvmlInit_v2()
            if rc == 0:
                _nvml_state["lib"] = lib
                _nvml_warn_once(f"NVML loaded from {path}")
                break
            _nvml_warn_once(f"nvmlInit_v2 failed in {path} (rc={rc})")
    except Exception as e:
        _nvml_state["lib"] = None
        _nvml_warn_once(f"NVML load error: {e}")
    if _nvml_state["lib"] is None:
        _nvml_warn_once("nvml.dll not found/initialised - no core offsets")
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
_gpu_tool_state = {}
def _gpu_tool_allowed(tool):
    """Safety guard for local GPU tool calls (nvidia-smi)"""
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
_last_gpu_count = 0
def _gpu_failure_placeholders(reason):
    """When a GPU stats source FAILS (tool paused/blocked/failed/timed out, or osn unreachable) report"""
    idxs = list(range(_last_gpu_count or 0))
    out = []
    for i in idxs:
        st = {}
        out.append({
            "index": i, "name": st.get("name") or f"GPU {i}", "vendor": st.get("vendor") or "NVIDIA",
            "uuid": st.get("uuid"),
            "temp": -1, "mem_temp": -1, "util": -1, "mem_util": -1, "power_watts": -1, "fan_percent": -1,
            "sm_clock": -1, "mem_clock": -1, "vram_used": -1, "vram_total": -1,
            "stats_failed": True, "stats_error": reason,
        })
    return out
def collect_gpu_stats():
    gpus = []
    if platform.system() != "Windows":
        return []
    if not _gpu_tool_allowed("nvidia-smi"):
        return _gpu_failure_placeholders("nvidia-smi paused/blocked by the GPU tool guard")
    try:
        cmd = (
            'nvidia-smi --query-gpu='
            'index,name,temperature.gpu,utilization.gpu,utilization.memory,'
            'power.draw,fan.speed,clocks.current.sm,clocks.current.memory,'
            'memory.used,memory.total,driver_version,pci.bus_id,power.limit '
            '--format=csv,noheader,nounits'
        )
        result = subprocess.run(cmd.split(), capture_output=True, text=True, timeout=GPU_TOOL_TIMEOUT_SECONDS)
        _gpu_tool_record("nvidia-smi", result.returncode == 0, f"nvidia-smi query rc={result.returncode}")
        if result.returncode != 0:
            return _gpu_failure_placeholders(f"nvidia-smi query rc={result.returncode}")
        lines = result.stdout.strip().split("\n")
        for i, line in enumerate(lines):
            fields = [x.strip() for x in line.split(",")]
            if len(fields) < 12:
                continue
            try:
                idx = fields[0]
                name = fields[1]
                temp = fields[2]
                util = fields[3]
                mem_util = fields[4]
                power_watts = fields[5]
                fan_percent = fields[6]
                sm_clock = fields[7]
                mem_clock = fields[8]
                vram_used = fields[9]
                vram_total = fields[10]
                driver_version = fields[11]
                pci_bus = fields[12] if len(fields) > 12 else ""
                power_limit_cur = _parse_float_or_none(fields[13]) if len(fields) > 13 else None
                pnp_id = None
                if WMI_AVAILABLE:
                    try:
                        import pythoncom
                        pythoncom.CoInitialize()
                        try:
                            w = wmi.WMI()
                            for wmi_gpu in w.Win32_VideoController():
                                if wmi_gpu.Name.strip() == name and hasattr(wmi_gpu, 'PNPDeviceID'):
                                    pnp_id = wmi_gpu.PNPDeviceID
                                    break
                        finally:
                            pythoncom.CoUninitialize()
                    except:
                        pass
                board_partner = detect_board_partner(name, pnp_id, float(power_watts) if power_watts.replace('.', '', 1).isdigit() else 0)
                _tm = re.search(r"-?\d+(?:\.\d+)?", temp)
                temp_val = int(round(float(_tm.group(0)))) if _tm else 0
                util_val = int(util) if util.isdigit() else 0
                memutil_val = int(mem_util) if mem_util.isdigit() else 0
                watts_val = float(power_watts) if power_watts.replace('.', '', 1).isdigit() else 0.0
                fan_val = int(fan_percent) if fan_percent.isdigit() else 0
                smclk_val = int(sm_clock) if sm_clock.isdigit() else 0
                memclk_val = int(mem_clock) if mem_clock.isdigit() else 0
                memused_val = int(vram_used) if vram_used.isdigit() else 0
                memtotal_val = int(vram_total) if vram_total.isdigit() else 0
                gpu_uuid = f"GPU_{idx}"
                if pnp_id:
                    gpu_uuid = pnp_id
                gpus.append({
                    "index": int(idx),
                    "uuid": gpu_uuid,
                    "name": name,
                    "board_partner": board_partner,
                    "vendor": "NVIDIA",
                    "temp": temp_val,
                    "util": util_val,
                    "mem_util": memutil_val,
                    "power_watts": watts_val,
                    "power_limit": power_limit_cur,
                    "fan_percent": fan_val,
                    "sm_clock": smclk_val,
                    "mem_clock": memclk_val,
                    "vram_used": memused_val,
                    "vram_total": memtotal_val,
                    "driver_version": driver_version,
                    "pci_bus_id": pci_bus,
                    "pci_slot": pci_bus.split(":")[-1] if pci_bus else ""
                })
            except Exception as e:
                print(f"Error parsing GPU {i}: {e}")
                continue
    except Exception as e:
        _gpu_tool_record("nvidia-smi", False, f"{type(e).__name__}: {e}", timed_out=isinstance(e, subprocess.TimeoutExpired))
        print(f"Error collecting GPU stats: {e}")
    if gpus and any(g.get("temp", 0) <= 0 for g in gpus):
        fallback_temps = _collect_nvidia_core_temps()
        for g in gpus:
            if g.get("temp", 0) <= 0 and g["index"] in fallback_temps:
                g["temp"] = fallback_temps[g["index"]]
    if gpus and any(g.get("power_watts", 0) <= 0 for g in gpus):
        fallback_draw = _collect_nvidia_power_draw()
        for g in gpus:
            if g.get("power_watts", 0) <= 0 and g["index"] in fallback_draw:
                g["power_watts"] = fallback_draw[g["index"]]
    if gpus:
        limits = _collect_nvidia_power_limits()
        for g in gpus:
            lim = limits.get(g["index"], {})
            g["power_limit_min"] = lim.get("power_limit_min")
            g["power_limit_default"] = lim.get("power_limit_default")
            g["power_limit_max"] = lim.get("power_limit_max")
            if lim.get("vbios_version"):
                g["vbios_version"] = lim["vbios_version"]
        try:
            offsets = _nvml_core_offsets([g["index"] for g in gpus if isinstance(g.get("index"), int)])
            for g in gpus:
                if g.get("index") in offsets:
                    g["coreoffset"] = offsets[g["index"]]
        except Exception as e:
            print(f"Error reading GPU core offsets: {e}")
    global _last_gpu_count
    if gpus:
        _last_gpu_count = len(gpus)
    elif _last_gpu_count:
        return _gpu_failure_placeholders("nvidia-smi returned no GPU data")
    return gpus
def has_nvidia_gpu():
    if platform.system() != "Windows":
        return False
    try:
        if _gpu_tool_allowed("nvidia-smi"):
            result = subprocess.run(["nvidia-smi", "-L"], capture_output=True, text=True, timeout=GPU_TOOL_TIMEOUT_SECONDS)
            _gpu_tool_record("nvidia-smi", result.returncode == 0, f"nvidia-smi -L rc={result.returncode}")
            if result.returncode == 0 and "GPU" in result.stdout:
                return True
    except Exception as e:
        _gpu_tool_record("nvidia-smi", False, f"nvidia-smi -L {type(e).__name__}", timed_out=isinstance(e, subprocess.TimeoutExpired))
    if WMI_AVAILABLE:
        try:
            import pythoncom
            pythoncom.CoInitialize()
            try:
                w = wmi.WMI()
                gpus = w.Win32_VideoController()
                for gpu in gpus:
                    if "nvidia" in gpu.Name.lower():
                        return True
            finally:
                pythoncom.CoUninitialize()
        except:
            pass
    return False
def _cpu_temp_debug(msg):
    """Diagnostic trace for collect_cpu_temp(), off by default"""
    if os.environ.get("RIGCONTROL_CPU_TEMP_DEBUG", "").strip().lower() in ("1", "true", "yes", "on"):
        print(f"[cpu_temp] {msg}", flush=True)
def collect_cpu_temp():
    """Get CPU temperature for Windows - similar structure to Ubuntu version"""
    if platform.system() != "Windows":
        return None
    try:
        import pythoncom
        pythoncom.CoInitialize()
        try:
            w = wmi.WMI(namespace="root\\wmi")
            temperatures = w.MSAcpi_ThermalZoneTemperature()
            if not temperatures:
                _cpu_temp_debug("1) MSAcpi_ThermalZoneTemperature returned no entries - this board/BIOS doesn't expose ACPI thermal zones to WMI")
            for temp_obj in temperatures or []:
                if hasattr(temp_obj, 'CurrentTemperature'):
                    temp_kelvin = temp_obj.CurrentTemperature / 10.0
                    celsius = temp_kelvin - 273.15
                    if -20 <= celsius <= 120:
                        _cpu_temp_debug(f"1) MSAcpi_ThermalZoneTemperature succeeded: {celsius:.1f}C")
                        return round(celsius, 1)
                    _cpu_temp_debug(f"1) MSAcpi_ThermalZoneTemperature out of range: {celsius:.1f}C, ignoring")
        finally:
            pythoncom.CoUninitialize()
    except Exception as e:
        _cpu_temp_debug(f"1) MSAcpi_ThermalZoneTemperature raised: {e}")
    try:
        result = subprocess.run(
            'tasklist /fi "imagename eq OpenHardwareMonitor.exe"',
            shell=True,
            capture_output=True,
            text=True,
            timeout=2
        )
        if "OpenHardwareMonitor.exe" in result.stdout:
            ps_script = (
                "try { "
                "$temp = Get-WmiObject -Namespace root/OpenHardwareMonitor -Class Sensor | "
                "Where-Object {$_.SensorType -eq 'Temperature' -and $_.Name -match 'CPU|Core|Package'} | "
                "Sort-Object Value -Descending | Select-Object -First 1; "
                "if ($temp) { [math]::Round($temp.Value, 1) } else { $null } "
                "} catch { $null }"
            )
            result = subprocess.run(
                ["powershell", "-NoProfile", "-NonInteractive", "-Command", ps_script],
                capture_output=True,
                text=True,
                timeout=3
            )
            if result.returncode == 0 and result.stdout.strip():
                temp = float(result.stdout.strip())
                if -20 <= temp <= 120:
                    _cpu_temp_debug(f"2) OpenHardwareMonitor succeeded: {temp}C")
                    return temp
                _cpu_temp_debug(f"2) OpenHardwareMonitor out of range: {temp}C, ignoring")
            else:
                _cpu_temp_debug(f"2) OpenHardwareMonitor.exe is running but WMI query returned nothing (rc={result.returncode}, stdout={result.stdout!r}, stderr={result.stderr!r})")
        else:
            _cpu_temp_debug("2) OpenHardwareMonitor.exe is not running - skipped")
    except Exception as e:
        _cpu_temp_debug(f"2) OpenHardwareMonitor check raised: {e}")
    try:
        ps_script = (
            "try { "
            "$temps = Get-WmiObject -Namespace root/LibreHardwareMonitor -Class Sensor | "
            "Where-Object {$_.SensorType -eq 'Temperature' -and $_.Name -match 'CPU|Core|Package'} | "
            "Sort-Object Value -Descending; "
            "if ($temps) { [math]::Round(($temps | Select-Object -First 1).Value, 1) } else { $null } "
            "} catch { $null }"
        )
        result = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-Command", ps_script],
            capture_output=True,
            text=True,
            timeout=3
        )
        if result.returncode == 0 and result.stdout.strip():
            temp = float(result.stdout.strip())
            if -20 <= temp <= 120:
                _cpu_temp_debug(f"3) LibreHardwareMonitor succeeded: {temp}C")
                return temp
            _cpu_temp_debug(f"3) LibreHardwareMonitor out of range: {temp}C, ignoring")
        else:
            _cpu_temp_debug(f"3) LibreHardwareMonitor WMI query returned nothing - likely not installed/running, or its 'Expose WMI' option is off (rc={result.returncode}, stdout={result.stdout!r}, stderr={result.stderr!r})")
    except Exception as e:
        _cpu_temp_debug(f"3) LibreHardwareMonitor query raised: {e}")
    try:
        result = subprocess.run(
            'wmic /namespace:\\\\root\\wmi PATH MSAcpi_ThermalZoneTemperature get CurrentTemperature /format:value',
            shell=True,
            capture_output=True,
            text=True,
            timeout=2,
            encoding='utf-8',
            errors='ignore'
        )
        if result.returncode == 0:
            import re
            match = re.search(r'CurrentTemperature=(\d+)', result.stdout)
            if match:
                temp_decikelvin = float(match.group(1))
                celsius = (temp_decikelvin / 10.0) - 273.15
                if -20 <= celsius <= 120:
                    _cpu_temp_debug(f"4) wmic succeeded: {celsius:.1f}C")
                    return round(celsius, 1)
                _cpu_temp_debug(f"4) wmic out of range: {celsius:.1f}C, ignoring")
            else:
                _cpu_temp_debug(f"4) wmic returned no CurrentTemperature field (stdout={result.stdout!r}) - same ACPI limitation as method 1, or wmic is unavailable/removed on this Windows build")
        else:
            _cpu_temp_debug(f"4) wmic exited non-zero (rc={result.returncode}, stderr={result.stderr!r}) - wmic may have been removed (Windows 11 23H2+ drops it by default)")
    except Exception as e:
        _cpu_temp_debug(f"4) wmic raised: {e}")
    try:
        if hasattr(psutil, "sensors_temperatures"):
            temps = psutil.sensors_temperatures()
            if temps:
                for name, entries in temps.items():
                    name_lower = name.lower()
                    if any(keyword in name_lower for keyword in ['cpu', 'core', 'package', 'k10', 'coretemp']):
                        for entry in entries:
                            if entry.current:
                                _cpu_temp_debug(f"5) psutil succeeded via '{name}': {entry.current}C")
                                return round(entry.current, 1)
                all_temps = []
                for name, entries in temps.items():
                    for entry in entries:
                        if entry.current and -20 <= entry.current <= 120:
                            all_temps.append(entry.current)
                if all_temps:
                    _cpu_temp_debug(f"5) psutil succeeded (highest of {len(all_temps)} sensors): {max(all_temps)}C")
                    return round(max(all_temps), 1)
            _cpu_temp_debug("5) psutil.sensors_temperatures() returned nothing (expected - not implemented on Windows)")
        else:
            _cpu_temp_debug("5) psutil.sensors_temperatures not available on this platform (expected on Windows) - skipped")
    except Exception as e:
        _cpu_temp_debug(f"5) psutil.sensors_temperatures raised: {e}")
    try:
        result = subprocess.run(
            'powershell "try { '
            '$temp = Get-WmiObject MSAcpi_ThermalZoneTemperature -Namespace root/wmi -ErrorAction Stop | '
            'Select-Object -First 1 | Select-Object -ExpandProperty CurrentTemperature; '
            '[math]::Round(($temp/10) - 273.15, 1) '
            '} catch { $null }"',
            shell=True,
            capture_output=True,
            text=True,
            timeout=3
        )
        if result.returncode == 0 and result.stdout.strip():
            temp = float(result.stdout.strip())
            if -20 <= temp <= 120:
                _cpu_temp_debug(f"6) PowerShell WMI succeeded: {temp}C")
                return temp
            _cpu_temp_debug(f"6) PowerShell WMI out of range: {temp}C, ignoring")
        else:
            _cpu_temp_debug(f"6) PowerShell WMI returned nothing (rc={result.returncode}, stdout={result.stdout!r}, stderr={result.stderr!r}) - same ACPI limitation as method 1")
    except Exception as e:
        _cpu_temp_debug(f"6) PowerShell WMI raised: {e}")
    _cpu_temp_debug("All 6 methods failed - returning None. If method 1/4/6 all report 'no ACPI thermal zone data', install and run LibreHardwareMonitor with its WMI/'Remote Web Server' option enabled so method 3 can pick it up.")
    return None
def collect_cpu_usage():
    return psutil.cpu_percent(interval=0.1)
def collect_load():
    """Get load averages in Linux format (load1, load5, load15)"""
    cpu_count = psutil.cpu_count()
    current_load = psutil.cpu_percent(interval=0.1) / 100.0 * cpu_count
    load_rounded = round(current_load, 2)
    return {
        "1m": load_rounded,
        "5m": load_rounded,
        "15m": load_rounded
    }
def collect_memory():
    mem = psutil.virtual_memory()
    return {
        "total_mb": mem.total // (1024 * 1024),
        "used_mb": mem.used // (1024 * 1024),
        "free_mb": mem.available // (1024 * 1024),
        "percent": mem.percent
    }
def collect_network():
    """rx_bytes/tx_bytes are raw cumulative counters via psutil.net_io_counters() (reset on reboot) - used"""
    try:
        c1 = psutil.net_io_counters()
        sample_window_s = 0.5
        time.sleep(sample_window_s)
        c2 = psutil.net_io_counters()
        rx_mbps = max(0.0, (c2.bytes_recv - c1.bytes_recv) * 8 / (sample_window_s * 1_000_000))
        tx_mbps = max(0.0, (c2.bytes_sent - c1.bytes_sent) * 8 / (sample_window_s * 1_000_000))
        return {
            "rx_bytes": c2.bytes_recv, "tx_bytes": c2.bytes_sent,
            "rx_mbps": round(rx_mbps, 3), "tx_mbps": round(tx_mbps, 3),
        }
    except Exception:
        return {"rx_bytes": 0, "tx_bytes": 0, "rx_mbps": 0, "tx_mbps": 0}
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
def _build_gpu_entry(index, name=None, hashrate_hs=None, accepted_shares=None, rejected_shares=None):
    """Canonical per-GPU entry, matching keryx's/T-Rex's shape"""
    return {
        "gpu_id":          index,
        "index":           index,
        "name":            name if name else f"GPU {index}",
        "hashrate_hs":     hashrate_hs if hashrate_hs is not None else 0,
        "accepted_shares": accepted_shares,
        "rejected_shares": rejected_shares,
    }
def _build_miner_result(status, miner, miner_version=None, uptime_s=None, algorithms=None, gpus=None,
                         error=None, **extra):
    """Canonical top-level shape for every collect_*_stats() return value"""
    algorithms = algorithms or []
    result = {
        "status":                status,
        "miner":                 miner,
        "miner_version":         miner_version or "",
        "uptime_s":              uptime_s if uptime_s is not None else 0,
        "algorithms":            algorithms,
        "gpus":                  gpus if gpus is not None else [],
        "total_hashrate_hs":     sum((a.get("hashrate_hs") or 0) for a in algorithms),
        "total_accepted_shares": sum((a.get("accepted_shares") or 0) for a in algorithms),
        "total_rejected_shares": sum((a.get("rejected_shares") or 0) for a in algorithms),
    }
    if error is not None:
        result["error"] = error
    result.update(extra)
    return result
def collect_bzminer_stats():
    API_URL = "http://127.0.0.1:4014/status"
    try:
        req = urllib.request.Request(API_URL, method="GET")
        with urllib.request.urlopen(req, timeout=1.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        return _build_miner_result("offline", "bzminer", error=str(e))
    method = data.get("method", "")
    if method != "fullstatus":
        return _build_miner_result("unexpected_format", "bzminer", error="unexpected API response shape", data=data)
    pools = data.get("pools") or []
    devices = data.get("devices") or []
    algorithms = []
    device_hashrates = [0] * len(devices)
    for pool in pools:
        pool_id = pool.get("id", -1)
        pool_algo = pool.get("algorithm", "unknown")
        pool_url = ""
        current_url = pool.get("current_url", "")
        if current_url:
            url_parts = current_url.split("://")
            if len(url_parts) > 1:
                host_part = url_parts[1].split(":")[0]
                pool_url = host_part.split(".")[-2] if "." in host_part else host_part
        total_hashrate = 0
        for dev_i, device in enumerate(devices):
            device_pools = device.get("pool", [])
            device_hr = device.get("hashrate", [])
            if isinstance(device_pools, list) and isinstance(device_hr, list):
                for i, p_id in enumerate(device_pools):
                    if p_id == pool_id and i < len(device_hr):
                        total_hashrate += device_hr[i]
                        device_hashrates[dev_i] += device_hr[i]
        if total_hashrate > 0 or pool.get("status", 0) > 0:
            algorithms.append(_build_algo_entry(
                pool_algo,
                hashrate_hs=total_hashrate if total_hashrate > 0 else None,
                accepted_shares=pool.get("valid_solutions"),
                rejected_shares=pool.get("rejected_solutions"),
                stale_shares=pool.get("stale_solutions"),
                pool=pool_url,
            ))
    gpus = [_build_gpu_entry(i, hashrate_hs=hr) for i, hr in enumerate(device_hashrates)]
    return _build_miner_result(
        "ok", "bzminer",
        miner_version=data.get("bzminer_version"),
        uptime_s=data.get("uptime_s"),
        algorithms=algorithms,
        gpus=gpus,
        rig_name=data.get("rig_name"),
        cuda_driver_version=data.get("cuda_driver_version"),
    )
def collect_rigel_stats():
    host = os.environ.get("RIGEL_API_HOST", "127.0.0.1")
    port = int(os.environ.get("RIGEL_API_PORT", "5000"))
    url = f"http://{host}:{port}"
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=1.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        return _build_miner_result("offline", "rigel", error=str(e))
    hr = data.get("hashrate", {})
    pool_hr = data.get("pool_hashrate", {})
    sol = data.get("solution_stat", {})
    pool_data = data.get("pool", {})
    algorithms = []
    all_algos = set()
    if isinstance(hr, dict):
        all_algos.update(hr.keys())
    if isinstance(pool_hr, dict):
        all_algos.update(pool_hr.keys())
    if isinstance(sol, dict):
        all_algos.update(sol.keys())
    for algo in all_algos:
        algo_sol = sol.get(algo, {}) if isinstance(sol, dict) else {}
        hashrate_hs = hr.get(algo) if isinstance(hr, dict) else None
        algorithms.append(_build_algo_entry(
            algo,
            hashrate_hs=hashrate_hs,
            accepted_shares=algo_sol.get("accepted") if isinstance(algo_sol, dict) else None,
            rejected_shares=algo_sol.get("rejected") if isinstance(algo_sol, dict) else None,
            pool=pool_data.get("url", "").split("://")[-1].split(":")[0] if algo == list(all_algos)[0] else None,
            pool_hashrate_hs=pool_hr.get(algo) if isinstance(pool_hr, dict) else None,
        ))
    return _build_miner_result(
        "ok", "rigel",
        miner_version=data.get("version"),
        uptime_s=data.get("uptime"),
        algorithms=algorithms,
        cuda_driver=data.get("cuda_driver"),
    )
def collect_srbminer_stats():
    host = os.environ.get("SRB_API_HOST", "127.0.0.1")
    main_port = int(os.environ.get("SRB_API_PORT", "21550"))
    cpu_port = 21551
    main_data = {}
    main_status = "offline"
    try:
        main_url = f"http://{host}:{main_port}"
        with urllib.request.urlopen(main_url, timeout=1.0) as resp:
            main_data = json.loads(resp.read().decode("utf-8"))
        main_status = "ok"
    except Exception as e:
        main_data = {}
        main_status = "offline"
    cpu_data = {}
    cpu_status = "offline"
    try:
        cpu_url = f"http://{host}:{cpu_port}"
        with urllib.request.urlopen(cpu_url, timeout=1.0) as resp:
            cpu_data = json.loads(resp.read().decode("utf-8"))
        cpu_status = "ok"
    except Exception:
        pass
    if main_status == "offline" and cpu_status == "offline":
        return _build_miner_result("offline", "srbminer", error="Both main and CPU ports unavailable")
    algorithms = []
    if main_status == "ok":
        main_algos = main_data.get("algorithms", [])
        for algo_data in main_algos:
            name = algo_data.get("name")
            if not name:
                continue
            hr = algo_data.get("hashrate", {})
            gpu_block = hr.get("gpu", {}) if isinstance(hr, dict) else {}
            gpu_hs = gpu_block.get("total")
            if gpu_hs and gpu_hs > 0:
                shares = algo_data.get("shares", {})
                algorithms.append(_build_algo_entry(
                    name,
                    hashrate_hs=gpu_hs,
                    cpu_hashrate_hs=0,
                    gpu_hashrate_hs=gpu_hs,
                    mining_type="GPU",
                    accepted_shares=shares.get("accepted"),
                    rejected_shares=shares.get("rejected"),
                    workers=main_data.get("total_gpu_workers"),
                ))
    if main_status == "ok":
        main_algos = main_data.get("algorithms", [])
        for algo_data in main_algos:
            name = algo_data.get("name")
            if not name:
                continue
            hr = algo_data.get("hashrate", {})
            cpu_block = hr.get("cpu", {}) if isinstance(hr, dict) else {}
            cpu_hs = cpu_block.get("total")
            if cpu_hs and cpu_hs > 0:
                thread_hashrates = {}
                if isinstance(cpu_block, dict):
                    for key, value in cpu_block.items():
                        if key.startswith("thread") and isinstance(value, (int, float)):
                            thread_hashrates[key] = value
                shares = algo_data.get("shares", {})
                algorithms.append(_build_algo_entry(
                    name,
                    hashrate_hs=cpu_hs,
                    cpu_hashrate_hs=cpu_hs,
                    gpu_hashrate_hs=0,
                    mining_type="CPU",
                    accepted_shares=shares.get("accepted"),
                    rejected_shares=shares.get("rejected"),
                    workers=main_data.get("total_cpu_workers"),
                    thread_hashrates=thread_hashrates if thread_hashrates else None,
                ))
    if cpu_status == "ok":
        cpu_algos = cpu_data.get("algorithms", [])
        for algo_data in cpu_algos:
            name = algo_data.get("name")
            if not name:
                continue
            hr = algo_data.get("hashrate", {})
            cpu_block = hr.get("cpu", {}) if isinstance(hr, dict) else {}
            cpu_hs = cpu_block.get("total")
            if cpu_hs and cpu_hs > 0:
                thread_hashrates = {}
                if isinstance(cpu_block, dict):
                    for key, value in cpu_block.items():
                        if key.startswith("thread") and isinstance(value, (int, float)):
                            thread_hashrates[key] = value
                shares = algo_data.get("shares", {})
                algorithms.append(_build_algo_entry(
                    name,
                    hashrate_hs=cpu_hs,
                    cpu_hashrate_hs=cpu_hs,
                    gpu_hashrate_hs=0,
                    mining_type="CPU",
                    accepted_shares=shares.get("accepted"),
                    rejected_shares=shares.get("rejected"),
                    workers=cpu_data.get("total_cpu_workers"),
                    thread_hashrates=thread_hashrates if thread_hashrates else None,
                    source_port="21551",
                ))
    overall_status = "ok" if algorithms else "offline"
    source_data = main_data if main_status == "ok" else cpu_data
    return _build_miner_result(
        overall_status, "srbminer",
        miner_version=source_data.get("miner_version"),
        uptime_s=source_data.get("mining_time") or source_data.get("uptime") or source_data.get("uptime_s"),
        algorithms=algorithms,
        cpu_port_active=cpu_status == "ok",
        gpu_port_active=main_status == "ok",
    )
def collect_wildrig_stats():
    host = os.environ.get("WILDRIG_API_HOST", "127.0.0.1")
    port = int(os.environ.get("WILDRIG_API_PORT", "4000"))
    url = f"http://{host}:{port}"
    try:
        with urllib.request.urlopen(url, timeout=1.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        return _build_miner_result("offline", "wildrig", error=str(e))
    algo = data.get("algo")
    algorithms = []
    if algo:
        hr = data.get("hashrate", {})
        total_hr = hr.get("total")
        threads_hr = hr.get("threads")
        hashrate_hs = total_hr[0] if isinstance(total_hr, list) and len(total_hr) > 0 else None
        thread_hashrates = {}
        if isinstance(threads_hr, list):
            for i, thread_hr in enumerate(threads_hr):
                if isinstance(thread_hr, list) and len(thread_hr) > 0:
                    thread_hashrates[f"thread_{i}"] = thread_hr[0]
        results = data.get("results", {})
        acc = results.get("shares_accepted")
        rej = results.get("shares_rejected")
        accepted = acc[0] if isinstance(acc, list) and acc else None
        rejected = rej[0] if isinstance(rej, list) and rej else None
        algorithms.append(_build_algo_entry(
            algo,
            hashrate_hs=hashrate_hs,
            accepted_shares=accepted,
            rejected_shares=rejected,
            thread_hashrates=thread_hashrates if thread_hashrates else None,
        ))
    return _build_miner_result(
        "ok", "wildrig",
        miner_version=data.get("version"),
        uptime_s=data.get("uptime"),
        algorithms=algorithms,
    )
def collect_lolminer_stats():
    host = os.environ.get("LOLMINER_API_HOST", "127.0.0.1")
    port = int(os.environ.get("LOLMINER_API_PORT", "8020"))
    url = f"http://{host}:{port}/summary"
    try:
        with urllib.request.urlopen(url, timeout=1.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        return _build_miner_result("offline", "lolminer", error=str(e))
    algos = data.get("Algorithms", [])
    algorithms = []
    for algo_data in algos:
        algo_name = algo_data.get("Algorithm")
        if not algo_name:
            continue
        total_perf = algo_data.get("Total_Performance")
        factor = algo_data.get("Performance_Factor", 1)
        hashrate_hs = total_perf * factor if isinstance(total_perf, (int, float)) else None
        worker_perf = algo_data.get("Worker_Performance", [])
        thread_hashrates = {}
        if isinstance(worker_perf, list):
            for i, perf in enumerate(worker_perf):
                if isinstance(perf, (int, float)):
                    thread_hashrates[f"worker_{i}"] = perf * factor
        algorithms.append(_build_algo_entry(
            algo_name,
            hashrate_hs=hashrate_hs,
            accepted_shares=algo_data.get("Total_Accepted"),
            rejected_shares=algo_data.get("Total_Rejected"),
            pool=algo_data.get("Pool"),
            thread_hashrates=thread_hashrates if thread_hashrates else None,
        ))
    return _build_miner_result(
        "ok", "lolminer",
        miner_version=data.get("Software"),
        uptime_s=data.get("Session", {}).get("Uptime"),
        algorithms=algorithms,
    )
def collect_onezerominer_stats():
    host = os.environ.get("ONEZEROMINER_API_HOST", "127.0.0.1")
    port = int(os.environ.get("ONEZEROMINER_API_PORT", "3001"))
    url = f"http://{host}:{port}"
    try:
        with urllib.request.urlopen(url, timeout=1.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        return _build_miner_result("offline", "onezerominer", error=str(e))
    algos = data.get("algos", [])
    algorithms = []
    for algo_data in algos:
        name = algo_data.get("name")
        if not name:
            continue
        hashrate_hs = algo_data.get("total_hashrate")
        device_hr = algo_data.get("hashrates", [])
        thread_hashrates = {}
        if isinstance(device_hr, list):
            for i, hr_value in enumerate(device_hr):
                if isinstance(hr_value, (int, float)):
                    thread_hashrates[f"device_{i}"] = hr_value
        algorithms.append(_build_algo_entry(
            name,
            hashrate_hs=hashrate_hs,
            accepted_shares=algo_data.get("total_accepted_shares"),
            rejected_shares=algo_data.get("total_rejected_shares"),
            pool=algo_data.get("pool"),
            thread_hashrates=thread_hashrates if thread_hashrates else None,
        ))
    return _build_miner_result(
        "ok", "onezerominer",
        miner_version=data.get("version"),
        uptime_s=data.get("uptime_seconds"),
        algorithms=algorithms,
    )
def collect_gminer_stats():
    host = os.environ.get("GMINER_API_HOST", "127.0.0.1")
    port = int(os.environ.get("GMINER_API_PORT", "10050"))
    url = f"http://{host}:{port}/stat"
    try:
        with urllib.request.urlopen(url, timeout=1.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        return _build_miner_result("offline", "gminer", error=str(e))
    algo = data.get("algorithm")
    algorithms = []
    gpus = []
    if algo:
        total_hs = 0
        devices = data.get("devices", [])
        thread_hashrates = {}
        if isinstance(devices, list):
            for i, d in enumerate(devices):
                speed = d.get("speed")
                if isinstance(speed, (int, float)):
                    total_hs += speed
                    thread_hashrates[f"gpu_{i}"] = speed
                gpus.append(_build_gpu_entry(i, hashrate_hs=speed))
        hashrate_hs = total_hs if total_hs > 0 else None
        algorithms.append(_build_algo_entry(
            algo,
            hashrate_hs=hashrate_hs,
            accepted_shares=data.get("total_accepted_shares"),
            rejected_shares=data.get("total_rejected_shares"),
            pool=data.get("pool"),
            thread_hashrates=thread_hashrates if thread_hashrates else None,
        ))
    return _build_miner_result(
        "ok", "gminer",
        miner_version=data.get("miner"),
        uptime_s=data.get("uptime"),
        algorithms=algorithms,
        gpus=gpus,
    )
def collect_xmrig_stats():
    host = os.environ.get("XMRIG_HTTP_HOST", "127.0.0.1")
    port = int(os.environ.get("XMRIG_HTTP_PORT", "18080"))
    url = f"http://{host}:{port}/2/summary"
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=1.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        return _build_miner_result("offline", "xmrig", error=str(e))
    algo = data.get("algo")
    algorithms = []
    if algo:
        hashrate = data.get("hashrate", {})
        total = hashrate.get("total") or [0]
        hashrate_hs = float(total[0]) if total else 0
        shares_good = data.get("results", {}).get("shares_good")
        shares_total = data.get("results", {}).get("shares_total")
        rejected_shares = None
        if shares_total is not None and shares_good is not None:
            rejected_shares = shares_total - shares_good
        connection = data.get("connection", {})
        pool_url = connection.get("url", "").split("://")[-1].split(":")[0] if connection else None
        cpu_info = data.get("cpu", {})
        threads = cpu_info.get("threads", 0)
        algorithms.append(_build_algo_entry(
            algo,
            hashrate_hs=hashrate_hs,
            accepted_shares=shares_good,
            rejected_shares=rejected_shares,
            pool=pool_url,
            pool_latency_ms=connection.get("ping", 0) if connection else 0,
            mining_type="CPU" if threads > 0 else "GPU",
            cpu_threads=threads,
        ))
    return _build_miner_result(
        "ok", "xmrig",
        miner_version=data.get("version"),
        uptime_s=data.get("uptime"),
        algorithms=algorithms,
    )
def collect_trex_stats():
    host = os.environ.get("TREX_API_HOST", "127.0.0.1")
    port = int(os.environ.get("TREX_API_PORT", "4067"))
    url = f"http://{host}:{port}/summary"
    try:
        with urllib.request.urlopen(url, timeout=1.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        return _build_miner_result("offline", "trex", error=str(e))
    algo = data.get("algorithm")
    algorithms = []
    gpu_entries = []
    if algo:
        hashrate = data.get("hashrate", 0)
        hashrate_hs = float(hashrate)
        raw_gpus = data.get("gpus", [])
        thread_hashrates = {}
        if isinstance(raw_gpus, list):
            for i, gpu in enumerate(raw_gpus):
                gpu_hashrate = gpu.get("hashrate", 0)
                if gpu_hashrate:
                    thread_hashrates[f"gpu_{i}"] = gpu_hashrate
                gpu_entries.append(_build_gpu_entry(
                    gpu.get("gpu_id", i),
                    name=gpu.get("name"),
                    hashrate_hs=gpu_hashrate,
                ))
        algorithms.append(_build_algo_entry(
            algo,
            hashrate_hs=hashrate_hs,
            accepted_shares=data.get("accepted_count"),
            rejected_shares=data.get("rejected_count"),
            pool=data.get("url", "").split("://")[-1].split(":")[0] if data.get("url") else None,
            thread_hashrates=thread_hashrates if thread_hashrates else None,
        ))
    return _build_miner_result(
        "ok", "trex",
        miner_version=data.get("version"),
        uptime_s=data.get("uptime"),
        algorithms=algorithms,
        gpus=gpu_entries,
    )
def collect_nbminer_stats():
    host = os.environ.get("NBMINER_API_HOST", "127.0.0.1")
    port = int(os.environ.get("NBMINER_API_PORT", "22333"))
    url = f"http://{host}:{port}/api/v1/status"
    try:
        with urllib.request.urlopen(url, timeout=1.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        return _build_miner_result("offline", "nbminer", error=str(e))
    algo = data.get("miner", {}).get("algorithm")
    algorithms = []
    gpu_entries = []
    if algo:
        hashrate = data.get("miner", {}).get("total_hashrate_raw", 0)
        hashrate_hs = float(hashrate)
        devices = data.get("miner", {}).get("devices", [])
        thread_hashrates = {}
        if isinstance(devices, list):
            for i, device in enumerate(devices):
                device_hashrate = device.get("hashrate_raw", 0)
                if device_hashrate:
                    thread_hashrates[f"gpu_{i}"] = device_hashrate
                gpu_entries.append(_build_gpu_entry(
                    device.get("id", i),
                    name=device.get("name"),
                    hashrate_hs=device_hashrate,
                ))
        algorithms.append(_build_algo_entry(
            algo,
            hashrate_hs=hashrate_hs,
            accepted_shares=data.get("stratum", {}).get("accepted_shares"),
            rejected_shares=data.get("stratum", {}).get("rejected_shares"),
            pool=data.get("stratum", {}).get("url", "").split("://")[-1].split(":")[0] if data.get("stratum", {}).get("url") else None,
            thread_hashrates=thread_hashrates if thread_hashrates else None,
        ))
    return _build_miner_result(
        "ok", "nbminer",
        miner_version=data.get("miner", {}).get("version"),
        uptime_s=data.get("miner", {}).get("runtime"),
        algorithms=algorithms,
        gpus=gpu_entries,
    )
def _decode_log_bytes(data):
    """Decode miner log bytes to text, tolerating both UTF-8/ASCII and UTF-16 - including a single chunk"""
    if data.startswith(b"\xff\xfe") or data.startswith(b"\xfe\xff"):
        data = data[2:]
    return data.replace(b"\x00", b"").decode("utf-8", errors="ignore")
def _tail_file(path, max_bytes=131072):
    """Read the last max_bytes of a file as text (cheap tail, no deps)"""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - max_bytes))
            data = f.read()
        return _decode_log_bytes(data)
    except Exception:
        return None
_log_event_state = {}
def _read_new_log_bytes(path, state, restart_threshold_bytes=1048576):
    """Read only what's been appended to `path` since the last call for this state dict (tracked via"""
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
                    return _decode_log_bytes(new_tail)
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
        return _decode_log_bytes(data)
    except Exception:
        return None
def _keryx_bin_for(display_name, default_bin):
    """Resolves a keryx binary's path via <NAME>_BIN (KERYX_MINER_BIN / KERYX_MINER_SUPR_BIN, sanitized"""
    prefix = re.sub(r"[^A-Za-z0-9]+", "_", display_name).strip("_").upper()
    return os.environ.get(f"{prefix}_BIN", "").strip() or default_bin
def _detect_keryx_variant():
    """Checks the actually-running process list for keryx-miner-supr.exe vs plain keryx-miner.exe (checked"""
    try:
        for proc in psutil.process_iter(['name']):
            try:
                proc_name = (proc.info['name'] or "").lower()
            except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
                continue
            if "keryx-miner-supr" in proc_name:
                return "keryx-miner-supr", _keryx_bin_for("keryx-miner-supr", KERYX_MINER_SUPR_BIN_DEFAULT)
        for proc in psutil.process_iter(['name']):
            try:
                proc_name = (proc.info['name'] or "").lower()
            except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
                continue
            if "keryx-miner" in proc_name:
                return "keryx-miner", _keryx_bin_for("keryx-miner", KERYX_MINER_BIN_DEFAULT)
    except Exception:
        pass
    return "keryx-miner-supr", _keryx_bin_for("keryx-miner-supr", KERYX_MINER_SUPR_BIN_DEFAULT)
_keryx_version_cache = {"version": "", "last_uptime_s": None}
def _query_keryx_version(bin_path):
    """Runs `<bin_path> --version` and returns its first line, or "" on any failure (binary missing"""
    try:
        out = subprocess.run(
            [bin_path, "--version"], capture_output=True, text=True, timeout=2.0
        )
        text = (out.stdout or out.stderr or "").strip()
        return text.splitlines()[0] if text else ""
    except Exception:
        return ""
def collect_keryx_stats():
    """keryx-miner 0.3.7+ exposes a small JSON stats API on 127.0.0.1:3338 (KERYX_API_HOST/KERYX_API_PORT"""
    _keryx_bin_path = _keryx_bin_path_override()
    if _keryx_bin_path:
        display_name, bin_path = _custom_miner_display_name(), _keryx_bin_path
    else:
        display_name, bin_path = _detect_keryx_variant()
    _name_prefix = re.sub(r"[^A-Za-z0-9]+", "_", display_name).strip("_").upper()
    api_host = os.environ.get(f"{_name_prefix}_API_HOST", os.environ.get("KERYX_API_HOST", KERYX_API_HOST_DEFAULT))
    api_port = int(os.environ.get(f"{_name_prefix}_API_PORT", os.environ.get("KERYX_API_PORT", KERYX_API_PORT_DEFAULT)))
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
        return _build_miner_result("error", display_name,
                                    error=f"keryx-miner API unreachable at {api_host}:{api_port} (/stats, /v1/miner/stats): {last_err}")
    device_re = re.compile(r"#(\d+)\s*\(([^)]+)\)")
    raw_devices = data.get("devices", []) or []
    parsed_devices = []
    for i, dev in enumerate(raw_devices):
        dev_id = dev.get("id") or dev.get("name") or ""
        m = device_re.search(dev_id)
        idx  = int(m.group(1)) if m else i
        name = m.group(2).strip() if m else dev_id
        parsed_devices.append((idx, name, dev.get("hashrate_hs", 0)))
    parsed_devices.sort(key=lambda d: d[0])
    total_hr_hs = data.get("total_hashrate_hs", 0)
    if "accepted_blocks" in data or "rejected_blocks" in data:
        accepted_blocks = data.get("accepted_blocks", 0)
        rejected_blocks = data.get("rejected_blocks", 0)
    else:
        shares = data.get("shares") or {}
        accepted_blocks = shares.get("accepted", 0)
        rejected_blocks = shares.get("rejected", 0)
    uptime_s = data.get("uptime_s", 0)
    if data.get("version"):
        _keryx_version_cache["version"] = f"{display_name} {data['version']}"
    else:
        last_uptime = _keryx_version_cache["last_uptime_s"]
        if last_uptime is None or uptime_s < last_uptime:
            _keryx_version_cache["version"] = _query_keryx_version(bin_path)
    _keryx_version_cache["last_uptime_s"] = uptime_s
    single_gpu = len(parsed_devices) == 1
    gpus = [
        _build_gpu_entry(
            idx, name=name, hashrate_hs=hr,
            accepted_shares=accepted_blocks if single_gpu else None,
            rejected_shares=rejected_blocks if single_gpu else None,
        )
        for idx, name, hr in parsed_devices
    ]
    return _build_miner_result(
        "ok", data.get("miner") or display_name,
        miner_version=_keryx_version_cache["version"],
        uptime_s=uptime_s,
        algorithms=[_build_algo_entry(
            "keryxhash",
            hashrate_hs=total_hr_hs,
            accepted_shares=accepted_blocks,
            rejected_shares=rejected_blocks,
        )],
        gpus=gpus,
        synced=data.get("synced"),
        mining_address=data.get("mining_address", ""),
    )
_KERYXD_MAX_PLAUSIBLE_BATCH = 1000
_keryxd_pid_cache = {"pid": None}
def _get_keryxd_pid():
    """Return keryxd's current PID (int), or None if it's not running"""
    try:
        for proc in psutil.process_iter(['pid', 'name']):
            try:
                if proc.info['name'] and proc.info['name'].lower().startswith('keryxd'):
                    return proc.info['pid']
            except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
                continue
    except Exception:
        pass
    return None
def collect_keryxd_stats():
    """keryxd (the Keryx node itself, not the miner) logs to stdout"""
    default_log_path = os.path.join(os.environ.get("TEMP", "C:\\Temp"), "keryxd.log")
    log_path = os.environ.get("KERYXD_LOG_PATH", default_log_path)
    log_style = os.environ.get("KERYXD_LOG_STYLE", "").strip().lower()
    line_re = re.compile(
        r"^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}\.\d+[+-]\d{2}:\d{2}[ \t]+"
        r"\[[A-Za-z]+\s*\][ \t]+Accepted[ \t]+(\d+)[ \t]+blocks?"
        r"(?:[^\n]*?[ \t](\d+)[ \t]+via[ \t]+submit[ \t]+blocks?)?",
        re.MULTILINE,
    )
    use_submit_only = (log_style == "blocks")
    current_pid = _get_keryxd_pid()
    keryxd_restarted = (
        current_pid is not None
        and _keryxd_pid_cache["pid"] is not None
        and current_pid != _keryxd_pid_cache["pid"]
    )
    _keryxd_pid_cache["pid"] = current_pid
    share_state = _log_event_state.setdefault(
        log_path, {"offset": 0, "accepted_shares": 0}
    )
    new_text = _read_new_log_bytes(log_path, share_state)
    if new_text is None:
        return _build_miner_result("error", "keryxd", error=f"could not read log file '{log_path}'")
    if share_state.get("reset") or keryxd_restarted:
        share_state["accepted_shares"] = 0
    for match in line_re.finditer(new_text):
        if use_submit_only:
            n = int(match.group(2)) if match.group(2) else 0
        else:
            n = int(match.group(1))
        if n > _KERYXD_MAX_PLAUSIBLE_BATCH:
            continue
        share_state["accepted_shares"] += n
    accepted_shares = share_state["accepted_shares"]
    return _build_miner_result(
        "ok", "keryxd",
        algorithms=[_build_algo_entry("keryxd-node", hashrate_hs=accepted_shares)],
    )
_CUSTOM_HASHRATE_RE = re.compile(
    r"([\d]+(?:\.\d+)?)\s*([kKmMgGtTpP]?)h(?:ash(?:es)?)?\s*/\s*s", re.IGNORECASE
)
_CUSTOM_ACCEPTED_RE = re.compile(r"accepted[^\d\n]{0,10}(\d+)", re.IGNORECASE)
_CUSTOM_REJECTED_RE = re.compile(r"rejected[^\d\n]{0,10}(\d+)", re.IGNORECASE)
_CUSTOM_HASHRATE_UNIT_MULTIPLIER = {"": 1, "k": 1e3, "m": 1e6, "g": 1e9, "t": 1e12, "p": 1e15}
_CUSTOM_LOG_VERSION_RE = re.compile(r"(suprminer[-\w]*|quanpool-miner)[\s_:]+v?(\d+(?:\.\d+)+\S*)", re.IGNORECASE)
_custom_log_version_cache = {"pid": None, "name": "", "version": ""}
def _detect_custom_log_miner(log_text=""):
    """Finds the running custom_log miner process and returns (display_name, version)"""
    try:
        for proc in psutil.process_iter(['name', 'exe']):
            try:
                proc_name = proc.info.get('name') or ""
                low = proc_name.lower()
                match = next((n for n in CUSTOM_LOG_MINER_NAMES if n in low), None)
                if not match:
                    continue
                pid = proc.pid
                exe_path = proc.info.get('exe') or ""
            except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
                continue
            if pid == _custom_log_version_cache["pid"] and _custom_log_version_cache["version"]:
                return match, _custom_log_version_cache["version"]
            version = ""
            if exe_path:
                try:
                    out = subprocess.run([exe_path, "--version"], capture_output=True, text=True, timeout=2.0)
                    if out.returncode == 0:
                        text = (out.stdout or out.stderr or "").strip()
                        version = text.splitlines()[0] if text else ""
                except Exception:
                    version = ""
            if not version and log_text:
                m = None
                for m in _CUSTOM_LOG_VERSION_RE.finditer(log_text):
                    pass
                if m:
                    version = f"{m.group(1)} {m.group(2)}"
            _custom_log_version_cache["pid"] = pid if version else None
            _custom_log_version_cache["version"] = version
            return match, version
    except Exception:
        pass
    return CUSTOM_LOG_MINER_DISPLAY_NAME, ""
def collect_custom_log_miner_stats():
    """Best-effort telemetry for a custom miner with no known stats API, scraped from its own log file"""
    log_path = _custom_miner_log_path()
    tail_bytes = int(os.environ.get("CUSTOM_LOG_TAIL_BYTES", "65536"))
    text = _tail_file(log_path, max_bytes=tail_bytes)
    display_name, detected_version = _detect_custom_log_miner(text or "")
    if text is None:
        return _build_miner_result("error", display_name, error=f"could not read log file '{log_path}'")
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
        "ok", display_name,
        miner_version=detected_version,
        algorithms=[_build_algo_entry(
            "unknown",
            hashrate_hs=hashrate_hs,
            accepted_shares=accepted_shares,
            rejected_shares=rejected_shares,
        )],
    )
def collect_full_stats():
    gpu_present = has_nvidia_gpu()
    gpu_list = collect_gpu_stats() if gpu_present else []
    stats = {
        "rig": RIG_NAME,
        "timestamp": int(time.time()),
        "cpu_temp": 0,
        "cpu_usage": collect_cpu_usage(),
        "load": collect_load(),
        "memory": collect_memory(),
        "network": collect_network(),
        "system_uptime_seconds": collect_system_uptime(),
        "gpu_present": gpu_present,
        "gpus": gpu_list,
        "gpu_count": len(gpu_list),
        "exclude_from_totals": EXCLUDE_FROM_TOTALS,
        "platform": platform.system(),
        "platform_version": platform.version(),
    }
    detected_miners = detect_running_miners()
    stats["detected_miners"] = detected_miners
    miner_stats = collect_miner_stats_based_on_processes()
    stats.update(miner_stats)
    try:
        cpu_service_result = subprocess.run(
            'sc query CPU_Miner_Service',
            shell=True,
            capture_output=True,
            text=True
        )
        if cpu_service_result.returncode == 0 and "RUNNING" in cpu_service_result.stdout:
            stats["cpu_service"] = {
                "state": "active",
                "uptime_seconds": 0
            }
        else:
            stats["cpu_service"] = {
                "state": "inactive",
                "uptime_seconds": 0
            }
    except:
        stats["cpu_service"] = {
            "state": "unknown",
            "uptime_seconds": 0
        }
    try:
        gpu_service_result = subprocess.run(
            'sc query GPU_Miner_Service',
            shell=True,
            capture_output=True,
            text=True
        )
        if gpu_service_result.returncode == 0 and "RUNNING" in gpu_service_result.stdout:
            stats["gpu_service"] = {
                "state": "active",
                "uptime_seconds": 0
            }
        else:
            stats["gpu_service"] = {
                "state": "inactive",
                "uptime_seconds": 0
            }
    except:
        stats["gpu_service"] = {
            "state": "unknown",
            "uptime_seconds": 0
        }    
    stats["docker"] = collect_docker_containers()
    return stats
if __name__ == "__main__":
    stats = collect_full_stats()
    print(json.dumps(stats, indent=2))
