[Get started](../README.md#get-started)

# Dashboard server (mosquitto broker, websocket, caddy, duckdns)

optional Home Assistant setup (separate docker-compose): [ha-docker](ha-docker/README.md)

## Guides

- [Initial setup ( TLS - server cert only )](#initial-setup--tls---server-cert-only-)
- [Basic TLS](#basic-tls)
- [Advanced TLS](#advanced-tls)
- [No TLS](#no-tls)
- [Web address](#web-address)
- [Update server](#update-server)
- [Bridge to a windows dashboard server](#bridge-to-a-windows-dashboard-server)

## Initial setup ( TLS - server cert only )

encrypted MQTT on port 8883 with the broker's own certificate. `10.10.0.10` below is your dashboard server ip (the broker runs on the same machine), replace it everywhere. the dashboard server and the workers connect in test mode (`MQTT_TLS_INSECURE=1`): encrypted, the broker certificate is not checked, nothing is copied to the workers. verified TLS is the next section.

1. install docker and the compose plugin on the pi (skip if `docker compose version` works):

   ```
   curl -fsSL https://get.docker.com | sudo sh
   ```

2. copy the files of this folder to `~/rigcontrol-server` on the pi (run on the pc, in the folder that contains `rigcontrol_dashboard_server_pi`):

   ```
   ssh user@PI "mkdir -p ~/rigcontrol-server"
   scp -r rigcontrol_dashboard_server_pi/. user@PI:~/rigcontrol-server/
   ```

   the `ha-docker` subfolder is not needed here, it is a separate compose.

3. create `.env` from `.env.example` and set your values: `MQTT_HOST` (the dashboard ip), `MQTT_PASS` (the broker password from step 6), `CADDY_*` and `DUCKDNS_*` (domain, email, basic-auth hash, token, see the comments in the file). the TLS defaults (`MQTT_PORT=8883`, `MQTT_TLS=true`, `MQTT_TLS_INSECURE=true`) are already set.

   ```
   cd ~/rigcontrol-server && cp .env.example .env && nano .env
   ```

4. create the database files before the first run, docker mounts a missing file as a folder:

   ```
   cd ~/rigcontrol-server/rigcontrol-ws
   touch rigcontrol_config.json rigcontrol_saved_commands.db rigcontrol_flightsheets.db rigcontrol_wallets.db rigcontrol_overclocks.db rigcontrol_watchdog_profiles.db rigcontrol_status_log.db rigcontrol_cmd_history.db
   sudo chown user:user *.db
   ```

5. create the server certificate (the broker's identity). paste this once in the parent folder of mosquitto (`~/rigcontrol-server`), it writes `mosquitto-server-cert.sh` in the current folder, then run it with the dashboard ip (details: [basic TLS guide](mosquitto-tls-setup.md)):

   ```
   sudo tee mosquitto-server-cert.sh > /dev/null <<'EOF'
   #!/bin/bash
   # TLS, see mosquitto-tls-setup.md
   # Creates the CA and the broker (server) certificate: sudo bash mosquitto-server-cert.sh <dashboard-server-ip> [more ips or hostnames]
   # run it from the parent folder of mosquitto, certificates go to ./mosquitto/config/certs
   # <dashboard-server-ip> = the dashboard server ip (the broker runs on it). Output: ca.crt ca.key server.crt server.key
   # CERT_DIR=/path/to/certs overrides the certificate folder (windows git bash: CERT_DIR=/c/mosquitto-certs bash mosquitto-server-cert.sh <ip>)
   set -e
   if [ $# -lt 1 ]; then
       echo "usage: sudo $0 <dashboard-server-ip> [more ips or hostnames]   (run from the parent folder of mosquitto)"
       exit 1
   fi
   IP="$1"
   SAN="IP:$IP"
   shift
   for A in "$@"; do
       if [[ "$A" =~ ^[0-9.]+$ ]]; then SAN="$SAN,IP:$A"; else SAN="$SAN,DNS:$A"; fi
   done
   CERT_DIR="${CERT_DIR:-$PWD/mosquitto/config/certs}"
   if [ -f "$CERT_DIR/ca.key" ] || [ -f "$CERT_DIR/server.crt" ]; then
       echo "certificates already exist in $CERT_DIR, not overwriting (workers would need the new ca.crt). remove the files first to recreate them"
       exit 1
   fi
   openssl version > /dev/null 2>&1 || (apt update && apt install -y openssl)
   mkdir -p "$CERT_DIR" && cd "$CERT_DIR"
   openssl genrsa -out ca.key 4096
   openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -subj "/CN=RigControl MQTT CA" -out ca.crt
   openssl genrsa -out server.key 2048
   openssl req -new -key server.key -subj "/CN=$IP" -out server.csr
   printf "subjectAltName=$SAN" > san.ext
   openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 825 -sha256 -extfile san.ext
   chown 1883:1883 server.key server.crt ca.crt 2>/dev/null || echo "note: chown 1883:1883 failed, run it manually on server.key server.crt ca.crt"
   chmod 640 server.key
   echo "created certificates for $SAN in $CERT_DIR (keep ca.key private, only ca.crt goes to workers)"
   EOF
   sudo chmod +x mosquitto-server-cert.sh
   ```

   ```
   cd ~/rigcontrol-server && sudo bash mosquitto-server-cert.sh 10.10.0.10
   ```

   the certificate only covers the dashboard ip, always connect by that ip (dashboard, workers, browser). keep `ca.key` on the pi.

6. create the mosquitto password file (the broker will not start without it):

   ```
   sudo docker run --rm -it -v ~/rigcontrol-server/mosquitto/config:/mosquitto/config eclipse-mosquitto:2 mosquitto_passwd -c /mosquitto/config/passwd admin
   sudo chown 1883:1883 ~/rigcontrol-server/mosquitto/config/passwd
   sudo chmod 600 ~/rigcontrol-server/mosquitto/config/passwd
   ```

7. start everything and check the broker log (expect `Opening ipv4 listen socket on port 8883`) and the dashboard log (expect `Connecting to 10.10.0.10:8883`):

   ```
   cd ~/rigcontrol-server && sudo docker compose up -d --build
   sudo docker logs --tail 20 mosquitto
   sudo docker logs rigcontrol-ws 2>&1 | grep "Mode="
   ```

8. open the [dashboard](#web-address) and connect the workers: [agent setup](../rigcontrol_agent/README.md#agent-setup--get-worker-connected-first-) (test mode is the default there too).

## Basic TLS

the dashboard server and the workers verify the broker certificate with `ca.crt`.

1. workers first: copy `ca.crt` to each worker and switch its conf to verified TLS ([agent basic TLS](../rigcontrol_agent/README.md#basic-tls))

   note: if unsure, or on a first-time setup, make the worker changes from a ssh session on the worker (not from the dashboard), a wrong setting can easily lose its connection to the dashboard.

2. dashboard server: in `~/rigcontrol-server/.env` set `MQTT_TLS_INSECURE=false` and uncomment `#MQTT_CA_FILE=/mqtt-certs/ca.crt` (docker-compose.yml already mounts the certs folder at `/mqtt-certs`), then recreate the container (a plain restart does not re-read `.env`):

   ```
   cd ~/rigcontrol-server && sudo docker compose up -d --force-recreate rigcontrol-ws
   ```

3. tests and details: [basic TLS guide](mosquitto-tls-setup.md)

## Advanced TLS

client certificates (mutual TLS): the broker only accepts clients that present a certificate signed by your CA. each worker, the agent on this pi, the dashboard server and other clients of the broker (zigbee2mqtt) need their own. full steps: [advanced TLS guide](mosquitto-tls-advanced.md)

1. create a certificate for the dashboard server and one per client (helper script [mosquitto-client-cert.sh](mosquitto-client-cert.sh), paste it once in `~/rigcontrol-server` like the server certificate script):

   ```
   sudo bash mosquitto-client-cert.sh rigcontrol-dashboard
   sudo bash mosquitto-client-cert.sh WORKER_NAME
   ```

2. dashboard server: add to `~/rigcontrol-server/.env` and recreate the container:

   ```
   MQTT_CLIENT_CERT=/mqtt-certs/clients/rigcontrol-dashboard.crt
   MQTT_CLIENT_KEY=/mqtt-certs/clients/rigcontrol-dashboard.key
   ```

   ```
   cd ~/rigcontrol-server && sudo docker compose up -d --force-recreate rigcontrol-ws
   ```

3. workers: [agent advanced TLS](../rigcontrol_agent/README.md#advanced-tls). zigbee2mqtt and other clients: [ha-docker](ha-docker/README.md)

4. when everything is connected with its certificate, uncomment `require_certificate true` in the 8883 listener of `mosquitto/config/mosquitto.conf` and restart the broker (clients without a certificate are refused, remove the line to roll back):

   ```
   cd ~/rigcontrol-server && sudo docker compose restart mosquitto
   sudo docker logs --tail 30 mosquitto
   ```

## No TLS

plain MQTT on port 1883, no certificates, only the user and password. everything is sent unencrypted, only use it on a network you trust. steps (broker listener, `.env` with `MQTT_TLS=false` and `MQTT_PORT=1883`, workers): [no TLS guide](mosquitto-no-tls-setup.md), workers: [agent no TLS](../rigcontrol_agent/README.md#no-tls)

## Web address

- LAN: `https://10.10.0.10:8081/dashboard/` (use the dashboard ip, a hostname shows a certificate warning)
- remote: `https://YOUR_DOMAIN/dashboard/` (Caddy, Let's Encrypt, basic auth, forward router ports 80 and 443 to the pi)
- everything between the browser and the pi is encrypted (https / wss through Caddy). Caddy passes requests on to the dashboard app (`8765`) inside the pi (`127.0.0.1`, set by `API_BIND=127.0.0.1` in `.env`), so nothing travels unencrypted on the network. `API_PORT` must match `reverse_proxy 127.0.0.1:8765` in `caddy/Caddyfile`. keep `API_BIND=127.0.0.1`, `0.0.0.0` would also open that port on the LAN as plain http

the LAN address is encrypted either way, the browser only shows "not secure" because it does not know your CA. to remove the warning (and let the browser verify it is your server) install the broker's `ca.crt` (public) as a trusted root CA for any browser accessing the dashboard (windows commands below, chrome and edge use the windows certificate store). run in cmd on the pc (copies the file from the pi, adds it for your user only, no admin needed, then deletes the file: windows keeps its own copy in the certificate store), then restart the browser:

```
scp user@10.10.0.10:~/rigcontrol-server/mosquitto/config/certs/ca.crt %USERPROFILE%\ca.crt
certutil -user -addstore Root %USERPROFILE%\ca.crt
certutil -user -store Root | findstr /i "RigControl"
del %USERPROFILE%\ca.crt
```

the `findstr` line should print `RigControl MQTT CA` (imported ok). to check the file is yours before importing compare `certutil -hashfile %USERPROFILE%\ca.crt SHA256` with `openssl x509 -in ~/rigcontrol-server/mosquitto/config/certs/ca.crt -noout -fingerprint -sha256` on the pi. for all users on the pc use an administrator cmd and `certutil -addstore -f "Root"` instead of the `-user` one.

(firefox has its own store: Settings, Privacy & Security, Certificates, View Certificates, Authorities, Import)

## Update server

run docker compose from `~/rigcontrol-server`, not from `rigcontrol-ws` (inside that folder it reads the wrong `.env`):

```
cd ~/rigcontrol-server
docker stop rigcontrol-ws
docker rm rigcontrol-ws
docker compose build rigcontrol-ws
docker compose up -d rigcontrol-ws
```

follow logs:

```
docker logs -f rigcontrol-ws
```

## Bridge to a windows dashboard server

[bridge-windows.conf](mosquitto/config/conf.d/bridge-windows.conf) - [mosquitto-bridge mode.txt](mosquitto-bridge%20mode.txt)

- forwards mqtt data to another mqtt broker on windows for development/testing a dashboard server on windows
