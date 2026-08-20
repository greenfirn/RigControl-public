[Get started](https://github.com/greenfirn/RigControl#get-started)

website host/backend, mqtt, caddy

docker-compose.yml: note needed extras
- homeassistant:
- nodered:
- zigbee2mqtt:

/mosquitto/config/conf.d/bridge-windows.conf - [mosquitto-bridge mode](mosquitto-bridge mode.txt)
- forwards mqtt data to another mqtt broker on windows for development/testing a dashboard server on windows

# IMPORTANT 

create database files,config.json before first run:
```
touch rigcontrol_config.json
touch rigcontrol_flightsheets.db
touch rigcontrol_wallets.db
touch rigcontrol_overclocks.db
touch rigcontrol_watchdog_profiles.db
touch rigcontrol_status_log.db
```
set owner if needed:
```
sudo chown user:user *.db
```
to update server:
```
cd ~/ha-docker/rigcontrol-ws
docker stop rigcontrol-ws
docker rm rigcontrol-ws
docker compose build rigcontrol-ws
docker compose up -d rigcontrol-ws
```
follow logs:
```
docker logs -f rigcontrol-ws
```
