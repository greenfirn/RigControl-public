[Get started](../README.md#get-started)

website host/backend, mqtt, caddy

[docker-compose.yml](docker-compose.yml) only has the RigControl containers: mosquitto, rigcontrol-ws, caddy, duckdns. Home Assistant, node-red and zigbee2mqtt run from their own compose: [ha-docker](ha-docker/README.md). Caddy's default route still proxies to Home Assistant on `127.0.0.1:8123` (see `caddy/Caddyfile`).

[bridge-windows.conf](mosquitto/config/conf.d/bridge-windows.conf) - [mosquitto-bridge mode.txt](mosquitto-bridge%20mode.txt)
- forwards mqtt data to another mqtt broker on windows for development/testing a dashboard server on windows

# Web address (encrypted)

- LAN: `https://10.10.0.10:8081/dashboard/` (Caddy, TLS with the broker's `server.crt`; use the ip, install `mosquitto/config/certs/ca.crt` as a trusted root CA on the PC so the browser shows it as secure: windows, admin cmd: `certutil -addstore -f "Root" C:\temp\ca.crt`, then restart the browser)
- remote: `https://YOUR_DOMAIN/dashboard/` (Caddy, Let's Encrypt, basic auth)
- the api itself (`8765`) is plain http: `.env` has `API_BIND=127.0.0.1` so only Caddy can reach it. `API_PORT` must match `reverse_proxy 127.0.0.1:8765` in `caddy/Caddyfile`

# IMPORTANT 

create database files,config.json before first run: it will try and mount as a folder if files are missing
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
cd ~/rigcontrol-server/rigcontrol-ws
docker stop rigcontrol-ws
docker rm rigcontrol-ws
docker compose build rigcontrol-ws
docker compose up -d rigcontrol-ws
```
follow logs:
```
docker logs -f rigcontrol-ws
```

## Encrypted MQTT (TLS)

MQTT is encrypted (TLS) by default: the broker listens on 8883 with your own certificate. quickest start: create the server certificate and run the workers in test mode (`MQTT_TLS_INSECURE`, no file to copy to the workers), see [mosquitto-tls-setup.md](mosquitto-tls-setup.md) (then verified TLS with `ca.crt`), optionally [mosquitto-tls-advanced.md](mosquitto-tls-advanced.md) (client certificates). plain MQTT, no TLS: [mosquitto-no-tls-setup.md](mosquitto-no-tls-setup.md)
