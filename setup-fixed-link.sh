sudo tee /home/user/setup-fixed-link.sh > /dev/null <<'EOF'
#!/usr/bin/env bash
# setup-fixed-link.sh
# Detects the first physical LAN adapter (name + MAC) and writes
# /etc/systemd/network/10-fixed.link to pin that name permanently.

set -euo pipefail

ADAPTER=""
MAC=""

for iface in /sys/class/net/*; do
    name=$(basename "$iface")

    [[ "$name" == "lo" ]]       && continue
    [[ -d "$iface/bridge" ]]    && continue
    [[ -d "$iface/bonding" ]]   && continue
    [[ -L "$iface/device" ]] || continue

    type_file="$iface/type"
    [[ -f "$type_file" ]] || continue
    [[ "$(cat "$type_file")" == "1" ]] || continue

    [[ -d "$iface/wireless" ]] && continue

    mac_file="$iface/address"
    [[ -f "$mac_file" ]] || continue
    mac=$(cat "$mac_file")

    [[ "$mac" == "00:00:00:00:00:00" ]] && continue
    [[ -z "$mac" ]] && continue

    ADAPTER="$name"
    MAC="$mac"
    break
done

if [[ -z "$ADAPTER" ]]; then
    echo "ERROR: No physical Ethernet adapter found." >&2
    exit 1
fi

echo "Detected adapter : $ADAPTER"
echo "Detected MAC     : $MAC"

LINK_FILE="/etc/systemd/network/10-fixed.link"

sudo tee "$LINK_FILE" > /dev/null <<INNEREOF
[Match]
MACAddress=${MAC}

[Link]
Name=${ADAPTER}
INNEREOF

echo ""
echo "Written: $LINK_FILE"
echo "---"
cat "$LINK_FILE"
echo "---"

if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    sudo systemctl restart systemd-networkd
    echo "systemd-networkd restarted."
fi

echo ""
echo "Done. The adapter will be named '${ADAPTER}' after next reboot"
echo "(or run: sudo udevadm trigger --action=add)"
EOF

sudo chmod +x /home/user/setup-fixed-link.sh
echo "Script written to setup-fixed-link.sh — run it with: sudo ./setup-fixed-link.sh"
#sudo /home/user/setup-fixed-link.sh