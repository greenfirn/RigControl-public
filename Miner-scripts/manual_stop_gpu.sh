sudo tee /usr/local/bin/manual_stop_gpu.sh > /dev/null <<'EOF'
#!/bin/bash
set -Eeuo pipefail
shopt -s inherit_errexit
echo "========================================"
echo "MANUAL MINER STOP SCRIPT"
echo "========================================"
echo "[init] Loading configuration..."
MINER_CONF="/etc/rigcontrol/miner.conf"
API_CONF="/etc/rigcontrol/api.conf"
CFG_FILE="/etc/rigcontrol/rig-gpu.conf"
BASE_DIR="/opt/miners"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$CFG_FILE" in
    *.json) RIG_GPU_JSON="$CFG_FILE" ;;
    *) RIG_GPU_JSON="${CFG_FILE%.conf}.json" ;;
esac
if [[ -f "$BASE_DIR/miner_paths.env" ]]; then
    echo "[init] Loading miner paths from: $BASE_DIR/miner_paths.env"
    source "$BASE_DIR/miner_paths.env"
else
    echo "[init] WARNING: miner_paths.env not found at $BASE_DIR/miner_paths.env"
    echo "[init] Miner binary locations may not be set correctly"
fi
[[ -f "$CFG_FILE" || -f "$RIG_GPU_JSON" ]] || {
    echo "Missing rig config: neither $CFG_FILE nor $RIG_GPU_JSON exists"
    exit 1
}
[[ -f "$MINER_CONF" ]] || {
    echo "Missing miner.conf: $MINER_CONF"
    exit 1
}
for f in \
    "$SCRIPT_DIR/lib/00-get_rig_conf.sh" \
    "$SCRIPT_DIR/lib/02-load_configs.sh" \
    "$SCRIPT_DIR/lib/04-algo_config.sh"
do
    [[ -f "$f" ]] || { echo "Missing include: $f"; exit 1; }
    source "$f"
done
SERVICE_TYPE="gpu"
RESET_OC=$(get_rig_conf "RESET_OC" "0")
RESET_OC="${RESET_OC//\"/}"
RESET_OC="${RESET_OC,,}"
: "${RESET_OC:=false}"
: "${POWER_LIMIT:=}"
echo "Miner Name:      $MINER_NAME"
echo "Screen Session:  $SERVICE_TYPE"
echo "Reset GPU on stop: $RESET_OC"
echo "========================================"
kill_by_pid() {
    local pid_file="/run/rigcontrol/${SERVICE_TYPE}_miner.pid"
    if [[ -f "$pid_file" ]]; then
        local miner_pid=$(cat "$pid_file")
        if ps -p "$miner_pid" > /dev/null 2>&1; then
            echo "[$(date)] WARNING: Miner process still alive after screen quit - forcing kill (PID: $miner_pid)..."
            kill -15 "$miner_pid" 2>/dev/null
            sleep 2
            if ps -p "$miner_pid" > /dev/null 2>&1; then
                echo "[$(date)] Miner not responding to SIGTERM - sending SIGKILL..."
                kill -9 "$miner_pid" 2>/dev/null
                sleep 1
            fi
            pkill -P "$miner_pid" 2>/dev/null 2>&1 || true
            echo "[$(date)] Miner process $miner_pid terminated (forcefully)"
        fi
        rm -f "$pid_file"
    fi
}
stop_miner() {
    echo "[$(date)] Stopping $SERVICE_TYPE miner..."
    if screen -list | grep -q "$SERVICE_TYPE"; then
        echo "[$(date)] Screen session found for $SERVICE_TYPE"
        local pid_file="/run/rigcontrol/${SERVICE_TYPE}_miner.pid"
        echo "[$(date)] Sending Ctrl+C to screen session (lets the miner unwind/flush state and release its API port before we tear anything down)..."
        screen -S "$SERVICE_TYPE" -X stuff $'\003'
        echo "[$(date)] Waiting 8 seconds for graceful exit..."
        sleep 8
        if [[ -f "$pid_file" ]] && ps -p "$(cat "$pid_file")" > /dev/null 2>&1; then
            echo "[$(date)] Still running after Ctrl+C - sending clean quit to screen session..."
            screen -S "$SERVICE_TYPE" -X quit
            echo "[$(date)] Waiting 5 seconds for miner cleanup..."
            sleep 5
        else
            echo "[$(date)] Miner exited cleanly after Ctrl+C."
        fi
        if [[ -f "$pid_file" ]]; then
            local miner_pid=$(cat "$pid_file")
            if ps -p "$miner_pid" > /dev/null 2>&1; then
                echo "[$(date)] Miner still running after screen quit - using force cleanup..."
                kill_by_pid
            else
                echo "[$(date)] Miner exited cleanly after screen quit."
                rm -f "$pid_file"
            fi
        fi
        local screen_pids=$(pgrep -f "SCREEN.*$SERVICE_TYPE" 2>/dev/null || true)
        if [[ -n "$screen_pids" ]]; then
            echo "[$(date)] Cleaning up leftover screen processes..."
            kill -15 $screen_pids 2>/dev/null
            sleep 2
            kill -9 $screen_pids 2>/dev/null 2>&1 || true
        fi
        echo "[$(date)] Verifying cleanup..."
        if screen -list | grep -q "$SERVICE_TYPE"; then
            echo "[$(date)] WARNING: Screen session still exists!"
            echo "[$(date)] Attempting forceful cleanup..."
            screen -ls | grep "$SERVICE_TYPE" | cut -d. -f1 | awk '{print $1}' | xargs kill 2>/dev/null || true
            sleep 2
            if screen -list | grep -q "$SERVICE_TYPE"; then
                echo "[$(date)] ERROR: Could not remove screen session!"
            else
                echo "[$(date)] Screen session forcefully removed."
            fi
        else
            echo "[$(date)] Screen session cleaned up successfully."
        fi
        rm -f "/run/rigcontrol/${SERVICE_TYPE}_miner.pid"
    else
        echo "[$(date)] No $SERVICE_TYPE screen session found."
        local pid_file="/run/rigcontrol/${SERVICE_TYPE}_miner.pid"
        if [[ -f "$pid_file" ]]; then
            local miner_pid=$(cat "$pid_file")
            if ps -p "$miner_pid" > /dev/null 2>&1; then
                echo "[$(date)] Found orphaned miner process (PID: $miner_pid) - cleaning up..."
                kill_by_pid
            else
                echo "[$(date)] Removing stale PID file..."
                rm -f "$pid_file"
            fi
        else
            echo "[$(date)] No PID file found."
        fi
    fi
    if [[ "${RESET_OC,,}" == "true" ]]; then
        echo "[$(date)] Resetting GPU clocks and power limits..."
        /usr/local/bin/gpu_reset_poststop.sh "$POWER_LIMIT"
    fi
    echo "[$(date)] Final sleep 2 seconds..."
    sleep 2
    echo "========================================"
    echo "MINER STOPPED SUCCESSFULLY"
    echo "========================================"
}
if screen -list | grep -q "$SERVICE_TYPE"; then
    echo "Miner is currently running in screen session: $SERVICE_TYPE"
    if [[ -f "/run/rigcontrol/${SERVICE_TYPE}_miner.pid" ]]; then
        miner_pid=$(cat "/run/rigcontrol/${SERVICE_TYPE}_miner.pid")
        if ps -p "$miner_pid" > /dev/null 2>&1; then
            echo "Active PID: $miner_pid"
        fi
    fi
    stop_miner
else
    echo "Miner is not currently running in a screen session."
    echo "check for orphaned miner process"
	stop_miner
fi
EOF
sudo chmod +x /usr/local/bin/manual_stop_gpu.sh
