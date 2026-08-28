sudo mkdir -v /usr/local/bin/lib
sudo tee /usr/local/bin/lib/00-get_rig_conf.sh > /dev/null <<'EOF'
if [[ "$CFG_FILE" == *.json ]]; then
    RIG_GPU_JSON="$CFG_FILE"
elif [[ -n "$CFG_FILE" ]]; then
    RIG_GPU_JSON="${CFG_FILE%.conf}.json"
else
    RIG_GPU_JSON="/etc/rigcontrol/rig-gpu.json"
fi
convert_old_miner_name() {
    local name="$1"
    case "$name" in
        wildrig)              echo "wildrig-multi" ;;
        SRBMiner-MULTI)       echo "srbminer" ;;
        SRBMiner-MULTI-cpu)   echo "srbminer-cpu" ;;
        SRBMiner-MULTI-gpu)   echo "srbminer-gpu" ;;
        lolMiner)              echo "lolminer" ;;
        t-rex)                 echo "trex" ;;
        *)       echo "$name" ;;
    esac
}
RIG_GPU_JSON_KEYS=" ALGO PASS ARGS POOL POOL_URLS MINER_COMMAND TEMPLATE WALLET_ADDR MINER CUSTOM_MINER CUSTOM_MINER_URL TARGET_IMAGE TARGET_NAME RESET_OC APPLY_OC HUGEPAGES CPU_CONFIG TLS CPU "
RIG_GPU_JQ_FILTER=$(cat <<'JQ'
  .items[0] as $it
  | ($it.miner_config // {}) as $mc
  | ($it.miner == "custom") as $is_custom
  | {
      ALGO: ($mc.algo // ""),
      PASS: ($mc.pass // ""),
      ARGS: ($mc.user_config // ""),
      POOL: ($mc.url // ""),
      POOL_URLS: (($it.pool_urls // []) | join("|")),
      MINER_COMMAND: ($it.miner_command // ""),
      TEMPLATE: ($mc.template // ""),
      WALLET_ADDR: ($mc.wallet_address // ""),
      MINER: (if $is_custom then "" else
          (if (($it.miner_alt // "") | length) > 0 then $it.miner_alt else ($it.miner // "") end)
        end),
      CUSTOM_MINER: (if $is_custom then ($it.miner_alt // $mc.miner // "") else "" end),
      CUSTOM_MINER_URL: (if $is_custom then ($mc.install_url // "") else "" end),
      TARGET_IMAGE: ($it.target_image // ""),
      TARGET_NAME: ($it.target_name // ""),
      RESET_OC: ($it.reset_oc // ""),
      APPLY_OC: ($it.apply_oc // ""),
      HUGEPAGES: (($mc.hugepages // "") | tostring),
      CPU_CONFIG: ($mc.cpu_config // ""),
      TLS: (($mc.tls // "") | tostring),
      CPU: (($mc.cpu // "") | tostring)
    }[$k]
JQ
)
RIG_GPU_JSON_GENERATE_ATTEMPTED=""
generate_rig_gpu_json_from_conf() {
    command -v jq >/dev/null 2>&1 || return 1
    [[ -f "$CFG_FILE" ]] || return 1
    local miner algo pass args pool wallet custom_miner custom_miner_url
    local target_image target_name reset_oc apply_oc
    miner=$(get_rig_conf "MINER" "0")
    miner=$(convert_old_miner_name "$miner")
    algo=$(get_rig_conf "ALGO" "0")
    pass=$(get_rig_conf "PASS" "0")
    args=$(get_rig_conf "ARGS" "0")
    pool=$(get_rig_conf "POOL" "0")
    wallet=$(get_rig_conf "WALLET" "0")
    custom_miner=$(get_rig_conf "CUSTOM_MINER" "0")
    custom_miner_url=$(get_rig_conf "CUSTOM_MINER_URL" "0")
    target_image=$(get_rig_conf "TARGET_IMAGE" "0")
    target_name=$(get_rig_conf "TARGET_NAME" "0")
    reset_oc=$(get_rig_conf "RESET_OC" "0")
    apply_oc=$(get_rig_conf "APPLY_OC" "0")
    if [[ -z "$miner" && -z "$custom_miner" ]]; then
        return 1
    fi
    local pool_ssl="false"
    local pool_url="$pool"
    case "$pool" in
        stratum+ssl://*) pool_ssl="true";  pool_url="${pool#stratum+ssl://}" ;;
        stratum+tcp://*) pool_ssl="false"; pool_url="${pool#stratum+tcp://}" ;;
    esac
    local miner_field="$miner"
    local miner_alt_field=""
    local mc_miner_field=""
    local install_url_field=""
    if [[ -n "$custom_miner" && "$custom_miner" != "0" ]]; then
        miner_field="custom"
        miner_alt_field="$custom_miner"
        mc_miner_field="$custom_miner"
        install_url_field="$custom_miner_url"
    fi
    mkdir -p "$(dirname "$RIG_GPU_JSON")" 2>/dev/null
    jq -n \
      --arg miner "$miner_field" \
      --arg miner_alt "$miner_alt_field" \
      --argjson pool_ssl "$pool_ssl" \
      --arg url "$pool_url" \
      --arg algo "$algo" \
      --arg pass "$pass" \
      --arg template "$wallet" \
      --arg mc_miner "$mc_miner_field" \
      --arg install_url "$install_url_field" \
      --arg user_config "$args" \
      --arg target_image "$target_image" \
      --arg target_name "$target_name" \
      --arg reset_oc "$reset_oc" \
      --arg apply_oc "$apply_oc" \
      '{
         items: [
           ( {pool_ssl: $pool_ssl, miner: $miner}
             + (if ($miner_alt|length) > 0 then {miner_alt: $miner_alt} else {} end)
             + (if ($target_image|length) > 0 then {target_image: $target_image} else {} end)
             + (if ($target_name|length) > 0 then {target_name: $target_name} else {} end)
             + (if ($reset_oc|length) > 0 then {reset_oc: $reset_oc} else {} end)
             + (if ($apply_oc|length) > 0 then {apply_oc: $apply_oc} else {} end)
             + {
                 miner_config: (
                   {url: $url, algo: $algo, pass: $pass, template: $template}
                   + (if ($mc_miner|length) > 0 then {miner: $mc_miner} else {} end)
                   + (if ($install_url|length) > 0 then {install_url: $install_url} else {} end)
                   + (if ($user_config|length) > 0 then {user_config: $user_config} else {} end)
                 )
               }
           )
         ]
       }' > "${RIG_GPU_JSON}.tmp" 2>/dev/null && mv "${RIG_GPU_JSON}.tmp" "$RIG_GPU_JSON"
}
get_rig_conf() {
    local key=""
    local gpu_id=""
    local cfg_file=""
    if [[ $# -eq 2 ]]; then
        cfg_file="$CFG_FILE"
        key="$1"
        gpu_id="$2"
    elif [[ $# -eq 3 ]]; then
        cfg_file="$1"
        key="$2"
        gpu_id="$3"
    else
        echo "[get_rig_conf] Invalid arguments" >&2
        return 1
    fi
    if [[ ! -f "$RIG_GPU_JSON" && -z "$RIG_GPU_JSON_GENERATE_ATTEMPTED" ]]; then
        RIG_GPU_JSON_GENERATE_ATTEMPTED=1
        # || true: non-fatal failure here should fall through to parsing $cfg_file directly
        generate_rig_gpu_json_from_conf || true
    fi
    if [[ -f "$RIG_GPU_JSON" ]] && command -v jq >/dev/null 2>&1 && [[ "$RIG_GPU_JSON_KEYS" == *" $key "* ]]; then
        local json_val
        if json_val=$(jq -r --arg k "$key" "$RIG_GPU_JQ_FILTER" "$RIG_GPU_JSON" 2>/dev/null); then
            [[ "$json_val" == "null" ]] && json_val=""
            echo "$json_val"
            return
        fi
    fi
    [[ -f "$cfg_file" ]] || { echo ""; return; }
    local selected_value=""
    local file_key file_gpu rest_of_line value col_gpu combined_value
    while read -r file_key file_gpu rest_of_line; do
        [[ -z "$file_key" || "$file_key" =~ ^# ]] && continue
        [[ "$file_key" != "$key" ]] && continue
        if [[ "$file_gpu" == \"* || -z "$rest_of_line" ]]; then
            col_gpu="ALL"
            if [[ -n "$rest_of_line" ]]; then
                combined_value="$file_gpu $rest_of_line"
            else
                combined_value="$file_gpu"
            fi
        else
            col_gpu="$file_gpu"
            combined_value="$rest_of_line"
        fi
        value="$combined_value"
        value="${value#\"}"
        value="${value%\"}"
        if [[ "$col_gpu" == "$gpu_id" ]]; then
            selected_value="$value"
            break
        fi
        if [[ "$col_gpu" == "ALL" ]]; then
            selected_value="$value"
        fi
    done < "$cfg_file"
    echo "$selected_value"
}
resolve_worker_name() {
    local value="$1"
    echo "${value//%WORKER_NAME%/$WORKER_NAME}"
}
resolve_wallet() {
    local value="$1"
    echo "${value//%WALLET%/$WALLET}"
}
resolve_pass() {
    local value="$1"
    echo "${value//%PASS%/$PASS}"
}
resolve_url() {
    local value="$1"
    echo "${value//%URL%/$POOL}"
}
resolve_algo() {
    local value="$1"
    echo "${value//%ALGO%/$ALGO}"
}
resolve_wallet_addr() {
    local value="$1"
    echo "${value//%WAL%/$WALLET_ADDR}"
}
resolve_url_indexed() {
    local value="$1"
    case "$value" in
        *"%URL%["*) ;;
        *) echo "$value"; return ;;
    esac
    local urls=()
    mapfile -t urls < <(get_pool_url_list)
    local idx replacement
    while [[ "$value" =~ %URL%\[([0-9]+)\] ]]; do
        idx="${BASH_REMATCH[1]}"
        replacement="${urls[$idx]:-}"
        value="${value//%URL%\[$idx\]/$replacement}"
    done
    echo "$value"
}
EOF
sudo tee /usr/local/bin/lib/01-miner_install.sh > /dev/null <<'EOF'
XMRIG_VERSION=$(get_rig_conf "$MINER_CONF" "XMRIG_VERSION" "0")
BZMINER_VERSION=$(get_rig_conf "$MINER_CONF" "BZMINER_VERSION" "0")
WILDRIG_VERSION=$(get_rig_conf "$MINER_CONF" "WILDRIG_VERSION" "0")
SRBMINER_VERSION=$(get_rig_conf "$MINER_CONF" "SRBMINER_VERSION" "0")
SRBMINER_CPU_VERSION=$(get_rig_conf "$MINER_CONF" "SRBMINER-CPU_VERSION" "0")
RIGEL_VERSION=$(get_rig_conf "$MINER_CONF" "RIGEL_VERSION" "0")
LOLMINER_VERSION=$(get_rig_conf "$MINER_CONF" "LOLMINER_VERSION" "0")
ONEZEROMINER_VERSION=$(get_rig_conf "$MINER_CONF" "ONEZEROMINER_VERSION" "0")
GMINER_VERSION=$(get_rig_conf "$MINER_CONF" "GMINER_VERSION" "0")
TEAMREDMINER_VERSION=$(get_rig_conf "$MINER_CONF" "TEAMREDMINER_VERSION" "0")
TREXMINER_VERSION=$(get_rig_conf "$MINER_CONF" "TREXMINER_VERSION" "0")
CUSTOM_MINER_URL=$(get_rig_conf "$CFG_FILE" "CUSTOM_MINER_URL" "0")
CUSTOM_MINER_NAME=$(get_rig_conf "$CFG_FILE" "CUSTOM_MINER" "0")
INSTALL_ALL=false
REQUESTED_MINERS=()
if [ $# -eq 0 ]; then
    CONFIG_MINER=$(get_rig_conf "$CFG_FILE" "MINER" "0")
    CONFIG_MINER=$(convert_old_miner_name "$CONFIG_MINER")
	echo "$CONFIG_MINER from rig.conf"
    if [ -n "$CONFIG_MINER" ] && [ "$CONFIG_MINER" != "0" ]; then
        REQUESTED_MINERS+=("$CONFIG_MINER")
        echo "Using MINER=$CONFIG_MINER from rig.conf"
    else
        INSTALL_ALL=false
        echo "No miner specified in config or arguments - skipping install"
    fi
elif [ $# -eq 1 ] && [ "$(echo "$1" | tr '[:upper:]' '[:lower:]')" = "all" ]; then
    INSTALL_ALL=true
    echo "Installing ALL miners (requested via command line)"
else
    for miner in "$@"; do
        REQUESTED_MINERS+=("$(convert_old_miner_name "$miner")")
    done
fi
echo ""
echo "==============================================="
echo "  Miner Versions Loaded from rig.conf"
echo "==============================================="
echo "  XMRig:        $XMRIG_VERSION"
echo "  BzMiner:      $BZMINER_VERSION"
echo "  WildRig:      $WILDRIG_VERSION"
echo "  SRBMiner:     $SRBMINER_VERSION"
echo "  SRBMiner-CPU: $SRBMINER_CPU_VERSION"
echo "  Rigel:        $RIGEL_VERSION"
echo "  lolMiner:     $LOLMINER_VERSION"
echo "  OneZeroMiner: $ONEZEROMINER_VERSION"
echo "  GMiner:       $GMINER_VERSION"
echo "  TeamRedMiner: $TEAMREDMINER_VERSION"
echo "  TRex:         $TREXMINER_VERSION"
if [ -n "$CUSTOM_MINER_URL" ] && [ "$CUSTOM_MINER_URL" != "0" ]; then
    echo "  Custom:       ${CUSTOM_MINER_NAME:-<unset>} <- $CUSTOM_MINER_URL"
fi
echo "==============================================="
if [ "$INSTALL_ALL" = true ]; then
    echo "  Installing: ALL miners"
else
    echo "  Installing: ${REQUESTED_MINERS[*]}"
fi
echo "==============================================="
echo ""
download_with_retry() {
    local outfile="$1"
    local url="$2"
    for attempt in 1 2 3; do
        echo "  [Attempt $attempt] Downloading: $url"
        if wget -q "$url" -O "$outfile"; then
            if [ -s "$outfile" ]; then return 0; fi
        fi
        echo "  Download failed, retrying..."
        sleep 2
    done
    echo "ERROR: Could not download $url"
    return 1
}
install_miner() {
    local name="$1"
    local version="$2"
    local url="$3"
    local file="$4"
    local strip="$5"
    local bin_name="$6"
    local miner_dir="$BASE_DIR/$name/current"
    local bin_path="$miner_dir/$bin_name"
    local version_file="$miner_dir/.installed_version"
    local installed_version=""
    [ -f "$version_file" ] && installed_version="$(cat "$version_file" 2>/dev/null)"
    if [ ! -f "$bin_path" ] || [ "$installed_version" != "$version" ]; then
        echo ""
        echo "==== Installing $name $version (overwriting in place, current is kept as-is otherwise) ===="
        mkdir -p "$miner_dir"
        cd "$miner_dir"
        download_with_retry "$file" "$url"
        echo "  Extracting on top of $miner_dir..."
        if ! tar -xf "$file" $strip; then
            echo "ERROR: Extraction failed — file likely invalid."
            rm -f "$file"
            exit 1
        fi
        rm -f "$file"
        if [ ! -f "$bin_name" ]; then
            echo "ERROR: Expected binary '$bin_name' not found!"
            exit 1
        fi
        echo "$version" > "$version_file"
    else
        echo ""
        echo "$name $version already installed (found $bin_name), skipping."
    fi
    echo "  Installed at: $miner_dir"
}
install_custom_miner() {
    local url="$1"
    local bin_name="$2"
    local file
    file="$(basename "$url")"
    local version
    version="$(echo -n "$url" | md5sum | cut -d' ' -f1)"
    local miner_dir="$BASE_DIR/custom/$bin_name/current"
    local bin_path="$miner_dir/$bin_name"
    local version_file="$miner_dir/.installed_version"
    local installed_version=""
    [ -f "$version_file" ] && installed_version="$(cat "$version_file" 2>/dev/null)"
    if [ ! -f "$bin_path" ] || [ "$installed_version" != "$version" ]; then
        echo ""
        echo "==== Installing CUSTOM_MINER ($bin_name), overwriting in place, current is kept as-is otherwise ===="
        mkdir -p "$miner_dir"
        cd "$miner_dir"
        download_with_retry "$file" "$url"
        echo "  Extracting on top of $miner_dir..."
        case "$file" in
            *.tar.gz|*.tgz)  tar -xzf "$file" --strip-components=1 ;;
            *.tar.xz|*.txz)  tar -xJf "$file" --strip-components=1 ;;
            *.tar.bz2)       tar -xjf "$file" --strip-components=1 ;;
            *.tar)           tar -xf  "$file" --strip-components=1 ;;
            *.zip)           unzip -o -q "$file" ;;
            *)
                echo "  '$file' isn't a recognized archive type - treating it as a direct binary download."
                if [ "$file" != "$bin_name" ]; then
                    mv -f "$file" "$bin_name"
                fi
                ;;
        esac
        if [ ! -f "$bin_name" ]; then
            echo "  Binary not found after stripped extract, retrying flat..."
            case "$file" in
                *.tar.gz|*.tgz)  tar -xzf "$file" ;;
                *.tar.xz|*.txz)  tar -xJf "$file" ;;
                *.tar.bz2)       tar -xjf "$file" ;;
                *.tar)           tar -xf  "$file" ;;
                *.zip)
                    local entries=()
                    for e in "$miner_dir"/*; do
                        [ "$(basename "$e")" = "$file" ] && continue
                        entries+=("$e")
                    done
                    if [ "${#entries[@]}" -eq 1 ] && [ -d "${entries[0]}" ]; then
                        echo "  Flattening single top-level folder: $(basename "${entries[0]}")"
                        cp -a "${entries[0]}"/. "$miner_dir"/
                        rm -rf "${entries[0]}"
                    fi
                    ;;
            esac
        fi
        if [ "$file" != "$bin_name" ]; then
            rm -f "$file"
        fi
        if [ ! -f "$bin_name" ]; then
            echo "ERROR: Expected binary '$bin_name' not found after extracting $url!"
            exit 1
        fi
        chmod +x "$bin_name" 2>/dev/null
        echo "$version" > "$version_file"
    else
        echo ""
        echo "CUSTOM_MINER already installed (found $bin_name), skipping."
    fi
    local reported_version
    reported_version="$("$miner_dir/$bin_name" --version 2>&1 | head -n1)"
    if [ -n "$reported_version" ]; then
        echo "  Binary reports: $reported_version"
    else
        echo "  WARNING: '$bin_name --version' produced no output"
    fi
    echo "  Installed at: $miner_dir"
}
should_install() {
    local miner="$1"
    if [ "$INSTALL_ALL" = true ]; then
        return 0
    fi
    for requested in "${REQUESTED_MINERS[@]}"; do
        if [ "$requested" = "$miner" ]; then
            return 0
        fi
    done
    return 1
}
if should_install "xmrig"; then
    XMRIG_TAR="xmrig-${XMRIG_VERSION}-linux-static-x64.tar.gz"
    install_miner "xmrig" "$XMRIG_VERSION" \
      "https://github.com/xmrig/xmrig/releases/download/v${XMRIG_VERSION}/${XMRIG_TAR}" \
      "$XMRIG_TAR" "--strip-components=1" "xmrig"
fi
if should_install "wildrig-multi"; then
    WILDRIG_TAR="wildrig-multi-linux-${WILDRIG_VERSION}.tar.gz"
    install_miner "wildrig-multi" "$WILDRIG_VERSION" \
      "https://github.com/andru-kun/wildrig-multi/releases/download/${WILDRIG_VERSION}/${WILDRIG_TAR}" \
      "$WILDRIG_TAR" "" "wildrig-multi"
fi
if should_install "bzminer"; then
    BZ_TAR="bzminer_${BZMINER_VERSION}_linux.tar.gz"
    install_miner "bzminer" "$BZMINER_VERSION" \
      "https://github.com/bzminer/bzminer/releases/download/${BZMINER_VERSION}/${BZ_TAR}" \
      "$BZ_TAR" "--strip-components=1" "bzminer"
fi
if should_install "srbminer"; then
    SRB_DASH="${SRBMINER_VERSION//./-}"
    SRB_TAR="SRBMiner-Multi-${SRB_DASH}-Linux.tar.gz"
    install_miner "srbminer" "$SRBMINER_VERSION" \
      "https://github.com/doktor83/SRBMiner-Multi/releases/download/${SRBMINER_VERSION}/${SRB_TAR}" \
      "$SRB_TAR" "--strip-components=1" "SRBMiner-MULTI"
fi
if should_install "srbminer-cpu"; then
    SRB_CPU_DASH="${SRBMINER_CPU_VERSION//./-}"
    SRB_CPU_TAR="SRBMiner-Multi-${SRB_CPU_DASH}-Linux.tar.gz"
    install_miner "srbminer-cpu" "$SRBMINER_CPU_VERSION" \
      "https://github.com/doktor83/SRBMiner-Multi/releases/download/${SRBMINER_CPU_VERSION}/${SRB_CPU_TAR}" \
      "$SRB_CPU_TAR" "--strip-components=1" "SRBMiner-MULTI"
fi
if should_install "rigel"; then
    RIGEL_TAR="rigel-${RIGEL_VERSION}-linux.tar.gz"
    install_miner "rigel" "$RIGEL_VERSION" \
      "https://github.com/rigelminer/rigel/releases/download/${RIGEL_VERSION}/${RIGEL_TAR}" \
      "$RIGEL_TAR" "--strip-components=1" "rigel"
fi
if should_install "lolminer"; then
    LOL_TAR="lolMiner_v${LOLMINER_VERSION}_Lin64.tar.gz"
    install_miner "lolminer" "$LOLMINER_VERSION" \
      "https://github.com/Lolliedieb/lolMiner-releases/releases/download/${LOLMINER_VERSION}/${LOL_TAR}" \
      "$LOL_TAR" "--strip-components=1" "lolMiner"
fi
if should_install "onezerominer"; then
    ONEZERO_TAR="onezerominer-linux-${ONEZEROMINER_VERSION}.tar.gz"
    install_miner "onezerominer" "$ONEZEROMINER_VERSION" \
      "https://github.com/OneZeroMiner/OneZeroMiner/releases/download/v${ONEZEROMINER_VERSION}/${ONEZERO_TAR}" \
      "$ONEZERO_TAR" "--strip-components=1" "onezerominer"
fi
if should_install "gminer"; then
    GM_U="${GMINER_VERSION//./_}"
    GM_TAR="gminer_${GM_U}_linux64.tar.xz"
    install_miner "gminer" "$GMINER_VERSION" \
      "https://github.com/develsoftware/GMinerRelease/releases/download/${GMINER_VERSION}/${GM_TAR}" \
      "$GM_TAR" "" "miner"
fi
if should_install "teamredminer"; then
    TEAMRED_TAR="teamredminer-v${TEAMREDMINER_VERSION}-linux.tgz"
    install_miner "teamredminer" "$TEAMREDMINER_VERSION" \
      "https://github.com/todxx/teamredminer/releases/download/v${TEAMREDMINER_VERSION}/${TEAMRED_TAR}" \
      "$TEAMRED_TAR" "--strip-components=1" "teamredminer"
fi
if should_install "trex"; then
    TREX_TAR="t-rex-${TREXMINER_VERSION}-linux.tar.gz"
    install_miner "trexminer" "$TREXMINER_VERSION" \
      "https://github.com/trexminer/T-Rex/releases/download/${TREXMINER_VERSION}/${TREX_TAR}" \
      "$TREX_TAR" "" "t-rex"
fi
if [ -n "$CUSTOM_MINER_URL" ] && [ "$CUSTOM_MINER_URL" != "0" ]; then
    if [ -z "$CUSTOM_MINER_NAME" ] || [ "$CUSTOM_MINER_NAME" = "0" ]; then
        echo "ERROR: CUSTOM_MINER_URL is set but CUSTOM_MINER (binary name) is not — skipping custom miner install." >&2
    else
        install_custom_miner "$CUSTOM_MINER_URL" "$CUSTOM_MINER_NAME"
    fi
fi
cat <<EXPORTS > "$BASE_DIR/miner_paths.env"
$(if [ -f "$BASE_DIR/xmrig/current/xmrig" ]; then echo 'XMRIG_BIN="$BASE_DIR/xmrig/current/xmrig"'; fi)
$(if [ -f "$BASE_DIR/wildrig-multi/current/wildrig-multi" ]; then echo 'WILDRIG_BIN="$BASE_DIR/wildrig-multi/current/wildrig-multi"'; fi)
$(if [ -f "$BASE_DIR/bzminer/current/bzminer" ]; then echo 'BZMINER_BIN="$BASE_DIR/bzminer/current/bzminer"'; fi)
$(if [ -f "$BASE_DIR/srbminer/current/SRBMiner-MULTI" ]; then echo 'SRBMINER_BIN="$BASE_DIR/srbminer/current/SRBMiner-MULTI"'; fi)
$(if [ -f "$BASE_DIR/srbminer-cpu/current/SRBMiner-MULTI" ]; then echo 'SRBMINER_CPU_BIN="$BASE_DIR/srbminer-cpu/current/SRBMiner-MULTI"'; fi)
$(if [ -f "$BASE_DIR/rigel/current/rigel" ]; then echo 'RIGEL_BIN="$BASE_DIR/rigel/current/rigel"'; fi)
$(if [ -f "$BASE_DIR/lolminer/current/lolMiner" ]; then echo 'LOLMINER_BIN="$BASE_DIR/lolminer/current/lolMiner"'; fi)
$(if [ -f "$BASE_DIR/onezerominer/current/onezerominer" ]; then echo 'ONEZEROMINER_BIN="$BASE_DIR/onezerominer/current/onezerominer"'; fi)
$(if [ -f "$BASE_DIR/gminer/current/miner" ]; then echo 'GMINER_BIN="$BASE_DIR/gminer/current/miner"'; fi)
$(if [ -f "$BASE_DIR/teamredminer/current/teamredminer" ]; then echo 'TEAMREDMINER_BIN="$BASE_DIR/teamredminer/current/teamredminer"'; fi)
$(if [ -f "$BASE_DIR/trexminer/current/t-rex" ]; then echo 'TREXMINER_BIN="$BASE_DIR/trexminer/current/t-rex"'; fi)
$(if [ -n "$CUSTOM_MINER_NAME" ] && [ "$CUSTOM_MINER_NAME" != "0" ] && [ -f "$BASE_DIR/custom/$CUSTOM_MINER_NAME/current/$CUSTOM_MINER_NAME" ]; then echo "CUSTOM_MINER_BIN=\"\$BASE_DIR/custom/$CUSTOM_MINER_NAME/current/$CUSTOM_MINER_NAME\""; fi)
EXPORTS
echo ""
echo "Miner paths saved to: $BASE_DIR/miner_paths.env"
echo "Load them with: source $BASE_DIR/miner_paths.env"
if [ -f "$BASE_DIR/miner_paths.env" ]; then
    source "$BASE_DIR/miner_paths.env"
fi
echo ""
echo "Installation complete!"
EOF
sudo tee /usr/local/bin/lib/02-load_configs.sh > /dev/null <<'EOF'
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
EOF
sudo tee /usr/local/bin/lib/03-cpu_threads.sh > /dev/null <<'EOF'
TOTAL_THREADS=$(nproc)
CPU_THREADS=$((TOTAL_THREADS - 1))
AUTOFILL_CPU=""
if [[ "$MINER_NAME" == "xmrig" && "$ALGO" == "rx/0" ]]; then
    RX_THREADS=-1
    if [[ "$TOTAL_THREADS" -eq 32 ]]; then
        RX_THREADS=31
        RX_CORES=(0 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31)
    elif [[ "$TOTAL_THREADS" -eq 24 ]]; then
        RX_THREADS=23
        RX_CORES=(0 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23)
    fi
    if [[ "$RX_THREADS" -ne -1 ]]; then
        BITMASK=0
        for core in "${RX_CORES[@]}"; do
            (( BITMASK |= (1 << core) ))
        done
        RX_MASK=$(printf "0x%X" "$BITMASK")
        AUTOFILL_CPU="$RX_THREADS --cpu-affinity=$RX_MASK"
    fi
fi
EOF
sudo tee /usr/local/bin/lib/04-algo_config.sh > /dev/null <<'EOF'
WARTHOG_TARGET=""
if [[ "$ALGO" == "warthog" ]]; then
    if (( TOTAL_THREADS >= 32 )); then
        WARTHOG_TARGET=47000000
    elif (( TOTAL_THREADS >= 24 )); then
        WARTHOG_TARGET=37000000
    else
        WARTHOG_TARGET=30000000
    fi
fi
EOF
ls -lh /usr/local/bin/lib/
