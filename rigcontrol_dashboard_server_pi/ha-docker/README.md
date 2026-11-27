Separate docker-compose for the non-RigControl containers: homeassistant, nodered, zigbee2mqtt. Copy this folder to `~/ha-docker` on the Pi. The RigControl containers (mosquitto, rigcontrol-ws, caddy, duckdns) run from `~/rigcontrol-server` ([docker-compose.yml](../docker-compose.yml)).

```
cp .env.example .env
```

set the real dongle path in `docker-compose.yml` (replace `CHANGE_ME`, from `ls /dev/serial/by-id/`), then:

```
sudo docker compose up -d
```

zigbee2mqtt uses the broker in `rigcontrol-server`. In `zigbee2mqtt/data/configuration.yaml`:

```
mqtt:
  server: mqtts://10.10.0.10:8883
  user: admin
  password: YOUR_PASSWORD
  ca: /app/data/ca.crt
```

`ca.crt` = `~/rigcontrol-server/mosquitto/config/certs/ca.crt` copied to `~/ha-docker/zigbee2mqtt/data/ca.crt` (or use `reject_unauthorized: false` instead of `ca:` for test mode). zigbee2mqtt needs stop then start, not restart:

```
sudo docker stop zigbee2mqtt && sudo docker start zigbee2mqtt
```
