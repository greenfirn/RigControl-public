[Get started](../README.md#get-started)

** update.. use octaspace osn metrics for gpu stats 'OSN_PRIMARY=1' in agent config **

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
  - `OSN_PRIMARY=1` (default): GPU, CPU and memory come from osn only, no local GPU fallback. Static values are filled from the start-up cache; osn unreachable gives `-1` values.
  - `OSN_PRIMARY=0`: local `nvidia-smi` / `rocm-smi` / gputemps through the GPU tool guard.
- **GPU tool guard:** every local GPU call has a 5s timeout. A timeout blocks the tool until the agent restarts; any other failure pauses it 30s, and a second failure in a row blocks it. Paused or blocked tools report `-1` values (`stats_failed` / `stats_error` say why).
- **5. Miner stats** always come from the miner APIs / logs. Load, network, uptime, docker and service status are collected locally.
- **6. Reply:** one universal payload (`gpus[]` with temp, util, `power_watts` + `power_limit`, clocks, `coreoffset`, VRAM, ...). The dashboard combines used/limit watts for display. The log's "Stats source" line shows where each part came from.

Value meaning on the dashboard: `0` = intentionally not read (passthrough / `BLOCK_LIST`), `-1` = read failed, `--` = not reported.

## USER FLAG DESCRIPTION (`/etc/rigcontrol/rigcontrol-agent.conf`, read live)

- `OSN_PRIMARY=1` use OctaSpace node (osn) metrics for GPU + CPU/memory; `0` ignores osn and collects locally.
- `OSN_ALLOW_MISSING_GPU_STATS=1` also fetch what osn leaves out and needs no `nvidia-smi` (live mem temp via gputemps, lspci/proc fallbacks); `0` skips that. The start-up read happens regardless.
- `DOCKER_SKIP_GPU_STATS=0` (default off) skip GPU stats while a non-miner container is running. Passthrough always skips.
- `OVERRIDE_LIST=""` docker images that are "GPU stats safe" and ignored by the docker rule (keyword match anywhere in the image name, case-insensitive).
- `BLOCK_LIST=""` docker images that ALWAYS skip GPU stats while running (same keyword match as `OVERRIDE_LIST`).
- `STATS_DB_ENABLED`, `STATS_DB_MAX_HISTORY_DAYS`, `STATS_DB_INTERVAL_SECONDS` local stats history.
- `MIN_TELEMETRY_PULL_INTERVAL_SECONDS=5` minimum gap between telemetry pulls.
- `CPU_SERVICE_NAME`, `GPU_SERVICE_NAME`, `AUX_SERVICE_NAME`, `WATCHDOG_SERVICE_NAME` custom agent service names for dashboard control.
- `CUSTOM_MINER_BIN_GPU` / `_CPU` / `_AUX` custom miner binaries to detect.
- `<NAME>_BIN` binary for a custom miner, keyed by the miner's own name (`CUSTOM_MINER` in `rig-gpu/cpu/aux.conf` or `.json`, sanitized to A-Z0-9_).
- `<NAME>_API_HOST` / `<NAME>_API_PORT` custom miner JSON stats API (e.g. `KERYX_MINER_API_PORT=3338`, `SUPRMINER_NEPTUNE_API_PORT=4068`).
- `<NAME>_LOG_PATH` custom miner log file to scrape for stats when there is no API.
- `<NAME>_LOG_STYLE` how that log is read: `blocks` counts keryxd-style "Accepted N blocks"; unset uses generic hashrate scraping.
- `EXCLUDE_FROM_TOTALS = True` (in `rigcontrol_telemetry.sh`) leaves a dashboard host out of the status totals.

## Setup

1. install python on a client worker...

```
sudo apt update; sudo apt install -y python3 python3-venv ca-certificates
```

2. download the needed files:
   - [rigcontrol-agent-local.sh](rigcontrol-agent-local.sh)
   - [rigcontrol_agent.sh](rigcontrol_agent.sh)
   - [rigcontrol_agent-service.sh](rigcontrol_agent-service.sh)
   - [rigcontrol_telemetry.sh](rigcontrol_telemetry.sh)
   - [rigcontrol_cmd.sh](rigcontrol_cmd.sh)
   - [generate-copy-paste-update.bat](generate-copy-paste-update.bat)
3. set the server details in [rigcontrol-agent-local.sh](rigcontrol-agent-local.sh)
4. for custom service names set them in [rigcontrol-agent-local.sh](rigcontrol-agent-local.sh) -- 'AUX_SERVICE_NAME=keryxd.service'
5. install / update
   - run 'generate-copy-paste-update.bat' to create/update 'copy-paste-update.sh'
   - open a ssh session on a worker (on a windows machine use putty or similar ssh client)
   - copy/paste the contents of 'copy-paste-update.sh' into a worker ssh session and press enter to write the files and start/restart the agent

'EXCLUDE_FROM_TOTALS = True' in [rigcontrol_telemetry.sh](rigcontrol_telemetry.sh) for dashboard host to not be included in status totals, select

Useful commands:

show service status:

```bash
systemctl status rigcontrol-agent.service --no-pager
```

follow the agent log:

```bash
journalctl -u rigcontrol-agent.service -f
```

ctrl+c to break/exit

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

[rigcontrol-agent-local-keryxd.sh](rigcontrol-agent-local-keryxd.sh)... keryxd node: aux service name,binary location,log,log type

```
sudo tee /etc/rigcontrol/rigcontrol-agent.conf > /dev/null <<'EOF'
# ===== SERVER SETTINGS (dashboard server MQTT broker) =====
BROKER_HOST=10.10.0.10
BROKER_PORT=1883
BROKER_USER=admin
BROKER_PASS=********************
MIN_TELEMETRY_PULL_INTERVAL_SECONDS=5
# ===== END SERVER SETTINGS =====
# ===== USER FLAG DESCRIPTION (rigcontrol-agent.conf, read live) =====
# BROKER_HOST / BROKER_PORT / BROKER_USER / BROKER_PASS: MQTT broker (dashboard server) the agent connects to
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
```

[rigcontrol-agent-local.sh](rigcontrol-agent-local.sh)... KERYX_MINER_API

```
sudo tee /etc/rigcontrol/rigcontrol-agent.conf > /dev/null <<'EOF'
# ===== SERVER SETTINGS (dashboard server MQTT broker) =====
BROKER_HOST=10.10.0.10
BROKER_PORT=1883
BROKER_USER=admin
BROKER_PASS=**********
MIN_TELEMETRY_PULL_INTERVAL_SECONDS=5
# ===== END SERVER SETTINGS =====
# ===== USER FLAG DESCRIPTION (rigcontrol-agent.conf, read live) =====
# BROKER_HOST / BROKER_PORT / BROKER_USER / BROKER_PASS: MQTT broker (dashboard server) the agent connects to
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
