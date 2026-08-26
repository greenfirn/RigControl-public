import json
import socket
import sqlite3
import subprocess
import time
import os
import psutil
import platform
import threading
from datetime import datetime, timezone
import paho.mqtt.client as mqtt
import sys
sys.path.insert(0, os.path.dirname(__file__))
try:
    import rigcontrol_telemetry as telemetry
    TELEMETRY_AVAILABLE = True
except ImportError as e:
    print(f"Warning: Telemetry module not available: {e}")
    TELEMETRY_AVAILABLE = False
# GLOBAL SETTINGS
BROKER_HOST = "127.0.0.1"
BROKER_PORT = 1883
BROKER_USER = None
BROKER_PASS = None
CMD_SCRIPT = os.path.join(os.path.dirname(__file__), "rigcontrol_cmd.bat")
CONFIG_PATH = None
STATS_DB_ENABLED = True
STATS_DB_MAX_HISTORY_DAYS = 7
STATS_DB_INTERVAL_SECONDS = 90
MIN_TELEMETRY_PULL_INTERVAL_SECONDS = 5
# LOGGING
def log(msg):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[RigControl] {timestamp} {msg}", flush=True)
def _fmt_hashrate_hs(hs):
    """H/s -> a short auto-scaled string (kH/s, MH/s, GH/s, TH/s) for the log line - mirrors the
    dashboard's fmtRateHs() scaling, just without the DOM/formatting concerns that function has."""
    try:
        hs = float(hs or 0)
    except (TypeError, ValueError):
        return "0 H/s"
    if hs <= 0:
        return "0 H/s"
    for unit, div in (("TH/s", 1e12), ("GH/s", 1e9), ("MH/s", 1e6), ("kH/s", 1e3)):
        if hs >= div:
            return f"{hs / div:.2f} {unit}"
    return f"{hs:.0f} H/s"
def log_miner_summary(payload):
    """Logs one line per detected+active miner - name, hashrate, and accepted/rejected shares -
    right after a telemetry push, so "is the miner actually being detected/read correctly" is
    answerable from the Windows console/service log alone, without needing to inspect the MQTT
    payload or open the dashboard. Pulled straight from the same miner_<name> entries (built by
    _build_miner_result() in rigcontrol_telemetry.py) the dashboard itself reads, so this can
    never show something different than what actually got sent."""
    detected = payload.get("detected_miners") or []
    if not detected:
        log("[Telemetry] No miner process detected")
        return
    for name in detected:
        miner = payload.get(f"miner_{name}")
        if not isinstance(miner, dict):
            continue
        if miner.get("status") != "ok":
            log(f"[Telemetry] {name}: {miner.get('status', 'unknown')} - {miner.get('error', '')}".rstrip(" -"))
            continue
        display_name = miner.get("miner") or name
        hashrate_str = _fmt_hashrate_hs(miner.get("total_hashrate_hs"))
        accepted = miner.get("total_accepted_shares") or 0
        rejected = miner.get("total_rejected_shares") or 0
        log(f"[Telemetry] {display_name} detected - hashrate {hashrate_str}, shares {accepted} accepted / {rejected} rejected")
# CONFIG - load
def load_broker_config():
    """Load configuration from rigcontrol_agent.conf"""
    global CONFIG_PATH
    config_path = os.path.join(os.path.dirname(__file__), "rigcontrol_agent.conf")
    if not os.path.isfile(config_path):
        config_path = "C:\\rigcontrol\\rigcontrol_agent.conf"
    CONFIG_PATH = config_path
    cfg = {}
    if not os.path.isfile(config_path):
        log(f"Config file not found: {config_path}")
        return cfg
    try:
        with open(config_path, "r") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    k, v = line.split("=", 1)
                    cfg[k.strip().upper()] = v.strip()
    except Exception as e:
        log(f"Config load error: {e}")
    return cfg
# CONFIG - LOCAL MQTT OR AWS
cfg = load_broker_config()
# Export every KEY=VALUE parsed from rigcontrol_agent.conf into this process's environment,
# mirroring what happens on Linux when rigcontrol_agent.sh does `source`/`export` on
# rigcontrol-agent.conf before launching the telemetry heredoc. Without this, rigcontrol_telemetry.py's
# os.environ.get("KERYX_MINER_API_HOST", ...) calls (and KERYX_MINER_SUPR_API_HOST/PORT,
# KERYX_BIN_PATH, CUSTOM_MINER_PROCESS_NAME, etc.) would never see values placed in the conf file -
# only variables set some other way directly in the Windows environment. This makes conf-file entries
# the source of truth (same as Linux), overriding any same-named var that happened to already be set
# in the OS environment. Safe to do unconditionally: telemetry.py only reads env vars lazily at
# collect-time (inside collect_keryx_stats() etc.), not at import time, so it doesn't matter that
# `import rigcontrol_telemetry as telemetry` above happens before this line runs.
for _k, _v in cfg.items():
    os.environ[_k] = _v
USE_AWS = "AWS_MQTT_HOST" in cfg
if USE_AWS:
    BROKER_HOST = cfg["AWS_MQTT_HOST"]
    BROKER_PORT = int(cfg.get("AWS_MQTT_PORT", 8883))
    AWS_CERT = cfg.get("AWS_MQTT_CERT", "")
    AWS_KEY = cfg.get("AWS_MQTT_KEY", "")
    AWS_CA = cfg.get("AWS_MQTT_CA", "")
    log("[Config] MQTT Mode = AWS IoT Core")
    log(f"[Config] Endpoint = {BROKER_HOST}:{BROKER_PORT}")
else:
    BROKER_HOST = cfg.get("BROKER_HOST", BROKER_HOST)
    BROKER_PORT = int(cfg.get("BROKER_PORT", BROKER_PORT))
    BROKER_USER = cfg.get("BROKER_USER")
    BROKER_PASS = cfg.get("BROKER_PASS")
    log("[Config] MQTT Mode = LOCAL")
    log(f"[Config] Broker = {BROKER_HOST}:{BROKER_PORT}")
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
STATS_DB_PATH = os.path.join(os.path.dirname(CONFIG_PATH), "rigcontrol_stats.db")
log(f"[Config] Local stats DB enabled = {STATS_DB_ENABLED}")
log(f"[Config] Local stats DB max history days = {STATS_DB_MAX_HISTORY_DAYS}")
log(f"[Config] Local stats DB periodic save interval = {STATS_DB_INTERVAL_SECONDS}s")
log(f"[Config] Local stats DB path = {STATS_DB_PATH}")
log(f"[Config] Minimum telemetry pull interval = {MIN_TELEMETRY_PULL_INTERVAL_SECONDS}s")
# TOPICS
TOPIC_PREFIX = "rigcontrol"
RIG_NAME = socket.gethostname().lower()
STATUS_TOPIC = f"{TOPIC_PREFIX}/{RIG_NAME}/status"
CMD_TOPIC_DIRECT = f"{TOPIC_PREFIX}/{RIG_NAME}/cmd"
CMD_TOPIC_ALL = f"{TOPIC_PREFIX}/all/cmd"
CHECK_TOPIC_DIRECT = f"{TOPIC_PREFIX}/{RIG_NAME}/check"
CHECK_TOPIC_ALL = f"{TOPIC_PREFIX}/all/check"
RESP_TOPIC = f"{TOPIC_PREFIX}/{RIG_NAME}/cmd_response"
STATS_CONTROL_TOPIC_DIRECT = f"{TOPIC_PREFIX}/{RIG_NAME}/stats_control"
STATS_CONTROL_TOPIC_ALL = f"{TOPIC_PREFIX}/all/stats_control"
STATS_REQUEST_TOPIC_DIRECT = f"{TOPIC_PREFIX}/{RIG_NAME}/stats_request"
STATS_REQUEST_TOPIC_ALL = f"{TOPIC_PREFIX}/all/stats_request"
STATS_RESPONSE_TOPIC = f"{TOPIC_PREFIX}/{RIG_NAME}/stats_response"
mqtt_client = None
_stats_db_last_cleanup = 0.0
_stats_db_last_save = 0.0
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
    """Writes one telemetry snapshot to the local SQLite history and prunes rows past the retention window at most once per day, using its own short-lived connection on a worker thread."""
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
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is not None:
        dt = dt.astimezone(timezone.utc).replace(tzinfo=None)
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
    """Live-updates stats DB settings and persists the new values back into rigcontrol_agent.conf in a single write."""
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
    try:
        if os.path.isfile(CONFIG_PATH):
            with open(CONFIG_PATH, "r") as f:
                lines = f.readlines()
            for key, value in changed_keys.items():
                lines = _conf_set_line(lines, key, value)
            with open(CONFIG_PATH, "w") as f:
                f.writelines(lines)
    except Exception as e:
        log(f"[StatsDB] Error persisting stats config to conf: {e}")
# SYSTEM STATS COLLECTION (Fallback if telemetry not available)
def collect_basic_stats():
    """Collect basic system stats as fallback"""
    stats = {
        "rig": RIG_NAME,
        "timestamp": int(time.time()),
        "platform": platform.system(),
        "platform_version": platform.version(),
        "cpu_usage": psutil.cpu_percent(),
        "memory": {
            "total_mb": psutil.virtual_memory().total // (1024 * 1024),
            "used_mb": psutil.virtual_memory().used // (1024 * 1024),
            "percent": psutil.virtual_memory().percent
        }
    }
    try:
        import pythoncom
        pythoncom.CoInitialize()
        try:
            import wmi
            w = wmi.WMI()
            gpus = []
            for gpu in w.Win32_VideoController():
                gpus.append({
                    "name": gpu.Name,
                    "driver": gpu.DriverVersion if hasattr(gpu, 'DriverVersion') else "Unknown",
                    "memory_mb": gpu.AdapterRAM // (1024 * 1024) if gpu.AdapterRAM else 0
                })
            if gpus:
                stats["gpus"] = gpus
        finally:
            pythoncom.CoUninitialize()
    except ImportError:
        pass
    except Exception as e:
        log(f"WMI GPU collection failed: {e}")
    return stats
def collect_full_stats():
    """Collect stats using unified telemetry or fallback"""
    if TELEMETRY_AVAILABLE:
        try:
            return telemetry.collect_full_stats()
        except Exception as e:
            log(f"Telemetry error: {e}, using fallback")
    stats = collect_basic_stats()
    stats["telemetry_status"] = "fallback"
    return stats
# MQTT PUBLISH FUNCTIONS
_last_telemetry_pull_ts = 0.0
_telemetry_pull_lock = threading.Lock()
def publish_status(reason="request"):
    """Publish status to MQTT"""
    global _last_telemetry_pull_ts
    if not _telemetry_pull_lock.acquire(blocking=False):
        log(f"[Telemetry] Pull already in progress - skipping ({reason})")
        return
    try:
        now = time.time()
        elapsed = now - _last_telemetry_pull_ts
        if elapsed < MIN_TELEMETRY_PULL_INTERVAL_SECONDS:
            log(f"[Telemetry] Skipped ({reason}) - {elapsed:.1f}s since last pull, minimum is {MIN_TELEMETRY_PULL_INTERVAL_SECONDS}s")
            return
        _last_telemetry_pull_ts = now
        try:
            payload = collect_full_stats()
            payload["event"] = reason
            payload["agent_version"] = "2.0-windows-sync"
            payload["stats_db_enabled"] = STATS_DB_ENABLED
            payload["stats_db_max_history_days"] = STATS_DB_MAX_HISTORY_DAYS
            payload["stats_db_interval_seconds"] = STATS_DB_INTERVAL_SECONDS
            if STATS_DB_ENABLED:
                threading.Thread(target=save_stats_locally, args=(payload,)).start()
            result = mqtt_client.publish(STATUS_TOPIC, json.dumps(payload))
            if result.rc == mqtt.MQTT_ERR_SUCCESS:
                log(f"Telemetry sent ({reason})")
                log_miner_summary(payload)
            else:
                log(f"Failed to publish status: MQTT error {result.rc}")
        except Exception as e:
            log(f"Error publishing status: {e}")
    finally:
        _telemetry_pull_lock.release()
def publish_check():
    """Publish check response"""
    payload = {
        "rig": RIG_NAME,
        "type": "check",
        "timestamp": int(time.time()),
        "state": "online",
        "agent_version": "2.0-windows-sync"
    }
    try:
        result = mqtt_client.publish(STATUS_TOPIC, json.dumps(payload))
        if result.rc == mqtt.MQTT_ERR_SUCCESS:
            log("Check response sent")
        else:
            log(f"Failed to publish check: MQTT error {result.rc}")
    except Exception as e:
        log(f"Error publishing check: {e}")
# COMMAND HANDLER (Same as Ubuntu version - pass command via STDIN)
def handle_command(raw):
    """Handle incoming MQTT commands (same format as Ubuntu version)"""
    log(f"Command received RAW: {raw}")
    try:
        data = json.loads(raw)
    except Exception:
        log("Invalid JSON received")
        return
    cmd_id = data.get("id", "unknown")
    command = data.get("command", "")
    if not command:
        log("Command missing 'command' field")
        return
    if command.strip().lower() == "refresh":
        threading.Thread(target=publish_status, args=("refresh-request",)).start()
        return
    if os.path.exists(CMD_SCRIPT):
        try:
            proc = subprocess.run(
                [CMD_SCRIPT],
                input=command,
                capture_output=True,
                text=True,
                shell=True
            )
            response = {
                "id": cmd_id,
                "rig": RIG_NAME,
                "timestamp": int(time.time()),
                "returncode": proc.returncode,
                "stdout": proc.stdout.strip(),
                "stderr": proc.stderr.strip(),
            }
            mqtt_client.publish(RESP_TOPIC, json.dumps(response))
            log(f"Command executed ({cmd_id})")
            threading.Thread(target=publish_status, args=("cmd-run",)).start()
        except Exception as e:
            log(f"Command execution error: {e}")
            response = {
                "id": cmd_id,
                "rig": RIG_NAME,
                "timestamp": int(time.time()),
                "returncode": -1,
                "stdout": "",
                "stderr": str(e)
            }
            mqtt_client.publish(RESP_TOPIC, json.dumps(response))
    else:
        log(f"Command script not found: {CMD_SCRIPT}")
        response = {
            "id": cmd_id,
            "rig": RIG_NAME,
            "timestamp": int(time.time()),
            "returncode": -1,
            "stdout": "",
            "stderr": f"Command script not found: {CMD_SCRIPT}"
        }
        mqtt_client.publish(RESP_TOPIC, json.dumps(response))
# STATS CONTROL HANDLER
def handle_stats_control(raw):
    """Handles incoming MQTT stats_control messages: enables/disables and/or live-tweaks local stats DB settings, persisting to conf."""
    log(f"Stats control message received: {raw}")
    try:
        data = json.loads(raw)
    except Exception:
        log("Invalid JSON received on stats_control topic")
        return
    if not any(k in data for k in ("enabled", "max_history_days", "interval_seconds")):
        log("stats_control message missing 'enabled', 'max_history_days', and 'interval_seconds' - ignoring")
        return
    set_stats_config(
        data.get("enabled"),
        data.get("max_history_days"),
        data.get("interval_seconds"),
    )
    publish_status("stats-control")
# STATS HISTORY REQUEST HANDLER
def mqtt_publish_resilient(topic, payload_str, context):
    """Synchronous MQTT publish with one retry on failure; success only reflects local queuing, not broker acknowledgment."""
    try:
        result = mqtt_client.publish(topic, payload_str)
        if result.rc == mqtt.MQTT_ERR_SUCCESS:
            return True
        log(f"[MQTT] Publish failed for {context} (topic={topic}): rc={result.rc} - retrying in 4s")
    except Exception as e:
        log(f"[MQTT] Publish raised for {context} (topic={topic}): {e} - retrying in 4s")
    time.sleep(4)
    try:
        result = mqtt_client.publish(topic, payload_str)
        if result.rc == mqtt.MQTT_ERR_SUCCESS:
            log(f"[MQTT] Retry succeeded for {context}")
            return True
        log(f"[MQTT] Retry failed for {context}: rc={result.rc} - giving up, response lost")
        return False
    except Exception as e2:
        log(f"[MQTT] Retry raised for {context}: {e2} - giving up, response lost")
        return False
def handle_stats_request(raw):
    """Handles incoming MQTT stats_request messages by reading back locally stored telemetry history and replying on the stats_response topic."""
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
        mqtt_publish_resilient(STATS_RESPONSE_TOPIC, json.dumps({
            "id": req_id,
            "rig": RIG_NAME,
            "error": "missing or invalid 'days' (must be a positive integer)",
        }), f"stats error response ({req_id})")
        return
    limit = data.get("limit")
    try:
        limit = int(limit) if limit is not None else None
        if limit is not None and limit < 1:
            limit = None
    except (TypeError, ValueError):
        limit = None
    start_date = data.get("start_date")
    entries = query_stats_history(days, limit, start_date)
    CHUNK_MAX_BYTES = 150_000
    CHUNK_ENVELOPE_BYTES = 512
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
    total_bytes = 0
    log(f"[StatsDB] Sending stats response for {req_id} as {chunk_count} chunk(s): {total_entries} entries")
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
        resp_str = json.dumps(resp)
        total_bytes += len(resp_str.encode("utf-8"))
        mqtt_publish_resilient(STATS_RESPONSE_TOPIC, resp_str, f"stats response ({req_id}) chunk {idx + 1}/{chunk_count}")
        if idx < chunk_count - 1:
            time.sleep(0.02)
    if start_date:
        log(f"Stats history sent: {total_entries} entries covering {days} day(s) from {start_date} ({req_id}) in {chunk_count} chunk(s), {total_bytes} bytes total")
    else:
        log(f"Stats history sent: {total_entries} entries covering last {days} day(s) ({req_id}) in {chunk_count} chunk(s), {total_bytes} bytes total")
# STATS DB PERIODIC SAVE LOOP
def stats_db_periodic_loop():
    """Background thread loop that tops up the local stats DB on its own cadence (STATS_DB_INTERVAL_SECONDS) independent of refresh/cmd-triggered publishes, skipping a cycle if a more recent row already exists."""
    CHECK_EVERY = 5
    while True:
        time.sleep(CHECK_EVERY)
        if not STATS_DB_ENABLED:
            continue
        elapsed = time.time() - _stats_db_last_save
        if elapsed < STATS_DB_INTERVAL_SECONDS:
            continue
        try:
            payload = collect_full_stats()
            payload["event"] = "stats-db-periodic"
            payload["stats_db_enabled"] = STATS_DB_ENABLED
            payload["stats_db_max_history_days"] = STATS_DB_MAX_HISTORY_DAYS
            payload["stats_db_interval_seconds"] = STATS_DB_INTERVAL_SECONDS
            save_stats_locally(payload)
            log(f"[StatsDB] Periodic save ({STATS_DB_INTERVAL_SECONDS}s interval)")
        except Exception as e:
            log(f"[StatsDB] Periodic collection error: {e}")
# MQTT CALLBACKS
def on_connect(client, userdata, flags, rc):
    """MQTT connection callback"""
    if rc == 0:
        log("MQTT connected successfully")
        client.subscribe(CMD_TOPIC_ALL)
        client.subscribe(CMD_TOPIC_DIRECT)
        client.subscribe(CHECK_TOPIC_ALL)
        client.subscribe(CHECK_TOPIC_DIRECT)
        client.subscribe(STATS_CONTROL_TOPIC_ALL)
        client.subscribe(STATS_CONTROL_TOPIC_DIRECT)
        client.subscribe(STATS_REQUEST_TOPIC_ALL)
        client.subscribe(STATS_REQUEST_TOPIC_DIRECT)
        log(f"Subscribed to: {CMD_TOPIC_ALL}")
        log(f"Subscribed to: {CMD_TOPIC_DIRECT}")
        log(f"Subscribed to: {CHECK_TOPIC_ALL}")
        log(f"Subscribed to: {CHECK_TOPIC_DIRECT}")
        log(f"Subscribed to: {STATS_CONTROL_TOPIC_ALL}")
        log(f"Subscribed to: {STATS_CONTROL_TOPIC_DIRECT}")
        log(f"Subscribed to: {STATS_REQUEST_TOPIC_ALL}")
        log(f"Subscribed to: {STATS_REQUEST_TOPIC_DIRECT}")
    else:
        log(f"Connection failed with code {rc}")
        if rc == 5:
            log("Authentication failed - check username/password")
def on_message(client, userdata, msg):
    """MQTT message callback"""
    topic = msg.topic
    payload = msg.payload.decode(errors="ignore")
    log(f"Message received on {topic}")
    if topic.endswith("/check"):
        threading.Thread(target=publish_check).start()
        return
    if topic.endswith("/stats_control"):
        threading.Thread(target=handle_stats_control, args=(payload,)).start()
        return
    if topic.endswith("/stats_request"):
        threading.Thread(target=handle_stats_request, args=(payload,)).start()
        return
    if topic.endswith("/cmd"):
        threading.Thread(target=handle_command, args=(payload,)).start()
        return
    log(f"Ignoring message on unexpected topic: {topic}")
def on_disconnect(client, userdata, rc):
    """MQTT disconnect callback"""
    if rc != 0:
        log(f"Unexpected MQTT disconnection (code: {rc}), reconnecting...")
    else:
        log("MQTT disconnected gracefully")
# MAIN
def main():
    """Main synchronous entry point"""
    global mqtt_client
    log(f"RigControl Sync Agent starting on {RIG_NAME}")
    log(f"Python {sys.version}")
    log(f"Platform: {platform.platform()}")
    try:
        import paho.mqtt.client as mqtt
        log("paho-mqtt library available")
    except ImportError:
        log("ERROR: paho-mqtt not installed. Run: pip install paho-mqtt")
        return
    if not TELEMETRY_AVAILABLE:
        log("WARNING: Telemetry module not available, using basic stats")
    client_id = f"rigcontrol_{RIG_NAME}_{int(time.time())}"
    mqtt_client = mqtt.Client(client_id=client_id, clean_session=True)
    mqtt_client.on_connect = on_connect
    mqtt_client.on_message = on_message
    mqtt_client.on_disconnect = on_disconnect
    if BROKER_USER:
        mqtt_client.username_pw_set(BROKER_USER, BROKER_PASS)
    if USE_AWS and AWS_CERT and AWS_KEY and AWS_CA:
        try:
            import ssl
            mqtt_client.tls_set(
                ca_certs=AWS_CA,
                certfile=AWS_CERT,
                keyfile=AWS_KEY,
                tls_version=ssl.PROTOCOL_TLSv1_2
            )
            log("TLS configured for AWS IoT")
        except Exception as e:
            log(f"TLS configuration failed: {e}")
    threading.Thread(target=stats_db_periodic_loop, daemon=True).start()
    while True:
        try:
            log(f"Connecting to MQTT broker at {BROKER_HOST}:{BROKER_PORT}")
            mqtt_client.connect(BROKER_HOST, BROKER_PORT, 60)
            mqtt_client.loop_forever()
        except KeyboardInterrupt:
            log("Shutdown requested by user")
            mqtt_client.disconnect()
            break
        except ConnectionRefusedError:
            log("Connection refused - broker may be down")
            time.sleep(5)
        except Exception as e:
            log(f"MQTT connection error: {e}")
            log("Reconnecting in 5 seconds...")
            time.sleep(5)
if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nAgent stopped by user")
    except Exception as e:
        log(f"Fatal error: {e}")
        sys.exit(1)
