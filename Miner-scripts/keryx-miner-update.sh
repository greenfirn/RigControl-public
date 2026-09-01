sudo tee /usr/local/bin/keryx-miner-update.sh > /dev/null <<'EOF'
#!/bin/bash
set -Eeuo pipefail

# Bump this to update keryx-miner - the download URL/zip/binary names below are all built
# from it, so this is the only line that needs to change between updates.
VERSION="v0.5.4-PoM"

# Where keryx-miner lives on this rig - matches keryx-miner.service's WorkingDirectory/ExecStart.
INSTALL_DIR="/opt/miners/keryx-miner"

ZIP="keryx-miner-${VERSION}-linux-amd64.zip"
URL="https://github.com/Keryx-Labs/keryx-miner/releases/download/${VERSION}/${ZIP}"

sudo mkdir -p "$INSTALL_DIR"

echo "$(date): stopping keryx-miner.service..."
sudo systemctl stop keryx-miner.service

echo "$(date): waiting for keryx-miner.service to fully stop..."
while systemctl is-active --quiet keryx-miner.service; do
    echo "$(date): keryx-miner.service still active - waiting 5s..."
    sleep 5
done
echo "$(date): keryx-miner.service stopped."

cd "$INSTALL_DIR"
echo "$(date): downloading $URL..."
sudo wget -O "$ZIP" "$URL"
sudo unzip -o "$ZIP"
sudo rm -v "$ZIP"

echo "$(date): installed version:"
"$INSTALL_DIR/keryx-miner" --version

echo "$(date): starting keryx-miner.service..."
sudo systemctl start keryx-miner.service

echo "$(date): done - tailing logs (Ctrl+C to exit)..."
journalctl -u keryx-miner.service -f
EOF
sudo chmod +x /usr/local/bin/keryx-miner-update.sh
sudo /usr/local/bin/keryx-miner-update.sh
