sudo tee /usr/local/bin/docker_events_universal.sh > /dev/null <<'EOF'
#!/bin/bash
set -Eeuo pipefail
shopt -s inherit_errexit
# Power limit for GPU reset (default 150W, can be overridden by service)
: "${POWER_LIMIT:=}"
SHUTDOWN_REQUESTED=0
PODMAN_READY=false
# Number of times to check for no running containers
: "${IDLE_CONFIRM_LOOPS:=3}"
: "${MAX_LOG_BYTES:=10485760}"  # 10 MB default, override via env
: "${LOG_CHECK_INTERVAL:=60}"  # seconds between size checks
: "${ALWAYS_LOGS:=true}"
handle_signal() {
    local sig=$1
    echo "$(date): Received signal $sig - initiating graceful shutdown..."
    SHUTDOWN_REQUESTED=1
    echo "$(date): Stopping miner if running..."
    stop_miner || true
    exit 0
}
trap 'handle_signal TERM' TERM
trap 'handle_signal INT' INT
trap 'handle_signal HUP' HUP
BASE_DIR="/opt/miners"
readonly BASE_DIR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
echo "[init] SCRIPT_DIR=$SCRIPT_DIR"
echo "[init] BASE_DIR=$BASE_DIR"
mkdir -p "$BASE_DIR"
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
# MINER_CONF: path to miner.conf (default /etc/rigcontrol/miner.conf).
: "${MINER_CONF:=/etc/rigcontrol/miner.conf}"
[[ -f "$MINER_CONF" ]] || {
    echo "Missing miner.conf: $MINER_CONF"
    exit 1
}
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
# PODMAN EVENT SOURCE
echo "$(date): Confirming Podman config..."
if [ "$TARGET_NAME" = "podman" ]; then
    echo "$(date): Using Podman events monitor"
    echo "$(date): Podman idle confirm loops: $IDLE_CONFIRM_LOOPS"
else
    echo "$(date): Exiting... TARGET_NAME in conf should be podman"
	exit 1
fi
# API_CONF: path to api.conf (default /etc/rigcontrol/api.conf).
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
if [[ -n "$AUTOFILL_CPU" ]]; then
    ARGS="${ARGS//%CPU_THREADS%/$AUTOFILL_CPU}"
else
    ARGS="${ARGS//%CPU_THREADS%/$CPU_THREADS}"
fi
if [[ -n "$WARTHOG_TARGET" ]]; then
    ARGS="${ARGS//%WARTHOG_TARGET%/$WARTHOG_TARGET}"
fi
ARGS="${ARGS//%WORKER_NAME%/$WORKER_NAME}"
WALLET="${WALLET//%WORKER_NAME%/$WORKER_NAME}"
PASS="${PASS//%WORKER_NAME%/$WORKER_NAME}"
POOL="${POOL//%WORKER_NAME%/$WORKER_NAME}"
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
check_api_health() {
    if [[ "$API_PORT" -eq 0 ]]; then
        return 0
    fi
    return 0
}
is_miner_alive() {
    local pid_file="/run/rigcontrol/${SERVICE_TYPE}_miner.pid"
    [[ -f "$pid_file" ]] || return 1
    local pid
    pid=$(cat "$pid_file" 2>/dev/null)
    [[ -n "$pid" ]] || return 1
    ps -p "$pid" > /dev/null 2>&1
}
# PID-BASED KILL - Backup for crashed miners
kill_by_pid() {
    local pid_file="/run/rigcontrol/${SERVICE_TYPE}_miner.pid"
    if [[ -f "$pid_file" ]]; then
        local miner_pid=$(cat "$pid_file")
        if ps -p "$miner_pid" > /dev/null 2>&1; then
            echo "$(date): Sending Ctrl+C (SIGINT) to miner process group (PGID: $miner_pid)..."
            kill -2 -- "-$miner_pid" 2>/dev/null
            local waited=0
            while [[ $waited -lt 10 ]]; do
                if ! ps -p "$miner_pid" > /dev/null 2>&1; then
                    echo "$(date): Miner exited gracefully after ${waited}s"
                    break
                fi
                sleep 1
                ((waited++))
            done
            if ps -p "$miner_pid" > /dev/null 2>&1; then
                echo "$(date): Miner not responding to SIGINT after 10s - sending SIGKILL..."
                kill -9 -- "-$miner_pid" 2>/dev/null
                sleep 1
                pkill -P "$miner_pid" 2>/dev/null 2>&1 || true
                echo "$(date): Miner process group $miner_pid terminated (forcefully)"
            fi
        fi
    fi
    return 0
}
# PODMAN-SPECIFIC FUNCTIONS
is_docker_running() {
    docker ps > /dev/null 2>&1
    return $?
}
is_podman_container_running() {
    docker ps --filter "name=^podman$" --format "{{.Names}}" | grep -q "^podman$" && return 0 || return 1
}
get_podman_child_containers() {
    if [ "$PODMAN_READY" = true ] && is_podman_container_running; then
        docker exec podman podman ps --format "{{.Names}}" 2>/dev/null | \
            grep -v "^tunnel-api-" | \
            grep -v "^frpc-api-" | \
            sort | tr '\n' ' ' | xargs
    else
        echo ""
    fi
}
confirm_podman_idle() {
    local loops=${1:-$IDLE_CONFIRM_LOOPS}
    local check_interval=5  # seconds
    echo "$(date): Confirming Podman is idle (checking $loops times, $check_interval second intervals)..."
    for ((i=1; i<=loops; i++)); do
        echo "$(date): Podman idle check $i/$loops..."
        # Check if shutdown was requested
        if [[ $SHUTDOWN_REQUESTED -eq 1 ]]; then
            echo "$(date): Shutdown requested during idle confirmation, aborting..."
            return 1
        fi
        # Check if Podman container is running
        if ! is_podman_container_running; then
            echo "$(date): Podman container not found → UNAVAILABLE → BREAKING (safe failure mode)"
            return 1
        fi
        # Get current child containers
        local child_containers=$(get_podman_child_containers)
        if [ -n "$child_containers" ]; then
            echo "$(date): Found child containers: [$child_containers] → BREAKING idle check (Podman busy)"
            return 1
        else
            echo "$(date): No child containers found → Podman IDLE"
        fi
        # If this is not the last check, wait and continue
        if [ $i -lt $loops ]; then
            echo "$(date): Waiting $check_interval seconds for next idle check..."
            sleep $check_interval
        fi
    done
    echo "$(date): Podman confirmed idle after $loops consecutive checks"
    return 0
}
process_podman_event() {
    local container_name="$1"
    local status="$2"
    local event_time="$3"
    # Skip tunnel-api and frpc-api containers
    if [[ "$container_name" == tunnel-api-* ]] || [[ "$container_name" == frpc-api-* ]]; then
        echo "$(date): Skipping tunnel/frpc container: $container_name"
        return
    fi
    case "$status" in
        init|start|create|unpause|restart)
            echo "$(date): IMMEDIATE REACTION to Podman $status event → Podman busy → INSTANT stop_miner"
            stop_miner || true
            ;;
        kill|destroy|stop|die|died|pause)
            echo "$(date): Podman STOP/PAUSE event ($status) → Confirm Podman idle, then start miner..."
            # Wait a moment for operation to complete
            sleep 1
            # Confirm Podman is actually idle
            if confirm_podman_idle $IDLE_CONFIRM_LOOPS; then
                echo "$(date): Podman confirmed IDLE → start_miner"
                start_miner || true
            else
                echo "$(date): Podman still busy or unavailable → keep miner stopped"
            fi
            ;;
        *)
            ;;
    esac
}
# MINER CONTROL FUNCTIONS
# Function to start miner
start_miner() {
    local pid_file="/run/rigcontrol/${SERVICE_TYPE}_miner.pid"
    # Check if miner is already running
    if is_miner_alive; then
        echo "$(date): Miner already running for $SERVICE_TYPE (PID: $(cat "$pid_file"))"
        echo "$(date): Miner output goes to this service's journal (journalctl -f)"
        return 0  # Exit early - miner is already running
    elif [[ -f "$pid_file" ]]; then
        echo "$(date): Stale PID file found for $SERVICE_TYPE - cleaning up..."
        stop_miner || true
        echo "$(date): Starting fresh miner after cleanup..."
        # Continue to start fresh miner
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
    local LOG_FILE="/run/rigcontrol/${SERVICE_TYPE}_miner.log"
    # Create PID file directory
    mkdir -p /run/rigcontrol
    if [[ "$API_PORT" -gt 0 && "${ALWAYS_LOGS,,}" != "true" ]]; then
        echo "$(date): Known miner with API - starting without log file (nothing reads it)"
        setsid bash -c \
            'echo "Miner starting at $(date)"; \
             echo "API: '"$API_HOST:$API_PORT"'"; \
             trap '\''echo "Miner exiting at $(date)"; rm -f "'"$pid_file"'"'\'' EXIT; \
             '"$START_CMD"'' \
            < /dev/null &
        echo $! > "$pid_file"
    else
        if [[ "$API_PORT" -gt 0 ]]; then
            echo "$(date): ALWAYS_LOGS enabled - starting with log file for easier review of miner output (API is still used for stats, this is redundant with the service journal but kept for consistency/override-ability)"
        else
            echo "$(date): No API for this miner - still writing $LOG_FILE (needed for log-scraping telemetry), in addition to the service journal"
        fi
        rm -f "$LOG_FILE"
        setsid bash -c \
            'echo "Miner starting at $(date)"; \
             echo "API: '"$API_HOST:$API_PORT"'"; \
             trap '\''echo "Miner exiting at $(date)"; rm -f "'"$pid_file"'"'\'' EXIT; \
             ( while true; do \
                 sleep '"$LOG_CHECK_INTERVAL"'; \
                 sz=$(stat -c%s "'"$LOG_FILE"'" 2>/dev/null || echo 0); \
                 if [ "$sz" -gt '"$MAX_LOG_BYTES"' ]; then \
                     tail -c '"$MAX_LOG_BYTES"' "'"$LOG_FILE"'" > "'"$LOG_FILE"'.tmp" 2>/dev/null && cat "'"$LOG_FILE"'.tmp" > "'"$LOG_FILE"'" && rm -f "'"$LOG_FILE"'.tmp"; \
                 fi; \
               done ) & \
             '"$START_CMD"' 2>&1 | tee -a "'"$LOG_FILE"'"' \
            < /dev/null &
        echo $! > "$pid_file"
    fi
    sleep 2
    if is_miner_alive; then
        local miner_pid=$(cat "$pid_file")
        echo "$(date): Miner started (PID: $miner_pid)"
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
        echo "$(date): To view miner output: journalctl -u <service-name> -f"
        return 0
    else
        echo "$(date): ERROR: Failed to start miner!"
        return 1
    fi
}
# Function to stop miner (clean closure first)
stop_miner() {
    echo "$(date): Stopping $SERVICE_TYPE miner..."
    local pid_file="/run/rigcontrol/${SERVICE_TYPE}_miner.pid"
    if ! is_miner_alive; then
        echo "$(date): No running $SERVICE_TYPE process found - nothing to stop."
        rm -f "$pid_file"
        return 0
    fi
    local miner_pid=$(cat "$pid_file")
    kill_by_pid
    # Reset GPU if configured
    if [[ "${RESET_OC,,}" == "true" ]]; then
        echo "$(date): Resetting GPU clocks and power limits..."
        /usr/local/bin/gpu_reset_poststop.sh "$POWER_LIMIT"
    fi
    echo "$(date): Verifying cleanup..."
    if ps -p "$miner_pid" > /dev/null 2>&1; then
        echo "$(date): WARNING: Miner process still exists! Waiting 5s before retrying kill_by_pid..."
        sleep 5
        kill_by_pid
        if ps -p "$miner_pid" > /dev/null 2>&1; then
            echo "$(date): WARNING: Miner process still exists after retry!"
            return 1
        else
            echo "$(date): Miner process cleaned up successfully after retry."
            rm -f "$pid_file"
        fi
    else
        echo "$(date): Miner process cleaned up successfully."
        rm -f "$pid_file"
    fi
    echo "$(date): Final sleep 2 seconds..."
    sleep 2
}
# INITIAL PODMAN CHECK
echo "$(date): Performing initial Podman check..."
# PODMAN MODE: Wait for Podman container to be ready
echo "$(date): Waiting for Podman container to be ready..."
max_wait=60
waited=0
while [[ $waited -lt $max_wait ]]; do
    if is_podman_container_running; then
        echo "$(date): Podman container is running"
        PODMAN_READY=true
        break
    fi
    sleep 1
    ((waited++))
done
if [ "$PODMAN_READY" = true ]; then
    # Initial idle confirmation for Podman
    if confirm_podman_idle $IDLE_CONFIRM_LOOPS; then
        echo "$(date): Podman confirmed IDLE at startup → start_miner"
        start_miner || true
    else
        echo "$(date): Podman BUSY or UNAVAILABLE at startup → stop_miner"
        stop_miner || true
    fi
else
    echo "$(date): Podman container not ready after $max_wait seconds → stop_miner"
    stop_miner || true
fi
# PODMAN EVENT MONITORING LOOP
echo "$(date): Starting Podman event monitor..."
# Main monitoring loop with restart on failure
while [[ $SHUTDOWN_REQUESTED -eq 0 ]]; do
    # PODMAN EVENT STREAM
    echo "$(date): Connecting to Podman events stream..."
    docker exec podman podman events \
        --filter 'type=container' \
        --format '{{.Time}}|{{.Status}}|{{.Name}}' 2>&1 | \
    while IFS='|' read -r event_time status container_name; do
        # Check for shutdown request
        if [[ $SHUTDOWN_REQUESTED -eq 1 ]]; then
            echo "$(date): Shutdown requested, breaking event loop..."
            break 2  # Break out of both loops
        fi
        # Skip empty lines or malformed events
        [ -z "$status" ] && continue
        [ -z "$container_name" ] && continue
        # Process Podman event
        process_podman_event "$container_name" "$status" "$event_time"
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
    # Check if podman container is running
    if ! is_podman_container_running; then
        echo "$(date): ERROR: Podman container not running. Waiting 30 seconds..."
        PODMAN_READY=false
        # Wait for Podman to restart
        max_wait=60
        waited=0
        while [[ $waited -lt $max_wait && $SHUTDOWN_REQUESTED -eq 0 ]]; do
            if is_podman_container_running; then
                echo "$(date): Podman container restarted"
                PODMAN_READY=true
                break
            fi
            sleep 1
            ((waited++))
        done
        if [ "$PODMAN_READY" = false ]; then
            echo "$(date): Podman container not available after $max_wait seconds"
            stop_miner || true
            continue
        fi
    fi
    # Wait before retrying
    echo "$(date): Podman events stream ended, restarting monitor in 5 seconds..."
    sleep 5
done
# Final cleanup before exit
echo "$(date): Performing final cleanup..."
stop_miner || true
echo "$(date): Podman event monitor stopped gracefully"
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
Environment="IDLE_CONFIRM_LOOPS=7"
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
Environment="IDLE_CONFIRM_LOOPS=7"
Environment="POWER_LIMIT="
ExecStopPost=/usr/local/bin/gpu_reset_poststop.sh
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
Environment="IDLE_CONFIRM_LOOPS=7"
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
