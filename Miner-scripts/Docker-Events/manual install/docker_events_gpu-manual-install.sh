sudo systemctl stop docker_events_gpu.service
sudo systemctl stop docker_events_cpu.service
sudo systemctl disable docker_events_gpu.service
sudo systemctl disable docker_events_cpu.service
sudo mkdir -v /usr/local/bin
sudo tee /usr/local/bin/docker_events_gpu.sh > /dev/null <<'EOF'
#!/bin/bash
set -euo pipefail
DIAGNOSTIC=false
if [ ! -f "/opt/miners/rigel/current/rigel" ]; then
    sudo mkdir -p /opt/miners/rigel/current
    cd /opt/miners/rigel
    sudo wget https://github.com/rigelminer/rigel/releases/download/1.23.1/rigel-1.23.1-linux.tar.gz
    sudo tar -xvf rigel-1.23.1-linux.tar.gz --strip-components=1
    sudo cp -v rigel /opt/miners/rigel/current
else
    echo "rigel already exists in current directory"
fi
TARGET_IMAGE="ubuntu:24.04"
TARGET_NAME="clore-default-"
SERVICE_TYPE="gpu"
START_CMD="/opt/miners/rigel/current/rigel"
ARGS="-a kawpow -o stratum+ssl://ca.quai.herominers.com:1185 -o stratum+ssl://us2.quai.herominers.com:1185 -u wallet-address -p x -w 5950X-2-3070 --api-bind 127.0.0.1:5000"
APPLY_OC="false"
RESET_OC="false"
if [[ -z "$START_CMD" ]]; then
    echo "$(date): START_CMD empty — refusing to start miner"
    exit 1
fi
: "${POWER_LIMIT:=}"
SHUTDOWN_REQUESTED=0
: "${MAX_LOG_BYTES:=10485760}"  # 10 MB default, override via env
: "${LOG_CHECK_INTERVAL:=60}"  # seconds between size checks
handle_signal() {
    local sig=$1
    echo "$(date): Received signal $sig - initiating graceful shutdown..."
    SHUTDOWN_REQUESTED=1
    if [[ -n "${DIAG_HEARTBEAT_PID:-}" ]]; then
        kill "$DIAG_HEARTBEAT_PID" 2>/dev/null || true
    fi
    echo "$(date): Stopping miner if running..."
    stop_miner || true
    pkill -f "docker events" 2>/dev/null || true
    exit 0
}
trap 'handle_signal TERM' TERM
trap 'handle_signal INT' INT
trap 'handle_signal HUP' HUP
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
is_miner_alive() {
    local pid_file="/run/rigcontrol/${SERVICE_TYPE}_miner.pid"
    [[ -f "$pid_file" ]] || return 1
    local pid
    pid=$(cat "$pid_file" 2>/dev/null)
    [[ -n "$pid" ]] || return 1
    ps -p "$pid" > /dev/null 2>&1
}
start_miner() {
    local pid_file="/run/rigcontrol/${SERVICE_TYPE}_miner.pid"
    local LOG_FILE="/run/rigcontrol/${SERVICE_TYPE}_miner.log"
    if is_miner_alive; then
        echo "$(date): Miner already running for $SERVICE_TYPE (PID: $(cat "$pid_file"))"
        echo "$(date): Miner output goes to this service's journal (journalctl -f) and $LOG_FILE"
        return 0
    elif [[ -f "$pid_file" ]]; then
        echo "$(date): Stale PID file found for $SERVICE_TYPE - cleaning up..."
        stop_miner || true
        echo "$(date): Starting fresh miner after cleanup..."
    fi
    if [[ "${APPLY_OC,,}" == "true" ]]; then
        echo "$(date): Applying GPU clocks..."
        /usr/local/bin/gpu_apply_ocs.sh
    fi
    echo "$(date): Starting $SERVICE_TYPE..."
    echo "$(date): Command: $START_CMD $ARGS"
    mkdir -p /run/rigcontrol
    rm -f "$LOG_FILE"
    setsid bash -c \
        'echo "Miner starting at $(date)"; \
         trap '\''echo "Miner exiting at $(date)"; rm -f "'"$pid_file"'"'\'' EXIT; \
         ( while true; do \
             sleep '"$LOG_CHECK_INTERVAL"'; \
             sz=$(stat -c%s "'"$LOG_FILE"'" 2>/dev/null || echo 0); \
             if [ "$sz" -gt '"$MAX_LOG_BYTES"' ]; then \
                 tail -c '"$MAX_LOG_BYTES"' "'"$LOG_FILE"'" > "'"$LOG_FILE"'.tmp" 2>/dev/null && cat "'"$LOG_FILE"'.tmp" > "'"$LOG_FILE"'" && rm -f "'"$LOG_FILE"'.tmp"; \
             fi; \
           done ) & \
         '"$START_CMD $ARGS"' 2>&1 | tee -a "'"$LOG_FILE"'"' \
        < /dev/null &
    echo $! > "$pid_file"
    sleep 2
    if is_miner_alive; then
        local miner_pid=$(cat "$pid_file")
        echo "$(date): Miner started (PID: $miner_pid)"
        echo "$(date): ARGS/OCS: $ARGS"
        echo "$(date): To view miner output: journalctl -u docker_events_${SERVICE_TYPE}.service -f"
        return 0
    else
        echo "$(date): ERROR: Failed to start miner!"
        return 1
    fi
}
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
check_target_container() {
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
        echo "no matching container treat as stopped"
        return 1
    fi
    status=$(docker inspect -f '{{.State.Status}}' "$match_id" 2>/dev/null)
    if [ "$status" = "running" ]; then
        return 0
    else
        echo "status=$status treat as stopped"
        return 1
    fi
}
: "${DIAG_IDLE_CONFIRMATION_THRESHOLD:=7}"
DIAG_SYSTEM_IDLE=true
DIAG_CONFIRMED_IDLE=false
DIAG_JOB_COUNT=0
DIAG_LAST_JOB_START=""
DIAG_IDLE_CONFIRMATION_COUNT=0
diag_format_duration() {
    local seconds=$1
    if [ "$seconds" -lt 60 ]; then
        echo "${seconds}s"
    elif [ "$seconds" -lt 3600 ]; then
        echo "$((seconds / 60))m$((seconds % 60))s"
    else
        echo "$((seconds / 3600))h$(((seconds % 3600) / 60))m$((seconds % 60))s"
    fi
}
diag_calculate_duration() {
    local start_seconds end_seconds
    start_seconds=$(date -d "$1" +%s 2>/dev/null || echo "$1")
    end_seconds=$(date -d "$2" +%s 2>/dev/null || echo "$2")
    diag_format_duration $((end_seconds - start_seconds))
}
diag_update_system_state() {
    local reason="" state
    if ! docker ps > /dev/null 2>&1; then
        state="active:no-docker"
    elif check_target_container; then
        state="active:target-running"
    else
        state="idle"
    fi
    if [[ "$state" == active:* ]]; then
        reason="${state#active:}"
        if [ "$DIAG_SYSTEM_IDLE" = true ] || [ "$DIAG_CONFIRMED_IDLE" = true ]; then
            DIAG_SYSTEM_IDLE=false
            DIAG_CONFIRMED_IDLE=false
            DIAG_JOB_COUNT=$((DIAG_JOB_COUNT + 1))
            DIAG_LAST_JOB_START=$(date '+%H:%M:%S')
            echo "$(date): [DIAG] SYSTEM_ACTIVE #$DIAG_JOB_COUNT (reason: $reason)"
        fi
        DIAG_IDLE_CONFIRMATION_COUNT=0
    else
        if [ "$DIAG_SYSTEM_IDLE" = false ]; then
            DIAG_SYSTEM_IDLE=true
            DIAG_CONFIRMED_IDLE=false
            DIAG_IDLE_CONFIRMATION_COUNT=1
            echo "$(date): [DIAG] Idle detected, confirming... (1/$DIAG_IDLE_CONFIRMATION_THRESHOLD)"
        elif [ "$DIAG_CONFIRMED_IDLE" = false ]; then
            DIAG_IDLE_CONFIRMATION_COUNT=$((DIAG_IDLE_CONFIRMATION_COUNT + 1))
            if [ "$DIAG_IDLE_CONFIRMATION_COUNT" -ge "$DIAG_IDLE_CONFIRMATION_THRESHOLD" ]; then
                DIAG_CONFIRMED_IDLE=true
                if [ -n "$DIAG_LAST_JOB_START" ]; then
                    echo "$(date): [DIAG] Job #$DIAG_JOB_COUNT duration: $(diag_calculate_duration "$DIAG_LAST_JOB_START" "$(date '+%H:%M:%S')")"
                    DIAG_LAST_JOB_START=""
                fi
                echo "$(date): [DIAG] Confirmed IDLE"
            else
                echo "$(date): [DIAG] Confirming idle... ($DIAG_IDLE_CONFIRMATION_COUNT/$DIAG_IDLE_CONFIRMATION_THRESHOLD)"
            fi
        fi
    fi
}
diag_status_line() {
    local mining_icon=""
    is_miner_alive && mining_icon="⛏️🔥"
    if [ "$DIAG_CONFIRMED_IDLE" = true ]; then
        echo "$(date): [DIAG] ✅ IDLE $mining_icon | Jobs: $DIAG_JOB_COUNT"
    elif [ "$DIAG_SYSTEM_IDLE" = true ]; then
        echo "$(date): [DIAG] ⏳ IDLE? ($DIAG_IDLE_CONFIRMATION_COUNT/$DIAG_IDLE_CONFIRMATION_THRESHOLD) | Jobs: $DIAG_JOB_COUNT"
    else
        echo "$(date): [DIAG] 🔴 ACTIVE [started: $DIAG_LAST_JOB_START] | Job #$DIAG_JOB_COUNT"
    fi
}
diag_heartbeat_loop() {
    while [[ $SHUTDOWN_REQUESTED -eq 0 ]]; do
        diag_update_system_state
        diag_status_line
        sleep 5
    done
}
if [[ "$DIAGNOSTIC" == "true" ]]; then
    diag_heartbeat_loop &
    DIAG_HEARTBEAT_PID=$!
    echo "$(date): [DIAG] Diagnostic state tracker enabled (PID: $DIAG_HEARTBEAT_PID)"
fi
if check_target_container; then
    echo "$(date): Target container (${TARGET_IMAGE} name ${TARGET_NAME}) detected at startup"
    start_miner || true
else
    echo "$(date): Target container (${TARGET_IMAGE} name ${TARGET_NAME}) not found at startup"
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
            echo "$(date): non-container event: Type: $type, Action: $action, Name: $name"
            continue
        fi
        echo "$(date): Container event detected - Action: $action, Name: $name, Image: $image"
        name_match=0
        if [[ "$name" == "$TARGET_NAME" ]]; then
            name_match=1
        elif [[ "$name" == ${TARGET_NAME}* ]]; then
            suffix="${name#${TARGET_NAME}}"
            if [[ "$suffix" =~ ^[0-9]+$ ]]; then
                name_match=1
            fi
        fi
        if [[ "$image" == "$TARGET_IMAGE" && "$name_match" -eq 1 ]]; then
        case "$action" in
            start|create|unpause)
                echo "$(date): START event detected → Wait for start to complete"
                retry_count=0
                started=false
                while [[ $retry_count -lt 10 && $SHUTDOWN_REQUESTED -eq 0 ]]; do
                    sleep 0.2
                    if docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null | grep -q "running"; then
                        echo "$(date): Container confirmed running → start_miner"
                        start_miner || true
                        started=true
                        break
                    fi
                    retry_count=$((retry_count + 1))
                    echo "$(date): Start check attempt $retry_count: container not yet running"
                done
                if [[ "$started" = false && $SHUTDOWN_REQUESTED -eq 0 ]]; then
                    echo "$(date): WARNING: Container $name never reached 'running' state after $retry_count attempts"
                    if ! docker inspect "$name" &>/dev/null; then
                        echo "$(date): Container $name no longer exists"
                    fi
                fi
                ;;
            kill|destroy|stop|die)
                echo "$(date): STOP event detected ($action) → stop_miner"
                stop_miner || true
                ;;
            pause)
                echo "$(date): PAUSE event detected → Wait for pause to complete"
                retry_count=0
                while [[ $retry_count -lt 5 && $SHUTDOWN_REQUESTED -eq 0 ]]; do
                    sleep 0.1
                    status=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || echo "not_found")
                    case "$status" in
                        "paused")
                            echo "$(date): Container confirmed paused → stop_miner"
                            stop_miner || true
                            break
                            ;;
                        "not_found")
                            echo "$(date): Container removed while pausing → stop_miner"
                            stop_miner || true
                            break
                            ;;
                        "exited"|"dead")
                            echo "$(date): Container exited/died instead of pausing → stop_miner"
                            stop_miner || true
                            break
                            ;;
                    esac
                    retry_count=$((retry_count + 1))
                done
                if [[ $retry_count -eq 5 && $SHUTDOWN_REQUESTED -eq 0 ]]; then
                    echo "$(date): WARNING: Container $name never reached 'paused' state, checking current status"
                    final_status=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || echo "not_found")
                    if [[ "$final_status" != "running" ]]; then
                        echo "$(date): Container is $final_status → stop_miner"
                        stop_miner || true
                    fi
                fi
                ;;
            *)
                echo "$(date): DEBUG: Unhandled action: $action for $name"
                ;;
        esac
        fi
    done
    if [[ $SHUTDOWN_REQUESTED -eq 1 ]]; then
        echo "$(date): Shutdown requested, exiting main loop..."
        break
    fi
    if ! docker ps > /dev/null 2>&1; then
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
sudo chmod +x /usr/local/bin/docker_events_gpu.sh
sudo tee /etc/systemd/system/docker_events_gpu.service > /dev/null <<'EOF'
[Unit]
Description=Docker Events GPU Miner Monitor
After=docker.service
Requires=docker.service
[Service]
Type=simple
User=root
Environment="POWER_LIMIT="
ExecStartPre=/bin/chmod +x /usr/local/bin/docker_events_gpu.sh
ExecStart=/usr/local/bin/docker_events_gpu.sh
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
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
StandardOutput=journal
StandardError=journal
SendSIGKILL=no
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable docker_events_gpu.service
sudo systemctl start docker_events_gpu.service
sudo systemctl stop docker_events_gpu.service
sudo systemctl status docker_events_gpu.service
sudo journalctl -u docker_events_gpu.service -f
sudo systemctl disable docker_events_gpu.service
