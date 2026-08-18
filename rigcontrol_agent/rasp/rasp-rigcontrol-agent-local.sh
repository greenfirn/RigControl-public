sudo mkdir -p /etc/rigcontrol
sudo tee /etc/rigcontrol/rigcontrol-agent.conf > /dev/null <<'EOF'
BROKER_HOST=127.0.0.1
BROKER_PORT=1883
BROKER_USER=admin
BROKER_PASS=*************
# Minimum seconds between telemetry pulls, prevents overlapping collection calls
MIN_TELEMETRY_PULL_INTERVAL_SECONDS=5
EOF
