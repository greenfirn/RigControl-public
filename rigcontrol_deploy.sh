#!/bin/bash
# Installs the staged files from /home/user/ into rigcontrol-ws/ and
# rebuilds + restarts the container. Run on the Pi (via ssh from
# update-pi.bat, or by hand) after scp'ing the new files to /home/user/.
set -e

sudo rm -fv /home/user/rigcontrol-server/rigcontrol-ws/rigcloud_dashboard_server.py
sudo cp -v /home/user/rigcontrol_dashboard_server.py /home/user/rigcontrol-server/rigcontrol-ws/
sudo cp -v /home/user/index.html /home/user/rigcontrol-server/rigcontrol-ws/static/
sudo cp -v /home/user/landing.html /home/user/rigcontrol-server/rigcontrol-ws/static/
sudo cp -v /home/user/app.js /home/user/rigcontrol-server/rigcontrol-ws/static/js/
sudo cp -v /home/user/app.css /home/user/rigcontrol-server/rigcontrol-ws/static/css/

cd /home/user/rigcontrol-server
docker stop rigcontrol-ws
docker rm rigcontrol-ws
docker compose build --no-cache rigcontrol-ws
docker compose up -d rigcontrol-ws

echo ""
echo "==== Done. ===="
