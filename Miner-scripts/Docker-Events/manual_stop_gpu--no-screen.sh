sudo tee /usr/local/bin/manual_stop_gpu.sh > /dev/null <<'EOF'
#!/bin/bash
set -Eeuo pipefail
shopt -s inherit_errexit
echo "========================================"
echo "MANUAL MINER STOP SCRIPT"
echo "========================================"
# HARDCODED CONFIGURATION
echo "[init] Loading configuration..."
# Hardcoded paths
MINER_CONF="/etc/rigcontrol/miner.conf"
API_CONF="/etc/rigcontrol/api.conf"
CFG_FILE="/etc/rigcontrol/rig-gpu.conf"
BASE_DIR="/opt/miners"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$CFG_FILE" in
    *.json) RIG_GPU_JSON="$CFG_FILE" ;;
    *) RIG_GPU_JSON="${CFG_FILE%.conf}.json" ;;
esac
# Load miner paths environment
if [[ -f "$BASE_DIR/miner_paths.env" ]]; then
    echo "[init] Loading miner paths from: $BASE_DIR/miner_paths.env"
    source "$BASE_DIR/miner_paths.env"
else
    echo "[init] WARNING: miner_paths.env not found at $BASE_DIR/miner_paths.env"
    echo "[init] Miner binary locations may not be set correctly"
fi
# Check config files exist
[[ -f "$CFG_FILE" || -f "$RIG_GPU_JSON" ]] || {
    echo "Missing rig config: neither $CFG_FILE nor $RIG_GPU_JSON exists"
    exit 1
}
[[ -f "$MINER_CONF" ]] || {
    echo "Missing miner.conf: $MINER_CONF"
    exit 1
}
# Source libraries (only needed ones for stop)
for f in \
    "$SCRIPT_DIR/lib/00-get_rig_conf.sh" \
    "$SCRIPT_DIR/lib/02-load_configs.sh" \
    "$SCRIPT_DIR/lib/04-algo_config.sh"
do
    [[ -f "$f" ]] || { echo "Missing include: $f"; exit 1; }
    source "$f"
done
# Slot is fixed by which service instance this is - not user-configurable
SCREEN_NAME="gpu"
# Get OC settings from rig.conf
RESET_OC=$(get_rig_conf "RESET_OC" "0")
# Remove quotes if present
RESET_OC="${RESET_OC//\"/}"
# Convert to lowercase for comparison
RESET_OC="${RESET_OC,,}"
# Default to false if empty
: "${RESET_OC:=false}"
echo "Miner Name:      $MINER_NAME"
echo "Screen Session:  $SCREEN_NAME"
echo "Reset GPU on stop: $RESET_OC"
echo "========================================"
# PID-BASED ALIVE CHECK / KILL FUNCTIONS
is_miner_alive() {
    local pid_file="/run/rigcontrol/${SCREEN_NAME}_miner.pid"
    [[ -f "$pid_file" ]] || return 1
    local pid
    pid=$(cat "$pid_file" 2>/dev/null)
    [[ -n "$pid" ]] || return 1
    ps -p "$pid" > /dev/null 2>&1
}
kill_by_pid() {
    local pid_file="/run/rigcontrol/${SCREEN_NAME}_miner.pid"
    if [[ -f "$pid_file" ]]; then
        local miner_pid=$(cat "$pid_file")
        if ps -p "$miner_pid" > /dev/null 2>&1; then
            echo "[$(date)] Sending Ctrl+C (SIGINT) to miner process group (PGID: $miner_pid)..."
            kill -2 -- "-$miner_pid" 2>/dev/null
            local waited=0
            while [[ $waited -lt 10 ]]; do
                if ! ps -p "$miner_pid" > /dev/null 2>&1; then
                    echo "[$(date)] Miner exited gracefully after ${waited}s"
                    break
                fi
                sleep 1
                ((waited++))
            done
            if ps -p "$miner_pid" > /dev/null 2>&1; then
                echo "[$(date)] Miner not responding to SIGINT after 10s - sending SIGKILL..."
                kill -9 -- "-$miner_pid" 2>/dev/null
                sleep 1
                pkill -P "$miner_pid" 2>/dev/null 2>&1 || true
                echo "[$(date)] Miner process group $miner_pid terminated (forcefully)"
            fi
        fi
        # Clean up PID file
        rm -f "$pid_file"
    fi
}
# STOP MINER FUNCTION
stop_miner() {
    echo "[$(date)] Stopping $SCREEN_NAME miner..."
    local pid_file="/run/rigcontrol/${SCREEN_NAME}_miner.pid"
    if ! is_miner_alive; then
        echo "[$(date)] No running $SCREEN_NAME process found - nothing to stop."
        rm -f "$pid_file"
    else
        local miner_pid=$(cat "$pid_file")
        kill_by_pid
        echo "[$(date)] Verifying cleanup..."
        if ps -p "$miner_pid" > /dev/null 2>&1; then
            echo "[$(date)] WARNING: Miner process still exists! Waiting 5s before retrying kill_by_pid..."
            sleep 5
            kill_by_pid
            if ps -p "$miner_pid" > /dev/null 2>&1; then
                echo "[$(date)] WARNING: Miner process still exists after retry!"
            else
                echo "[$(date)] Miner process cleaned up successfully after retry."
                rm -f "$pid_file"
            fi
        else
            echo "[$(date)] Miner process cleaned up successfully."
            rm -f "$pid_file"
        fi
    fi
    # Reset GPU if configured (always run this if RESET_OC is true)
    if [[ "${RESET_OC,,}" == "true" ]]; then
        echo "[$(date)] Resetting GPU clocks and power limits..."
        /usr/local/bin/gpu_reset_poststop.sh
    fi
    echo "[$(date)] Final sleep 2 seconds..."
    sleep 2
    echo "========================================"
    echo "MINER STOPPED SUCCESSFULLY"
    echo "========================================"
}
if is_miner_alive; then
    miner_pid=$(cat "/run/rigcontrol/${SCREEN_NAME}_miner.pid")
    echo "Miner is currently running (PID: $miner_pid)"
else
    echo "Miner is not currently running."
    echo "check for orphaned miner process"
fi
stop_miner
EOF
# Make the script executable
sudo chmod +x /usr/local/bin/manual_stop_gpu.sh
