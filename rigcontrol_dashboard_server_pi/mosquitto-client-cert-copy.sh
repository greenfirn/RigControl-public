sudo tee mosquitto-client-cert-copy.sh > /dev/null <<'EOF'
#!/bin/bash
# advanced TLS, see mosquitto-tls-advanced.txt
# Copies a worker's client certificate pair to the worker: bash mosquitto-client-cert-copy.sh <root-path> <name> [user@worker]
# <root-path> = the folder that holds mosquitto/ (e.g. ~/ha-docker), certificates are read from <root-path>/mosquitto/config/certs/clients
# <name> = the name used with mosquitto-client-cert.sh (the worker hostname). [user@worker] defaults to $USER@<name>.
# Run it as your normal user (not sudo) so your ssh keys are used. Installs /etc/rigcontrol/client.crt + client.key on the worker (key root-only).
# CERT_DIR=/path/to/certs overrides the certificate folder
set -e
if [ $# -lt 2 ]; then
    echo "usage: $0 <root-path> <name> [user@worker]   (e.g. ~/ha-docker 5900x-3-4070tis user@192.168.1.50)"
    exit 1
fi
ROOT="$1"
NAME="$2"
TARGET="${3:-$USER@$NAME}"
CERT_DIR="${CERT_DIR:-$ROOT/mosquitto/config/certs}"
OUT="$CERT_DIR/clients"
if [ ! -f "$OUT/$NAME.crt" ] || [ ! -f "$OUT/$NAME.key" ]; then
    echo "$OUT/$NAME.crt / $NAME.key not found (create them first: sudo bash mosquitto-client-cert.sh $ROOT $NAME)"
    exit 1
fi
scp "$OUT/$NAME.crt" "$OUT/$NAME.key" "$TARGET:/tmp/"
ssh -t "$TARGET" "sudo mkdir -p /etc/rigcontrol && sudo mv /tmp/$NAME.crt /etc/rigcontrol/client.crt && sudo mv /tmp/$NAME.key /etc/rigcontrol/client.key && sudo chown root:root /etc/rigcontrol/client.* && sudo chmod 600 /etc/rigcontrol/client.key"
echo "copied $NAME to $TARGET:/etc/rigcontrol/ (client.crt, client.key)"
EOF
sudo chmod +x mosquitto-client-cert-copy.sh
