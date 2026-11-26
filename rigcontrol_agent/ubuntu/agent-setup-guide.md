# Agent setup

[agent README](../README.md)

## Basic setup

1. install the agent on a worker (steps below)
2. copy the broker's `ca.crt` to `/etc/rigcontrol/ca.crt` on the worker once ([basic TLS guide](../../rigcontrol_dashboard_server_pi/mosquitto-tls-setup.txt))
3. set `BROKER_HOST`, `BROKER_USER`, `BROKER_PASS` in `rigcontrol-agent-local.sh` (TLS is on by default: port 8883, `MQTT_TLS=1`)
4. run the install / update, the agent starts and connects

> note: for an easier TLS setup, once a worker is connected the dashboard can edit its `rigcontrol-agent.conf` (TLS settings and the optional client certificate lines) from the browser, so you do not need to ssh in to change them. the agent must be restarted after a broker setting change.

## Install / update steps

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
3. set the server details in [rigcontrol-agent-local.sh](rigcontrol-agent-local.sh)
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
