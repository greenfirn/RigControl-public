sudo tee mosquitto-ca-copy.sh > /dev/null <<'EOF'
#!/bin/bash
# TLS, see mosquitto-tls-setup.md
# Copies the broker's public ca.crt to one or more workers: bash mosquitto-ca-copy.sh user@worker [user@worker2 ...]
# run it from the parent folder of mosquitto, ca.crt is read from ./mosquitto/config/certs
# Run it as your normal user (not sudo) so your ssh keys are used. Installs /etc/rigcontrol/ca.crt on each worker.
# CERT_DIR=/path/to/certs overrides the certificate folder
set -e
if [ $# -lt 1 ]; then
    echo "usage: $0 user@worker [user@worker2 ...]   (run from the parent folder of mosquitto)"
    exit 1
fi
CERT_DIR="${CERT_DIR:-$PWD/mosquitto/config/certs}"
if [ ! -f "$CERT_DIR/ca.crt" ]; then
    echo "$CERT_DIR/ca.crt not found (see mosquitto-tls-setup.md step 1)"
    exit 1
fi
for TARGET in "$@"; do
    scp "$CERT_DIR/ca.crt" "$TARGET:/tmp/ca.crt"
    ssh -t "$TARGET" "sudo mkdir -p /etc/rigcontrol && sudo mv /tmp/ca.crt /etc/rigcontrol/ca.crt"
    echo "copied ca.crt to $TARGET:/etc/rigcontrol/ca.crt"
done
EOF
sudo chmod +x mosquitto-ca-copy.sh
