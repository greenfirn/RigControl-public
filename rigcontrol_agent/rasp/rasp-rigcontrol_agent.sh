sudo tee /usr/local/bin/rigcontrol_agent.py > /dev/null <<'EOF'
import rigcontrol_telemetry as telemetry
import asyncio
import json
import socket
import subprocess
import time
import urllib.request
import os
import datetime
from aiomqtt import Client, MqttError
# ================================================================
# GLOBAL SETTINGS
# ================================================================
BROKER_HOST = "127.0.0.1"
BROKER_PORT = 1883
BROKER_USER = None
BROKER_PASS = None
CMD_SCRIPT = "/usr/local/bin/rigcontrol_cmd.sh"
MIN_TELEMETRY_PULL_INTERVAL_SECONDS = 5
# ================================================================
# LOGGING
# ================================================================
def log(msg):
    print(f"[RigControl] {msg}", flush=True)
# ================================================================
# CONFIG - load
# ================================================================
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
                    cfg[k.strip().upper()] = v.strip()
    except Exception as e:
        log(f"Config load error: {e}")
    return cfg
# ================================================================
# CONFIG - LOCAL MQTT OR AWS
# ================================================================
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
try:
    MIN_TELEMETRY_PULL_INTERVAL_SECONDS = int(cfg.get("MIN_TELEMETRY_PULL_INTERVAL_SECONDS", MIN_TELEMETRY_PULL_INTERVAL_SECONDS))
    if MIN_TELEMETRY_PULL_INTERVAL_SECONDS < 0:
        MIN_TELEMETRY_PULL_INTERVAL_SECONDS = 0
except (TypeError, ValueError):
    MIN_TELEMETRY_PULL_INTERVAL_SECONDS = 5
log(f"[Config] Minimum telemetry pull interval = {MIN_TELEMETRY_PULL_INTERVAL_SECONDS}s")
# ================================================================
# TOPICS
# ================================================================
TOPIC_PREFIX = "rigcontrol"
RIG_NAME = socket.gethostname()
STATUS_TOPIC = f"{TOPIC_PREFIX}/{RIG_NAME}/status"
CMD_TOPIC_DIRECT = f"{TOPIC_PREFIX}/{RIG_NAME}/cmd"
CMD_TOPIC_ALL = f"{TOPIC_PREFIX}/all/cmd"
CHECK_TOPIC_DIRECT = f"{TOPIC_PREFIX}/{RIG_NAME}/check"
CHECK_TOPIC_ALL = f"{TOPIC_PREFIX}/all/check"
RESP_TOPIC   = f"{TOPIC_PREFIX}/{RIG_NAME}/cmd_response"
# ================================================================
# RUN SHELL HELPERS (unchanged)
# ================================================================
def run(cmd):
    proc = subprocess.run(cmd, shell=True, text=True,
                          stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE)
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
_last_telemetry_pull_ts = 0.0
_telemetry_pull_in_progress = False
# ================================================================
# ASYNC PUBLISH
# ================================================================
async def publish_status(mqtt, reason="periodic"):
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
        payload = await asyncio.to_thread(
            telemetry.collect_full_stats
        )
        payload["event"] = reason
        await mqtt.publish(STATUS_TOPIC, json.dumps(payload))
        log(f"Telemetry sent ({reason})")
    finally:
        _telemetry_pull_in_progress = False
# ================================================================
# ASYNC COMMAND HANDLER (EXTERNAL SCRIPT)
# ================================================================
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
        await publish_status(mqtt, "refresh-request")
        return
    try:
        proc = await asyncio.to_thread(
            subprocess.run,
            [CMD_SCRIPT],
            input=command,
            capture_output=True,
            text=True
        )
        response = {
            "id": cmd_id,
            "rig": RIG_NAME,
            "timestamp": int(time.time()),
            "returncode": proc.returncode,
            "stdout": proc.stdout.strip(),
            "stderr": proc.stderr.strip(),
        }
        await mqtt.publish(RESP_TOPIC, json.dumps(response))
        log(f"Command executed ({cmd_id})")
        await publish_status(mqtt, "cmd-run")
    except Exception as e:
        log(f"Command execution error: {e}")
# ================================================================
# Publish check
# ================================================================
async def publish_check(mqtt):
    payload = {
        "rig": RIG_NAME,
        "type": "check",
        "timestamp": int(time.time()),
        "uptime": int(time.monotonic()),
        "state": "online"
    }
    await mqtt.publish(STATUS_TOPIC, json.dumps(payload))
# ================================================================
# MQTT LOOP (LOCAL BROKER, AUTH OPTIONAL)
# ================================================================
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
                log(f"Subscribed → {CMD_TOPIC_ALL}")
                log(f"Subscribed → {CMD_TOPIC_DIRECT}")
                log(f"Subscribed → {CHECK_TOPIC_ALL}")
                log(f"Subscribed → {CHECK_TOPIC_DIRECT}")
                async for msg in mqtt.messages:
                    topic = str(msg.topic)
                    payload = msg.payload.decode(errors="ignore")
                    if topic.endswith("/check"):
                        asyncio.create_task(publish_check(mqtt))
                        continue
                    if topic.endswith("/cmd"):
                        asyncio.create_task(handle_command(payload, mqtt))
                        continue
                    log(f"Ignoring message on unexpected topic: {topic}")
        except MqttError as e:
            log(f"MQTT error: {e} — retrying in 3s")
            await asyncio.sleep(3)
# ================================================================
# MAIN
# ================================================================
async def main():
    await asyncio.gather(
        mqtt_loop()
    )
if __name__ == "__main__":
    asyncio.run(main())
EOF
sudo systemctl restart rigcontrol-agent
