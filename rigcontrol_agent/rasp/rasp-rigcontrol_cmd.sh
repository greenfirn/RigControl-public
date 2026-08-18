sudo tee /usr/local/bin/rigcontrol_cmd.sh > /dev/null <<'EOF'
#!/bin/bash
set -e
LOG="/var/lib/rigcontrol/rigcontrol_cmd.log"
# Read entire command from STDIN (multi-line safe)
RAW_CMD="$(cat)"
if [[ -z "$RAW_CMD" ]]; then
    echo "No command received"
    exit 1
fi
echo "==================================================" >> "$LOG"
echo "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"
echo "$RAW_CMD" >> "$LOG"
# Parse first line for structured commands
FIRST_LINE="$(echo "$RAW_CMD" | head -n1)"
CMD="$(echo "$FIRST_LINE" | awk '{print $1}')"
case "$CMD" in
    # SYSTEM REBOOT
    reboot)
        echo "Rebooting system..."
        systemctl reboot
        ;;
    # RAW MULTI-LINE SHELL COMMAND (DEFAULT)
    *)
        echo "[RAW EXECUTION]"
        bash -c "$RAW_CMD"
        ;;
esac
EOF
sudo chmod +x /usr/local/bin/rigcontrol_cmd.sh
