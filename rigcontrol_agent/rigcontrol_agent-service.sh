AGENT_VENV="/usr/local/lib/rigcontrol-agent/.venv"
if [ ! -x "$AGENT_VENV/bin/pip" ]; then
    echo "Creating rigcontrol-agent virtual environment at $AGENT_VENV ..."
    sudo mkdir -p "$(dirname "$AGENT_VENV")"
    sudo apt-get update
    sudo apt-get install -y python3-venv
    sudo python3 -m venv --clear "$AGENT_VENV"
    if [ ! -x "$AGENT_VENV/bin/pip" ]; then
        echo "ERROR: $AGENT_VENV/bin/pip still doesn't exist after venv creation - see any ensurepip/apt-get error above. Not starting the agent under a broken interpreter; fix the venv (apt-get install python3-venv) and re-run this script."
        exit 1
    fi
    sudo "$AGENT_VENV/bin/pip" install --upgrade pip
    sudo "$AGENT_VENV/bin/pip" install aiomqtt typing_extensions paho-mqtt requests
    echo "Virtual environment created and dependencies installed."
else
    echo "rigcontrol-agent virtual environment already exists at $AGENT_VENV - skipping dependency install."
fi
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
