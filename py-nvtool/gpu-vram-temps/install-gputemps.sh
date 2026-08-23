#!/bin/bash
# Builds and installs 'gputemps' (github.com/ThomasBaruzier/gddr6-core-junction-vram-temps)
# to /usr/local/bin/gputemps, where rigcontrol_telemetry.sh / rigcontrol_telemetry-exclude.sh
# and nvtool.py already look for it as an optional VRAM-temp fallback for GPUs where
# nvidia-smi's temperature.memory is unsupported (i.e. virtually all GeForce cards).
set -e

BUILD_DIR="$HOME/gddr6-core-junction-vram-temps"

echo "== Installing build dependencies =="
sudo apt-get update -qq
sudo apt-get install -y gcc make libpci-dev nvidia-cuda-toolkit

echo "== Cloning gputemps source =="
if [ -d "$BUILD_DIR" ]; then
    echo "Existing $BUILD_DIR found - pulling latest instead of a fresh clone."
    git -C "$BUILD_DIR" pull
else
    git clone https://github.com/ThomasBaruzier/gddr6-core-junction-vram-temps "$BUILD_DIR"
fi

echo "== Building =="
cd "$BUILD_DIR"
make

echo "== Installing to /usr/local/bin/gputemps =="
sudo cp -v gputemps /usr/local/bin/gputemps
sudo chmod +x /usr/local/bin/gputemps

echo "== Self-test (sudo gputemps --once --json) =="
sudo /usr/local/bin/gputemps --once --json

echo ""
echo "Done. rigcontrol_telemetry.sh and nvtool.py will pick this up automatically on their next run -"
echo "no service restart strictly required, but 'sudo systemctl restart rigcontrol-agent.service' will"
echo "make the dashboard's Stats page reflect it sooner."
