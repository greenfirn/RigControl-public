sudo tee /usr/local/bin/gpu_apply_ocs.sh > /dev/null <<'EOF'
#!/bin/bash
# gpu_apply_ocs.sh <algo_name> / <custom miner name>
# Generated from the dashboard's Overclock module - edit there, not by hand.
ALGO="${1:-}"
if [[ -z "$ALGO" ]]; then
    echo "Usage: $0 <algo_name>"
    exit 1
fi
ALGO_LOWER=$(echo "$ALGO" | tr '[:upper:]' '[:lower:]')
case "$ALGO_LOWER" in
    keryxhash|keryx-miner|keryx-minerx)
        CORE=1650
        CORE_OFFSET=200
        MEM=0
        MEM_OFFSET=1500
        POWER_LIMIT=0
        FAN_MODE="none"
        FAN_VALUE=""
        echo "Copying escrow.cert into place for keryx-miner..."
        if cp -v --update=none /escrow.cert /opt/miners/keryx-miner/current/; then
            echo "escrow.cert: success, file exists at /opt/miners/keryx-miner/current/escrow.cert"
        else
            echo "escrow.cert: copy failed"
        fi
        ;;
    *)
        echo "No OC profile defined for algo '$ALGO' - add a row for it in the dashboard's Overclock module"
        exit 1
        ;;
esac

echo "Setting GPU OC for algo '$ALGO': core=$CORE (+$CORE_OFFSET) mem=$MEM (+$MEM_OFFSET) power_limit=$POWER_LIMIT fan=$FAN_MODE:$FAN_VALUE"
CMD=(py-nvtool --setcore "$CORE" --setcoreoffset "$CORE_OFFSET" --setmem "$MEM" --setmemoffset "$MEM_OFFSET")
if [[ -n "$POWER_LIMIT" && "$POWER_LIMIT" != "0" ]]; then
    CMD+=(--setpl "$POWER_LIMIT")
fi
if [[ "$FAN_MODE" == "percent" ]]; then
    CMD+=(--setfan "$FAN_VALUE")
fi
"${CMD[@]}"
if [[ "$FAN_MODE" == "curve" ]]; then
    :
fi
EOF
sudo chmod +x /usr/local/bin/gpu_apply_ocs.sh
sudo /usr/local/bin/gpu_apply_ocs.sh keryx-miner