sudo tee /usr/local/bin/docker_events_universal.sh > /dev/null <<'EOF'
#!/bin/bash
set -Eeuo pipefail
shopt -s inherit_errexit
: "${POWER_LIMIT:=}"
SHUTDOWN_REQUESTED=0
: "${MAX_LOG_BYTES:=10485760}"  # 10 MB default, override via env
: "${LOG_CHECK_INTERVAL:=10}"  # seconds between size checks
: "${ALWAYS_LOGS:=true}"
# SIGNAL HANDLER
handle_signal() {
    local sig=$1
    echo "$(date): Received signal $sig - initiating graceful shutdown..."
    SHUTDOWN_REQUESTED=1
    # Ensure miner is stopped
    echo "$(date): Stopping miner if running..."
    stop_miner
    exit 0
}
# Setup signal handlers
trap 'handle_signal TERM' TERM
trap 'handle_signal INT' INT
trap 'handle_signal HUP' HUP
# Where miners are installed
BASE_DIR="/opt/miners"
readonly BASE_DIR
# Where THIS script and lib/ live
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
echo "[init] SCRIPT_DIR=$SCRIPT_DIR"
echo "[init] BASE_DIR=$BASE_DIR"
mkdir -p "$BASE_DIR"
# Rig config (must be set by service)
: "${OC_FILE:?OC_FILE is not set}"
CFG_FILE="$OC_FILE"
export CFG_FILE
case "$CFG_FILE" in
    *.json) RIG_GPU_JSON="$CFG_FILE" ;;
    *) RIG_GPU_JSON="${CFG_FILE%.conf}.json" ;;
esac
if [[ ! -f "$CFG_FILE" && ! -f "$RIG_GPU_JSON" ]]; then
    echo "Missing rig config: neither $CFG_FILE nor $RIG_GPU_JSON exists"
    exit 1
fi
# Miner config (with default location)
: "${MINER_CONF:=/etc/rigcontrol/miner.conf}"
[[ -f "$MINER_CONF" ]] || {
    echo "Missing miner.conf: $MINER_CONF"
    exit 1
}
# Source libraries
for f in \
    "$SCRIPT_DIR/lib/00-get_rig_conf.sh" \
    "$SCRIPT_DIR/lib/01-miner_install.sh" \
    "$SCRIPT_DIR/lib/02-load_configs.sh" \
    "$SCRIPT_DIR/lib/03-cpu_threads.sh" \
    "$SCRIPT_DIR/lib/04-algo_config.sh"
do
    [[ -f "$f" ]] || { echo "Missing include: $f"; exit 1; }
    source "$f"
done
: "${API_CONF:=/etc/rigcontrol/api.conf}"
PORTS_CONF="$API_CONF"
unset API_PORT API_HOST
API_LOOKUP_NAME="$MINER_NAME"
if [[ -n "${CUSTOM_MINER:-}" && "$CUSTOM_MINER" != "0" ]]; then
    API_LOOKUP_NAME="$CUSTOM_MINER"
fi
: "${AGENT_CONF:=/etc/rigcontrol/rigcontrol-agent.conf}"
_read_agent_conf_val() {
    local key="$1"
    [[ -f "$AGENT_CONF" ]] || return 0
    grep -E "^${key}=" "$AGENT_CONF" | tail -n1 | cut -d= -f2-
}
MINER_UPPER=$(echo "$API_LOOKUP_NAME" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
MINER_API_PORT_VAR="${MINER_UPPER}_API_PORT"
MINER_API_HOST_VAR="${MINER_UPPER}_API_HOST"
if [[ ! -f "$PORTS_CONF" ]]; then
    echo "[api] WARNING: $PORTS_CONF not found"
else
    echo "[api] Loading API settings from $PORTS_CONF"
    source "$PORTS_CONF"
fi
if [[ -n "${!MINER_API_PORT_VAR:-}" ]]; then
    API_PORT="${!MINER_API_PORT_VAR}"
    echo "[api] Found specific API_PORT: $MINER_API_PORT_VAR=$API_PORT (from $PORTS_CONF)"
else
    AGENT_CONF_PORT="$(_read_agent_conf_val "$MINER_API_PORT_VAR")"
    if [[ -n "$AGENT_CONF_PORT" ]]; then
        API_PORT="$AGENT_CONF_PORT"
        echo "[api] Found specific API_PORT: $MINER_API_PORT_VAR=$API_PORT (from $AGENT_CONF, not in $PORTS_CONF)"
    else
        API_PORT=0
        echo "[api] No $MINER_API_PORT_VAR found in $PORTS_CONF or $AGENT_CONF, API disabled"
    fi
fi
if [[ -n "${!MINER_API_HOST_VAR:-}" ]]; then
    API_HOST="${!MINER_API_HOST_VAR}"
    echo "[api] Found specific API_HOST: $MINER_API_HOST_VAR=$API_HOST (from $PORTS_CONF)"
else
    AGENT_CONF_HOST="$(_read_agent_conf_val "$MINER_API_HOST_VAR")"
    if [[ -n "$AGENT_CONF_HOST" ]]; then
        API_HOST="$AGENT_CONF_HOST"
        echo "[api] Found specific API_HOST: $MINER_API_HOST_VAR=$API_HOST (from $AGENT_CONF, not in $PORTS_CONF)"
    else
        API_HOST="127.0.0.1"
        echo "[api] No $MINER_API_HOST_VAR found in $PORTS_CONF or $AGENT_CONF, defaulting to $API_HOST"
    fi
fi
echo "[api] Final API settings for $API_LOOKUP_NAME:"
echo "[api]   API_HOST=$API_HOST"
echo "[api]   API_PORT=$API_PORT"
# MINER-SPECIFIC API COMMAND GENERATION
add_api_flags() {
    local miner_name="$1"
    local api_host="$2"
    local api_port="$3"
    local current_args="$4"
    if [[ "$api_port" -eq 0 ]]; then
        echo "$current_args"
        return
    fi
    case "$miner_name" in
        "xmrig"|"xmrig-cpu"|"xmrig-gpu")
            echo "$current_args --http-host=$api_host --http-port=$api_port"
            ;;
        "rigel")
            echo "$current_args --api-bind $api_host:$api_port"
            ;;
        "srbminer"|"srbminer-cpu"|"srbminer-gpu"|"srbminer-multi")
            echo "$current_args --api-enable --api-port $api_port"
            ;;
        "lolminer")
            echo "$current_args --apiport $api_port --apihost $api_host"
            ;;
        "wildrig"|"wildrig-multi")
            echo "$current_args --api-port $api_port"
            ;;
        "gminer")
            echo "$current_args --api $api_port"
            ;;
        "bzminer")
            echo "$current_args --http_port $api_port --http_address $api_host"
            ;;
        "onezerominer")
            echo "$current_args --api-port $api_port"
            ;;
        "t-rex")
            echo "$current_args --api-bind $api_host:$api_port"
            ;;
        "teamredminer")
            echo "$(date): teamredminer API flags added"
            echo "$current_args --api_listen=$api_host:$api_port"
            ;;
        "nbminer")
            echo "$current_args --api $api_host:$api_port"
            ;;
        "keryx-miner"|"keryx_miner")
            echo "$current_args"
            ;;
        *)
            echo "[api] Miner '$miner_name' has no known API integration (unknown/custom miner) - starting without API flags, no API health check possible. If this miner exposes no stats API at all, telemetry log-scraping is the fallback for monitoring it instead (see CUSTOM_MINER_PROCESS_NAME / CUSTOM_MINER_LOG_PATH in rigcloud_telemetry.py)." >&2
            echo "$current_args"
            ;;
    esac
}
# FINAL PLACEHOLDER SUBSTITUTION
# CPU threads
if [[ -n "$AUTOFILL_CPU" ]]; then
    ARGS="${ARGS//%CPU_THREADS%/$AUTOFILL_CPU}"
else
    ARGS="${ARGS//%CPU_THREADS%/$CPU_THREADS}"
fi
# Warthog target
if [[ -n "$WARTHOG_TARGET" ]]; then
    ARGS="${ARGS//%WARTHOG_TARGET%/$WARTHOG_TARGET}"
fi
# Replace %WORKER_NAME% placeholder in ARGS, WALLET, PASS, POOL
ARGS="${ARGS//%WORKER_NAME%/$WORKER_NAME}"
WALLET="${WALLET//%WORKER_NAME%/$WORKER_NAME}"
PASS="${PASS//%WORKER_NAME%/$WORKER_NAME}"
POOL="${POOL//%WORKER_NAME%/$WORKER_NAME}"
# Add miner-specific API flags
if [[ "$API_PORT" -gt 0 ]]; then
        ARGS=$(add_api_flags "$API_LOOKUP_NAME" "$API_HOST" "$API_PORT" "$ARGS")
fi
START_CMD=$(get_start_cmd "$MINER_NAME")
# SERVICE_TYPE: one of "cpu" / "gpu" / "aux" - fixed by which service instance this is, not user-configurable
case "$OC_FILE" in
    *rig-gpu*) SERVICE_TYPE="gpu" ;;
    *rig-cpu*) SERVICE_TYPE="cpu" ;;
    *rig-aux*) SERVICE_TYPE="aux" ;;
esac
# API HEALTH CHECK FUNCTION
check_api_health() {
    if [[ "$API_PORT" -eq 0 ]]; then
        return 0  # API not enabled, consider healthy
    fi
    # just return healthy...
    return 0
}
# PID-BASED KILL - Backup for crashed miners
kill_by_pid() {
    local pid_file="/run/rigcontrol/${SERVICE_TYPE}_miner.pid"
    if [[ -f "$pid_file" ]]; then
        local miner_pid=$(cat "$pid_file")
        if ps -p "$miner_pid" > /dev/null 2>&1; then
            echo "$(date): WARNING: Miner process still alive after screen quit - forcing kill (PID: $miner_pid)..."
            # Send SIGTERM first (graceful)
            kill -15 "$miner_pid" 2>/dev/null
            sleep 2
            # Force kill if still running
            if ps -p "$miner_pid" > /dev/null 2>&1; then
                echo "$(date): Miner not responding to SIGTERM - sending SIGKILL..."
                kill -9 "$miner_pid" 2>/dev/null
                sleep 1
            fi
            # Kill any child processes
            pkill -P "$miner_pid" 2>/dev/null 2>&1 || true
            echo "$(date): Miner process $miner_pid terminated (forcefully)"
        fi
        # Clean up PID file
        rm -f "$pid_file"
    fi
}
# MINER CONTROL FUNCTIONS
# Function to start miner
start_miner() {
    # Check if miner is already running
    if screen -list | grep -q "$SERVICE_TYPE"; then
        echo "$(date): Screen session exists for $SERVICE_TYPE - checking if miner is alive..."
        local pid_file="/run/rigcontrol/${SERVICE_TYPE}_miner.pid"
        if [[ -f "$pid_file" ]]; then
            local miner_pid=$(cat "$pid_file")
            if ps -p "$miner_pid" > /dev/null 2>&1; then
                echo "$(date): Miner already running in screen session: $SERVICE_TYPE"
                echo "$(date): To view: sudo screen -r $SERVICE_TYPE"
                return 0  # Exit early - miner is already running
            else
                echo "$(date): Miner process is dead but screen session exists - cleaning up..."
                stop_miner
                echo "$(date): Starting fresh miner after cleanup..."
                # Continue to start fresh miner
            fi
        else
            echo "$(date): Screen session exists but no PID file found - cleaning up..."
            stop_miner
            echo "$(date): Starting fresh miner after cleanup..."
            # Continue to start fresh miner
        fi
    fi
    # Start fresh miner
    # Apply GPU OC's if configured
    if [[ "${APPLY_OC,,}" == "true" ]]; then
        OC_TARGET="${ALGO:-}"
        if [[ -z "$OC_TARGET" || "$OC_TARGET" == "0" ]]; then
            OC_TARGET="${CUSTOM_MINER:-}"
        fi
        if [[ -n "$OC_TARGET" && "$OC_TARGET" != "0" ]]; then
            echo "$(date): Applying GPU clocks for '$OC_TARGET'..."
            /usr/local/bin/gpu_apply_ocs.sh "$OC_TARGET"
        else
            echo "$(date): Applying GPU clocks skipped - no ALGO or CUSTOM_MINER name available."
        fi
    fi
    echo "$(date): Starting $SERVICE_TYPE..."
    echo "$(date): API: $API_HOST:$API_PORT"
    echo "$(date): Command: $START_CMD"
    if [[ "$API_PORT" -gt 0 ]]; then
        echo "$(date): Running in API mode (health checks enabled)"
    else
        echo "$(date): Running in no-API mode (no known API integration for this miner - health checks disabled; use CUSTOM_MINER_PROCESS_NAME / CUSTOM_MINER_LOG_PATH telemetry log-scraping instead if needed)"
    fi
    # Create PID file directory
    mkdir -p /run/rigcontrol
    # Start in screen session
    if [[ "${START_CMD,,}" == *keryx* ]]; then
        LOG_FILE="/run/rigcontrol/${SERVICE_TYPE}_miner.log"
        SCRAP_LOG="/run/rigcontrol/${SERVICE_TYPE}_miner.scrap.log"
        rm -f "$LOG_FILE" "$SCRAP_LOG"  # delete log on each fresh start
        touch "$LOG_FILE"
        screen -fn -dmS "$SERVICE_TYPE" -L -Logfile "$SCRAP_LOG" bash -c \
            'echo "Miner starting at $(date)"; \
             echo "API: '"$API_HOST:$API_PORT"'"; \
             echo "$$" > "'"/run/rigcontrol/${SERVICE_TYPE}_miner.pid"'"; \
             trap '\''echo "Miner exiting at $(date)"; rm -f "'"/run/rigcontrol/${SERVICE_TYPE}_miner.pid"'"'\'' EXIT; \
             ( while true; do \
                 sed -u -r "s/\x1b\][^\x07]*\x07//g; s/\x1b[()][A-Za-z0-9]//g; s/\x1b\[\??[0-9;]*[a-zA-Z]//g" "'"$SCRAP_LOG"'" 2>/dev/null | grep -Pao "[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}.*?(?=  |[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}|$)" 2>/dev/null | sed -r "s/ +$//" | awk '\''!seen[$0]++'\'' > "'"$LOG_FILE"'.tmp" 2>/dev/null && mv -f "'"$LOG_FILE"'.tmp" "'"$LOG_FILE"'"; \
                 sz=$(stat -c%s "'"$SCRAP_LOG"'" 2>/dev/null || echo 0); \
                 if [ "$sz" -gt '"$MAX_LOG_BYTES"' ]; then \
                     tail -c '"$MAX_LOG_BYTES"' "'"$SCRAP_LOG"'" > "'"$SCRAP_LOG"'.tmp" 2>/dev/null && cat "'"$SCRAP_LOG"'.tmp" > "'"$SCRAP_LOG"'" && rm -f "'"$SCRAP_LOG"'.tmp"; \
                 fi; \
                 sleep '"$LOG_CHECK_INTERVAL"'; \
               done ) & \
             '"$START_CMD"''
    else
        LOG_FILE="/run/rigcontrol/${SERVICE_TYPE}_miner.log"
        rm -f "$LOG_FILE"
        touch "$LOG_FILE"
        screen -fn -dmS "$SERVICE_TYPE" -L -Logfile "$LOG_FILE" bash -c \
            'echo "Miner starting at $(date)"; \
             echo "API: '"$API_HOST:$API_PORT"'"; \
             echo "$$" > "'"/run/rigcontrol/${SERVICE_TYPE}_miner.pid"'"; \
             trap '\''echo "Miner exiting at $(date)"; rm -f "'"/run/rigcontrol/${SERVICE_TYPE}_miner.pid"'"'\'' EXIT; \
             ( while true; do \
                 sz=$(stat -c%s "'"$LOG_FILE"'" 2>/dev/null || echo 0); \
                 if [ "$sz" -gt '"$MAX_LOG_BYTES"' ]; then \
                     tail -c '"$MAX_LOG_BYTES"' "'"$LOG_FILE"'" > "'"$LOG_FILE"'.tmp" 2>/dev/null && cat "'"$LOG_FILE"'.tmp" > "'"$LOG_FILE"'" && rm -f "'"$LOG_FILE"'.tmp"; \
                 fi; \
                 sleep '"$LOG_CHECK_INTERVAL"'; \
               done ) & \
             '"$START_CMD"''
    fi
    # Wait a moment for PID file creation
    sleep 2
    # Verify startup
    if screen -list | grep -q "$SERVICE_TYPE"; then
        echo "$(date): Miner started in screen session: $SERVICE_TYPE"
        if [[ -f "/run/rigcontrol/${SERVICE_TYPE}_miner.pid" ]]; then
            local miner_pid=$(cat "/run/rigcontrol/${SERVICE_TYPE}_miner.pid")
            echo "$(date): Miner process PID: $miner_pid"
        fi
        # Wait for API to come up if enabled
        if [[ "$API_PORT" -gt 0 ]]; then
            echo "$(date): Waiting for API to start (max 30 seconds)..."
            local max_wait=30
            local waited=0
            while [[ $waited -lt $max_wait ]]; do
                if check_api_health; then
                    echo "$(date): API is up and running"
                    break
                fi
                sleep 1
                ((waited++))
            done
            if [[ $waited -ge $max_wait ]]; then
                echo "$(date): WARNING: API did not respond after $max_wait seconds"
            fi
        fi
        echo "$(date): ARGS/OCS: $ARGS"
        echo "$(date): To view miner output: sudo screen -r $SERVICE_TYPE"
        return 0
    else
        echo "$(date): ERROR: Failed to start screen session!"
        return 1
    fi
}
# Function to stop miner (clean closure first)
stop_miner() {
    echo "$(date): Stopping $SERVICE_TYPE miner..."
    # Check if screen session exists at all
    if ! screen -list | grep -q "$SERVICE_TYPE"; then
        echo "$(date): No $SERVICE_TYPE screen session found - nothing to stop."
        return 0
    fi
    # 1. FIRST ATTEMPT: Clean screen quit (let miner cleanup)
    echo "$(date): Sending clean quit to screen session..."
    screen -S "$SERVICE_TYPE" -X quit
    echo "$(date): Waiting 10 seconds for miner cleanup..."
    sleep 10
    # 2. CHECK: If miner process still exists after clean quit
    local pid_file="/run/rigcontrol/${SERVICE_TYPE}_miner.pid"
    if [[ -f "$pid_file" ]]; then
        local miner_pid=$(cat "$pid_file")
        if ps -p "$miner_pid" > /dev/null 2>&1; then
            echo "$(date): Miner still running after screen quit - using force cleanup..."
            kill_by_pid
        else
            echo "$(date): Miner exited cleanly after screen quit."
            rm -f "$pid_file"
        fi
    fi
    # 3. CLEANUP: Any leftover screen processes
    local screen_pids=$(pgrep -f "SCREEN.*$SERVICE_TYPE" 2>/dev/null || true)
    if [[ -n "$screen_pids" ]]; then
        echo "$(date): Cleaning up leftover screen processes..."
        kill -15 $screen_pids 2>/dev/null
        sleep 2
        kill -9 $screen_pids 2>/dev/null 2>&1 || true
    fi
    # 4. Reset GPU if configured
    if [[ "${RESET_OC,,}" == "true" ]]; then
        echo "$(date): Resetting GPU clocks and power limits..."
        /usr/local/bin/gpu_reset_poststop.sh "$POWER_LIMIT"
    fi
    # 5. Final verification
    echo "$(date): Verifying cleanup..."
    if screen -list | grep -q "$SERVICE_TYPE"; then
        echo "$(date): WARNING: Screen session still exists!"
        return 1
    else
        echo "$(date): Screen session cleaned up successfully."
    fi
    # Clean PID file if still exists
    rm -f "$pid_file"
    echo "$(date): Final sleep 2 seconds..."
    sleep 2
}
# START MINER
echo "$(date): Starting miner (no container checks)..."
start_miner
while [[ $SHUTDOWN_REQUESTED -eq 0 ]]; do
    sleep 60
done
# Final cleanup before exit
echo "$(date): Performing final cleanup..."
stop_miner
echo "$(date): Miner launcher stopped gracefully"
EOF
# Make the script executable
sudo chmod +x /usr/local/bin/docker_events_universal.sh
# -- write GPU service --
sudo tee /etc/systemd/system/docker_events_gpu.service > /dev/null <<'EOF'
[Unit]
Description=GPU Miner Launcher
[Service]
Type=simple
User=root
Environment="OC_FILE=/etc/rigcontrol/rig-gpu.json"
Environment="POWER_LIMIT="
ExecStopPost=/usr/local/bin/gpu_reset_poststop.sh
ExecStartPre=/bin/chmod +x /usr/local/bin/docker_events_universal.sh
ExecStart=/usr/local/bin/docker_events_universal.sh
Restart=always
RestartSec=10
KillSignal=SIGTERM
TimeoutStopSec=30
StandardOutput=journal
StandardError=journal
SendSIGKILL=no
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
# -- write CPU service --
sudo tee /etc/systemd/system/docker_events_cpu.service > /dev/null <<'EOF'
[Unit]
Description=CPU Miner Launcher
[Service]
Type=simple
User=root
Environment="OC_FILE=/etc/rigcontrol/rig-cpu.json"
ExecStartPre=/bin/chmod +x /usr/local/bin/docker_events_universal.sh
ExecStart=/usr/local/bin/docker_events_universal.sh
Restart=always
RestartSec=10
KillSignal=SIGTERM
TimeoutStopSec=30
StandardOutput=journal
StandardError=journal
SendSIGKILL=no
[Install]
WantedBy=multi-user.target
EOF
sudo tee /etc/systemd/system/docker_events_aux.service > /dev/null <<'EOF'
[Unit]
Description=AUX Miner Launcher
[Service]
Type=simple
User=root
Environment="OC_FILE=/etc/rigcontrol/rig-aux.json"
ExecStartPre=/bin/chmod +x /usr/local/bin/docker_events_universal.sh
ExecStart=/usr/local/bin/docker_events_universal.sh
Restart=always
RestartSec=10
KillSignal=SIGTERM
TimeoutStopSec=30
StandardOutput=journal
StandardError=journal
SendSIGKILL=no
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl restart docker_events_cpu.service
sudo systemctl restart docker_events_gpu.service
sudo systemctl restart docker_events_aux.service
sudo systemctl enable docker_events_cpu.service
sudo systemctl enable docker_events_gpu.service
sudo systemctl enable docker_events_aux.service
# follow logs
sudo journalctl -u docker_events_cpu.service -f
sudo journalctl -u docker_events_gpu.service -f
sudo journalctl -u docker_events_aux.service -f
