@echo off
REM Pushes the dashboard server + static files 
REM + deploy "%REPO%\rigcontrol_deploy.sh"
REM + Dockerfile "%REPO%\rigcontrol_dashboard_server_pi\rigcontrol-ws\Dockerfile"
REM script from the RigControl repo working tree to the Pi, then runs
REM the deploy script remotely to install + rebuild.

set REPO=C:\Users\%USERNAME%\Documents\GitHub\RigControl
set PI=user@10.10.0.10

echo ==== Copying to Pi staging (/home/user/) - one password prompt ====
scp "%REPO%\rigcontrol_dashboard_server_pi\rigcontrol-ws\rigcontrol_dashboard_server.py" "%REPO%\static\index.html" "%REPO%\static\landing.html" "%REPO%\static\css\app.css" "%REPO%\static\js\app.js" %PI%:/home/user/

echo.
echo ==== Running deploy script on Pi - one password prompt ====
ssh %PI% "bash /home/user/rigcontrol_deploy.sh"

echo.
echo ==== Tailing logs - Ctrl+C to exit ====
ssh %PI% "docker logs -f rigcontrol-ws"

pause

REM ==== Optional: only run these by hand when you've actually changed
REM      one of these infra files, NOT every routine push - they touch
REM      containers other than rigcontrol-ws (caddy, mosquitto) that are
REM      also running on this same Pi. ====

REM -- docker-compose.yml --
REM scp "%REPO%\rigcontrol_dashboard_server_pi\docker-compose.yml" %PI%:/home/user/ha-docker/
REM ssh %PI% "cd /home/user/ha-docker && docker compose up -d"

REM -- Caddyfile --
REM scp "%REPO%\rigcontrol_dashboard_server_pi\caddy\Caddyfile" %PI%:/home/user/ha-docker/caddy/
REM ssh %PI% "docker compose -f /home/user/ha-docker/docker-compose.yml restart caddy"

REM -- mosquitto bridge conf --
REM scp "%REPO%\rigcontrol_dashboard_server_pi\mosquitto\bridge-windows.conf" %PI%:/home/user/ha-docker/mosquitto/config/conf.d/
REM ssh %PI% "docker compose -f /home/user/ha-docker/docker-compose.yml restart mosquitto"

REM -- themes --
REM scp -r "%REPO%\rigcontrol_dashboard_server_pi\rigcontrol-ws\themes\*" %PI%:/home/user/ha-docker/rigcontrol-ws/themes/
