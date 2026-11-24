sudo mkdir -p /etc/rigcontrol /var/lib/rigcontrol /run/rigcontrol
sudo tee /etc/rigcontrol/rigcontrol-agent.conf > /dev/null <<'EOF'
BROKER_HOST=10.10.0.10
BROKER_PORT=1883
BROKER_USER=admin
BROKER_PASS=**********
# comma seperated list of gpu stats safe images
OVERRIDE_LIST=""
# gpu stats will still be collected for docker image names that include a known miner name
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
#KERYX_MINER_SUPR_BIN=/opt/miners/custom/keryx-miner-supr/current/keryx-miner-supr
KERYX_MINER_SUPR_API_HOST=127.0.0.1
KERYX_MINER_SUPR_API_PORT=3338
#KERYXD_BIN=/opt/miners/keryx-node/keryxd
#KERYXD_LOG_PATH=/run/rigcontrol/aux_miner.log
#KERYXD_LOG_STYLE=blocks
EOF
