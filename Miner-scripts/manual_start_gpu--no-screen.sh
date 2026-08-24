sudo tee /usr/local/bin/manual_start_gpu.sh > /dev/null <<'EOF'
#!/bin/bash
set -Eeuo pipefail
shopt -s inherit_errexit
echo "========================================"
echo "MANUAL MINER START SCRIPT"
echo "========================================"
echo "[init] Loading configuration..."
MINER_CONF="/etc/rigcontrol/miner.conf"
API_CONF="/etc/rigcontrol/api.conf"
CFG_FILE="/etc/rigcontrol/rig-gpu.conf"
BASE_DIR="/opt/miners"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "[init] MINER_CONF=$MINER_CONF"
echo "[init] API_CONF=$API_CONF"
echo "[init] CFG_FILE=$CFG_FILE"
echo "[init] BASE_DIR=$BASE_DIR"
echo "[init] SCRIPT_DIR=$SCRIPT_DIR"
mkdir -p "$BASE_DIR"
: "${MAX_LOG_BYTES:=10485760}"  # 10 MB default, override via env
: "${LOG_CHECK_INTERVAL:=60}"  # seconds between size checks
case "$CFG_FILE" in
    *.json) RIG_GPU_JSON="$CFG_FILE" ;;
    *) RIG_GPU_JSON="${CFG_FILE%.conf}.json" ;;
esac
if [[ ! -f "$CFG_FILE" && ! -f "$RIG_GPU_JSON" ]]; then
    echo "Missing rig config: neither $CFG_FILE nor $RIG_GPU_JSON exists"
    exit 1
fi
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
APPLY_OC=$(get_rig_conf "APPLY_OC" "0")
RESET_OC=$(get_rig_conf "RESET_OC" "0")
APPLY_OC="${APPLY_OC//\"/}"
RESET_OC="${RESET_OC//\"/}"
APPLY_OC="${APPLY_OC,,}"
RESET_OC="${RESET_OC,,}"
: "${APPLY_OC:=false}"
: "${RESET_OC:=false}"
echo "[oc] APPLY_OC: $APPLY_OC"
echo "[oc] RESET_OC: $RESET_OC"
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
if [[ ! -f "$API_CONF" ]]; then
    echo "[api] WARNING: $API_CONF not found"
else
    echo "[api] Loading API settings from $API_CONF"
    source "$API_CONF"
fi
if [[ -n "${!MINER_API_PORT_VAR:-}" ]]; then
    API_PORT="${!MINER_API_PORT_VAR}"
    echo "[api] Found specific API_PORT: $MINER_API_PORT_VAR=$API_PORT (from $API_CONF)"
else
    AGENT_CONF_PORT="$(_read_agent_conf_val "$MINER_API_PORT_VAR")"
    if [[ -n "$AGENT_CONF_PORT" ]]; then
        API_PORT="$AGENT_CONF_PORT"
        echo "[api] Found specific API_PORT: $MINER_API_PORT_VAR=$API_PORT (from $AGENT_CONF, not in $API_CONF)"
    else
        : "${API_PORT:=0}"
        echo "[api] Using generic API_PORT: $API_PORT"
    fi
fi
if [[ -n "${!MINER_API_HOST_VAR:-}" ]]; then
    API_HOST="${!MINER_API_HOST_VAR}"
    echo "[api] Found specific API_HOST: $MINER_API_HOST_VAR=$API_HOST (from $API_CONF)"
else
    AGENT_CONF_HOST="$(_read_agent_conf_val "$MINER_API_HOST_VAR")"
    if [[ -n "$AGENT_CONF_HOST" ]]; then
        API_HOST="$AGENT_CONF_HOST"
        echo "[api] Found specific API_HOST: $MINER_API_HOST_VAR=$API_HOST (from $AGENT_CONF, not in $API_CONF)"
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
SERVICE_TYPE="gpu"
echo "========================================"
echo "STARTUP CONFIGURATION SUMMARY"
echo "========================================"
echo "Miner Name:      $MINER_NAME"
echo "Screen Session:  $SERVICE_TYPE"
echo "Worker Name:     $WORKER_NAME"
echo "API:             $API_HOST:$API_PORT"
echo "Wallet:          $WALLET"
echo "Pool:            $POOL"
echo "Apply GPU OC:    $APPLY_OC"
echo "Reset GPU on Stop: $RESET_OC"
echo "========================================"
START_CMD=$(get_start_cmd "$MINER_NAME")
echo "[debug] START_CMD: $START_CMD"
check_api_health() {
    if [[ "$API_PORT" -eq 0 ]]; then
        return 0
    fi
    if timeout 2 bash -c "echo > /dev/tcp/$API_HOST/$API_PORT" 2>/dev/null; then
        return 0
    else
        return 1
    fi
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
        echo "[$(date)] Miner already running for $SERVICE_TYPE (PID: $(cat "$pid_file"))"
        echo "[$(date)] To view output: tail -f $LOG_FILE"
        return 0
    elif [[ -f "$pid_file" ]]; then
        echo "[$(date)] Stale PID file found for $SERVICE_TYPE - cleaning up..."
        rm -f "$pid_file"
        echo "[$(date)] Starting fresh miner after cleanup..."
    fi
    if [[ "${APPLY_OC,,}" == "true" ]]; then
        OC_TARGET="${ALGO:-}"
        if [[ -z "$OC_TARGET" || "$OC_TARGET" == "0" ]]; then
            OC_TARGET="${CUSTOM_MINER:-}"
        fi
        if [[ -n "$OC_TARGET" && "$OC_TARGET" != "0" ]]; then
            echo "[$(date)] Applying GPU clocks for '$OC_TARGET'..."
            /usr/local/bin/gpu_apply_ocs.sh "$OC_TARGET"
        else
            echo "[$(date)] Applying GPU clocks skipped - no ALGO or CUSTOM_MINER name available."
        fi
    fi
    echo "[$(date)] Starting $SERVICE_TYPE..."
    echo "[$(date)] API: $API_HOST:$API_PORT"
    echo "[$(date)] Full Command: $START_CMD"
    if [[ "$API_PORT" -gt 0 ]]; then
        echo "[$(date)] Running in API mode (health checks enabled)"
    else
        echo "[$(date)] Running in no-API mode (no known API integration for this miner - health checks disabled; use CUSTOM_MINER_PROCESS_NAME / CUSTOM_MINER_LOG_PATH telemetry log-scraping instead if needed)"
    fi
    mkdir -p /run/rigcontrol
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
    sleep 3
    if is_miner_alive; then
        local miner_pid=$(cat "$pid_file")
        echo "[$(date)] Miner started (PID: $miner_pid)"
        if [[ "$API_PORT" -gt 0 ]]; then
            echo "[$(date)] Waiting for API to start (max 30 seconds)..."
            local max_wait=30
            local waited=0
            while [[ $waited -lt $max_wait ]]; do
                if check_api_health; then
                    echo "[$(date)] API is up and running"
                    break
                fi
                sleep 1
                ((waited++))
            done
            if [[ $waited -ge $max_wait ]]; then
                echo "[$(date)] WARNING: API did not respond after $max_wait seconds"
            fi
        else
            echo "[$(date)] API disabled, skipping health check"
        fi
        echo "[$(date)] ARGS/OCS: $ARGS"
        echo "[$(date)] To view miner output: tail -f $LOG_FILE"
        echo "========================================"
        echo "MINER STARTED SUCCESSFULLY"
        echo "========================================"
        return 0
    else
        echo "[$(date)] ERROR: Failed to start miner process!"
        if [[ -f "$pid_file" ]]; then
            local miner_pid=$(cat "$pid_file")
            echo "[$(date)] Found PID file with PID: $miner_pid"
            if ps -p "$miner_pid" > /dev/null 2>&1; then
                echo "[$(date)] Process $miner_pid is running but health check failed"
            fi
        fi
        return 1
    fi
}
echo "Starting miner..."
start_miner
EOF
sudo chmod +x /usr/local/bin/manual_start_gpu.sh
