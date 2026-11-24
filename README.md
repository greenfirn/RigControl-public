# RigControl - Dashboard

A self-hosted rig monitoring dashboard for Ubuntu Server / Windows rigs, Clore AI, Octaspace, Salad Hosts etc. Built with a Python telemetry agent, MQTT-based dashboard server, and a webpage frontend.

--> [Design](#design)

Dashboard... Docker / miner details popout

![dashboard](images/Screenshot-dashboard-popout.png)

Flightsheets... Apply to

![fs-apply-to](images/Screenshot-fs-apply-to.png)

# Work in progress...

> redesigned install paths... use binary short names etc

```
sudo mkdir -p /opt/miners/custom
sudo cp -a /opt/miners/keryx-miner /opt/miners/custom/keryx-miner
```

> updated Stats:
>
> Full chart order now: Hashrate, GPU Core Clock, GPU Mem Clock, GPU Power, GPU VRAM, GPU Utl, GPU Temp,
>
> RAM Usage, Load Average, CPU Utl, CPU Temp.
>
> windows agent notes for running services, not tested
>

# Get started

- [rigcontrol_dashboard_server_windows](rigcontrol_dashboard_server_windows)
- [rigcontrol_dashboard_server_pi](rigcontrol_dashboard_server_pi)
- [static](static)
- [rigcontrol_agent](rigcontrol_agent)
- [Miner-scripts](Miner-scripts)
- [Docker-Events](Miner-scripts/Docker-Events)
- [py-nvtool](py-nvtool/py-nvtool-install-usage.txt)
- [Overclocks](Overclocks)
- [gpu-vram-temps](py-nvtool/gpu-vram-temps)
- [Fan-control](Fan-control)
- [themes](themes)

X-files

![x-files](images/Screenshot-wp-x-files.png)

Fallout

![fallout](images/Screenshot-wp-fallout.png)

Alien

![alien](images/Screenshot-wp-alien.png)

Phantom Menace

![phantom-menace](images/Screenshot-wp-phantom-menace.png)

# Design:

![server-tree](images/rigcontrol_full_worker_server_tree.png)

![broadcast-flow](images/rigcontrol_server_broadcast_flow.png)

Render tuning... Advanced Server Settings

![render-tuning](images/Screenshot-render-tuning.png)

Themes... saved to browser data, profiles save on server

![color-shceme](images/Screenshot-color-scheme.png)

Multi-gpu pane in details popout, main list shows total watts, highest temp, highest watts, etc

![Dashboard Screenshot](images/Screenshot-gpus-pane2.png)

Search workers multi term coma seperated

![search](images/Screenshot-search-multi.png)

Rig Statistics -- saves to rig local db, skip gpu stats with override rules still apply

![Dashboard Screenshot](images/Screenshot-rig-stats.png)

![Dashboard Screenshot](images/Screenshot-rig-stats2.png)

Remote access view only mode... with email unlock [2FA.md](rigcontrol_dashboard_server_pi/2FA.md)

![unlock](images/Screenshot-view-only.png)

Unlock... 3 attempts per 24h, 60 second sleep

![unlock](images/Screenshot-view-only-dialog.png)

Unlock email...

![unlock](images/Screenshot-view-only-unlock.png)

[RigControl - Dashboard](#rigcontrol---dashboard)

[Get started](#get-started)

---

## Support

Donations are appreciated:

MetaMask supported chains (Base/Eth/Clore)
<img src="https://raw.githubusercontent.com/base/brand-kit/main/logo/TheSquare/Digital/Base_square_blue.svg" width="16" height="16" /> <img src="https://assets.coingecko.com/coins/images/279/standard/ethereum.png?1696501628" width="20" height="20" /> <img src="https://assets.coingecko.com/coins/images/30959/standard/CLORE_Logo_200x200_PNG.png?1696529798" width="16" height="16" />

```
0xe65b5d7B7D43D77eF585CCF4a675832d0d23f806
```
