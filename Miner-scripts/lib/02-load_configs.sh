get_miner_bin() {
    local name="$1"
    local custom=$(get_rig_conf "CUSTOM_MINER" "0")
    if [[ -n "$custom" && "$custom" != "0" ]]; then
        echo "$BASE_DIR/$custom/current/$custom"
        return
    fi
    case "$name" in
        bzminer)      echo "$BZMINER_BIN" ;;
        wildrig-multi) echo "$WILDRIG_BIN" ;;
        xmrig)        echo "$XMRIG_BIN" ;;
        srbminer)     echo "$SRBMINER_BIN" ;;
        rigel)        echo "$RIGEL_BIN" ;;
        lolminer)     echo "$LOLMINER_BIN" ;;
        onezerominer) echo "$ONEZEROMINER_BIN" ;;
        gminer)       echo "$GMINER_BIN" ;;
        teamredminer) echo "$TEAMREDMINER_BIN" ;;
		trex)         echo "$TREXMINER_BIN" ;;
        *)
            echo "$(date): ERROR — Unknown miner '$name', no binary path available" >&2
            echo ""
            ;;
    esac
}
get_pool_url_list() {
    local urls=()
    if [[ -n "$POOL_URLS" && "$POOL_URLS" != "0" ]]; then
        local IFS='|'
        read -ra urls <<< "$POOL_URLS"
    fi
    if [[ ${#urls[@]} -eq 0 ]]; then
        urls=("$POOL")
    fi
    printf '%s\n' "${urls[@]}"
}
build_pool_cmd_args() {
    local miner="$1"
    local urls=()
    mapfile -t urls < <(get_pool_url_list)
    local bare_list=()
    local h
    for h in "${urls[@]}"; do
        h="${h#stratum+ssl://}"
        h="${h#stratum+tcp://}"
        bare_list+=("$h")
    done
    local out=""
    case "$miner" in
        xmrig)
            for h in "${bare_list[@]}"; do
                out+=" -o $h -u $WALLET -p $PASS"
            done
            ;;
        wildrig-multi)
            for h in "${bare_list[@]}"; do
                out+=" --url $h --user $WALLET --pass $PASS"
            done
            ;;
        gminer)
            for h in "${bare_list[@]}"; do
                out+=" --server $h --user $WALLET"
            done
            ;;
        trex)
            for u in "${urls[@]}"; do
                out+=" -o $u -u $WALLET -p $PASS"
            done
            ;;
        teamredminer)
            for u in "${urls[@]}"; do
                out+=" -o $u -u $WALLET -p $PASS"
            done
            ;;
        rigel)
            for u in "${urls[@]}"; do
                out+=" -o $u -u $WALLET"
            done
            ;;
        lolminer)
            for u in "${urls[@]}"; do
                out+=" --pool $u --user $WALLET --pass $PASS"
            done
            ;;
        srbminer)
            local joined
            joined=$(IFS=,; echo "${bare_list[*]}")
            out=" --pool $joined --wallet $WALLET"
            ;;
        bzminer)
            local joined
            joined=$(IFS=' '; echo "${urls[*]}")
            out=" -p $joined -w $WALLET"
            ;;
        onezerominer)
            local joined
            joined=$(IFS=,; echo "${urls[*]}")
            out=" --pool $joined --wallet $WALLET"
            ;;
        *)
            out=" -o $POOL -u $WALLET -p $PASS"
            ;;
    esac
    echo "$out"
}
convert_bzminer_oc_json_to_args() {
    local input="$1"
    if [[ ! "$input" =~ ^[[:space:]]*\" ]]; then
        echo "$input"
        return
    fi
    local out=""
    local line key raw_value value flag
    while IFS= read -r line; do
        line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^\"([a-zA-Z0-9_]+)\"[[:space:]]*:[[:space:]]*(.+)$ ]]; then
            key="${BASH_REMATCH[1]}"
            raw_value="${BASH_REMATCH[2]}"
            raw_value="${raw_value%,}"
            raw_value="${raw_value%\"}"; raw_value="${raw_value#\"}"
            raw_value="${raw_value%\]}"; raw_value="${raw_value#\[}"
            value="${raw_value//,/ }"
            value="$(echo "$value" | xargs)"
            [[ -z "$value" ]] && continue
            flag=""
            case "$key" in
                cpu_threads)            flag="--cpu_threads" ;;
                oc_lock_core_clock)     flag="--oc_lock_core_clock" ;;
                oc_core_clock_offset)   flag="--oc_core_clock_offset" ;;
                oc_lock_memory_clock)   flag="--oc_lock_memory_clock" ;;
                oc_memory_clock_offset) flag="--oc_memory_clock_offset" ;;
                oc_power_limit)         flag="--oc_power_limit" ;;
                oc_core_volt_offset)    flag="--oc_core_volt_offset" ;;
                oc_memory_volt_offset)  flag="--oc_memory_volt_offset" ;;
                oc_fan_speed)           flag="--oc_fan_speed" ;;
                oc_pstate)              flag="--oc_pstate" ;;
            esac
            [[ -n "$flag" ]] && out+=" $flag $value"
        fi
    done <<< "$input"
    echo "$out" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}
xmrig_value_is_truthy() {
    [[ "$1" == "true" || "$1" == "1" ]]
}
xmrig_value_is_falsy() {
    [[ "$1" == "false" || "$1" == "0" ]]
}
convert_xmrig_user_config_to_args() {
    local input="$1"
    if [[ ! "$input" =~ ^[[:space:]]*\" ]]; then
        echo "$input"
        return
    fi
    local out=""
    if [[ "$input" =~ \"randomx\"[[:space:]]*:[[:space:]]*\{[[:space:]]*\"1gb-pages\"[[:space:]]*:[[:space:]]*(true|false|1|0)[[:space:]]*\} ]]; then
        xmrig_value_is_truthy "${BASH_REMATCH[1]}" && out+=" --randomx-1gb-pages"
    fi
    local line key raw_value
    while IFS= read -r line; do
        line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^\"([a-zA-Z0-9_-]+)\"[[:space:]]*:[[:space:]]*(.+)$ ]]; then
            key="${BASH_REMATCH[1]}"
            raw_value="${BASH_REMATCH[2]}"
            raw_value="${raw_value%,}"
            raw_value="${raw_value%\"}"; raw_value="${raw_value#\"}"
            [[ -z "$raw_value" ]] && continue
            if [[ "$key" == "keepalive" ]]; then
                xmrig_value_is_truthy "$raw_value" && out+=" --keepalive"
                continue
            fi
            if [[ "$key" == "tls" ]]; then
                xmrig_value_is_truthy "$raw_value" && out+=" --tls"
                continue
            fi
            if [[ "$key" == "cpu" ]]; then
                xmrig_value_is_falsy "$raw_value" && out+=" --no-cpu"
                continue
            fi
            if [[ "$key" == "donate-level" ]]; then
                out+=" --donate-level $raw_value"
            fi
        fi
    done <<< "$input"
    echo "$out" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}
convert_xmrig_cpu_config_to_args() {
    local input="$1"
    [[ -z "$input" ]] && { echo ""; return; }
    local body="$input"
    if [[ "$input" =~ \"cpu\"[[:space:]]*:[[:space:]]*\{(.*)\}[[:space:]]*$ ]]; then
        body="${BASH_REMATCH[1]}"
    fi
    local out=""
    local line key raw_value
    while IFS= read -r line; do
        line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^\"([a-zA-Z0-9_-]+)\"[[:space:]]*:[[:space:]]*(.+)$ ]]; then
            key="${BASH_REMATCH[1]}"
            raw_value="${BASH_REMATCH[2]}"
            raw_value="${raw_value%,}"
            case "$key" in
                huge-pages)
                    xmrig_value_is_falsy "$raw_value" && out+=" --no-huge-pages"
                    ;;
                priority)
                    [[ "$raw_value" != "null" ]] && out+=" --cpu-priority=$raw_value"
                    ;;
                memory-pool)
                    xmrig_value_is_falsy "$raw_value" && out+=" --cpu-memory-pool=0"
                    ;;
                asm)
                    if xmrig_value_is_truthy "$raw_value"; then
                        out+=" --asm=auto"
                    elif xmrig_value_is_falsy "$raw_value"; then
                        out+=" --asm=none"
                    elif [[ "$raw_value" =~ ^\"(.*)\"$ ]]; then
                        out+=" --asm=${BASH_REMATCH[1]}"
                    fi
                    ;;
                rx)
                    if [[ "$raw_value" =~ ^\[(.*)\]$ ]]; then
                        local nums="${BASH_REMATCH[1]}"
                        local count=0
                        local mask=0
                        local n
                        local rx_list=()
                        IFS=',' read -ra rx_list <<< "$nums"
                        for n in "${rx_list[@]}"; do
                            n="$(echo "$n" | xargs)"
                            [[ -z "$n" ]] && continue
                            [[ "$n" =~ ^[0-9]+$ ]] || continue
                            (( count++ ))
                            (( mask |= (1 << n) ))
                        done
                        if (( count > 0 )); then
                            local hex
                            hex="$(printf '%X' "$mask")"
                            out+=" --threads=$count --cpu-affinity=0x$hex"
                        fi
                    fi
                    ;;
            esac
        fi
    done <<< "$body"
    echo "$out" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}
apply_xmrig_hugepages() {
    local pages="$1"
    [[ -n "$pages" && "$pages" != "0" && "$pages" =~ ^[0-9]+$ ]] || return 0
    if [[ -w /proc/sys/vm/nr_hugepages ]]; then
        echo "$pages" > /proc/sys/vm/nr_hugepages 2>/dev/null
    elif command -v sysctl >/dev/null 2>&1; then
        sysctl -w vm.nr_hugepages="$pages" >/dev/null 2>&1
    fi
    local applied
    applied="$(cat /proc/sys/vm/nr_hugepages 2>/dev/null)"
    if [[ "$applied" != "$pages" ]]; then
        echo "$(date): WARNING — could not set vm.nr_hugepages=$pages (currently $applied - likely missing container privileges/capabilities for this rig - huge pages may be unavailable to xmrig)." >&2
    fi
}
get_start_cmd() {
    local name="$1"
    local cmd=""
    local custom=$(get_rig_conf "CUSTOM_MINER" "0")
    if [[ -n "$custom" && "$custom" != "0" ]]; then
        cmd="$BASE_DIR/$custom/current/$custom $ARGS"
        echo "$cmd"
        return
    fi
    case "$name" in
        bzminer)
            local bz_args
            bz_args="$(convert_bzminer_oc_json_to_args "$ARGS")"
            cmd="$MINER_BIN -a $ALGO$(build_pool_cmd_args bzminer) --pool_password $PASS $bz_args"
            ;;
        wildrig-multi)
            if [[ "$POOL_SSL" == "true" ]]; then
                echo "$(date): WARNING — wildrig-multi has no SSL/TLS support; connecting to $POOL_HOST over plain TCP instead of the requested SSL." >&2
            fi
            cmd="$MINER_BIN --algo $ALGO$(build_pool_cmd_args wildrig-multi) $ARGS"
            ;;
        xmrig)
            local xmrig_args
            xmrig_args="$(convert_xmrig_user_config_to_args "$ARGS")"
            local xmrig_cpu_flags
            xmrig_cpu_flags="$(convert_xmrig_cpu_config_to_args "$CPU_CONFIG")"
            if [[ -n "$xmrig_cpu_flags" ]]; then
                xmrig_args="$(echo "$xmrig_args $xmrig_cpu_flags" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            fi
            local tls_flag=""
            if [[ ("$POOL_SSL" == "true" || "$TLS" == "1" || "$TLS" == "true") && "$xmrig_args" != *"--tls"* ]]; then
                tls_flag="--tls"
            fi
            if [[ ("$CPU" == "0" || "$CPU" == "false") && "$xmrig_args" != *"--no-cpu"* ]]; then
                xmrig_args="$(echo "$xmrig_args --no-cpu" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            fi
            apply_xmrig_hugepages "$HUGEPAGES"
            cmd="$MINER_BIN $tls_flag -a $ALGO$(build_pool_cmd_args xmrig) $xmrig_args"
            ;;
        srbminer)
            local srb_tls_flag=""
            if [[ "$ARGS" != *"--tls "* ]]; then
                local srb_tls="false"
                [[ "$POOL_SSL" == "true" || "$TLS" == "1" || "$TLS" == "true" ]] && srb_tls="true"
                srb_tls_flag="--tls $srb_tls"
            fi
            cmd="$MINER_BIN $srb_tls_flag --algorithm $ALGO$(build_pool_cmd_args srbminer) --password $PASS $ARGS"
            ;;
        rigel)
            # Accepts stratum+ssl:// directly in the pool address.
            cmd="$MINER_BIN -a $ALGO$(build_pool_cmd_args rigel) -p $PASS $ARGS"
            ;;
        lolminer)
            cmd="$MINER_BIN --algo $ALGO$(build_pool_cmd_args lolminer) $ARGS"
            ;;
        onezerominer)
            # Accepts stratum+ssl://ssl:// directly in the pool address.
            cmd="$MINER_BIN --algo $ALGO$(build_pool_cmd_args onezerominer) --pass $PASS $ARGS"
            ;;
        gminer)
            local gm_ssl_flag=""
            if [[ "$ARGS" != *"--ssl "* ]]; then
                local gm_ssl="0"
                [[ "$POOL_SSL" == "true" ]] && gm_ssl="1"
                gm_ssl_flag="--ssl $gm_ssl"
            fi
            cmd="$MINER_BIN $gm_ssl_flag --algo $ALGO$(build_pool_cmd_args gminer) --pass $PASS $ARGS"
            ;;
        teamredminer)
            # Accepts stratum+ssl:// directly in the pool address.
            cmd="$MINER_BIN -a $ALGO$(build_pool_cmd_args teamredminer) $ARGS"
            ;;
        trex)
            # Accepts stratum+ssl:// directly in the pool address.
            cmd="$MINER_BIN -a $ALGO$(build_pool_cmd_args trex) $ARGS"
            ;;
        *)
            echo "[ERROR] Unknown miner: $name" >&2
            return
            ;;
    esac
    echo "$cmd"
}
WORKER_NAME="$(cat /etc/hostname)"
WORKER_NAME="${WORKER_NAME//x/X}"
WORKER_NAME="${WORKER_NAME//t/T}"
WORKER_NAME="${WORKER_NAME//s/S}"
TARGET_IMAGE=$(get_rig_conf "TARGET_IMAGE" "0")
TARGET_NAME=$(get_rig_conf "TARGET_NAME" "0")
APPLY_OC=$(get_rig_conf "APPLY_OC" "0")
RESET_OC=$(get_rig_conf "RESET_OC" "0")
MINER_NAME=$(get_rig_conf "MINER" "0")
MINER_NAME=$(convert_old_miner_name "$MINER_NAME")
CUSTOM_MINER=$(get_rig_conf "CUSTOM_MINER" "0")
if [[ -n "$CUSTOM_MINER" && "$CUSTOM_MINER" != "0" ]]; then
    echo "[miner] CUSTOM_MINER set — skipping built-in miner name/binary checks"
    MINER_BIN="$BASE_DIR/$CUSTOM_MINER/current/$CUSTOM_MINER"
    if [[ ! -f "$MINER_BIN" ]]; then
        echo "$(date): ERROR — CUSTOM_MINER binary not found at '$MINER_BIN'. Did 01-miner_install.sh run with CUSTOM_MINER_URL set?" >&2
        return 1 2>/dev/null || exit 1
    fi
else
    if [[ -z "$MINER_NAME" ]]; then
        echo "$(date): ERROR — MINER not set in rig.conf. Please set MINER ALL <miner_name>, or set CUSTOM_MINER instead." >&2
        return 1 2>/dev/null || exit 1
    fi
    MINER_BIN=$(get_miner_bin "$MINER_NAME")
    if [[ -z "$MINER_BIN" ]]; then
        echo "$(date): ERROR — Could not resolve a binary path for MINER='$MINER_NAME'. Aborting." >&2
        return 1 2>/dev/null || exit 1
    fi
fi
echo "[miner] $MINER_BIN"
TEMPLATE=$(get_rig_conf "TEMPLATE" "0")
TEMPLATE=$(resolve_worker_name "$TEMPLATE")
WALLET_ADDR=$(get_rig_conf "WALLET_ADDR" "0")
WALLET="${TEMPLATE//%WALLET%/$WALLET_ADDR}"
WALLET="${WALLET//%WAL%/$WALLET_ADDR}"
PASS=$(get_rig_conf "PASS" "0")
PASS=$(resolve_worker_name "$PASS")
PASS=$(resolve_wallet "$PASS")
POOL=$(get_rig_conf "POOL" "0")
POOL=$(resolve_worker_name "$POOL")
POOL=$(resolve_wallet "$POOL")
POOL=$(resolve_pass "$POOL")
POOL_URLS=$(get_rig_conf "POOL_URLS" "0")
POOL_URLS=$(resolve_worker_name "$POOL_URLS")
POOL_URLS=$(resolve_wallet "$POOL_URLS")
POOL_URLS=$(resolve_pass "$POOL_URLS")
ALGO=$(get_rig_conf "ALGO" "0")
ALGO=$(resolve_worker_name "$ALGO")
ALGO=$(resolve_wallet "$ALGO")
ALGO=$(resolve_pass "$ALGO")
ALGO=$(resolve_url_indexed "$ALGO")
ALGO=$(resolve_url "$ALGO")
ARGS=$(get_rig_conf "ARGS" "0")
ARGS=$(resolve_worker_name "$ARGS")
ARGS=$(resolve_wallet "$ARGS")
ARGS=$(resolve_wallet_addr "$ARGS")
ARGS=$(resolve_pass "$ARGS")
ARGS=$(resolve_url_indexed "$ARGS")
ARGS=$(resolve_url "$ARGS")
ARGS=$(resolve_algo "$ARGS")
POOL_SSL="false"
POOL_HOST="$POOL"
case "$POOL" in
    stratum+ssl://*) POOL_SSL="true";  POOL_HOST="${POOL#stratum+ssl://}" ;;
    stratum+tcp://*) POOL_SSL="false"; POOL_HOST="${POOL#stratum+tcp://}" ;;
esac
HUGEPAGES=$(get_rig_conf "HUGEPAGES" "0")
CPU_CONFIG=$(get_rig_conf "CPU_CONFIG" "0")
TLS=$(get_rig_conf "TLS" "0")
CPU=$(get_rig_conf "CPU" "0")
