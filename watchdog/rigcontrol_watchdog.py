#!/usr/bin/env python3
"""
Reads /etc/rigcontrol/rigcontrol-watchdog.conf (per-algo thresholds/actions) and
/etc/rigcontrol/rigcontrol-agent.conf (MQTT login, CPU_SERVICE_NAME/GPU_SERVICE_NAME/AUX_SERVICE_NAME).
"""
import argparse
import base64
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
sys.path.insert(0, "/usr/local/bin")
import rigcontrol_telemetry as telemetry
RIG_NAME = socket.gethostname()
TOPIC_PREFIX = "rigcontrol"
WATCHDOG_ALERT_TOPIC = f"{TOPIC_PREFIX}/{RIG_NAME}/watchdog_alert"
def log(msg):
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    print(f"[Watchdog] {ts} UTC {msg}", flush=True)
DEFAULT_ACTIONS = {
    "ACTION_RESTART_CPU": True,
    "ACTION_RESTART_GPU": True,
    "ACTION_REBOOT_RIG": False,
    "ACTION_EMAIL_NOTIFY": False,
    "ACTION_SMS_NOTIFY": False,
    "ACTION_RESTART_FAN": False,
    "ACTION_RESTART_AUX": False,
    "ACTION_CUSTOM_SCRIPT": False,
}
DEFAULT_ALGO_SETTINGS = {
    "min_hashrate_hs": 1.0,
    "min_watts_total": 20.0,
    "max_watts_total": 0.0,  # 0 disables the check
    "grace_checks": 3,
    "cooldown_seconds": 600,
    "check_interval_seconds": 60,
    "actions": dict(DEFAULT_ACTIONS),
    "custom_script": "",
}
DEFAULT_GLOBAL_SETTINGS = {
    "stop_after_fails": 5,  # 0 disables this - the service never self-stops
    "mining_watchdog_enabled": True,  # False skips hashrate/watts monitoring entirely
    "mining_interval_seconds": 60,  # how often the mining watchdog re-checks health
    "log_watcher_enabled": False,
    "log_watcher_interval_seconds": 60,  # how often the log watcher re-scans its log(s)
    "log_watcher_slots": [],  # e.g. ["cpu", "gpu", "aux"]
    "log_watcher_terms": [],  # e.g. [("Found a block on", "important"), ("error", "critical")]
    "log_watcher_custom_script": "",  # legacy shared-script fallback (pre-per-term profiles)
}
LOG_WATCHER_SEVERITIES = ("good", "warn", "important", "critical")
LOG_WATCHER_SLOT_LOG_PATHS = {
    "cpu": "/run/rigcontrol/cpu_miner.log",
    "gpu": "/run/rigcontrol/gpu_miner.log",
    "aux": "/run/rigcontrol/aux_miner.log",
}
# Same action keys as the mining watchdog's DEFAULT_ACTIONS - ACTION_CUSTOM_SCRIPT runs
# the term's own custom_script.
LOG_WATCHER_TERM_ACTION_KEYS = (
    "ACTION_RESTART_CPU", "ACTION_RESTART_GPU", "ACTION_RESTART_FAN", "ACTION_RESTART_AUX",
    "ACTION_EMAIL_NOTIFY", "ACTION_SMS_NOTIFY", "ACTION_REBOOT_RIG", "ACTION_CUSTOM_SCRIPT",
)
def _b64_decode_utf8(b64_text):
    try:
        return base64.b64decode(b64_text).decode("utf-8")
    except Exception:
        return ""
_TERM_SCRIPT_RE = re.compile(r'LOG_WATCHER_TERM_SCRIPT_BEGIN (\d+)\n([\s\S]*?)\nLOG_WATCHER_TERM_SCRIPT_END')
def _parse_log_watcher_term_scripts(text):
    """Parses LOG_WATCHER_TERM_SCRIPT_BEGIN <index>/END blocks. Returns {index: script_text}."""
    scripts = {}
    for m in _TERM_SCRIPT_RE.finditer(text):
        try:
            scripts[int(m.group(1))] = m.group(2)
        except ValueError:
            continue
    return scripts
def _parse_log_watcher_terms(raw_value, legacy_script="", term_scripts=None):
    """Parses LOG_WATCHER_TERMS - ';'-separated rows of
    '<contains-csv>|<not-contains-csv>|<severity>|<actions-csv>|<slot>'. Each term's script
    comes from term_scripts (keyed by row position), falling back to an inline base64 field
    (old 6-field format) then legacy_script (oldest shared-script format)."""
    term_scripts = term_scripts or {}
    terms = []
    for idx, row in enumerate(raw_value.split(";")):
        row = row.strip()
        if not row:
            continue
        raw_parts = row.split("|")
        legacy_script_b64 = ""
        if len(raw_parts) >= 6:
            contains_raw, not_contains_raw, severity, actions_raw, legacy_script_b64, slot_raw = raw_parts[:6]
        else:
            parts = list(raw_parts)
            while len(parts) < 5:
                parts.append("")
            contains_raw, not_contains_raw, severity, actions_raw, slot_raw = parts[:5]
        contains = [c.strip() for c in contains_raw.split(",") if c.strip()]
        not_contains = [c.strip() for c in not_contains_raw.split(",") if c.strip()]
        if not contains:
            continue
        severity = severity.strip().lower()
        if severity not in LOG_WATCHER_SEVERITIES:
            severity = "warn"
        action_keys = {a.strip().upper() for a in actions_raw.split(",") if a.strip()}
        actions = {key: (key in action_keys) for key in LOG_WATCHER_TERM_ACTION_KEYS}
        if idx in term_scripts:
            custom_script = term_scripts[idx]
        elif legacy_script_b64.strip():
            custom_script = _b64_decode_utf8(legacy_script_b64)
        else:
            custom_script = legacy_script
        slot = slot_raw.strip().lower()
        if slot not in LOG_WATCHER_SLOT_LOG_PATHS:
            slot = "all"
        terms.append({
            "contains": contains,
            "not_contains": not_contains,
            "severity": severity,
            "actions": actions,
            "custom_script": custom_script,
            "slot": slot,
        })
    return terms
def _log_watcher_term_matches(line_lower, term):
    for c in term["contains"]:
        if c.lower() not in line_lower:
            return False
    for nc in term["not_contains"]:
        if nc.lower() in line_lower:
            return False
    return True
_BLOCK_HEADER_RE = re.compile(r'^\[(.+?)\]\s*$', re.MULTILINE)
_KV_RE = re.compile(r'^([A-Z_]+)\s+"([^"]*)"\s*$', re.MULTILINE)
_SCRIPT_RE = re.compile(r'CUSTOM_SCRIPT_BEGIN\n([\s\S]*?)\nCUSTOM_SCRIPT_END')
def _parse_block(body):
    kv = {m.group(1): m.group(2) for m in _KV_RE.finditer(body)}
    script_match = _SCRIPT_RE.search(body)
    custom_script = script_match.group(1) if script_match else ""
    def num(key, default, cast=float):
        try:
            return cast(kv[key])
        except (KeyError, ValueError, TypeError):
            return default
    actions = dict(DEFAULT_ACTIONS)
    for key in DEFAULT_ACTIONS:
        if key in kv:
            actions[key] = kv[key] == "1"
    return {
        "min_hashrate_hs": num("MIN_HASHRATE_HS", DEFAULT_ALGO_SETTINGS["min_hashrate_hs"]),
        "min_watts_total": num("MIN_WATTS_TOTAL", DEFAULT_ALGO_SETTINGS["min_watts_total"]),
        "max_watts_total": num("MAX_WATTS_TOTAL", DEFAULT_ALGO_SETTINGS["max_watts_total"]),
        "grace_checks": max(1, int(num("GRACE_CHECKS", DEFAULT_ALGO_SETTINGS["grace_checks"], int))),
        "cooldown_seconds": max(0, int(num("COOLDOWN_SECONDS", DEFAULT_ALGO_SETTINGS["cooldown_seconds"], int))),
        "check_interval_seconds": max(5, int(num("CHECK_INTERVAL_SECONDS", DEFAULT_ALGO_SETTINGS["check_interval_seconds"], int))),
        "actions": actions,
        "custom_script": custom_script,
    }
def load_watchdog_conf(path):
    try:
        with open(path, "r") as f:
            text = f.read()
    except Exception as e:
        log(f"[conf] Error reading {path}: {e}")
        text = ""
    thresholds = {}
    matches = list(_BLOCK_HEADER_RE.finditer(text))
    for i, m in enumerate(matches):
        algo = m.group(1).strip()
        if not algo:
            continue
        body_start = m.end()
        body_end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        thresholds[algo.lower()] = _parse_block(text[body_start:body_end])
    return thresholds
def settings_for(conf, algo_name):
    key = (algo_name or "").strip().lower()
    return conf.get(key) or conf.get("default")
def load_global_watchdog_settings(path):
    settings = dict(DEFAULT_GLOBAL_SETTINGS)
    try:
        with open(path, "r") as f:
            text = f.read()
    except Exception as e:
        log(f"[conf] Error reading {path} for global settings: {e}")
        return settings
    m = re.search(r'^GLOBAL_STOP_AFTER_FAILS\s+"(-?\d+)"\s*$', text, re.MULTILINE)
    if m:
        try:
            settings["stop_after_fails"] = max(0, int(m.group(1)))
        except ValueError:
            pass
    m = re.search(r'^MINING_WATCHDOG_ENABLED\s+"(\d)"\s*$', text, re.MULTILINE)
    if m:
        settings["mining_watchdog_enabled"] = m.group(1) == "1"
    m = re.search(r'^MINING_INTERVAL_SECONDS\s+"(\d+)"\s*$', text, re.MULTILINE)
    if m:
        try:
            settings["mining_interval_seconds"] = max(5, int(m.group(1)))
        except ValueError:
            pass
    m = re.search(r'^LOG_WATCHER_ENABLED\s+"(\d)"\s*$', text, re.MULTILINE)
    if m:
        settings["log_watcher_enabled"] = m.group(1) == "1"
    m = re.search(r'^LOG_WATCHER_INTERVAL_SECONDS\s+"(\d+)"\s*$', text, re.MULTILINE)
    if m:
        try:
            settings["log_watcher_interval_seconds"] = max(5, int(m.group(1)))
        except ValueError:
            pass
    m = re.search(r'^LOG_WATCHER_SLOTS\s+"([^"]*)"\s*$', text, re.MULTILINE)
    if m:
        settings["log_watcher_slots"] = [
            s.strip() for s in m.group(1).split(",") if s.strip() in LOG_WATCHER_SLOT_LOG_PATHS
        ]
    m = re.search(r'LOG_WATCHER_SCRIPT_BEGIN\n([\s\S]*?)\nLOG_WATCHER_SCRIPT_END', text)
    legacy_script = m.group(1) if m else ""
    if m:
        settings["log_watcher_custom_script"] = legacy_script
    term_scripts = _parse_log_watcher_term_scripts(text)
    m = re.search(r'^LOG_WATCHER_TERMS\s+"([^"]*)"\s*$', text, re.MULTILINE)
    if m:
        settings["log_watcher_terms"] = _parse_log_watcher_terms(
            m.group(1), legacy_script=legacy_script, term_scripts=term_scripts
        )
    return settings
def stop_watchdog_service():
    try:
        subprocess.run(
            ["sudo", "systemctl", "stop", "rigcontrol_watchdog.service"],
            capture_output=True, timeout=10,
        )
    except Exception as e:
        log(f"[GLOBAL] Error stopping rigcontrol_watchdog.service: {e}")
AGENT_CONF_PATH = "/etc/rigcontrol/rigcontrol-agent.conf"
def _load_kv_conf(path):
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
        log(f"[conf] Error reading {path}: {e}")
    return cfg
def load_mqtt_login():
    cfg = _load_kv_conf(AGENT_CONF_PATH)
    if not cfg:
        return None
    if "AWS_MQTT_HOST" in cfg:
        return None
    host = cfg.get("BROKER_HOST")
    if not host:
        return None
    try:
        port = int(cfg.get("BROKER_PORT", 1883))
    except (TypeError, ValueError):
        port = 1883
    return host, port, cfg.get("BROKER_USER"), cfg.get("BROKER_PASS")
def load_agent_service_names():
    cfg = _load_kv_conf(AGENT_CONF_PATH)
    return {
        "cpu_service": cfg.get("CPU_SERVICE_NAME", "").strip() or CPU_SERVICE_DEFAULT,
        "gpu_service": cfg.get("GPU_SERVICE_NAME", "").strip() or GPU_SERVICE_DEFAULT,
        "aux_service": cfg.get("AUX_SERVICE_NAME", "").strip() or AUX_SERVICE_DEFAULT,
    }
def publish_alert(rig, algo, reasons, actions):
    payload_text = json.dumps({
        "rig": rig,
        "algo": algo,
        "reasons": reasons,
        "actions": actions,
        "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    })
    login = load_mqtt_login()
    if not login:
        log("[mqtt] No local broker configured in rigcontrol-agent.conf (or AWS IoT mode) - "
            "skipping watchdog_alert publish; ACTION_EMAIL_NOTIFY/ACTION_SMS_NOTIFY (if set) will not be delivered")
        return
    host, port, user, password = login
    try:
        import paho.mqtt.client as mqtt
    except ImportError:
        log("[mqtt] paho-mqtt not installed - skipping alert publish (pip3 install paho-mqtt). "
            "ACTION_EMAIL_NOTIFY/ACTION_SMS_NOTIFY (if set) will not be delivered without it")
        return
    try:
        client = mqtt.Client(callback_api_version=mqtt.CallbackAPIVersion.VERSION2)
        if user:
            client.username_pw_set(user, password)
        client.connect(host, port, keepalive=10)
        client.loop_start()
        client.publish(WATCHDOG_ALERT_TOPIC, payload_text, qos=1)
        time.sleep(0.5)
        client.loop_stop()
        client.disconnect()
    except Exception as e:
        log(f"[mqtt] Error publishing alert: {e}")
_log_watcher_offsets = {}
def trigger_log_watcher_term_actions(label, actions, line, restarted_this_cycle, agent_service_names,
                                      custom_script_text=""):
    """Fires a term's restart/notify/reboot/script actions; always publishes to the Status Log."""
    cpu_service = agent_service_names.get("cpu_service", CPU_SERVICE_DEFAULT)
    gpu_service = agent_service_names.get("gpu_service", GPU_SERVICE_DEFAULT)
    aux_service = agent_service_names.get("aux_service", AUX_SERVICE_DEFAULT)
    if actions.get("ACTION_RESTART_CPU") and cpu_service not in restarted_this_cycle:
        restart_service(cpu_service)
        restarted_this_cycle.add(cpu_service)
    if actions.get("ACTION_RESTART_GPU") and gpu_service not in restarted_this_cycle:
        restart_service(gpu_service)
        restarted_this_cycle.add(gpu_service)
    if actions.get("ACTION_RESTART_AUX") and aux_service not in restarted_this_cycle:
        restart_service(aux_service)
        restarted_this_cycle.add(aux_service)
    if actions.get("ACTION_RESTART_FAN") and FAN_SERVICE not in restarted_this_cycle:
        restart_service(FAN_SERVICE)
        restarted_this_cycle.add(FAN_SERVICE)
    if actions.get("ACTION_CUSTOM_SCRIPT"):
        run_custom_script(label, custom_script_text)
    publish_alert(RIG_NAME, label, line, [k for k, v in actions.items() if v])
    if actions.get("ACTION_REBOOT_RIG"):
        reboot_rig()
def run_log_watcher_cycle(global_settings):
    """Tails each configured slot log; each term (its own contains/not-contains, slot
    filter, and script) fires its own actions on a match and publishes to the Status Log."""
    if not global_settings.get("log_watcher_enabled"):
        return
    slots = global_settings.get("log_watcher_slots") or []
    terms = global_settings.get("log_watcher_terms") or []
    if not slots or not terms:
        return
    agent_service_names = load_agent_service_names()
    restarted_this_cycle = set()
    for slot in slots:
        path = LOG_WATCHER_SLOT_LOG_PATHS.get(slot)
        if not path or not os.path.isfile(path):
            continue
        if path not in _log_watcher_offsets:
            # First time watching this log - start from current end, skip backfill.
            try:
                start_offset = os.path.getsize(path)
            except OSError:
                start_offset = 0
            _log_watcher_offsets[path] = {"offset": start_offset}
        state = _log_watcher_offsets[path]
        new_text = telemetry._read_new_log_bytes(path, state)
        if not new_text:
            continue
        for line in new_text.splitlines():
            line = line.strip()
            if not line:
                continue
            line_lower = line.lower()
            for term in terms:
                term_slot = term.get("slot", "all")
                if term_slot != "all" and term_slot != slot:
                    continue
                if _log_watcher_term_matches(line_lower, term):
                    label_text = ", ".join(term["contains"])
                    severity_label = term["severity"].upper()
                    log(f"[log-watcher] {slot}: [{severity_label}] matched \"{label_text}\" - {line}")
                    trigger_log_watcher_term_actions(
                        f"[{severity_label}] {label_text} ({slot})", term["actions"], line,
                        restarted_this_cycle, agent_service_names, term.get("custom_script", ""),
                    )
                    break
def algo_combined_hashrate(entry):
    cpu = entry.get("cpu_hashrate_hs")
    gpu = entry.get("gpu_hashrate_hs")
    if cpu is not None or gpu is not None:
        total = 0.0
        for val in (cpu, gpu):
            try:
                total += float(val) if val is not None else 0.0
            except (TypeError, ValueError):
                pass
        return total
    try:
        return float(entry.get("hashrate_hs") or 0)
    except (TypeError, ValueError):
        return 0.0
def collect_snapshot():
    stats = telemetry.collect_full_stats()
    total_gpu_watts = 0.0
    for gpu in stats.get("gpus", []) or []:
        try:
            total_gpu_watts += float(gpu.get("power_watts") or 0)
        except (TypeError, ValueError):
            pass
    algo_totals = {}
    for key, val in stats.items():
        if not key.startswith("miner_") or not isinstance(val, dict):
            continue
        if val.get("status") != "ok":
            continue
        for entry in val.get("algorithms", []) or []:
            name = (entry.get("algorithm") or "unknown").strip().lower()
            algo_totals[name] = algo_totals.get(name, 0.0) + algo_combined_hashrate(entry)
    return total_gpu_watts, algo_totals
CPU_SERVICE_DEFAULT = "docker_events_cpu.service"
GPU_SERVICE_DEFAULT = "docker_events_gpu.service"
AUX_SERVICE_DEFAULT = "docker_events_aux.service"
FAN_SERVICE = "fan-curve.service"
def service_is_active(service_name):
    try:
        result = subprocess.run(
            ["systemctl", "is-active", service_name],
            capture_output=True, text=True, timeout=5
        )
        return result.stdout.strip() == "active"
    except Exception as e:
        log(f"[systemd] Error checking {service_name}: {e}")
        return False
def restart_service(service_name):
    log(f"[systemd] Restarting {service_name} ...")
    try:
        result = subprocess.run(
            ["systemctl", "restart", service_name],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0:
            log(f"[systemd] {service_name} restarted successfully")
        else:
            log(f"[systemd] Restart of {service_name} exited {result.returncode}: {result.stderr.strip()}")
    except Exception as e:
        log(f"[systemd] Error restarting {service_name}: {e}")
def reboot_rig():
    log("[system] ACTION_REBOOT_RIG - rebooting now ...")
    try:
        subprocess.run(["systemctl", "reboot"], timeout=10)
    except Exception as e:
        log(f"[system] Error triggering reboot: {e}")
def run_custom_script(algo, script_text):
    if not script_text.strip():
        log(f"[custom-script] ACTION_CUSTOM_SCRIPT enabled for '{algo}' but the script body is empty - skipping")
        return
    try:
        with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
            if not script_text.startswith("#!"):
                f.write("#!/bin/bash\n")
            f.write(script_text)
            script_path = f.name
        os.chmod(script_path, 0o700)
        log(f"[custom-script] Running custom script for '{algo}' ({script_path}) ...")
        result = subprocess.run(["/bin/bash", script_path], capture_output=True, text=True, timeout=120)
        if result.stdout.strip():
            log(f"[custom-script] stdout: {result.stdout.strip()}")
        if result.stderr.strip():
            log(f"[custom-script] stderr: {result.stderr.strip()}")
        log(f"[custom-script] Exited {result.returncode}")
    except Exception as e:
        log(f"[custom-script] Error running custom script for '{algo}': {e}")
    finally:
        try:
            os.unlink(script_path)
        except Exception:
            pass
def docker_status():
    try:
        result = subprocess.run(["docker", "ps", "-q"], capture_output=True, text=True, timeout=5)
    except FileNotFoundError:
        return "unavailable"
    except Exception as e:
        log(f"[docker] Error checking Docker: {e}")
        return "unavailable"
    if result.returncode != 0:
        return "unavailable"
    return "containers_running" if result.stdout.strip() else "no_containers"
def evaluate_algo(algo, hashrate, total_gpu_watts, settings):
    reasons = []
    if settings["min_hashrate_hs"] > 0 and hashrate < settings["min_hashrate_hs"]:
        reasons.append(f"hashrate {hashrate:.0f} H/s < min {settings['min_hashrate_hs']:.0f} H/s")
    if settings["min_watts_total"] > 0 and total_gpu_watts < settings["min_watts_total"]:
        reasons.append(f"GPU watts {total_gpu_watts:.1f}W < min {settings['min_watts_total']:.1f}W")
    if settings["max_watts_total"] > 0 and total_gpu_watts > settings["max_watts_total"]:
        reasons.append(f"GPU watts {total_gpu_watts:.1f}W > max {settings['max_watts_total']:.1f}W")
    return reasons
def trigger_actions(algo, settings, reasons, restarted_this_cycle, service_names=None):
    if service_names is None:
        service_names = {}
    cpu_service = service_names.get("cpu_service", CPU_SERVICE_DEFAULT)
    gpu_service = service_names.get("gpu_service", GPU_SERVICE_DEFAULT)
    aux_service = service_names.get("aux_service", AUX_SERVICE_DEFAULT)
    actions = settings["actions"]
    summary = "; ".join(reasons)
    log(f"[ALERT] '{algo}' unhealthy for {settings['grace_checks']} consecutive checks - {summary}")
    if actions["ACTION_RESTART_CPU"] and cpu_service not in restarted_this_cycle:
        restart_service(cpu_service)
        restarted_this_cycle.add(cpu_service)
    if actions["ACTION_RESTART_GPU"] and gpu_service not in restarted_this_cycle:
        restart_service(gpu_service)
        restarted_this_cycle.add(gpu_service)
    if actions["ACTION_RESTART_AUX"] and aux_service not in restarted_this_cycle:
        restart_service(aux_service)
        restarted_this_cycle.add(aux_service)
    if actions["ACTION_RESTART_FAN"] and FAN_SERVICE not in restarted_this_cycle:
        restart_service(FAN_SERVICE)
        restarted_this_cycle.add(FAN_SERVICE)
    if actions["ACTION_CUSTOM_SCRIPT"]:
        run_custom_script(algo, settings["custom_script"])
    publish_alert(RIG_NAME, f"{algo} unhealthy", summary, [k for k, v in actions.items() if v])
    if actions["ACTION_REBOOT_RIG"]:
        reboot_rig()
def _format_actions(actions):
    enabled = [k[len("ACTION_"):] for k, v in actions.items() if v]
    return ", ".join(enabled) if enabled else "none"
def format_conf_summary(conf):
    if not conf:
        return "  (empty - nothing configured, nothing is being monitored or enforced)"
    lines = []
    for algo in sorted(conf.keys()):
        s = conf[algo]
        min_hr = f"{s['min_hashrate_hs']:.0f} H/s" if s["min_hashrate_hs"] > 0 else "off"
        min_w = f"{s['min_watts_total']:.1f}W" if s["min_watts_total"] > 0 else "off"
        max_w = f"{s['max_watts_total']:.1f}W" if s["max_watts_total"] > 0 else "off"
        lines.append(
            f"  [{algo}] min_hashrate={min_hr} min_watts={min_w} max_watts={max_w} "
            f"grace={s['grace_checks']} cooldown={s['cooldown_seconds']}s "
            f"interval={s['check_interval_seconds']}s actions=[{_format_actions(s['actions'])}]"
        )
    return "\n".join(lines)
def run_one_cycle(conf_path, consecutive_fails, last_action_ts, last_conf_state=None,
                   global_alert_state=None, global_settings=None):
    """Runs one mining health-check cycle - independent cadence from run_log_watcher_cycle()."""
    if last_conf_state is None:
        last_conf_state = {}
    if global_alert_state is None:
        global_alert_state = {"count": 0}
    conf = load_watchdog_conf(conf_path)
    if global_settings is None:
        global_settings = load_global_watchdog_settings(conf_path)
    agent_service_names = load_agent_service_names()
    sleep_seconds = global_settings.get("mining_interval_seconds", 60)
    if not global_settings.get("mining_watchdog_enabled", True):
        if consecutive_fails:
            log("[skip] Mining Watchdog is disabled (MINING_WATCHDOG_ENABLED \"0\") - resetting fail counters")
            consecutive_fails.clear()
        return sleep_seconds
    conf_summary = format_conf_summary(conf)
    if last_conf_state.get("summary") != conf_summary:
        log(f"[config] Currently monitored algorithm(s) from {conf_path}:\n{conf_summary}")
        last_conf_state["summary"] = conf_summary
    if docker_status() == "containers_running":
        if consecutive_fails:
            log("[skip] Docker container(s) running - docker workload has taken over, resetting fail counters")
        consecutive_fails.clear()
        return sleep_seconds
    cpu_service = agent_service_names["cpu_service"]
    gpu_service = agent_service_names["gpu_service"]
    aux_service = agent_service_names["aux_service"]
    if not service_is_active(cpu_service) and not service_is_active(gpu_service) and not service_is_active(aux_service):
        if consecutive_fails:
            log(f"[skip] Neither {cpu_service}, {gpu_service}, nor {aux_service} is active - resetting fail counters")
        consecutive_fails.clear()
        return sleep_seconds
    total_gpu_watts, algo_totals = collect_snapshot()
    if not algo_totals:
        algo_totals = {"(none detected)": 0.0}
    restarted_this_cycle = set()
    healthy_algos = set()
    for algo, hashrate in algo_totals.items():
        settings = settings_for(conf, algo)
        if settings is None:
            if consecutive_fails.pop(algo, None):
                log(f"[check] '{algo}' no longer has a config block - clearing its fail counter, not monitoring it")
            continue
        reasons = evaluate_algo(algo, hashrate, total_gpu_watts, settings)
        if not reasons:
            healthy_algos.add(algo)
            continue
        consecutive_fails[algo] = consecutive_fails.get(algo, 0) + 1
        log(f"[check] '{algo}' FAIL ({consecutive_fails[algo]}/{settings['grace_checks']}): {'; '.join(reasons)}")
        if consecutive_fails[algo] < settings["grace_checks"]:
            continue
        since_last = time.time() - last_action_ts.get(algo, 0.0)
        if since_last < settings["cooldown_seconds"]:
            log(f"[check] '{algo}' grace threshold hit but still in cooldown "
                f"({since_last:.0f}s / {settings['cooldown_seconds']}s) - not acting again yet")
            continue
        trigger_actions(algo, settings, reasons, restarted_this_cycle, agent_service_names)
        last_action_ts[algo] = time.time()
        consecutive_fails[algo] = 0
        stop_after = global_settings.get("stop_after_fails", 0)
        global_alert_state["count"] = global_alert_state.get("count", 0) + 1
        if stop_after > 0 and global_alert_state["count"] >= stop_after:
            log(f"[GLOBAL] {global_alert_state['count']} total action(s)/notification(s) fired "
                f"across all algorithms - reached the configured limit of {stop_after}. "
                f"Stopping the watchdog service itself rather than continuing to restart "
                f"things on what looks like a persistently unhealthy rig - a human needs "
                f"to look at this and restart the service manually once resolved.")
            stop_watchdog_service()
            return None
    for algo in healthy_algos:
        if consecutive_fails.pop(algo, None):
            log(f"[check] '{algo}' OK - healthy again, resetting fail counter")
    if healthy_algos:
        ok_summary = ", ".join(f"{a}: {algo_totals[a]:.0f} H/s" for a in sorted(healthy_algos))
        log(f"[check] OK - {ok_summary}, GPU watts: {total_gpu_watts:.1f}W")
    if not consecutive_fails and global_alert_state.get("count", 0) > 0:
        log(f"[GLOBAL] All monitored algorithm(s) healthy - resetting the global "
            f"action/notification count (was {global_alert_state['count']}, now 0)")
        global_alert_state["count"] = 0
    return sleep_seconds
MAIN_TICK_SECONDS = 5  # housekeeping tick - each subsystem still only actually runs on its own interval
def main():
    ap = argparse.ArgumentParser(description="RigControl per-algorithm mining watchdog")
    ap.add_argument("--conf", default="/etc/rigcontrol/rigcontrol-watchdog.conf")
    args = ap.parse_args()
    log(f"Starting - conf={args.conf}")
    consecutive_fails = {}
    last_action_ts = {}
    last_conf_state = {}
    global_alert_state = {"count": 0}
    next_mining_check_at = 0.0
    next_log_watcher_at = 0.0
    while True:
        now = time.time()
        try:
            global_settings = load_global_watchdog_settings(args.conf)
        except Exception as e:
            log(f"[error] Unexpected error loading global settings: {e}")
            global_settings = dict(DEFAULT_GLOBAL_SETTINGS)
        if now >= next_mining_check_at:
            mining_interval = DEFAULT_ALGO_SETTINGS["check_interval_seconds"]
            try:
                mining_interval = run_one_cycle(
                    args.conf, consecutive_fails, last_action_ts, last_conf_state,
                    global_alert_state, global_settings,
                )
            except Exception as e:
                log(f"[error] Unexpected error during mining check: {e}")
            if mining_interval is None:
                log("[GLOBAL] Watchdog loop stopping itself now.")
                break
            next_mining_check_at = time.time() + mining_interval
        if global_settings.get("log_watcher_enabled") and now >= next_log_watcher_at:
            log_watcher_interval = global_settings.get("log_watcher_interval_seconds", 60)
            try:
                run_log_watcher_cycle(global_settings)
            except Exception as e:
                log(f"[log-watcher] Unexpected error: {e}")
            next_log_watcher_at = time.time() + log_watcher_interval
        time.sleep(MAIN_TICK_SECONDS)
if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("Shutdown requested by user")
