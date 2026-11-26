[agent README](../README.md)

# Agent setup

start with the install in test mode (1), then verified TLS (2), then client certificates (3).

## 1. Install / update (user, password only, 'TLS - no certificate check')

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
2. in `rigcontrol-agent-local.sh` set `MQTT_TLS_INSECURE=0` and uncomment `#MQTT_CA_FILE=/etc/rigcontrol/ca.crt` (or `#MQTT_CA_FILE=C:\rigcontrol\ca.crt` in the Windows conf)
3. run the install / update again, the agent restarts and connects with the certificate verified

## 3. Advanced TLS (client certificates, mutual TLS)

only when the broker has `require_certificate true`: [advanced TLS guide](../../rigcontrol_dashboard_server_pi/mosquitto-tls-advanced.txt). per worker, copy its `client.crt` / `client.key` to `/etc/rigcontrol/` and uncomment in `rigcontrol-agent-local.sh`:

```
#MQTT_CLIENT_CERT=/etc/rigcontrol/client.crt
#MQTT_CLIENT_KEY=/etc/rigcontrol/client.key
```

then run the install / update again.

## Plain MQTT (no TLS, optional)

for a network you trust: set `BROKER_PORT=1883` and `MQTT_TLS=0` (leave `MQTT_TLS_INSECURE` alone, it only applies with TLS) in `rigcontrol-agent-local.sh`. the broker needs a plain 1883 listener: [no TLS guide](../../rigcontrol_dashboard_server_pi/mosquitto-no-tls-setup.txt).
