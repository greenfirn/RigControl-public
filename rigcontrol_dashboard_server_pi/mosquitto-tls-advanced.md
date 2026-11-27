# Encrypted MQTT (TLS) - advanced - client certificates (mutual TLS), dashboard server (docker mosquitto), agents and server

optional extra on top of [mosquitto-tls-setup.md](mosquitto-tls-setup.md) (basic TLS). finish and test the basic setup first: broker on 8883, workers and server connected with `MQTT_TLS=1` and the CA.

basic TLS: the clients verify the broker (`ca.crt`). advanced: the broker also requires every client to present a certificate signed by your CA, on top of `BROKER_USER` / `BROKER_PASS`. one certificate per worker, plus one for the dashboard server. the agent, server and watchdog already send `MQTT_CLIENT_CERT` / `MQTT_CLIENT_KEY` when they are set. until step 8 the broker accepts the certificates but does not require them, so nothing disconnects.

1. create the certificates on the broker pi. first open the parent folder of mosquitto and write the helper script once (paste the contents of [`mosquitto-client-cert.sh`](mosquitto-client-cert.sh), it writes `mosquitto-client-cert.sh` in the current folder), then one per client:

   ```
   sudo bash mosquitto-client-cert.sh rigcontrol-dashboard
   sudo bash mosquitto-client-cert.sh BROKER_PI_HOSTNAME
   sudo bash mosquitto-client-cert.sh WORKER_NAME
   sudo bash mosquitto-client-cert.sh zigbee2mqtt
   ```

   (`BROKER_PI_HOSTNAME` = the pi's own agent, `WORKER_NAME` = each worker's hostname, repeat per worker, `zigbee2mqtt` only if you use it. output: `~/rigcontrol-server/mosquitto/config/certs/clients/<name>.crt` and `<name>.key`)

   do not `chown -R` the certs folder: `server.key` must stay readable by the broker (`sudo chown 1883:1883 server.key server.crt ca.crt`, `chmod 640 server.key`).

2. copy each worker's pair to it (the private key stays root-only on the worker)

   ```
   bash mosquitto-client-cert-copy.sh WORKER_NAME user@WORKER
   ```

   (helper script [`mosquitto-client-cert-copy.sh`](mosquitto-client-cert-copy.sh): paste it once in the same parent folder of mosquitto like step 1, run it from there)

3. the agent on the broker pi itself: install its pair locally (it also needs `ca.crt`, see [mosquitto-tls-setup.md](mosquitto-tls-setup.md)):

   ```
   cd ~/rigcontrol-server/mosquitto/config/certs
   sudo mkdir -p /etc/rigcontrol
   sudo cp ca.crt /etc/rigcontrol/ca.crt
   sudo cp clients/BROKER_PI_HOSTNAME.crt /etc/rigcontrol/client.crt
   sudo cp clients/BROKER_PI_HOSTNAME.key /etc/rigcontrol/client.key
   sudo chown root:root /etc/rigcontrol/ca.crt /etc/rigcontrol/client.*
   sudo chmod 600 /etc/rigcontrol/client.key
   ```

   `BROKER_HOST` in its conf must be the broker ip (`10.10.0.10`), not `127.0.0.1`: the server certificate only covers the ip it was made for.

4. worker config: `/etc/rigcontrol/rigcontrol-agent.conf` (the watchdog reads the same file), also on the broker pi, then restart the agent (`sudo systemctl restart rigcontrol-agent.service`)

   ```
   MQTT_CA_FILE=/etc/rigcontrol/ca.crt
   MQTT_CLIENT_CERT=/etc/rigcontrol/client.crt
   MQTT_CLIENT_KEY=/etc/rigcontrol/client.key
   ```

   windows worker: `MQTT_CA_FILE=C:\rigcontrol\ca.crt`, `MQTT_CLIENT_CERT=C:\rigcontrol\client.crt` and `MQTT_CLIENT_KEY=C:\rigcontrol\client.key` in `rigcontrol_agent.conf` (or wherever you put the files), then restart the agent

5. dashboard server: check `docker-compose.yml` has `MQTT_CLIENT_CERT=${MQTT_CLIENT_CERT:-}` and `MQTT_CLIENT_KEY=${MQTT_CLIENT_KEY:-}` under `rigcontrol-ws` and mounts the certs folder at `/mqtt-certs`, then add to `.env` and recreate the container (a plain restart does not re-read `.env`)

   ```
   MQTT_CLIENT_CERT=/mqtt-certs/clients/rigcontrol-dashboard.crt
   MQTT_CLIENT_KEY=/mqtt-certs/clients/rigcontrol-dashboard.key
   ```

   ```
   cd ~/rigcontrol-server && sudo docker compose up -d --force-recreate rigcontrol-ws
   ```

6. zigbee2mqtt / other clients (skip if you do not use them): copy `ca.crt` and the pair into its data folder and set them in `zigbee2mqtt/data/configuration.yaml`, then stop and start it (it does not like `restart`)

   ```
   sudo cp ~/rigcontrol-server/mosquitto/config/certs/ca.crt ~/rigcontrol-server/mosquitto/config/certs/clients/zigbee2mqtt.* ~/ha-docker/zigbee2mqtt/data/
   ```

   ```
   mqtt:
     server: mqtts://10.10.0.10:8883
     ca: /app/data/ca.crt
     cert: /app/data/zigbee2mqtt.crt
     key: /app/data/zigbee2mqtt.key
   ```

   home assistant / node-red MQTT settings need the same three files.

7. check every client is connected before requiring certificates: `sudo docker logs --tail 50 mosquitto` should show the dashboard, the pi agent and all workers connected, no `peer did not return a certificate` errors.

8. require the certificates

   uncomment `require_certificate true` in the 8883 listener of `mosquitto/config/mosquitto.conf`, then:

   ```
   cd ~/rigcontrol-server && sudo docker compose restart mosquitto
   sudo docker logs --tail 30 mosquitto
   ```

   clients without a certificate are now refused (`peer did not return a certificate` in the log: that client still needs step 3 to 6). to roll back remove that line and restart mosquitto.

9. keep `ca.key` on the broker only, and keep each `client.key` readable by root only (chmod 600).
