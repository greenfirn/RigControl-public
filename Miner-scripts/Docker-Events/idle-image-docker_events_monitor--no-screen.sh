# idle-image-docker_events_monitor--no-screen.sh
# No-screen variant (miner runs as a plain background process via setsid,
# no GNU screen session) of the target-image idle monitor. Its own
# idle-detection logic (check_docker_target_container, TARGET_IMAGE/
# TARGET_NAME tracking, etc.) is unchanged - only start_miner/stop_miner/
# kill_by_pid were converted, and the config-loading engine (API_LOOKUP_NAME/
# CUSTOM_MINER support, the keryx-miner add_api_flags case, MAX_LOG_BYTES
# log trimming) was brought up to date to match the other no-screen variants.

sudo tee /usr/local/bin/docker_events_universal.sh > /dev/null <<'EOF'
#!/bin/bash

set -Eeuo pipefail
shopt -s inherit_errexit

# Power limit for GPU reset (default 150W, can be overridden by service)
: "${POWER_LIMIT:=150}"
SHUTDOWN_REQUESTED=0

# Number of times to check for running state for Docker  
: "${IDLE_CONFIRM_LOOPS:=2}"

# Max size (bytes) the miner log file is allowed to grow to before being
# trimmed back down to the tail end. Miners can run for weeks at a time
# without a restart, so we can't rely on truncate-on-start alone.
: "${MAX_LOG_BYTES:=10485760}"   # 10 MB default, override via env
: "${LOG_CHECK_INTERVAL:=60}"    # seconds between size checks

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

# RIG_GPU_JSON derivation duplicated here (matches 00-get_rig_conf.sh) so
# this pre-flight check can accept a JSON-only rig - one that has
# rig-*.json but no .conf file at all. get_rig_conf() itself already
# prefers JSON once sourced below; this just stops the script from
# refusing to start over a missing .conf file that JSON can fully cover.
# Derived from CFG_FILE (rig-gpu.conf -> rig-gpu.json, rig-cpu.conf ->
# rig-cpu.json, rig-aux.conf -> rig-aux.json) so GPU/CPU/AUX rigs each
# check their own JSON file.
RIG_GPU_JSON="${CFG_FILE%.conf}.json"

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

# ---------------------------------------------------------
# DOCKER EVENT SOURCE
# ---------------------------------------------------------
echo "$(date): Using Docker events monitor"
echo "$(date): Target Image: ${TARGET_IMAGE}"
echo "$(date): Docker running confirm loops: $IDLE_CONFIRM_LOOPS"

# API_CONF: path to api.conf (default /etc/rigcontrol/api.conf).
: "${API_CONF:=/etc/rigcontrol/api.conf}"
PORTS_CONF="$API_CONF"

unset API_PORT API_HOST

API_LOOKUP_NAME="$MINER_NAME"
if [[ -n "${CUSTOM_MINER:-}" && "$CUSTOM_MINER" != "0" ]]; then
    API_LOOKUP_NAME="$CUSTOM_MINER"
fi

# AGENT_CONF: the dashboard agent's own conf (rigcontrol_telemetry.sh reads
# <NAME>_API_HOST/<NAME>_API_PORT from here for custom miners) - checked as a
# fallback below so a custom miner's API settings only need to be defined
# once, instead of also having to be duplicated into api.conf.
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

# SCREEN_NAME is kept as the process identifier (used for the PID file and log file
# name below, and still read from the same rig-config key for compatibility) even
# though this variant no longer launches the miner inside a GNU screen session.
SCREEN_NAME=$(get_rig_conf "SCREEN_NAME" "0")

if [[ -z "$SCREEN_NAME" ]]; then
    case "$OC_FILE" in
        *rig-gpu*) SCREEN_NAME="gpu" ;;
        *rig-cpu*) SCREEN_NAME="cpu" ;;
        *rig-aux*) SCREEN_NAME="aux" ;;
    esac
fi

check_api_health() {
    if [[ "$API_PORT" -eq 0 ]]; then
        return 0
    fi
    return 0
}

# Screen-free replacement for the old "screen -list | grep -q $SCREEN_NAME" check:
# the PID file is now the single source of truth for whether the miner is alive.
is_miner_alive() {
    local pid_file="/run/rigcontrol/${SCREEN_NAME}_miner.pid"

    [[ -f "$pid_file" ]] || return 1

    local pid
    pid=$(cat "$pid_file" 2>/dev/null)
    [[ -n "$pid" ]] || return 1

    ps -p "$pid" > /dev/null 2>&1
}

# ---------------------------------------------------------
# PID-BASED KILL - Backup for crashed miners
# ---------------------------------------------------------
kill_by_pid() {
    local pid_file="/run/rigcontrol/${SCREEN_NAME}_miner.pid"

    if [[ -f "$pid_file" ]]; then
        local miner_pid=$(cat "$pid_file")

        if ps -p "$miner_pid" > /dev/null 2>&1; then
            # Signal the whole process group (setsid made $miner_pid the group leader),
            # not just the single PID - the miner itself runs as a CHILD of the
            # backgrounded wrapper (the EXIT trap prevents bash from exec-replacing
            # itself into $START_CMD), so signaling only $miner_pid would hit the
            # wrapper and leave the actual miner process running, orphaned.
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

    # kill_by_pid's job is just "attempt to stop it" - the internal ps checks above
    # are expected to fail (that's the SUCCESS case, miner is gone), and with
    # set -e active, letting one of those propagate as this function's own return
    # value would abort the whole monitor script. stop_miner() does its own
    # explicit ps check afterward to determine actual success/failure.
    return 0
}

# ---------------------------------------------------------
# DOCKER-SPECIFIC FUNCTIONS
# ---------------------------------------------------------
is_docker_running() {
    docker ps > /dev/null 2>&1
    return $?
}

check_docker_target_container() {
    # Get all containers based on image
    candidates=$(docker ps -a \
        --filter "ancestor=${TARGET_IMAGE}" \
        --format "{{.ID}} {{.Names}}")

    match_id=""

    while read -r cid cname; do
        # Exact match
        if [[ "$cname" == "$TARGET_NAME" ]]; then
            match_id="$cid"
            break
        fi

        # Prefix match: name begins with TARGET_NAME
        if [[ "$cname" == ${TARGET_NAME}* ]]; then
            suffix="${cname#${TARGET_NAME}}"

            # Suffix must be 1+ digits ONLY
            if [[ "$suffix" =~ ^[0-9]+$ ]]; then
                match_id="$cid"
                break
            fi
        fi
    done <<< "$candidates"

    # No matching container found
    if [ -z "$match_id" ]; then
        echo "no matching container found"
        return 1
    fi

    # Check container status
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
    local check_interval=2  # seconds
    
    echo "$(date): Confirming Docker target container is running (checking $loops times, $check_interval second intervals)..."
    
    for ((i=1; i<=loops; i++)); do
        echo "$(date): Docker running check $i/$loops..."
        
        # Check if shutdown was requested
        if [[ $SHUTDOWN_REQUESTED -eq 1 ]]; then
            echo "$(date): Shutdown requested during running confirmation, aborting..."
            return 1
        fi
        
        # Check if Docker is running
        if ! is_docker_running; then
            echo "$(date): Docker not running → UNAVAILABLE → BREAKING (cannot confirm)"
            return 1
        fi
        
        # Check if target container exists and is running
        if check_docker_target_container; then
            echo "$(date): Target container confirmed running → continue checking"
            # Continue checking to confirm it's stable
        else
            echo "$(date): Target container NOT running → BREAKING (container not running)"
            return 1
        fi
        
        # If this is not the last check, wait and continue
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
    
    # echo "$(date): Docker event - Container: $container_name, Action: $status, Image: $image"
    
    # DOCKER-SPECIFIC LOGIC: Name matching with image
    name_match=0
    if [[ "$container_name" == "$TARGET_NAME" ]]; then
        name_match=1
    elif [[ "$container_name" == ${TARGET_NAME}* ]]; then
        suffix="${container_name#${TARGET_NAME}}"
        if [[ "$suffix" =~ ^[0-9]+$ ]]; then
            name_match=1
        fi
    fi
    
    # Process only if image AND name match
    if [[ "$image" != "$TARGET_IMAGE" ]] || [[ "$name_match" -eq 0 ]]; then
        echo "$(date): Skipping non-matching container"
        return
    fi
    
    # DOCKER LOGIC: 
    # - Start events → CONFIRM container running, then start miner
    # - Stop events → IMMEDIATE stop miner
    case "$status" in
        start|create|unpause|restart)
            echo "$(date): Docker START event ($status) → Confirm container is running, then start miner..."
            
            # Wait a moment for container to fully start
            sleep 1
            
            # Confirm container is actually running (not just transient)
            if confirm_docker_container_running $IDLE_CONFIRM_LOOPS; then
                echo "$(date): Docker container confirmed running → START miner"
                start_miner
            else
                echo "$(date): Docker container not running (transient state) → no action"
            fi
            ;;
        
        kill|destroy|stop|die|died|pause)
            echo "$(date): Docker STOP/PAUSE event ($status) → IMMEDIATE stop_miner"
            stop_miner
            ;;
        
        *)
            # Ignore irrelevant Docker events
            # echo "$(date): DEBUG: Unhandled Docker action: $status for $container_name"
            ;;
    esac
}

# ---------------------------------------------------------
# MINER CONTROL FUNCTIONS
# ---------------------------------------------------------

# Function to start miner
start_miner() {
    local pid_file="/run/rigcontrol/${SCREEN_NAME}_miner.pid"

    # Check if miner is already running
    if is_miner_alive; then
        echo "$(date): Miner already running for $SCREEN_NAME (PID: $(cat "$pid_file"))"
        echo "$(date): Miner output goes to this service's journal (journalctl -f)"
        return 0  # Exit early - miner is already running
    elif [[ -f "$pid_file" ]]; then
        echo "$(date): Stale PID file found for $SCREEN_NAME - cleaning up..."
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
    
    echo "$(date): Starting $SCREEN_NAME..."
    echo "$(date): API: $API_HOST:$API_PORT"
    echo "$(date): Command: $START_CMD"
    if [[ "$API_PORT" -gt 0 ]]; then
        echo "$(date): Running in API mode (health checks enabled)"
    else
        echo "$(date): Running in no-API mode (no known API integration for this miner - health checks disabled; use CUSTOM_MINER_PROCESS_NAME / CUSTOM_MINER_LOG_PATH telemetry log-scraping instead if needed)"
    fi

    local LOG_FILE="/run/rigcontrol/${SCREEN_NAME}_miner.log"

    # Create PID file directory
    mkdir -p /run/rigcontrol

    # No screen session in this variant, so the miner's output is left attached to
    # this script's own stdout/stderr instead of a screen's - since the systemd
    # unit runs with StandardOutput=journal / StandardError=journal, that means
    # "sudo screen -r $SCREEN_NAME" is replaced by "journalctl -u <service> -f".
    if [[ "$API_PORT" -gt 0 ]]; then
        setsid bash -c \
            'echo "Miner starting at $(date)"; \
             echo "API: '"$API_HOST:$API_PORT"'"; \
             trap '\''echo "Miner exiting at $(date)"; rm -f "'"$pid_file"'"'\'' EXIT; \
             '"$START_CMD"'' \
            < /dev/null &
        echo $! > "$pid_file"
    else
        echo "$(date): No API for this miner - still writing $LOG_FILE (needed for log-scraping telemetry), in addition to the service journal"

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
    echo "$(date): Stopping $SCREEN_NAME miner..."

    local pid_file="/run/rigcontrol/${SCREEN_NAME}_miner.pid"

    if ! is_miner_alive; then
        echo "$(date): No running $SCREEN_NAME process found - nothing to stop."
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

###############################################
#  INITIAL CHECK
###############################################

echo "$(date): Performing initial Docker container check..."

# DOCKER MODE: Check if target container is running, confirm, then start miner
echo "$(date): Checking Docker target container..."

if confirm_docker_container_running $IDLE_CONFIRM_LOOPS; then
    echo "$(date): Docker target container confirmed running at startup → start_miner"
    start_miner
else
    echo "$(date): Docker target container not running at startup → stop_miner"
    stop_miner
fi

###############################################
#  DOCKER EVENT MONITORING LOOP
###############################################

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
stop_miner
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
Environment="OC_FILE=/etc/rigcontrol/rig-cpu.conf"
Environment="IDLE_CONFIRM_LOOPS=3"
ExecStartPre=/bin/chmod +x /usr/local/bin/docker_events_universal.sh
ExecStart=/usr/local/bin/docker_events_universal.sh
#Environment="MINER_CONF=/etc/rigcontrol/miner.conf"
#Environment="API_CONF=/etc/rigcontrol/api.conf"
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

# -- write GPU service --
sudo tee /etc/systemd/system/docker_events_gpu.service > /dev/null <<'EOF'
[Unit]
Description=Docker Events GPU Miner Monitor
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=root
Environment="OC_FILE=/etc/rigcontrol/rig-gpu.conf"
Environment="IDLE_CONFIRM_LOOPS=3"
Environment="POWER_LIMIT=150"
ExecStopPost=/usr/local/bin/gpu_reset_poststop.sh 150
ExecStartPre=/bin/chmod +x /usr/local/bin/docker_events_universal.sh
ExecStart=/usr/local/bin/docker_events_universal.sh
#Environment="MINER_CONF=/etc/rigcontrol/miner.conf"
#Environment="API_CONF=/etc/rigcontrol/api.conf"
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
sudo systemctl enable docker_events_cpu.service
sudo systemctl enable docker_events_gpu.service

# follow logs
sudo journalctl -u docker_events_cpu.service -f
sudo journalctl -u docker_events_gpu.service -f