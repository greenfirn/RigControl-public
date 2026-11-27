[Get started](../README.md#get-started)

website host/backend, mqtt, caddy

[docker-compose.yml](docker-compose.yml) only has the RigControl containers: mosquitto, rigcontrol-ws, caddy, duckdns. Home Assistant, node-red and zigbee2mqtt run from their own compose: [ha-docker](ha-docker/README.md). Caddy's default route still proxies to Home Assistant on `127.0.0.1:8123` (see `caddy/Caddyfile`).

[bridge-windows.conf](mosquitto/config/conf.d/bridge-windows.conf) - [mosquitto-bridge mode.txt](mosquitto-bridge%20mode.txt)
- forwards mqtt data to another mqtt broker on windows for development/testing a dashboard server on windows

# Web address (encrypted)

- LAN: `https://10.10.0.10:8081/dashboard/` (Caddy, TLS with the broker's `server.crt`, use the ip)
- remote: `https://YOUR_DOMAIN/dashboard/` (Caddy, Let's Encrypt, basic auth)
- the api itself (`8765`) is plain http: `.env` has `API_BIND=127.0.0.1` so only Caddy can reach it. `API_PORT` must match `reverse_proxy 127.0.0.1:8765` in `caddy/Caddyfile`

for the browser to show the LAN address as secure, install the broker's `ca.crt` (public) as a trusted root CA on each windows pc. run in cmd on the pc (copies the file from the pi, adds it for your user only, no admin needed, then deletes the file: windows keeps its own copy in the certificate store), then restart the browser:

```
scp user@10.10.0.10:~/rigcontrol-server/mosquitto/config/certs/ca.crt %USERPROFILE%\ca.crt
certutil -user -addstore Root %USERPROFILE%\ca.crt
certutil -user -store Root | findstr /i "RigControl"
del %USERPROFILE%\ca.crt
```

the `findstr` line should print `RigControl MQTT CA` (imported ok). to check the file is yours before importing compare `certutil -hashfile %USERPROFILE%\ca.crt SHA256` with `openssl x509 -in ~/rigcontrol-server/mosquitto/config/certs/ca.crt -noout -fingerprint -sha256` on the pi. for all users on the pc use an administrator cmd and `certutil -addstore -f "Root"` instead of the `-user` one.

(firefox has its own store: Settings, Privacy & Security, Certificates, View Certificates, Authorities, Import)

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
