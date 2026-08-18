# --- write fan-curve.service ---

sudo tee /etc/systemd/system/fan-curve.service > /dev/null << 'EOF'
[Unit]
Description=NVIDIA Fan Curve Controller (NVML, no Xorg/Coolbits required)
After=multi-user.target nvidia-persistenced.service
Wants=nvidia-persistenced.service

StartLimitIntervalSec=0

[Service]
Type=notify
NotifyAccess=main
User=root
Environment=PYTHONUNBUFFERED=1

# If nvmlInit() or anything before the first READY=1 hangs at boot,
# systemd kills the unit after this long and Restart=always retries.
TimeoutStartSec=30

# Loop pings systemd once per full pass over all GPUs (roughly once per
# --interval). Set this comfortably above --interval + worst-case cooldown
# stall so normal ticks never trip it, but a genuinely hung NVML call
# (e.g. GSP firmware wedge) gets caught quickly.
WatchdogSec=15

# On watchdog timeout, send SIGTERM (not the systemd default SIGABRT) so
# fan_curve.py's existing signal handler runs and resets fans to AUTO
# before the process is killed, instead of an abrupt abort leaving fans
# pinned at their last commanded speed.
WatchdogSignal=SIGTERM

# Give persistence/driver a moment to settle at boot
ExecStartPre=/bin/bash -c 'sleep 3'

# Per-rig curve lives here — edit this line for each machine, then:
#   sudo systemctl daemon-reload && sudo systemctl restart fan-curve.service
ExecStart=/usr/bin/python3 /usr/local/bin/fan_curve.py \
    --interval 2 --hysteresis 2 \
    --cooldown-delta 10 --cooldown-seconds 15 \
    --curve "30:30,40:45,50:65,55:90,65:100"

# fan_curve.py resets fans to AUTO on SIGTERM before exiting, so no
# separate ExecStop/fan-reset.sh script is needed. With WatchdogSignal=SIGTERM
# above, this same clean-exit path also runs on a watchdog timeout.
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

#========================================================================================================
#========================================================================================================

# let systemd know about the new/changed service
sudo systemctl daemon-reload
sudo systemctl restart fan-curve.service

# show status — should show "Status: Controlling N GPU(s)" once ready
sleep 2
sudo systemctl status fan-curve.service

# watch the live log
journalctl -u fan-curve.service -f

# stop / restart as needed
# sudo systemctl stop fan-curve.service
# sudo systemctl restart fan-curve.service
