[Get started](https://github.com/greenfirn/RigControl#get-started)

# Docker Events

> ⚠️ **Use extreme caution with any custom scripts — you're risking your host or account being banned.** Test thoroughly before relying on this... not a good option for VastAI (CPU only) ... keep in mind power limit while idle mining will be what is shown in marketplace, so use locked core to limit power, Clore uses oc profiles that can't be over writen so not best if switching between mining very different coins

---

# Important

- keryx-miner: version change overwrites any files in miner folder '/opt/miners/keryx-miner/current'

save escrow file/models outside of current:
```
--escrow-key-file /opt/miners/escrow.key --models-dir /opt/miners/models
```
copy/move models before updating
```
sudo systemctl stop docker_events_gpu.service
sudo mv -v /opt/miners/keryx-miner/current/models /opt/miners/
sudo systemctl start docker_events_gpu.service
```

'update_miner_versions.sh miner-name miner-name' no options for all -- do not spam run this script uses github api, you will get rate limited

## Setup

-- [no-container-docker_events_monitor--LATEST-log.sh](/Miner-scripts/Docker-Events/no-container-docker_events_monitor--LATEST-log.sh) is best for keryx-miner with screen session and logs --

-- [no-container-docker_events_monitor--no-screen-log.sh](/Miner-scripts/Docker-Events/no-container-docker_events_monitor--no-screen-log.sh) --

* most recent updated, others may not work as is
* naming/layout may have changed for clore, nosana, etc

1. 'write - script files--LATEST...' (see lib to explore original seperate files)
2. 'write - api.conf' -- miner api settings
3. 'write - miner_conf.sh' -- miner versions
4. miner start/stop scripts:
- 'keryx-miner.service.sh'
-  using flightsheets:
- 'no-docker_launcher.sh' -- systems without docker
- 'no-container-docker_events_monitor--no-screen-log.sh' -- no screen, logs in service
- 'no-container-docker_events_monitor--LATEST' -- with miner screen session
- clore, etc
5. 'rig-confs' -- "flightsheets"
6. 'py-nvtool/py-nvtool.txt' -- 'overclocks' Reset / Apply
7. 'update_miner_versions.sh  miner-name miner-name' no options for all -- do not spam run this script uses github api, you will get rate limited

** show last 20 lines of service log... journalctl -u docker_events_gpu.service -n 20 --no-pager **

'no-container-docker_events_monitor--no-screen-log.sh' or 'no-container-docker_events_monitor--LATEST...' for octaspace

'source/manual_start_gpu.sh', 'source/manual_stop_gpu.sh' another option for octaspace start/stop idle miner (sudo manual_...)

'no-container-docker_events_monitor-clore.sh' ... run idle job parallel with clore idle job (empty script ubuntu image etc)

'podman_events_monitor.sh' ... Nosana podman containers

'no-docker_launcher.sh' ... same miner conf,api,etc for no docker mining rigs

'keryx-dummy-cpu-service.sh' ... keryx-miner service named same as cpu service for easy dashboard control on gpu only mining rig
