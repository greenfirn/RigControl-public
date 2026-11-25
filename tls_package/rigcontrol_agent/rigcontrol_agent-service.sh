sudo tee /etc/systemd/system/rigcontrol-agent.service > /dev/null <<EOF
[Unit]
Description=RigControl MQTT Agent
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$AGENT_VENV/bin/python3 /usr/local/bin/rigcontrol_agent.py
Restart=always
RestartSec=5
User=root
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable rigcontrol-agent.service
sudo systemctl restart rigcontrol-agent.service
