sudo mkdir -p /etc/rigcontrol /var/lib/rigcontrol /run/rigcontrol
[ -s /etc/rigcontrol/ca.crt ] || echo "WARNING: /etc/rigcontrol/ca.crt is missing - copy the broker's ca.crt there once (see mosquitto-tls-setup.txt), otherwise the agent cannot verify the broker"
sudo tee /etc/rigcontrol/rigcontrol-agent.conf > /dev/null <<'EOF'
# ===== SERVER SETTINGS (dashboard server MQTT broker) =====
BROKER_HOST=10.10.0.10
BROKER_PORT=8883
BROKER_USER=admin
BROKER_PASS=********************
MQTT_TLS=1
MQTT_CA_FILE=/etc/rigcontrol/ca.crt
#MQTT_CLIENT_CERT=
#MQTT_CLIENT_KEY=
#MQTT_TLS_INSECURE=0
MIN_TELEMETRY_PULL_INTERVAL_SECONDS=5
# ===== END SERVER SETTINGS =====
# ===== USER FLAG DESCRIPTION (rigcontrol-agent.conf, read live) =====
# BROKER_HOST / BROKER_PORT / BROKER_USER / BROKER_PASS: MQTT broker (dashboard server) the agent connects to
# MQTT_TLS (default 1): 1 = encrypted connection to the broker (BROKER_PORT = broker TLS port, 8883), 0 = plain MQTT (BROKER_PORT 1883)
# MQTT_CA_FILE: CA certificate that signed the broker certificate (copy the broker's ca.crt to this path once; empty = system CAs)
# MQTT_CLIENT_CERT / MQTT_CLIENT_KEY: client certificate and key, only if the broker requires them
# MQTT_TLS_INSECURE (default 0): 1 = skip certificate/hostname verification (testing only)
# MIN_TELEMETRY_PULL_INTERVAL_SECONDS: minimum seconds between telemetry pulls
# OSN_PRIMARY (default 1): 1 = GPU + CPU/memory from OctaSpace osn only, no local GPU fallback; 0 = ignore osn, collect locally
# OSN_ALLOW_MISSING_GPU_STATS (default 1): with osn, also fetch what it leaves out without nvidia-smi (mem temp, lspci/proc); the start-up read happens regardless
# DOCKER_SKIP_GPU_STATS (default 0): 1 = skip GPU stats while a non-miner docker container is running
# OVERRIDE_LIST: docker image keywords that are GPU-stats safe (keyword match anywhere in the image name)
# BLOCK_LIST: docker image keywords that ALWAYS skip GPU stats while running (same match, values report 0)
# STATS_DB_ENABLED / STATS_DB_MAX_HISTORY_DAYS / STATS_DB_INTERVAL_SECONDS: local stats history on/off, days kept, seconds between samples
# CPU_SERVICE_NAME / GPU_SERVICE_NAME / AUX_SERVICE_NAME / WATCHDOG_SERVICE_NAME: service names the dashboard controls
# CUSTOM_MINER_BIN_GPU / _CPU / _AUX: custom miner binary per slot
# <NAME>_BIN / _API_HOST / _API_PORT / _LOG_PATH / _LOG_STYLE: per custom miner, NAME = miner name as A-Z0-9_ (LOG_STYLE=blocks counts "Accepted N blocks")
# ===== END USER FLAG DESCRIPTION =====
OSN_PRIMARY=1
#OSN_ALLOW_MISSING_GPU_STATS=1
#DOCKER_SKIP_GPU_STATS=0
OVERRIDE_LIST="miner/miner:latest"
BLOCK_LIST=""
STATS_DB_ENABLED=true
STATS_DB_MAX_HISTORY_DAYS=7
STATS_DB_INTERVAL_SECONDS=90
#CPU_SERVICE_NAME=docker_events_cpu.service
#GPU_SERVICE_NAME=docker_events_gpu.service
AUX_SERVICE_NAME=keryxd.service
#WATCHDOG_SERVICE_NAME=rigcontrol_watchdog.service
#CUSTOM_MINER_BIN_GPU=/opt/miners/my-custom-miner/current/my-custom-miner
#CUSTOM_MINER_BIN_CPU=/opt/miners/my-custom-miner/current/my-custom-miner
CUSTOM_MINER_BIN_AUX=/opt/miners/keryx-node/keryxd
KERYXD_LOG_PATH=/run/rigcontrol/aux_miner.log
KERYXD_LOG_STYLE=blocks
#KERYX_MINER_API_HOST=127.0.0.1
#KERYX_MINER_API_PORT=3338
#KERYX_MINER_SUPR_API_HOST=127.0.0.1
#KERYX_MINER_SUPR_API_PORT=3338
EOF
