sudo tee /usr/local/bin/rigcontrol_cmd.sh > /dev/null <<'EOF'
#!/bin/bash
set -e
LOG="/var/lib/rigcontrol/rigcontrol_cmd.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
GPU_SERVICE="${GPU_SERVICE_NAME:-docker_events_gpu.service}"
CPU_SERVICE="${CPU_SERVICE_NAME:-docker_events_cpu.service}"
AUX_SERVICE="${AUX_SERVICE_NAME:-docker_events_aux.service}"
WATCHDOG_SERVICE="${WATCHDOG_SERVICE_NAME:-rigcontrol_watchdog.service}"
# Workers tab -> Logs -> API call. rigcontrol_agent.sh has already resolved
# the actual running miner's stats-API endpoint (see resolve_active_miner_api()
# in rigcontrol_telemetry.sh) and passed it in via <PREFIX>_API_* env vars -
# this just fetches it and pretty-prints the response (jq, falling back to
# python3's json.tool, falling back to raw text for non-JSON APIs like
# TeamRedMiner's cgminer protocol).
rc_miner_api_fetch() {
    local prefix="$1"   # CPU | GPU | AUX
    local method_var="${prefix}_API_METHOD"
    local url_var="${prefix}_API_URL"
    local urlfb_var="${prefix}_API_URL_FALLBACK"
    local tcphost_var="${prefix}_API_TCP_HOST"
    local tcpport_var="${prefix}_API_TCP_PORT"
    local tcppayload_var="${prefix}_API_TCP_PAYLOAD"
    local miner_var="${prefix}_API_MINER"
    local reason_var="${prefix}_API_REASON"
    local method="${!method_var:-}"
    local url="${!url_var:-}"
    local url_fb="${!urlfb_var:-}"
    local tcp_host="${!tcphost_var:-}"
    local tcp_port="${!tcpport_var:-}"
    local tcp_payload="${!tcppayload_var:-}"
    local miner="${!miner_var:-}"
    local reason="${!reason_var:-}"

    if [[ "$method" != "http" && "$method" != "tcp" ]]; then
        echo "No active miner API available for $prefix."
        [[ -n "$reason" ]] && echo "$reason"
        return 1
    fi
    [[ -n "$miner" ]] && echo "[$prefix] miner: $miner"

    local body=""
    if [[ "$method" == "tcp" ]]; then
        body=$(timeout 4 bash -c '
            exec 3<>"/dev/tcp/'"$tcp_host"'/'"$tcp_port"'" || exit 1
            printf "%s" "$1" >&3
            cat <&3
        ' _ "$tcp_payload" 2>/dev/null) || true
    else
        body=$(curl -s -m 4 "$url" 2>/dev/null) || true
        if [[ -z "$body" && -n "$url_fb" ]]; then
            body=$(curl -s -m 4 "$url_fb" 2>/dev/null) || true
        fi
    fi

    if [[ -z "$body" ]]; then
        echo "No response from the miner's API."
        return 1
    fi
    if command -v jq >/dev/null 2>&1 && echo "$body" | jq . >/dev/null 2>&1; then
        echo "$body" | jq .
    elif command -v python3 >/dev/null 2>&1 && echo "$body" | python3 -m json.tool >/dev/null 2>&1; then
        echo "$body" | python3 -m json.tool
    else
        echo "$body"
    fi
}
# Read entire command from STDIN (multi-line safe)
RAW_CMD="$(cat)"
if [[ -z "$RAW_CMD" ]]; then
    echo "No command received"
    exit 1
fi
echo "==================================================" >> "$LOG"
echo "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"
echo "$RAW_CMD" >> "$LOG"
# Parse first line for structured commands
FIRST_LINE="$(echo "$RAW_CMD" | head -n1)"
CMD="$(echo "$FIRST_LINE" | awk '{print $1}')"
ARG="$(echo "$FIRST_LINE" | cut -d' ' -f2-)"
case "$CMD" in
    # GPU Miner Controls
    gpu.start)
        systemctl start "$GPU_SERVICE"
        echo "Started $GPU_SERVICE"
        ;;
    gpu.stop)
        systemctl stop "$GPU_SERVICE"
        echo "Stopped $GPU_SERVICE"
        ;;
    gpu.restart)
        systemctl restart "$GPU_SERVICE"
        echo "Restarted $GPU_SERVICE"
        ;;
    # CPU Miner Controls
    cpu.start)
        systemctl start "$CPU_SERVICE"
        echo "Started $CPU_SERVICE"
        ;;
    cpu.stop)
        systemctl stop "$CPU_SERVICE"
        echo "Stopped $CPU_SERVICE"
        ;;
    cpu.restart)
        systemctl restart "$CPU_SERVICE"
        echo "Restarted $CPU_SERVICE"
        ;;
    # AUX Service Controls
    aux.start)
        systemctl start "$AUX_SERVICE"
        echo "Started $AUX_SERVICE"
        ;;
    aux.stop)
        systemctl stop "$AUX_SERVICE"
        echo "Stopped $AUX_SERVICE"
        ;;
    aux.restart)
        systemctl restart "$AUX_SERVICE"
        echo "Restarted $AUX_SERVICE"
        ;;
    # Watchdog Controls (single unified service - see WATCHDOG_SERVICE)
    watchdog.start)
        systemctl enable "$WATCHDOG_SERVICE"
        systemctl start "$WATCHDOG_SERVICE"
        echo "Enabled + started $WATCHDOG_SERVICE"
        ;;
    watchdog.stop)
        systemctl disable "$WATCHDOG_SERVICE"
        systemctl stop "$WATCHDOG_SERVICE"
        echo "Disabled + stopped $WATCHDOG_SERVICE"
        ;;
    watchdog.restart)
        systemctl restart "$WATCHDOG_SERVICE"
        echo "Restarted $WATCHDOG_SERVICE"
        ;;
    # MINER API CALL (Workers tab -> Logs -> CPU/GPU/AUX API)
    cpu.api)
        rc_miner_api_fetch CPU
        ;;
    gpu.api)
        rc_miner_api_fetch GPU
        ;;
    aux.api)
        rc_miner_api_fetch AUX
        ;;
    # MODE SWITCHING
    mode.set)
        MODE="$(echo "$ARG" | tr '[:lower:]' '[:upper:]')"
        systemctl stop "$CPU_SERVICE" "$GPU_SERVICE"
        systemctl disable "$CPU_SERVICE" "$GPU_SERVICE"
        if [[ "$MODE" == "CPU" ]]; then
            systemctl enable "$CPU_SERVICE"
            systemctl start "$CPU_SERVICE"
            echo "Mode changed -> CPU"
        elif [[ "$MODE" == "GPU" ]]; then
            systemctl enable "$GPU_SERVICE"
            systemctl start "$GPU_SERVICE"
            echo "Mode changed -> GPU"
        else
            echo "Invalid mode: $ARG"
            exit 1
        fi
        ;;
    # SYSTEM REBOOT
    reboot)
        echo "Rebooting system..."
        systemctl reboot
        ;;
    # RAW MULTI-LINE SHELL COMMAND (DEFAULT)
    *)
        echo "[RAW EXECUTION]"
        bash -c "$RAW_CMD"
        ;;
esac
EOF
sudo chmod +x /usr/local/bin/rigcontrol_cmd.sh
