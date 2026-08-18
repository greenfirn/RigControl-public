sudo tee /usr/local/bin/rigcontrol_watchdog.py > /dev/null <<'EOF'
#!/usr/bin/env python3
"""
Reads /etc/rigcontrol/rigcontrol-watchdog.conf (per-algo thresholds/actions) and
/etc/rigcontrol/rigcontrol-agent.conf (MQTT login, CPU_SERVICE_NAME/GPU_SERVICE_NAME/AUX_SERVICE_NAME).
"""
import argparse
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
}
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
    publish_alert(RIG_NAME, algo, summary, [k for k, v in actions.items() if v])
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
                   global_alert_state=None):
    if last_conf_state is None:
        last_conf_state = {}
    if global_alert_state is None:
        global_alert_state = {"count": 0}
    conf = load_watchdog_conf(conf_path)
    global_settings = load_global_watchdog_settings(conf_path)
    agent_service_names = load_agent_service_names()
    sleep_seconds = min((s["check_interval_seconds"] for s in conf.values()), default=DEFAULT_ALGO_SETTINGS["check_interval_seconds"])
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
def main():
    ap = argparse.ArgumentParser(description="RigControl per-algorithm mining watchdog")
    ap.add_argument("--conf", default="/etc/rigcontrol/rigcontrol-watchdog.conf")
    args = ap.parse_args()
    log(f"Starting - conf={args.conf}")
    consecutive_fails = {}
    last_action_ts = {}
    last_conf_state = {}
    global_alert_state = {"count": 0}
    while True:
        sleep_seconds = 60
        try:
            sleep_seconds = run_one_cycle(
                args.conf, consecutive_fails, last_action_ts, last_conf_state, global_alert_state
            )
        except Exception as e:
            log(f"[error] Unexpected error during check: {e}")
        if sleep_seconds is None:
            log("[GLOBAL] Watchdog loop stopping itself now.")
            break
        time.sleep(sleep_seconds)
if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("Shutdown requested by user")
EOF
sudo chmod +x /usr/local/bin/rigcontrol_watchdog.py
if [[ ! -f /etc/rigcontrol/rigcontrol-watchdog.conf ]]; then
    sudo mkdir -p /etc/rigcontrol
    sudo tee /etc/rigcontrol/rigcontrol-watchdog.conf > /dev/null <<'EOF'
EOF
    echo "Wrote empty /etc/rigcontrol/rigcontrol-watchdog.conf - nothing is monitored yet. Configure real per-algo thresholds from the dashboard's Watchdog Config module (Apply to Selected Rigs), then start the watchdog service."
else
    echo "/etc/rigcontrol/rigcontrol-watchdog.conf already exists - leaving it as-is."
fi
AGENT_VENV="/usr/local/lib/rigcontrol-agent/.venv"
if [ ! -x "$AGENT_VENV/bin/pip" ]; then
    echo "Shared rig venv not found (or incomplete) - creating it at $AGENT_VENV ..."
    sudo mkdir -p "$(dirname "$AGENT_VENV")"
    sudo apt-get install -y python3-venv
    sudo python3 -m venv --clear "$AGENT_VENV"
    if [ ! -x "$AGENT_VENV/bin/pip" ]; then
        echo "ERROR: $AGENT_VENV/bin/pip still doesn't exist after venv creation - see any ensurepip/apt-get error above. Not starting the watchdog under a broken interpreter; fix the venv (apt-get install python3-venv) and re-run this script."
        exit 1
    fi
    sudo "$AGENT_VENV/bin/pip" install --upgrade pip
    sudo "$AGENT_VENV/bin/pip" install aiomqtt typing_extensions paho-mqtt requests
else
    sudo "$AGENT_VENV/bin/pip" install --quiet paho-mqtt || \
        echo "Warning: couldn't confirm paho-mqtt in $AGENT_VENV - ACTION_EMAIL_NOTIFY/ACTION_SMS_NOTIFY won't be able to reach the dashboard server until this is installed."
fi
sudo tee /etc/systemd/system/rigcontrol_watchdog.service > /dev/null <<EOF
[Unit]
Description=RigControl Per-Algorithm Mining Watchdog
After=docker_events_gpu.service docker_events_cpu.service rigcontrol-agent.service
Wants=rigcontrol-agent.service
[Service]
Type=simple
User=root
ExecStart=$AGENT_VENV/bin/python3 /usr/local/bin/rigcontrol_watchdog.py \\
    --conf /etc/rigcontrol/rigcontrol-watchdog.conf
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
echo "rigcontrol_watchdog.service installed but not started - configure real thresholds from the dashboard's Watchdog Config module, then start it from the WD button (or: sudo systemctl enable --now rigcontrol_watchdog.service)."
