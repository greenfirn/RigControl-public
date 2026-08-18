sudo mkdir -p /etc/rigcontrol /var/lib/rigcontrol /run/rigcontrol
sudo tee /etc/rigcontrol/rigcontrol-agent.conf > /dev/null <<'EOF'
BROKER_HOST=10.10.0.10
BROKER_PORT=1883
BROKER_USER=admin
BROKER_PASS=**********
# comma seperated list of gpu stats safe images
OVERRIDE_LIST="miner/miner:latest"
STATS_DB_ENABLED=true
# How many days of local telemetry history to keep before old rows are pruned
STATS_DB_MAX_HISTORY_DAYS=7
STATS_DB_INTERVAL_SECONDS=90
# Minimum seconds between telemetry pulls, prevents overlapping collection calls
MIN_TELEMETRY_PULL_INTERVAL_SECONDS=5
KERYX_MINER_API_HOST=127.0.0.1
KERYX_MINER_API_PORT=3338
KERYX_MINERX_API_HOST=127.0.0.1
KERYX_MINERX_API_PORT=3338
EOF
sudo systemctl restart rigcontrol-agent.service
