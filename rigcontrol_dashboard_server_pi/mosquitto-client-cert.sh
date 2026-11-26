#!/bin/bash
# advanced TLS, see mosquitto-tls-advanced.txt
# Creates a client certificate (mutual TLS) signed by the broker CA: sudo ./mosquitto-client-cert.sh <name>
# <name> = worker hostname, or rigcontrol-dashboard for the dashboard server. Output: <certs>/clients/<name>.crt + .key
# CERT_DIR=/path/to/certs overrides the default ~/ha-docker/mosquitto/config/certs (windows git bash: CERT_DIR=/c/mosquitto-certs bash mosquitto-client-cert.sh <name>)
set -e
NAME="$1"
if [ -z "$NAME" ]; then
    echo "usage: sudo $0 <name>   (e.g. 5900x-3-4070tis, or rigcontrol-dashboard)"
    exit 1
fi
OWNER="${SUDO_USER:-$USER}"
OWNER_HOME=$(getent passwd "$OWNER" 2>/dev/null | cut -d: -f6 || true)
OWNER_HOME="${OWNER_HOME:-$HOME}"
CERT_DIR="${CERT_DIR:-$OWNER_HOME/ha-docker/mosquitto/config/certs}"
OUT="$CERT_DIR/clients"
if [ ! -f "$CERT_DIR/ca.crt" ] || [ ! -f "$CERT_DIR/ca.key" ]; then
    echo "ca.crt / ca.key not found in $CERT_DIR (see mosquitto-tls-setup.txt step 1)"
    exit 1
fi
mkdir -p "$OUT"
openssl genrsa -out "$OUT/$NAME.key" 2048
openssl req -new -key "$OUT/$NAME.key" -subj "/CN=$NAME" -out "$OUT/$NAME.csr"
printf "keyUsage=digitalSignature\nextendedKeyUsage=clientAuth\n" > "$OUT/$NAME.ext"
openssl x509 -req -in "$OUT/$NAME.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
    -out "$OUT/$NAME.crt" -days 825 -sha256 -extfile "$OUT/$NAME.ext"
rm -f "$OUT/$NAME.csr" "$OUT/$NAME.ext"
chown "$OWNER" "$OUT/$NAME.key" "$OUT/$NAME.crt" 2>/dev/null || true
chmod 600 "$OUT/$NAME.key"
chmod 644 "$OUT/$NAME.crt"
openssl verify -CAfile "$CERT_DIR/ca.crt" -purpose sslclient "$OUT/$NAME.crt"
echo "created $OUT/$NAME.crt and $OUT/$NAME.key"
