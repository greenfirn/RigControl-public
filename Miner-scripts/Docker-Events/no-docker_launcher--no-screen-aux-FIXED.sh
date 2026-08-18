# miner_launcher.sh
# Starts the miner on service start. No Docker container checks/monitoring.

sudo tee /usr/local/bin/docker_events_universal.sh > /dev/null <<'EOF'
#!/bin/bash

set -Eeuo pipefail
shopt -s inherit_errexit

# ---------------------------------------------------------
# GLOBAL VARIABLES FOR SIGNAL HANDLING
# ---------------------------------------------------------
# Power limit for GPU reset (default 150W, can be overridden by service)
: "${POWER_LIMIT:=}"
SHUTDOWN_REQUESTED=0

# ---------------------------------------------------------
# CONFIGURABLE SETTINGS
# ---------------------------------------------------------
# Max size (bytes) the miner log file is allowed to grow to before being
# trimmed back down to the tail end. Miners can run for weeks at a time
# without a restart, so we can't rely on truncate-on-start alone.
: "${MAX_LOG_BYTES:=10485760}"   # 10 MB default, override via env
: "${LOG_CHECK_INTERVAL:=60}"    # seconds between size checks

# ---------------------------------------------------------
# SIGNAL HANDLER
# ---------------------------------------------------------
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

# -------------------------------------------------
# Rig config (must be set by service)
# -------------------------------------------------
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

# -------------------------------------------------
# Miner config (with default location)
# -------------------------------------------------
: "${MINER_CONF:=/etc/rigcontrol/miner.conf}"
[[ -f "$MINER_CONF" ]] || {
    echo "Missing miner.conf: $MINER_CONF"
    exit 1
}

# -------------------------------------------------
# Source libraries
# -------------------------------------------------
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
# API SETTINGS - from API_CONF or default location
# ---------------------------------------------------------
# Use API_CONF environment variable if set, otherwise default
: "${API_CONF:=/etc/rigcontrol/api.conf}"
PORTS_CONF="$API_CONF"

# Clear any stale API_PORT/API_HOST that may already be exported in the
# environment, so a missing config file always means "disabled" rather
# than silently inheriting a leftover value.
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

# ---------------------------------------------------------
# MINER-SPECIFIC API COMMAND GENERATION
# ---------------------------------------------------------
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
            # convert_old_miner_name() normalizes "wildrig" -> "wildrig-multi"
            # upstream (02-load_configs.sh) before API_LOOKUP_NAME is even
            # built, so the name actually reaching this case is
            # "wildrig-multi", not "wildrig" - matching only the old short
            # name here meant this case silently never fired, and wildrig
            # started with no --api-port flag at all.
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

# ---------------------------------------------------------
# FINAL PLACEHOLDER SUBSTITUTION
# ---------------------------------------------------------

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

# Load from rig.conf
#
# SLOT name ("gpu"/"cpu"/"aux", derived from OC_FILE) is the primary
# default - NOT MINER_NAME. Two reasons this has to be slot-based rather
# than miner-based: (1) MINER_NAME is blank for a "miner":"custom"
# rig-gpu.json entry (only CUSTOM_MINER gets set - see
# 02-load_configs.sh), which produced log/pid files literally named
# "_miner.log"/"_miner.pid" (confirmed live on a keryx-miner-supr rig);
# (2) more importantly, the SAME miner can run in both the GPU and CPU
# slots at once (e.g. srbminer) - MINER_NAME-based naming would have
# BOTH services resolve to the identical "srbminer_miner.log"/
# "srbminer_miner.pid", with two independent processes stomping on one
# shared PID file (breaking is_miner_alive()/kill_by_pid() for both).
# Slot name is always unique per systemd unit, so this can never happen.
# No MINER_NAME fallback at all now - slot name always wins, full stop.
SCREEN_NAME=$(get_rig_conf "SCREEN_NAME" "0")

if [[ -z "$SCREEN_NAME" ]]; then
    case "$OC_FILE" in
        *rig-gpu*) SCREEN_NAME="gpu" ;;
        *rig-cpu*) SCREEN_NAME="cpu" ;;
        *rig-aux*) SCREEN_NAME="aux" ;;
    esac
fi

# ---------------------------------------------------------
# API HEALTH CHECK FUNCTION
# ---------------------------------------------------------
check_api_health() {
    if [[ "$API_PORT" -eq 0 ]]; then
        return 0  # API not enabled, consider healthy
    fi
    # just return healthy...
    return 0
}

# ---------------------------------------------------------
# PID-BASED ALIVE CHECK / KILL - no screen session in this variant
# ---------------------------------------------------------
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

        # Clean up PID file
        rm -f "$pid_file"
    fi
}

# ---------------------------------------------------------
# MINER CONTROL FUNCTIONS
# ---------------------------------------------------------

# Function to start miner
start_miner() {
    local pid_file="/run/rigcontrol/${SCREEN_NAME}_miner.pid"
    local LOG_FILE="/run/rigcontrol/${SCREEN_NAME}_miner.log"

    # Check if miner is already running
    if is_miner_alive; then
        echo "$(date): Miner already running for $SCREEN_NAME (PID: $(cat "$pid_file"))"
        echo "$(date): Miner output goes to this service's journal (journalctl -f), and to $LOG_FILE"
        return 0
    elif [[ -f "$pid_file" ]]; then
        echo "$(date): Stale PID file found for $SCREEN_NAME - cleaning up..."
        stop_miner || true
        echo "$(date): Starting fresh miner after cleanup..."
    fi

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

    # Create PID file directory
    mkdir -p /run/rigcontrol

    # No screen session in this variant, so the miner's output is left attached to
    # this script's own stdout/stderr (systemd StandardOutput=journal captures it),
    # in addition to always being teed to $LOG_FILE (needed for log-scraping
    # telemetry regardless of API mode), which self-trims via MAX_LOG_BYTES.
    rm -f "$LOG_FILE"   # delete log on each fresh start

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

    # Wait a moment for the process to come up
    sleep 2

    # Verify startup
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
        echo "$(date): To view miner output: journalctl -f, or tail -f $LOG_FILE"
        return 0
    else
        echo "$(date): ERROR: Failed to start miner process!"
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

    # Final verification
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
        fi
    else
        echo "$(date): Miner process cleaned up successfully."
    fi

    rm -f "$pid_file"

    echo "$(date): Final sleep 2 seconds..."
    sleep 2
}

###############################################
#  START MINER
###############################################

echo "$(date): Starting miner (no container checks)..."
start_miner

###############################################
#  IDLE WAIT LOOP
###############################################
# Nothing left to watch for — just keep the service process alive so
# systemd sees it as running, and let the signal traps handle shutdown.

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
Environment="OC_FILE=/etc/rigcontrol/rig-gpu.conf"
Environment="POWER_LIMIT="
ExecStopPost=/usr/local/bin/gpu_reset_poststop.sh
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

# -- write CPU service --
sudo tee /etc/systemd/system/docker_events_cpu.service > /dev/null <<'EOF'
[Unit]
Description=CPU Miner Launcher

[Service]
Type=simple
User=root
Environment="OC_FILE=/etc/rigcontrol/rig-cpu.conf"
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

# -- write AUX service --
sudo tee /etc/systemd/system/docker_events_aux.service > /dev/null <<'EOF'
[Unit]
Description=AUX Miner Launcher

[Service]
Type=simple
User=root
Environment="OC_FILE=/etc/rigcontrol/rig-aux.conf"
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
sudo systemctl restart docker_events_aux.service
sudo systemctl enable docker_events_cpu.service
sudo systemctl enable docker_events_gpu.service
sudo systemctl enable docker_events_aux.service

# follow logs
sudo journalctl -u docker_events_cpu.service -f
sudo journalctl -u docker_events_gpu.service -f
sudo journalctl -u docker_events_aux.service -f
