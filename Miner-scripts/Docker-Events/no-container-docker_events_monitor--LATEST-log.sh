sudo tee /usr/local/bin/docker_events_universal.sh > /dev/null <<'EOF'
#!/bin/bash
set -Eeuo pipefail
shopt -s inherit_errexit
# Power limit for GPU reset (default 150W, can be overridden by service)
: "${POWER_LIMIT:=}"
SHUTDOWN_REQUESTED=0
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
case "$OC_FILE" in
    *rig-gpu*) SCREEN_NAME="gpu" ;;
    *rig-cpu*) SCREEN_NAME="cpu" ;;
    *rig-aux*) SCREEN_NAME="aux" ;;
esac
check_api_health() {
    if [[ "$API_PORT" -eq 0 ]]; then
        return 0
    fi
    return 0
}
kill_by_pid() {
    local pid_file="/run/rigcontrol/${SCREEN_NAME}_miner.pid"
    if [[ -f "$pid_file" ]]; then
        local miner_pid=$(cat "$pid_file")
        if ps -p "$miner_pid" > /dev/null 2>&1; then
            echo "$(date): WARNING: Miner process still alive after screen quit - forcing kill (PID: $miner_pid)..."
            kill -15 "$miner_pid" 2>/dev/null
            sleep 2
            if ps -p "$miner_pid" > /dev/null 2>&1; then
                echo "$(date): Miner not responding to SIGTERM - sending SIGKILL..."
                kill -9 "$miner_pid" 2>/dev/null
                sleep 1
            fi
            pkill -P "$miner_pid" 2>/dev/null 2>&1 || true
            echo "$(date): Miner process $miner_pid terminated (forcefully)"
        fi
        rm -f "$pid_file"
    fi
}
is_docker_running() {
    docker ps > /dev/null 2>&1
    return $?
}
any_container_running() {
    local running_count=$(docker ps -q 2>/dev/null | wc -l)
    if [[ $running_count -gt 0 ]]; then
        echo "$(date): Found $running_count running container(s)"
        return 0
    else
        echo "$(date): No containers running"
        return 1
    fi
}
confirm_no_containers_running() {
    local loops=${1:-$IDLE_CONFIRM_LOOPS}
    local check_interval=2
    echo "$(date): Confirming no containers are running (checking $loops times, $check_interval second intervals)..."
    for ((i=1; i<=loops; i++)); do
        echo "$(date): No-container check $i/$loops..."
        if [[ $SHUTDOWN_REQUESTED -eq 1 ]]; then
            echo "$(date): Shutdown requested during confirmation, aborting..."
            return 1
        fi
        if ! is_docker_running; then
            echo "$(date): Docker not running → UNAVAILABLE → BREAKING (cannot confirm)"
            return 1
        fi
        if any_container_running; then
            echo "$(date): Containers found running → BREAKING (containers exist)"
            return 1
        else
            echo "$(date): No containers running → continue checking"
        fi
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
            echo "$(date): ANY Docker START event ($status) → IMMEDIATE stop_miner"
            stop_miner || true
            ;;
        kill|destroy|stop|die|died|pause)
            echo "$(date): Docker STOP event ($status) → Checking if all containers stopped..."
            sleep 3
            if confirm_no_containers_running $IDLE_CONFIRM_LOOPS; then
                echo "$(date): Confirmed no containers running → START miner"
                start_miner || true
            else
                echo "$(date): Containers still running → no action"
            fi
            ;;
        *)
            echo "$(date): Unhandled Docker action: $status for $container_name"
            ;;
    esac
}
start_miner() {
    if screen -list | grep -q "$SCREEN_NAME"; then
        echo "$(date): Screen session exists for $SCREEN_NAME - checking if miner is alive..."
        local pid_file="/run/rigcontrol/${SCREEN_NAME}_miner.pid"
        if [[ -f "$pid_file" ]]; then
            local miner_pid=$(cat "$pid_file")
            if ps -p "$miner_pid" > /dev/null 2>&1; then
                echo "$(date): Miner already running in screen session: $SCREEN_NAME"
                echo "$(date): To view: sudo screen -r $SCREEN_NAME"
                return 0
            else
                echo "$(date): Miner process is dead but screen session exists - cleaning up..."
                stop_miner || true
                echo "$(date): Starting fresh miner after cleanup..."
            fi
        else
            echo "$(date): Screen session exists but no PID file found - cleaning up..."
            stop_miner || true
            echo "$(date): Starting fresh miner after cleanup..."
        fi
    fi
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
    echo "$(date): Starting $SCREEN_NAME..."
    echo "$(date): API: $API_HOST:$API_PORT"
    echo "$(date): Command: $START_CMD"
    mkdir -p /run/rigcontrol
    if [[ "$API_PORT" -gt 0 && "${ALWAYS_LOGS,,}" != "true" ]]; then
        echo "$(date): Known miner with API - starting without log file (nothing reads it)"
        screen -fn -dmS "$SCREEN_NAME" bash -c \
            'echo "Miner starting at $(date)"; \
             echo "API: '"$API_HOST:$API_PORT"'"; \
             echo "$$" > "'"/run/rigcontrol/${SCREEN_NAME}_miner.pid"'"; \
             trap '\''echo "Miner exiting at $(date)"; rm -f "'"/run/rigcontrol/${SCREEN_NAME}_miner.pid"'"'\'' EXIT; \
             '"$START_CMD"''
    else
        if [[ "$API_PORT" -gt 0 ]]; then
            echo "$(date): ALWAYS_LOGS enabled - starting with log file for easier review of miner output (API is still used for stats)"
        else
            echo "$(date): No API for this miner - starting with log file (needed for log-scraping telemetry)"
        fi
        LOG_FILE="/run/rigcontrol/${SCREEN_NAME}_miner.log"
        rm -f "$LOG_FILE"
        screen -fn -dmS "$SCREEN_NAME" bash -c \
            'echo "Miner starting at $(date)"; \
             echo "API: '"$API_HOST:$API_PORT"'"; \
             echo "$$" > "'"/run/rigcontrol/${SCREEN_NAME}_miner.pid"'"; \
             trap '\''echo "Miner exiting at $(date)"; rm -f "'"/run/rigcontrol/${SCREEN_NAME}_miner.pid"'"'\'' EXIT; \
             ( while true; do \
                 sleep '"$LOG_CHECK_INTERVAL"'; \
                 sz=$(stat -c%s "'"$LOG_FILE"'" 2>/dev/null || echo 0); \
                 if [ "$sz" -gt '"$MAX_LOG_BYTES"' ]; then \
                     tail -c '"$MAX_LOG_BYTES"' "'"$LOG_FILE"'" > "'"$LOG_FILE"'.tmp" 2>/dev/null && cat "'"$LOG_FILE"'.tmp" > "'"$LOG_FILE"'" && rm -f "'"$LOG_FILE"'.tmp"; \
                 fi; \
               done ) & \
             '"$START_CMD"' 2>&1 | sed -u -r "s/\x1b\[[0-9;]*[a-zA-Z]//g" | tee -a "'"$LOG_FILE"'"'
    fi
    sleep 2
    if screen -list | grep -q "$SCREEN_NAME"; then
        echo "$(date): Miner started in screen session: $SCREEN_NAME"
        if [[ -f "/run/rigcontrol/${SCREEN_NAME}_miner.pid" ]]; then
            local miner_pid=$(cat "/run/rigcontrol/${SCREEN_NAME}_miner.pid")
            echo "$(date): Miner process PID: $miner_pid"
        fi
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
        echo "$(date): To view miner output: sudo screen -r $SCREEN_NAME"
        return 0
    else
        echo "$(date): ERROR: Failed to start screen session!"
        return 1
    fi
}
stop_miner() {
    echo "$(date): Stopping $SCREEN_NAME miner..."
    if ! screen -list | grep -q "$SCREEN_NAME"; then
        echo "$(date): No $SCREEN_NAME screen session found - nothing to stop."
        return 0
    fi
    echo "$(date): Sending clean quit to screen session..."
    screen -S "$SCREEN_NAME" -X quit
    echo "$(date): Waiting 10 seconds for miner cleanup..."
    sleep 10
    local pid_file="/run/rigcontrol/${SCREEN_NAME}_miner.pid"
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
    local screen_pids=$(pgrep -f "SCREEN.*$SCREEN_NAME" 2>/dev/null || true)
    if [[ -n "$screen_pids" ]]; then
        echo "$(date): Cleaning up leftover screen processes..."
        kill -15 $screen_pids 2>/dev/null
        sleep 2
        kill -9 $screen_pids 2>/dev/null 2>&1 || true
    fi
    if [[ "${RESET_OC,,}" == "true" ]]; then
        echo "$(date): Resetting GPU clocks and power limits..."
        /usr/local/bin/gpu_reset_poststop.sh "$POWER_LIMIT"
    fi
    echo "$(date): Verifying cleanup..."
    if screen -list | grep -q "$SCREEN_NAME"; then
        echo "$(date): WARNING: Screen session still exists!"
        return 1
    else
        echo "$(date): Screen session cleaned up successfully."
    fi
    rm -f "$pid_file"
    echo "$(date): Final sleep 2 seconds..."
    sleep 2
}
echo "$(date): Performing initial Docker container check..."
if any_container_running; then
    echo "$(date): Containers found running at startup → stop_miner (do not start miner)"
    stop_miner || true
else
    echo "$(date): No containers running at startup → start_miner"
    start_miner || true
fi
echo "$(date): Starting Docker event monitor..."
while [[ $SHUTDOWN_REQUESTED -eq 0 ]]; do
    echo "$(date): Connecting to Docker events stream..."
    docker events --format "{{.Type}} {{.Action}} {{.Actor.Attributes.name}} {{.Actor.Attributes.image}}" 2>&1 | \
    while read -r type action name image; do
        if [[ $SHUTDOWN_REQUESTED -eq 1 ]]; then
            echo "$(date): Shutdown requested, breaking event loop..."
            break 2
        fi
        if [ "$type" != "container" ]; then
            continue
        fi
        process_docker_event "$name" "$action" "$image"
    done
    if [[ $SHUTDOWN_REQUESTED -eq 1 ]]; then
        echo "$(date): Shutdown requested, exiting main loop..."
        break
    fi
    if ! is_docker_running; then
        echo "$(date): ERROR: Docker daemon not responding. Waiting 30 seconds..."
        sleep 30
        continue
    fi
    echo "$(date): Docker events stream ended, restarting monitor in 5 seconds..."
    sleep 5
done
echo "$(date): Performing final cleanup..."
stop_miner || true
echo "$(date): Docker event monitor stopped gracefully"
EOF
sudo chmod +x /usr/local/bin/docker_events_universal.sh
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
sudo systemctl daemon-reload
sudo systemctl enable docker_events_gpu.service
sudo systemctl restart docker_events_gpu.service
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
sudo systemctl enable docker_events_cpu.service
sudo systemctl restart docker_events_cpu.service
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
sudo systemctl enable docker_events_aux.service
sudo systemctl restart docker_events_aux.service
sudo journalctl -u docker_events_gpu.service -f
sudo journalctl -u docker_events_cpu.service -f
sudo journalctl -u docker_events_aux.service -f
