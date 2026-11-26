sudo mkdir -p /etc/rigcontrol
sudo tee /etc/rigcontrol/rigcontrol-agent.conf > /dev/null <<'EOF'
BROKER_HOST=127.0.0.1
BROKER_PORT=8883
BROKER_USER=admin
BROKER_PASS=CHANGE_ME
# MQTT_TLS (default 1): 1 = encrypted connection to the broker (BROKER_PORT = broker TLS port, 8883), 0 = plain MQTT (BROKER_PORT 1883)
# --- BASIC TLS: encrypted connection on the broker's TLS port. for verified TLS copy ca.crt to the worker and uncomment MQTT_CA_FILE (mosquitto-tls-setup.txt) ---
MQTT_TLS=1
#MQTT_CA_FILE=/etc/rigcontrol/ca.crt
# --- END BASIC TLS ---
# --- ADVANCED TLS: client certificate (mutual TLS), uncomment when the broker has require_certificate true (mosquitto-tls-advanced.txt) ---
#MQTT_CLIENT_CERT=/etc/rigcontrol/client.crt
#MQTT_CLIENT_KEY=/etc/rigcontrol/client.key
# --- END ADVANCED TLS ---
# --- TEST TLS: skip certificate and hostname verification, no ca.crt needed on the worker. comment out when verified TLS is used ---
MQTT_TLS_INSECURE=1
# --- END TEST TLS ---
# Minimum seconds between telemetry pulls, prevents overlapping collection calls
MIN_TELEMETRY_PULL_INTERVAL_SECONDS=5
EOF
