[agent README](../README.md)

# Agent setup

start with the plain install (1), then add TLS when it works (2, with the insecure test mode for troubleshooting), then client certificates (3).

## 1. Install / update (plain MQTT, no TLS)

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
3. set the server details in [rigcontrol-agent-local.sh](rigcontrol-agent-local.sh): `BROKER_HOST`, `BROKER_USER`, `BROKER_PASS` (plain MQTT on port 1883 is the default, the broker needs a plain 1883 listener: [no TLS guide](../../rigcontrol_dashboard_server_pi/mosquitto-no-tls-setup.txt))
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

## 2. Basic TLS (encrypted, broker certificate verified)

on the broker follow the [basic TLS guide](../../rigcontrol_dashboard_server_pi/mosquitto-tls-setup.txt), then on each worker:

1. copy the broker's `ca.crt` (public) to `/etc/rigcontrol/ca.crt` on the worker once
2. in `rigcontrol-agent-local.sh` set `BROKER_PORT=8883` and uncomment `MQTT_TLS=1` (`ca.crt` is found automatically at that path; `#MQTT_CA_FILE=` stays commented unless you need a different path)
3. run the install / update again (step 5 above), the agent restarts and connects over TLS

### Test mode (skip certificate checks)

available as soon as TLS is on (needs `MQTT_TLS=1`). for troubleshooting only, e.g. to tell a certificate problem from a network problem: uncomment `#MQTT_TLS_INSECURE=1` in `rigcontrol-agent-local.sh` and run the install / update again. remove it afterwards.

## 3. Advanced TLS (client certificates, mutual TLS)

only when the broker has `require_certificate true`: [advanced TLS guide](../../rigcontrol_dashboard_server_pi/mosquitto-tls-advanced.txt). per worker, copy its `client.crt` / `client.key` to `/etc/rigcontrol/` and uncomment in `rigcontrol-agent-local.sh`:

```
#MQTT_CLIENT_CERT=/etc/rigcontrol/client.crt
#MQTT_CLIENT_KEY=/etc/rigcontrol/client.key
```

then run the install / update again.
