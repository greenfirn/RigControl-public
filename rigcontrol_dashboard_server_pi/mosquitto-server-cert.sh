sudo tee mosquitto-server-cert.sh > /dev/null <<'EOF'
#!/bin/bash
# TLS, see mosquitto-tls-setup.txt
# Creates the CA and the broker (server) certificate: sudo bash mosquitto-server-cert.sh <dashboard-server-ip> [more ips or hostnames]
# run it from the parent folder of mosquitto, certificates go to ./mosquitto/config/certs
# <dashboard-server-ip> = the ip workers use to reach the broker, 127.0.0.1 is always added. Output: ca.crt ca.key server.crt server.key
# CERT_DIR=/path/to/certs overrides the certificate folder (windows git bash: CERT_DIR=/c/mosquitto-certs bash mosquitto-server-cert.sh <ip>)
set -e
if [ $# -lt 1 ]; then
    echo "usage: sudo $0 <dashboard-server-ip> [more ips or hostnames]   (run from the parent folder of mosquitto)"
    exit 1
fi
IP="$1"
SAN="IP:$IP,IP:127.0.0.1"
shift
for A in "$@"; do
    if [[ "$A" =~ ^[0-9.]+$ ]]; then SAN="$SAN,IP:$A"; else SAN="$SAN,DNS:$A"; fi
done
CERT_DIR="${CERT_DIR:-$PWD/mosquitto/config/certs}"
if [ -f "$CERT_DIR/ca.key" ] || [ -f "$CERT_DIR/server.crt" ]; then
    echo "certificates already exist in $CERT_DIR, not overwriting (workers would need the new ca.crt). remove the files first to recreate them"
    exit 1
fi
openssl version > /dev/null 2>&1 || (apt update && apt install -y openssl)
mkdir -p "$CERT_DIR" && cd "$CERT_DIR"
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -subj "/CN=RigControl MQTT CA" -out ca.crt
openssl genrsa -out server.key 2048
openssl req -new -key server.key -subj "/CN=$IP" -out server.csr
printf "subjectAltName=$SAN" > san.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 825 -sha256 -extfile san.ext
chown 1883:1883 server.key server.crt ca.crt 2>/dev/null || echo "note: chown 1883:1883 failed, run it manually on server.key server.crt ca.crt"
chmod 640 server.key
echo "created certificates for $SAN in $CERT_DIR (keep ca.key private, only ca.crt goes to workers)"
EOF
sudo chmod +x mosquitto-server-cert.sh
