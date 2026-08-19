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
        wildrig) echo "wildrig-multi" ;;
        *)       echo "$name" ;;
    esac
}
RIG_GPU_JSON_KEYS=" ALGO PASS ARGS POOL POOL_URLS TEMPLATE WALLET_ADDR MINER CUSTOM_MINER CUSTOM_MINER_URL TARGET_IMAGE TARGET_NAME RESET_OC APPLY_OC HUGEPAGES CPU_CONFIG TLS CPU "
RIG_GPU_JQ_FILTER=$(cat <<'JQ'
  .items[0] as $it
  | ($it.miner_config // {}) as $mc
  | ($it.miner == "custom") as $is_custom
  | {
      ALGO: ($mc.algo // ""),
      PASS: ($mc.pass // ""),
      ARGS: ($mc.user_config // ""),
      POOL: (if (($mc.url // "") == "") then "" else
          (if ($is_custom) then "" elif ($it.pool_ssl == true) then "stratum+ssl://" else "stratum+tcp://" end) + $mc.url
        end),
      POOL_URLS: (
          ($it.pool_urls // [])
          | map(sub("^stratum\\+ssl://"; "") | sub("^stratum\\+tcp://"; ""))
          | (if $is_custom then . else
              map(if ($it.pool_ssl == true) then "stratum+ssl://" + . else "stratum+tcp://" + . end)
            end)
          | join("|")
        ),
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
        generate_rig_gpu_json_from_conf
    fi
    if [[ -f "$RIG_GPU_JSON" ]] && command -v jq >/dev/null 2>&1 && [[ "$RIG_GPU_JSON_KEYS" == *" $key "* ]]; then
        local json_val
        if json_val=$(jq -r --arg k "$key" "$RIG_GPU_JQ_FILTER" "$RIG_GPU_JSON" 2>/dev/null); then
            [[ "$json_val" == "null" ]] && json_val=""
            echo "$json_val"
            return
        fi
        # rig-gpu.json exists but failed to parse — fall through below.
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
