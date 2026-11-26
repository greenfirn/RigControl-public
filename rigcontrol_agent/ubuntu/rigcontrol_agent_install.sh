#!/bin/bash
set -e
cd "$(dirname "$0")"
sudo mkdir -p /etc/rigcontrol /var/lib/rigcontrol /run/rigcontrol
echo "== rigcontrol-agent-local.sh (writes /etc/rigcontrol/rigcontrol-agent.conf) =="
bash rigcontrol-agent-local.sh
echo "== rigcontrol_cmd.sh (writes /usr/local/bin/rigcontrol_cmd.sh) =="
bash rigcontrol_cmd.sh
echo "== rigcontrol_telemetry.sh (writes /usr/local/bin/rigcontrol_telemetry.py) =="
bash rigcontrol_telemetry.sh
echo "== rigcontrol_agent.sh (writes /usr/local/bin/rigcontrol_agent.py) =="
bash rigcontrol_agent.sh
echo "== rigcontrol_agent-service.sh (venv + systemd service - LAST) =="
bash rigcontrol_agent-service.sh
echo "== Verifying service status =="
sudo systemctl is-active rigcontrol-agent.service && echo "rigcontrol-agent.service is active" || echo "WARNING: rigcontrol-agent.service is NOT active - check 'sudo systemctl status rigcontrol-agent.service' on this rig"
