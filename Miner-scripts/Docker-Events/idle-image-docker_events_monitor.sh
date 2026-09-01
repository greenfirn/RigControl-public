sudo tee /usr/local/bin/docker_events_universal.sh > /dev/null <<'EOF'
#!/bin/bash
set -Eeuo pipefail
shopt -s inherit_errexit
: "${POWER_LIMIT:=150}"
SHUTDOWN_REQUESTED=0
: "${IDLE_CONFIRM_LOOPS:=2}"
: "${MAX_LOG_BYTES:=10485760}"  # 10 MB default, override via env
: "${LOG_CHECK_INTERVAL:=10}"  # seconds between size checks
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
echo "$(date): Using Docker events monitor"
echo "$(date): Target Image: ${TARGET_IMAGE}"
echo "$(date): Docker running confirm loops: $IDLE_CONFIRM_LOOPS"
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
    grep -E "^${key}=" "$AGENT_CONF" | tail -n1 | cut -d= -f2- || true
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
# get_start_cmd() (02-load_configs.sh) only reads $ARGS for CUSTOM_MINER now - known miners
# run the dashboard-built $MINER_COMMAND instead, so the API flag has to land there or it's
# silently dropped from the actual launched command. Custom miners still read $ARGS directly.
if [[ "$API_PORT" -gt 0 ]]; then
    if [[ -n "${CUSTOM_MINER:-}" && "$CUSTOM_MINER" != "0" ]]; then
        ARGS=$(add_api_flags "$API_LOOKUP_NAME" "$API_HOST" "$API_PORT" "$ARGS")
    else
        MINER_COMMAND=$(add_api_flags "$API_LOOKUP_NAME" "$API_HOST" "$API_PORT" "$MINER_COMMAND")
    fi
fi
START_CMD=$(get_start_cmd "$MINER_NAME")
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
kill_by_pid() {
    local pid_file="/run/rigcontrol/${SERVICE_TYPE}_miner.pid"
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
check_docker_target_container() {
    candidates=$(docker ps -a \
        --filter "ancestor=${TARGET_IMAGE}" \
        --format "{{.ID}} {{.Names}}")
    match_id=""
    while read -r cid cname; do
        if [[ "$cname" == "$TARGET_NAME" ]]; then
            match_id="$cid"
            break
        fi
        if [[ "$cname" == ${TARGET_NAME}* ]]; then
            suffix="${cname#${TARGET_NAME}}"
            if [[ "$suffix" =~ ^[0-9]+$ ]]; then
                match_id="$cid"
                break
            fi
        fi
    done <<< "$candidates"
    if [ -z "$match_id" ]; then
        echo "no matching container found"
        return 1
    fi
    status=$(docker inspect -f '{{.State.Status}}' "$match_id" 2>/dev/null)
    if [ "$status" = "running" ]; then
        echo "target container running"
        return 0
    else
        echo "target container exists but status=$status"
        return 1
    fi
}
confirm_docker_container_running() {
    local loops=${1:-$IDLE_CONFIRM_LOOPS}
    local check_interval=2
    echo "$(date): Confirming Docker target container is running (checking $loops times, $check_interval second intervals)..."
    for ((i=1; i<=loops; i++)); do
        echo "$(date): Docker running check $i/$loops..."
        if [[ $SHUTDOWN_REQUESTED -eq 1 ]]; then
            echo "$(date): Shutdown requested during running confirmation, aborting..."
            return 1
        fi
        if ! is_docker_running; then
            echo "$(date): Docker not running → UNAVAILABLE → BREAKING (cannot confirm)"
            return 1
        fi
        if check_docker_target_container; then
            echo "$(date): Target container confirmed running → continue checking"
        else
            echo "$(date): Target container NOT running → BREAKING (container not running)"
            return 1
        fi
        if [ $i -lt $loops ]; then
            echo "$(date): Waiting $check_interval seconds for next running check..."
            sleep $check_interval
        fi
    done
    echo "$(date): Docker container confirmed running after $loops consecutive checks"
    return 0
}
process_docker_event() {
    local container_name="$1"
    local status="$2"
    local image="$3"
    name_match=0
    if [[ "$container_name" == "$TARGET_NAME" ]]; then
        name_match=1
    elif [[ "$container_name" == ${TARGET_NAME}* ]]; then
        suffix="${container_name#${TARGET_NAME}}"
        if [[ "$suffix" =~ ^[0-9]+$ ]]; then
            name_match=1
        fi
    fi
    if [[ "$image" != "$TARGET_IMAGE" ]] || [[ "$name_match" -eq 0 ]]; then
        echo "$(date): Skipping non-matching container"
        return
    fi
    case "$status" in
        start|create|unpause|restart)
            echo "$(date): Docker START event ($status) → Confirm container is running, then start miner..."
            sleep 1
            if confirm_docker_container_running $IDLE_CONFIRM_LOOPS; then
                echo "$(date): Docker container confirmed running → START miner"
                start_miner || true
            else
                echo "$(date): Docker container not running (transient state) → no action"
            fi
            ;;
        kill|destroy|stop|die|died|pause)
            echo "$(date): Docker STOP/PAUSE event ($status) → IMMEDIATE stop_miner"
            stop_miner || true
            ;;
        *)
            ;;
    esac
}
start_miner() {
    if screen -list | grep -q "$SERVICE_TYPE"; then
        echo "$(date): Screen session exists for $SERVICE_TYPE - checking if miner is alive..."
        local pid_file="/run/rigcontrol/${SERVICE_TYPE}_miner.pid"
        if [[ -f "$pid_file" ]]; then
            local miner_pid=$(cat "$pid_file")
            if ps -p "$miner_pid" > /dev/null 2>&1; then
                echo "$(date): Miner already running in screen session: $SERVICE_TYPE"
                echo "$(date): To view: sudo screen -r $SERVICE_TYPE"
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
    echo "$(date): Starting $SERVICE_TYPE..."
    echo "$(date): API: $API_HOST:$API_PORT"
    echo "$(date): Command: $START_CMD"
    mkdir -p /run/rigcontrol
    if [[ "$API_PORT" -gt 0 && "${ALWAYS_LOGS,,}" != "true" ]]; then
        echo "$(date): Known miner with API - starting without log file (nothing reads it)"
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
        if [[ "${START_CMD,,}" == *"keryx-miner "* ]]; then
            LOG_FILE="/run/rigcontrol/${SERVICE_TYPE}_miner.log"
            SCRAP_LOG="/run/rigcontrol/${SERVICE_TYPE}_miner.scrap.log"
            rm -f "$LOG_FILE" "$SCRAP_LOG"
            touch "$LOG_FILE"
            screen -dmS "$SERVICE_TYPE" -L -Logfile "$SCRAP_LOG" bash -c \
                'stty rows 50 cols 250; \
                 echo "Miner starting at $(date)"; \
                 echo "API: '"$API_HOST:$API_PORT"'"; \
                 echo "$$" > "'"/run/rigcontrol/${SERVICE_TYPE}_miner.pid"'"; \
                 trap '\''echo "Miner exiting at $(date)"; rm -f "'"/run/rigcontrol/${SERVICE_TYPE}_miner.pid"'"'\'' EXIT; \
                 ( while true; do \
                     sed -u -r "s/\x1b\[[0-9]+;[0-9]+[Hf]/\n/g; s/\x1b\][^\x07]*\x07//g; s/\x1b[()][A-Za-z0-9]//g; s/\x1b\[\??[0-9;]*[a-zA-Z]//g" "'"$SCRAP_LOG"'" 2>/dev/null | grep -Pao "[0-9]{4}-[0-9]{2}-[0-9]{2}\s[0-9]{2}:[0-9]{2}:[0-9]{2}\sUTC\s\[[A-Z]+\s*\].*?(?=[0-9]{4}-[0-9]{2}-[0-9]{2}\s[0-9]{2}:[0-9]{2}:[0-9]{2}\sUTC\s\[|$)" 2>/dev/null | sed -r "s/ +$//" | awk '\''!seen[$0]++'\'' > "'"$LOG_FILE"'.tmp" 2>/dev/null && mv -f "'"$LOG_FILE"'.tmp" "'"$LOG_FILE"'"; \
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
    fi
    sleep 2
    if screen -list | grep -q "$SERVICE_TYPE"; then
        echo "$(date): Miner started in screen session: $SERVICE_TYPE"
        if [[ -f "/run/rigcontrol/${SERVICE_TYPE}_miner.pid" ]]; then
            local miner_pid=$(cat "/run/rigcontrol/${SERVICE_TYPE}_miner.pid")
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
        echo "$(date): To view miner output: sudo screen -r $SERVICE_TYPE"
        return 0
    else
        echo "$(date): ERROR: Failed to start screen session!"
        return 1
    fi
}
stop_miner() {
    echo "$(date): Stopping $SERVICE_TYPE miner..."
    if ! screen -list | grep -q "$SERVICE_TYPE"; then
        echo "$(date): No $SERVICE_TYPE screen session found - nothing to stop."
        return 0
    fi
    local pid_file="/run/rigcontrol/${SERVICE_TYPE}_miner.pid"
    echo "$(date): Sending Ctrl+C to screen session (lets the miner unwind/flush state and release its API port before we tear anything down)..."
    screen -S "$SERVICE_TYPE" -X stuff $'\003'
    echo "$(date): Waiting 8 seconds for graceful exit..."
    sleep 8
    if [[ -f "$pid_file" ]] && ps -p "$(cat "$pid_file")" > /dev/null 2>&1; then
        echo "$(date): Still running after Ctrl+C - sending clean quit to screen session..."
        screen -S "$SERVICE_TYPE" -X quit
        echo "$(date): Waiting 5 seconds for miner cleanup..."
        sleep 5
    else
        echo "$(date): Miner exited cleanly after Ctrl+C."
    fi
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
    local screen_pids=$(pgrep -f "SCREEN.*$SERVICE_TYPE" 2>/dev/null || true)
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
    if screen -list | grep -q "$SERVICE_TYPE"; then
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
echo "$(date): Checking Docker target container..."
if confirm_docker_container_running $IDLE_CONFIRM_LOOPS; then
    echo "$(date): Docker target container confirmed running at startup → start_miner"
    start_miner || true
else
    echo "$(date): Docker target container not running at startup → stop_miner"
    stop_miner || true
fi
echo "$(date): Starting Docker event monitor..."
while [[ $SHUTDOWN_REQUESTED -eq 0 ]]; do
    echo "$(date): Connecting to Docker events stream..."
    # KillMode=mixed (see [Service] block below) only signals this script itself, not this
    # blocking `docker events` child - a bash script parked in wait() for a foreground pipe
    # like this one does not act on a trapped signal until the pipe itself returns, so an
    # un-timed-out `docker events` stream would leave the TERM trap (and this whole script)
    # stuck indefinitely whenever no container events happen to be arriving. The timeout
    # below bounds that wait so SHUTDOWN_REQUESTED gets rechecked - and any pending trap
    # gets to run - at least every 15s even when the stream is idle.
    timeout 15 docker events --format "{{.Type}} {{.Action}} {{.Actor.Attributes.name}} {{.Actor.Attributes.image}}" 2>&1 | \
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
# KillMode=mixed (not the default control-group) so a stop/restart only signals this
# tracked process - control-group would signal the screen session and the miner running
# inside it at the same instant, racing ahead of (and generally beating) stop_miner()'s
# own graceful Ctrl+C/quit sequence below, killing the miner directly before this script
# ever gets a chance to shut it down cleanly.
KillMode=mixed
TimeoutStopSec=60
StandardOutput=journal
StandardError=journal
SendSIGKILL=no
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
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
# KillMode=mixed (not the default control-group) so a stop/restart only signals this
# tracked process - control-group would signal the screen session and the miner running
# inside it at the same instant, racing ahead of (and generally beating) stop_miner()'s
# own graceful Ctrl+C/quit sequence below, killing the miner directly before this script
# ever gets a chance to shut it down cleanly.
KillMode=mixed
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
# KillMode=mixed (not the default control-group) so a stop/restart only signals this
# tracked process - control-group would signal the screen session and the miner running
# inside it at the same instant, racing ahead of (and generally beating) stop_miner()'s
# own graceful Ctrl+C/quit sequence below, killing the miner directly before this script
# ever gets a chance to shut it down cleanly.
KillMode=mixed
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
sudo journalctl -u docker_events_cpu.service -f
sudo journalctl -u docker_events_gpu.service -f
sudo journalctl -u docker_events_aux.service -f
