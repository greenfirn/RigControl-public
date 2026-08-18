#!/bin/bash
# Standalone converter: reads a RigControl-style .conf file and writes out
# the rig-gpu.json layout (HiveOS-flightsheet-shaped, dropped fields we
# don't use: pool, pool_geo, wal_id, dpool_ssl). Same conversion logic as
# generate_rig_gpu_json_from_conf() in 00-get_rig_conf.sh — this is just a
# standalone copy so you can run/inspect it on a rig without installing the
# full lib set first.
#
# Usage:
#   ./convert-conf-to-rig-gpu-json.sh [cfg_file] [output_json]
#
# Defaults:
#   cfg_file    = /etc/rigcontrol/rig-gpu.conf
#   output_json = same path as cfg_file with .conf swapped for .json (so
#                 rig-cpu.conf defaults to rig-cpu.json, not rig-gpu.json)
#
# To test safely without touching the real rig-gpu.json, pass a throwaway
# output path:
#   ./convert-conf-to-rig-gpu-json.sh /etc/rigcontrol/rig-gpu.conf /tmp/rig-gpu-test.json

set -u

CFG_FILE="${1:-/etc/rigcontrol/rig-gpu.conf}"
OUT_JSON="${2:-${CFG_FILE%.conf}.json}"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not installed." >&2
    exit 1
fi

if [[ ! -f "$CFG_FILE" ]]; then
    echo "ERROR: conf file not found: $CFG_FILE" >&2
    exit 1
fi

# Old miner slug -> current canonical slug. Canonical names now match
# HiveOS's own naming (e.g. "wildrig-multi", not the old short "wildrig").
# Same helper as convert_old_miner_name in 00-get_rig_conf.sh — add future
# renames here too if you add one there.
convert_old_miner_name() {
    local name="$1"
    case "$name" in
        wildrig) echo "wildrig-multi" ;;
        *)       echo "$name" ;;
    esac
}

# Plain-text conf lookup — same KEY GPU_ID VALUE / "ALL" fallback semantics
# as get_rig_conf's own fallback path.
get_rig_conf_from_file() {
    local cfg_file="$1"
    local key="$2"
    local gpu_id="$3"

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

miner=$(get_rig_conf_from_file "$CFG_FILE" "MINER" "0")
miner=$(convert_old_miner_name "$miner")
algo=$(get_rig_conf_from_file "$CFG_FILE" "ALGO" "0")
pass=$(get_rig_conf_from_file "$CFG_FILE" "PASS" "0")
args=$(get_rig_conf_from_file "$CFG_FILE" "ARGS" "0")
pool=$(get_rig_conf_from_file "$CFG_FILE" "POOL" "0")
wallet=$(get_rig_conf_from_file "$CFG_FILE" "WALLET" "0")
custom_miner=$(get_rig_conf_from_file "$CFG_FILE" "CUSTOM_MINER" "0")
custom_miner_url=$(get_rig_conf_from_file "$CFG_FILE" "CUSTOM_MINER_URL" "0")
target_image=$(get_rig_conf_from_file "$CFG_FILE" "TARGET_IMAGE" "0")
target_name=$(get_rig_conf_from_file "$CFG_FILE" "TARGET_NAME" "0")
reset_oc=$(get_rig_conf_from_file "$CFG_FILE" "RESET_OC" "0")
apply_oc=$(get_rig_conf_from_file "$CFG_FILE" "APPLY_OC" "0")

echo "Read from $CFG_FILE:" >&2
echo "  MINER=$miner  CUSTOM_MINER=$custom_miner  CUSTOM_MINER_URL=$custom_miner_url" >&2
echo "  ALGO=$algo  PASS=$pass  ARGS=$args" >&2
echo "  POOL=$pool" >&2
echo "  WALLET=$wallet" >&2
echo "  TARGET_IMAGE=$target_image  TARGET_NAME=$target_name  RESET_OC=$reset_oc  APPLY_OC=$apply_oc" >&2
echo "" >&2

if [[ -z "$miner" && -z "$custom_miner" ]]; then
    echo "ERROR: no MINER or CUSTOM_MINER set in $CFG_FILE — nothing to convert." >&2
    exit 1
fi

pool_ssl="false"
pool_url="$pool"
case "$pool" in
    stratum+ssl://*) pool_ssl="true";  pool_url="${pool#stratum+ssl://}" ;;
    stratum+tcp://*) pool_ssl="false"; pool_url="${pool#stratum+tcp://}" ;;
esac

miner_field="$miner"
miner_alt_field=""
mc_miner_field=""
install_url_field=""
if [[ -n "$custom_miner" && "$custom_miner" != "0" ]]; then
    miner_field="custom"
    miner_alt_field="$custom_miner"
    mc_miner_field="$custom_miner"
    install_url_field="$custom_miner_url"
fi

mkdir -p "$(dirname "$OUT_JSON")" 2>/dev/null

if ! jq -n \
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
   }' > "${OUT_JSON}.tmp"; then
    echo "ERROR: jq failed to build the JSON." >&2
    rm -f "${OUT_JSON}.tmp"
    exit 1
fi

mv "${OUT_JSON}.tmp" "$OUT_JSON"

echo "Wrote: $OUT_JSON" >&2
echo "--- content ---" >&2
jq '.' "$OUT_JSON"
