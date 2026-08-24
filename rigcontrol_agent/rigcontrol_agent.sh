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
def log(msg):
    print(f"[RigControl] {msg}", flush=True)
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
_custom_miner_slots = {"cpu": "", "gpu": "", "aux": ""}
_custom_miner_conf_paths = {"cpu": "", "gpu": "", "aux": ""}
def resolve_custom_miner():
    """Re-resolves the custom-miner slot/name/env vars for ALL THREE slots
    (cpu/gpu/aux) independently - more than one slot can simultaneously run
    a miner unrecognized by telemetry._BUILTIN_MINER_PROCESS_MAP (e.g. GPU
    running keryx-miner while AUX runs keryxd), and each slot needs its own
    registered custom-miner name so neither one starves the other out of
    telemetry collection. Called once at startup, then re-run whenever
    telemetry.consume_miners_changed_flag() reports the running-miner
    process set changed (see publish_status / stats_db_periodic_loop) so a
    miner binary/version change picked up while the agent is already
    running doesn't require an agent restart to be detected."""
    global _custom_miner_slots, _custom_miner_conf_paths
    for _slot_name, _rig_conf_path in (
        ("gpu", "/etc/rigcontrol/rig-gpu.conf"),
        ("cpu", "/etc/rigcontrol/rig-cpu.conf"),
        ("aux", "/etc/rigcontrol/rig-aux.conf"),
    ):
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
            telemetry.set_custom_miner_process_name(_slot_name, "")
            _custom_miner_slots[_slot_name] = ""
            _custom_miner_conf_paths[_slot_name] = ""
            continue
        _resolved_lower = _resolved_name.strip().lower()
        _already_known = (
            _resolved_lower in telemetry._BUILTIN_MINER_PROCESS_MAP
            or _resolved_lower in set(telemetry._BUILTIN_MINER_PROCESS_MAP.values())
        )
        if _already_known:
            _source_desc = f"CUSTOM_MINER_BIN_{_slot_name.upper()} basename" if _override_bin else str(_rig_conf_path)
            log(f"[Config] {_source_desc} MINER='{_resolved_name}' already has a known collector - not treating as custom")
            telemetry.set_custom_miner_process_name(_slot_name, "")
            _custom_miner_slots[_slot_name] = ""
            _custom_miner_conf_paths[_slot_name] = ""
            continue
        telemetry.set_custom_miner_process_name(_slot_name, _resolved_name)
        _custom_miner_slots[_slot_name] = _resolved_name
        _custom_miner_conf_paths[_slot_name] = _rig_conf_path
        if _override_bin:
            log(f"[Config] CUSTOM_MINER_PROCESS_NAME (manual, from CUSTOM_MINER_BIN_{_slot_name.upper()} basename, conf/json skipped) = {_resolved_name}")
        else:
            log(f"[Config] CUSTOM_MINER_PROCESS_NAME (auto-detected from {_rig_conf_path}) = {_resolved_name}")
        _miner_key = telemetry._sanitize_miner_key(_resolved_name)
        for _cfg_key, _cfg_val in cfg.items():
            if _cfg_key.startswith(f"{_miner_key}_") and _cfg_val.strip():
                os.environ[_cfg_key] = _cfg_val.strip()
                log(f"[Config] {_cfg_key} (rigcontrol-agent.conf) = {_cfg_val.strip()}")
        _custom_bin_override = cfg.get(f"CUSTOM_MINER_BIN_{_slot_name.upper()}", "").strip()
        if _custom_bin_override and f"{_miner_key}_BIN" not in os.environ:
            os.environ[f"{_miner_key}_BIN"] = _custom_bin_override
            log(f"[Config] {_miner_key}_BIN (from CUSTOM_MINER_BIN_{_slot_name.upper()}) = {_custom_bin_override}")
        if f"{_miner_key}_LOG_PATH" not in os.environ:
            os.environ[f"{_miner_key}_LOG_PATH"] = f"/run/rigcontrol/{_slot_name}_miner.log"
            log(f"[Config] {_miner_key}_LOG_PATH (auto-derived from {_slot_name} slot) = {os.environ[f'{_miner_key}_LOG_PATH']}")
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
    extra_env = {}
    first_line = command.strip().splitlines()[0].strip() if command.strip() else ""
    if first_line in ("cpu.api", "gpu.api", "aux.api"):
        slot = first_line.split(".", 1)[0]
        try:
            resolved = await asyncio.to_thread(telemetry.resolve_active_miner_api, slot)
        except Exception as e:
            resolved = {"method": "none", "reason": f"resolution error: {e}"}
        prefix = f"{slot.upper()}_API_"
        extra_env[f"{prefix}METHOD"]       = resolved.get("method", "none")
        extra_env[f"{prefix}URL"]          = resolved.get("url", "")
        extra_env[f"{prefix}URL_FALLBACK"] = resolved.get("url_fallback", "")
        extra_env[f"{prefix}TCP_HOST"]     = resolved.get("host", "")
        extra_env[f"{prefix}TCP_PORT"]     = str(resolved.get("port", "") or "")
        extra_env[f"{prefix}TCP_PAYLOAD"]  = resolved.get("payload", "")
        extra_env[f"{prefix}MINER"]        = resolved.get("miner", "")
        extra_env[f"{prefix}REASON"]       = resolved.get("reason", "")
        log(f"[Logs] Resolved {slot} miner API: {resolved}")
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
                **extra_env,
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
async def main():
    await asyncio.gather(
        mqtt_loop(),
        stats_db_periodic_loop(),
    )
if __name__ == "__main__":
    asyncio.run(main())
EOF
