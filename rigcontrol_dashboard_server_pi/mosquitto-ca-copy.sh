sudo tee ~/ha-docker/mosquitto-ca-copy.sh > /dev/null <<'EOF'
#!/bin/bash
# TLS, see mosquitto-tls-setup.txt
# Copies the broker's public ca.crt to one or more workers: bash mosquitto-ca-copy.sh <root-path> user@worker [user@worker2 ...]
# <root-path> = the folder that holds mosquitto/ (e.g. ~/ha-docker), ca.crt is read from <root-path>/mosquitto/config/certs
# Run it as your normal user (not sudo) so your ssh keys are used. Installs /etc/rigcontrol/ca.crt on each worker.
# CERT_DIR=/path/to/certs overrides the certificate folder
set -e
if [ $# -lt 2 ]; then
    echo "usage: $0 <root-path> user@worker [user@worker2 ...]   (e.g. ~/ha-docker user@192.168.1.50)"
    exit 1
fi
ROOT="$1"
shift
CERT_DIR="${CERT_DIR:-$ROOT/mosquitto/config/certs}"
if [ ! -f "$CERT_DIR/ca.crt" ]; then
    echo "$CERT_DIR/ca.crt not found (see mosquitto-tls-setup.txt step 1)"
    exit 1
fi
for TARGET in "$@"; do
    scp "$CERT_DIR/ca.crt" "$TARGET:/tmp/ca.crt"
    ssh -t "$TARGET" "sudo mkdir -p /etc/rigcontrol && sudo mv /tmp/ca.crt /etc/rigcontrol/ca.crt"
    echo "copied ca.crt to $TARGET:/etc/rigcontrol/ca.crt"
done
EOF
sudo chmod +x ~/ha-docker/mosquitto-ca-copy.sh
