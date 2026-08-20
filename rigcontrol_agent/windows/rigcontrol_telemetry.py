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
RIG_NAME = socket.gethostname().lower()
EXCLUDE_FROM_TOTALS = False
KERYX_BIN_PATH_DEFAULT = r"C:\miners\keryx-miner\keryx-miner.exe"
KERYX_BIN_PATH = os.environ.get("KERYX_BIN_PATH", KERYX_BIN_PATH_DEFAULT)
CUSTOM_MINER_LOG_PATH_DEFAULT = r"C:\Temp\gpu-miner.log"
CUSTOM_MINER_LOG_PATH = os.environ.get("CUSTOM_MINER_LOG_PATH", CUSTOM_MINER_LOG_PATH_DEFAULT)
CUSTOM_MINER_DISPLAY_NAME = os.environ.get("CUSTOM_MINER_PROCESS_NAME", "keryx-miner-supr")
CUSTOM_MINER_BIN_PATH = os.environ.get("CUSTOM_MINER_BIN_PATH", "").strip()
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
    "keryx-miner-supr.exe": "custom_log",
    "keryx-miner-supr": "custom_log",
    "keryx-miner.exe": "keryx",
    "keryx-miner": "keryx",
    "keryxd.exe": "keryxd",
    "keryxd": "keryxd",
}
NON_MINER_PROCESS_EXCLUSIONS = {
    "lolminergui.exe",
    "lolminergui",
}
def detect_running_miners():
    """Detect which miners are currently running on Windows"""
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
    """Collect stats only for miners that are actually running"""
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
            'sc query docker_events_cpu',
            shell=True,
            capture_output=True,
            text=True
        )
        if cpu_service_result.returncode == 0 and "RUNNING" in cpu_service_result.stdout:
            miner_stats["cpu_miner_service"] = {
                "status": "running",
                "service": "docker_events_cpu"
            }
    except:
        pass
    try:
        gpu_service_result = subprocess.run(
            'sc query docker_events_gpu',
            shell=True,
            capture_output=True,
            text=True
        )
        if gpu_service_result.returncode == 0 and "RUNNING" in gpu_service_result.stdout:
            miner_stats["gpu_miner_service"] = {
                "status": "running",
                "service": "docker_events_gpu"
            }
    except:
        pass
    try:
        aux_service_result = subprocess.run(
            'sc query docker_events_aux',
            shell=True,
            capture_output=True,
            text=True
        )
        if aux_service_result.returncode == 0 and "RUNNING" in aux_service_result.stdout:
            miner_stats["aux_miner_service"] = {
                "status": "running",
                "service": "docker_events_aux"
            }
    except:
        pass
    return miner_stats
def collect_service_uptime(service_name):
    """Get service status and uptime for Windows"""
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
    """Check for Docker containers on Windows"""
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
    """nvidia-smi prints '[Not Supported]' for some fields on some GPUs/drivers; treat that as
    unknown rather than crashing or defaulting to a misleading 0."""
    try:
        return float(raw)
    except ValueError:
        return None
def _gpu_architecture_from_name(name):
    """Best-effort NVIDIA architecture guess from the GPU name string. nvidia-smi's --query-gpu
    has no 'architecture' field, and the real way to get it (NVML nvmlDeviceGetArchitecture) needs
    full ctypes NVML bindings for one label - not worth it here."""
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
def collect_gpu_stats():
    """Collect GPU statistics for any NVIDIA GPU - Complete metrics"""
    gpus = []
    if platform.system() != "Windows":
        return []
    try:
        cmd = (
            'nvidia-smi --query-gpu='
            'index,name,temperature.gpu,temperature.memory,utilization.gpu,utilization.memory,'
            'power.draw,fan.speed,clocks.current.sm,clocks.current.memory,'
            'memory.used,memory.total,driver_version,pci.bus_id,'
            'vbios_version,power.min_limit,power.default_limit,power.max_limit '
            '--format=csv,noheader,nounits'
        )
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=3)
        if result.returncode != 0:
            return []
        lines = result.stdout.strip().split("\n")
        for i, line in enumerate(lines):
            fields = [x.strip() for x in line.split(",")]
            if len(fields) < 13:
                continue
            try:
                idx = fields[0]
                name = fields[1]
                temp = fields[2]
                mem_temp = fields[3]
                util = fields[4]
                mem_util = fields[5]
                power_watts = fields[6]
                fan_percent = fields[7]
                sm_clock = fields[8]
                mem_clock = fields[9]
                vram_used = fields[10]
                vram_total = fields[11]
                driver_version = fields[12]
                pci_bus = fields[13] if len(fields) > 13 else ""
                vbios_version = fields[14] if len(fields) > 14 else ""
                pwr_min_raw = fields[15] if len(fields) > 15 else ""
                pwr_default_raw = fields[16] if len(fields) > 16 else ""
                pwr_max_raw = fields[17] if len(fields) > 17 else ""
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
                temp_val = int(temp) if temp.isdigit() else 0
                mem_temp_val = int(mem_temp) if mem_temp.isdigit() else None
                util_val = int(util) if util.isdigit() else 0
                memutil_val = int(mem_util) if mem_util.isdigit() else 0
                watts_val = float(power_watts) if power_watts.replace('.', '', 1).isdigit() else 0.0
                fan_val = int(fan_percent) if fan_percent.isdigit() else 0
                smclk_val = int(sm_clock) if sm_clock.isdigit() else 0
                memclk_val = int(mem_clock) if mem_clock.isdigit() else 0
                memused_val = int(vram_used) if vram_used.isdigit() else 0
                memtotal_val = int(vram_total) if vram_total.isdigit() else 0
                power_limit_min = _parse_float_or_none(pwr_min_raw)
                power_limit_default = _parse_float_or_none(pwr_default_raw)
                power_limit_max = _parse_float_or_none(pwr_max_raw)
                gpu_uuid = f"GPU_{idx}"
                if pnp_id:
                    gpu_uuid = pnp_id
                gpus.append({
                    "index": int(idx),
                    "uuid": gpu_uuid,
                    "name": name,
                    "board_partner": board_partner,
                    "vendor": "NVIDIA",
                    "architecture": _gpu_architecture_from_name(name),
                    "temp": temp_val,
                    "mem_temp": mem_temp_val,
                    "util": util_val,
                    "mem_util": memutil_val,
                    "power_watts": watts_val,
                    "fan_percent": fan_val,
                    "sm_clock": smclk_val,
                    "mem_clock": memclk_val,
                    "vram_used": memused_val,
                    "vram_total": memtotal_val,
                    "driver_version": driver_version,
                    "vbios_version": vbios_version,
                    "power_limit_min": power_limit_min,
                    "power_limit_default": power_limit_default,
                    "power_limit_max": power_limit_max,
                    "pci_bus_id": pci_bus,
                    "pci_slot": pci_bus.split(":")[-1] if pci_bus else ""
                })
            except Exception as e:
                print(f"Error parsing GPU {i}: {e}")
                continue
    except Exception as e:
        print(f"Error collecting GPU stats: {e}")
    return gpus
def has_nvidia_gpu():
    """Check if NVIDIA GPU is present on Windows"""
    if platform.system() != "Windows":
        return False
    try:
        result = subprocess.run("nvidia-smi -L", shell=True, capture_output=True, text=True)
        if result.returncode == 0 and "GPU" in result.stdout:
            return True
    except:
        pass
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
    """Diagnostic trace for collect_cpu_temp(), off by default; enable via RIGCONTROL_CPU_TEMP_DEBUG=1 to print which detection method ran and why it failed."""
    if os.environ.get("RIGCONTROL_CPU_TEMP_DEBUG", "").strip().lower() in ("1", "true", "yes", "on"):
        print(f"[cpu_temp] {msg}", flush=True)
def collect_cpu_temp():
    """Gets CPU temperature on Windows via up to 6 fallback detection methods (ACPI WMI, OpenHardwareMonitor/LibreHardwareMonitor), any of which may be unavailable on a given board."""
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
    """Get CPU usage percentage"""
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
    """Get memory usage"""
    mem = psutil.virtual_memory()
    return {
        "total_mb": mem.total // (1024 * 1024),
        "used_mb": mem.used // (1024 * 1024),
        "free_mb": mem.available // (1024 * 1024),
        "percent": mem.percent
    }
def collect_bzminer_stats():
    API_URL = "http://127.0.0.1:4014/status"
    try:
        req = urllib.request.Request(API_URL, method="GET")
        with urllib.request.urlopen(req, timeout=1.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        return {"status": "offline", "error": str(e)}
    method = data.get("method", "")
    if method != "fullstatus":
        return {"status": "unexpected_format", "data": data}
    pools = data.get("pools") or []
    devices = data.get("devices") or []
    algorithms = []
    for pool in pools:
        pool_id = pool.get("id", -1)
        pool_algo = pool.get("algorithm", "unknown")
        pool_url = ""
        current_url = pool.get("current_url", "")
        if current_url:
            url_parts = current_url.split("://")
            if len(url_parts) > 1:
                pool_url = url_parts[1]
        total_hashrate = 0
        for device in devices:
            device_pools = device.get("pool", [])
            device_hr = device.get("hashrate", [])
            if isinstance(device_pools, list) and isinstance(device_hr, list):
                for i, p_id in enumerate(device_pools):
                    if p_id == pool_id and i < len(device_hr):
                        total_hashrate += device_hr[i]
        if total_hashrate > 0 or pool.get("status", 0) > 0:
            algo_data = {
                "algorithm": pool_algo,
                "pool": pool_url,
                "hashrate_hs": total_hashrate if total_hashrate > 0 else None,
                "accepted_shares": pool.get("valid_solutions"),
                "rejected_shares": pool.get("rejected_solutions"),
                "stale_shares": pool.get("stale_solutions"),
                "workers": None
            }
            algorithms.append(algo_data)
    return {
        "status": "ok",
        "miner": "bzminer",
        "miner_version": data.get("bzminer_version"),
        "rig_name": data.get("rig_name"),
        "uptime_s": data.get("uptime_s"),
        "total_devices": len(devices),
        "cuda_driver_version": data.get("cuda_driver_version"),
        "algorithms": algorithms
    }
def collect_rigel_stats():
    host = os.environ.get("RIGEL_API_HOST", "127.0.0.1")
    port = int(os.environ.get("RIGEL_API_PORT", "5000"))
    url = f"http://{host}:{port}"
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=1.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        return {"status": "offline", "error": str(e)}
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
        algo_data = {
            "algorithm": algo,
            "hashrate_hs": hashrate_hs,
            "pool_hashrate_hs": pool_hr.get(algo) if isinstance(pool_hr, dict) else None,
            "accepted_shares": algo_sol.get("accepted") if isinstance(algo_sol, dict) else None,
            "rejected_shares": algo_sol.get("rejected") if isinstance(algo_sol, dict) else None,
            "pool": pool_data.get("url", "").split("://")[-1] if algo == list(all_algos)[0] else None
        }
        algorithms.append(algo_data)
    return {
        "status": "ok",
        "miner": "rigel",
        "miner_version": data.get("version"),
        "cuda_driver": data.get("cuda_driver"),
        "uptime_s": data.get("uptime"),
        "algorithms": algorithms
    }
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
        return {
            "status": "offline",
            "error": "Both main and CPU ports unavailable"
        }
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
                algo_info = {
                    "algorithm": name,
                    "cpu_hashrate_hs": 0,
                    "gpu_hashrate_hs": gpu_hs,
                    "hashrate_hs": gpu_hs,
                    "accepted_shares": shares.get("accepted"),
                    "rejected_shares": shares.get("rejected"),
                    "cpu_workers": 0,
                    "gpu_workers": main_data.get("total_gpu_workers"),
                    "thread_hashrates": None,
                    "mining_type": "GPU"
                }
                algorithms.append(algo_info)
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
                algo_info = {
                    "algorithm": name,
                    "cpu_hashrate_hs": cpu_hs,
                    "gpu_hashrate_hs": 0,
                    "hashrate_hs": cpu_hs,
                    "accepted_shares": shares.get("accepted"),
                    "rejected_shares": shares.get("rejected"),
                    "cpu_workers": main_data.get("total_cpu_workers"),
                    "gpu_workers": 0,
                    "thread_hashrates": thread_hashrates if thread_hashrates else None,
                    "mining_type": "CPU"
                }
                algorithms.append(algo_info)
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
                algo_info = {
                    "algorithm": name,
                    "cpu_hashrate_hs": cpu_hs,
                    "gpu_hashrate_hs": 0,
                    "hashrate_hs": cpu_hs,
                    "accepted_shares": shares.get("accepted"),
                    "rejected_shares": shares.get("rejected"),
                    "cpu_workers": cpu_data.get("total_cpu_workers"),
                    "gpu_workers": 0,
                    "thread_hashrates": thread_hashrates if thread_hashrates else None,
                    "mining_type": "CPU",
                    "source_port": "21551"
                }
                algorithms.append(algo_info)
    overall_status = "ok" if algorithms else "offline"
    source_data = main_data if main_status == "ok" else cpu_data
    return {
        "status": overall_status,
        "miner": "srbminer",
        "miner_version": source_data.get("miner_version"),
        "cpu_port_active": cpu_status == "ok",
        "gpu_port_active": main_status == "ok",
        "uptime_s": source_data.get("mining_time") or source_data.get("uptime") or source_data.get("uptime_s"),
        "algorithms": algorithms
    }
def collect_wildrig_stats():
    host = os.environ.get("WILDRIG_API_HOST", "127.0.0.1")
    port = int(os.environ.get("WILDRIG_API_PORT", "4000"))
    url = f"http://{host}:{port}"
    try:
        with urllib.request.urlopen(url, timeout=1.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        return {"status": "offline", "error": str(e)}
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
        algo_data = {
            "algorithm": algo,
            "hashrate_hs": hashrate_hs,
            "accepted_shares": accepted,
            "rejected_shares": rejected,
            "thread_hashrates": thread_hashrates if thread_hashrates else None
        }
        algorithms.append(algo_data)
    return {
        "status": "ok",
        "miner": "wildrig",
        "miner_version": data.get("version"),
        "uptime_s": data.get("uptime"),
        "algorithms": algorithms
    }
def collect_lolminer_stats():
    host = os.environ.get("LOLMINER_API_HOST", "127.0.0.1")
    port = int(os.environ.get("LOLMINER_API_PORT", "8020"))
    url = f"http://{host}:{port}/summary"
    try:
        with urllib.request.urlopen(url, timeout=1.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        return {"status": "offline", "error": str(e)}
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
        algo_info = {
            "algorithm": algo_name,
            "hashrate_hs": hashrate_hs,
            "accepted_shares": algo_data.get("Total_Accepted"),
            "rejected_shares": algo_data.get("Total_Rejected"),
            "pool": algo_data.get("Pool"),
            "thread_hashrates": thread_hashrates if thread_hashrates else None
        }
        algorithms.append(algo_info)
    return {
        "status": "ok",
        "miner": "lolminer",
        "miner_version": data.get("Software"),
        "uptime_s": data.get("Session", {}).get("Uptime"),
        "algorithms": algorithms
    }
def collect_onezerominer_stats():
    host = os.environ.get("ONEZEROMINER_API_HOST", "127.0.0.1")
    port = int(os.environ.get("ONEZEROMINER_API_PORT", "3001"))
    url = f"http://{host}:{port}"
    try:
        with urllib.request.urlopen(url, timeout=1.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        return {"status": "offline", "error": str(e)}
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
        algo_info = {
            "algorithm": name,
            "hashrate_hs": hashrate_hs,
            "accepted_shares": algo_data.get("total_accepted_shares"),
            "rejected_shares": algo_data.get("total_rejected_shares"),
            "pool": algo_data.get("pool"),
            "thread_hashrates": thread_hashrates if thread_hashrates else None
        }
        algorithms.append(algo_info)
    return {
        "status": "ok",
        "miner": "onezerominer",
        "miner_version": data.get("version"),
        "uptime_s": data.get("uptime_seconds"),
        "algorithms": algorithms
    }
def collect_gminer_stats():
    host = os.environ.get("GMINER_API_HOST", "127.0.0.1")
    port = int(os.environ.get("GMINER_API_PORT", "10050"))
    url = f"http://{host}:{port}/stat"
    try:
        with urllib.request.urlopen(url, timeout=1.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        return {"status": "offline", "error": str(e)}
    algo = data.get("algorithm")
    algorithms = []
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
        hashrate_hs = total_hs if total_hs > 0 else None
        algo_data = {
            "algorithm": algo,
            "hashrate_hs": hashrate_hs,
            "accepted_shares": data.get("total_accepted_shares"),
            "rejected_shares": data.get("total_rejected_shares"),
            "pool": data.get("pool"),
            "thread_hashrates": thread_hashrates if thread_hashrates else None
        }
        algorithms.append(algo_data)
    return {
        "status": "ok",
        "miner": "gminer",
        "miner_version": data.get("miner"),
        "uptime_s": data.get("uptime"),
        "algorithms": algorithms
    }
def collect_xmrig_stats():
    host = os.environ.get("XMRIG_HTTP_HOST", "127.0.0.1")
    port = int(os.environ.get("XMRIG_HTTP_PORT", "18080"))
    url = f"http://{host}:{port}/2/summary"
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=1.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        return {"status": "offline", "error": str(e)}
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
        pool_url = connection.get("url", "").split("://")[-1] if connection else None
        cpu_info = data.get("cpu", {})
        threads = cpu_info.get("threads", 0)
        algo_data = {
            "algorithm": algo,
            "hashrate_hs": hashrate_hs,
            "accepted_shares": shares_good,
            "rejected_shares": rejected_shares,
            "pool": pool_url,
            "pool_latency_ms": connection.get("ping", 0) if connection else 0,
            "cpu_threads": threads,
            "mining_type": "CPU" if threads > 0 else "GPU"
        }
        algorithms.append(algo_data)
    return {
        "status": "ok",
        "miner": "xmrig",
        "miner_version": data.get("version"),
        "uptime_s": data.get("uptime"),
        "algorithms": algorithms
    }
def collect_trex_stats():
    """Collect T-Rex miner stats"""
    host = os.environ.get("TREX_API_HOST", "127.0.0.1")
    port = int(os.environ.get("TREX_API_PORT", "4067"))
    url = f"http://{host}:{port}/summary"
    try:
        with urllib.request.urlopen(url, timeout=1.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        return {"status": "offline", "error": str(e)}
    algo = data.get("algorithm")
    algorithms = []
    if algo:
        hashrate = data.get("hashrate", 0)
        hashrate_hs = float(hashrate)
        gpus = data.get("gpus", [])
        thread_hashrates = {}
        if isinstance(gpus, list):
            for i, gpu in enumerate(gpus):
                gpu_hashrate = gpu.get("hashrate", 0)
                if gpu_hashrate:
                    thread_hashrates[f"gpu_{i}"] = gpu_hashrate
        algo_data = {
            "algorithm": algo,
            "hashrate_hs": hashrate_hs,
            "accepted_shares": data.get("accepted_count"),
            "rejected_shares": data.get("rejected_count"),
            "pool": data.get("url", "").split("://")[-1] if data.get("url") else None,
            "thread_hashrates": thread_hashrates if thread_hashrates else None
        }
        algorithms.append(algo_data)
    return {
        "status": "ok",
        "miner": "trex",
        "miner_version": data.get("version"),
        "uptime_s": data.get("uptime"),
        "algorithms": algorithms
    }
def collect_nbminer_stats():
    """Collect NBminer stats"""
    host = os.environ.get("NBMINER_API_HOST", "127.0.0.1")
    port = int(os.environ.get("NBMINER_API_PORT", "22333"))
    url = f"http://{host}:{port}/api/v1/status"
    try:
        with urllib.request.urlopen(url, timeout=1.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        return {"status": "offline", "error": str(e)}
    algo = data.get("miner", {}).get("algorithm")
    algorithms = []
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
        algo_data = {
            "algorithm": algo,
            "hashrate_hs": hashrate_hs,
            "accepted_shares": data.get("stratum", {}).get("accepted_shares"),
            "rejected_shares": data.get("stratum", {}).get("rejected_shares"),
            "pool": data.get("stratum", {}).get("url", "").split("://")[-1] if data.get("stratum", {}).get("url") else None,
            "thread_hashrates": thread_hashrates if thread_hashrates else None
        }
        algorithms.append(algo_data)
    return {
        "status": "ok",
        "miner": "nbminer",
        "miner_version": data.get("miner", {}).get("version"),
        "uptime_s": data.get("miner", {}).get("runtime"),
        "algorithms": algorithms
    }
def _decode_log_bytes(data):
    """Decodes miner log bytes to text by stripping 0x00 bytes before decoding, correctly handling UTF-8/ASCII, UTF-16, and a single chunk that mixes both."""
    if data.startswith(b"\xff\xfe") or data.startswith(b"\xfe\xff"):
        data = data[2:]
    return data.replace(b"\x00", b"").decode("utf-8", errors="ignore")
def _tail_file(path, max_bytes=131072):
    """Read the last max_bytes of a file as text (cheap tail, no deps)."""
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
        return _decode_log_bytes(data)
    except Exception:
        return None
_keryx_version_cache = {"version": "", "last_uptime_s": None}
def _query_binary_version(bin_path):
    """Runs `<bin_path> --version` and returns its first line, or "" on any failure; generic helper also used by collect_keryxd_stats() and collect_custom_log_miner_stats()."""
    try:
        out = subprocess.run(
            [bin_path, "--version"], capture_output=True, text=True, timeout=2.0
        )
        text = (out.stdout or out.stderr or "").strip()
        return text.splitlines()[0] if text else ""
    except Exception:
        return ""
def collect_keryx_stats():
    """Reads keryx-miner's JSON stats API on KERYX_API_HOST/KERYX_API_PORT for hashrate and accepted/rejected block counts; temp/fan/power still come from this agent's usual GPU stats collector."""
    api_host = os.environ.get("KERYX_API_HOST", "127.0.0.1")
    api_port = int(os.environ.get("KERYX_API_PORT", "3338"))
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
        return {"status": "error", "error": f"keryx-miner API unreachable at {api_host}:{api_port} (/stats, /v1/miner/stats): {last_err}"}
    device_re = re.compile(r"#(\d+)\s*\(([^)]+)\)")
    gpus = []
    for i, dev in enumerate(data.get("devices", []) or []):
        m = device_re.search(dev.get("id", "") or "")
        idx  = int(m.group(1)) if m else i
        name = m.group(2).strip() if m else (dev.get("id") or "")
        gpus.append({
            "gpu_id":      idx,
            "index":       idx,
            "name":        name,
            "hashrate_hs": dev.get("hashrate_hs", 0),
        })
    gpus.sort(key=lambda g: g["index"])
    total_hr_hs     = data.get("total_hashrate_hs", 0)
    accepted_blocks = data.get("accepted_blocks", 0)
    rejected_blocks = data.get("rejected_blocks", 0)
    uptime_s        = data.get("uptime_s", 0)
    last_uptime = _keryx_version_cache["last_uptime_s"]
    if last_uptime is None or uptime_s < last_uptime:
        _keryx_version_cache["version"] = _query_binary_version(KERYX_BIN_PATH)
    _keryx_version_cache["last_uptime_s"] = uptime_s
    return {
        "status": "ok", "miner": "keryx",
        "miner_version":  _keryx_version_cache["version"],
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
def collect_keryxd_stats():
    """Tails keryxd's log file for "Accepted N blocks" lines and sums the counts since the last poll, reporting the cumulative total via hashrate_hs/total_hashrate_hs."""
    default_log_path = os.path.join(os.environ.get("TEMP", "C:\\Temp"), "keryxd.log")
    log_path = os.environ.get("KERYXD_LOG_PATH", default_log_path)
    accepted_re = re.compile(r"Accepted\s+(\d+)\s+blocks?", re.IGNORECASE)
    share_state = _log_event_state.setdefault(log_path, {"offset": 0, "accepted_shares": 0})
    new_text = _read_new_log_bytes(log_path, share_state)
    if new_text is None:
        return {"status": "error", "error": f"could not read log file '{log_path}'"}
    if share_state.get("reset"):
        share_state["accepted_shares"] = 0
    for match in accepted_re.finditer(new_text):
        share_state["accepted_shares"] += int(match.group(1))
    accepted_shares = share_state["accepted_shares"]
    return {
        "status": "ok", "miner": "keryxd",
        "miner_version": "",
        "uptime_s": 0,
        "algorithms": [{
            "algorithm":   "keryxd-node",
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
_custom_miner_version_cache = {"version": "", "queried": False}
def collect_custom_log_miner_stats():
    """Best-effort telemetry for a custom miner with no stats API, scraped from CUSTOM_MINER_LOG_PATH by re-scanning the last CUSTOM_LOG_TAIL_BYTES each poll and taking the last matching hashrate/accepted/rejected line."""
    log_path = CUSTOM_MINER_LOG_PATH
    tail_bytes = int(os.environ.get("CUSTOM_LOG_TAIL_BYTES", "65536"))
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
    if not _custom_miner_version_cache["queried"]:
        if CUSTOM_MINER_BIN_PATH:
            _custom_miner_version_cache["version"] = _query_binary_version(CUSTOM_MINER_BIN_PATH)
        _custom_miner_version_cache["queried"] = True
    return {
        "status": "ok", "miner": CUSTOM_MINER_DISPLAY_NAME,
        "miner_version": _custom_miner_version_cache["version"],
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
def collect_full_stats():
    """Collect all system and miner statistics"""
    gpu_present = has_nvidia_gpu()
    gpu_list = collect_gpu_stats() if gpu_present else []
    stats = {
        "rig": RIG_NAME,
        "timestamp": int(time.time()),
        "cpu_temp": 0,
        "cpu_usage": collect_cpu_usage(),
        "load": collect_load(),
        "memory": collect_memory(),
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
            'sc query docker_events_cpu',
            shell=True,
            capture_output=True,
            text=True
        )
        if cpu_service_result.returncode == 0 and "RUNNING" in cpu_service_result.stdout:
            stats["cpu_service"] = {
                "state": "active",
                "uptime_seconds": 0,
                "service": "docker_events_cpu"
            }
        else:
            stats["cpu_service"] = {
                "state": "inactive",
                "uptime_seconds": 0,
                "service": "docker_events_cpu"
            }
    except:
        stats["cpu_service"] = {
            "state": "unknown",
            "uptime_seconds": 0,
            "service": "docker_events_cpu"
        }
    try:
        gpu_service_result = subprocess.run(
            'sc query docker_events_gpu',
            shell=True,
            capture_output=True,
            text=True
        )
        if gpu_service_result.returncode == 0 and "RUNNING" in gpu_service_result.stdout:
            stats["gpu_service"] = {
                "state": "active",
                "uptime_seconds": 0,
                "service": "docker_events_gpu"
            }
        else:
            stats["gpu_service"] = {
                "state": "inactive",
                "uptime_seconds": 0,
                "service": "docker_events_gpu"
            }
    except:
        stats["gpu_service"] = {
            "state": "unknown",
            "uptime_seconds": 0,
            "service": "docker_events_gpu"
        }    
    try:
        aux_service_result = subprocess.run(
            'sc query docker_events_aux',
            shell=True,
            capture_output=True,
            text=True
        )
        if aux_service_result.returncode == 0 and "RUNNING" in aux_service_result.stdout:
            stats["aux_service"] = {
                "state": "active",
                "uptime_seconds": 0,
                "service": "docker_events_aux"
            }
        else:
            stats["aux_service"] = {
                "state": "inactive",
                "uptime_seconds": 0,
                "service": "docker_events_aux"
            }
    except:
        stats["aux_service"] = {
            "state": "unknown",
            "uptime_seconds": 0,
            "service": "docker_events_aux"
        }
    stats["docker"] = collect_docker_containers()
    return stats
if __name__ == "__main__":
    stats = collect_full_stats()
    print(json.dumps(stats, indent=2))
