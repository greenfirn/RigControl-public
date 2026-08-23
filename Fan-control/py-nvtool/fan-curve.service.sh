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

# seconds to wait for startup (READY=1) before systemd kills and restarts the unit
TimeoutStartSec=30

# seconds between required watchdog pings; should stay above --interval + worst-case cooldown
WatchdogSec=15

# send SIGTERM on watchdog timeout so fan_curve.py resets fans to AUTO before exiting
WatchdogSignal=SIGTERM

ExecStartPre=/bin/bash -c 'sleep 3'

# per-rig curve — edit this line for each machine, then:
#   sudo systemctl daemon-reload && sudo systemctl restart fan-curve.service
ExecStart=/usr/bin/python3 /usr/local/bin/fan_curve.py \
    --interval 2 --hysteresis 2 \
    --cooldown-delta 10 --cooldown-seconds 15 \
    --curve "30:30,40:45,50:65,55:90,65:100"

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

#========================================================================================================
#========================================================================================================

sudo systemctl daemon-reload
sudo systemctl restart fan-curve.service

# should show "Status: Controlling N GPU(s)" once ready
sleep 2
sudo systemctl status fan-curve.service

journalctl -u fan-curve.service -f

# stop / restart as needed
# sudo systemctl stop fan-curve.service
# sudo systemctl restart fan-curve.service
