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
FIRST_LINE="$(echo "$RAW_CMD" | head -n1)"
CMD="$(echo "$FIRST_LINE" | awk '{print $1}')"
case "$CMD" in
    reboot)
        echo "Rebooting system..."
        systemctl reboot
        ;;
    *)
        echo "[RAW EXECUTION]"
        # Delivered via stdin (here-string), NOT as `bash -c "$RAW_CMD"` - passing the whole
        # command as a single argv string hits the kernel's per-argument MAX_ARG_STRLEN cap
        # (128 KB on x86_64) regardless of total ARG_MAX headroom, which a large pasted
        # command (e.g. an entire source file) blows straight through, failing with
        # "Argument list too long" (exit 126) before a single line of it ever runs. A
        # here-string has no such size limit since it's just a pipe/temp-file under the hood.
        bash <<< "$RAW_CMD"
        ;;
esac
EOF
sudo chmod +x /usr/local/bin/rigcontrol_cmd.sh
