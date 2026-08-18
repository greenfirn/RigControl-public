sudo mkdir -v /usr/local/bin/lib

sudo tee /usr/local/bin/lib/00-get_rig_conf.sh > /dev/null <<'EOF'
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
EOF

sudo tee /usr/local/bin/lib/01-miner_install.sh > /dev/null <<'EOF'

XMRIG_VERSION=$(get_rig_conf "$MINER_CONF" "XMRIG_VERSION" "0")
BZMINER_VERSION=$(get_rig_conf "$MINER_CONF" "BZMINER_VERSION" "0")
WILDRIG_VERSION=$(get_rig_conf "$MINER_CONF" "WILDRIG_VERSION" "0")
SRBMINER_VERSION=$(get_rig_conf "$MINER_CONF" "SRBMINER_VERSION" "0")
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

# Miner selection: no args -> use MINER from rig.conf; single arg "all" (case-insensitive) -> install every miner; any other args -> install only those named miners.
# convert_old_miner_name (from 00-get_rig_conf.sh) upgrades legacy slugs
# (e.g. "wildrig" -> "wildrig-multi") wherever a miner name comes in, so
# should_install()/install_miner() only ever see the current canonical name.
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

cleanup_old_versions() {
    local miner="$1"
    local keep="$2"

    local folder="$BASE_DIR/$miner"
    [ -d "$folder" ] || return 0

    for dir in "$folder"/*; do
        [[ "$dir" == "$folder/current" ]] && continue
        [[ "$dir" == "$folder/$keep" ]] && continue
        echo "  Removing old version: $dir"
        rm -rf "$dir"
    done
}

install_miner() {
    local name="$1"
    local version="$2"
    local url="$3"
    local file="$4"
    local strip="$5"
    local bin_name="$6"

    local miner_dir="$BASE_DIR/$name/$version"
    local bin_path="$miner_dir/$bin_name"

    if [ ! -f "$bin_path" ]; then
        echo ""
        echo "==== Installing $name $version ===="
        rm -rf "$miner_dir"
        mkdir -p "$miner_dir"
        cd "$miner_dir"

        download_with_retry "$file" "$url"

        echo "  Extracting..."
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
    else
        echo ""
        echo "$name $version already installed (found $bin_name), skipping."
    fi

    ln -sfn "$miner_dir" "$BASE_DIR/$name/current"
    echo "  Symlink: $BASE_DIR/$name/current -> $miner_dir"

    cleanup_old_versions "$name" "$version"
}

install_custom_miner() {
    local url="$1"
    local bin_name="$2"

    local file
    file="$(basename "$url")"

    local version
    version="$(echo -n "$url" | md5sum | cut -d' ' -f1)"

    local miner_dir="$BASE_DIR/$bin_name/$version"
    local bin_path="$miner_dir/$bin_name"

    if [ ! -f "$bin_path" ]; then
        echo ""
        echo "==== Installing CUSTOM_MINER ($bin_name) ===="
        rm -rf "$miner_dir"
        mkdir -p "$miner_dir"
        cd "$miner_dir"

        download_with_retry "$file" "$url"

        echo "  Extracting..."
        case "$file" in
            *.tar.gz|*.tgz)  tar -xzf "$file" --strip-components=1 ;;
            *.tar.xz|*.txz)  tar -xJf "$file" --strip-components=1 ;;
            *.tar.bz2)       tar -xjf "$file" --strip-components=1 ;;
            *.tar)           tar -xf  "$file" --strip-components=1 ;;
            *.zip)           unzip -o -q "$file" ;;
            *)
                # Not a recognized archive extension - assume CUSTOM_MINER_URL
                # points directly at the binary itself (e.g. a raw executable
                # asset with no/unusual extension) rather than failing
                # outright. Rename it into place as $bin_name so the checks
                # below find it exactly like a freshly-extracted archive would.
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

    ln -sfn "$miner_dir" "$BASE_DIR/$bin_name/current"
    echo "  Symlink: $BASE_DIR/$bin_name/current -> $miner_dir"

    cleanup_old_versions "$bin_name" "$version"
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
$(if [ -f "$BASE_DIR/rigel/current/rigel" ]; then echo 'RIGEL_BIN="$BASE_DIR/rigel/current/rigel"'; fi)
$(if [ -f "$BASE_DIR/lolminer/current/lolMiner" ]; then echo 'LOLMINER_BIN="$BASE_DIR/lolminer/current/lolMiner"'; fi)
$(if [ -f "$BASE_DIR/onezerominer/current/onezerominer" ]; then echo 'ONEZEROMINER_BIN="$BASE_DIR/onezerominer/current/onezerominer"'; fi)
$(if [ -f "$BASE_DIR/gminer/current/miner" ]; then echo 'GMINER_BIN="$BASE_DIR/gminer/current/miner"'; fi)
$(if [ -f "$BASE_DIR/teamredminer/current/teamredminer" ]; then echo 'TEAMREDMINER_BIN="$BASE_DIR/teamredminer/current/teamredminer"'; fi)
$(if [ -f "$BASE_DIR/trexminer/current/t-rex" ]; then echo 'TREXMINER_BIN="$BASE_DIR/trexminer/current/t-rex"'; fi)
$(if [ -n "$CUSTOM_MINER_NAME" ] && [ "$CUSTOM_MINER_NAME" != "0" ] && [ -f "$BASE_DIR/$CUSTOM_MINER_NAME/current/$CUSTOM_MINER_NAME" ]; then echo "CUSTOM_MINER_BIN=\"\$BASE_DIR/$CUSTOM_MINER_NAME/current/$CUSTOM_MINER_NAME\""; fi)
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
