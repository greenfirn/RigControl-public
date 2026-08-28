get_miner_bin() {
    local name="$1"
    local custom=$(get_rig_conf "CUSTOM_MINER" "0")
    if [[ -n "$custom" && "$custom" != "0" ]]; then
        echo "$BASE_DIR/custom/$custom/current/$custom"
        return
    fi
    case "$name" in
        bzminer)      echo "$BZMINER_BIN" ;;
        wildrig-multi) echo "$WILDRIG_BIN" ;;
        xmrig)        echo "$XMRIG_BIN" ;;
        srbminer|srbminer-gpu) echo "$SRBMINER_BIN" ;;
        srbminer-cpu) echo "$SRBMINER_CPU_BIN" ;;
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
        cmd="$BASE_DIR/custom/$custom/current/$custom $ARGS"
        echo "$cmd"
        return
    fi
    # MINER_COMMAND is the FULL command line (algo flag, pool/wallet/pass/TLS flags, and any
    # extra args the user typed) built entirely dashboard-side at Save time, with %WALLET%/
    # %PASS%/%WORKER_NAME%/etc. tokens already substituted above. This includes xmrig/bzminer
    # ARGS that came in as an OC-JSON blob (a HiveOS flightsheet import, or the dashboard's own
    # optional overclock/CPU editor for those two miners) - the dashboard converts that to real
    # CLI flags before it ever gets here, so this script just drops MINER_COMMAND in after
    # $MINER_BIN and runs it. No per-miner flag decisions, and no OC-JSON conversion, happen
    # rig-side anymore.
    case "$name" in
        xmrig)
            if [[ -z "$MINER_COMMAND" ]]; then
                echo "[ERROR] MINER_COMMAND is empty for xmrig - re-save the flightsheet in the dashboard." >&2
                return
            fi
            # --no-cpu is the one flag still decided rig-side: CPU on/off is a live per-rig
            # toggle, not something re-saving the flightsheet always accompanies.
            local xmrig_args=""
            if [[ ("$CPU" == "0" || "$CPU" == "false") && "$MINER_COMMAND" != *"--no-cpu"* ]]; then
                xmrig_args="--no-cpu"
            fi
            apply_xmrig_hugepages "$HUGEPAGES"
            cmd="$MINER_BIN $MINER_COMMAND $xmrig_args"
            ;;
        bzminer|wildrig-multi|srbminer|srbminer-cpu|srbminer-gpu|rigel|lolminer|onezerominer|gminer|teamredminer|trex)
            if [[ -z "$MINER_COMMAND" ]]; then
                echo "[ERROR] MINER_COMMAND is empty for $name - re-save the flightsheet in the dashboard." >&2
                return
            fi
            cmd="$MINER_BIN $MINER_COMMAND"
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
    MINER_BIN="$BASE_DIR/custom/$CUSTOM_MINER/current/$CUSTOM_MINER"
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
# For custom miners, miner_config.url is left as the literal token "%URL%" (rather than a
# hardcoded address) so it always tracks the flightsheet's pool_urls list, backups included.
# POOL itself needs to be resolved to a real address here (index 0 = primary; use %URL%[N] in
# ARGS/ALGO directly to reach a specific backup) before it's used below as the substitution
# value for any other field's %URL% token via resolve_url().
if [[ "$POOL" == *"%URL%"* ]]; then
    _pool_url_list=()
    mapfile -t _pool_url_list < <(get_pool_url_list)
    _primary_pool_url="${_pool_url_list[0]:-}"
    # Strip any scheme off the primary address before substituting it into %URL% here - the
    # surrounding template text (e.g. "stratum+ssl://%URL%") already supplies whatever scheme
    # it wants, so using an already-schemed pool_urls[0] would double it up
    # (stratum+ssl://stratum+ssl://host:port). %URL%[N] below is unaffected - it substitutes
    # pool_urls[N] as-is, scheme and all, since there's no surrounding template wrapping it.
    _primary_pool_url="${_primary_pool_url#stratum+ssl://}"
    _primary_pool_url="${_primary_pool_url#stratum+tcp://}"
    POOL="${POOL//%URL%/${_primary_pool_url}}"
fi
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
# MINER_COMMAND is the dashboard-built full command line for known miners (algo flag, pool/
# wallet/pass/TLS flags, and any extra args baked in already) - it gets the exact same token
# pipeline as ARGS/ALGO above, since it can contain the same %WORKER_NAME%/%WALLET%/%PASS%/
# %URL%/%URL%[N]/%ALGO% tokens.
MINER_COMMAND=$(get_rig_conf "MINER_COMMAND" "0")
MINER_COMMAND=$(resolve_worker_name "$MINER_COMMAND")
MINER_COMMAND=$(resolve_wallet "$MINER_COMMAND")
MINER_COMMAND=$(resolve_wallet_addr "$MINER_COMMAND")
MINER_COMMAND=$(resolve_pass "$MINER_COMMAND")
MINER_COMMAND=$(resolve_url_indexed "$MINER_COMMAND")
MINER_COMMAND=$(resolve_url "$MINER_COMMAND")
MINER_COMMAND=$(resolve_algo "$MINER_COMMAND")
HUGEPAGES=$(get_rig_conf "HUGEPAGES" "0")
CPU_CONFIG=$(get_rig_conf "CPU_CONFIG" "0")
CPU=$(get_rig_conf "CPU" "0")
