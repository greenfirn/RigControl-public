[Get started](../README.md#get-started)

## Guides

- [Server certificate](#server-certificate)
- [Agent setup ( Get worker connected first )](#agent-setup--get-worker-connected-first-)
- [Recommended](#recommended)
- [Basic TLS](#basic-tls)
- [Advanced TLS](#advanced-tls)
- [No TLS](#no-tls)
- [Custom api / logs](#custom-api--logs)

## Updates

** update.. 'OSN_PRIMARY=0' (default): local GPU/CPU/memory stats. Set 'OSN_PRIMARY=1' to use OctaSpace node (osn) metrics instead. **

** updated agent to use .venv virtual environment, uninstall not needed requirements from system **

Ubuntu 24.04:

```
sudo python3 -m pip uninstall -y aiomqtt typing_extensions paho-mqtt --break-system-packages
```

Ubuntu 22.04:

```
sudo python3 -m pip uninstall -y aiomqtt typing_extensions paho-mqtt
```

## Telemetry flow (each poll)

- **Agent start:** one full local GPU read (unless the GPUs are in passthrough / blocked), cached: power limits (min/default/max), vbios, board partner, architecture, PCI slot, VRAM total. Reused on every poll; never repeated on refresh.
- **1. Local passthrough check:** GPUs bound to `vfio-pci` (sysfs) belong to a VM. Runs first, before osn is asked, and cannot be overridden. GPU values are reported as `0`, no GPU tool is called.
- **2. osn is asked** (always, if installed): `osn_gpu_passthrough_active=1` gives the same result as step 1.
- **3. Docker rules:** a running container matching `BLOCK_LIST` always skips GPU stats (values `0`). Optional `DOCKER_SKIP_GPU_STATS=1` also skips while any non-miner container runs (empty GPU list).
- **4. GPU stats source:**
  - `OSN_PRIMARY=0` (default): local `nvidia-smi` / `rocm-smi` / gputemps through the GPU tool guard.
  - `OSN_PRIMARY=1`: GPU, CPU and memory come from osn only, no local GPU fallback. Static values are filled from the start-up cache; osn unreachable gives `-1` values.
- **GPU tool guard:** every local GPU call has a 5s timeout. A timeout blocks the tool until the agent restarts; any other failure pauses it 30s, and a second failure in a row blocks it. Paused or blocked tools report `-1` values (`stats_failed` / `stats_error` say why).
- **5. Miner stats** always come from the miner APIs / logs. Load, network, uptime, docker and service status are collected locally.
- **6. Reply:** one universal payload (`gpus[]` with temp, util, `power_watts` + `power_limit`, clocks, `coreoffset`, VRAM, ...). The dashboard combines used/limit watts for display. The log's "Stats source" line shows where each part came from.

Value meaning on the dashboard: `0` = intentionally not read (passthrough / `BLOCK_LIST`), `-1` = read failed, `--` = not reported.

## Server certificate

1. create the server certificate on the server (skip if already done during the server setup, details: [basic TLS guide](../rigcontrol_dashboard_server_pi/mosquitto-tls-setup.md), steps 1-2). server certs are the broker's identity, workers use them to check they are talking to the right broker. paste this once in the parent folder of mosquitto, it writes `mosquitto-server-cert.sh` in the current folder:

   ```
   sudo tee mosquitto-server-cert.sh > /dev/null <<'EOF'
   #!/bin/bash
   # TLS, see mosquitto-tls-setup.md
   # Creates the CA and the broker (server) certificate: sudo bash mosquitto-server-cert.sh <dashboard-server-ip> [more ips or hostnames]
   # run it from the parent folder of mosquitto, certificates go to ./mosquitto/config/certs
   # <dashboard-server-ip> = the ip workers and the dashboard server use to reach the broker. Output: ca.crt ca.key server.crt server.key
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

   then run it from there with the ip of your dashboard server (extra ips or hostnames can follow), and restart the broker:

   ```
   sudo bash mosquitto-server-cert.sh 10.10.0.10
   sudo docker compose up -d mosquitto
   ```

   (windows server: [Windows basic TLS guide](../rigcontrol_dashboard_server_windows/mosquitto-tls-setup.md))

## Agent setup ( Get worker connected first )

the broker needs its server certificate first, see [Server certificate](#server-certificate) (or [No TLS](#no-tls) for plain mqtt).

1. install python on a client worker...

   ```
   sudo apt update; sudo apt install -y python3 python3-venv ca-certificates
   ```

2. download the needed files:
   - [rigcontrol-agent-local.sh](ubuntu/rigcontrol-agent-local.sh)
   - [rigcontrol_agent.sh](ubuntu/rigcontrol_agent.sh)
   - [rigcontrol_agent-service.sh](ubuntu/rigcontrol_agent-service.sh)
   - [rigcontrol_telemetry.sh](ubuntu/rigcontrol_telemetry.sh)
   - [rigcontrol_cmd.sh](ubuntu/rigcontrol_cmd.sh)
   - [generate-copy-paste-update.bat](ubuntu/generate-copy-paste-update.bat)

3. set the server details in [rigcontrol-agent-local.sh](ubuntu/rigcontrol-agent-local.sh): `BROKER_HOST`, `BROKER_USER`, `BROKER_PASS`

4. for custom service names set them in [rigcontrol-agent-local.sh](ubuntu/rigcontrol-agent-local.sh) -- 'AUX_SERVICE_NAME=keryxd.service'

5. install / update (the agent connects with user and password, encrypted, certificate not checked yet)
   - run 'generate-copy-paste-update.bat' to create/update 'copy-paste-update.sh'
   - open a ssh session on a worker (on a windows machine use putty or similar ssh client)
   - copy/paste the contents of 'copy-paste-update.sh' into a worker ssh session and press enter to write the files and start/restart the agent

   if copy/paste into the console fails (the file is about 4000 lines and a terminal can drop or corrupt lines, giving a SyntaxError or IndentationError in the agent log), copy the file to the worker and run it instead:

   ```
   scp copy-paste-update.sh user@WORKER:~/
   ssh -t user@WORKER "bash ~/copy-paste-update.sh"
   ```

   'EXCLUDE_FROM_TOTALS = True' in [rigcontrol_telemetry.sh](ubuntu/rigcontrol_telemetry.sh) for dashboard host to not be included in status totals, select

## Basic TLS

1. copy the broker's `ca.crt` (public) to `/etc/rigcontrol/ca.crt` on each worker. paste [mosquitto-ca-copy.sh](../rigcontrol_dashboard_server_pi/mosquitto-ca-copy.sh) once in the parent folder of mosquitto, it writes `mosquitto-ca-copy.sh` in the current folder, then run it from there as your normal user (no sudo), with one or more worker logins:

   ```
   bash mosquitto-ca-copy.sh user@WORKER [user@WORKER2 ...]
   ```

   (windows server: there is no mosquitto folder to run from, the certificates are in `C:\mosquitto-certs\`. in Git Bash run `CERT_DIR=/c/mosquitto-certs bash mosquitto-ca-copy.sh user@WORKER`. a windows worker uses `C:\rigcontrol\ca.crt`)

2. in `/etc/rigcontrol/rigcontrol-agent.conf` on the worker set `MQTT_TLS_INSECURE=0` and uncomment `#MQTT_CA_FILE=/etc/rigcontrol/ca.crt` (or `#MQTT_CA_FILE=C:\rigcontrol\ca.crt` in `C:\rigcontrol\rigcontrol_agent.conf` on a windows worker)

3. restart the agent, it now verifies the broker certificate:

   ```
   sudo systemctl restart rigcontrol-agent.service
   ```

## Advanced TLS

1. client certs are separate from the server certs, they let the broker check who is connecting. each worker gets one, the dashboard server also connects to the broker so it needs one too (`rigcontrol-dashboard`, [advanced TLS guide](../rigcontrol_dashboard_server_pi/mosquitto-tls-advanced.md), step 4). paste [mosquitto-client-cert.sh](../rigcontrol_dashboard_server_pi/mosquitto-client-cert.sh) once in the parent folder of mosquitto, it writes `mosquitto-client-cert.sh` in the current folder ([advanced TLS guide](../rigcontrol_dashboard_server_pi/mosquitto-tls-advanced.md), step 1), then create the worker's client certificate from there, replace `WORKER_NAME` with the worker's hostname, one certificate per worker:

   ```
   sudo bash mosquitto-client-cert.sh WORKER_NAME
   ```

2. copy the worker's `client.crt` and `client.key` to `/etc/rigcontrol/` on that worker. paste [mosquitto-client-cert-copy.sh](../rigcontrol_dashboard_server_pi/mosquitto-client-cert-copy.sh) once in the parent folder of mosquitto, it writes `mosquitto-client-cert-copy.sh` in the current folder, then run it from there as your normal user (no sudo), replace `WORKER_NAME` with the certificate name and `user@WORKER` with the worker login:

   ```
   bash mosquitto-client-cert-copy.sh WORKER_NAME user@WORKER
   ```

   for a windows worker run [get-client-cert.bat](windows/get-client-cert.bat) in cmd on that pc to copy its certificate from the server, replace `WORKER_NAME` with the certificate name, `user@SERVER` with the server login and `PARENT_FOLDER` with the parent folder of mosquitto on the server (an optional 4th argument sets the destination folder, default `C:\rigcontrol`):

   ```
   get-client-cert.bat WORKER_NAME user@SERVER PARENT_FOLDER
   ```

   to push certificates from a windows pc to a linux worker, run [copy-client-cert.bat](ubuntu/copy-client-cert.bat) from the folder with the certificate files:

   ```
   copy-client-cert.bat WORKER_NAME user@WORKER
   ```

3. in `/etc/rigcontrol/rigcontrol-agent.conf` on the worker uncomment:

   ```
   #MQTT_CLIENT_CERT=/etc/rigcontrol/client.crt
   #MQTT_CLIENT_KEY=/etc/rigcontrol/client.key
   ```

   (windows worker: in `C:\rigcontrol\rigcontrol_agent.conf` uncomment `#MQTT_CLIENT_CERT=C:\rigcontrol\client.crt` and `#MQTT_CLIENT_KEY=C:\rigcontrol\client.key`)

4. restart the agent:

   ```
   sudo systemctl restart rigcontrol-agent.service
   ```

5. when every worker is connected with its certificate, enable `require_certificate true` on the broker ([advanced TLS guide](../rigcontrol_dashboard_server_pi/mosquitto-tls-advanced.md), step 5). the dashboard server's own client certificate is step 4 of that guide, do it before this

## No TLS

1. in `/etc/rigcontrol/rigcontrol-agent.conf` on the worker set `BROKER_PORT=1883` and `MQTT_TLS=0`
2. restart the agent:

   ```
   sudo systemctl restart rigcontrol-agent.service
   ```

3. the broker needs a plain 1883 listener: [no TLS guide](../rigcontrol_dashboard_server_pi/mosquitto-no-tls-setup.md)

## Recommended

reserve the port range used for rental services (replace 51000-52000 with yours), so outgoing connections like the agent's mqtt never use a rental port. services can still bind these ports.

```
echo "net.ipv4.ip_local_reserved_ports = 51000-52000" | sudo tee /etc/sysctl.d/99-rental-ports.conf
sudo sysctl --system
cat /proc/sys/net/ipv4/ip_local_reserved_ports
```

Useful commands:

```bash
# show service status
systemctl status rigcontrol-agent.service --no-pager

# follow the agent log: ctrl+c to break/exit
journalctl -u rigcontrol-agent.service -f

# show the last 100 log lines
journalctl -u rigcontrol-agent.service -n 100 --no-pager

# reload systemd after editing the service file
sudo systemctl daemon-reload

# enable start on boot
sudo systemctl enable rigcontrol-agent.service

# disable start on boot
sudo systemctl disable rigcontrol-agent.service

# start the agent
sudo systemctl start rigcontrol-agent.service

# stop the agent
sudo systemctl stop rigcontrol-agent.service

# restart the agent
sudo systemctl restart rigcontrol-agent.service
```

![test-windows](../images/Screenshot-test-windows.png)

## Custom api / logs

[rigcontrol-agent-local.sh](ubuntu/rigcontrol-agent-local.sh)... keryxd node: aux service name,binary location,log,log type

```
AUX_SERVICE_NAME=keryxd.service
CUSTOM_MINER_BIN_AUX=/opt/miners/keryx-node/keryxd
KERYXD_LOG_PATH=/run/rigcontrol/aux_miner.log
KERYXD_LOG_STYLE=blocks
```

[rigcontrol-agent-local.sh](ubuntu/rigcontrol-agent-local.sh)... KERYX_MINER_API

```
KERYX_MINER_API_HOST=127.0.0.1
KERYX_MINER_API_PORT=3338
KERYX_MINER_SUPR_API_HOST=127.0.0.1
KERYX_MINER_SUPR_API_PORT=3338
```
