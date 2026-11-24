[Get started](../README.md#get-started)

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

## Agent flags (`/etc/rigcontrol/rigcontrol-agent.conf`, read live)

- `OSN_PRIMARY=1` use OctaSpace node (osn) metrics for GPU + CPU/memory; `0` ignores osn and collects locally.
- `OSN_ALLOW_MISSING_GPU_STATS=1` also fetch what osn leaves out and needs no `nvidia-smi` (live mem temp via gputemps, lspci/proc fallbacks); `0` skips that. The start-up read happens regardless.
- `DOCKER_SKIP_GPU_STATS=0` (default off) skip GPU stats while a non-miner container is running. Passthrough always skips.
- `OVERRIDE_LIST=""` docker images that are "GPU stats safe" and ignored by the docker rule (keyword match anywhere in the image name, case-insensitive).
- `BLOCK_LIST=""` docker images that ALWAYS skip GPU stats while running (same keyword match as `OVERRIDE_LIST`).
- `MIN_TELEMETRY_PULL_INTERVAL_SECONDS=5` minimum gap between telemetry pulls.
- `STATS_DB_ENABLED`, `STATS_DB_MAX_HISTORY_DAYS`, `STATS_DB_INTERVAL_SECONDS` local stats history.
- `CPU_SERVICE_NAME`, `GPU_SERVICE_NAME`, `AUX_SERVICE_NAME`, `WATCHDOG_SERVICE_NAME` custom agent service names for dashboard control.
- `CUSTOM_MINER_BIN_GPU` / `_CPU` / `_AUX` custom miner binaries to detect.
- `<NAME>_BIN` binary for a custom miner, keyed by the miner's own name (`CUSTOM_MINER` in `rig-gpu/cpu/aux.conf` or `.json`, sanitized to A-Z0-9_).
- `<NAME>_API_HOST` / `<NAME>_API_PORT` custom miner JSON stats API (e.g. `KERYX_MINER_API_PORT=3338`, `SUPRMINER_NEPTUNE_API_PORT=4068`).
- `<NAME>_LOG_PATH` custom miner log file to scrape for stats when there is no API.
- `<NAME>_LOG_STYLE` how that log is read: `blocks` counts keryxd-style "Accepted N blocks"; unset uses generic hashrate scraping.
- `EXCLUDE_FROM_TOTALS = True` (in `rigcontrol_telemetry.sh`) leaves a dashboard host out of the status totals.

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
1. install python on a client rig...
```
sudo apt update; sudo apt install -y python3 python3-venv ca-certificates
```
2. download the needed files: [rigcontrol-agent-local.sh](rigcontrol-agent-local.sh), [rigcontrol_agent.sh](rigcontrol_agent.sh), [rigcontrol_agent-service.sh](rigcontrol_agent-service.sh), [rigcontrol_telemetry.sh](rigcontrol_telemetry.sh), [rigcontrol_cmd.sh](rigcontrol_cmd.sh), [generate-copy-paste-update.bat](generate-copy-paste-update.bat)

3. set the server details in [rigcontrol-agent-local.sh](rigcontrol-agent-local.sh)

4. for custom service names set them in [rigcontrol-agent-local.sh](rigcontrol-agent-local.sh) -- 'AUX_SERVICE_NAME=keryxd.service'

5. 'generate-copy-paste-update.bat -> copy-paste-update.sh' then copy/paste contents to write the files to a rig

'EXCLUDE_FROM_TOTALS = True' in [rigcontrol_telemetry.sh](rigcontrol_telemetry.sh) for dashboard host to not be included in status totals, select

![test-windows](../images/Screenshot-test-windows.png)

[rigcontrol-agent-local-keryxd.sh](rigcontrol-agent-local-keryxd.sh)... keryxd node: aux service name,binary location,log,log type
```
sudo tee /etc/rigcontrol/rigcontrol-agent.conf > /dev/null <<'EOF'
BROKER_HOST=10.10.0.10
BROKER_PORT=1883
BROKER_USER=admin
BROKER_PASS=********************
# comma separated list of gpu stats safe images (keyword match anywhere in the image name)
OVERRIDE_LIST="miner/miner:latest"
# comma separated list of docker images (keyword match anywhere in the image name, same as OVERRIDE_LIST) that ALWAYS skip gpu stats while running
BLOCK_LIST=""
STATS_DB_ENABLED=true
# How many days of local telemetry history to keep before old rows are pruned
STATS_DB_MAX_HISTORY_DAYS=7
STATS_DB_INTERVAL_SECONDS=90
# Minimum seconds between telemetry pulls, prevents overlapping collection calls
MIN_TELEMETRY_PULL_INTERVAL_SECONDS=5
# Use OctaSpace node (osn) metrics for GPU + CPU/memory stats - no local GPU fallback (0 = ignore osn)
OSN_PRIMARY=1
# osn leaves some GPU fields out (mem temp/util, vbios, power min/max, partner). 1 = also fetch mem temp live (gputemps) + lspci/proc fallbacks; 0 = skip those. Static ones (power limits, vbios, partner) are always cached from one full read at agent start
#OSN_ALLOW_MISSING_GPU_STATS=1
# Safety rule, off by default: 1 = skip GPU stats while a non-miner docker container is running (for diagnosis / new rigs). Passthrough always skips
#DOCKER_SKIP_GPU_STATS=0
#CPU_SERVICE_NAME=docker_events_cpu.service
#GPU_SERVICE_NAME=docker_events_gpu.service
AUX_SERVICE_NAME=keryxd.service
#WATCHDOG_SERVICE_NAME=rigcontrol_watchdog.service
#CUSTOM_MINER_BIN_GPU=/opt/miners/my-custom-miner/current/my-custom-miner
#CUSTOM_MINER_BIN_CPU=/opt/miners/my-custom-miner/current/my-custom-miner
CUSTOM_MINER_BIN_AUX=/opt/miners/keryx-node/keryxd
# Per-custom-miner overrides, keyed by the miner's own name (from CUSTOM_MINER
# in rig-gpu/cpu/aux.conf or .json, sanitized to A-Z0-9_) - <NAME>_BIN for the
# binary, <NAME>_API_HOST/<NAME>_API_PORT for a keryx-style JSON stats API,
# or <NAME>_LOG_PATH for log scraping (<NAME>_LOG_STYLE=blocks for
# keryxd-style "Accepted N blocks" counting instead of generic hashrate scraping)
KERYXD_LOG_PATH=/run/rigcontrol/aux_miner.log
KERYXD_LOG_STYLE=blocks
#KERYX_MINER_API_HOST=127.0.0.1
#KERYX_MINER_API_PORT=3338
EOF
```
[rigcontrol-agent-local.sh](rigcontrol-agent-local.sh)... KERYX_MINER_API
```
sudo tee /etc/rigcontrol/rigcontrol-agent.conf > /dev/null <<'EOF'
BROKER_HOST=10.10.0.10
BROKER_PORT=1883
BROKER_USER=admin
BROKER_PASS=**************
# comma separated list of gpu stats safe images (keyword match anywhere in the image name)
OVERRIDE_LIST="miner/miner:latest"
# comma separated list of docker images (keyword match anywhere in the image name, same as OVERRIDE_LIST) that ALWAYS skip gpu stats while running
BLOCK_LIST=""
STATS_DB_ENABLED=true
# How many days of local telemetry history to keep before old rows are pruned
STATS_DB_MAX_HISTORY_DAYS=7
STATS_DB_INTERVAL_SECONDS=90
# Minimum seconds between telemetry pulls, prevents overlapping collection calls
MIN_TELEMETRY_PULL_INTERVAL_SECONDS=5
# Use OctaSpace node (osn) metrics for GPU + CPU/memory stats - no local GPU fallback (0 = ignore osn)
OSN_PRIMARY=1
# osn leaves some GPU fields out (mem temp/util, vbios, power min/max, partner). 1 = also fetch mem temp live (gputemps) + lspci/proc fallbacks; 0 = skip those. Static ones (power limits, vbios, partner) are always cached from one full read at agent start
#OSN_ALLOW_MISSING_GPU_STATS=1
# Safety rule, off by default: 1 = skip GPU stats while a non-miner docker container is running (for diagnosis / new rigs). Passthrough always skips
#DOCKER_SKIP_GPU_STATS=0
#CPU_SERVICE_NAME=docker_events_cpu.service
#GPU_SERVICE_NAME=docker_events_gpu.service
#AUX_SERVICE_NAME=keryxd.service
#WATCHDOG_SERVICE_NAME=rigcontrol_watchdog.service
#CUSTOM_MINER_BIN_GPU=/opt/miners/my-custom-miner/current/my-custom-miner
#CUSTOM_MINER_BIN_CPU=/opt/miners/my-custom-miner/current/my-custom-miner
#CUSTOM_MINER_BIN_AUX=/opt/miners/my-custom-miner/current/my-custom-miner
# Per-custom-miner overrides, keyed by the miner's own name (from CUSTOM_MINER
# in rig-gpu/cpu/aux.conf or .json, sanitized to A-Z0-9_) - <NAME>_BIN for the
# binary, <NAME>_API_HOST/<NAME>_API_PORT for a keryx-style JSON stats API,
# or <NAME>_LOG_PATH for log scraping (<NAME>_LOG_STYLE=blocks for
# keryxd-style "Accepted N blocks" counting instead of generic hashrate scraping)
#KERYX_MINER_BIN=/opt/miners/keryx-miner/current/keryx-miner
KERYX_MINER_API_HOST=127.0.0.1
KERYX_MINER_API_PORT=3338
#KERYXD_BIN=/opt/miners/keryx-node/keryxd
#KERYXD_LOG_PATH=/run/rigcontrol/aux_miner.log
#KERYXD_LOG_STYLE=blocks
EOF
```
