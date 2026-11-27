# RigControl: upgrade an existing install to encrypted MQTT (TLS)

TLS is now the default in this version (port 8883, `MQTT_TLS` on, certificate verified against your CA). **New installs** just follow `mosquitto-tls-setup.md` in the server folder. **This guide is for moving a running install** (workers on plain 1883) to TLS without losing connection, so the steps below keep 1883 open until the end.

Do not replace your running `mosquitto/config/mosquitto.conf` with the new one from this package until step 4: the new file has only the TLS listener (no 1883) and would disconnect every worker still on plain MQTT.

Broker IP used below: `10.10.0.10`. Plain MQTT on 1883 keeps working until you remove it, so workers can be moved over one at a time without losing connection.

Order: **1. Broker (Pi)** -> **2. Workers** -> **3. Dashboard server (last)** -> **4. Lock down**.

Workers and the dashboard server are separate clients of the same broker. Restarting the server does not disconnect workers. Never switch a worker to 8883 before step 1 is done, or it has no TLS listener to connect to.

---

## 1. Broker (Pi)

### 1.0 Install openssl (skip if `openssl version` already works)

```
openssl version || (sudo apt update && sudo apt install -y openssl)
```

### 1.1 Create the certificates

```
sudo mkdir -p ~/ha-docker/mosquitto/config/certs && cd ~/ha-docker/mosquitto/config/certs
sudo openssl genrsa -out ca.key 4096
sudo openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -subj "/CN=RigControl MQTT CA" -out ca.crt
sudo openssl genrsa -out server.key 2048
sudo openssl req -new -key server.key -subj "/CN=10.10.0.10" -out server.csr
printf "subjectAltName=IP:10.10.0.10" | sudo tee san.ext > /dev/null
sudo openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 825 -sha256 -extfile san.ext
sudo chown 1883:1883 server.key server.crt ca.crt
sudo chmod 640 server.key
```

If workers connect by hostname instead of IP, use `printf "subjectAltName=IP:10.10.0.10,DNS:yourhost"`.

Keep `ca.key` private. Only `ca.crt` is copied to workers.

### 1.2 Enable the TLS listener (port 8883)

Create `~/ha-docker/mosquitto/config/conf.d/tls.conf` (your existing `mosquitto.conf` already includes that folder, keeps its 1883 listener, and its `allow_anonymous false` / `password_file` settings apply to the new listener too):

```
sudo tee ~/ha-docker/mosquitto/config/conf.d/tls.conf > /dev/null <<'EOF'
listener 8883
protocol mqtt
cafile /mosquitto/config/certs/ca.crt
certfile /mosquitto/config/certs/server.crt
keyfile /mosquitto/config/certs/server.key
tls_version tlsv1.2
EOF
```

### 1.3 Restart the broker

```
cd ~/ha-docker && sudo docker compose restart mosquitto
```

Plain 1883 stays open, so all workers and the server reconnect on their old settings within seconds. Compose warnings about `SMTP_SERVER` / `SMTP_PORT` not set are harmless.

### 1.4 Test the broker (2 checks, run on the Pi)

Check 1: the broker serves its certificate on 8883 (no CA given, so a self-signed warning is expected):

```
openssl s_client -connect 10.10.0.10:8883 </dev/null | head -5
```

Expected: `depth=0 CN = 10.10.0.10`, certificate chain with issuer `CN = RigControl MQTT CA`, and `verify error:num=19:self-signed certificate in certificate chain`. The `Can't use SSL_get_servername` line is harmless. If you get `Connection refused` or no certificate, check `sudo docker logs mosquitto --tail 30`.

Check 2: the certificate chain verifies against your CA:

```
openssl s_client -connect 10.10.0.10:8883 -CAfile ~/ha-docker/mosquitto/config/certs/ca.crt </dev/null | grep -i "verify return\|Verify return code"
```

Expected: every `verify return:1` and `Verify return code: 0 (ok)`.

Both checks pass -> the broker is ready. Move on to the workers.

---

## 2. Workers

Do one worker first, then the rest. Each worker is offline only while its agent restarts.

### 2.0 Update the worker files first (required)

TLS support is in the new agent code, not just the conf. Files that changed on the worker:

- `/usr/local/bin/rigcontrol_agent.py` (new TLS connection code; this is the one that matters)
- `/usr/local/bin/rigcontrol_telemetry.py`
- `/usr/local/bin/rigcontrol_cmd.sh`
- `/etc/rigcontrol/rigcontrol-agent.conf` (rewritten with the TLS keys)
- `/etc/systemd/system/rigcontrol-agent.service`

`copy-paste-update.sh` writes all of them, with TLS on by default (port 8883, `MQTT_TLS=1`, `MQTT_CA_FILE=/etc/rigcontrol/ca.crt`). Source files: `rigcontrol-agent-local.sh` (or `-keryxd`), `rigcontrol_telemetry.sh`, `rigcontrol_cmd.sh`, `rigcontrol_agent.sh`, `rigcontrol_agent-service.sh`. Rebuild with `generate-copy-paste-update.bat` (the package already contains a rebuilt copy). The scripts never write or overwrite `/etc/rigcontrol/ca.crt`: install the CA once per worker (2.3), they only print a warning if it is missing. For quick mode (no CA file) set `MQTT_TLS_INSECURE=1` in the conf block before running it.

1. Edit the conf block at the top of the script: set your real `BROKER_USER` / `BROKER_PASS` (the script rewrites the conf).
2. **Copy the script to the worker as a file and run it. Do not paste it into the terminal.** It is about 4,000 lines, and a terminal paste can drop or corrupt lines, leaving a `SyntaxError` / `IndentationError` in `rigcontrol_agent.py` or `rigcontrol_telemetry.py` and the agent crash-looping.

```
scp copy-paste-update.sh user@WORKER:~/
ssh user@WORKER "bash ~/copy-paste-update.sh"
```

(On Windows use WinSCP or similar to upload, then `bash copy-paste-update.sh` in the SSH session.)

3. Check the new agent is installed:

```
grep -c "TLSParameters" /usr/local/bin/rigcontrol_agent.py
```

`0` means the old agent is still there. An old agent ignores `MQTT_TLS=1` and sends plain MQTT to port 8883, which the broker resets (log: `failed to receive on socket: [Errno 104] Connection reset by peer`, `MQTT error: Operation timed out`).

To recover a worker stuck this way: set `BROKER_PORT=1883` and `MQTT_TLS=0` in `/etc/rigcontrol/rigcontrol-agent.conf` and restart the agent.

Once a worker has the new agent, later TLS conf changes (quick to verified mode, port) only need the conf edit and an Agent Restart.

### 2.1 Choose the mode

- **Quick (no CA file, certificate not verified):** set `MQTT_TLS_INSECURE=1`. Traffic is encrypted but the broker is not verified. Testing only.
- **Verified:** copy `ca.crt` to the worker and set `MQTT_CA_FILE`. See 2.3.

### 2.2 Linux workers, quick mode

If you did not use the new `copy-paste-update.sh` (it already sets these), then on a worker that already has the new agent (2.0) open Settings > Configs, select only the test worker, and set these keys:

```
BROKER_HOST=10.10.0.10
BROKER_PORT=8883
MQTT_TLS=1
MQTT_TLS_INSECURE=1
```

Press **Agent Restart** (or run `sudo systemctl restart rigcontrol-agent.service` on the worker).

Do not re-run `copy-paste-update.sh` afterwards without editing it first: it rewrites the conf from the conf block inside the script, so keep your `BROKER_HOST`, `BROKER_USER`, `BROKER_PASS` and the TLS keys there.

### 2.3 Linux workers, verified mode

**Install the CA once per worker:** copy the broker's `ca.crt` to `/etc/rigcontrol/ca.crt` (the install scripts never write or overwrite it).

Then in `/etc/rigcontrol/rigcontrol-agent.conf` (or the dashboard conf editor):

```
BROKER_HOST=10.10.0.10
BROKER_PORT=8883
MQTT_TLS=1
MQTT_CA_FILE=/etc/rigcontrol/ca.crt
```

Restart the agent (Agent Restart, or `sudo systemctl restart rigcontrol-agent.service`).

### 2.4 Windows workers

The Windows agent needs the new `rigcontrol_agent_win.py` and `rigcontrol_telemetry.py` from the package first (same reason as 2.0: an old agent ignores the TLS keys). The conf is `C:\rigcontrol\rigcontrol_agent.conf`.

**Quick mode (no CA file, certificate not verified):**

```
BROKER_HOST=10.10.0.10
BROKER_PORT=8883
MQTT_TLS=1
MQTT_TLS_INSECURE=1
```

**Verified mode:** copy `ca.crt` to the worker (e.g. `C:\rigcontrol\ca.crt`) and use:

```
BROKER_HOST=10.10.0.10
BROKER_PORT=8883
MQTT_TLS=1
MQTT_CA_FILE=C:\rigcontrol\ca.crt
```

Restart the Windows agent. Its log should show `[Config] MQTT TLS = ON (...)` and `Connecting to MQTT broker at 10.10.0.10:8883`.

### 2.5 Watchdog

The watchdog publishes its alerts to the broker and reads the same `/etc/rigcontrol/rigcontrol-agent.conf` as the agent. So a worker that already has the TLS keys (2.2 / 2.3) needs no separate watchdog settings. It only needs the new `watchdog/rigcontrol_watchdog.py` / `rigcontrol_watchdog.sh` from the package (they contain the TLS code), then a restart of the watchdog service. An old watchdog ignores the TLS keys and its alerts fail to publish once plain 1883 is removed.

**Quick mode (no CA file, certificate not verified):**

```
BROKER_HOST=10.10.0.10
BROKER_PORT=8883
MQTT_TLS=1
MQTT_TLS_INSECURE=1
```

**Verified mode:**

```
BROKER_HOST=10.10.0.10
BROKER_PORT=8883
MQTT_TLS=1
MQTT_CA_FILE=/etc/rigcontrol/ca.crt
```

If the watchdog fails to publish, its log shows `[mqtt] Error publishing alert: ...`.

### 2.6 Test a worker (2 checks, then repeat for the rest)

Check A, agent log (on the worker): the broker line must show port 8883.

```
sudo journalctl -u rigcontrol-agent.service -n 100 --no-pager | grep -i "broker\|mqtt"
```

Expected: `[Config] Broker = 10.10.0.10:8883` and `Connecting to MQTT 10.10.0.10:8883` with no TLS errors.

Check B, dashboard: the worker shows online again within a few seconds and telemetry is updating.

Verified mode only, optional certificate check from the worker:

```
openssl s_client -connect 10.10.0.10:8883 -CAfile /etc/rigcontrol/ca.crt </dev/null | grep -i "verify return\|Verify return code"
```

Both checks pass -> repeat for the remaining workers. If a worker stays offline: SSH in and run `sudo systemctl restart rigcontrol-agent.service`. To roll back set `BROKER_PORT=1883`, `MQTT_TLS=0` and restart (1883 stays open until step 4).

---

## 3. Dashboard server (last, after all workers are on 8883)

Two files in `~/ha-docker`.

### 3.0 Update the server files first (required)

Replace `rigcontrol-ws/rigcontrol_dashboard_server.py` (Pi: `rigcontrol_dashboard_server_pi/rigcontrol-ws/`, Windows: `rigcontrol_dashboard_server_windows/`) with the new one from the package. It contains the `MQTT_TLS*` settings; the old one ignores them and sends plain MQTT to 8883. The rebuild in 3.3 picks it up. Also take the updated `static/` files if you use them.

### 3.1 `.env`

Add (or change) these lines:

```
MQTT_HOST=10.10.0.10
MQTT_PORT=8883
MQTT_TLS=true
MQTT_CA_FILE=/mqtt-certs/ca.crt
```

`MQTT_HOST` must be the broker address on the certificate (`10.10.0.10`), not `localhost`. For quick mode use `MQTT_TLS_INSECURE=true` and leave out `MQTT_CA_FILE`.

### 3.2 `docker-compose.yml`

In the `rigcontrol-ws:` service, add one line to its existing `volumes:` list and three lines to its existing `environment:` list (do not create a second `volumes:` or `environment:`). Example:

```
  rigcontrol-ws:
    volumes:
      - /etc/rigcontrol/aws-certs:/certs:ro                                        # already there
      - /home/user/ha-docker/mosquitto/config/certs:/mqtt-certs:ro                 # ADD
    environment:
      - MQTT_PORT=${MQTT_PORT}                                                     # already there
      - MQTT_TLS=${MQTT_TLS:-false}                                                # ADD
      - MQTT_CA_FILE=${MQTT_CA_FILE:-}                                             # ADD
      - MQTT_TLS_INSECURE=${MQTT_TLS_INSECURE:-false}                              # ADD
```

The `# ADD` lines are the new ones; the rest of the service stays as it is. The repo's `docker-compose.yml` already has these.

### 3.3 Rebuild and check

```
cd ~/ha-docker && sudo docker compose up -d --build rigcontrol-ws
sudo docker logs rigcontrol-ws --tail 30
```

Check that the log shows a successful MQTT connection on 8883 and that all workers appear in the dashboard.

---

## 4. Lock down (after every worker, the server and the watchdog are on 8883)

Remove the plain `listener 1883` from `mosquitto.conf`, then:

```
cd ~/ha-docker && sudo docker compose restart mosquitto
```

Anything still on 1883 loses its connection at this point.

Then switch from quick to verified mode if you used quick mode: copy `ca.crt` to workers (2.3), set `MQTT_CA_FILE`, and remove `MQTT_TLS_INSECURE` on workers and the server.

---

## Troubleshooting

- **Worker offline after switching:** check `BROKER_PORT=8883` and that port 8883 is reachable (`nc -vz 10.10.0.10 8883`). The agent only reads the broker settings when it starts, so restart it after any change.
- **Certificate verify failed / hostname mismatch:** the broker address in `BROKER_HOST` must match the SAN (IP or DNS) in `san.ext`. Re-issue `server.crt` if it doesn't.
- **Mosquitto won't start:** check `sudo docker logs mosquitto`. Usually `server.key` ownership/permissions (step 1.1) or the certs folder not visible inside the container (`sudo docker exec mosquitto ls /mosquitto/config/certs`).
- **Rollback:** set `MQTT_TLS=0` and `BROKER_PORT=1883` on the worker (and `MQTT_TLS=false`, `MQTT_PORT=1883` in the server `.env`). Plain 1883 stays available until step 4.
