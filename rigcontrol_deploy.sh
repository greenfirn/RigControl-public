#!/bin/bash
# Installs the staged files from /home/user/ into rigcontrol-ws/ and
# rebuilds + restarts the container. Run on the Pi (via ssh from
# update-pi.bat, or by hand) after scp'ing the new files to /home/user/.
set -e

sudo rm -fv /home/user/ha-docker/rigcontrol-ws/rigcloud_dashboard_server.py
#sudo cp -v /home/user/Dockerfile /home/user/ha-docker/rigcontrol-ws/
sudo cp -v /home/user/rigcontrol_dashboard_server.py /home/user/ha-docker/rigcontrol-ws/
sudo cp -v /home/user/index.html /home/user/ha-docker/rigcontrol-ws/static/
sudo cp -v /home/user/landing.html /home/user/ha-docker/rigcontrol-ws/static/
sudo cp -v /home/user/app.js /home/user/ha-docker/rigcontrol-ws/static/js/
sudo cp -v /home/user/app.css /home/user/ha-docker/rigcontrol-ws/static/css/

cd /home/user/ha-docker/rigcontrol-ws
docker stop rigcontrol-ws
docker rm rigcontrol-ws
docker compose build --no-cache rigcontrol-ws
docker compose up -d rigcontrol-ws

echo ""
echo "==== Done. ===="

#sudo tee /home/user/rigcontrol_deploy.sh > /dev/null <<'EOF'
#EOF
#sudo chmod +x /home/user/rigcontrol_deploy.sh
#sudo /home/user/rigcontrol_deploy.sh
