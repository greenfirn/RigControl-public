[agent README](../README.md)

# Agent setup

start with the install in test mode (1), then verified TLS (2), then client certificates (3).

## 1. Install / update (user, password only, 'TLS - no certificate check')

0. create the server certificate on the server (skip if already done during the server setup, details: [basic TLS guide](../../rigcontrol_dashboard_server_pi/mosquitto-tls-setup.txt), steps 1-2). replace `10.10.0.10` with the ip of your dashboard server:

   ```
   openssl version || (sudo apt update && sudo apt install -y openssl)
   sudo mkdir -p ~/ha-docker/mosquitto/config/certs && cd ~/ha-docker/mosquitto/config/certs
   sudo openssl genrsa -out ca.key 4096
   sudo openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -subj "/CN=RigControl MQTT CA" -out ca.crt
   sudo openssl genrsa -out server.key 2048
   sudo openssl req -new -key server.key -subj "/CN=10.10.0.10" -out server.csr
   printf "subjectAltName=IP:10.10.0.10,IP:127.0.0.1" | sudo tee san.ext > /dev/null
   sudo openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 825 -sha256 -extfile san.ext
   sudo chown 1883:1883 server.key server.crt ca.crt
   sudo chmod 640 server.key
   cd ~/ha-docker && sudo docker compose up -d mosquitto
   ```

   (windows server: [Windows basic TLS guide](../../rigcontrol_dashboard_server_windows/mosquitto-tls-setup.txt))

   server certs: these are the broker's identity. workers use them to check they are talking to the right broker.
1. install python on a client worker...

```
sudo apt update; sudo apt install -y python3 python3-venv ca-certificates
```

2. download the needed files:
   - [rigcontrol-agent-local.sh](rigcontrol-agent-local.sh)
   - [rigcontrol_agent.sh](rigcontrol_agent.sh)
   - [rigcontrol_agent-service.sh](rigcontrol_agent-service.sh)
   - [rigcontrol_telemetry.sh](rigcontrol_telemetry.sh)
   - [rigcontrol_cmd.sh](rigcontrol_cmd.sh)
   - [generate-copy-paste-update.bat](generate-copy-paste-update.bat)
3. set the server details in [rigcontrol-agent-local.sh](rigcontrol-agent-local.sh): `BROKER_HOST`, `BROKER_USER`, `BROKER_PASS`
4. for custom service names set them in [rigcontrol-agent-local.sh](rigcontrol-agent-local.sh) -- 'AUX_SERVICE_NAME=keryxd.service'
5. install / update
   - run 'generate-copy-paste-update.bat' to create/update 'copy-paste-update.sh'
   - open a ssh session on a worker (on a windows machine use putty or similar ssh client)
   - copy/paste the contents of 'copy-paste-update.sh' into a worker ssh session and press enter to write the files and start/restart the agent

if copy/paste into the console fails (the file is about 4000 lines and a terminal can drop or corrupt lines, giving a SyntaxError or IndentationError in the agent log), copy the file to the worker and run it instead:

```
scp copy-paste-update.sh user@WORKER:~/
ssh -t user@WORKER "bash ~/copy-paste-update.sh"
```

'EXCLUDE_FROM_TOTALS = True' in [rigcontrol_telemetry.sh](rigcontrol_telemetry.sh) for dashboard host to not be included in status totals, select

## 2. Verified TLS (broker certificate checked)

1. copy the broker's `ca.crt` (public) from the server's certificate folder (`~/ha-docker/mosquitto/config/certs/`) to `/etc/rigcontrol/ca.crt` on each worker. run on the server for every worker, replace `user@WORKER` with the worker login:

   ```
   scp ~/ha-docker/mosquitto/config/certs/ca.crt user@WORKER:/tmp/ca.crt
   ssh -t user@WORKER "sudo mkdir -p /etc/rigcontrol && sudo mv /tmp/ca.crt /etc/rigcontrol/ca.crt"
   ```

   (windows server: the folder is `C:\mosquitto-certs\`, run the same commands in Git Bash with `/c/mosquitto-certs/ca.crt`. a windows worker uses `C:\rigcontrol\ca.crt`)
2. in `/etc/rigcontrol/rigcontrol-agent.conf` on the worker set `MQTT_TLS_INSECURE=0` and uncomment `#MQTT_CA_FILE=/etc/rigcontrol/ca.crt` (or `#MQTT_CA_FILE=C:\rigcontrol\ca.crt` in `C:\rigcontrol\rigcontrol_agent.conf` on a windows worker)
3. restart the agent:

   ```
   sudo systemctl restart rigcontrol-agent.service
   ```

## 3. Advanced TLS (client certificates, mutual TLS)

client certs are separate from the server certs from step 0: they let the broker check who is connecting. each worker gets one. the dashboard server also connects to the broker, so it needs one too (`rigcontrol-dashboard`).

1. on the server create the worker's client certificate. `WORKER_NAME` = the worker's hostname, one certificate per worker. needs the helper script [mosquitto-client-cert.sh](../../rigcontrol_dashboard_server_pi/mosquitto-client-cert.sh) in `~/ha-docker` ([advanced TLS guide](../../rigcontrol_dashboard_server_pi/mosquitto-tls-advanced.txt), step 1).:

   ```
   cd ~/ha-docker
   sudo bash mosquitto-client-cert.sh WORKER_NAME
   ```
2. copy the worker's `client.crt` and `client.key` to `/etc/rigcontrol/` on that worker. first write the helper script once (paste the contents of [mosquitto-client-cert-copy.sh](../../rigcontrol_dashboard_server_pi/mosquitto-client-cert-copy.sh), it writes `~/ha-docker/mosquitto-client-cert-copy.sh`), then run it as your normal user (no sudo), replace `WORKER_NAME` with the certificate name and `user@WORKER` with the worker login:

   ```
   cd ~/ha-docker
   bash mosquitto-client-cert-copy.sh WORKER_NAME user@WORKER
   ```
3. in `/etc/rigcontrol/rigcontrol-agent.conf` on the worker uncomment:

   ```
   #MQTT_CLIENT_CERT=/etc/rigcontrol/client.crt
   #MQTT_CLIENT_KEY=/etc/rigcontrol/client.key
   ```

4. restart the agent:

   ```
   sudo systemctl restart rigcontrol-agent.service
   ```

5. when every worker is connected with its certificate, enable `require_certificate true` on the broker ([advanced TLS guide](../../rigcontrol_dashboard_server_pi/mosquitto-tls-advanced.txt), step 5). the dashboard server's own client certificate is step 4 of that guide, do it before this

## Plain MQTT (no TLS, optional)

for a network you trust: set `BROKER_PORT=1883` and `MQTT_TLS=0` (leave `MQTT_TLS_INSECURE` alone, it only applies with TLS) in `/etc/rigcontrol/rigcontrol-agent.conf`, then restart the agent (`sudo systemctl restart rigcontrol-agent.service`). the broker needs a plain 1883 listener: [no TLS guide](../../rigcontrol_dashboard_server_pi/mosquitto-no-tls-setup.txt).
