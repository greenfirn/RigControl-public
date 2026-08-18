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

# Splits the pipe-delimited POOL_URLS conf value (rig-gpu.json's own
# pool_urls array - primary/secondary/etc - already re-prefixed
# consistently with $POOL_SSL by 00-get_rig_conf.sh's jq filter) into a
# bash array, one pool per element. Falls back to a single-element array
# containing just $POOL when POOL_URLS is empty - either because the
# flightsheet only has one pool (rig-gpu.json had no pool_urls array at
# all) or was saved before this field existed - so every miner branch in
# build_pool_cmd_args() below still gets at least the primary pool
# either way, and none of them need their own empty-list special case.
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

# Builds the primary+secondary/failover pool arguments for miner "$1"
# from the pool list above - every supported miner has its own
# convention for how (or whether) it accepts more than one pool on the
# command line, researched per-miner rather than assumed:
#   - xmrig, trex, teamredminer, wildrig-multi, rigel, lolminer, gminer:
#     repeat the pool flag (full -o/--url/--pool/--server block, WITH
#     wallet - and pass, for the miners whose single-pool form already
#     carried one per pool) once per pool. xmrig/wildrig-multi/gminer use
#     the bare host:port form (same as their existing $POOL_HOST
#     convention); trex/teamredminer/rigel/lolminer use the full
#     scheme-prefixed URL (same as their existing $POOL convention).
#   - srbminer: SINGLE --pool flag, all pools comma-separated, bare
#     addresses (SSL is its own separate --tls flag either way).
#   - bzminer: SINGLE -p flag, all pools space-separated, full
#     scheme-prefixed URLs.
#   - onezerominer: SINGLE --pool flag, all pools comma-separated, full
#     scheme-prefixed URLs - confirmed via a real working onezerominer.bat
#     ("-o pool1,pool2"), not documented in its own README (which only
#     covers --o2, an entirely different SECOND ALGORITHM for dual
#     mining - easy to conflate with same-algo failover, but distinct).
# Echoes just the pool(+wallet+pass) portion of the command line, meant
# to be spliced into the surrounding $ALGO/$PASS/$ARGS command in
# get_start_cmd() below - callers that don't embed wallet/pass into this
# output still append their own $WALLET/$PASS afterward exactly as they
# did before this function existed, so single-pool flightsheets (the
# common case) build an identical command line to before.
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
            # -o/--pool DOES accept a comma-separated list for same-algo
            # failover, confirmed via a real working onezerominer.bat
            # ("-o pool1:port,pool2:port") - not documented in its own
            # README, which only covers --o2 (an entirely different
            # SECOND ALGORITHM for dual mining, not a backup pool for
            # this one). Single flag for the whole list, prefixed
            # addresses (same convention as its existing single-pool
            # form - accepts stratum+ssl:// directly).
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

# Some HiveOS bzminer exports store overclock overrides as loose JSON
# key/value lines in miner_config.user_config instead of real CLI flags
# (see the matching JS-side convertBzminerOcJsonToArgs() in the web app's
# Flightsheet editor, and fsBzminerOcJsonUserConfig - the web app
# deliberately keeps this text unconverted in the saved rig-gpu.json so
# it stays byte-compatible with being pasted back into HiveOS later) -
# $ARGS below can end up holding that literal JSON text instead of CLI
# flags for those flightsheets. Detected by a leading '"' (real CLI flags
# always start with '-'), left completely untouched otherwise. Converts
# each recognized key to its real bzminer flag - verified against
# bzminer's own example launch scripts (warthog.bat/xelis.bat both use a
# plain `--cpu_threads 0`, not an algo-prefixed flag), stripping HiveOS's
# bracket-wrapped-array value format ("[1480]" -> "1480",
# "[1480,1490]" -> "1480 1490" for multi-GPU) into the space-separated
# per-device value list those flags expect. Unrecognized keys are
# dropped rather than guessed at.
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

# Some HiveOS xmrig exports put OC/behavior overrides in user_config as
# flat JSON key/value lines, same shape as the bzminer case above (no
# enclosing braces, one per line, e.g. `"donate-level": 1` /
# `"keepalive": true`) - the web app's Flightsheet editor keeps this
# text in its ORIGINAL unconverted form when saving (same reasoning as
# convert_bzminer_oc_json_to_args - staying byte-compatible with being
# pasted back into HiveOS), so $ARGS can still be this literal JSON text
# rather than real CLI flags by the time this runs. Mirrors the web
# app's own convertXmrigUserConfigToArgs() - verified against xmrig's
# official CLI reference (xmrig.com/docs/miner/command-line-options):
#   donate-level: N          -> --donate-level N
#   keepalive: true          -> --keepalive (bare boolean flag, only
#     emitted when true - there's no --no-keepalive)
#   randomx: { 1gb-pages: true } -> --randomx-1gb-pages (nested one-line
#     object, not a flat key:value pair - handled as a special case
#     before the flat-line pass, which otherwise silently drops any
#     line it can't parse as "key": value)
# Unrecognized keys are dropped rather than guessed at.
# HiveOS exports booleans as literal true/false in some fields but as
# 1/0 in others (a real export's own "cpu"/"tls" toggles were seen as
# 1, not true) - these two helpers normalize both spellings so every
# boolean-ish key below is read consistently either way. Mirrors the
# web app's xmrigValueIsTruthy()/xmrigValueIsFalsy().
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

            # xmrig's own top-level "tls" override, distinct from
            # miner_config.tls ($TLS, handled in get_start_cmd()'s xmrig
            # case below) - either source can request --tls; that
            # caller already skips re-adding it if it's already present
            # in the converted args, so no duplicate flag results from
            # having both.
            if [[ "$key" == "tls" ]]; then
                xmrig_value_is_truthy "$raw_value" && out+=" --tls"
                continue
            fi

            # xmrig's own "cpu" mining-enabled toggle - true/1 is
            # xmrig's own default (no flag needed), only false/0 needs
            # an explicit --no-cpu.
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

# xmrig's SEPARATE cpu_config field - the literal contents of xmrig's own
# config.json "cpu" object (e.g. `"cpu": {\n  "huge-pages": true, ...\n}`),
# also kept in its original JSON form by the web app for the same
# HiveOS-round-trip reason as user_config above. Mirrors the web app's
# own convertXmrigCpuConfigToArgs() - converts every key with an
# unambiguous CLI equivalent (verified against xmrig's own CLI
# reference) and leaves the rest out rather than guessing:
#   huge-pages: false -> --no-huge-pages (true is xmrig's own default, no flag needed)
#   priority: N        -> --cpu-priority=N (null = unset, skipped)
#   memory-pool: false -> --cpu-memory-pool=0 (explicit disable; true has
#     no single unambiguous page-count per the docs, left unmapped)
#   asm: true/false/"x" -> --asm=auto / --asm=none / --asm=x
#   rx: [core ids...]  -> --threads=<count> plus a --cpu-affinity=0xHEX
#     bitmask built by OR-ing 1<<core for every listed core index - the
#     same technique 03-cpu_threads.sh already hardcodes for the fixed
#     24/32-thread RandomX case.
# Assumes one key per line inside the braces (the shape every real
# HiveOS export seen so far actually uses) rather than a full JSON
# parse - simpler and consistent with every other JSON-ish field this
# script already hand-parses the same way.
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

# xmrig's cpu_config."huge-pages" (converted above into --no-huge-pages
# when false, or left as the default when true) just tells xmrig whether
# to USE huge pages IF the OS already has them reserved - it doesn't
# reserve them itself. $HUGEPAGES (miner_config.hugepages, a plain page
# COUNT like 1248) is the separate "make them available" step this rig
# needs to do BEFORE launching xmrig, via the same sysctl HiveOS itself
# uses.
# Best-effort: warns rather than failing the whole launch if the
# container/rig doesn't have permission to write it (common without
# --privileged or the SYS_ADMIN capability).
apply_xmrig_hugepages() {
    local pages="$1"
    # "0" is this codebase's usual not-set sentinel (same convention as
    # CUSTOM_MINER/MINER elsewhere in this file) - treated the same as
    # empty/missing here too, not as an explicit "set hugepages to zero"
    # request, since "0" would otherwise still pass the digits-only check
    # below and actively zero out any hugepages already reserved.
    [[ -n "$pages" && "$pages" != "0" && "$pages" =~ ^[0-9]+$ ]] || return 0

    if [[ -w /proc/sys/vm/nr_hugepages ]]; then
        echo "$pages" > /proc/sys/vm/nr_hugepages 2>/dev/null
    elif command -v sysctl >/dev/null 2>&1; then
        # sysctl -w can exit 0 even when it silently declined the write
        # (observed as "permission denied ... ignoring" while still
        # returning success in some unprivileged-container sysctl
        # builds) - its own exit code alone isn't trustworthy here, so
        # the actual applied value is read back below regardless of
        # which path was taken.
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

    # Not every miner accepts the stratum+ssl://stratum+tcp:// URL scheme
    # we use internally (rig-gpu.json's pool_ssl + POOL's own convention) -
    # some want SSL toggled via a completely separate flag, with the pool
    # address passed bare (no scheme prefix) instead. $POOL_SSL/$POOL_HOST
    # below split that apart so each miner's branch can use whichever form
    # it actually understands. build_pool_cmd_args() (above) reuses this
    # same split for every pool in $POOL_URLS, not just the primary one.
    case "$name" in

        bzminer)
            # -p takes a space-separated list of full pool URLs (accepts
            # stratum+ssl:// directly) - single flag, not repeated. $ARGS
            # may be real CLI flags, or - for flightsheets saved from a
            # HiveOS OC-override JSON export - the original literal JSON
            # text; convert_bzminer_oc_json_to_args() (above) detects and
            # converts that case, passing real CLI flags straight through
            # untouched.
            local bz_args
            bz_args="$(convert_bzminer_oc_json_to_args "$ARGS")"
            cmd="$MINER_BIN -a $ALGO$(build_pool_cmd_args bzminer) --pool_password $PASS $bz_args"
            ;;

        wildrig-multi)
            # wildrig-multi has no SSL/TLS support at all - no flag, no
            # URL scheme it understands for it. Always connect bare/plain
            # TCP, and say so loudly if the flightsheet asked for SSL,
            # rather than silently mining over an unencrypted connection
            # the user thought was secured.
            if [[ "$POOL_SSL" == "true" ]]; then
                echo "$(date): WARNING — wildrig-multi has no SSL/TLS support; connecting to $POOL_HOST over plain TCP instead of the requested SSL." >&2
            fi
            cmd="$MINER_BIN --algo $ALGO$(build_pool_cmd_args wildrig-multi) $ARGS"
            ;;

        xmrig)
            # $ARGS/$CPU_CONFIG may each be real CLI text already, or the
            # original HiveOS JSON-style override text (see
            # convert_xmrig_user_config_to_args/convert_xmrig_cpu_config_to_args
            # above) - convert first, THEN decide on --tls below, since
            # checking for an existing "--tls" substring against the raw
            # JSON text (which never contains that string) would always
            # miss it.
            local xmrig_args
            xmrig_args="$(convert_xmrig_user_config_to_args "$ARGS")"
            local xmrig_cpu_flags
            xmrig_cpu_flags="$(convert_xmrig_cpu_config_to_args "$CPU_CONFIG")"
            if [[ -n "$xmrig_cpu_flags" ]]; then
                xmrig_args="$(echo "$xmrig_args $xmrig_cpu_flags" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            fi

            # Supports stratum+ssl:// in the URL too, but the bare --tls
            # flag is the more common/explicit form - pool address stays
            # scheme-free. Two independent sources can request it: the
            # flightsheet's own POOL_SSL, or xmrig's own separate TLS
            # toggle (miner_config.tls - can be set independently of
            # POOL_SSL on real HiveOS exports, e.g. pool_ssl:false,
            # tls:1). Skipped if the converted args already have --tls
            # (a flightsheet built by hand or already carrying real CLI
            # flags might) so it's never added twice.
            local tls_flag=""
            if [[ ("$POOL_SSL" == "true" || "$TLS" == "1" || "$TLS" == "true") && "$xmrig_args" != *"--tls"* ]]; then
                tls_flag="--tls"
            fi

            # miner_config.cpu is xmrig's own top-level CPU-mining-enabled
            # toggle (same level as tls above - a real export had both:
            # {"cpu":1,"tls":1,...}) - true/1 is xmrig's own default (no
            # flag needed), only false/0 needs an explicit --no-cpu.
            # Skipped if the converted args already have it for the same
            # never-add-twice reason as tls_flag above.
            if [[ ("$CPU" == "0" || "$CPU" == "false") && "$xmrig_args" != *"--no-cpu"* ]]; then
                xmrig_args="$(echo "$xmrig_args --no-cpu" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            fi

            apply_xmrig_hugepages "$HUGEPAGES"
            cmd="$MINER_BIN $tls_flag -a $ALGO$(build_pool_cmd_args xmrig) $xmrig_args"
            ;;

        srbminer)
            # --tls true/false is SRBMiner-Multi's own explicit switch.
            # Two independent sources can request it, same as xmrig's
            # tls_flag above: the flightsheet's own POOL_SSL, or
            # miner_config.tls (a real "srb test" export had
            # pool_ssl:false, tls:1 set independently). Skipped if ARGS
            # already sets --tls itself (web-app-built flightsheets do)
            # to avoid passing it twice.
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
            # Accepts stratum+ssl://ssl:// directly in the pool address
            # (auto-enables TLS from the scheme).
            cmd="$MINER_BIN --algo $ALGO$(build_pool_cmd_args lolminer) $ARGS"
            ;;

        onezerominer)
            # Accepts stratum+ssl://ssl:// directly in the pool address.
            cmd="$MINER_BIN --algo $ALGO$(build_pool_cmd_args onezerominer) --pass $PASS $ARGS"
            ;;

        gminer)
            # GMiner's --server takes a bare host:port (no URL scheme at
            # all) - SSL is toggled purely via the separate --ssl 0/1 flag.
            # Skipped if ARGS already sets --ssl itself (web-app-built
            # flightsheets do) to avoid passing it twice.
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

# WALLET is now built from two separate pieces, same split HiveOS itself
# uses: TEMPLATE is pattern text (may contain %WALLET%, or HiveOS's own
# %WAL% spelling for a flightsheet template pasted straight from a
# HiveOS export, plus the usual %WORKER_NAME%) and WALLET_ADDR is just
# the raw address that fills it in - see the TEMPLATE/WALLET_ADDR
# comment block in 00-get_rig_conf.sh for where each one comes from.
# %WORKER_NAME% is resolved into TEMPLATE first (it's TEMPLATE's own
# token, same as every other field below), THEN %WALLET%/%WAL% are
# substituted using WALLET_ADDR - the result becomes $WALLET, used
# exactly the same way everywhere below (and by resolve_wallet() for
# every other field) as it always has been. A rig-gpu.json with no
# wallet_address at all (old single-field flightsheets, or a fresh
# .conf bootstrap - see generate_rig_gpu_json_from_conf) just leaves
# WALLET_ADDR empty, so this substitution is a no-op and $WALLET ends
# up equal to TEMPLATE unchanged - the same already-resolved value the
# old single WALLET field used to hold directly.
TEMPLATE=$(get_rig_conf "TEMPLATE" "0")
TEMPLATE=$(resolve_worker_name "$TEMPLATE")
WALLET_ADDR=$(get_rig_conf "WALLET_ADDR" "0")
WALLET="${TEMPLATE//%WALLET%/$WALLET_ADDR}"
WALLET="${WALLET//%WAL%/$WALLET_ADDR}"

PASS=$(get_rig_conf "PASS" "0")
PASS=$(resolve_worker_name "$PASS")
PASS=$(resolve_wallet "$PASS")

# %WORKER_NAME%, %WALLET%, and %PASS% can each show up in any of these
# depending on the miner/flightsheet - resolve_worker_name/resolve_wallet/
# resolve_pass fill them in with this rig's already-cased name and the
# WALLET/PASS values read above, respectively. Order matters:
# resolve_worker_name first, since WALLET/PASS (just resolved above)
# could already have substituted a %WORKER_NAME% token into these via
# %WALLET%/%PASS%.
POOL=$(get_rig_conf "POOL" "0")
POOL=$(resolve_worker_name "$POOL")
POOL=$(resolve_wallet "$POOL")
POOL=$(resolve_pass "$POOL")

# Resolved here (right after POOL, before ALGO/ARGS) rather than down by
# build_pool_cmd_args()'s own call site - resolve_url_indexed() below
# needs $POOL_URLS already populated when it runs as part of the ALGO/ARGS
# chains, and those run before build_pool_cmd_args() ever gets called.
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

# Split POOL back into its SSL flag + bare host:port for the miners in
# get_start_cmd() above that don't accept our stratum+ssl://stratum+tcp://
# scheme prefix and need SSL toggled via their own separate flag instead.
POOL_SSL="false"
POOL_HOST="$POOL"
case "$POOL" in
    stratum+ssl://*) POOL_SSL="true";  POOL_HOST="${POOL#stratum+ssl://}" ;;
    stratum+tcp://*) POOL_SSL="false"; POOL_HOST="${POOL#stratum+tcp://}" ;;
esac

# Primary+secondary/failover pool list - already resolved above (right
# after POOL, before ALGO/ARGS - see the comment there) so it's available
# in time for resolve_url_indexed(). Used by build_pool_cmd_args() above,
# and by resolve_url_indexed() for %URL%[N] in ALGO/ARGS. "0" (get_rig_conf's
# not-set sentinel) and empty both mean "no pool_urls array" -
# get_pool_url_list() already falls back to just $POOL in that case.

# xmrig-only OS-level huge page count (see apply_xmrig_hugepages() above)
# - a plain number, no %WORKER_NAME%/%WALLET%/%PASS% tokens to resolve.
# "0" (get_rig_conf's not-set sentinel) is handled the same as empty by
# apply_xmrig_hugepages's own validation, so no extra check needed here.
HUGEPAGES=$(get_rig_conf "HUGEPAGES" "0")

# xmrig-only cpu_config JSON text (see convert_xmrig_cpu_config_to_args()
# above) - no %WORKER_NAME%/%WALLET%/%PASS% tokens expected in it either.
CPU_CONFIG=$(get_rig_conf "CPU_CONFIG" "0")

# xmrig-only TLS toggle (see the xmrig case in get_start_cmd() above) -
# plain "0"/"1"/"true"/"false" text, no tokens to resolve.
TLS=$(get_rig_conf "TLS" "0")

# xmrig-only top-level CPU-mining-enabled toggle (see the --no-cpu
# injection in get_start_cmd()'s xmrig case above) - same shape/level as
# TLS, a real export had both: {"cpu":1,"tls":1,...}. Empty when absent
# (this key isn't part of the not-set-sentinel-"0" convention CUSTOM_MINER
# etc. use - 00-get_rig_conf.sh's jq filter falls back to "" here, same as
# HUGEPAGES/TLS, since an explicit "0" genuinely means "disable CPU
# mining" and must stay distinguishable from "field wasn't present at
# all").
CPU=$(get_rig_conf "CPU" "0")
