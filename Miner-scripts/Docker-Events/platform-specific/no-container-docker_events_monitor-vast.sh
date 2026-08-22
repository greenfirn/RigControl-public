# no-container-docker_events_monitor.sh
sudo tee /usr/local/bin/docker_events_universal.sh > /dev/null <<'EOF'
#!/bin/bash
set -Eeuo pipefail
shopt -s inherit_errexit
: "${POWER_LIMIT:=}"
# Global list of ignored images
IGNORED_IMAGES=(
    "vastai/test:bandwidth-test-nvidia"
    "vastai/test:speedtest"
    "vastai/test:common"
)
SHUTDOWN_REQUESTED=0
: "${IDLE_CONFIRM_LOOPS:=3}"
: "${MAX_LOG_BYTES:=10485760}"  # 10 MB default, override via env
: "${LOG_CHECK_INTERVAL:=60}"  # seconds between size checks
: "${ALWAYS_LOGS:=true}"
# SIGNAL HANDLER
handle_signal() {
    local sig=$1
    echo "$(date): Received signal $sig - initiating graceful shutdown..."
    SHUTDOWN_REQUESTED=1
    # Ensure miner is stopped
    echo "$(date): Stopping miner if running..."
    stop_miner || true
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
# VAST EVENT SOURCE
echo "$(date): Confirming Vast config..."
if [ "$TARGET_NAME" = "vast" ]; then
    echo "$(date): Using Vast events monitor"
    echo "$(date): Vast idle confirm loops: $IDLE_CONFIRM_LOOPS"
else
    echo "$(date): Exiting... TARGET_NAME in conf should be vast"
	exit 1
fi
: "${API_CONF:=/etc/rigcontrol/api.conf}"
PORTS_CONF="$API_CONF"
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
        : "${API_PORT:=0}"
        echo "[api] Using generic API_PORT: $API_PORT"
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
        : "${API_HOST:=127.0.0.1}"
        echo "[api] Using generic API_HOST: $API_HOST"
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
        *)
            # No API flags for unknown miners
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
# DOCKER-SPECIFIC FUNCTIONS
is_docker_running() {
    docker ps > /dev/null 2>&1
    return $?
}
should_ignore_image() {
    local image="$1"
    # Check if image is in the ignore list
    for ignored_image in "${IGNORED_IMAGES[@]}"; do
        if [[ "$image" == "$ignored_image" ]]; then
            return 0  # Image should be ignored (true)
        fi
    done
    return 1  # Image should NOT be ignored (false)
}
# Check if ANY container is running with exclusions
any_container_running() {
    # Get list of running containers
    local containers=$(docker ps --format "{{.Names}}:{{.Image}}" 2>/dev/null)
    # If no containers, return false (no containers running)
    if [ -z "$containers" ]; then
        return 1
    fi
    # Check each container
    while IFS= read -r container_info; do
        local container_name=$(echo "$container_info" | cut -d':' -f1)
        local image_name=$(echo "$container_info" | cut -d':' -f2)
        # Check if this is a container to ignore using the helper function
        if should_ignore_image "$image_name"; then
            echo "$(date): Ignoring: $container_name with $image_name"
            continue
        fi
        # If any other container is found, return true
        echo "$(date): Found: $container_name with $image_name"
        return 0
    done <<< "$containers"
    # No non-ignored containers found
    return 1
}
# Confirm NO containers are running (for multiple checks)
confirm_no_containers_running() {
    local loops=${1:-$IDLE_CONFIRM_LOOPS}
    local check_interval=2  # seconds
    echo "$(date): Confirming no containers are running (checking $loops times, $check_interval second intervals)..."
    for ((i=1; i<=loops; i++)); do
        echo "$(date): No-container check $i/$loops..."
        # Check if shutdown was requested
        if [[ $SHUTDOWN_REQUESTED -eq 1 ]]; then
            echo "$(date): Shutdown requested during confirmation, aborting..."
            return 1
        fi
        # Check if Docker is running
        if ! is_docker_running; then
            echo "$(date): Docker not running → UNAVAILABLE → BREAKING (cannot confirm)"
            return 1
        fi
        # Check if any containers are running
        if any_container_running; then
            echo "$(date): Containers found running → BREAKING (containers exist)"
            return 1
        else
            echo "$(date): No containers running → continue checking"
            # Continue checking to confirm stable state
        fi
        # If this is not the last check, wait and continue
        if [ $i -lt $loops ]; then
            echo "$(date): Waiting $check_interval seconds for next check..."
            sleep $check_interval
        fi
    done
    echo "$(date): Confirmed no containers running after $loops consecutive checks"
    return 0
}
process_docker_event() {
    local container_name="$1"
    local status="$2"
    local image="$3"
    echo "$(date): Docker event - Container: $container_name, Action: $status, Image: $image"
    case "$status" in
        init|start|create|unpause|restart)
            # ANY container starting → IMMEDIATE stop miner
            echo "$(date): ANY Docker START event ($status) → IMMEDIATE stop_miner"
            stop_miner || true
            ;;
        kill|destroy|stop|die|died|pause)
            echo "$(date): Docker STOP event ($status) → Checking if all containers stopped..."
            # Wait a moment for system to stabilize
            sleep 3
            # Confirm NO containers are running
            if confirm_no_containers_running $IDLE_CONFIRM_LOOPS; then
                echo "$(date): Confirmed no containers running → START miner"
                start_miner || true
            else
                echo "$(date): Containers still running → no action"
            fi
            ;;
        *)
            # Ignore other events
            echo "$(date): Unhandled Docker action: $status for $container_name"
            ;;
    esac
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
                stop_miner || true
                echo "$(date): Starting fresh miner after cleanup..."
                # Continue to start fresh miner
            fi
        else
            echo "$(date): Screen session exists but no PID file found - cleaning up..."
            stop_miner || true
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
    # Create PID file directory
    mkdir -p /run/rigcontrol
    if [[ "$API_PORT" -gt 0 && "${ALWAYS_LOGS,,}" != "true" ]]; then
        echo "$(date): Known miner with API - starting without log file (nothing reads it)"
        # Start in screen session
        screen -dmS "$SERVICE_TYPE" bash -c \
            'echo "Miner starting at $(date)"; \
             echo "API: '"$API_HOST:$API_PORT"'"; \
             echo "$$" > "'"/run/rigcontrol/${SERVICE_TYPE}_miner.pid"'"; \
             trap '\''echo "Miner exiting at $(date)"; rm -f "'"/run/rigcontrol/${SERVICE_TYPE}_miner.pid"'"'\'' EXIT; \
             '"$START_CMD"''
    else
        if [[ "$API_PORT" -gt 0 ]]; then
            echo "$(date): ALWAYS_LOGS enabled - starting with log file for easier review of miner output (API is still used for stats)"
        else
            echo "$(date): No API for this miner - starting with log file (needed for log-scraping telemetry)"
        fi
        LOG_FILE="/run/rigcontrol/${SERVICE_TYPE}_miner.log"
        SCRAP_LOG="/run/rigcontrol/${SERVICE_TYPE}_miner.scrap.log"
        rm -f "$LOG_FILE" "$SCRAP_LOG"
        # Start in screen session
        screen -dmS "$SERVICE_TYPE" -L -Logfile "$SCRAP_LOG" bash -c \
            'echo "Miner starting at $(date)"; \
             echo "API: '"$API_HOST:$API_PORT"'"; \
             echo "$$" > "'"/run/rigcontrol/${SERVICE_TYPE}_miner.pid"'"; \
             trap '\''echo "Miner exiting at $(date)"; rm -f "'"/run/rigcontrol/${SERVICE_TYPE}_miner.pid"'"'\'' EXIT; \
             ( while true; do \
                 sleep '"$LOG_CHECK_INTERVAL"'; \
                 sed -u -r "s/\x1b\[[0-9;]*[a-zA-Z]//g" "'"$SCRAP_LOG"'" 2>/dev/null | grep -aE "^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}" | awk '\''!seen[$0]++'\'' > "'"$LOG_FILE"'.tmp" 2>/dev/null && mv -f "'"$LOG_FILE"'.tmp" "'"$LOG_FILE"'"; \
                 sz=$(stat -c%s "'"$SCRAP_LOG"'" 2>/dev/null || echo 0); \
                 if [ "$sz" -gt '"$MAX_LOG_BYTES"' ]; then \
                     tail -c '"$MAX_LOG_BYTES"' "'"$SCRAP_LOG"'" > "'"$SCRAP_LOG"'.tmp" 2>/dev/null && cat "'"$SCRAP_LOG"'.tmp" > "'"$SCRAP_LOG"'" && rm -f "'"$SCRAP_LOG"'.tmp"; \
                 fi; \
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
    echo "$(date): Waiting 5 seconds for miner cleanup..."
    sleep 5
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
# INITIAL CHECK
echo "$(date): Performing initial Docker container check..."
# Check if any containers are running at startup
if confirm_no_containers_running; then
    echo "$(date): No containers running at startup → start_miner"
    start_miner || true
else
    echo "$(date): Containers found running at startup → stop_miner (do not start miner)"
    stop_miner || true
fi
# DOCKER EVENT MONITORING LOOP
echo "$(date): Starting Docker event monitor..."
# Main monitoring loop with restart on failure
while [[ $SHUTDOWN_REQUESTED -eq 0 ]]; do
    # DOCKER EVENT STREAM
    echo "$(date): Connecting to Docker events stream..."
    docker events --format "{{.Type}} {{.Action}} {{.Actor.Attributes.name}} {{.Actor.Attributes.image}}" 2>&1 | \
    while read -r type action name image; do
        # Check for shutdown request
        if [[ $SHUTDOWN_REQUESTED -eq 1 ]]; then
            echo "$(date): Shutdown requested, breaking event loop..."
            break 2  # Break out of both loops
        fi
        # Skip non-container events
        if [ "$type" != "container" ]; then
            continue
        fi
        # Skip events from ignored images using the helper function
        if should_ignore_image "$image"; then
            echo "$(date): Skipping: $image (container: $name, $action)"
            continue
        fi
        # Process Docker event
        process_docker_event "$name" "$action" "$image"
    done
    # Events stream ended
    # Check if shutdown was requested
    if [[ $SHUTDOWN_REQUESTED -eq 1 ]]; then
        echo "$(date): Shutdown requested, exiting main loop..."
        break
    fi
    # Check if docker is running
    if ! is_docker_running; then
        echo "$(date): ERROR: Docker daemon not responding. Waiting 30 seconds..."
        sleep 30
        continue
    fi
    # Wait before retrying
    echo "$(date): Docker events stream ended, restarting monitor in 5 seconds..."
    sleep 5
done
# Final cleanup before exit
echo "$(date): Performing final cleanup..."
stop_miner || true
echo "$(date): Docker event monitor stopped gracefully"
EOF
# Make the script executable
sudo chmod +x /usr/local/bin/docker_events_universal.sh
# -- write CPU service --
sudo tee /etc/systemd/system/docker_events_cpu.service > /dev/null <<'EOF'
[Unit]
Description=Docker Events CPU Miner Monitor
After=docker.service
Requires=docker.service
[Service]
Type=simple
User=root
Environment="OC_FILE=/etc/rigcontrol/rig-cpu.json"
Environment="IDLE_CONFIRM_LOOPS=3"
ExecStartPre=/bin/chmod +x /usr/local/bin/docker_events_universal.sh
ExecStart=/usr/local/bin/docker_events_universal.sh
Restart=always
RestartSec=10
KillSignal=SIGTERM
TimeoutStopSec=60
StandardOutput=journal
StandardError=journal
SendSIGKILL=no
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
# -- write GPU service --
sudo tee /etc/systemd/system/docker_events_gpu.service > /dev/null <<'EOF'
[Unit]
Description=Docker Events GPU Miner Monitor
After=docker.service
Requires=docker.service
[Service]
Type=simple
User=root
Environment="OC_FILE=/etc/rigcontrol/rig-gpu.json"
Environment="IDLE_CONFIRM_LOOPS=3"
Environment="POWER_LIMIT=150"
ExecStopPost=/usr/local/bin/gpu_reset_poststop.sh 150
ExecStartPre=/bin/chmod +x /usr/local/bin/docker_events_universal.sh
ExecStart=/usr/local/bin/docker_events_universal.sh
Restart=always
RestartSec=10
KillSignal=SIGTERM
TimeoutStopSec=60
StandardOutput=journal
StandardError=journal
SendSIGKILL=no
[Install]
WantedBy=multi-user.target
EOF
sudo tee /etc/systemd/system/docker_events_aux.service > /dev/null <<'EOF'
[Unit]
Description=Docker Events AUX Miner Monitor
After=docker.service
Requires=docker.service
[Service]
Type=simple
User=root
Environment="OC_FILE=/etc/rigcontrol/rig-aux.json"
Environment="IDLE_CONFIRM_LOOPS=3"
ExecStartPre=/bin/chmod +x /usr/local/bin/docker_events_universal.sh
ExecStart=/usr/local/bin/docker_events_universal.sh
Restart=always
RestartSec=10
KillSignal=SIGTERM
TimeoutStopSec=60
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
