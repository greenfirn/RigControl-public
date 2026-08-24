sudo tee /usr/local/bin/gpu_reset_poststop.sh > /dev/null <<'EOF'
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
echo "[GPU-RESET] Starting GPU reset sequence..."
POWER_LIMIT=""
if [ $# -eq 1 ]; then
    if [[ $1 =~ ^[0-9]+$ ]] && [ $1 -gt 0 ]; then
        POWER_LIMIT=$1
        echo "[GPU-RESET] Power limit specified: ${POWER_LIMIT}W"
    else
        echo "[GPU-RESET] Warning: Invalid power limit '$1'. Must be integer > 0. Using default."
    fi
fi
command_exists() {
    command -v "$1" >/dev/null 2>&1
}
reset_nvidia_gpus() {
    echo "[GPU-RESET] Detected NVIDIA GPU(s)"
    for i in {1..10}; do
        if nvidia-smi >/dev/null 2>&1; then break; fi
        sleep 1
    done
    for id in $(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null); do
        echo "[GPU-RESET] Resetting NVIDIA GPU $id"
        nvidia-smi -i "$id" -rgc >/dev/null 2>&1
        nvidia-smi -i "$id" -rmc >/dev/null 2>&1
        if [ -n "$POWER_LIMIT" ]; then
            echo "[GPU-RESET] Setting NVIDIA GPU $id power limit → ${POWER_LIMIT}W (user specified)"
            nvidia-smi -i "$id" --power-limit="$POWER_LIMIT" >/dev/null 2>&1
        else
            default_pl=$(nvidia-smi -i "$id" --query-gpu=power.default_limit --format=csv,noheader,nounits 2>/dev/null)
            if [ -n "$default_pl" ]; then
                echo "[GPU-RESET] Setting NVIDIA GPU $id power limit → ${default_pl}W (default)"
                nvidia-smi -i "$id" --power-limit="$default_pl" >/dev/null 2>&1
            else
                echo "[GPU-RESET] Skipping NVIDIA GPU $id power limit (no default PL found)"
            fi
        fi
    done
}
if command_exists "nvidia-smi" && nvidia-smi >/dev/null 2>&1; then
    reset_nvidia_gpus
else
    echo "[GPU-RESET] No GPU detected"
fi
echo "[GPU-RESET] Complete."
EOF
sudo chmod +x /usr/local/bin/gpu_reset_poststop.sh
sudo /usr/local/bin/gpu_reset_poststop.sh
sudo /usr/local/bin/gpu_reset_poststop.sh 150
