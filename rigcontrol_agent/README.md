[Get started](../README.md#get-started)

## Guides

- [Server certificate](#server-certificate)
- [Agent setup](#agent-setup)
- [Basic TLS](#basic-tls)
- [Advanced TLS](#advanced-tls)
- [No TLS](#no-tls)

## Updates

** update.. 'OSN_PRIMARY=0' (default): local GPU/CPU/memory stats. Set 'OSN_PRIMARY=1' to use OctaSpace node (osn) metrics instead. **

** updated agent to use .venv virtual environment, uninstall not needed requirements from system **

Ubuntu 24.04:

```
sudo python3 -m pip uninstall -y aiomqtt typing_extensions paho-mqtt --break-system-packages
```

Ubuntu 22.04:

```
sudo python3 -m pip uninstall -y aiomqtt typing_extensions paho-mqtt
```

## Telemetry flow (each poll)

- **Agent start:** one full local GPU read (unless the GPUs are in passthrough / blocked), cached: power limits (min/default/max), vbios, board partner, architecture, PCI slot, VRAM total. Reused on every poll; never repeated on refresh.
- **1. Local passthrough check:** GPUs bound to `vfio-pci` (sysfs) belong to a VM. Runs first, before osn is asked, and cannot be overridden. GPU values are reported as `0`, no GPU tool is called.
- **2. osn is asked** (always, if installed): `osn_gpu_passthrough_active=1` gives the same result as step 1.
- **3. Docker rules:** a running container matching `BLOCK_LIST` always skips GPU stats (values `0`). Optional `DOCKER_SKIP_GPU_STATS=1` also skips while any non-miner container runs (empty GPU list).
- **4. GPU stats source:**
  - `OSN_PRIMARY=0` (default): local `nvidia-smi` / `rocm-smi` / gputemps through the GPU tool guard.
  - `OSN_PRIMARY=1`: GPU, CPU and memory come from osn only, no local GPU fallback. Static values are filled from the start-up cache; osn unreachable gives `-1` values.
- **GPU tool guard:** every local GPU call has a 5s timeout. A timeout blocks the tool until the agent restarts; any other failure pauses it 30s, and a second failure in a row blocks it. Paused or blocked tools report `-1` values (`stats_failed` / `stats_error` say why).
- **5. Miner stats** always come from the miner APIs / logs. Load, network, uptime, docker and service status are collected locally.
- **6. Reply:** one universal payload (`gpus[]` with temp, util, `power_watts` + `power_limit`, clocks, `coreoffset`, VRAM, ...). The dashboard combines used/limit watts for display. The log's "Stats source" line shows where each part came from.

Value meaning on the dashboard: `0` = intentionally not read (passthrough / `BLOCK_LIST`), `-1` = read failed, `--` = not reported.

## Server certificate

1. create the server certificate on the server (skip if already done during the server setup, details: [basic TLS guide](../rigcontrol_dashboard_server_pi/mosquitto-tls-setup.txt), steps 1-2). server certs are the broker's identity, workers use them to check they are talking to the right broker. replace `10.10.0.10` with the ip of your dashboard server:

   ```
   openssl version || (sudo apt update && sudo apt install -y openssl)
   sudo mkdir -p ~/ha-docker/mosquitto/config/certs && cd ~/ha-docker/mosquitto/config/certs
   sudo openssl genrsa -out ca.key 4096
   sudo openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -subj "/CN=RigControl MQTT CA" -out ca.crt
   sudo openssl genrsa -out server.key 2048
   sudo openssl req -new -key server.key -subj "/CN=10.10.0.10" -out server.csr
   printf "subjectAltName=IP:10.10.0.10,IP:127.0.0.1" | sudo tee san.ext > /dev/null
   sudo openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 825 -sha256 -extfile san.ext
   sudo chown 1883:1883 server.key server.crt ca.crt
   sudo chmod 640 server.key
   cd ~/ha-docker && sudo docker compose up -d mosquitto
   ```

   (windows server: [Windows basic TLS guide](../rigcontrol_dashboard_server_windows/mosquitto-tls-setup.txt))

## Agent setup

the broker needs its server certificate first, see [Server certificate](#server-certificate) (or [No TLS](#no-tls) for plain mqtt).

1. install python on a client worker...

   ```
   sudo apt update; sudo apt install -y python3 python3-venv ca-certificates
   ```

2. download the needed files:
   - [rigcontrol-agent-local.sh](ubuntu/rigcontrol-agent-local.sh)
   - [rigcontrol_agent.sh](ubuntu/rigcontrol_agent.sh)
   - [rigcontrol_agent-service.sh](ubuntu/rigcontrol_agent-service.sh)
   - [rigcontrol_telemetry.sh](ubuntu/rigcontrol_telemetry.sh)
   - [rigcontrol_cmd.sh](ubuntu/rigcontrol_cmd.sh)
   - [generate-copy-paste-update.bat](ubuntu/generate-copy-paste-update.bat)

3. set the server details in [rigcontrol-agent-local.sh](ubuntu/rigcontrol-agent-local.sh): `BROKER_HOST`, `BROKER_USER`, `BROKER_PASS`

4. for custom service names set them in [rigcontrol-agent-local.sh](ubuntu/rigcontrol-agent-local.sh) -- 'AUX_SERVICE_NAME=keryxd.service'

5. install / update (the agent connects with user and password, encrypted, certificate not checked yet)
   - run 'generate-copy-paste-update.bat' to create/update 'copy-paste-update.sh'
   - open a ssh session on a worker (on a windows machine use putty or similar ssh client)
   - copy/paste the contents of 'copy-paste-update.sh' into a worker ssh session and press enter to write the files and start/restart the agent

   if copy/paste into the console fails (the file is about 4000 lines and a terminal can drop or corrupt lines, giving a SyntaxError or IndentationError in the agent log), copy the file to the worker and run it instead:

   ```
   scp copy-paste-update.sh user@WORKER:~/
   ssh -t user@WORKER "bash ~/copy-paste-update.sh"
   ```

   'EXCLUDE_FROM_TOTALS = True' in [rigcontrol_telemetry.sh](ubuntu/rigcontrol_telemetry.sh) for dashboard host to not be included in status totals, select

## Basic TLS

1. copy the broker's `ca.crt` (public) to `/etc/rigcontrol/ca.crt` on each worker. first write the helper script once (paste the contents of [mosquitto-ca-copy.sh](../rigcontrol_dashboard_server_pi/mosquitto-ca-copy.sh), it writes `~/ha-docker/mosquitto-ca-copy.sh`), then run it as your normal user (no sudo) with one or more worker logins:

   ```
   cd ~/ha-docker
   bash mosquitto-ca-copy.sh user@WORKER [user@WORKER2 ...]
   ```

   (windows server: the folder is `C:\mosquitto-certs\`, run the same commands in Git Bash with `/c/mosquitto-certs/ca.crt`. a windows worker uses `C:\rigcontrol\ca.crt`)

2. in `/etc/rigcontrol/rigcontrol-agent.conf` on the worker set `MQTT_TLS_INSECURE=0` and uncomment `#MQTT_CA_FILE=/etc/rigcontrol/ca.crt` (or `#MQTT_CA_FILE=C:\rigcontrol\ca.crt` in `C:\rigcontrol\rigcontrol_agent.conf` on a windows worker)

3. restart the agent, it now verifies the broker certificate:

   ```
   sudo systemctl restart rigcontrol-agent.service
   ```

## Advanced TLS

1. client certs are separate from the server certs, they let the broker check who is connecting. each worker gets one, the dashboard server also connects to the broker so it needs one too (`rigcontrol-dashboard`, [advanced TLS guide](../rigcontrol_dashboard_server_pi/mosquitto-tls-advanced.txt), step 4). on the server create the worker's client certificate, `WORKER_NAME` = the worker's hostname, one per worker. needs the helper script [mosquitto-client-cert.sh](../rigcontrol_dashboard_server_pi/mosquitto-client-cert.sh) in `~/ha-docker` ([advanced TLS guide](../rigcontrol_dashboard_server_pi/mosquitto-tls-advanced.txt), step 1):

   ```
   cd ~/ha-docker
   sudo bash mosquitto-client-cert.sh WORKER_NAME
   ```

2. copy the worker's `client.crt` and `client.key` to `/etc/rigcontrol/` on that worker. first write the helper script once (paste the contents of [mosquitto-client-cert-copy.sh](../rigcontrol_dashboard_server_pi/mosquitto-client-cert-copy.sh), it writes `~/ha-docker/mosquitto-client-cert-copy.sh`), then run it as your normal user (no sudo), replace `WORKER_NAME` with the certificate name and `user@WORKER` with the worker login:

   ```
   cd ~/ha-docker
   bash mosquitto-client-cert-copy.sh WORKER_NAME user@WORKER
   ```

   from a windows pc (certificates in `C:\temp\clients`) use [copy-client-cert.bat](ubuntu/copy-client-cert.bat) instead:

   ```
   copy-client-cert.bat WORKER_NAME user@WORKER
   ```

3. in `/etc/rigcontrol/rigcontrol-agent.conf` on the worker uncomment:

   ```
   #MQTT_CLIENT_CERT=/etc/rigcontrol/client.crt
   #MQTT_CLIENT_KEY=/etc/rigcontrol/client.key
   ```

4. restart the agent:

   ```
   sudo systemctl restart rigcontrol-agent.service
   ```

5. when every worker is connected with its certificate, enable `require_certificate true` on the broker ([advanced TLS guide](../rigcontrol_dashboard_server_pi/mosquitto-tls-advanced.txt), step 5). the dashboard server's own client certificate is step 4 of that guide, do it before this

## No TLS

1. in `/etc/rigcontrol/rigcontrol-agent.conf` on the worker set `BROKER_PORT=1883` and `MQTT_TLS=0`
2. restart the agent:

   ```
   sudo systemctl restart rigcontrol-agent.service
   ```

3. the broker needs a plain 1883 listener: [no TLS guide](../rigcontrol_dashboard_server_pi/mosquitto-no-tls-setup.txt)

## Recommended

reserve the port range used for rental services (replace 51000-52000 with yours), so outgoing connections like the agent's mqtt never use a rental port. services can still bind these ports.

```
echo "net.ipv4.ip_local_reserved_ports = 51000-52000" | sudo tee /etc/sysctl.d/99-rental-ports.conf
sudo sysctl --system
cat /proc/sys/net/ipv4/ip_local_reserved_ports
```

Useful commands:

show service status:

```bash
systemctl status rigcontrol-agent.service --no-pager
```

follow the agent log: ctrl+c to break/exit

```bash
journalctl -u rigcontrol-agent.service -f
```

show the last 100 log lines:

```bash
journalctl -u rigcontrol-agent.service -n 100 --no-pager
```

reload systemd after editing the service file:

```bash
sudo systemctl daemon-reload
```

enable start on boot:

```bash
sudo systemctl enable rigcontrol-agent.service
```

disable start on boot:

```bash
sudo systemctl disable rigcontrol-agent.service
```

start the agent:

```bash
sudo systemctl start rigcontrol-agent.service
```

stop the agent:

```bash
sudo systemctl stop rigcontrol-agent.service
```

restart the agent:

```bash
sudo systemctl restart rigcontrol-agent.service
```

![test-windows](../images/Screenshot-test-windows.png)

[rigcontrol-agent-local-keryxd.sh](ubuntu/rigcontrol-agent-local-keryxd.sh)... keryxd node: aux service name,binary location,log,log type

```
sudo tee /etc/rigcontrol/rigcontrol-agent.conf > /dev/null <<'EOF'
# ===== SERVER SETTINGS (dashboard server MQTT broker) =====
BROKER_HOST=10.10.0.10
BROKER_PORT=8883
BROKER_USER=admin
BROKER_PASS=CHANGE_ME
# --- BASIC TLS: encrypted connection on the broker's TLS port. for verified TLS copy ca.crt to the worker and uncomment MQTT_CA_FILE (mosquitto-tls-setup.txt) ---
MQTT_TLS=1
#MQTT_CA_FILE=/etc/rigcontrol/ca.crt
# --- END BASIC TLS ---
# --- ADVANCED TLS: client certificate (mutual TLS), uncomment when the broker has require_certificate true (mosquitto-tls-advanced.txt) ---
#MQTT_CLIENT_CERT=/etc/rigcontrol/client.crt
#MQTT_CLIENT_KEY=/etc/rigcontrol/client.key
# --- END ADVANCED TLS ---
# --- TEST TLS: skip certificate and hostname verification, no ca.crt needed on the worker. set to 0 when verified TLS is used ---
MQTT_TLS_INSECURE=1
# --- END TEST TLS ---
MIN_TELEMETRY_PULL_INTERVAL_SECONDS=5
# ===== END SERVER SETTINGS =====
# ===== USER FLAG DESCRIPTION (rigcontrol-agent.conf, read live) =====
# BROKER_HOST / BROKER_PORT / BROKER_USER / BROKER_PASS: MQTT broker (dashboard server) the agent connects to
# MQTT_TLS (default 1): 1 = encrypted connection to the broker (BROKER_PORT = broker TLS port, 8883), 0 = plain MQTT (BROKER_PORT 1883)
# MQTT_CA_FILE: CA certificate that signed the broker certificate (copy the broker's ca.crt to this path once; empty = /etc/rigcontrol/ca.crt if present, else system CAs)
# MQTT_CLIENT_CERT / MQTT_CLIENT_KEY: client certificate and key, only if the broker requires them
# MQTT_TLS_INSECURE (default 0): 1 = skip certificate/hostname verification (testing only)
# MIN_TELEMETRY_PULL_INTERVAL_SECONDS: minimum seconds between telemetry pulls
# OSN_PRIMARY (default 0): 1 = GPU + CPU/memory from OctaSpace osn only, no local GPU fallback; 0 = ignore osn, collect locally
# OSN_ALLOW_MISSING_GPU_STATS (default 1): with osn, also fetch what it leaves out without nvidia-smi (mem temp, lspci/proc); the start-up read happens regardless
# DOCKER_SKIP_GPU_STATS (default 0): 1 = skip GPU stats while a non-miner docker container is running
# OVERRIDE_LIST: docker image keywords that are GPU-stats safe (keyword match anywhere in the image name)
# BLOCK_LIST: docker image keywords that ALWAYS skip GPU stats while running (same match, values report 0)
# STATS_DB_ENABLED / STATS_DB_MAX_HISTORY_DAYS / STATS_DB_INTERVAL_SECONDS: local stats history on/off, days kept, seconds between samples
# CPU_SERVICE_NAME / GPU_SERVICE_NAME / AUX_SERVICE_NAME / WATCHDOG_SERVICE_NAME: service names the dashboard controls
# CUSTOM_MINER_BIN_GPU / _CPU / _AUX: custom miner binary per slot
# <NAME>_BIN / _API_HOST / _API_PORT / _LOG_PATH / _LOG_STYLE: per custom miner, NAME = miner name as A-Z0-9_ (LOG_STYLE=blocks counts "Accepted N blocks")
# ===== END USER FLAG DESCRIPTION =====
OSN_PRIMARY=0
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
```

[rigcontrol-agent-local.sh](ubuntu/rigcontrol-agent-local.sh)... KERYX_MINER_API

```
sudo tee /etc/rigcontrol/rigcontrol-agent.conf > /dev/null <<'EOF'
# ===== SERVER SETTINGS (dashboard server MQTT broker) =====
BROKER_HOST=10.10.0.10
BROKER_PORT=8883
BROKER_USER=admin
BROKER_PASS=CHANGE_ME
# --- BASIC TLS: encrypted connection on the broker's TLS port. for verified TLS copy ca.crt to the worker and uncomment MQTT_CA_FILE (mosquitto-tls-setup.txt) ---
MQTT_TLS=1
#MQTT_CA_FILE=/etc/rigcontrol/ca.crt
# --- END BASIC TLS ---
# --- ADVANCED TLS: client certificate (mutual TLS), uncomment when the broker has require_certificate true (mosquitto-tls-advanced.txt) ---
#MQTT_CLIENT_CERT=/etc/rigcontrol/client.crt
#MQTT_CLIENT_KEY=/etc/rigcontrol/client.key
# --- END ADVANCED TLS ---
# --- TEST TLS: skip certificate and hostname verification, no ca.crt needed on the worker. set to 0 when verified TLS is used ---
MQTT_TLS_INSECURE=1
# --- END TEST TLS ---
MIN_TELEMETRY_PULL_INTERVAL_SECONDS=5
# ===== END SERVER SETTINGS =====
# ===== USER FLAG DESCRIPTION (rigcontrol-agent.conf, read live) =====
# BROKER_HOST / BROKER_PORT / BROKER_USER / BROKER_PASS: MQTT broker (dashboard server) the agent connects to
# MQTT_TLS (default 1): 1 = encrypted connection to the broker (BROKER_PORT = broker TLS port, 8883), 0 = plain MQTT (BROKER_PORT 1883)
# MQTT_CA_FILE: CA certificate that signed the broker certificate (copy the broker's ca.crt to this path once; empty = /etc/rigcontrol/ca.crt if present, else system CAs)
# MQTT_CLIENT_CERT / MQTT_CLIENT_KEY: client certificate and key, only if the broker requires them
# MQTT_TLS_INSECURE (default 0): 1 = skip certificate/hostname verification (testing only)
# MIN_TELEMETRY_PULL_INTERVAL_SECONDS: minimum seconds between telemetry pulls
# OSN_PRIMARY (default 0): 1 = GPU + CPU/memory from OctaSpace osn only, no local GPU fallback; 0 = ignore osn, collect locally
# OSN_ALLOW_MISSING_GPU_STATS (default 1): with osn, also fetch what it leaves out without nvidia-smi (mem temp, lspci/proc); the start-up read happens regardless
# DOCKER_SKIP_GPU_STATS (default 0): 1 = skip GPU stats while a non-miner docker container is running
# OVERRIDE_LIST: docker image keywords that are GPU-stats safe (keyword match anywhere in the image name)
# BLOCK_LIST: docker image keywords that ALWAYS skip GPU stats while running (same match, values report 0)
# STATS_DB_ENABLED / STATS_DB_MAX_HISTORY_DAYS / STATS_DB_INTERVAL_SECONDS: local stats history on/off, days kept, seconds between samples
# CPU_SERVICE_NAME / GPU_SERVICE_NAME / AUX_SERVICE_NAME / WATCHDOG_SERVICE_NAME: service names the dashboard controls
# CUSTOM_MINER_BIN_GPU / _CPU / _AUX: custom miner binary per slot
# <NAME>_BIN / _API_HOST / _API_PORT / _LOG_PATH / _LOG_STYLE: per custom miner, NAME = miner name as A-Z0-9_ (LOG_STYLE=blocks counts "Accepted N blocks")
# ===== END USER FLAG DESCRIPTION =====
OSN_PRIMARY=0
#OSN_ALLOW_MISSING_GPU_STATS=1
#DOCKER_SKIP_GPU_STATS=0
OVERRIDE_LIST=""
BLOCK_LIST=""
STATS_DB_ENABLED=true
STATS_DB_MAX_HISTORY_DAYS=7
STATS_DB_INTERVAL_SECONDS=90
#CPU_SERVICE_NAME=docker_events_cpu.service
#GPU_SERVICE_NAME=docker_events_gpu.service
#AUX_SERVICE_NAME=keryxd.service
#WATCHDOG_SERVICE_NAME=rigcontrol_watchdog.service
#CUSTOM_MINER_BIN_GPU=/opt/miners/my-custom-miner/current/my-custom-miner
#CUSTOM_MINER_BIN_CPU=/opt/miners/my-custom-miner/current/my-custom-miner
#CUSTOM_MINER_BIN_AUX=/opt/miners/my-custom-miner/current/my-custom-miner
#KERYX_MINER_BIN=/opt/miners/keryx-miner/current/keryx-miner
KERYX_MINER_API_HOST=127.0.0.1
KERYX_MINER_API_PORT=3338
#KERYX_MINER_SUPR_BIN=/opt/miners/custom/keryx-miner-supr/current/keryx-miner-supr
KERYX_MINER_SUPR_API_HOST=127.0.0.1
KERYX_MINER_SUPR_API_PORT=3338
#KERYXD_BIN=/opt/miners/keryx-node/keryxd
#KERYXD_LOG_PATH=/run/rigcontrol/aux_miner.log
#KERYXD_LOG_STYLE=blocks
EOF
```
