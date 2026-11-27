# Plain MQTT (no TLS) - dashboard server (docker mosquitto), agents and server

this is the optional plain setup: port 1883, no certificates, only the `BROKER_USER` / `BROKER_PASS` login. the default is encrypted (see [mosquitto-tls-setup.md](mosquitto-tls-setup.md)). user, password and all telemetry are sent unencrypted, so only use it on a network you trust.

1. broker config: replace `~/ha-docker/mosquitto/config/mosquitto.conf` (the one in the repo has the TLS listener) with:

   ```
   sudo tee ~/ha-docker/mosquitto/config/mosquitto.conf > /dev/null <<'EOF'
   persistence false
   persistence_location /mosquitto/data/

   log_dest stdout

   listener 1883
   allow_anonymous false
   password_file /mosquitto/config/passwd
   include_dir /mosquitto/config/conf.d
   EOF
   ```

   if a conf.d/`tls.conf` exists from an earlier TLS setup, remove or rename it (it would also open 8883).

2. password file (skip if `~/ha-docker/mosquitto/config/passwd` already exists)

   ```
   sudo docker run --rm -it -v ~/ha-docker/mosquitto/config:/mosquitto/config eclipse-mosquitto:2 mosquitto_passwd -c /mosquitto/config/passwd admin
   sudo chown 1883:1883 ~/ha-docker/mosquitto/config/passwd
   sudo chmod 600 ~/ha-docker/mosquitto/config/passwd
   ```

3. start / restart the broker

   ```
   cd ~/ha-docker && sudo docker compose up -d --force-recreate mosquitto
   ```

4. test the broker

   ```
   sudo docker logs mosquitto --tail 20
   nc -vz 10.10.0.10 1883
   sudo docker exec mosquitto mosquitto_sub -h 127.0.0.1 -p 1883 -u admin -P YOUR_PASSWORD -t 'rigcontrol/#' -C 1 -W 5
   ```

   (the last one waits up to 5 seconds for a message from a worker)

5. dashboard server `.env` (`docker-compose.yml` turns TLS on by default, so `MQTT_TLS=false` must be set), then recreate the container

   ```
   MQTT_MODE=pi
   MQTT_HOST=10.10.0.10
   MQTT_PORT=1883
   MQTT_TLS=false
   MQTT_USER=admin
   MQTT_PASS=YOUR_PASSWORD
   ```

   ```
   cd ~/ha-docker && sudo docker compose up -d --force-recreate rigcontrol-ws
   sudo docker logs rigcontrol-ws 2>&1 | grep "Mode="
   ```

   (expect `Mode=pi Connecting to 10.10.0.10:1883`)

6. each worker: the install scripts default to TLS, so in the conf block of `rigcontrol-agent-local.sh` set

   ```
   BROKER_HOST=10.10.0.10
   BROKER_PORT=1883
   BROKER_USER=admin
   BROKER_PASS=YOUR_PASSWORD
   MQTT_TLS=0
   ```

   (`MQTT_TLS_INSECURE` is ignored without TLS, no `ca.crt` needed). regenerate `copy-paste-update.sh` and run it on the worker as a file
   (scp + bash, do not paste it into the terminal). the watchdog reads the same conf. windows worker: the same keys in `C:\rigcontrol\rigcontrol_agent.conf`.

   the agent log should show `[Config] Broker = 10.10.0.10:1883` and no `[Config] MQTT TLS = ON` line.

7. firewall (only if ufw is on)

   ```
   sudo ufw allow 1883/tcp
   ```

8. later switch to encrypted MQTT: see [mosquitto-tls-setup.md](mosquitto-tls-setup.md) (the broker can keep 1883 open while workers move over).
