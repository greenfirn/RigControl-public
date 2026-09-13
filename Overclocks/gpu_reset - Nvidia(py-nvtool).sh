# -- write gpu reset script --
# https://github.com/Akisoft41/py-nvtool/releases

sudo tee /usr/local/bin/gpu_reset_poststop.sh > /dev/null <<'EOF'
#!/bin/bash

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo "[GPU-RESET] Starting GPU reset sequence..."

# Power limit argument(s): either one value (applied to every GPU) or a
# space-separated list, one value per GPU, in nvidia-smi GPU index order
# (0, 1, 2, ...) - the same order nvtop lists GPUs in and the same order
# the miner enumerates/binds GPUs in.
#   0  in place of a value -> set that GPU to its own default power limit
#   1  in place of a value -> skip that GPU entirely (leave power limit untouched)
# e.g.:
#   gpu_reset_poststop.sh 150
#   gpu_reset_poststop.sh 150 200 180
#   gpu_reset_poststop.sh 150 0 100 1 320
POWER_LIMITS=()
for arg in "$@"; do
    if [[ $arg =~ ^[0-9]+$ ]]; then
        POWER_LIMITS+=("$arg")
    else
        echo "[GPU-RESET] Warning: Invalid power limit '$arg'. Must be a non-negative integer (0 = default, 1 = skip). Skipping."
    fi
done

if [ ${#POWER_LIMITS[@]} -eq 1 ]; then
    echo "[GPU-RESET] Power limit specified: ${POWER_LIMITS[0]}W (applies to all GPUs)"
elif [ ${#POWER_LIMITS[@]} -gt 1 ]; then
    echo "[GPU-RESET] Per-GPU power limits specified: ${POWER_LIMITS[*]} (by GPU index, in order)"
fi

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to reset NVIDIA GPUs
reset_nvidia_gpus() {
    echo "[GPU-RESET] Detected NVIDIA GPU(s)"

    # Wait for NVIDIA driver to become available
    for i in {1..10}; do
        if nvidia-smi >/dev/null 2>&1; then break; fi
        sleep 1
    done

    local gpu_pos=0
    for id in $(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null); do
        echo "[GPU-RESET] Resetting NVIDIA GPU $id"

        # Reset core/mem clocks and offsets
        py-nvtool -i "$id" --setcore 0 --setmem 0 --setcoreoffset 0 --setmemoffset 0

        # Determine which power limit applies to this GPU:
        #   - 1 at this GPU's position -> skip entirely, leave power limit untouched
        #   - 0 at this GPU's position, or no value given -> use the GPU's own default limit
        #   - multiple values given -> positional (by GPU index order)
        #   - exactly one value given -> that same value for every GPU
        gpu_power_limit=""
        gpu_skip=false
        if [ ${#POWER_LIMITS[@]} -gt 1 ]; then
            entry="${POWER_LIMITS[$gpu_pos]:-}"
            if [ "$entry" == "1" ]; then
                gpu_skip=true
            elif [ -n "$entry" ] && [ "$entry" != "0" ]; then
                gpu_power_limit="$entry"
            fi
        elif [ ${#POWER_LIMITS[@]} -eq 1 ]; then
            if [ "${POWER_LIMITS[0]}" == "1" ]; then
                gpu_skip=true
            elif [ "${POWER_LIMITS[0]}" != "0" ]; then
                gpu_power_limit="${POWER_LIMITS[0]}"
            fi
        fi

        if [ "$gpu_skip" == "true" ]; then
            echo "[GPU-RESET] GPU $id power limit set to 1 - skipping power limit change"
        elif [ -n "$gpu_power_limit" ]; then
            echo "[GPU-RESET] Setting NVIDIA GPU $id power limit → ${gpu_power_limit}W (user specified)"
            py-nvtool -i "$id" --setpl "$gpu_power_limit"
        else
            # Query default safe power limit
            default_pl=$(nvidia-smi -i "$id" --query-gpu=power.default_limit --format=csv,noheader,nounits 2>/dev/null)

            if [ -n "$default_pl" ]; then
                echo "[GPU-RESET] Setting NVIDIA GPU $id power limit → ${default_pl}W (default)"
                py-nvtool -i "$id" --setpl "$default_pl"
            else
                echo "[GPU-RESET] Skipping NVIDIA GPU $id power limit (no default PL found)"
            fi
        fi

        gpu_pos=$((gpu_pos + 1))
    done
}

# Main detection
if command_exists "nvidia-smi" && nvidia-smi >/dev/null 2>&1; then
    reset_nvidia_gpus
else
    echo "[GPU-RESET] No GPU detected"
fi

echo "[GPU-RESET] Complete."
EOF

# Make it executable
sudo chmod +x /usr/local/bin/gpu_reset_poststop.sh

# test proper power limit etc is applied
sudo /usr/local/bin/gpu_reset_poststop.sh

# to apply the same custom power limit (150W) to every GPU
sudo /usr/local/bin/gpu_reset_poststop.sh 150

# to apply a different power limit per GPU, in nvidia-smi/nvtop/miner GPU
# index order (GPU0=150W, GPU1=200W, GPU2=180W)
sudo /usr/local/bin/gpu_reset_poststop.sh 150 200 180

# GPU0=150W, GPU1=default power limit, GPU2=100W, GPU3=skipped entirely
# (left untouched), GPU4=320W
sudo /usr/local/bin/gpu_reset_poststop.sh 150 0 100 1 320
