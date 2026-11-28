################################################################################
# WARNING - FOR TESTING / EXPERIMENTAL PURPOSES ONLY
# OctaSpace gives a clear warning about mining outside of its own idle mining
# platform (idle jobs). A miner or other heavy workload started on a node any
# other way keeps running during a rental and takes the GPU, CPU or memory the
# renter paid for, and a node caught doing this can be taken off the marketplace.
# https://docs.octa.space/idle-jobs  (section: Do not run workloads outside idle jobs)
# Use at your own risk.
################################################################################
sudo tee /usr/local/bin/keryx-miner-update.sh > /dev/null <<'EOF'
#!/bin/bash
################################################################################
# WARNING - FOR TESTING / EXPERIMENTAL PURPOSES ONLY
# OctaSpace gives a clear warning about mining outside of its own idle mining
# platform (idle jobs). A miner or other heavy workload started on a node any
# other way keeps running during a rental and takes the GPU, CPU or memory the
# renter paid for, and a node caught doing this can be taken off the marketplace.
# https://docs.octa.space/idle-jobs  (section: Do not run workloads outside idle jobs)
# Use at your own risk.
################################################################################
set -Eeuo pipefail

VERSION="v0.5.4-PoM"

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
