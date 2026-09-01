sudo tee /usr/local/bin/keryx-node-update.sh > /dev/null <<'EOF'
#!/bin/bash
set -Eeuo pipefail

# Bump this to update keryx-node - the download URL/zip/binary names below are all built
# from it, so this is the only line that needs to change between updates.
VERSION="v1.5.8-PoM"

# Where keryx-node lives on this rig - matches keryxd.service's WorkingDirectory/ExecStart.
INSTALL_DIR="/opt/miners"

ZIP="keryx-node-${VERSION}-linux-amd64.zip"
URL="https://github.com/Keryx-Labs/keryx-node/releases/download/${VERSION}/${ZIP}"

echo "$(date): stopping keryxd.service..."
sudo systemctl stop keryxd.service

echo "$(date): waiting for keryxd.service to fully stop..."
while systemctl is-active --quiet keryxd.service; do
    echo "$(date): keryxd.service still active - waiting 5s..."
    sleep 5
done
echo "$(date): keryxd.service stopped."

cd "$INSTALL_DIR"
echo "$(date): downloading $URL..."
sudo wget -O "$ZIP" "$URL"
sudo unzip -o "$ZIP"
sudo rm -v "$ZIP"

echo "$(date): installed version:"
"$INSTALL_DIR/keryx-node/keryxd" --version

echo "$(date): starting keryxd.service..."
sudo systemctl start keryxd.service

echo "$(date): done - tailing logs (Ctrl+C to exit)..."
journalctl -u keryxd.service -f
EOF
sudo chmod +x /usr/local/bin/keryx-node-update.sh
sudo /usr/local/bin/keryx-node-update.sh
