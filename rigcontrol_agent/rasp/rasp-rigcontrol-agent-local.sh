sudo mkdir -p /etc/rigcontrol
[ -s /etc/rigcontrol/ca.crt ] || echo "WARNING: /etc/rigcontrol/ca.crt is missing - copy the broker's ca.crt there once (see mosquitto-tls-setup.txt), otherwise the agent cannot verify the broker"
sudo tee /etc/rigcontrol/rigcontrol-agent.conf > /dev/null <<'EOF'
BROKER_HOST=127.0.0.1
BROKER_PORT=8883
BROKER_USER=admin
BROKER_PASS=*************
# MQTT_TLS (default 1): 1 = encrypted connection to the broker (BROKER_PORT = broker TLS port, 8883), 0 = plain MQTT (BROKER_PORT 1883)
MQTT_TLS=1
MQTT_CA_FILE=/etc/rigcontrol/ca.crt
#MQTT_TLS_INSECURE=0
# Minimum seconds between telemetry pulls, prevents overlapping collection calls
MIN_TELEMETRY_PULL_INTERVAL_SECONDS=5
EOF
