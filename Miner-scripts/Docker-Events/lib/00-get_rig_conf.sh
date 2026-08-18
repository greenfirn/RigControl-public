# Derived from CFG_FILE (rig-gpu.conf -> rig-gpu.json, rig-cpu.conf ->
# rig-cpu.json) so CPU and GPU rigs each get/read their own JSON file
# instead of both landing on rig-gpu.json. CFG_FILE must already be set by
# the time this is sourced (docker_events_universal.sh sets/exports it from
# OC_FILE before sourcing the lib/ files) - falls back to the old fixed
# path only if CFG_FILE somehow isn't set yet.
if [[ -n "$CFG_FILE" ]]; then
    RIG_GPU_JSON="${CFG_FILE%.conf}.json"
else
    RIG_GPU_JSON="/etc/rigcontrol/rig-gpu.json"
fi

# Old miner slug -> current canonical slug. Canonical names now match
# HiveOS's own naming (e.g. "wildrig-multi", not the old short "wildrig")
# so rig-gpu.json never needs per-miner translation. Add future renames
# here — every place a miner name gets read from user input or an old
# .conf file runs it through this first.
convert_old_miner_name() {
    local name="$1"
    case "$name" in
        wildrig) echo "wildrig-multi" ;;
        *)       echo "$name" ;;
    esac
}

# Keys this JSON layout can actually supply. Anything else always falls
# through to the plain-text conf file (miner version numbers, SCREEN_NAME,
# etc. still have no equivalent in this JSON). POOL_URLS added alongside
# POOL — same JSON-first gate, same fallback-to-conf behavior for rigs
# whose rig-gpu.json has no pool_urls array (or no rig-gpu.json at all).
RIG_GPU_JSON_KEYS=" ALGO PASS ARGS POOL POOL_URLS TEMPLATE WALLET_ADDR MINER CUSTOM_MINER CUSTOM_MINER_URL TARGET_IMAGE TARGET_NAME RESET_OC APPLY_OC HUGEPAGES CPU_CONFIG TLS CPU "

# jq filter: takes rig-gpu.json (HiveOS-flightsheet-shaped export, dropped
# fields we don't use: pool, pool_geo, wal_id, dpool_ssl) and derives the
# RigControl key requested via --arg k.
#   items[0] only — first miner entry in the sheet.
#   "miner":"custom" -> MINER blank, CUSTOM_MINER = miner_alt (falls back to
#     miner_config.miner), CUSTOM_MINER_URL = miner_config.install_url.
#   built-in miner    -> MINER = miner_alt when HiveOS supplies one (HiveOS
#     uses variant slugs like "xmrig-new" for specific builds/forks, with
#     miner_alt carrying the base family name RigControl actually
#     recognizes, e.g. "xmrig"); falls back to the raw miner slug when
#     miner_alt is absent (e.g. "wildrig-multi", which already matches
#     RigControl's own naming). convert_old_miner_name handles legacy short
#     names on the .conf side.
#   POOL is built from miner_config.url + pool_ssl (stratum+ssl:// vs
#     stratum+tcp:// prefix) - most miners (trex, teamredminer, rigel,
#     lolminer, bzminer, onezerominer) actually require an explicit
#     scheme even for a plain connection, so stratum+tcp:// stays the
#     default. gminer/xmrig/srbminer/wildrig-multi don't care either way
#     - get_start_cmd() on the rig side already strips it back off via
#     POOL_HOST for those. Custom miners are the one real exception: they
#     never get a prefix at all, regardless of pool_ssl, since they
#     handle their own URL/TLS entirely through their own hand-built
#     ARGS (e.g. srbminer_custom's user_config already has its own
#     --pool host:port) - POOL isn't even read for them on the rig side.
#   POOL_URLS mirrors POOL's own scheme convention across every entry in
#     items[0].pool_urls (primary/secondary/... failover pools), joined
#     with "|" since conf values are single-line strings —
#     02-load_configs.sh's get_pool_url_list() splits back on "|". Each
#     entry is re-prefixed from scratch (existing prefixes stripped first)
#     so every pool's SSL state stays consistent with pool_ssl even if the
#     source array carried mixed/stale prefixes. Custom miners get "" for
#     the same reason POOL does — they never read this on the rig side.
#     Empty/absent pool_urls also collapses to "" — get_pool_url_list()
#     already falls back to the single POOL value in that case, so rigs
#     with only one configured pool need no changes.
#   TEMPLATE = miner_config.template, WALLET_ADDR = miner_config.wallet_address
#     — split the same way HiveOS itself splits a flightsheet's wallet:
#     TEMPLATE is pattern text (may contain %WALLET% or HiveOS's own %WAL%,
#     plus the usual %WORKER_NAME%), WALLET_ADDR is just the raw address
#     that fills it in. 02-load_configs.sh resolves TEMPLATE with
#     WALLET_ADDR into the rig's actual $WALLET command-line value (see
#     its own comment block for the substitution order) - this file just
#     hands both pieces over unresolved. A rig-gpu.json saved before this
#     split existed (or bootstrapped fresh from a legacy .conf - see
#     generate_rig_gpu_json_from_conf below) simply has no wallet_address
#     key at all, so WALLET_ADDR comes back "" and TEMPLATE alone (already
#     a fully-resolved address in that case, no token to substitute) is
#     used as-is - no migration needed for rigs already deployed with the
#     old single-field shape. %WORKER_NAME% can show up in different
#     fields for different miners (TEMPLATE, PASS, ARGS, ...) and is left
#     untouched here — see resolve_worker_name below, which the caller
#     applies once it's actually consuming the value (not here, so the
#     token still round-trips correctly when this file is regenerated
#     from .conf — see generate_rig_gpu_json_from_conf).
#   ARGS = miner_config.user_config (custom miners' raw CLI args string).
#     The web app's Flightsheet editor DISPLAYS xmrig's HiveOS JSON-style
#     OC/behavior overrides (user_config's flat key/value lines, plus a
#     separate cpu_config field holding xmrig's own config.json "cpu"
#     object) as converted real CLI flags for readability, but writes
#     the ORIGINAL unconverted JSON text back into this file on save -
#     same reasoning as bzminer's own OC-override JSON (see
#     fsXmrigOcJsonUserConfig/fsBzminerOcJsonUserConfig in the web app):
#     staying byte-compatible with being pasted back into HiveOS matters
#     more than saving this script a conversion step. So ARGS here can
#     still be that literal JSON text rather than real flags -
#     02-load_configs.sh's convert_xmrig_user_config_to_args() mirrors
#     the web app's own conversion logic to handle it at launch time,
#     the same way convert_bzminer_oc_json_to_args() already does for
#     bzminer.
#   CPU_CONFIG = miner_config.cpu_config - xmrig's separate JSON "cpu"
#     config block (see above) - also kept in its original JSON form
#     here, converted rig-side by convert_xmrig_cpu_config_to_args() and
#     folded into the same command line as ARGS above.
#   TLS = miner_config.tls - xmrig's own separate TLS toggle (mirrors its
#     config.json "tls" boolean and --tls CLI flag 1:1) - real-world
#     HiveOS exports can have this set independently of the
#     flightsheet's own top-level pool_ssl (e.g. pool_ssl:false, tls:1),
#     so 02-load_configs.sh checks both when deciding whether to add
#     --tls, not just POOL_SSL. tostring for the same reason as
#     HUGEPAGES above - arrives as a JSON number/boolean, not a string.
#   HUGEPAGES = miner_config.hugepages - an xmrig-only OS-level page
#     COUNT the rig needs to actually allocate via sysctl before xmrig
#     can benefit from huge pages (see 02-load_configs.sh's
#     apply_xmrig_hugepages()) - distinct from cpu_config's "huge-pages"
#     boolean (already converted to --no-huge-pages when false, or
#     omitted when true, since true is xmrig's own default and needs no
#     flag) which just tells xmrig whether to USE huge pages if they're
#     already available. tostring since jq's // only substitutes on
#     null/false, and this value arrives as a JSON number.
#   TARGET_IMAGE/TARGET_NAME/RESET_OC/APPLY_OC have no HiveOS equivalent —
#   they're read/written as plain sibling keys on items[0] itself (not
#   inside miner_config), same string values as the .conf ("" / "true").
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

# Only try to bootstrap rig-gpu.json once per script run — if generation
# fails (no CFG_FILE, no jq, nothing to write), don't retry it on every
# single get_rig_conf call for the rest of the run.
RIG_GPU_JSON_GENERATE_ATTEMPTED=""

# Builds /etc/rigcontrol/rig-gpu.json from the current plain-text conf file,
# so a legacy rig that's never had rig-gpu.json still ends up on the same
# JSON-first path going forward. Reuses get_rig_conf() itself to pull the
# values — safe to do here since RIG_GPU_JSON doesn't exist yet at the point
# this runs, so those calls fall straight through to the .conf reader below.
# Reverses the same POOL string convention (stratum+ssl:// / stratum+tcp://)
# used when reading POOL back out. Only writes a file if there's an actual
# miner configured; otherwise leaves rig-gpu.json absent (nothing to record
# yet, keep behavior on plain .conf until there is). Doesn't emit a
# pool_urls array — legacy .conf has no multi-pool concept, so bootstrapped
# rigs simply have none until a multi-pool flightsheet is pushed to them;
# get_pool_url_list() on the rig side already treats that the same as a
# single-pool flightsheet.
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

    # First call in this run, no rig-gpu.json yet — try to generate one from
    # the .conf file before we go any further. Flag is set before calling so
    # the get_rig_conf calls generate_rig_gpu_json_from_conf makes internally
    # don't loop back into this block.
    if [[ ! -f "$RIG_GPU_JSON" && -z "$RIG_GPU_JSON_GENERATE_ATTEMPTED" ]]; then
        RIG_GPU_JSON_GENERATE_ATTEMPTED=1
        generate_rig_gpu_json_from_conf
    fi

    # rig-gpu.json is the sole source when present — no mixing with the
    # plain-text conf file for keys it supplies. Flat, no per-GPU overrides
    # — gpu_id is not used on this path.
    if [[ -f "$RIG_GPU_JSON" ]] && command -v jq >/dev/null 2>&1 && [[ "$RIG_GPU_JSON_KEYS" == *" $key "* ]]; then
        local json_val
        if json_val=$(jq -r --arg k "$key" "$RIG_GPU_JQ_FILTER" "$RIG_GPU_JSON" 2>/dev/null); then
            [[ "$json_val" == "null" ]] && json_val=""
            echo "$json_val"
            return
        fi
        # rig-gpu.json exists but failed to parse — fall through below.
    fi

    # Fall back to the plain-text conf file (rig-gpu.json missing, jq not
    # installed, this key isn't part of the JSON layout, or the JSON failed
    # to parse).
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

# Fills in %WORKER_NAME% wherever it shows up. Different miners put the
# token in different fields — WALLET, PASS, ARGS, whichever miner_config
# key HiveOS used it in — so this isn't tied to any one field. Callers
# apply it themselves to each value once they're actually about to use it
# (e.g. 02-load_configs.sh, right after each get_rig_conf call for
# ALGO/PASS/ARGS/POOL/WALLET). Deliberately NOT called from inside
# get_rig_conf or generate_rig_gpu_json_from_conf — the token needs to
# survive intact into rig-gpu.json so it's still there to resolve the next
# time this file is read, not baked in (or blanked out, if WORKER_NAME
# isn't set yet at generation time) once and lost.
resolve_worker_name() {
    local value="$1"
    echo "${value//%WORKER_NAME%/$WORKER_NAME}"
}

# Fills in %WALLET% wherever it shows up - a general-purpose substitution
# (RigControl web app's ARGS field has a clickable token for it) letting
# any OTHER flightsheet field reference the flightsheet's own resolved
# WALLET value without hand-copying/duplicating it. Not applied to WALLET
# itself (self-referential, and WALLET is what supplies the value here in
# the first place) - callers apply this to every other field
# (ALGO/ARGS/POOL/POOL_URLS in 02-load_configs.sh) only after WALLET has
# already been read and resolved (see resolve_worker_name above - WALLET
# can itself contain %WORKER_NAME%, so that substitution has to happen
# first).
resolve_wallet() {
    local value="$1"
    echo "${value//%WALLET%/$WALLET}"
}

# Same idea as resolve_wallet() above, for %PASS% - lets the RigControl
# web app's Pool field preview (and anything else) reference this
# flightsheet's own PASS value with a short token instead of repeating it.
# Not applied to PASS itself. Callers apply this to every other field
# (ALGO/ARGS/POOL/POOL_URLS) only after PASS has already been read and
# resolved.
resolve_pass() {
    local value="$1"
    echo "${value//%PASS%/$PASS}"
}

# Same idea as resolve_wallet()/resolve_pass() above, for %URL% - lets ARGS
# (and ALGO) reference this flightsheet's own resolved POOL value with a
# short token instead of repeating it. This matters most for CUSTOM_MINER:
# get_start_cmd() in 02-load_configs.sh doesn't append any pool flags of
# its own for a custom binary (it just runs "$custom $ARGS" verbatim), so
# %URL% in ARGS is the ONLY way a custom miner receives the pool address
# from the flightsheet at all. Not applied to POOL itself. Callers apply
# this to ALGO/ARGS only after POOL has already been read and resolved.
resolve_url() {
    local value="$1"
    echo "${value//%URL%/$POOL}"
}

# Same idea as resolve_url() above, for %ALGO% - lets ARGS reference this
# flightsheet's own resolved ALGO value with a short token, for miners
# whose ARGS needs the algo name repeated in a flag RigControl doesn't
# already build for it (e.g. a CUSTOM_MINER, or an extra --algo-style flag
# a built-in miner's own get_start_cmd() branch doesn't add). Not applied
# to ALGO itself. Callers apply this to ARGS only after ALGO has already
# been read and resolved.
resolve_algo() {
    local value="$1"
    echo "${value//%ALGO%/$ALGO}"
}

# %WAL% in ARGS, resolved straight from WALLET_ADDR - independent of
# TEMPLATE/$WALLET. $WALLET only gets a value when TEMPLATE itself
# contains a %WALLET%/%WAL% pattern to substitute into (see the
# TEMPLATE/WALLET_ADDR block below), so a custom miner whose flightsheet
# has no TEMPLATE set at all (just a raw WALLET_ADDR, the common case for
# a plain ARGS-driven custom binary) would otherwise never get its wallet
# address into ARGS. This substitutes %WAL% directly from WALLET_ADDR so
# ARGS doesn't need TEMPLATE set up at all - only applied to ARGS.
resolve_wallet_addr() {
    local value="$1"
    echo "${value//%WAL%/$WALLET_ADDR}"
}

# %URL%[N] (0-indexed) resolves to the Nth entry of POOL_URLS - lets ARGS
# (and ALGO) reference a SPECIFIC pool, not just the primary that plain
# %URL% already covers (%URL% and %URL%[0] are equivalent). Useful for a
# custom miner whose own CLI wants secondary/tertiary failover pools
# spelled out explicitly, since RigControl's own -o/-o/-o repetition in
# build_pool_cmd_args() only applies to known miners' get_start_cmd()
# branches, never to a custom binary's raw ARGS. Depends on
# get_pool_url_list() (defined below, in the same sourced environment -
# call-time resolution, so definition order between the two doesn't
# matter) which falls back to just $POOL for index 0 when POOL_URLS is
# empty (single-pool flightsheet, or one saved before pool_urls existed).
# An index with no corresponding pool resolves to an empty string rather
# than erroring, since a hand-edited ARGS string could reference an index
# that doesn't exist for a particular flightsheet. MUST run before
# resolve_url(): resolve_url()'s blind %URL% substring replace would
# otherwise mangle %URL%[N] into <resolved-primary-pool>[N] before this
# function ever gets a chance to see the indexed form.
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
