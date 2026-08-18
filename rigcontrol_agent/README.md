[Get started](https://github.com/greenfirn/RigControl#get-started)

** updated agent to use .venv virtual environment, uninstall not needed requirements from system **

Ubuntu 24.04:

sudo python3 -m pip uninstall -y aiomqtt typing_extensions paho-mqtt --break-system-packages

Ubuntu 22.04:

sudo python3 -m pip uninstall -y aiomqtt typing_extensions paho-mqtt

1. install python on a client rig...
```
sudo apt update; sudo apt install -y python3 python3-venv ca-certificates
```
2. download the needed files: 'rigcontrol-agent-local.sh', 'rigcontrol_agent.sh', 'rigcontrol_telemetry.sh', 'rigcontrol_cmd.sh'

3. set the server details in 'rigcontrol-agent-local.sh'

4. for custom service names set them in 'rigcontrol-agent-local.sh' -- 'AUX_SERVICE_NAME=keryxd.service'

5. download then copy/paste contents to write the files to a rig

6. create, enable, start the service 'rigcontrol_agent-service.sh', watch logs for connection to mqtt

'EXCLUDE_FROM_TOTALS = True' in rigcontrol_telemetry.sh for dashboard host to not be included in status totals, select

![test-windows](/images/Screenshot-test-windows.png)

rigcontrol-agent-local... keryx-miner api settings
![local-config-keryx-miner](/images/Screenshot-local-config-keryx-miner.png)

rigcontrol-agent-local... keryxd node: aux service name,binary location,log,log type
![local-config](/images/Screenshot-local-config.png)
