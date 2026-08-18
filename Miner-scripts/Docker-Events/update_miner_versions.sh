# Ensure jq is available for parsing GitHub API JSON responses
sudo apt update
sudo apt install -y jq

sudo tee /usr/local/bin/update_miner_versions.sh > /dev/null <<'EOF'
#!/bin/bash

set -Eeuo pipefail
shopt -s inherit_errexit

# ---------------------------------------------------------
# CONFIG
# ---------------------------------------------------------
: "${MINER_CONF:=/etc/rigcontrol/miner.conf}"

# GitHub API requires a User-Agent header or it 4xx's the request.
UA="rigcloud-version-updater"

# Optional: export GITHUB_TOKEN to raise the rate limit from 60/hr
# (unauthenticated) to 5000/hr - useful if this gets scheduled often
# across many rigs sharing an egress IP.
AUTH_HEADER=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    AUTH_HEADER=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

# KEY -> "owner/repo", taken directly from the download URLs already
# hardcoded in lib/01-miner_install.sh.
declare -A REPO=(
    [XMRIG_VERSION]="xmrig/xmrig"
    [BZMINER_VERSION]="bzminer/bzminer"
    [WILDRIG_VERSION]="andru-kun/wildrig-multi"
    [SRBMINER_VERSION]="doktor83/SRBMiner-Multi"
    [RIGEL_VERSION]="rigelminer/rigel"
    [LOLMINER_VERSION]="Lolliedieb/lolMiner-releases"
    [ONEZEROMINER_VERSION]="OneZeroMiner/OneZeroMiner"
    [GMINER_VERSION]="develsoftware/GMinerRelease"
    [TEAMREDMINER_VERSION]="todxx/teamredminer"
    [TREXMINER_VERSION]="trexminer/T-Rex"
)

# Preserve ordering for the rewritten miner.conf (bash associative arrays
# have no guaranteed order).
KEY_ORDER=(
    XMRIG_VERSION
    BZMINER_VERSION
    WILDRIG_VERSION
    SRBMINER_VERSION
    RIGEL_VERSION
    LOLMINER_VERSION
    ONEZEROMINER_VERSION
    GMINER_VERSION
    TEAMREDMINER_VERSION
    TREXMINER_VERSION
)

# Miner name (as used in rig.conf's MINER field / add_api_flags) -> VERSION key.
# Aliases included for miners known by more than one name.
declare -A NAME_TO_KEY=(
    [xmrig]="XMRIG_VERSION"
    [xmrig-cpu]="XMRIG_VERSION"
    [xmrig-gpu]="XMRIG_VERSION"
    [bzminer]="BZMINER_VERSION"
    [wildrig]="WILDRIG_VERSION"
    [srbminer]="SRBMINER_VERSION"
    [srbminer-cpu]="SRBMINER_VERSION"
    [srbminer-gpu]="SRBMINER_VERSION"
    [srbminer-multi]="SRBMINER_VERSION"
    [rigel]="RIGEL_VERSION"
    [lolminer]="LOLMINER_VERSION"
    [onezerominer]="ONEZEROMINER_VERSION"
    [gminer]="GMINER_VERSION"
    [teamredminer]="TEAMREDMINER_VERSION"
    [t-rex]="TREXMINER_VERSION"
    [trex]="TREXMINER_VERSION"
    [trexminer]="TREXMINER_VERSION"
)

usage() {
    echo "Usage: $(basename "$0") [miner_name ...]"
    echo ""
    echo "  No arguments      - check/update ALL known miners"
    echo "  miner_name ...    - check/update only the named miner(s), leaving all others untouched"
    echo ""
    echo "Valid miner names: xmrig, bzminer, wildrig, srbminer, rigel, lolminer, onezerominer, gminer, teamredminer, t-rex (aliases: trex, trexminer)"
}

if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
    usage
    exit 0
fi

SELECTED_KEYS=()
if [[ $# -eq 0 ]]; then
    SELECTED_KEYS=("${KEY_ORDER[@]}")
else
    for arg in "$@"; do
        arg_lower=$(echo "$arg" | tr '[:upper:]' '[:lower:]')
        key="${NAME_TO_KEY[$arg_lower]:-}"
        if [[ -z "$key" ]]; then
            echo "[warn] Unknown miner name: '$arg' - skipping" >&2
            continue
        fi
        # Avoid duplicate entries if the same miner (or an alias of it) is passed twice
        already_selected=false
        for k in "${SELECTED_KEYS[@]:-}"; do
            [[ "$k" == "$key" ]] && already_selected=true && break
        done
        [[ "$already_selected" == true ]] || SELECTED_KEYS+=("$key")
    done

    if [[ ${#SELECTED_KEYS[@]} -eq 0 ]]; then
        echo "[error] No valid miner names given." >&2
        usage
        exit 1
    fi
fi

# Keys whose stored value must NOT include a leading "v" - because
# lib/01-miner_install.sh's own download URL template re-adds "v" itself
# (v${XMRIG_VERSION}, v${ONEZEROMINER_VERSION}, v${TEAMREDMINER_VERSION}).
# Every other key is stored exactly as GitHub's tag_name comes back,
# because those install templates use the version raw, with no "v" added
# (this includes bzminer, whose own tags already embed a "v", e.g.
# "v25.0.0b6" - stripping it here would break that miner's download URL).
STRIP_V_KEYS=("XMRIG_VERSION" "ONEZEROMINER_VERSION" "TEAMREDMINER_VERSION")

should_strip_v() {
    local key="$1"
    local k
    for k in "${STRIP_V_KEYS[@]}"; do
        [[ "$k" == "$key" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------
# GITHUB LOOKUP
# ---------------------------------------------------------
get_latest_tag() {
    local repo="$1"
    local response

    response=$(curl -fsSL --max-time 15 "${AUTH_HEADER[@]}" \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: $UA" \
        "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null) || return 1

    local tag
    if command -v jq > /dev/null 2>&1; then
        tag=$(echo "$response" | jq -r '.tag_name // empty' 2>/dev/null)
    else
        tag=$(echo "$response" | grep -oP '"tag_name":\s*"\K[^"]+' | head -1)
    fi

    [[ -n "$tag" ]] || return 1
    echo "$tag"
}

# ---------------------------------------------------------
# READ CURRENT VALUE FROM miner.conf
# ---------------------------------------------------------
# Same parsing rules as lib/00-get_rig_conf.sh: tolerates the current
# 2-column "KEY "value"" format as well as the older "KEY ALL "value""
# / "KEY 0 "value"" 3-column format, in case an old-format file is
# still in place on this rig.
get_current_version() {
    local key="$1"
    [[ -f "$MINER_CONF" ]] || { echo ""; return; }

    local file_key file_gpu rest_of_line combined value
    while read -r file_key file_gpu rest_of_line; do
        [[ -z "$file_key" || "$file_key" =~ ^# ]] && continue
        [[ "$file_key" != "$key" ]] && continue

        if [[ "$file_gpu" == \"* || -z "$rest_of_line" ]]; then
            combined="$file_gpu${rest_of_line:+ $rest_of_line}"
        else
            combined="$rest_of_line"
        fi

        value="${combined#\"}"
        value="${value%\"}"
        echo "$value"
        return
    done < "$MINER_CONF"

    echo ""
}

# ---------------------------------------------------------
# MAIN
# ---------------------------------------------------------
echo "========================================"
echo "MINER VERSION UPDATE (from GitHub releases)"
echo "========================================"
echo "$(date): miner.conf = $MINER_CONF"

declare -A NEW_VERSION
declare -A OLD_VERSION
CHANGED=0
FAILED=0

# Preserve current values for every key first, in case only a subset of
# miners is being checked this run - the rewritten miner.conf below always
# includes all 10 keys, so unselected ones must not go blank.
for key in "${KEY_ORDER[@]}"; do
    NEW_VERSION[$key]="$(get_current_version "$key")"
done

if [[ ${#SELECTED_KEYS[@]} -eq ${#KEY_ORDER[@]} ]]; then
    echo "$(date): Checking ALL miners"
else
    echo "$(date): Checking: ${SELECTED_KEYS[*]}"
fi

for key in "${SELECTED_KEYS[@]}"; do
    repo="${REPO[$key]}"
    old="${NEW_VERSION[$key]}"
    OLD_VERSION[$key]="$old"

    echo "[check] $key ($repo): current = ${old:-<unset>}"

    if ! tag="$(get_latest_tag "$repo")"; then
        echo "[check]   WARNING: could not fetch latest release for $repo - keeping current value" >&2
        NEW_VERSION[$key]="$old"
        ((FAILED++)) || true
        continue
    fi

    if should_strip_v "$key"; then
        tag="${tag#v}"
        tag="${tag#V}"
    fi

    NEW_VERSION[$key]="$tag"

    if [[ "$tag" != "$old" ]]; then
        echo "[check]   -> new version available: ${old:-<unset>} -> $tag"
        ((CHANGED++)) || true
    else
        echo "[check]   -> already up to date"
    fi
done

echo "========================================"

if [[ $FAILED -gt 0 ]]; then
    echo "$(date): WARNING - $FAILED miner(s) could not be checked (see warnings above); their existing versions were kept as-is."
fi

if [[ $CHANGED -eq 0 ]]; then
    echo "$(date): No version changes - $MINER_CONF left untouched."
    exit 0
fi

echo "$(date): Writing updated $MINER_CONF ($CHANGED version(s) changed)..."

mkdir -p /etc/rigcontrol
tee "$MINER_CONF" > /dev/null <<CONF
XMRIG_VERSION "${NEW_VERSION[XMRIG_VERSION]}"
BZMINER_VERSION "${NEW_VERSION[BZMINER_VERSION]}"
WILDRIG_VERSION "${NEW_VERSION[WILDRIG_VERSION]}"
SRBMINER_VERSION "${NEW_VERSION[SRBMINER_VERSION]}"
RIGEL_VERSION "${NEW_VERSION[RIGEL_VERSION]}"
LOLMINER_VERSION "${NEW_VERSION[LOLMINER_VERSION]}"
ONEZEROMINER_VERSION "${NEW_VERSION[ONEZEROMINER_VERSION]}"
GMINER_VERSION "${NEW_VERSION[GMINER_VERSION]}"
TEAMREDMINER_VERSION "${NEW_VERSION[TEAMREDMINER_VERSION]}"
TREXMINER_VERSION "${NEW_VERSION[TREXMINER_VERSION]}"
CONF

echo "========================================"
echo "MINER VERSIONS UPDATED"
echo "========================================"

# Service restart disabled for now - uncomment to auto-restart on version change.
# echo "$(date): Restarting services to pick up new versions..."
# sudo systemctl restart docker_events_cpu.service 2>/dev/null || echo "$(date): docker_events_cpu.service not restarted (not present/active)"
# sudo systemctl restart docker_events_gpu.service 2>/dev/null || echo "$(date): docker_events_gpu.service not restarted (not present/active)"
echo "$(date): Services NOT restarted automatically - restart docker_events_cpu/gpu manually to pick up the new version(s)."

echo "$(date): Done."
EOF

sudo chmod +x /usr/local/bin/update_miner_versions.sh

sudo /usr/local/bin/update_miner_versions.sh