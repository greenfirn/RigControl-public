import os
import asyncio
import ipaddress
import json
import re
import secrets
import string
import threading
import time
import queue
import boto3
import csv
import sqlite3
from datetime import datetime
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from typing import Dict, List, Optional, Any, Tuple
from twilio.rest import Client
from twilio.base.exceptions import TwilioRestException
from pathlib import Path
import aiomqtt
import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, APIRouter, HTTPException, Request, Response, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from contextlib import asynccontextmanager
from pydantic import BaseModel, ConfigDict
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError
dynamodb = None
flightsheets_table = None
router = APIRouter()
class FlightSheetEntryIn(BaseModel):
    key: str
    gpu: int
    value: str
class FlightSheetPutIn(BaseModel):
    entries: List[FlightSheetEntryIn]
class OverclockEntryIn(BaseModel):
    key: str
    gpu: int
    value: str
class OverclockPutIn(BaseModel):
    entries: List[OverclockEntryIn]
class SavedCommandEntryIn(BaseModel):
    key: str
    gpu: int
    value: str
class SavedCommandPutIn(BaseModel):
    entries: List[SavedCommandEntryIn]
class WalletEntryIn(BaseModel):
    key: str
    gpu: int
    value: str
class WalletPutIn(BaseModel):
    entries: List[WalletEntryIn]
class WatchdogProfileEntryIn(BaseModel):
    key: str
    gpu: int
    value: str
class WatchdogProfilePutIn(BaseModel):
    entries: List[WatchdogProfileEntryIn]
class NotificationSettings(BaseModel):
    email_enabled: bool = True
    sms_primary_enabled: bool = False
    sms_secondary_enabled: bool = False
    sms_primary_number: Optional[str] = None
    sms_secondary_number: Optional[str] = None
    docker_email_enabled: bool = False
    docker_sms_primary_enabled: bool = False
    docker_sms_secondary_enabled: bool = False
    model_config = ConfigDict(from_attributes=True)
class QuickActionsIn(BaseModel):
    a: Optional[str] = ""
    b: Optional[str] = ""
    c: Optional[str] = ""
class TelemetryColumnsIn(BaseModel):
    visible_groups: Optional[List[str]] = None
USE_AWS_DB = os.getenv("USE_AWS_DB", "false").lower() == "true"
MQTT_MODE = os.getenv("MQTT_MODE", "local")
if MQTT_MODE == "local":
    MQTT_BROKER = os.getenv("MQTT_HOST", "127.0.0.1")
    MQTT_PORT   = int(os.getenv("MQTT_PORT", "1883"))
    MQTT_USER   = os.getenv("MQTT_USER", "admin")
    MQTT_PASS   = os.getenv("MQTT_PASS", "******")
    MQTT_CERT = None
    MQTT_KEY  = None
    MQTT_CA   = None
    BASE_PATH = os.getenv("BASE_PATH", "")
elif MQTT_MODE == "pi":
    MQTT_BROKER = os.getenv("MQTT_HOST", "127.0.0.1")
    MQTT_PORT   = int(os.getenv("MQTT_PORT", "1883"))
    MQTT_USER   = os.getenv("MQTT_USER", "admin")
    MQTT_PASS   = os.getenv("MQTT_PASS", "******")
    MQTT_CERT = None
    MQTT_KEY  = None
    MQTT_CA   = None
    BASE_PATH = os.getenv("BASE_PATH", "")
elif MQTT_MODE == "aws":
    MQTT_BROKER = os.getenv("AWS_MQTT_HOST", "")
    MQTT_PORT   = int(os.getenv("AWS_MQTT_PORT", "8883"))
    MQTT_USER = None
    MQTT_PASS = None
    MQTT_CERT = os.getenv("AWS_MQTT_CERT", "/certs/device.pem.crt")
    MQTT_KEY  = os.getenv("AWS_MQTT_KEY",  "/certs/private.pem.key")
    MQTT_CA   = os.getenv("AWS_MQTT_CA",   "/certs/AmazonRootCA1.pem")
    BASE_PATH = os.getenv("BASE_PATH", "")
else:
    raise RuntimeError(f"Invalid MQTT_MODE: {MQTT_MODE}")
BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"
API_BIND = os.getenv("API_BIND", "0.0.0.0")
API_PORT = int(os.getenv("API_PORT", "8765"))
MQTT_TOPIC_FILTER = os.getenv("MQTT_TOPIC_FILTER", "rigcontrol/+/+")
BROADCAST_INTERVAL = float(os.getenv("BROADCAST_INTERVAL", "10"))
OFFLINE_PING_INTERVAL = float(os.getenv("OFFLINE_PING_INTERVAL", "30"))
OFFLINE_THRESHOLD = float(os.getenv("OFFLINE_THRESHOLD", "90"))
TRUST_PROXY_HEADERS = os.getenv("TRUST_PROXY_HEADERS", "false").lower() == "true"
TRUSTED_PROXY_HOPS = max(1, int(os.getenv("TRUSTED_PROXY_HOPS", "1")))
TRUST_CLOUDFLARE = os.getenv("TRUST_CLOUDFLARE", "false").lower() == "true"
_PRIVATE_NETWORKS = [
    ipaddress.ip_network(net) for net in (
        "127.0.0.0/8",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "169.254.0.0/16",
        "::1/128",
        "fc00::/7",
        "fe80::/10",
    )
]
UNLOCK_CODE_TTL = int(os.getenv("UNLOCK_CODE_TTL_SECONDS", "600"))                                                   
UNLOCK_CODE_COOLDOWN = int(os.getenv("UNLOCK_CODE_COOLDOWN_SECONDS", "60"))                                        
UNLOCK_TOKEN_TTL = int(os.getenv("UNLOCK_TOKEN_TTL_SECONDS", str(12 * 3600)))                                        
UNLOCK_COOKIE_NAME = os.getenv("UNLOCK_COOKIE_NAME", "rigcontrol_unlock")
UNLOCK_MAX_ATTEMPTS_PER_IP = int(os.getenv("UNLOCK_MAX_ATTEMPTS_PER_IP", "3"))
UNLOCK_ATTEMPTS_WINDOW_SECONDS = int(os.getenv("UNLOCK_ATTEMPTS_WINDOW_SECONDS", str(24 * 3600)))
_unlock_code: Optional[str] = None
_unlock_code_expires: float = 0.0
_unlock_code_last_sent: float = 0.0
_unlock_lock = threading.Lock()
_unlock_tokens: Dict[str, float] = {}
_unlock_attempts_by_ip: Dict[str, List[float]] = {}
PERIODIC_SWEEP_INTERVAL_SECONDS = 300
DB_CONNECTION_IDLE_TIMEOUT_SECONDS = 300
_last_periodic_sweep_ts = 0.0
VIEW_ONLY_MUTATING_METHODS = {"POST", "PUT", "DELETE", "PATCH"}
VIEW_ONLY_EXEMPT_PATHS = {
    "/api/stats/request",
    "/api/view-only/request-code",
    "/api/view-only/verify-code",
}
MAX_WS_CONNECTIONS = 5
ws_connection_count = 0
CMD_ALL_TOPIC = "rigcontrol/all/cmd"
CHECK_ALL_TOPIC = "rigcontrol/all/check"
_mqtt_client_ref: "aiomqtt.Client | None" = None
mqtt_stop: asyncio.Event | None = None
mqtt_task: asyncio.Task | None = None
broadcast_task: asyncio.Task | None = None
broadcast_stop: asyncio.Event | None = None
broadcast_loop_running = False
broadcast_loop_lock = asyncio.Lock()
last_refresh_ts = 0.0
OFFLINE_GRACE_PERIOD = 60
last_ws_push = 0.0
WS_PUSH_MIN_INTERVAL = 1.2
ws_broadcast_pending = False
rigs: Dict[str, Dict[str, Any]] = {}
rigs_lock = threading.Lock()
connected_clients: List[WebSocket] = []
clients_lock = asyncio.Lock()
stats_response_chunk_buffers: Dict[str, Dict[str, Any]] = {}
stats_response_chunk_lock = asyncio.Lock()
STATS_CHUNK_STALE_SECONDS = 60
rig_last_update: Dict[str, float] = {}
rig_online_status: Dict[str, bool] = {}
rig_online_status_lock = threading.Lock()
offline_ping_mode_active = False
known_rigs: set[str] = set()
known_rigs_lock = threading.Lock()
last_offline_ping_ts = 0.0
offline_ping_stop = None
offline_ping_task = None
offline_ping_running = False
maintenance_sweep_stop = None
maintenance_sweep_task = None
offline_ping_lock = asyncio.Lock()
NOTIFICATION_SETTINGS_FILE = BASE_DIR / "notification_settings.json"
notification_settings = {
    "email_enabled": True,
    "sms_primary_enabled": False,
    "sms_secondary_enabled": False,
    "sms_primary_number": None,
    "sms_secondary_number": None,
    "docker_email_enabled": False,
    "docker_sms_primary_enabled": False,
    "docker_sms_secondary_enabled": False,
}
quick_actions = {
    "a": "",
    "b": "",
    "c": ""
}
telemetry_visible_groups: Optional[list] = None
rig_offline_notifications: Dict[str, float] = {}
rig_offline_notifications_lock = threading.Lock()
rig_docker_state: Dict[str, bool] = {}
rig_docker_state_lock = threading.Lock()
rig_missed_refreshes: Dict[str, int] = {}
rig_missed_refreshes_lock = threading.Lock()
MISSED_REFRESH_THRESHOLD = 2
def log(msg: str) -> None:
    now = time.time()
    ts = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(now))
    ms = int((now % 1) * 1000)
    print(f"[{ts}.{ms:03d} UTC] [RigControl] {msg}", flush=True)
# SHARED THREAD-LOCAL SQLITE CONNECTION REGISTRY
class _ThreadLocalSQLiteConnections:
    def __init__(self, db_path, ensure_schema_fn, label=None):
        self.db_path = db_path
        self._ensure_schema_fn = ensure_schema_fn
        self._label = label or Path(db_path).name
        self._lock = threading.Lock()
        self._connections = {}
    def get(self):
        thread_id = threading.get_ident()
        entry = self._connections.get(thread_id)
        if entry is not None:
            entry[1] = time.time()
            return entry[0]
        with self._lock:
            entry = self._connections.get(thread_id)
            if entry is not None:
                entry[1] = time.time()
                return entry[0]
            self.db_path.parent.mkdir(parents=True, exist_ok=True)
            conn = sqlite3.connect(self.db_path)
            conn.row_factory = sqlite3.Row
            self._ensure_schema_fn(conn)
            self._connections[thread_id] = [conn, time.time()]
            active = len(self._connections)
            log(f"[{self._label}] Opened connection for thread {thread_id} (active={active})")
            return conn
    def sweep_idle(self, idle_timeout_seconds=300):
        now = time.time()
        closed_ids = []
        with self._lock:
            stale_ids = [tid for tid, (conn, last_used) in self._connections.items()
                         if now - last_used > idle_timeout_seconds]
            for tid in stale_ids:
                conn, _ = self._connections.pop(tid)
                try:
                    conn.close()
                except Exception:
                    pass
                closed_ids.append(tid)
            active = len(self._connections)
        if closed_ids:
            log(f"[{self._label}] Cleanup: closed {len(closed_ids)} idle connection(s) "
                f"for thread(s) {closed_ids} (active={active})")
        return len(closed_ids)
    def close_all(self):
        with self._lock:
            thread_ids = list(self._connections.keys())
            for tid, (conn, _) in self._connections.items():
                try:
                    conn.close()
                except Exception:
                    pass
            self._connections.clear()
        if thread_ids:
            log(f"[{self._label}] Shutdown cleanup: closed {len(thread_ids)} connection(s) "
                f"for thread(s) {thread_ids}")
class LocalFlightsheetDB:
    def __init__(self, db_path: str = None):
        if db_path is None:
            db_path = BASE_DIR / "rigcontrol_flightsheets.db"
        self.db_path = Path(db_path)
        self._conns = _ThreadLocalSQLiteConnections(self.db_path, self._ensure_table_for_thread, label="FlightsheetDB")
    def _get_connection(self):
        return self._conns.get()
    def _ensure_table_for_thread(self, conn):
        try:
            cursor = conn.cursor()
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS flightsheets (
                    FlightsheetId TEXT NOT NULL,
                    GpuId INTEGER NOT NULL,
                    Key TEXT NOT NULL,
                    Value TEXT,
                    UpdatedAt INTEGER,
                    SavedAt TEXT DEFAULT CURRENT_TIMESTAMP,
                    UNIQUE(FlightsheetId, GpuId, Key)
                )
            ''')
            cursor.execute("SELECT name FROM sqlite_master WHERE type='index' AND name='idx_fs_id'")
            if not cursor.fetchone():
                cursor.execute('CREATE INDEX idx_fs_id ON flightsheets(FlightsheetId)')
            cursor.execute("SELECT name FROM sqlite_master WHERE type='index' AND name='idx_fs_gpu'")
            if not cursor.fetchone():
                cursor.execute('CREATE INDEX idx_fs_gpu ON flightsheets(GpuId)')
            conn.commit()
            return True
        except Exception as e:
            log(f"[LocalDB] Error ensuring table: {e}")
            return False
    def connect(self):
        try:
            conn = self._get_connection()
            return True
        except Exception as e:
            log(f"[LocalDB] Error connecting: {e}")
            return False
    def ensure_table(self):
        try:
            conn = self._get_connection()
            return True
        except Exception as e:
            log(f"[LocalDB] Error ensuring table: {e}")
            return False
    def scan(self):
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            cursor.execute('''
                SELECT FlightsheetId, GpuId, Key, Value, UpdatedAt
                FROM flightsheets
                ORDER BY FlightsheetId, GpuId, Key
            ''')
            items = []
            for row in cursor.fetchall():
                items.append({
                    "FlightsheetId": row[0],
                    "GpuId": row[1],
                    "Key": row[2],
                    "Value": row[3],
                    "UpdatedAt": row[4]
                })
            return {"Items": items}
        except Exception as e:
            log(f"[LocalDB] Scan error: {e}")
            return {"Items": []}
    def delete_flightsheet(self, flightsheet_id: str):
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            cursor.execute('DELETE FROM flightsheets WHERE FlightsheetId = ?', (flightsheet_id,))
            deleted = cursor.rowcount
            conn.commit()
            return deleted
        except Exception as e:
            log(f"[LocalDB] Delete error: {e}")
            return 0
    def put_flightsheet(self, flightsheet_id: str, entries: List[FlightSheetEntryIn], updated_at: int):
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            deleted = self.delete_flightsheet(flightsheet_id)
            inserted = 0
            for e in entries:
                try:
                    cursor.execute('''
                        INSERT INTO flightsheets
                        (FlightsheetId, GpuId, Key, Value, UpdatedAt)
                        VALUES (?, ?, ?, ?, ?)
                    ''', (
                        flightsheet_id,
                        int(e.gpu),
                        e.key.strip().upper(),
                        e.value,
                        updated_at
                    ))
                    inserted += 1
                except Exception as e:
                    log(f"[LocalDB] Insert error for {flightsheet_id}: {e}")
                    continue
            conn.commit()
            return deleted, inserted
        except Exception as e:
            log(f"[LocalDB] Put error: {e}")
            return 0, 0
    def close_all(self):
        self._conns.close_all()
local_flightsheet_db = LocalFlightsheetDB()
class LocalOverclockDB:
    def __init__(self, db_path: str = None):
        if db_path is None:
            db_path = BASE_DIR / "rigcontrol_overclocks.db"
        self.db_path = Path(db_path)
        self._conns = _ThreadLocalSQLiteConnections(self.db_path, self._ensure_table_for_thread, label="OverclockDB")
    def _get_connection(self):
        return self._conns.get()
    def _ensure_table_for_thread(self, conn):
        try:
            cursor = conn.cursor()
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS overclocks (
                    OverclockId TEXT NOT NULL,
                    GpuId INTEGER NOT NULL,
                    Key TEXT NOT NULL,
                    Value TEXT,
                    UpdatedAt INTEGER,
                    SavedAt TEXT DEFAULT CURRENT_TIMESTAMP,
                    UNIQUE(OverclockId, GpuId, Key)
                )
            ''')
            cursor.execute("SELECT name FROM sqlite_master WHERE type='index' AND name='idx_oc_id'")
            if not cursor.fetchone():
                cursor.execute('CREATE INDEX idx_oc_id ON overclocks(OverclockId)')
            cursor.execute("SELECT name FROM sqlite_master WHERE type='index' AND name='idx_oc_gpu'")
            if not cursor.fetchone():
                cursor.execute('CREATE INDEX idx_oc_gpu ON overclocks(GpuId)')
            conn.commit()
            return True
        except Exception as e:
            log(f"[OverclockDB] Error ensuring table: {e}")
            return False
    def connect(self):
        try:
            conn = self._get_connection()
            return True
        except Exception as e:
            log(f"[OverclockDB] Error connecting: {e}")
            return False
    def ensure_table(self):
        try:
            conn = self._get_connection()
            return True
        except Exception as e:
            log(f"[OverclockDB] Error ensuring table: {e}")
            return False
    def scan(self):
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            cursor.execute('''
                SELECT OverclockId, GpuId, Key, Value, UpdatedAt
                FROM overclocks
                ORDER BY OverclockId, GpuId, Key
            ''')
            items = []
            for row in cursor.fetchall():
                items.append({
                    "OverclockId": row[0],
                    "GpuId": row[1],
                    "Key": row[2],
                    "Value": row[3],
                    "UpdatedAt": row[4]
                })
            return {"Items": items}
        except Exception as e:
            log(f"[OverclockDB] Scan error: {e}")
            return {"Items": []}
    def delete_overclock(self, overclock_id: str):
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            cursor.execute('DELETE FROM overclocks WHERE OverclockId = ?', (overclock_id,))
            deleted = cursor.rowcount
            conn.commit()
            return deleted
        except Exception as e:
            log(f"[OverclockDB] Delete error: {e}")
            return 0
    def put_overclock(self, overclock_id: str, entries: List[OverclockEntryIn], updated_at: int):
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            deleted = self.delete_overclock(overclock_id)
            inserted = 0
            for e in entries:
                try:
                    cursor.execute('''
                        INSERT INTO overclocks
                        (OverclockId, GpuId, Key, Value, UpdatedAt)
                        VALUES (?, ?, ?, ?, ?)
                    ''', (
                        overclock_id,
                        int(e.gpu),
                        e.key.strip().upper(),
                        e.value,
                        updated_at
                    ))
                    inserted += 1
                except Exception as e:
                    log(f"[OverclockDB] Insert error for {overclock_id}: {e}")
                    continue
            conn.commit()
            return deleted, inserted
        except Exception as e:
            log(f"[OverclockDB] Put error: {e}")
            return 0, 0
    def close_all(self):
        self._conns.close_all()
local_overclock_db = LocalOverclockDB()
class LocalSavedCommandDB:
    def __init__(self, db_path: str = None):
        if db_path is None:
            db_path = BASE_DIR / "rigcontrol_saved_commands.db"
        self.db_path = Path(db_path)
        self._conns = _ThreadLocalSQLiteConnections(self.db_path, self._ensure_table_for_thread, label="SavedCommandDB")
    def _get_connection(self):
        return self._conns.get()
    def _ensure_table_for_thread(self, conn):
        try:
            cursor = conn.cursor()
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS saved_commands (
                    CommandId TEXT NOT NULL,
                    GpuId INTEGER NOT NULL,
                    Key TEXT NOT NULL,
                    Value TEXT,
                    UpdatedAt INTEGER,
                    SavedAt TEXT DEFAULT CURRENT_TIMESTAMP,
                    UNIQUE(CommandId, GpuId, Key)
                )
            ''')
            cursor.execute("SELECT name FROM sqlite_master WHERE type='index' AND name='idx_cmd_id'")
            if not cursor.fetchone():
                cursor.execute('CREATE INDEX idx_cmd_id ON saved_commands(CommandId)')
            cursor.execute("SELECT name FROM sqlite_master WHERE type='index' AND name='idx_cmd_gpu'")
            if not cursor.fetchone():
                cursor.execute('CREATE INDEX idx_cmd_gpu ON saved_commands(GpuId)')
            conn.commit()
            return True
        except Exception as e:
            log(f"[SavedCommandDB] Error ensuring table: {e}")
            return False
    def connect(self):
        try:
            conn = self._get_connection()
            return True
        except Exception as e:
            log(f"[SavedCommandDB] Error connecting: {e}")
            return False
    def ensure_table(self):
        try:
            conn = self._get_connection()
            return True
        except Exception as e:
            log(f"[SavedCommandDB] Error ensuring table: {e}")
            return False
    def scan(self):
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            cursor.execute('''
                SELECT CommandId, GpuId, Key, Value, UpdatedAt
                FROM saved_commands
                ORDER BY CommandId, GpuId, Key
            ''')
            items = []
            for row in cursor.fetchall():
                items.append({
                    "CommandId": row[0],
                    "GpuId": row[1],
                    "Key": row[2],
                    "Value": row[3],
                    "UpdatedAt": row[4]
                })
            return {"Items": items}
        except Exception as e:
            log(f"[SavedCommandDB] Scan error: {e}")
            return {"Items": []}
    def delete_command(self, command_id: str):
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            cursor.execute('DELETE FROM saved_commands WHERE CommandId = ?', (command_id,))
            deleted = cursor.rowcount
            conn.commit()
            return deleted
        except Exception as e:
            log(f"[SavedCommandDB] Delete error: {e}")
            return 0
    def put_command(self, command_id: str, entries: List[SavedCommandEntryIn], updated_at: int):
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            deleted = self.delete_command(command_id)
            inserted = 0
            for e in entries:
                try:
                    cursor.execute('''
                        INSERT INTO saved_commands
                        (CommandId, GpuId, Key, Value, UpdatedAt)
                        VALUES (?, ?, ?, ?, ?)
                    ''', (
                        command_id,
                        int(e.gpu),
                        e.key.strip().upper(),
                        e.value,
                        updated_at
                    ))
                    inserted += 1
                except Exception as e:
                    log(f"[SavedCommandDB] Insert error for {command_id}: {e}")
                    continue
            conn.commit()
            return deleted, inserted
        except Exception as e:
            log(f"[SavedCommandDB] Put error: {e}")
            return 0, 0
    def close_all(self):
        self._conns.close_all()
local_saved_command_db = LocalSavedCommandDB()
class LocalWatchdogProfileDB:
    def __init__(self, db_path: str = None):
        if db_path is None:
            db_path = BASE_DIR / "rigcontrol_watchdog_profiles.db"
        self.db_path = Path(db_path)
        self._conns = _ThreadLocalSQLiteConnections(self.db_path, self._ensure_table_for_thread, label="WatchdogProfileDB")
    def _get_connection(self):
        return self._conns.get()
    def _ensure_table_for_thread(self, conn):
        try:
            cursor = conn.cursor()
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS watchdog_profiles (
                    WatchdogProfileId TEXT NOT NULL,
                    GpuId INTEGER NOT NULL,
                    Key TEXT NOT NULL,
                    Value TEXT,
                    UpdatedAt INTEGER,
                    SavedAt TEXT DEFAULT CURRENT_TIMESTAMP,
                    UNIQUE(WatchdogProfileId, GpuId, Key)
                )
            ''')
            cursor.execute("SELECT name FROM sqlite_master WHERE type='index' AND name='idx_wd_id'")
            if not cursor.fetchone():
                cursor.execute('CREATE INDEX idx_wd_id ON watchdog_profiles(WatchdogProfileId)')
            conn.commit()
            return True
        except Exception as e:
            log(f"[WatchdogProfileDB] Error ensuring table: {e}")
            return False
    def connect(self):
        try:
            self._get_connection()
            return True
        except Exception as e:
            log(f"[WatchdogProfileDB] Error connecting: {e}")
            return False
    def scan(self):
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            cursor.execute('''
                SELECT WatchdogProfileId, GpuId, Key, Value, UpdatedAt
                FROM watchdog_profiles
                ORDER BY WatchdogProfileId, GpuId, Key
            ''')
            items = []
            for row in cursor.fetchall():
                items.append({
                    "WatchdogProfileId": row[0],
                    "GpuId": row[1],
                    "Key": row[2],
                    "Value": row[3],
                    "UpdatedAt": row[4]
                })
            return {"Items": items}
        except Exception as e:
            log(f"[WatchdogProfileDB] Scan error: {e}")
            return {"Items": []}
    def delete_profile(self, profile_id: str):
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            cursor.execute('DELETE FROM watchdog_profiles WHERE WatchdogProfileId = ?', (profile_id,))
            deleted = cursor.rowcount
            conn.commit()
            return deleted
        except Exception as e:
            log(f"[WatchdogProfileDB] Delete error: {e}")
            return 0
    def put_profile(self, profile_id: str, entries, updated_at: int):
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            deleted = self.delete_profile(profile_id)
            inserted = 0
            for e in entries:
                try:
                    cursor.execute('''
                        INSERT INTO watchdog_profiles
                        (WatchdogProfileId, GpuId, Key, Value, UpdatedAt)
                        VALUES (?, ?, ?, ?, ?)
                    ''', (
                        profile_id,
                        int(e.gpu),
                        e.key.strip().upper(),
                        e.value,
                        updated_at
                    ))
                    inserted += 1
                except Exception as ex:
                    log(f"[WatchdogProfileDB] Insert error for {profile_id}: {ex}")
                    continue
            conn.commit()
            return deleted, inserted
        except Exception as e:
            log(f"[WatchdogProfileDB] Put error: {e}")
            return 0, 0
    def close_all(self):
        self._conns.close_all()
local_watchdog_profile_db = LocalWatchdogProfileDB()
local_watchdog_profile_db.connect()
class LocalStatusLogDB:
    def __init__(self, db_path: str = None):
        if db_path is None:
            db_path = BASE_DIR / "rigcontrol_status_log.db"
        self.db_path = Path(db_path)
        self._conns = _ThreadLocalSQLiteConnections(self.db_path, self._ensure_table_for_thread, label="StatusLogDB")
    def _get_connection(self):
        return self._conns.get()
    def _ensure_table_for_thread(self, conn):
        try:
            cursor = conn.cursor()
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS status_log_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    rig TEXT,
                    algo TEXT,
                    title TEXT,
                    details TEXT,
                    reasons TEXT,
                    actions TEXT,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                )
            ''')
            cursor.execute("SELECT name FROM sqlite_master WHERE type='index' AND name='idx_statuslog_rig'")
            if not cursor.fetchone():
                cursor.execute('CREATE INDEX idx_statuslog_rig ON status_log_events(rig)')
            cursor.execute("SELECT name FROM sqlite_master WHERE type='index' AND name='idx_statuslog_created_at'")
            if not cursor.fetchone():
                cursor.execute('CREATE INDEX idx_statuslog_created_at ON status_log_events(created_at)')
            conn.commit()
            return True
        except Exception as e:
            log(f"[StatusLogDB] Error ensuring table: {e}")
            return False
    def connect(self):
        try:
            self._get_connection()
            return True
        except Exception as e:
            log(f"[StatusLogDB] Error connecting: {e}")
            return False
    def insert_event(self, rig: str, algo: str, title: str, details: str,
                      reasons: str = "", actions=None):
        MAX_EVENTS = 2000
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            cursor.execute('''
                INSERT INTO status_log_events (rig, algo, title, details, reasons, actions)
                VALUES (?, ?, ?, ?, ?, ?)
            ''', (rig, algo, title, details, reasons, json.dumps(actions or [])))
            new_id = cursor.lastrowid
            cursor.execute('''
                DELETE FROM status_log_events
                WHERE id NOT IN (
                    SELECT id FROM status_log_events ORDER BY id DESC LIMIT ?
                )
            ''', (MAX_EVENTS,))
            conn.commit()
            return new_id
        except Exception as e:
            log(f"[StatusLogDB] Insert error: {e}")
            return None
    def list_events(self, rig: str = None, limit: int = 200, title_q: str = None, content_q: str = None):
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            where_clauses = []
            params = []
            if rig:
                where_clauses.append("rig = ?")
                params.append(rig)
            if title_q:
                where_clauses.append("title LIKE ?")
                params.append(f"%{title_q}%")
            if content_q:
                where_clauses.append("(details LIKE ? OR reasons LIKE ?)")
                params.append(f"%{content_q}%")
                params.append(f"%{content_q}%")
            where_sql = f"WHERE {' AND '.join(where_clauses)}" if where_clauses else ""
            cursor.execute(f'''
                SELECT id, rig, algo, title, created_at FROM status_log_events
                {where_sql}
                ORDER BY id DESC LIMIT ?
            ''', (*params, limit))
            items = []
            for row in cursor.fetchall():
                items.append({
                    "id": row["id"],
                    "rig": row["rig"],
                    "algo": row["algo"],
                    "title": row["title"],
                    "created_at": row["created_at"],
                })
            return items
        except Exception as e:
            log(f"[StatusLogDB] List error: {e}")
            return []
    def get_event(self, event_id):
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            cursor.execute('''
                SELECT id, rig, algo, title, details, reasons, actions, created_at
                FROM status_log_events WHERE id = ?
            ''', (event_id,))
            row = cursor.fetchone()
            if not row:
                return None
            try:
                actions = json.loads(row["actions"]) if row["actions"] else []
            except Exception:
                actions = []
            return {
                "id": row["id"],
                "rig": row["rig"],
                "algo": row["algo"],
                "title": row["title"],
                "details": row["details"],
                "reasons": row["reasons"],
                "actions": actions,
                "created_at": row["created_at"],
            }
        except Exception as e:
            log(f"[StatusLogDB] Get error: {e}")
            return None
    def delete_events(self, ids: list) -> int:
        if not ids:
            return 0
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            placeholders = ",".join("?" for _ in ids)
            cursor.execute(
                f"DELETE FROM status_log_events WHERE id IN ({placeholders})",
                list(ids),
            )
            conn.commit()
            return cursor.rowcount
        except Exception as e:
            log(f"[StatusLogDB] Delete error: {e}")
            return 0
    def close_all(self):
        self._conns.close_all()
local_status_log_db = LocalStatusLogDB()
local_status_log_db.connect()
class LocalWalletDB:
    def __init__(self, db_path: str = None):
        if db_path is None:
            db_path = BASE_DIR / "rigcontrol_wallets.db"
        self.db_path = Path(db_path)
        self._conns = _ThreadLocalSQLiteConnections(self.db_path, self._ensure_table_for_thread, label="WalletDB")
    def _get_connection(self):
        return self._conns.get()
    def _ensure_table_for_thread(self, conn):
        try:
            cursor = conn.cursor()
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS wallets (
                    WalletId TEXT NOT NULL,
                    GpuId INTEGER NOT NULL,
                    Key TEXT NOT NULL,
                    Value TEXT,
                    UpdatedAt INTEGER,
                    SavedAt TEXT DEFAULT CURRENT_TIMESTAMP,
                    UNIQUE(WalletId, GpuId, Key)
                )
            ''')
            cursor.execute("SELECT name FROM sqlite_master WHERE type='index' AND name='idx_wallet_id'")
            if not cursor.fetchone():
                cursor.execute('CREATE INDEX idx_wallet_id ON wallets(WalletId)')
            conn.commit()
            return True
        except Exception as e:
            log(f"[WalletDB] Error ensuring table: {e}")
            return False
    def connect(self):
        try:
            conn = self._get_connection()
            return True
        except Exception as e:
            log(f"[WalletDB] Error connecting: {e}")
            return False
    def ensure_table(self):
        try:
            conn = self._get_connection()
            return True
        except Exception as e:
            log(f"[WalletDB] Error ensuring table: {e}")
            return False
    def scan(self):
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            cursor.execute('''
                SELECT WalletId, GpuId, Key, Value, UpdatedAt
                FROM wallets
                ORDER BY WalletId, GpuId, Key
            ''')
            items = []
            for row in cursor.fetchall():
                items.append({
                    "WalletId": row[0],
                    "GpuId": row[1],
                    "Key": row[2],
                    "Value": row[3],
                    "UpdatedAt": row[4]
                })
            return {"Items": items}
        except Exception as e:
            log(f"[WalletDB] Scan error: {e}")
            return {"Items": []}
    def delete_wallet(self, wallet_id: str):
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            cursor.execute('DELETE FROM wallets WHERE WalletId = ?', (wallet_id,))
            deleted = cursor.rowcount
            conn.commit()
            return deleted
        except Exception as e:
            log(f"[WalletDB] Delete error: {e}")
            return 0
    def put_wallet(self, wallet_id: str, entries: List[WalletEntryIn], updated_at: int):
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            deleted = self.delete_wallet(wallet_id)
            inserted = 0
            for e in entries:
                try:
                    cursor.execute('''
                        INSERT INTO wallets
                        (WalletId, GpuId, Key, Value, UpdatedAt)
                        VALUES (?, ?, ?, ?, ?)
                    ''', (
                        wallet_id,
                        int(e.gpu),
                        e.key.strip().upper(),
                        e.value,
                        updated_at
                    ))
                    inserted += 1
                except Exception as e:
                    log(f"[WalletDB] Insert error for {wallet_id}: {e}")
                    continue
            conn.commit()
            return deleted, inserted
        except Exception as e:
            log(f"[WalletDB] Put error: {e}")
            return 0, 0
    def close_all(self):
        self._conns.close_all()
local_wallet_db = LocalWalletDB()
class NotificationService:
    def __init__(self):
        self.load_settings()
    def load_settings(self):
        self.twilio_account_sid = os.getenv("TWILIO_ACCOUNT_SID")
        self.twilio_auth_token = os.getenv("TWILIO_AUTH_TOKEN")
        self.twilio_phone_number = os.getenv("TWILIO_PHONE_NUMBER")
        self.smtp_server = os.getenv("SMTP_SERVER", "smtp.gmail.com")
        if not self.smtp_server or self.smtp_server.strip() == "":
            self.smtp_server = "smtp.gmail.com"
            log(f"[Notifications] WARNING: SMTP_SERVER was empty, using default: {self.smtp_server}")
        try:
            self.smtp_port = int(os.getenv("SMTP_PORT", "587"))
        except (ValueError, TypeError):
            self.smtp_port = 587
        self.smtp_username = os.getenv("GMAIL_USERNAME")
        self.smtp_password = os.getenv("GMAIL_PASSWORD")
        log(f"[Notifications] Loaded settings:")
        log(f"[Notifications]   SMTP Server: {self.smtp_server}:{self.smtp_port}")
        log(f"[Notifications]   SMTP Username: {self.smtp_username}")
        log(f"[Notifications]   SMTP Password set: {'Yes' if self.smtp_password else 'No'}")
        email_recipient_str = os.getenv("EMAIL_RECIPIENTS", "")
        self.email_recipient = [email.strip() for email in email_recipient_str.split(",") if email.strip()]
        log(f"[Notifications]   Email recipients: {len(self.email_recipient)} recipients")
        self.twilio_client = None
        if self.twilio_account_sid and self.twilio_auth_token:
            try:
                self.twilio_client = Client(self.twilio_account_sid, self.twilio_auth_token)
                log(f"[Notifications] Twilio client initialized")
            except Exception as e:
                log(f"[Notifications] Failed to initialize Twilio client: {e}")
                self.twilio_client = None
    def refresh_settings(self):
        self.load_settings()
        log(f"[Notifications] Settings refreshed: email_recipient={len(self.email_recipient)}, twilio_configured={self.twilio_client is not None}")
    def send_email(self, subject: str, body: str, html_body: Optional[str] = None,
                   bypass_enabled_check: bool = False) -> bool:
        try:
            if not bypass_enabled_check and not notification_settings.get("email_enabled", True):
                log("Email notifications are disabled in settings")
                return False
            if not all([self.smtp_username, self.smtp_password]):
                log(f"Email configuration incomplete - missing SMTP credentials. Username: {bool(self.smtp_username)}, Password: {bool(self.smtp_password)}")
                return False
            if not self.email_recipient:
                log(f"No email recipients configured. Current recipients: {self.email_recipient}")
                return False
            log(f"[Email] Attempting to send to {len(self.email_recipient)} recipients: {self.email_recipient}")
            msg = MIMEMultipart('alternative')
            msg['Subject'] = subject
            msg['From'] = self.smtp_username
            msg['To'] = ", ".join(self.email_recipient)
            text_part = MIMEText(body, 'plain')
            msg.attach(text_part)
            if html_body:
                html_part = MIMEText(html_body, 'html')
                msg.attach(html_part)
            server = None
            try:
                server = smtplib.SMTP(self.smtp_server, self.smtp_port, timeout=30)
                log(f"[Email] Connection established")
                server.starttls()
                log(f"[Email] TLS started")
                server.login(self.smtp_username, self.smtp_password)
                log(f"[Email] Login successful")
                server.send_message(msg)
                log(f"[Email] Message sent")
                log(f"[Email] Email sent successfully to {len(self.email_recipient)} recipients")
                return True
            except smtplib.SMTPAuthenticationError as e:
                log(f"SMTP authentication failed: {e}")
                return False
            except smtplib.SMTPException as e:
                log(f"SMTP error: {e}")
                return False
            except Exception as e:
                log(f"Email sending error: {type(e).__name__}: {e}")
                return False
            finally:
                if server:
                    try:
                        server.quit()
                        log(f"[Email] Connection closed")
                    except:
                        pass
        except Exception as e:
            log(f"Failed to send email (outer exception): {type(e).__name__}: {e}")
            import traceback
            log(f"Traceback: {traceback.format_exc()}")
            return False
    def send_sms(self, message: str, to_number: str, from_number: Optional[str] = None) -> bool:
        return self._send_twilio_sms(message, to_number, from_number, "primary")
    def send_sms_secondary(self, message: str, to_number: str, from_number: Optional[str] = None) -> bool:
        return self._send_twilio_sms(message, to_number, from_number, "secondary")
    def _send_twilio_sms(self, message: str, to_number: str, from_number: Optional[str], notification_type: str) -> bool:
        try:
            if not self.twilio_client:
                log(f"Twilio client not initialized for {notification_type} SMS")
                return False
            if to_number:
                to_number = to_number.strip()
            from_num = from_number or self.twilio_phone_number
            if not from_num or not to_number:
                log(f"Missing phone numbers for {notification_type} SMS")
                return False
            sms = self.twilio_client.messages.create(
                body=message,
                from_=from_num,
                to=to_number
            )
            log(f"{notification_type.capitalize()} SMS sent to {to_number}, SID: {sms.sid}")
            return True
        except TwilioRestException as e:
            log(f"Twilio API error for {notification_type} SMS: {e}")
            return False
        except Exception as e:
            log(f"Failed to send {notification_type} SMS: {e}")
            return False
    def send_notification(self, message: str, subject: Optional[str] = None,
                         email: bool = True, sms_primary: bool = False,
                         sms_secondary: bool = False, sms_primary_number: Optional[str] = None,
                         sms_secondary_number: Optional[str] = None) -> Dict[str, bool]:
        results = {
            "email_sent": False,
            "sms_primary_sent": False,
            "sms_secondary_sent": False
        }
        if email:
            email_subject = subject or "RigControl Notification"
            results["email_sent"] = self.send_email(email_subject, message, bypass_enabled_check=True)
        if sms_primary:
            target_number = sms_primary_number or notification_settings.get("sms_primary_number")
            if target_number:
                results["sms_primary_sent"] = self.send_sms(message, target_number)
            else:
                log("Primary SMS enabled but no phone number configured")
        if sms_secondary:
            target_number = sms_secondary_number or notification_settings.get("sms_secondary_number")
            if target_number:
                results["sms_secondary_sent"] = self.send_sms_secondary(message, target_number)
            else:
                log("Secondary SMS enabled but no phone number configured")
        return results
notification_service = NotificationService()
# NOTIFICATION WORKER POOL
NOTIFICATION_WORKER_COUNT = 3
_notification_queue: "queue.Queue" = queue.Queue()
_notification_worker_threads: List[threading.Thread] = []
_notification_workers_stop = threading.Event()
def enqueue_notification(context_label: str, **kwargs):
    _notification_queue.put((context_label, kwargs))
def _notification_worker_loop(worker_id: int):
    log(f"[Notifications] Worker {worker_id} started")
    while not _notification_workers_stop.is_set():
        try:
            job = _notification_queue.get(timeout=1.0)
        except queue.Empty:
            continue
        if job is None:
            _notification_queue.task_done()
            break
        context_label, kwargs = job
        try:
            results = notification_service.send_notification(**kwargs)
            log(f"[Notifications] ({context_label}) Results: "
                f"Email={results['email_sent']}, SMS1={results['sms_primary_sent']}, "
                f"SMS2={results['sms_secondary_sent']}")
        except Exception as e:
            log(f"[Notifications] Worker {worker_id} error sending ({context_label}): {e}")
        finally:
            _notification_queue.task_done()
    log(f"[Notifications] Worker {worker_id} stopped")
def start_notification_workers():
    _notification_workers_stop.clear()
    for i in range(NOTIFICATION_WORKER_COUNT):
        t = threading.Thread(target=_notification_worker_loop, args=(i,), daemon=True)
        t.start()
        _notification_worker_threads.append(t)
    log(f"[Notifications] {NOTIFICATION_WORKER_COUNT} worker(s) started")
def stop_notification_workers():
    _notification_workers_stop.set()
    for _ in _notification_worker_threads:
        _notification_queue.put(None)
    for t in _notification_worker_threads:
        t.join(timeout=5.0)
    _notification_worker_threads.clear()
    log("[Notifications] Workers stopped")
CONFIG_FILE = BASE_DIR / "rigcontrol_config.json"
default_config = {
    "broadcast_interval": 10.0,
    "offline_ping_interval": 30.0,
    "offline_threshold": 90.0,
    "ws_push_min_interval": 1.2,
    "missed_refresh_threshold": 2,
    "notification_settings": {
        "email_enabled": True,
        "sms_primary_enabled": False,
        "sms_secondary_enabled": False,
        "sms_primary_number": None,
        "sms_secondary_number": None,
        "docker_email_enabled": False,
        "docker_sms_primary_enabled": False,
        "docker_sms_secondary_enabled": False
    },
    "quick_actions": {
        "a": "",
        "b": "",
        "c": ""
    },
    "telemetry_visible_groups": None
}
def _client_ip(request: Request) -> str:
    if TRUST_CLOUDFLARE:
        cf_ip = request.headers.get("cf-connecting-ip")
        if cf_ip:
            return cf_ip.strip()
    if TRUST_PROXY_HEADERS:
        fwd = request.headers.get("x-forwarded-for")
        if fwd:
            parts = [p.strip() for p in fwd.split(",") if p.strip()]
            if parts:
                idx = len(parts) - TRUSTED_PROXY_HOPS
                idx = max(0, min(idx, len(parts) - 1))
                return parts[idx]
    return request.client.host if request.client else ""
def is_local_ip(ip: str) -> bool:
    if not ip:
        return False
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(addr in net for net in _PRIVATE_NETWORKS)
def is_local_request(request: Request) -> bool:
    return is_local_ip(_client_ip(request))
def _check_and_record_ip_attempt(ip: str) -> Optional[str]:
    now = time.time()
    window_start = now - UNLOCK_ATTEMPTS_WINDOW_SECONDS
    with _unlock_lock:
        attempts = [t for t in _unlock_attempts_by_ip.get(ip, []) if t > window_start]
        if len(attempts) >= UNLOCK_MAX_ATTEMPTS_PER_IP:
            wait_s = int(min(attempts) + UNLOCK_ATTEMPTS_WINDOW_SECONDS - now)
            _unlock_attempts_by_ip[ip] = attempts
            return f"Too many unlock attempts from this IP - try again in {wait_s}s"
        attempts.append(now)
        _unlock_attempts_by_ip[ip] = attempts
    return None
def is_unlocked_request(request: Request) -> bool:
    token = request.cookies.get(UNLOCK_COOKIE_NAME)
    if not token:
        return False
    expires = _unlock_tokens.get(token)
    if not expires:
        return False
    if time.time() > expires:
        _unlock_tokens.pop(token, None)
        return False
    return True
def has_dashboard_access(request: Request) -> bool:
    return is_local_request(request) or is_unlocked_request(request)
def initialize_aws_dynamodb():
    global dynamodb, flightsheets_table
    AWS_KEYS_CSV = os.getenv(
        "AWS_KEYS_CSV",
        os.path.join(os.path.dirname(__file__), "accessKeys.csv")
    )
    if not Path(AWS_KEYS_CSV).exists():
        log(f"[AWS] AWS credentials file not found: {AWS_KEYS_CSV}")
        flightsheets_table = None
        return
    log("[AWS] Initializing AWS DynamoDB...")
    try:
        dynamodb = boto3.resource(
            "dynamodb",
            region_name=os.getenv("AWS_REGION", "us-east-1"),
            **load_aws_credentials_from_csv(AWS_KEYS_CSV),
        )
        try:
            flightsheets_table = dynamodb.Table("RigControlFlightsheets")
            flightsheets_table.load()
            log("[AWS] Flightsheets table found")
        except ClientError as e:
            if e.response["Error"]["Code"] == "ResourceNotFoundException":
                log("[AWS] Flightsheets table missing \u2014 creating it")
                flightsheets_table = dynamodb.create_table(
                    TableName="RigControlFlightsheets",
                    KeySchema=[
                        {"AttributeName": "FlightsheetId", "KeyType": "HASH"},
                        {"AttributeName": "GpuId", "KeyType": "RANGE"},
                    ],
                    AttributeDefinitions=[
                        {"AttributeName": "FlightsheetId", "AttributeType": "S"},
                        {"AttributeName": "GpuId", "AttributeType": "N"},
                    ],
                    BillingMode="PAY_PER_REQUEST",
                )
                flightsheets_table.wait_until_exists()
                log("[AWS] Flightsheets table created")
            else:
                log(f"[AWS] Error accessing DynamoDB: {e}")
                flightsheets_table = None
    except Exception as e:
        log(f"[AWS] Failed to initialize DynamoDB: {e}")
        flightsheets_table = None
def delete_flightsheet_if_exists(flightsheet_id: str) -> int:
    log(f"[FS DELETE] deleting flightsheet {flightsheet_id}")
    if USE_AWS_DB and flightsheets_table:
        deleted = 0
        last_key = None
        while True:
            args = {
                "KeyConditionExpression": Key("FlightsheetId").eq(flightsheet_id)
            }
            if last_key:
                args["ExclusiveStartKey"] = last_key
            resp = flightsheets_table.query(**args)
            with flightsheets_table.batch_writer() as batch:
                for item in resp.get("Items", []):
                    batch.delete_item(
                        Key={
                            "FlightsheetId": item["FlightsheetId"],
                            "GpuId": item["GpuId"],
                        }
                    )
                    deleted += 1
            last_key = resp.get("LastEvaluatedKey")
            if not last_key:
                break
        return deleted
    else:
        return local_flightsheet_db.delete_flightsheet(flightsheet_id)
def initialize_local_database():
    log(f"[LocalDB Init] Starting database initialization for '{local_flightsheet_db.db_path.name}' (USE_AWS_DB={USE_AWS_DB})")
    if not USE_AWS_DB:
        log(f"[LocalDB Init] Using local SQLite database: {local_flightsheet_db.db_path.name}")
        local_flightsheet_db.connect()
        resp = local_flightsheet_db.scan()
        item_count = len(resp.get("Items", []))
        if item_count == 0:
            log(f"[LocalDB Init] Local database is empty, attempting to import from DynamoDB...")
            if not flightsheets_table:
                initialize_aws_dynamodb()
            if flightsheets_table:
                success = import_from_dynamodb_to_local()
                if success:
                    resp = local_flightsheet_db.scan()
                    item_count = len(resp.get("Items", []))
                    log(f"[LocalDB Init] Import successful! Now have {item_count} entries")
                else:
                    log(f"[LocalDB Init] Import failed, starting with empty database")
            else:
                log(f"[LocalDB Init] No DynamoDB available for import, starting with empty database")
        log(f"[LocalDB Init] '{local_flightsheet_db.db_path.name}' ready with {item_count} entries")
        return True
    log(f"[LocalDB Init] Using AWS DynamoDB")
    initialize_aws_dynamodb()
    if not flightsheets_table:
        log(f"[LocalDB Init] WARNING: AWS DynamoDB not available!")
        return False
    local_db_exists = local_flightsheet_db.db_path.exists()
    if local_db_exists:
        log(f"[LocalDB Init] Local backup database exists: {local_flightsheet_db.db_path.name}")
        resp = local_flightsheet_db.scan()
        local_count = len(resp.get("Items", []))
        if local_count == 0:
            log(f"[LocalDB Init] Local backup '{local_flightsheet_db.db_path.name}' is empty, importing from DynamoDB...")
            success = import_from_dynamodb_to_local()
            log(f"[LocalDB Init] Import {'successful' if success else 'failed'}")
            return success
        else:
            log(f"[LocalDB Init] Local backup '{local_flightsheet_db.db_path.name}' has {local_count} entries")
            return True
    else:
        log(f"[LocalDB Init] No local backup database found")
        return True
def import_from_dynamodb_to_local():
    if not flightsheets_table:
        log(f"[LocalDB Import] DynamoDB table not available, skipping import")
        return False
    try:
        log(f"[LocalDB Import] Starting import from DynamoDB")
        conn = local_flightsheet_db._get_connection()
        local_flightsheet_db._ensure_table_for_thread(conn)
        cursor = conn.cursor()
        cursor.execute('DELETE FROM flightsheets')
        conn.commit()
        import_count = 0
        response = flightsheets_table.scan()
        items = response.get('Items', [])
        import_count = process_dynamodb_batch(conn, items)
        while 'LastEvaluatedKey' in response:
            response = flightsheets_table.scan(
                ExclusiveStartKey=response['LastEvaluatedKey']
            )
            items = response.get('Items', [])
            import_count += process_dynamodb_batch(conn, items)
        log(f"[LocalDB Import] Successfully imported {import_count} items from DynamoDB")
        return True
    except Exception as e:
        log(f"[LocalDB Import] Error importing from DynamoDB: {e}")
        return False
def process_dynamodb_batch(conn, items: List[Dict[str, Any]]) -> int:
    import_count = 0
    try:
        cursor = conn.cursor()
        for item in items:
            try:
                flightsheet_id = item.get('FlightsheetId')
                gpu_id = item.get('GpuId')
                key = item.get('Key')
                value = item.get('Value')
                updated_at = item.get('UpdatedAt')
                if not all([flightsheet_id, gpu_id is not None, key]):
                    continue
                cursor.execute('''
                    INSERT INTO flightsheets
                    (FlightsheetId, GpuId, Key, Value, UpdatedAt)
                    VALUES (?, ?, ?, ?, ?)
                ''', (
                    flightsheet_id,
                    int(gpu_id),
                    str(key).strip().upper(),
                    str(value) if value is not None else '',
                    int(updated_at) if updated_at is not None else int(time.time())
                ))
                import_count += 1
            except Exception as e:
                log(f"[LocalDB Import] Error processing item: {e}")
                continue
        conn.commit()
        return import_count
    except Exception as e:
        log(f"[LocalDB Import] Batch processing error: {e}")
        return 0
def create_local_database_from_dynamodb():
    try:
        local_flightsheet_db.db_path.parent.mkdir(parents=True, exist_ok=True)
        local_flightsheet_db.connect()
        local_flightsheet_db.ensure_table()
        if flightsheets_table:
            success = import_from_dynamodb_to_local()
            if success:
                log(f"[LocalDB Create] Successfully created local database from DynamoDB")
            else:
                log(f"[LocalDB Create] Created empty local database (DynamoDB import failed)")
            return success
        else:
            log(f"[LocalDB Create] Created empty local database (no DynamoDB table)")
            return True
    except Exception as e:
        log(f"[LocalDB Create] Error creating local database: {e}")
        return False
def load_aws_credentials_from_csv(csv_path: str | Path) -> dict:
    csv_path = Path(csv_path)
    if not csv_path.exists():
        raise FileNotFoundError(f"AWS credentials file not found: {csv_path}")
    with csv_path.open(newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for row in reader:
            access_key = (
                row.get("Access key ID")
                or row.get("Access key")
                or row.get("AccessKeyId")
            )
            secret_key = (
                row.get("Secret access key")
                or row.get("Secret access key ")
                or row.get("SecretAccessKey")
            )
            if access_key and secret_key:
                return {
                    "aws_access_key_id": access_key.strip(),
                    "aws_secret_access_key": secret_key.strip(),
                }
_dynamo_backup_tables: Dict[str, Any] = {}
def _key_schema_matches(actual: list, expected: list) -> bool:
    norm = lambda ks: {(k["AttributeName"], k["KeyType"]) for k in ks}
    return norm(actual) == norm(expected)
def get_or_create_dynamo_table(table_name: str, key_schema: list, attr_defs: list):
    if not dynamodb:
        return None
    try:
        table = dynamodb.Table(table_name)
        table.load()
        if not _key_schema_matches(table.key_schema, key_schema):
            raise ValueError(
                f"{table_name} already exists in AWS with an outdated key schema "
                f"(this happens if it was created before a recent fix) - delete the "
                f"table in the AWS DynamoDB console and try again so it can be "
                f"recreated with the correct schema"
            )
        return table
    except ClientError as e:
        if e.response["Error"]["Code"] == "ResourceNotFoundException":
            log(f"[Backups] {table_name} missing — creating it")
            table = dynamodb.create_table(
                TableName=table_name,
                KeySchema=key_schema,
                AttributeDefinitions=attr_defs,
                BillingMode="PAY_PER_REQUEST",
            )
            table.wait_until_exists()
            log(f"[Backups] {table_name} created")
            return table
        log(f"[Backups] Error accessing {table_name}: {e}")
        return None
    except ValueError:
        raise
    except Exception as e:
        log(f"[Backups] Error accessing {table_name}: {e}")
        return None
def _generic_scan(local_db) -> List[Dict[str, Any]]:
    return local_db.scan().get("Items", [])
def _generic_restore(local_db, sql_table: str, id_col: str, items: List[Dict[str, Any]], missing_only: bool = False) -> int:
    conn = local_db._get_connection()
    local_db._ensure_table_for_thread(conn)
    cursor = conn.cursor()
    if not missing_only:
        cursor.execute(f"DELETE FROM {sql_table}")
        conn.commit()
    inserted = 0
    for item in items:
        try:
            row_id = item.get(id_col)
            gpu_id = item.get("GpuId")
            key = item.get("Key")
            value = item.get("Value")
            updated_at = item.get("UpdatedAt")
            if not all([row_id, gpu_id is not None, key]):
                continue
            cursor.execute(f'''
                INSERT OR IGNORE INTO {sql_table}
                ({id_col}, GpuId, Key, Value, UpdatedAt)
                VALUES (?, ?, ?, ?, ?)
            ''', (
                row_id,
                int(gpu_id),
                str(key).strip().upper(),
                str(value) if value is not None else "",
                int(updated_at) if updated_at is not None else int(time.time()),
            ))
            if cursor.rowcount > 0:
                inserted += 1
        except Exception as e:
            log(f"[Backups] Restore insert error: {e}")
            continue
    conn.commit()
    return inserted
def _status_log_scan() -> List[Dict[str, Any]]:
    conn = local_status_log_db._get_connection()
    cursor = conn.cursor()
    cursor.execute('''
        SELECT id, rig, algo, title, details, reasons, actions, created_at
        FROM status_log_events ORDER BY id
    ''')
    items = []
    for row in cursor.fetchall():
        items.append({
            "id": row["id"],
            "rig": row["rig"],
            "algo": row["algo"],
            "title": row["title"],
            "details": row["details"],
            "reasons": row["reasons"],
            "actions": row["actions"],
            "created_at": row["created_at"],
        })
    return items
def _status_log_restore(items: List[Dict[str, Any]], missing_only: bool = False) -> int:
    conn = local_status_log_db._get_connection()
    local_status_log_db._ensure_table_for_thread(conn)
    cursor = conn.cursor()
    if not missing_only:
        cursor.execute("DELETE FROM status_log_events")
        conn.commit()
    inserted = 0
    for item in items:
        try:
            cursor.execute('''
                INSERT OR IGNORE INTO status_log_events
                (id, rig, algo, title, details, reasons, actions, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ''', (
                item.get("id"),
                item.get("rig"),
                item.get("algo"),
                item.get("title"),
                item.get("details"),
                item.get("reasons"),
                item.get("actions"),
                item.get("created_at"),
            ))
            if cursor.rowcount > 0:
                inserted += 1
        except Exception as e:
            log(f"[Backups] Status log restore insert error: {e}")
            continue
    conn.commit()
    return inserted
def _templates_file_path():
    return STATIC_DIR / "config" / "templates.json"
class _JsonFileStub:
    def __init__(self, path):
        self._path = path
    @property
    def db_path(self):
        return self._path
def _json_file_scan(path) -> List[Dict[str, Any]]:
    if not path.exists():
        return []
    try:
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
        return [{
            "FileId": path.name,
            "Content": content,
            "UpdatedAt": int(path.stat().st_mtime),
        }]
    except Exception as e:
        log(f"[Backups] Error reading {path}: {e}")
        return []
def _json_file_restore(path, items: List[Dict[str, Any]], missing_only: bool = False) -> int:
    if not items:
        return 0
    content = items[0].get("Content")
    if content is None:
        return 0
    try:
        if missing_only and path.exists():
            return 0
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        return 1
    except Exception as e:
        log(f"[Backups] Error restoring {path}: {e}")
        return 0
def _generic_wipe(local_db, sql_table: str) -> None:
    conn = local_db._get_connection()
    local_db._ensure_table_for_thread(conn)
    cursor = conn.cursor()
    cursor.execute(f"DELETE FROM {sql_table}")
    conn.commit()
def _status_log_wipe() -> None:
    conn = local_status_log_db._get_connection()
    local_status_log_db._ensure_table_for_thread(conn)
    cursor = conn.cursor()
    cursor.execute("DELETE FROM status_log_events")
    conn.commit()
def _json_file_wipe(path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write("{}")
BACKUP_TARGETS = [
    {
        "id": "flightsheets",
        "label": "Flightsheets",
        "file_name": "rigcontrol_flightsheets.db",
        "local_db": lambda: local_flightsheet_db,
        "scan_fn": lambda: _generic_scan(local_flightsheet_db),
        "restore_fn": lambda items, missing_only=False: _generic_restore(local_flightsheet_db, "flightsheets", "FlightsheetId", items, missing_only),
        "wipe_fn": lambda: _generic_wipe(local_flightsheet_db, "flightsheets"),
        "dynamo_table": "RigControlFlightsheets",
        "key_schema": [
            {"AttributeName": "FlightsheetId", "KeyType": "HASH"},
            {"AttributeName": "GpuId", "KeyType": "RANGE"},
        ],
        "attr_defs": [
            {"AttributeName": "FlightsheetId", "AttributeType": "S"},
            {"AttributeName": "GpuId", "AttributeType": "N"},
        ],
    },
    {
        "id": "overclocks",
        "label": "Overclocks",
        "file_name": "rigcontrol_overclocks.db",
        "local_db": lambda: local_overclock_db,
        "scan_fn": lambda: _generic_scan(local_overclock_db),
        "restore_fn": lambda items, missing_only=False: _generic_restore(local_overclock_db, "overclocks", "OverclockId", items, missing_only),
        "wipe_fn": lambda: _generic_wipe(local_overclock_db, "overclocks"),
        "dynamo_table": "RigControlOverclocks",
        "key_schema": [
            {"AttributeName": "OverclockId", "KeyType": "HASH"},
            {"AttributeName": "EntryKey", "KeyType": "RANGE"},
        ],
        "attr_defs": [
            {"AttributeName": "OverclockId", "AttributeType": "S"},
            {"AttributeName": "EntryKey", "AttributeType": "S"},
        ],
    },
    {
        "id": "saved_commands",
        "label": "Saved Commands",
        "file_name": "rigcontrol_saved_commands.db",
        "local_db": lambda: local_saved_command_db,
        "scan_fn": lambda: _generic_scan(local_saved_command_db),
        "restore_fn": lambda items, missing_only=False: _generic_restore(local_saved_command_db, "saved_commands", "CommandId", items, missing_only),
        "wipe_fn": lambda: _generic_wipe(local_saved_command_db, "saved_commands"),
        "dynamo_table": "RigControlSavedCommands",
        "key_schema": [
            {"AttributeName": "CommandId", "KeyType": "HASH"},
            {"AttributeName": "EntryKey", "KeyType": "RANGE"},
        ],
        "attr_defs": [
            {"AttributeName": "CommandId", "AttributeType": "S"},
            {"AttributeName": "EntryKey", "AttributeType": "S"},
        ],
    },
    {
        "id": "watchdog_profiles",
        "label": "Watchdog Profiles",
        "file_name": "rigcontrol_watchdog_profiles.db",
        "local_db": lambda: local_watchdog_profile_db,
        "scan_fn": lambda: _generic_scan(local_watchdog_profile_db),
        "restore_fn": lambda items, missing_only=False: _generic_restore(local_watchdog_profile_db, "watchdog_profiles", "WatchdogProfileId", items, missing_only),
        "wipe_fn": lambda: _generic_wipe(local_watchdog_profile_db, "watchdog_profiles"),
        "dynamo_table": "RigControlWatchdogProfiles",
        "key_schema": [
            {"AttributeName": "WatchdogProfileId", "KeyType": "HASH"},
            {"AttributeName": "EntryKey", "KeyType": "RANGE"},
        ],
        "attr_defs": [
            {"AttributeName": "WatchdogProfileId", "AttributeType": "S"},
            {"AttributeName": "EntryKey", "AttributeType": "S"},
        ],
    },
    {
        "id": "wallets",
        "label": "Wallets",
        "file_name": "rigcontrol_wallets.db",
        "local_db": lambda: local_wallet_db,
        "scan_fn": lambda: _generic_scan(local_wallet_db),
        "restore_fn": lambda items, missing_only=False: _generic_restore(local_wallet_db, "wallets", "WalletId", items, missing_only),
        "wipe_fn": lambda: _generic_wipe(local_wallet_db, "wallets"),
        "dynamo_table": "RigControlWallets",
        "key_schema": [
            {"AttributeName": "WalletId", "KeyType": "HASH"},
            {"AttributeName": "EntryKey", "KeyType": "RANGE"},
        ],
        "attr_defs": [
            {"AttributeName": "WalletId", "AttributeType": "S"},
            {"AttributeName": "EntryKey", "AttributeType": "S"},
        ],
    },
    {
        "id": "status_log",
        "label": "Status Log",
        "file_name": "rigcontrol_status_log.db",
        "local_db": lambda: local_status_log_db,
        "scan_fn": _status_log_scan,
        "restore_fn": lambda items, missing_only=False: _status_log_restore(items, missing_only),
        "wipe_fn": _status_log_wipe,
        "dynamo_table": "RigControlStatusLog",
        "key_schema": [
            {"AttributeName": "id", "KeyType": "HASH"},
        ],
        "attr_defs": [
            {"AttributeName": "id", "AttributeType": "N"},
        ],
    },
    {
        "id": "server_config",
        "label": "Server Config",
        "file_name": "rigcontrol_config.json",
        "local_db": lambda: _JsonFileStub(CONFIG_FILE),
        "scan_fn": lambda: _json_file_scan(CONFIG_FILE),
        "restore_fn": lambda items, missing_only=False: _json_file_restore(CONFIG_FILE, items, missing_only),
        "wipe_fn": lambda: _json_file_wipe(CONFIG_FILE),
        "dynamo_table": "RigControlServerConfig",
        "key_schema": [
            {"AttributeName": "FileId", "KeyType": "HASH"},
        ],
        "attr_defs": [
            {"AttributeName": "FileId", "AttributeType": "S"},
        ],
    },
    {
        "id": "templates",
        "label": "Templates",
        "file_name": "templates.json",
        "local_db": lambda: _JsonFileStub(_templates_file_path()),
        "scan_fn": lambda: _json_file_scan(_templates_file_path()),
        "restore_fn": lambda items, missing_only=False: _json_file_restore(_templates_file_path(), items, missing_only),
        "wipe_fn": lambda: _json_file_wipe(_templates_file_path()),
        "dynamo_table": "RigControlTemplates",
        "key_schema": [
            {"AttributeName": "FileId", "KeyType": "HASH"},
        ],
        "attr_defs": [
            {"AttributeName": "FileId", "AttributeType": "S"},
        ],
    },
]
def get_backup_target(target_id: str):
    for t in BACKUP_TARGETS:
        if t["id"] == target_id:
            return t
    return None
def delete_local_target(target: dict):
    wipe_fn = target.get("wipe_fn")
    if not wipe_fn:
        return False, "No local delete handler for this target"
    try:
        wipe_fn()
        return True, None
    except Exception as e:
        log(f"[Backups] Local delete error for {target['id']}: {e}")
        return False, str(e)
def delete_dynamo_target(target: dict):
    if not dynamodb:
        return False, "Not connected to AWS DynamoDB - check accessKeys.csv and test the connection first"
    try:
        table = dynamodb.Table(target["dynamo_table"])
        table.delete()
        table.wait_until_not_exists()
        return True, None
    except ClientError as e:
        if e.response["Error"]["Code"] == "ResourceNotFoundException":
            return True, None
        log(f"[Backups] DynamoDB delete error for {target['id']}: {e}")
        return False, str(e)
    except Exception as e:
        log(f"[Backups] DynamoDB delete error for {target['id']}: {e}")
        return False, str(e)
def _target_uses_entry_key(target: dict) -> bool:
    return any(k.get("AttributeName") == "EntryKey" for k in target["key_schema"])
def backup_target_to_dynamo(target: dict):
    if not dynamodb:
        return False, 0, "Not connected to AWS DynamoDB - check accessKeys.csv and test the connection first"
    try:
        table = get_or_create_dynamo_table(target["dynamo_table"], target["key_schema"], target["attr_defs"])
        if not table:
            return False, 0, f"Could not access or create DynamoDB table {target['dynamo_table']}"
        items = target["scan_fn"]()
        use_entry_key = _target_uses_entry_key(target)
        count = 0
        with table.batch_writer() as batch:
            for item in items:
                clean = {k: v for k, v in item.items() if v is not None}
                if use_entry_key:
                    clean["EntryKey"] = f"{item.get('GpuId')}#{item.get('Key')}"
                batch.put_item(Item=clean)
                count += 1
        return True, count, None
    except Exception as e:
        log(f"[Backups] Backup error for {target['id']}: {e}")
        return False, 0, str(e)
def restore_target_from_dynamo(target: dict, missing_only: bool = False):
    if not dynamodb:
        return False, 0, "Not connected to AWS DynamoDB - check accessKeys.csv and test the connection first"
    try:
        table = get_or_create_dynamo_table(target["dynamo_table"], target["key_schema"], target["attr_defs"])
        if not table:
            return False, 0, f"Could not access or create DynamoDB table {target['dynamo_table']}"
        items = []
        response = table.scan()
        items.extend(response.get("Items", []))
        while "LastEvaluatedKey" in response:
            response = table.scan(ExclusiveStartKey=response["LastEvaluatedKey"])
            items.extend(response.get("Items", []))
        count = target["restore_fn"](items, missing_only)
        return True, count, None
    except Exception as e:
        log(f"[Backups] Restore error for {target['id']}: {e}")
        return False, 0, str(e)
def scan_dynamo_target(target: dict):
    if not dynamodb:
        return False, [], "Not connected to AWS DynamoDB - check accessKeys.csv and test the connection first"
    try:
        table = get_or_create_dynamo_table(target["dynamo_table"], target["key_schema"], target["attr_defs"])
        if not table:
            return False, [], f"Could not access or create DynamoDB table {target['dynamo_table']}"
        items = []
        response = table.scan()
        items.extend(response.get("Items", []))
        while "LastEvaluatedKey" in response:
            response = table.scan(ExclusiveStartKey=response["LastEvaluatedKey"])
            items.extend(response.get("Items", []))
        return True, items, None
    except Exception as e:
        log(f"[Backups] DynamoDB scan error for {target['id']}: {e}")
        return False, [], str(e)
def check_backup_config():
    AWS_KEYS_CSV = os.getenv(
        "AWS_KEYS_CSV",
        os.path.join(os.path.dirname(__file__), "accessKeys.csv")
    )
    path = Path(AWS_KEYS_CSV)
    if not path.exists():
        return {"ok": False, "path": str(path), "message": "accessKeys.csv not found"}
    try:
        creds = load_aws_credentials_from_csv(path)
        if creds.get("aws_access_key_id") and creds.get("aws_secret_access_key"):
            masked = creds["aws_access_key_id"][:4] + "..." + creds["aws_access_key_id"][-4:]
            return {"ok": True, "path": str(path), "message": f"accessKeys.csv looks valid (key {masked})"}
        return {"ok": False, "path": str(path), "message": "accessKeys.csv found but missing access key / secret key columns"}
    except Exception as e:
        return {"ok": False, "path": str(path), "message": f"Could not parse accessKeys.csv: {e}"}
def test_dynamodb_connection():
    config_check = check_backup_config()
    if not config_check["ok"]:
        return {"ok": False, "message": config_check["message"]}
    try:
        AWS_KEYS_CSV = os.getenv(
            "AWS_KEYS_CSV",
            os.path.join(os.path.dirname(__file__), "accessKeys.csv")
        )
        creds = load_aws_credentials_from_csv(AWS_KEYS_CSV)
        client = boto3.client(
            "dynamodb",
            region_name=os.getenv("AWS_REGION", "us-east-1"),
            **creds,
        )
        resp = client.list_tables(Limit=100)
        table_names = resp.get("TableNames", [])
        backup_tables_present = [t["dynamo_table"] for t in BACKUP_TARGETS if t["dynamo_table"] in table_names]
        return {
            "ok": True,
            "message": f"Connected to AWS DynamoDB ({len(table_names)} table(s) in account, {len(backup_tables_present)} RigControl backup table(s) present)",
            "tables": table_names,
        }
    except Exception as e:
        return {"ok": False, "message": f"Connection failed: {e}"}
    raise RuntimeError("No valid AWS credentials found in CSV")
def load_all_settings():
    global BROADCAST_INTERVAL, OFFLINE_PING_INTERVAL, OFFLINE_THRESHOLD, WS_PUSH_MIN_INTERVAL, MISSED_REFRESH_THRESHOLD, notification_settings, quick_actions, telemetry_visible_groups
    if CONFIG_FILE.exists():
        try:
            with open(CONFIG_FILE, "r") as f:
                config = json.load(f)
            BROADCAST_INTERVAL = float(config.get("broadcast_interval", BROADCAST_INTERVAL))
            OFFLINE_PING_INTERVAL = float(config.get("offline_ping_interval", OFFLINE_PING_INTERVAL))
            OFFLINE_THRESHOLD = float(config.get("offline_threshold", OFFLINE_THRESHOLD))
            WS_PUSH_MIN_INTERVAL = float(config.get("ws_push_min_interval", WS_PUSH_MIN_INTERVAL))
            MISSED_REFRESH_THRESHOLD = int(config.get("missed_refresh_threshold", MISSED_REFRESH_THRESHOLD))
            notification_settings.update(config.get("notification_settings", {}))
            quick_actions.update(config.get("quick_actions", {}))
            telemetry_visible_groups = config.get("telemetry_visible_groups", None)
            os.environ["EMAIL_ENABLED"] = str(notification_settings.get("email_enabled", True))
            os.environ["SMS_PRIMARY_ENABLED"] = str(notification_settings.get("sms_primary_enabled", False))
            os.environ["SMS_SECONDARY_ENABLED"] = str(notification_settings.get("sms_secondary_enabled", False))
            log(f"[Config] Loaded from {CONFIG_FILE}")
            log(f"[Config] Broadcast interval: {BROADCAST_INTERVAL}s")
            log(f"[Config] Offline ping interval: {OFFLINE_PING_INTERVAL}s")
            log(f"[Config] Offline threshold: {OFFLINE_THRESHOLD}s")
            log(f"[Config] WS push min interval: {WS_PUSH_MIN_INTERVAL}s")
            log(f"[Config] Missed refresh threshold: {MISSED_REFRESH_THRESHOLD}")
            log(f"[Config] Email enabled: {notification_settings.get('email_enabled')}")
            log(f"[Config] SMS primary enabled: {notification_settings.get('sms_primary_enabled')}")
            log(f"[Config] SMS secondary enabled: {notification_settings.get('sms_secondary_enabled')}")
            log(f"[Config] Quick actions loaded: a={'set' if quick_actions.get('a') else 'empty'}, b={'set' if quick_actions.get('b') else 'empty'}, c={'set' if quick_actions.get('c') else 'empty'}")
            log(f"[Config] Telemetry visible groups: {telemetry_visible_groups if telemetry_visible_groups is not None else 'ALL (no filter set)'}")
            if notification_service:
                notification_service.refresh_settings()
        except Exception as e:
            log(f"[Config] Error loading config: {e}")
            save_all_settings()
    else:
        log(f"[Config] Config file not found, creating with defaults")
        save_all_settings()
def save_all_settings():
    global BROADCAST_INTERVAL, OFFLINE_PING_INTERVAL, OFFLINE_THRESHOLD, WS_PUSH_MIN_INTERVAL, MISSED_REFRESH_THRESHOLD, notification_settings, quick_actions, telemetry_visible_groups
    try:
        config = {
            "broadcast_interval": BROADCAST_INTERVAL,
            "offline_ping_interval": OFFLINE_PING_INTERVAL,
            "offline_threshold": OFFLINE_THRESHOLD,
            "ws_push_min_interval": WS_PUSH_MIN_INTERVAL,
            "missed_refresh_threshold": MISSED_REFRESH_THRESHOLD,
            "notification_settings": notification_settings,
            "quick_actions": quick_actions,
            "telemetry_visible_groups": telemetry_visible_groups,
            "last_updated": time.time()
        }
        CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with open(CONFIG_FILE, "w") as f:
            json.dump(config, f, indent=2, default=str)
        log(f"[Config] Saved all settings to {CONFIG_FILE}")
        os.environ["BROADCAST_INTERVAL"] = str(BROADCAST_INTERVAL)
        os.environ["OFFLINE_PING_INTERVAL"] = str(OFFLINE_PING_INTERVAL)
        os.environ["OFFLINE_THRESHOLD"] = str(OFFLINE_THRESHOLD)
        os.environ["EMAIL_ENABLED"] = str(notification_settings.get("email_enabled", True))
        os.environ["SMS_PRIMARY_ENABLED"] = str(notification_settings.get("sms_primary_enabled", False))
        os.environ["SMS_SECONDARY_ENABLED"] = str(notification_settings.get("sms_secondary_enabled", False))
        if notification_service:
            notification_service.refresh_settings()
    except Exception as e:
        log(f"[Config] Error saving settings: {e}")
def any_notification_channel_enabled() -> bool:
    return (
        notification_settings.get("email_enabled", False) or
        notification_settings.get("sms_primary_enabled", False) or
        notification_settings.get("sms_secondary_enabled", False) or
        notification_settings.get("docker_email_enabled", False) or
        notification_settings.get("docker_sms_primary_enabled", False) or
        notification_settings.get("docker_sms_secondary_enabled", False)
    )
def docker_notifications_enabled() -> bool:
    return (
        notification_settings.get("docker_email_enabled", False) or
        notification_settings.get("docker_sms_primary_enabled", False) or
        notification_settings.get("docker_sms_secondary_enabled", False)
    )
def get_effective_visible_groups():
    if telemetry_visible_groups is None:
        return None                                                 
    if docker_notifications_enabled() and "docker" not in telemetry_visible_groups:
        return telemetry_visible_groups + ["docker"]
    return telemetry_visible_groups
def check_offline_rigs_and_notify():
    now = time.time()
    if not any_notification_channel_enabled():
        return
    docker_channels_enabled = docker_notifications_enabled()
    has_dashboard_client = len(connected_clients) > 0
    docker_state_changes = []
    with rigs_lock, rig_offline_notifications_lock, rig_docker_state_lock:
        all_rigs = set(known_rigs)
        for rig_name in all_rigs:
            info = rigs.get(rig_name)
            last_update = info.get("updated", 0) if info else 0
            time_offline = now - last_update
            if time_offline > OFFLINE_THRESHOLD:
                last_notification = rig_offline_notifications.get(rig_name, 0)
                if now - last_notification > 86400:
                    hours = int(time_offline // 3600)
                    minutes = int((time_offline % 3600) // 60)
                    subject = f"Rig Offline Alert: {rig_name}"
                    message = f"Rig '{rig_name}' has been offline for {hours} hours, {minutes} minutes."
                    message += f"\n\nLast seen: {time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime(last_update))} UTC"
                    message += f"\n\nThreshold: {int(OFFLINE_THRESHOLD//3600)}h {int((OFFLINE_THRESHOLD%3600)//60)}m"
                    enqueue_notification(
                        f"offline_alert:{rig_name}",
                        message=message,
                        subject=subject,
                        email=notification_settings.get("email_enabled", True),
                        sms_primary=notification_settings.get("sms_primary_enabled", False),
                        sms_secondary=notification_settings.get("sms_secondary_enabled", False),
                        sms_primary_number=notification_settings.get("sms_primary_number"),
                        sms_secondary_number=notification_settings.get("sms_secondary_number")
                    )
                    rig_offline_notifications[rig_name] = now
                    log(f"[Notifications] Queued offline alert for {rig_name} (offline {hours}h {minutes}m)")
            else:
                if rig_name in rig_offline_notifications:
                    del rig_offline_notifications[rig_name]
                docker_list = (info or {}).get("data", {}).get("docker")
                if isinstance(docker_list, list):
                    has_docker = bool(docker_list)
                    prev_state = rig_docker_state.get(rig_name)
                    if prev_state is None:
                        rig_docker_state[rig_name] = has_docker
                    elif prev_state != has_docker:
                        rig_docker_state[rig_name] = has_docker
                        going_offline_soon = (not has_docker) and (time_offline > OFFLINE_THRESHOLD * 0.5)
                        if docker_channels_enabled and not going_offline_soon:
                            names = [c.get("name", "?") for c in docker_list] if docker_list else []
                            docker_state_changes.append((rig_name, has_docker, names))
        if docker_state_changes and docker_channels_enabled and not has_dashboard_client:
            if len(docker_state_changes) == 1:
                rig_name, _, _ = docker_state_changes[0]
                subject = f"Docker State Change: {rig_name}"
            else:
                subject = f"Docker State Change: {len(docker_state_changes)} rigs"
            lines = []
            for rig_name, has_docker, names in docker_state_changes:
                state_word = "now has" if has_docker else "no longer has"
                lines.append(f"Rig '{rig_name}' {state_word} Docker container(s) running.")
                lines.append(f"  Containers: {', '.join(names) if names else '(none)'}")
                lines.append("")
            message = "\n".join(lines).rstrip()
            message += f"\n\nTime: {time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime(now))} UTC"
            enqueue_notification(
                "docker_state_change",
                message=message,
                subject=subject,
                email=notification_settings.get("docker_email_enabled", False),
                sms_primary=notification_settings.get("docker_sms_primary_enabled", False),
                sms_secondary=notification_settings.get("docker_sms_secondary_enabled", False),
                sms_primary_number=notification_settings.get("sms_primary_number"),
                sms_secondary_number=notification_settings.get("sms_secondary_number")
            )
            changed_rig_names = ", ".join(r for r, _, _ in docker_state_changes)
            log(f"[Notifications] Queued bundled docker state change alert for {len(docker_state_changes)} rig(s): {changed_rig_names}")
        elif docker_state_changes and docker_channels_enabled and has_dashboard_client:
            changed_rig_names = ", ".join(r for r, _, _ in docker_state_changes)
            log(f"[Notifications] Docker state changed for {len(docker_state_changes)} rig(s) ({changed_rig_names}) "
                f"but a dashboard client is connected - skipping the email/SMS, state is still visible live")
async def handle_mqtt_message(topic: str, payload: bytes):
    """Handles an incoming MQTT message on the main asyncio event loop, offloading the blocking SQLite write to a thread."""
    try:
        data = json.loads(payload.decode("utf-8"))
        now = time.time()
        if topic.endswith("/cmd_response"):
            log(f"[CMD_RESPONSE] {data.get('rig')} id={data.get('id')}")
            await push_cmd_response_to_ws(data)
            return
        if topic.endswith("/stats_response"):
            log(f"[STATS_RESPONSE] {data.get('rig')} id={data.get('id')} count={data.get('count')}")
            await handle_stats_response_chunk(data)
            return
        if topic.endswith("/watchdog_alert"):
            wd_rig = data.get("rig", "unknown")
            wd_algo = data.get("algo", "unknown")
            wd_reasons = data.get("reasons", "")
            wd_actions = data.get("actions") or []
            log(f"[WATCHDOG_ALERT] {wd_rig} '{wd_algo}': {wd_reasons} (actions={wd_actions})")
            wants_email = "ACTION_EMAIL_NOTIFY" in wd_actions
            wants_sms = "ACTION_SMS_NOTIFY" in wd_actions
            notification_queued = False
            if wants_email or wants_sms:
                enqueue_notification(
                    f"watchdog_alert:{wd_rig}",
                    message=f"Rig '{wd_rig}' - '{wd_algo}': {wd_reasons}",
                    subject=f"RigControl Watchdog Alert - {wd_rig}",
                    email=wants_email,
                    sms_primary=wants_sms,
                    sms_secondary=wants_sms,
                    sms_primary_number=notification_settings.get("sms_primary_number"),
                    sms_secondary_number=notification_settings.get("sms_secondary_number"),
                )
                notification_queued = True
            sl_title = f"{wd_rig}: {wd_algo}"
            sl_details_lines = [
                f"Rig: {wd_rig}",
                f"Algorithm: {wd_algo}",
                f"Reasons: {wd_reasons or '(none given)'}",
                f"Actions requested: {', '.join(wd_actions) if wd_actions else '(none)'}",
                f"Time: {time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime(now))} UTC",
            ]
            if notification_queued:
                sl_details_lines.append("Notification: queued (see server log for send result)")
            sl_details = "\n".join(sl_details_lines)
            sl_event_id = await asyncio.to_thread(
                local_status_log_db.insert_event,
                rig=wd_rig, algo=wd_algo, title=sl_title,
                details=sl_details, reasons=wd_reasons, actions=wd_actions,
            )
            if sl_event_id is not None:
                sl_event = {
                    "id": sl_event_id,
                    "rig": wd_rig,
                    "algo": wd_algo,
                    "title": sl_title,
                    "created_at": time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(now)),
                }
                await push_status_log_event_to_ws(sl_event)
            return
        rig_name = data.get("rig")
        if not rig_name:
            return
        with known_rigs_lock:
            known_rigs.add(rig_name)
        with rigs_lock, rig_missed_refreshes_lock, rig_offline_notifications_lock:
            was_offline = rigs.get(rig_name, {}).get("online", True) == False
            if data.get("type") == "check":
                existing = rigs.get(rig_name, {})
                existing_data = existing.get("data", data)
                merged_data = {
                    **existing_data,
                    "docker": data.get("docker", existing_data.get("docker")),
                }
                rigs[rig_name] = {
                    **existing,
                    "timestamp": int(now),
                    "updated": now,
                    "online": True,
                    "data": merged_data,
                }
            else:
                rigs[rig_name] = {
                    "timestamp": int(now),
                    "updated": now,
                    "online": True,
                    "data": data,
                }
            rig_missed_refreshes[rig_name] = 0
            if was_offline:
                log(f"[Online] {rig_name} came back online")
                if rig_name in rig_offline_notifications:
                    del rig_offline_notifications[rig_name]
        if connected_clients:
            request_broadcast()
    except json.JSONDecodeError:
        log(f"[MQTT] Invalid JSON in message from {topic}")
    except Exception as e:
        log(f"[MQTT] Error processing message: {e}")
def build_current_snapshot():
    with rigs_lock:
        snapshot = {}
        for rig_name, info in rigs.items():
            info_copy = info.copy()
            if "data" in info_copy:
                info_copy["data"] = info_copy["data"].copy()
            snapshot[rig_name] = info_copy
        with known_rigs_lock:
            for rig_name in known_rigs:
                if rig_name not in snapshot:
                    now = time.time()
                    snapshot[rig_name] = {
                        "timestamp": int(now),
                        "updated": now - OFFLINE_THRESHOLD - 1,
                        "online": False,
                        "data": {
                            "rig": rig_name,
                            "offline": True,
                            "last_seen": now - OFFLINE_THRESHOLD - 1,
                            "last_seen_formatted": time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(now - OFFLINE_THRESHOLD - 1))
                        },
                    }
    return snapshot
async def mqtt_publish(topic: str, payload: dict):
    if _mqtt_client_ref is None:
        log(f"[MQTT] Publish skipped (not connected yet): {topic}")
        return
    try:
        await _mqtt_client_ref.publish(topic, json.dumps(payload), qos=0)
    except Exception as e:
        log(f"[MQTT] Publish error: {e}")
async def mqtt_loop():
    """Async MQTT client task on the main event loop; auto-reconnects with a 3s backoff on error."""
    global _mqtt_client_ref
    log(f"[MQTT] Mode={MQTT_MODE} Connecting to {MQTT_BROKER}:{MQTT_PORT} ...")
    tls_params = None
    if MQTT_MODE == "aws":
        tls_params = aiomqtt.TLSParameters(
            ca_certs=MQTT_CA,
            certfile=MQTT_CERT,
            keyfile=MQTT_KEY,
        )
    keepalive = 30 if MQTT_MODE == "aws" else 60
    while not mqtt_stop.is_set():
        try:
            async with aiomqtt.Client(
                hostname=MQTT_BROKER,
                port=MQTT_PORT,
                identifier=f"rigcontrol-dashboard-{os.getpid()}",
                username=MQTT_USER if MQTT_MODE in ("local", "pi") else None,
                password=MQTT_PASS if MQTT_MODE in ("local", "pi") else None,
                tls_params=tls_params,
                keepalive=keepalive,
            ) as client:
                _mqtt_client_ref = client
                log(f"[MQTT] Connected to {MQTT_BROKER}:{MQTT_PORT}")
                await client.subscribe(MQTT_TOPIC_FILTER, qos=0)
                log(f"[MQTT] Subscribed to {MQTT_TOPIC_FILTER}")
                async for message in client.messages:
                    await handle_mqtt_message(str(message.topic), message.payload)
        except asyncio.CancelledError:
            _mqtt_client_ref = None
            raise
        except aiomqtt.MqttError as e:
            _mqtt_client_ref = None
            log(f"[MQTT] Connection error: {e} \u2014 retrying in 3s")
            await asyncio.sleep(3)
        except Exception as e:
            _mqtt_client_ref = None
            log(f"[MQTT] Unexpected error: {e} \u2014 retrying in 3s")
            await asyncio.sleep(3)
    _mqtt_client_ref = None
    log("[MQTT] Loop stopped")
async def push_cmd_response_to_ws(resp: dict):
    async with clients_lock:
        clients = list(connected_clients)
    if not clients:
        return
    message = {"cmd_response": resp}
    for ws in clients:
        try:
            await ws.send_json(message)
        except:
            pass
async def push_stats_response_to_ws(resp: dict):
    async with clients_lock:
        clients = list(connected_clients)
    if not clients:
        return
    message = {"stats_response": resp}
    for ws in clients:
        try:
            await ws.send_json(message)
        except:
            pass
async def push_stats_response_progress_to_ws(req_id: str, rig: Optional[str], chunk_index: int, chunk_count: int):
    """Sends a "receiving chunk N of M" progress update to the dashboard while a chunked stats response is still arriving."""
    async with clients_lock:
        clients = list(connected_clients)
    if not clients:
        return
    message = {"stats_response_progress": {
        "id": req_id, "rig": rig, "chunk_index": chunk_index, "chunk_count": chunk_count,
    }}
    for ws in clients:
        try:
            await ws.send_json(message)
        except:
            pass
async def handle_stats_response_chunk(data: dict):
    """Reassembles chunked stats_response MQTT messages into one complete response before forwarding to the dashboard."""
    chunk_count = data.get("chunk_count")
    if not chunk_count or chunk_count <= 1:
        await push_stats_response_to_ws(data)
        return
    req_id = data.get("id", "unknown")
    chunk_index = data.get("chunk_index", 0)
    now = time.time()
    async with stats_response_chunk_lock:
        stale_ids = [
            rid for rid, buf in stats_response_chunk_buffers.items()
            if now - buf["first_seen"] > STATS_CHUNK_STALE_SECONDS
        ]
        for rid in stale_ids:
            stale_buf = stats_response_chunk_buffers.pop(rid)
            log(f"[STATS_RESPONSE] Dropping incomplete chunk assembly for {rid}: "
                f"got {len(stale_buf['chunks'])}/{stale_buf['chunk_count']} chunk(s), gave up after {STATS_CHUNK_STALE_SECONDS}s")
        buf = stats_response_chunk_buffers.setdefault(req_id, {
            "chunks": {},
            "chunk_count": chunk_count,
            "first_seen": now,
            "meta": data,
        })
        buf["chunks"][chunk_index] = data.get("entries", [])
        buf["chunk_count"] = chunk_count
        received = len(buf["chunks"])
        total = buf["chunk_count"]
        if received < total:
            log(f"[STATS_RESPONSE] {data.get('rig')} id={req_id} chunk {chunk_index + 1}/{total} received ({received}/{total} so far)")
            await push_stats_response_progress_to_ws(req_id, data.get("rig"), chunk_index, total)
            return
        stats_response_chunk_buffers.pop(req_id, None)
    merged_entries = []
    for idx in range(buf["chunk_count"]):
        merged_entries.extend(buf["chunks"].get(idx, []))
    meta = buf["meta"]
    merged_response = {
        "id": req_id,
        "rig": meta.get("rig"),
        "timestamp": meta.get("timestamp"),
        "days": meta.get("days"),
        "limit": meta.get("limit"),
        "start_date": meta.get("start_date"),
        "count": meta.get("count", len(merged_entries)),
        "entries": merged_entries,
    }
    log(f"[STATS_RESPONSE] {merged_response.get('rig')} id={req_id} all {buf['chunk_count']} chunk(s) received, {len(merged_entries)} entries - forwarding to dashboard")
    await push_stats_response_to_ws(merged_response)
async def push_status_log_event_to_ws(event: dict):
    async with clients_lock:
        clients = list(connected_clients)
    if not clients:
        return
    message = {"status_log_event": event}
    for ws in clients:
        try:
            await ws.send_json(message)
        except:
            pass
async def broadcast_loop():
    log("[Broadcast] Loop started (WS mode: missed refreshes for offline)")
    global last_refresh_ts, last_ws_push, ws_broadcast_pending
    try:
        while not broadcast_stop.is_set():
            now = time.time()
            current_interval = BROADCAST_INTERVAL
            just_refreshed = False
            if now - last_refresh_ts >= current_interval:
                just_refreshed = True
                await mqtt_publish(
                    CMD_ALL_TOPIC,
                    {
                        "id": f"refresh-{int(time.time())}",
                        "command": "refresh",
                        "source": "broadcast",
                        "visible_groups": get_effective_visible_groups()
                    }
                )
                last_refresh_ts = now
                log(f"[MQTT] Refresh requested (interval: {current_interval}s)")
                with known_rigs_lock, rigs_lock, rig_missed_refreshes_lock:
                    for rig_name in list(known_rigs):
                        if rig_name in rigs:
                            last_update = rigs[rig_name].get("updated", 0)
                            misses = rig_missed_refreshes.get(rig_name, 0)
                            if now - last_update > current_interval * 1.5:
                                misses += 1
                                rig_missed_refreshes[rig_name] = misses
                                if misses >= MISSED_REFRESH_THRESHOLD and rigs[rig_name].get("online", True):
                                    rigs[rig_name]["online"] = False
                                    rigs[rig_name]["data"] = {
                                        "rig": rig_name,
                                        "offline": True,
                                        "last_seen": last_update,
                                        "last_seen_formatted": time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(last_update)),
                                        "previously_had_data": True
                                    }
                                    log(f"[Offline WS] {rig_name} marked offline after {misses} missed refreshes")
                            else:
                                rig_missed_refreshes[rig_name] = 0
                        else:
                            rig_missed_refreshes[rig_name] = rig_missed_refreshes.get(rig_name, 0) + 1
                last_ws_push = time.time()
                if not ws_broadcast_pending:
                    ws_broadcast_pending = True
                    asyncio.create_task(_delayed_broadcast(WS_PUSH_MIN_INTERVAL))
            check_offline_rigs_and_notify()
            if not just_refreshed:
                await broadcast_snapshot()
            sleep_remaining = current_interval
            while sleep_remaining > 0 and not broadcast_stop.is_set():
                sleep_chunk = min(1.0, sleep_remaining)
                await asyncio.sleep(sleep_chunk)
                sleep_remaining -= sleep_chunk
    except asyncio.CancelledError:
        log("[Broadcast] Loop cancelled")
    except Exception as e:
        log(f"[Broadcast] Error in loop: {e}")
    finally:
        log("[Broadcast] Loop stopped")
async def run_periodic_maintenance_sweep():
    """Runs one pass of the periodic maintenance sweep, cleaning up stale IP histories, expired tokens, abandoned chunk buffers, and idle DB connections."""
    now = time.time()
    log("[Maintenance Sweep] Starting periodic cleanup pass")
    window_start = now - UNLOCK_ATTEMPTS_WINDOW_SECONDS
    stale_ips = []
    with _unlock_lock:
        for ip, attempts in list(_unlock_attempts_by_ip.items()):
            fresh = [t for t in attempts if t > window_start]
            if fresh:
                _unlock_attempts_by_ip[ip] = fresh
            else:
                stale_ips.append(ip)
        for ip in stale_ips:
            _unlock_attempts_by_ip.pop(ip, None)
    if stale_ips:
        log(f"[Maintenance Sweep] Removed {len(stale_ips)} stale unlock-attempt IP entries")
    expired_tokens = [tok for tok, exp in list(_unlock_tokens.items()) if exp <= now]
    for tok in expired_tokens:
        _unlock_tokens.pop(tok, None)
    if expired_tokens:
        log(f"[Maintenance Sweep] Removed {len(expired_tokens)} expired unlock token(s)")
    stale_chunk_ids = []
    async with stats_response_chunk_lock:
        stale_chunk_ids = [
            rid for rid, buf in stats_response_chunk_buffers.items()
            if now - buf["first_seen"] > STATS_CHUNK_STALE_SECONDS
        ]
        for rid in stale_chunk_ids:
            stale_buf = stats_response_chunk_buffers.pop(rid)
            log(f"[Maintenance Sweep] Dropped abandoned stats chunk buffer {rid}: "
                f"got {len(stale_buf['chunks'])}/{stale_buf['chunk_count']} chunk(s)")
    total_closed = 0
    for db in (local_flightsheet_db, local_overclock_db, local_saved_command_db,
               local_watchdog_profile_db, local_status_log_db, local_wallet_db):
        total_closed += await asyncio.to_thread(db._conns.sweep_idle, DB_CONNECTION_IDLE_TIMEOUT_SECONDS)
    log(f"[Maintenance Sweep] Pass complete (stale_ips={len(stale_ips)}, "
        f"expired_tokens={len(expired_tokens)}, stale_chunk_buffers={len(stale_chunk_ids)}, "
        f"idle_connections_closed={total_closed})")
async def maintenance_sweep_loop():
    """Dedicated always-on loop that calls run_periodic_maintenance_sweep() on its own schedule, independent of dashboard client connections."""
    log("[Maintenance Sweep] Loop started")
    global _last_periodic_sweep_ts
    try:
        while not maintenance_sweep_stop.is_set():
            now = time.time()
            if now - _last_periodic_sweep_ts >= PERIODIC_SWEEP_INTERVAL_SECONDS:
                _last_periodic_sweep_ts = now
                try:
                    await run_periodic_maintenance_sweep()
                except Exception as e:
                    log(f"[Maintenance Sweep] Error during sweep: {e}")
            await asyncio.sleep(1.0)
    except asyncio.CancelledError:
        log("[Maintenance Sweep] Loop cancelled")
    except Exception as e:
        log(f"[Maintenance Sweep] Error in loop: {e}")
    finally:
        log("[Maintenance Sweep] Loop stopped")
async def offline_ping_loop():
    log(f"[Offline Ping] Loop started (Offline mode: time-based offline with threshold {OFFLINE_THRESHOLD}s)")
    global last_offline_ping_ts
    try:
        while not offline_ping_stop.is_set():
            now = time.time()
            current_interval = OFFLINE_PING_INTERVAL
            async with clients_lock:
                has_clients = len(connected_clients) > 0
            if not has_clients and now - last_offline_ping_ts >= current_interval:
                await mqtt_publish(
                    CHECK_ALL_TOPIC,
                    {
                        "id": f"offline-ping-{int(time.time())}",
                        "source": "offline_ping",
                        "want_docker": docker_notifications_enabled()
                    }
                )
                last_offline_ping_ts = now
                log("[Offline Ping] Sent lightweight check to all rigs")
                with known_rigs_lock, rigs_lock:
                    for rig_name in list(known_rigs):
                        if rig_name in rigs:
                            last_update = rigs[rig_name].get("updated", 0)
                            time_offline = now - last_update
                            if time_offline > OFFLINE_THRESHOLD and rigs[rig_name].get("online", True):
                                rigs[rig_name]["online"] = False
                                rigs[rig_name]["data"] = {
                                    "rig": rig_name,
                                    "offline": True,
                                    "last_seen": last_update,
                                    "last_seen_formatted": time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(last_update)),
                                    "previously_had_data": True
                                }
                                log(f"[Offline Ping] {rig_name} marked offline after {int(time_offline)}s > threshold")
            check_offline_rigs_and_notify()
            await asyncio.sleep(1.0)
    except asyncio.CancelledError:
        log("[Offline Ping] Loop cancelled")
    except Exception as e:
        log(f"[Offline Ping] Error in loop: {e}")
    finally:
        log("[Offline Ping] Loop stopped")
def request_broadcast():
    global last_ws_push, ws_broadcast_pending
    now = time.time()
    elapsed = now - last_ws_push
    if elapsed >= WS_PUSH_MIN_INTERVAL:
        last_ws_push = now
        asyncio.create_task(broadcast_snapshot())
        return
    if not ws_broadcast_pending:
        ws_broadcast_pending = True
        delay = WS_PUSH_MIN_INTERVAL - elapsed
        asyncio.create_task(_delayed_broadcast(delay))
async def _delayed_broadcast(delay: float):
    global ws_broadcast_pending
    try:
        await asyncio.sleep(delay)
        await broadcast_snapshot()
    finally:
        ws_broadcast_pending = False
async def broadcast_snapshot():
    global last_ws_push
    snapshot = build_current_snapshot()
    last_ws_push = time.time()
    async with clients_lock:
        disconnected = []
        for ws in connected_clients[:]:
            try:
                await ws.send_json({"rigs": snapshot})
            except (WebSocketDisconnect, RuntimeError, ConnectionResetError) as e:
                log(f"[WS] Client disconnected during send: {e}")
                disconnected.append(ws)
            except Exception as e:
                log(f"[WS] Unexpected error sending to client: {e}")
                disconnected.append(ws)
        for ws in disconnected:
            if ws in connected_clients:
                connected_clients.remove(ws)
        if disconnected:
            log(f"[WS] Removed {len(disconnected)} disconnected clients")
    log(f"[WS Broadcast] Sent snapshot of {len(snapshot)} rig(s) to {len(connected_clients)} client(s)")
@router.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    global ws_connection_count, broadcast_task, broadcast_stop, offline_ping_task, offline_ping_stop, last_refresh_ts
    if ws_connection_count >= MAX_WS_CONNECTIONS:
        await websocket.close(code=1008)
        log(f"[WS] Connection rejected - max connections reached ({MAX_WS_CONNECTIONS})")
        return
    await websocket.accept()
    ws_connection_count += 1
    async with clients_lock:
        connected_clients.append(websocket)
        first_client = len(connected_clients) == 1
    log(f"[WS] Client connected (total: {len(connected_clients)})")
    if first_client:
        if broadcast_stop is None or broadcast_stop.is_set():
            broadcast_stop = asyncio.Event()
        if broadcast_task and not broadcast_task.done():
            broadcast_task.cancel()
            try:
                await broadcast_task
            except asyncio.CancelledError:
                pass
        broadcast_task = asyncio.create_task(broadcast_loop())
        log("[Broadcast] Loop started (first client)")
        await mqtt_publish(
            CMD_ALL_TOPIC,
            {
                "id": f"refresh-{int(time.time())}",
                "command": "refresh",
                "source": "ws_first_client",
                "visible_groups": get_effective_visible_groups()
            }
        )
        last_refresh_ts = time.time()
        log("[MQTT] Refresh requested (first WS client)")
        if offline_ping_task and not offline_ping_task.done():
            if offline_ping_stop:
                offline_ping_stop.set()
            try:
                await asyncio.wait_for(offline_ping_task, timeout=2.0)
            except (asyncio.TimeoutError, asyncio.CancelledError):
                offline_ping_task.cancel()
                try:
                    await offline_ping_task
                except:
                    pass
        with rig_missed_refreshes_lock:
            rig_missed_refreshes.clear()
    try:
        await websocket.send_json({"rigs": build_current_snapshot()})
        log("[WS] Sent initial snapshot")
    except Exception as e:
        log(f"[WS] Error sending initial snapshot: {e}")
    try:
        while True:
            try:
                message = await websocket.receive_text()
                log(f"[WS] Received unexpected message: {message}")
            except WebSocketDisconnect:
                log("[WS] Client disconnected (receive detected)")
                break
            except Exception as e:
                log(f"[WS] Error receiving: {e}")
                break
    except Exception as e:
        log(f"[WS] Outer exception: {e}")
    finally:
        ws_connection_count = max(0, ws_connection_count - 1)
        async with clients_lock:
            if websocket in connected_clients:
                connected_clients.remove(websocket)
            last_client = len(connected_clients) == 0
        log(f"[WS] Client removed (remaining: {len(connected_clients)})")
        if last_client:
            if broadcast_stop:
                broadcast_stop.set()
            if broadcast_task and not broadcast_task.done():
                try:
                    await asyncio.wait_for(broadcast_task, timeout=2.0)
                except (asyncio.TimeoutError, asyncio.CancelledError):
                    broadcast_task.cancel()
                    try:
                        await broadcast_task
                    except:
                        pass
            broadcast_task = None
            with rig_missed_refreshes_lock:
                rig_missed_refreshes.clear()
            if any_notification_channel_enabled():
                if offline_ping_stop is None or offline_ping_stop.is_set():
                    offline_ping_stop = asyncio.Event()
                offline_ping_task = asyncio.create_task(offline_ping_loop())
                log("[Offline Ping] Loop started (no WS clients, notifications enabled)")
            else:
                log("[Offline Ping] Skipping start - notifications disabled")
@router.get("/")
def serve_root():
    index = STATIC_DIR / "index.html"
    if not index.exists():
        return {"error": "static/index.html missing in container"}
    return FileResponse(index, headers={
        "Cache-Control": "no-cache, no-store, must-revalidate",
        "Pragma": "no-cache",
        "Expires": "0",
    })
@router.get("/rigs")
def get_rigs():
    with rigs_lock:
        snapshot = dict(rigs)
    return {"rigs": snapshot}
@router.post("/refresh")
async def refresh_all():
    await mqtt_publish(
        CMD_ALL_TOPIC,
        {
            "id": f"refresh-{int(time.time())}",
            "command": "refresh",
            "source": "manual",
            "visible_groups": get_effective_visible_groups()
        }
    )
    return {"status": "refresh sent"}
@router.post("/reset")
async def reset_known_rigs():
    global last_refresh_ts
    last_refresh_ts = time.time()
    with known_rigs_lock, rigs_lock, rig_online_status_lock, rig_offline_notifications_lock:
        known_rigs.clear()
        rigs.clear()
        rig_online_status.clear()
        rig_offline_notifications.clear()
    await mqtt_publish(
        CMD_ALL_TOPIC,
        {
            "id": f"refresh-{int(time.time())}",
            "command": "refresh",
            "source": "reset",
            "visible_groups": get_effective_visible_groups()
        }
    )
    log("[Reset] Cleared known rigs, telemetry, and online status (user request)")
    return {"status": "reset complete"}
@router.post("/command")
async def send_command(payload: dict):
    rigs_list = payload.get("rigs", [])
    command = payload.get("command")
    if not command or not rigs_list:
        return {"error": "missing rigs or command"}
    cmd_id = f"cmd-{int(time.time())}"
    msg = {"id": cmd_id, "command": command}
    for rig in rigs_list:
        topic = f"rigcontrol/{rig}/cmd"
        await mqtt_publish(topic, msg)
        log(f"[CMD] Sent command to {rig}: {command!r}")
    return {
        "status": "sent",
        "id": cmd_id,
        "rigs": rigs_list
    }
@router.post("/api/stats/request")
async def request_stats_history(payload: dict):
    rig = payload.get("rig")
    req_id = payload.get("id")
    days = payload.get("days", 1)
    limit = payload.get("limit")
    start_date = payload.get("start_date")
    if not rig or not req_id:
        raise HTTPException(status_code=400, detail="missing rig or id")
    try:
        days = int(days)
        if days < 1:
            days = 1
    except (TypeError, ValueError):
        days = 1
    if start_date is not None:
        try:
            datetime.fromisoformat(str(start_date).replace("Z", "+00:00"))
        except (TypeError, ValueError):
            log(f"[STATS_REQUEST] Ignoring invalid start_date from client: {start_date!r}")
            start_date = None
    msg = {"id": req_id, "days": days}
    if limit is not None:
        msg["limit"] = limit
    if start_date:
        msg["start_date"] = start_date
    topic = f"rigcontrol/{rig}/stats_request"
    await mqtt_publish(topic, msg)
    log(f"[STATS_REQUEST] Sent to {rig}: days={days} limit={limit} start_date={start_date} id={req_id}")
    return {"status": "sent", "id": req_id, "rig": rig, "days": days, "start_date": start_date}
@router.post("/api/stats/control")
async def stats_control_for_rigs(payload: dict):
    rigs_list = payload.get("rigs", [])
    if not rigs_list:
        raise HTTPException(status_code=400, detail="missing rigs")
    msg = {}
    if "enabled" in payload and payload.get("enabled") is not None:
        msg["enabled"] = bool(payload.get("enabled"))
    if "interval_seconds" in payload and payload.get("interval_seconds") is not None:
        try:
            secs = int(payload.get("interval_seconds"))
            if secs >= 5:
                msg["interval_seconds"] = secs
        except (TypeError, ValueError):
            pass
    if "max_history_days" in payload and payload.get("max_history_days") is not None:
        try:
            days = int(payload.get("max_history_days"))
            if days >= 1:
                msg["max_history_days"] = days
        except (TypeError, ValueError):
            pass
    if not msg:
        raise HTTPException(status_code=400, detail="no valid settings provided")
    for rig in rigs_list:
        topic = f"rigcontrol/{rig}/stats_control"
        await mqtt_publish(topic, msg)
    log(f"[STATS_CONTROL] Sent to {len(rigs_list)} rig(s) {rigs_list}: {msg}")
    return {"status": "sent", "rigs": rigs_list, "settings": msg}
@router.get("/api/flightsheets")
def get_flightsheets():
    if USE_AWS_DB:
        if not flightsheets_table:
            log(f"[FS GET AWS] DynamoDB table not available")
            return []
        try:
            resp = flightsheets_table.scan()
            items = resp.get("Items", [])
            log(f"[FS GET AWS] Returning {len(items)} flightsheet items")
            return items
        except Exception as e:
            log(f"[FS GET AWS ERROR] Exception: {e}")
            return []
    else:
        try:
            resp = local_flightsheet_db.scan()
            items = resp.get("Items", [])
            log(f"[FS GET LOCAL] Returning {len(items)} flightsheet items")
            return items
        except Exception as e:
            log(f"[FS GET LOCAL ERROR] Exception: {e}")
            return []
@router.put("/api/flightsheets/{flightsheet_id}")
def put_flightsheet(flightsheet_id: str, payload: FlightSheetPutIn):
    log(f"[FS PUT] Saving flightsheet: {flightsheet_id}")
    now = int(time.time())
    if USE_AWS_DB:
        if not flightsheets_table:
            raise HTTPException(503, "AWS Flightsheets table not available")
        deleted = delete_flightsheet_if_exists(flightsheet_id)
        inserted = 0
        with flightsheets_table.batch_writer() as batch:
            for e in payload.entries:
                item = {
                    "FlightsheetId": flightsheet_id,
                    "GpuId": int(e.gpu),
                    "Key": e.key.strip().upper(),
                    "Value": e.value,
                    "UpdatedAt": now,
                }
                batch.put_item(Item=item)
                inserted += 1
        log(f"[FS PUT AWS] Saved {inserted} entries for flightsheet {flightsheet_id}")
        try:
            local_deleted, local_inserted = local_flightsheet_db.put_flightsheet(
                flightsheet_id, payload.entries, now
            )
            log(f"[FS PUT LOCAL BACKUP] Also saved {local_inserted} entries locally")
        except Exception as e:
            log(f"[FS PUT LOCAL BACKUP ERROR] {e}")
    else:
        try:
            deleted, inserted = local_flightsheet_db.put_flightsheet(
                flightsheet_id, payload.entries, now
            )
            log(f"[FS PUT LOCAL] Saved {inserted} entries for flightsheet {flightsheet_id}")
        except Exception as e:
            log(f"[FS PUT LOCAL ERROR] Exception: {e}")
            raise HTTPException(500, f"Failed to save flightsheet: {e}")
    return {
        "status": "ok",
        "deleted": deleted if 'deleted' in locals() else 0,
        "inserted": inserted if 'inserted' in locals() else 0,
    }
@router.delete("/api/flightsheets/{flightsheet_id}")
def delete_flightsheet(flightsheet_id: str):
    log(f"[FS DELETE] Deleting flightsheet: {flightsheet_id}")
    if USE_AWS_DB:
        if not flightsheets_table:
            raise HTTPException(503, "AWS Flightsheets table not available")
        try:
            deleted = delete_flightsheet_if_exists(flightsheet_id)
            try:
                local_deleted = local_flightsheet_db.delete_flightsheet(flightsheet_id)
                log(f"[FS DELETE LOCAL CLEANUP] Also deleted {local_deleted} entries from local DB")
            except Exception as e:
                log(f"[FS DELETE LOCAL CLEANUP ERROR] {e}")
            log(f"[FS DELETE AWS] Deleted {deleted} entries for flightsheet {flightsheet_id}")
            return {
                "status": "deleted",
                "flightsheet_id": flightsheet_id,
                "deleted_count": deleted
            }
        except Exception as e:
            log(f"[FS DELETE AWS ERROR] Error: {e}")
            raise HTTPException(500, f"Failed to delete flightsheet: {e}")
    else:
        try:
            deleted = local_flightsheet_db.delete_flightsheet(flightsheet_id)
            log(f"[FS DELETE LOCAL] Deleted {deleted} entries for flightsheet {flightsheet_id}")
            return {
                "status": "deleted",
                "flightsheet_id": flightsheet_id,
                "deleted_count": deleted
            }
        except Exception as e:
            log(f"[FS DELETE LOCAL ERROR] Error: {e}")
            raise HTTPException(500, f"Failed to delete flightsheet: {e}")
@router.get("/api/overclocks")
def get_overclocks():
    try:
        resp = local_overclock_db.scan()
        items = resp.get("Items", [])
        log(f"[OC GET LOCAL] Returning {len(items)} overclock items")
        return items
    except Exception as e:
        log(f"[OC GET LOCAL ERROR] Exception: {e}")
        return []
@router.put("/api/overclocks/{overclock_id}")
def put_overclock(overclock_id: str, payload: OverclockPutIn):
    log(f"[OC PUT] Saving overclock: {overclock_id}")
    now = int(time.time())
    try:
        deleted, inserted = local_overclock_db.put_overclock(
            overclock_id, payload.entries, now
        )
        log(f"[OC PUT LOCAL] Saved {inserted} entries for overclock {overclock_id}")
    except Exception as e:
        log(f"[OC PUT LOCAL ERROR] Exception: {e}")
        raise HTTPException(500, f"Failed to save overclock: {e}")
    return {
        "status": "ok",
        "deleted": deleted,
        "inserted": inserted,
    }
@router.delete("/api/overclocks/{overclock_id}")
def delete_overclock(overclock_id: str):
    log(f"[OC DELETE] Deleting overclock: {overclock_id}")
    try:
        deleted = local_overclock_db.delete_overclock(overclock_id)
        log(f"[OC DELETE LOCAL] Deleted {deleted} entries for overclock {overclock_id}")
        return {
            "status": "deleted",
            "overclock_id": overclock_id,
            "deleted_count": deleted
        }
    except Exception as e:
        log(f"[OC DELETE LOCAL ERROR] Error: {e}")
        raise HTTPException(500, f"Failed to delete overclock: {e}")
@router.get("/api/saved-commands")
def get_saved_commands():
    try:
        resp = local_saved_command_db.scan()
        items = resp.get("Items", [])
        log(f"[CMD GET LOCAL] Returning {len(items)} saved command items")
        return items
    except Exception as e:
        log(f"[CMD GET LOCAL ERROR] Exception: {e}")
        return []
@router.put("/api/saved-commands/{command_id}")
def put_saved_command(command_id: str, payload: SavedCommandPutIn):
    log(f"[CMD PUT] Saving command: {command_id}")
    now = int(time.time())
    try:
        deleted, inserted = local_saved_command_db.put_command(command_id, payload.entries, now)
        log(f"[CMD PUT LOCAL] Saved {inserted} entries for command {command_id}")
    except Exception as e:
        log(f"[CMD PUT LOCAL ERROR] Exception: {e}")
        raise HTTPException(500, f"Failed to save command: {e}")
    return {
        "status": "ok",
        "deleted": deleted,
        "inserted": inserted,
    }
@router.delete("/api/saved-commands/{command_id}")
def delete_saved_command(command_id: str):
    log(f"[CMD DELETE] Deleting command: {command_id}")
    try:
        deleted = local_saved_command_db.delete_command(command_id)
        log(f"[CMD DELETE LOCAL] Deleted {deleted} entries for command {command_id}")
        return {
            "status": "deleted",
            "command_id": command_id,
            "deleted_count": deleted
        }
    except Exception as e:
        log(f"[CMD DELETE LOCAL ERROR] Error: {e}")
        raise HTTPException(500, f"Failed to delete command: {e}")
@router.get("/api/wallets")
def get_wallets():
    try:
        resp = local_wallet_db.scan()
        items = resp.get("Items", [])
        log(f"[Wallet GET LOCAL] Returning {len(items)} wallet items")
        return items
    except Exception as e:
        log(f"[Wallet GET LOCAL ERROR] Exception: {e}")
        return []
@router.put("/api/wallets/{wallet_id}")
def put_wallet(wallet_id: str, payload: WalletPutIn):
    log(f"[Wallet PUT] Saving wallet: {wallet_id}")
    now = int(time.time())
    try:
        deleted, inserted = local_wallet_db.put_wallet(
            wallet_id, payload.entries, now
        )
        log(f"[Wallet PUT LOCAL] Saved {inserted} entries for wallet {wallet_id}")
    except Exception as e:
        log(f"[Wallet PUT LOCAL ERROR] Exception: {e}")
        raise HTTPException(500, f"Failed to save wallet: {e}")
    return {
        "status": "ok",
        "deleted": deleted,
        "inserted": inserted,
    }
@router.delete("/api/wallets/{wallet_id}")
def delete_wallet(wallet_id: str):
    log(f"[Wallet DELETE] Deleting wallet: {wallet_id}")
    try:
        deleted = local_wallet_db.delete_wallet(wallet_id)
        log(f"[Wallet DELETE LOCAL] Deleted {deleted} entries for wallet {wallet_id}")
        return {
            "status": "deleted",
            "wallet_id": wallet_id,
            "deleted_count": deleted
        }
    except Exception as e:
        log(f"[Wallet DELETE LOCAL ERROR] Error: {e}")
        raise HTTPException(500, f"Failed to delete wallet: {e}")
@router.get("/api/watchdog-profiles")
def get_watchdog_profiles():
    try:
        resp = local_watchdog_profile_db.scan()
        items = resp.get("Items", [])
        log(f"[WD GET LOCAL] Returning {len(items)} watchdog profile items")
        return items
    except Exception as e:
        log(f"[WD GET LOCAL ERROR] Exception: {e}")
        return []
@router.put("/api/watchdog-profiles/{profile_id}")
def put_watchdog_profile(profile_id: str, payload: WatchdogProfilePutIn):
    log(f"[WD PUT] Saving watchdog profile: {profile_id}")
    now = int(time.time())
    try:
        deleted, inserted = local_watchdog_profile_db.put_profile(
            profile_id, payload.entries, now
        )
        log(f"[WD PUT LOCAL] Saved {inserted} entries for watchdog profile {profile_id}")
    except Exception as e:
        log(f"[WD PUT LOCAL ERROR] Exception: {e}")
        raise HTTPException(500, f"Failed to save watchdog profile: {e}")
    return {
        "status": "ok",
        "deleted": deleted,
        "inserted": inserted,
    }
@router.delete("/api/watchdog-profiles/{profile_id}")
def delete_watchdog_profile(profile_id: str):
    log(f"[WD DELETE] Deleting watchdog profile: {profile_id}")
    try:
        deleted = local_watchdog_profile_db.delete_profile(profile_id)
        log(f"[WD DELETE LOCAL] Deleted {deleted} entries for watchdog profile {profile_id}")
        return {
            "status": "deleted",
            "profile_id": profile_id,
            "deleted_count": deleted
        }
    except Exception as e:
        log(f"[WD DELETE LOCAL ERROR] Error: {e}")
        raise HTTPException(500, f"Failed to delete watchdog profile: {e}")
@router.get("/api/status-log")
def get_status_log(rig: Optional[str] = None, limit: int = 200, title_q: Optional[str] = None, content_q: Optional[str] = None):
    try:
        items = local_status_log_db.list_events(rig=rig or None, limit=limit, title_q=title_q or None, content_q=content_q or None)
        return items
    except Exception as e:
        log(f"[STATUSLOG GET ERROR] Exception: {e}")
        return []
@router.get("/api/status-log/{event_id}")
def get_status_log_entry(event_id: int):
    try:
        entry = local_status_log_db.get_event(event_id)
        if entry is None:
            raise HTTPException(404, f"Status log entry {event_id} not found")
        return entry
    except HTTPException:
        raise
    except Exception as e:
        log(f"[STATUSLOG GET ENTRY ERROR] Exception: {e}")
        raise HTTPException(500, f"Failed to load status log entry: {e}")
@router.delete("/api/status-log")
def delete_status_log_entries(ids: str):
    try:
        id_list = [int(x) for x in ids.split(",") if x.strip()]
    except ValueError:
        raise HTTPException(400, "ids must be a comma-separated list of integers")
    if not id_list:
        raise HTTPException(400, "No ids provided")
    try:
        deleted = local_status_log_db.delete_events(id_list)
        log(f"[STATUSLOG DELETE] Deleted {deleted}/{len(id_list)} requested entries")
        return {"status": "deleted", "deleted_count": deleted, "requested_count": len(id_list)}
    except Exception as e:
        log(f"[STATUSLOG DELETE ERROR] Exception: {e}")
        raise HTTPException(500, f"Failed to delete status log entries: {e}")
@router.post("/api/set-interval")
async def set_refresh_interval(payload: dict):
    global BROADCAST_INTERVAL
    interval_seconds = payload.get("interval_seconds")
    if not isinstance(interval_seconds, (int, float)):
        raise HTTPException(
            status_code=400,
            detail="interval_seconds must be a number"
        )
    if interval_seconds < 1 or interval_seconds > 3600:
        raise HTTPException(
            status_code=400,
            detail="interval_seconds must be between 1 and 3600 seconds"
        )
    old_interval = BROADCAST_INTERVAL
    BROADCAST_INTERVAL = float(interval_seconds)
    os.environ["BROADCAST_INTERVAL"] = str(interval_seconds)
    log(f"[Interval] Changed broadcast interval from {old_interval}s to {BROADCAST_INTERVAL}s")
    save_all_settings()
    async with clients_lock:
        clients = list(connected_clients)
    if clients:
        message = {
            "interval_changed": True,
            "old_interval": old_interval,
            "new_interval": BROADCAST_INTERVAL,
            "timestamp": time.time()
        }
        for ws in clients:
            try:
                await ws.send_json(message)
            except:
                pass
    return {
        "status": "success",
        "old_interval": old_interval,
        "new_interval": BROADCAST_INTERVAL,
        "message": f"Refresh interval set to {BROADCAST_INTERVAL} seconds"
    }
@router.post("/api/save-interval")
async def save_refresh_interval(payload: dict):
    interval_seconds = payload.get("interval_seconds")
    if not isinstance(interval_seconds, (int, float)):
        raise HTTPException(
            status_code=400,
            detail="interval_seconds must be a number"
        )
    if interval_seconds < 1 or interval_seconds > 3600:
        raise HTTPException(
            status_code=400,
            detail="interval_seconds must be between 1 and 3600 seconds"
        )
    try:
        env_file = BASE_DIR / ".env"
        env_lines = []
        if env_file.exists():
            with open(env_file, "r") as f:
                env_lines = f.readlines()
        found = False
        for i, line in enumerate(env_lines):
            if line.strip().startswith("BROADCAST_INTERVAL="):
                env_lines[i] = f"BROADCAST_INTERVAL={interval_seconds}\n"
                found = True
                break
        if not found:
            env_lines.append(f"BROADCAST_INTERVAL={interval_seconds}\n")
        with open(env_file, "w") as f:
            f.writelines(env_lines)
        log(f"[Interval] Saved interval {interval_seconds}s to {env_file}")
        save_all_settings()
        return {
            "status": "success",
            "message": f"Interval {interval_seconds}s saved to config file",
            "config_file": str(env_file)
        }
    except Exception as e:
        log(f"[Interval] Failed to save interval to file: {e}")
        raise HTTPException(
            status_code=500,
            detail=f"Failed to save interval to config file: {str(e)}"
        )
@router.post("/api/set-offline-ping-interval")
async def set_offline_ping_interval(payload: dict):
    global OFFLINE_PING_INTERVAL
    interval_seconds = payload.get("interval_seconds")
    if not isinstance(interval_seconds, (int, float)):
        raise HTTPException(
            status_code=400,
            detail="interval_seconds must be a number"
        )
    if interval_seconds < 10 or interval_seconds > 86400:
        raise HTTPException(
            status_code=400,
            detail="interval_seconds must be between 10 (10 sec) and 86400 (24 hours) seconds"
        )
    old_interval = OFFLINE_PING_INTERVAL
    OFFLINE_PING_INTERVAL = float(interval_seconds)
    os.environ["OFFLINE_PING_INTERVAL"] = str(interval_seconds)
    log(f"[Offline Ping] Changed interval from {old_interval}s to {OFFLINE_PING_INTERVAL}s")
    save_all_settings()
    async with clients_lock:
        clients = list(connected_clients)
    if clients:
        message = {
            "offline_ping_interval_changed": True,
            "old_interval": old_interval,
            "new_interval": OFFLINE_PING_INTERVAL,
            "timestamp": time.time()
        }
        for ws in clients:
            try:
                await ws.send_json(message)
            except:
                pass
    return {
        "status": "success",
        "old_interval": old_interval,
        "new_interval": OFFLINE_PING_INTERVAL,
        "message": f"Offline ping interval set to {OFFLINE_PING_INTERVAL} seconds"
    }
@router.post("/api/save-offline-ping-interval")
async def save_offline_ping_interval(payload: dict):
    interval_seconds = payload.get("interval_seconds")
    if not isinstance(interval_seconds, (int, float)):
        raise HTTPException(
            status_code=400,
            detail="interval_seconds must be a number"
        )
    if interval_seconds < 10 or interval_seconds > 86400:
        raise HTTPException(
            status_code=400,
            detail="interval_seconds must be between 10 (10 sec) and 86400 (24 hours) seconds"
        )
    try:
        env_file = BASE_DIR / ".env"
        env_lines = []
        if env_file.exists():
            with open(env_file, "r") as f:
                env_lines = f.readlines()
        found = False
        for i, line in enumerate(env_lines):
            if line.strip().startswith("OFFLINE_PING_INTERVAL="):
                env_lines[i] = f"OFFLINE_PING_INTERVAL={interval_seconds}\n"
                found = True
                break
        if not found:
            env_lines.append(f"OFFLINE_PING_INTERVAL={interval_seconds}\n")
        with open(env_file, "w") as f:
            f.writelines(env_lines)
        log(f"[Offline Ping] Saved interval {interval_seconds}s to {env_file}")
        save_all_settings()
        return {
            "status": "success",
            "message": f"Offline ping interval {interval_seconds}s saved to config file",
            "config_file": str(env_file)
        }
    except Exception as e:
        log(f"[Offline Ping] Failed to save interval to file: {e}")
        raise HTTPException(
            status_code=500,
            detail=f"Failed to save interval to config file: {str(e)}"
        )
@router.post("/api/trigger-offline-ping")
async def trigger_offline_ping(payload: dict = None):
    global last_offline_ping_ts
    log(f"[Offline Ping] Manually triggered refresh ping")
    await mqtt_publish(
        CHECK_ALL_TOPIC,
        {
            "id": f"manual-offline-ping-{int(time.time())}",
            "source": "manual_offline_ping",
            "want_docker": docker_notifications_enabled()
        }
    )
    last_offline_ping_ts = time.time()
    return {
        "status": "success",
        "message": "Sent manual liveness check to all rigs"
    }
@router.post("/api/set-offline-threshold")
async def set_offline_threshold(payload: dict):
    global OFFLINE_THRESHOLD
    threshold_seconds = payload.get("threshold_seconds")
    if not isinstance(threshold_seconds, (int, float)):
        raise HTTPException(
            status_code=400,
            detail="threshold_seconds must be a number"
        )
    if threshold_seconds < 30 or threshold_seconds > 86400:
        raise HTTPException(
            status_code=400,
            detail="threshold_seconds must be between 30 (30 sec) and 86400 (24 hours) seconds"
        )
    old_threshold = OFFLINE_THRESHOLD
    OFFLINE_THRESHOLD = float(threshold_seconds)
    os.environ["OFFLINE_THRESHOLD"] = str(threshold_seconds)
    log(f"[Offline Threshold] Changed from {old_threshold}s to {OFFLINE_THRESHOLD}s")
    save_all_settings()
    async with clients_lock:
        clients = list(connected_clients)
    if clients:
        message = {
            "offline_threshold_changed": True,
            "old_threshold": old_threshold,
            "new_threshold": OFFLINE_THRESHOLD,
            "timestamp": time.time()
        }
        for ws in clients:
            try:
                await ws.send_json(message)
            except:
                pass
    return {
        "status": "success",
        "old_threshold": old_threshold,
        "new_threshold": OFFLINE_THRESHOLD,
        "message": f"Offline notification threshold set to {OFFLINE_THRESHOLD} seconds"
    }
@router.post("/api/save-offline-threshold")
async def save_offline_threshold(payload: dict):
    threshold_seconds = payload.get("threshold_seconds")
    if not isinstance(threshold_seconds, (int, float)):
        raise HTTPException(
            status_code=400,
            detail="threshold_seconds must be a number"
        )
    if threshold_seconds < 30 or threshold_seconds > 86400:
        raise HTTPException(
            status_code=400,
            detail="threshold_seconds must be between 30 (30 sec) and 86400 (24 hours) seconds"
        )
    try:
        env_file = BASE_DIR / ".env"
        env_lines = []
        if env_file.exists():
            with open(env_file, "r") as f:
                env_lines = f.readlines()
        found = False
        for i, line in enumerate(env_lines):
            if line.strip().startswith("OFFLINE_THRESHOLD="):
                env_lines[i] = f"OFFLINE_THRESHOLD={threshold_seconds}\n"
                found = True
                break
        if not found:
            env_lines.append(f"OFFLINE_THRESHOLD={threshold_seconds}\n")
        with open(env_file, "w") as f:
            f.writelines(env_lines)
        log(f"[Offline Threshold] Saved threshold {threshold_seconds}s to {env_file}")
        save_all_settings()
        return {
            "status": "success",
            "message": f"Offline threshold {threshold_seconds}s saved to config file",
            "config_file": str(env_file)
        }
    except Exception as e:
        log(f"[Offline Threshold] Failed to save threshold to file: {e}")
        raise HTTPException(
            status_code=500,
            detail=f"Failed to save threshold to config file: {str(e)}"
        )
@router.get("/api/offline-threshold")
async def get_offline_threshold():
    return {
        "offline_threshold": OFFLINE_THRESHOLD,
        "threshold_seconds": OFFLINE_THRESHOLD,
        "threshold_human": f"{int(OFFLINE_THRESHOLD // 3600)}h {int((OFFLINE_THRESHOLD % 3600) // 60)}m"
    }
@router.get("/api/notification-settings")
async def get_notification_settings():
    return notification_settings
@router.post("/api/debug-notification-apply")
async def debug_notification_apply(payload: dict):
    log(f"[Debug] Received notification settings payload: {json.dumps(payload, indent=2)}")
    fields_present = list(payload.keys())
    log(f"[Debug] Fields present in payload: {fields_present}")
    log(f"[Debug] sms_primary_enabled value: {payload.get('sms_primary_enabled', 'NOT PRESENT')}")
    log(f"[Debug] sms_secondary_enabled value: {payload.get('sms_secondary_enabled', 'NOT PRESENT')}")
    log(f"[Debug] sms_primary_number value: {payload.get('sms_primary_number', 'NOT PRESENT')}")
    log(f"[Debug] sms_secondary_number value: {payload.get('sms_secondary_number', 'NOT PRESENT')}")
    return {
        "status": "debug",
        "received_payload": payload,
        "current_settings": notification_settings
    }
@router.post("/api/notification-settings")
async def update_notification_settings(settings: NotificationSettings):
    global notification_settings
    log(f"[Notifications] Received settings: email_enabled={settings.email_enabled}, "
        f"sms_primary_enabled={settings.sms_primary_enabled}, "
        f"sms_secondary_enabled={settings.sms_secondary_enabled}")
    if settings.sms_primary_enabled and not settings.sms_primary_number:
        log("[Notifications] Warning: Primary SMS enabled but no phone number provided")
        settings.sms_primary_enabled = False
    if settings.sms_secondary_enabled and not settings.sms_secondary_number:
        log("[Notifications] Warning: Secondary SMS enabled but no phone number provided")
        settings.sms_secondary_enabled = False
    if settings.sms_primary_number:
        cleaned = ''.join(filter(str.isdigit, settings.sms_primary_number))
        if cleaned != settings.sms_primary_number:
            log(f"[Notifications] Cleaned primary number: {settings.sms_primary_number} -> {cleaned}")
            settings.sms_primary_number = cleaned
    if settings.sms_secondary_number:
        cleaned = ''.join(filter(str.isdigit, settings.sms_secondary_number))
        if cleaned != settings.sms_secondary_number:
            log(f"[Notifications] Cleaned secondary number: {settings.sms_secondary_number} -> {cleaned}")
            settings.sms_secondary_number = cleaned
    try:
        settings_dict = settings.model_dump(exclude_none=True)
    except AttributeError:
        settings_dict = settings.dict(exclude_none=True)
    log(f"[Notifications] Updating with: {json.dumps(settings_dict, indent=2)}")
    notification_settings.update(settings_dict)
    save_all_settings()
    log(f"[Notifications] Settings updated successfully")
    log(f"[Notifications] Current settings: email={notification_settings.get('email_enabled')}, "
        f"sms_primary={notification_settings.get('sms_primary_enabled')} ({notification_settings.get('sms_primary_number')}), "
        f"sms_secondary={notification_settings.get('sms_secondary_enabled')} ({notification_settings.get('sms_secondary_number')})")
    return {
        "status": "success",
        "message": "Notification settings updated",
        "settings": notification_settings
    }
@router.get("/api/notification-status")
async def get_notification_status():
    status = {
        "file_settings": notification_settings,
        "service_initialized": notification_service is not None,
        "twilio_configured": notification_service.twilio_client is not None if notification_service else False,
        "smtp_configured": bool(notification_service.smtp_username and notification_service.smtp_password) if notification_service else False,
        "email_recipient_count": len(notification_service.email_recipient) if notification_service else 0,
        "notification_file_exists": NOTIFICATION_SETTINGS_FILE.exists(),
        "notification_file_path": str(NOTIFICATION_SETTINGS_FILE),
        "environment_variables": {
            "EMAIL_ENABLED": os.getenv("EMAIL_ENABLED"),
            "SMS_PRIMARY_ENABLED": os.getenv("SMS_PRIMARY_ENABLED"),
            "SMS_SECONDARY_ENABLED": os.getenv("SMS_SECONDARY_ENABLED"),
            "TWILIO_ACCOUNT_SID_set": bool(os.getenv("TWILIO_ACCOUNT_SID")),
            "GMAIL_USERNAME_set": bool(os.getenv("GMAIL_USERNAME")),
        }
    }
    return status
@router.post("/api/test-notification")
async def test_notification():
    subject = "RigControl Test Notification"
    message = "This is a test notification from RigControl Dashboard. "
    message += "If you're receiving this, your notification settings are working correctly."
    results = await asyncio.to_thread(
        notification_service.send_notification,
        message=message,
        subject=subject,
        email=notification_settings["email_enabled"],
        sms_primary=notification_settings["sms_primary_enabled"],
        sms_secondary=notification_settings["sms_secondary_enabled"],
        sms_primary_number=notification_settings["sms_primary_number"],
        sms_secondary_number=notification_settings["sms_secondary_number"]
    )
    return {
        "status": "success",
        "message": "Test notification sent",
        "results": results,
        "settings_used": {
            "email_enabled": notification_settings["email_enabled"],
            "sms_primary_enabled": notification_settings["sms_primary_enabled"],
            "sms_secondary_enabled": notification_settings["sms_secondary_enabled"]
        }
    }
@router.post("/api/notifications/on")
async def turn_notifications_on():
    global notification_settings
    email_configured = bool(notification_service.smtp_username and notification_service.smtp_password) if notification_service else False
    notification_settings["email_enabled"] = email_configured
    notification_settings["sms_primary_enabled"] = bool(notification_settings.get("sms_primary_number"))
    notification_settings["sms_secondary_enabled"] = bool(notification_settings.get("sms_secondary_number"))
    save_all_settings()
    enabled_types = []
    if notification_settings["email_enabled"]:
        enabled_types.append("email")
    if notification_settings["sms_primary_enabled"]:
        enabled_types.append("primary SMS")
    if notification_settings["sms_secondary_enabled"]:
        enabled_types.append("secondary SMS")
    enabled_count = len(enabled_types)
    log(f"[Notifications] Turned ON: {enabled_count} type(s) enabled - {', '.join(enabled_types) if enabled_types else 'none (not configured)'}")
    return {
        "status": "success",
        "message": f"Notifications turned ON ({enabled_count} type(s) enabled)",
        "enabled": True,
        "enabled_types": enabled_types,
        "settings": {
            "email_enabled": notification_settings.get("email_enabled"),
            "sms_primary_enabled": notification_settings.get("sms_primary_enabled"),
            "sms_secondary_enabled": notification_settings.get("sms_secondary_enabled")
        }
    }
@router.post("/api/notifications/off")
async def turn_notifications_off():
    global notification_settings
    notification_settings["email_enabled"] = False
    notification_settings["sms_primary_enabled"] = False
    notification_settings["sms_secondary_enabled"] = False
    save_all_settings()
    log(f"[Notifications] Turned OFF: all notifications disabled")
    return {
        "status": "success",
        "message": "Notifications turned OFF",
        "enabled": False,
        "settings": {
            "email_enabled": notification_settings.get("email_enabled"),
            "sms_primary_enabled": notification_settings.get("sms_primary_enabled"),
            "sms_secondary_enabled": notification_settings.get("sms_secondary_enabled")
        }
    }
@router.get("/api/offline-rigs")
async def get_offline_rigs():
    now = time.time()
    offline_rigs = []
    with rigs_lock, known_rigs_lock:
        for rig_name in known_rigs:
            info = rigs.get(rig_name)
            last_update = info.get("updated", 0) if info else 0
            time_offline = now - last_update
            if time_offline > OFFLINE_THRESHOLD:
                hours = int(time_offline // 3600)
                minutes = int((time_offline % 3600) // 60)
                offline_rigs.append({
                    "rig_name": rig_name,
                    "last_seen": last_update,
                    "last_seen_formatted": time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(last_update)),
                    "time_offline_seconds": int(time_offline),
                    "time_offline_human": f"{hours}h {minutes}m",
                    "notification_sent": rig_name in rig_offline_notifications,
                    "last_notification": rig_offline_notifications.get(rig_name, None)
                })
    return {
        "offline_rigs": offline_rigs,
        "count": len(offline_rigs),
        "threshold_seconds": OFFLINE_THRESHOLD
    }
@router.get("/api/quick-actions")
async def get_quick_actions():
    return quick_actions
@router.put("/api/quick-actions")
async def update_quick_actions(payload: QuickActionsIn):
    global quick_actions
    quick_actions = {
        "a": payload.a or "",
        "b": payload.b or "",
        "c": payload.c or ""
    }
    save_all_settings()
    log(f"[Quick Actions] Updated: a={'set' if quick_actions['a'] else 'empty'}, "
        f"b={'set' if quick_actions['b'] else 'empty'}, "
        f"c={'set' if quick_actions['c'] else 'empty'}")
    return {
        "status": "success",
        "message": "Quick actions updated",
        "quick_actions": quick_actions
    }
@router.get("/api/telemetry-columns")
async def get_telemetry_columns():
    return {"visible_groups": telemetry_visible_groups}
@router.put("/api/telemetry-columns")
async def update_telemetry_columns(payload: TelemetryColumnsIn):
    global telemetry_visible_groups
    telemetry_visible_groups = payload.visible_groups
    save_all_settings()
    log(f"[Telemetry Columns] Visible groups updated: "
        f"{telemetry_visible_groups if telemetry_visible_groups is not None else 'ALL (filter cleared)'}")
    return {
        "status": "success",
        "message": "Telemetry column filter updated",
        "visible_groups": telemetry_visible_groups
    }
@asynccontextmanager
async def lifespan(app: FastAPI):
    global mqtt_stop, mqtt_task, broadcast_stop, broadcast_task, broadcast_loop_running
    global offline_ping_stop, offline_ping_task, offline_ping_running, last_offline_ping_ts
    global maintenance_sweep_stop, maintenance_sweep_task
    load_all_settings()
    async with clients_lock:
        connected_clients.clear()
    broadcast_loop_running = False
    broadcast_task = None
    offline_ping_task = None
    offline_ping_running = False
    broadcast_stop = asyncio.Event()
    offline_ping_stop = asyncio.Event()
    last_offline_ping_ts = time.time()
    log("[Startup] Dashboard server starting - state cleaned")
    start_notification_workers()
    maintenance_sweep_stop = asyncio.Event()
    maintenance_sweep_task = asyncio.create_task(maintenance_sweep_loop())
    mqtt_stop = asyncio.Event()
    mqtt_task = asyncio.create_task(mqtt_loop())
    try:
        THEMES_DIR.mkdir(parents=True, exist_ok=True)
        theme_count = len(list(THEMES_DIR.glob("*.json")))
        log(f"[ColorSchemes] Themes folder ready at {THEMES_DIR.resolve()} ({theme_count} json file(s) found)")
    except Exception as e:
        log(f"[ColorSchemes] Could not create/scan {THEMES_DIR}: {e}")
    log(f"[Config] Broadcast interval: {BROADCAST_INTERVAL}s")
    log(f"[Config] Offline ping interval: {OFFLINE_PING_INTERVAL}s ({int(OFFLINE_PING_INTERVAL//3600)}h {int((OFFLINE_PING_INTERVAL%3600)//60)}m)")
    log(f"[Config] Offline threshold: {OFFLINE_THRESHOLD}s ({int(OFFLINE_THRESHOLD//3600)}h {int((OFFLINE_THRESHOLD%3600)//60)}m)")
    log(f"[Config] Email enabled: {notification_settings.get('email_enabled')}")
    log(f"[Config] SMS primary enabled: {notification_settings.get('sms_primary_enabled')}")
    log(f"[Config] SMS secondary enabled: {notification_settings.get('sms_secondary_enabled')}")
    initialize_local_database()
    try:
        oc_resp = local_overclock_db.scan()
        log(f"[LocalDB Init] Overclocks database ready with {len(oc_resp.get('Items', []))} entries")
    except Exception as e:
        log(f"[LocalDB Init] Error checking overclocks database: {e}")
    try:
        wallet_resp = local_wallet_db.scan()
        log(f"[LocalDB Init] Wallets database ready with {len(wallet_resp.get('Items', []))} entries")
    except Exception as e:
        log(f"[LocalDB Init] Error checking wallets database: {e}")
    try:
        wdprofile_resp = local_watchdog_profile_db.scan()
        log(f"[LocalDB Init] Watchdog Profiles database ready with {len(wdprofile_resp.get('Items', []))} entries")
    except Exception as e:
        log(f"[LocalDB Init] Error checking watchdog profiles database: {e}")
    try:
        sl_items = local_status_log_db.list_events(limit=5000)
        log(f"[LocalDB Init] Status Log database ready with {len(sl_items)} entries")
    except Exception as e:
        log(f"[LocalDB Init] Error checking status log database: {e}")
    if any_notification_channel_enabled():
        async with offline_ping_lock:
            offline_ping_stop.clear()
            offline_ping_task = asyncio.create_task(offline_ping_loop())
            offline_ping_running = True
        log("[Offline Ping] Loop started (initial - no clients)")
    else:
        log("[Offline Ping] Skipping start - notifications disabled")
    yield
    log("[Shutdown] Dashboard server stopping")
    stop_notification_workers()
    if maintenance_sweep_stop:
        maintenance_sweep_stop.set()
    if maintenance_sweep_task:
        maintenance_sweep_task.cancel()
        maintenance_sweep_task = None
    if mqtt_stop:
        mqtt_stop.set()
    if mqtt_task:
        mqtt_task.cancel()
        mqtt_task = None
    if broadcast_stop:
        broadcast_stop.set()
    if broadcast_task:
        broadcast_task.cancel()
        broadcast_task = None
    if offline_ping_stop:
        offline_ping_stop.set()
    if offline_ping_task:
        offline_ping_task.cancel()
        offline_ping_task = None
    broadcast_loop_running = False
    offline_ping_running = False
    log("[Shutdown] Closing SQLite connections across all threads...")
    local_flightsheet_db.close_all()
    local_overclock_db.close_all()
    local_saved_command_db.close_all()
    local_watchdog_profile_db.close_all()
    local_status_log_db.close_all()
    local_wallet_db.close_all()
    log("[Shutdown] Dashboard server shutdown complete")
class BackupTargetsIn(BaseModel):
    files: List[str]
    missing_only: bool = False
    source: str = "local"                                                      
@router.get("/api/backups/files")
async def list_backup_files():
    out = []
    for t in BACKUP_TARGETS:
        local_db = t["local_db"]()
        path = local_db.db_path
        try:
            size = path.stat().st_size if path.exists() else 0
        except Exception:
            size = 0
        try:
            count = len(t["scan_fn"]())
        except Exception as e:
            count = None
            log(f"[Backups] Error counting {t['id']}: {e}")
        out.append({
            "id": t["id"],
            "label": t["label"],
            "file_name": t["file_name"],
            "exists": path.exists(),
            "size_bytes": size,
            "item_count": count,
            "dynamo_table": t["dynamo_table"],
        })
    return out
@router.get("/api/backups/preview/{file_id}")
async def preview_backup_file(file_id: str, source: str = "local"):
    target = get_backup_target(file_id)
    if not target:
        raise HTTPException(404, f"Unknown backup file: {file_id}")
    if source == "dynamo":
        if not dynamodb:
            initialize_aws_dynamodb()
        ok, items, error = scan_dynamo_target(target)
        if not ok:
            raise HTTPException(502, error or f"Failed to read {file_id} from DynamoDB")
        return {"id": target["id"], "label": target["label"], "source": "dynamo", "items": items}
    try:
        items = target["scan_fn"]()
        return {"id": target["id"], "label": target["label"], "source": "local", "items": items}
    except Exception as e:
        raise HTTPException(500, f"Failed to read {file_id}: {e}")
@router.get("/api/backups/check-config")
async def backups_check_config():
    return check_backup_config()
@router.post("/api/backups/test-connection")
async def backups_test_connection():
    return test_dynamodb_connection()
@router.post("/api/backups/backup")
async def backups_backup(payload: BackupTargetsIn):
    if not dynamodb:
        initialize_aws_dynamodb()
    results = []
    for file_id in payload.files:
        target = get_backup_target(file_id)
        if not target:
            results.append({"id": file_id, "ok": False, "count": 0, "error": "Unknown backup file"})
            continue
        ok, count, error = backup_target_to_dynamo(target)
        log(f"[Backups] Backup {file_id}: ok={ok} count={count} error={error}")
        results.append({"id": file_id, "ok": ok, "count": count, "error": error})
    return {"results": results}
@router.post("/api/backups/restore")
async def backups_restore(payload: BackupTargetsIn):
    if not dynamodb:
        initialize_aws_dynamodb()
    results = []
    for file_id in payload.files:
        target = get_backup_target(file_id)
        if not target:
            results.append({"id": file_id, "ok": False, "count": 0, "error": "Unknown backup file"})
            continue
        ok, count, error = restore_target_from_dynamo(target, payload.missing_only)
        log(f"[Backups] Restore {file_id}: ok={ok} count={count} error={error} missing_only={payload.missing_only}")
        results.append({"id": file_id, "ok": ok, "count": count, "error": error})
    return {"results": results}
@router.post("/api/backups/delete")
async def backups_delete(payload: BackupTargetsIn):
    if payload.source == "dynamo" and not dynamodb:
        initialize_aws_dynamodb()
    results = []
    for file_id in payload.files:
        target = get_backup_target(file_id)
        if not target:
            results.append({"id": file_id, "ok": False, "error": "Unknown backup file"})
            continue
        if payload.source == "dynamo":
            ok, error = delete_dynamo_target(target)
        else:
            ok, error = delete_local_target(target)
        log(f"[Backups] Delete {file_id} (source={payload.source}): ok={ok} error={error}")
        results.append({"id": file_id, "ok": ok, "error": error})
    return {"results": results}
@router.post("/api/backups/import-accesskeys")
async def import_access_keys(file: UploadFile = File(...)):
    AWS_KEYS_CSV = os.getenv(
        "AWS_KEYS_CSV",
        os.path.join(os.path.dirname(__file__), "accessKeys.csv")
    )
    try:
        contents = await file.read()
        with open(AWS_KEYS_CSV, "wb") as f:
            f.write(contents)
        log(f"[Backups] Saved uploaded accessKeys.csv ({len(contents)} bytes) to {AWS_KEYS_CSV}")
        check = check_backup_config()
        return {"ok": check["ok"], "message": check["message"], "path": AWS_KEYS_CSV}
    except Exception as e:
        log(f"[Backups] Error saving uploaded accessKeys.csv: {e}")
        raise HTTPException(500, f"Failed to save accessKeys.csv: {e}")
@router.get("/sw.js")
async def dashboard_service_worker():
    js = (
        "self.addEventListener('install', () => self.skipWaiting());\n"
        "self.addEventListener('activate', (event) => event.waitUntil(clients.claim()));\n"
        "// Deliberately no 'fetch' listener - everything passes through to network.\n"
    )
    return Response(
        content=js,
        media_type="application/javascript",
        headers={"Cache-Control": "no-cache, no-store, must-revalidate"},
    )
@router.post("/api/set-advanced-server-settings")
async def set_advanced_server_settings(payload: dict):
    global WS_PUSH_MIN_INTERVAL, MISSED_REFRESH_THRESHOLD
    ws_push_min_interval = payload.get("ws_push_min_interval")
    missed_refresh_threshold = payload.get("missed_refresh_threshold")
    if not isinstance(ws_push_min_interval, (int, float)):
        raise HTTPException(status_code=400, detail="ws_push_min_interval must be a number")
    if ws_push_min_interval < 0.1 or ws_push_min_interval > 10:
        raise HTTPException(status_code=400, detail="ws_push_min_interval must be between 0.1 and 10 seconds")
    if not isinstance(missed_refresh_threshold, (int, float)):
        raise HTTPException(status_code=400, detail="missed_refresh_threshold must be a number")
    if missed_refresh_threshold < 1 or missed_refresh_threshold > 10:
        raise HTTPException(status_code=400, detail="missed_refresh_threshold must be between 1 and 10")
    old_ws_push_min_interval = WS_PUSH_MIN_INTERVAL
    old_missed_refresh_threshold = MISSED_REFRESH_THRESHOLD
    WS_PUSH_MIN_INTERVAL = float(ws_push_min_interval)
    MISSED_REFRESH_THRESHOLD = int(missed_refresh_threshold)
    log(f"[Advanced Settings] WS push min interval changed from {old_ws_push_min_interval}s to {WS_PUSH_MIN_INTERVAL}s")
    log(f"[Advanced Settings] Missed refresh threshold changed from {old_missed_refresh_threshold} to {MISSED_REFRESH_THRESHOLD}")
    save_all_settings()
    return {
        "status": "success",
        "ws_push_min_interval": WS_PUSH_MIN_INTERVAL,
        "missed_refresh_threshold": MISSED_REFRESH_THRESHOLD,
        "message": f"WS push min interval set to {WS_PUSH_MIN_INTERVAL}s, missed refresh threshold set to {MISSED_REFRESH_THRESHOLD}"
    }
@router.get("/api/config")
def get_config(request: Request):
    return {
        "basePath": BASE_PATH,
        "broadcast_interval": BROADCAST_INTERVAL,
        "offline_ping_interval": OFFLINE_PING_INTERVAL,
        "offline_threshold": OFFLINE_THRESHOLD,
        "ws_push_min_interval": WS_PUSH_MIN_INTERVAL,
        "missed_refresh_threshold": MISSED_REFRESH_THRESHOLD,
        "notification_settings": notification_settings,
        "view_only": not has_dashboard_access(request),
        "is_local": is_local_request(request),
    }
class NoCacheStaticFiles(StaticFiles):
    async def get_response(self, path: str, scope):
        response = await super().get_response(path, scope)
        response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
        response.headers["Pragma"] = "no-cache"
        response.headers["Expires"] = "0"
        return response
THEMES_DIR = BASE_DIR / "themes"
def sanitize_theme_filename(name: str) -> str:
    cleaned = re.sub(r'[\\/:*?"<>|\x00-\x1f]', "", name).strip()
    cleaned = re.sub(r"\s+", " ", cleaned)
    return cleaned or "Untitled Scheme"
def _parse_theme_file(path: Path):
    try:
        with open(path, "r") as f:
            parsed = json.load(f)
    except Exception as e:
        log(f"[ColorSchemes] Error reading theme file {path.name}: {e}")
        return None
    if not isinstance(parsed, dict) or not parsed:
        log(f"[ColorSchemes] Skipping {path.name}: not a non-empty JSON object")
        return None
    if isinstance(parsed.get("data"), dict):
        name = str(parsed.get("name") or path.stem)
        data = parsed["data"]
    elif len(parsed) == 1 and isinstance(next(iter(parsed.values())), dict):
        name = str(next(iter(parsed.keys())))
        data = next(iter(parsed.values()))
    else:
        name = path.stem
        data = parsed
    if not isinstance(data, dict) or not data:
        log(f"[ColorSchemes] Skipping {path.name}: no usable color/size entries")
        return None
    return name, data
def load_theme_folder_schemes() -> dict:
    themes: Dict[str, Any] = {}
    try:
        if not THEMES_DIR.exists():
            return themes
        for path in sorted(THEMES_DIR.glob("*.json")):
            result = _parse_theme_file(path)
            if result is None:
                continue
            name, data = result
            themes[name] = data
    except Exception as e:
        log(f"[ColorSchemes] Error scanning {THEMES_DIR}: {e}")
    return themes
def find_theme_file_for_name(name: str) -> Optional[Path]:
    try:
        if not THEMES_DIR.exists():
            return None
        for path in sorted(THEMES_DIR.glob("*.json")):
            result = _parse_theme_file(path)
            if result is None:
                continue
            file_name, _data = result
            if file_name == name:
                return path
    except Exception as e:
        log(f"[ColorSchemes] Error scanning {THEMES_DIR} for '{name}': {e}")
    return None
class ColorSchemeSaveIn(BaseModel):
    name: str
    data: Dict[str, Any]
@router.get("/api/color-schemes")
def get_color_schemes():
    return load_theme_folder_schemes()
@router.post("/api/color-schemes")
def save_color_scheme(payload: ColorSchemeSaveIn):
    name = payload.name.strip()
    if not name:
        raise HTTPException(status_code=400, detail="Scheme name cannot be empty")
    try:
        THEMES_DIR.mkdir(parents=True, exist_ok=True)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Could not create {THEMES_DIR.resolve()}: {e}")
    target_path = find_theme_file_for_name(name)
    if target_path is None:
        base_filename = sanitize_theme_filename(name)
        target_path = THEMES_DIR / f"{base_filename}.json"
        suffix = 2
        while target_path.exists():
            target_path = THEMES_DIR / f"{base_filename}_{suffix}.json"
            suffix += 1
    try:
        tmp_path = target_path.with_name(target_path.name + ".tmp")
        with open(tmp_path, "w") as f:
            json.dump({name: payload.data}, f, indent=2, default=str)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, target_path)
    except Exception as e:
        log(f"[ColorSchemes] Error saving {target_path}: {e}")
        raise HTTPException(
            status_code=500,
            detail=(
                f"Could not write {target_path.resolve()}: {e}. "
                f"If {THEMES_DIR.name}/ is supposed to be a mounted volume, check that the "
                f"mount is actually active and the container user can write to it."
            ),
        )
    result = _parse_theme_file(target_path)
    if result is None or result[0] != name:
        log(f"[ColorSchemes] Save reported success but re-reading {target_path} did not confirm '{name}'")
        raise HTTPException(
            status_code=500,
            detail=(
                f"Save appeared to succeed but re-reading {target_path.resolve()} did not "
                f"confirm '{name}'. This usually means {THEMES_DIR.name}/ isn't the persistent "
                f"volume you think it is."
            ),
        )
    log(f"[ColorSchemes] Saved scheme '{name}' -> {target_path.resolve()}")
    return {"status": "ok", "name": name, "file": target_path.name}
@router.delete("/api/color-schemes/{name}")
def delete_color_scheme(name: str):
    theme_path = find_theme_file_for_name(name)
    if theme_path is not None:
        try:
            theme_path.unlink()
            log(f"[ColorSchemes] Deleted theme file {theme_path.name} (scheme '{name}')")
            return {"status": "ok", "name": name, "file": theme_path.name}
        except PermissionError as e:
            log(f"[ColorSchemes] Permission denied deleting {theme_path}: {e}")
            raise HTTPException(
                status_code=500,
                detail=(
                    f"Found '{name}' in {THEMES_DIR.name}/{theme_path.name} but the server "
                    f"doesn't have permission to delete it - check the host folder/volume "
                    f"permissions for {THEMES_DIR.name}/."
                ),
            )
        except Exception as e:
            log(f"[ColorSchemes] Error deleting theme file {theme_path}: {e}")
            raise HTTPException(
                status_code=500,
                detail=f"Found '{name}' in {THEMES_DIR.name}/{theme_path.name} but couldn't delete it: {e}",
            )
    raise HTTPException(status_code=404, detail=f"Color scheme '{name}' not found")
@router.post("/api/view-only/request-code")
async def request_unlock_code(payload: dict, request: Request):
    global _unlock_code, _unlock_code_expires, _unlock_code_last_sent
    if has_dashboard_access(request):
        return {"status": "already_unlocked"}
    ip_error = _check_and_record_ip_attempt(_client_ip(request))
    if ip_error:
        log(f"[ViewOnly] Unlock code request rejected - IP over attempt quota ({_client_ip(request)})")
        return JSONResponse(status_code=429, content={"status": "error", "detail": ip_error})
    requested_email = str(payload.get("email") or "").strip().lower()
    if not requested_email:
        return JSONResponse(status_code=400, content={
            "status": "error",
            "detail": "Enter the email address configured for this dashboard",
        })
    with _unlock_lock:
        now = time.time()
        wait_left = UNLOCK_CODE_COOLDOWN - (now - _unlock_code_last_sent)
        if wait_left > 0:
            return JSONResponse(status_code=429, content={
                "status": "error",
                "detail": f"Please wait {int(wait_left)}s before requesting another code",
            })
        if not notification_service or not (
            notification_service.smtp_username and notification_service.smtp_password
        ) or not notification_service.email_recipient:
            return JSONResponse(status_code=400, content={
                "status": "error",
                "detail": "Email isn't configured on the server (SMTP credentials/recipients) - can't send an unlock code",
            })
        configured_emails = {e.strip().lower() for e in notification_service.email_recipient}
        if requested_email not in configured_emails:
            _unlock_code_last_sent = now
            log(f"[ViewOnly] Unlock code request rejected - email not recognized ({_client_ip(request)})")
            return JSONResponse(status_code=403, content={
                "status": "error",
                "detail": "Email not recognized",
            })
        code = secrets.token_hex(8)
        _unlock_code = code
        _unlock_code_expires = now + UNLOCK_CODE_TTL
        _unlock_code_last_sent = now
    client_ip = _client_ip(request)
    sent = await asyncio.to_thread(
        notification_service.send_email,
        "RigControl Dashboard - Remote Unlock Code",
        (
            f"An unlock code was requested for the RigControl dashboard from IP {client_ip}.\n\n"
            f"Code: {code}\n\n"
            f"This code expires in {UNLOCK_CODE_TTL // 60} minutes and can only be used once.\n"
            f"If you didn't request this, ignore it - view-only mode stays in effect."
        ),
        None,
        True,
    )
    if not sent:
        return JSONResponse(status_code=500, content={
            "status": "error",
            "detail": "Failed to send unlock code email - check server logs",
        })
    log(f"[ViewOnly] Unlock code requested from {client_ip}, emailed to {len(notification_service.email_recipient)} recipient(s)")
    return {"status": "sent"}
@router.post("/api/view-only/verify-code")
async def verify_unlock_code(payload: dict, request: Request, response: Response):
    global _unlock_code, _unlock_code_expires
    code = str(payload.get("code") or "").strip()
    if not code:
        return JSONResponse(status_code=400, content={"status": "error", "detail": "Missing code"})
    ip_error = _check_and_record_ip_attempt(_client_ip(request))
    if ip_error:
        log(f"[ViewOnly] Unlock verify rejected - IP over attempt quota ({_client_ip(request)})")
        return JSONResponse(status_code=429, content={"status": "error", "detail": ip_error})
    with _unlock_lock:
        valid = (
            _unlock_code is not None
            and secrets.compare_digest(code.lower(), _unlock_code.lower())
            and time.time() <= _unlock_code_expires
        )
        if valid:
            _unlock_code = None
            _unlock_code_expires = 0.0
    if not valid:
        return JSONResponse(status_code=400, content={"status": "error", "detail": "Invalid or expired code"})
    token = secrets.token_urlsafe(32)
    _unlock_tokens[token] = time.time() + UNLOCK_TOKEN_TTL
    response.set_cookie(
        key=UNLOCK_COOKIE_NAME,
        value=token,
        max_age=UNLOCK_TOKEN_TTL,
        httponly=True,
        samesite="lax",
    )
    client_ip = _client_ip(request)
    log(f"[ViewOnly] Unlocked for {client_ip}, expires in {UNLOCK_TOKEN_TTL // 3600}h")
    return {"status": "unlocked"}
@router.post("/api/view-only/logout")
async def logout_unlock(request: Request, response: Response):
    token = request.cookies.get(UNLOCK_COOKIE_NAME)
    if token:
        _unlock_tokens.pop(token, None)
    response.delete_cookie(key=UNLOCK_COOKIE_NAME)
    log(f"[ViewOnly] Logged out {_client_ip(request)}")
    return {"status": "logged_out"}
app = FastAPI(lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)
@app.middleware("http")
async def view_only_gate(request: Request, call_next):
    if request.method in VIEW_ONLY_MUTATING_METHODS:
        path = request.url.path
        if BASE_PATH and path.startswith(BASE_PATH):
            path = path[len(BASE_PATH):] or "/"
        if path not in VIEW_ONLY_EXEMPT_PATHS and not has_dashboard_access(request):
            return JSONResponse(
                status_code=403,
                content={
                    "error": "view_only",
                    "detail": "This dashboard is in view-only mode for remote connections - connect from the local network to make changes.",
                },
            )
    return await call_next(request)
@app.get("/favicon.ico", include_in_schema=False)
async def favicon():
    return FileResponse(STATIC_DIR / "favicon.ico", media_type="image/x-icon")
if BASE_PATH:
    app.include_router(router, prefix=BASE_PATH)
    app.mount(
        f"{BASE_PATH}/static",
        NoCacheStaticFiles(directory=STATIC_DIR),
        name="static"
    )
else:
    app.include_router(router)
    app.mount(
        "/static",
        NoCacheStaticFiles(directory=STATIC_DIR),
        name="static"
    )
if __name__ == "__main__":
    uvicorn.run(app, host=API_BIND, port=API_PORT, log_level="info")
