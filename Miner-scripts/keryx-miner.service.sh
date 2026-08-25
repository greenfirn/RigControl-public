sudo apt install -y unzip
sudo mkdir -p /opt/miners/keryx-miner
cd /opt/miners/keryx-miner
sudo wget https://github.com/Keryx-Labs/keryx-miner/releases/download/v0.4.9-PoM/keryx-miner-v0.4.9-PoM-linux-amd64.zip
sudo unzip -o keryx-miner-v0.4.9-PoM-linux-amd64.zip
sudo rm -v keryx-miner-v0.4.9-PoM-linux-amd64.zip
/opt/miners/keryx-miner/keryx-miner --version
# WorkingDirectory / ExecStart below must be full absolute paths if using a different install location
# --mining-address / --keryxd-address must be set to your wallet address and node IP
# uncomment ExecStartPre/ExecStopPost below to use the gpu oc apply/reset scripts
# output is tee'd to /run/rigcontrol/gpu_miner.log (GPU slot) so the dashboard's plain gpu.log
# tab and the watchdog's Log Watcher terms work, same as journalctl -u keryx-miner.service does -
# if this rig instead runs keryx-miner as CPU or AUX, swap gpu_miner.log for cpu_miner.log/aux_miner.log
# below to match GPU_SERVICE_NAME/CPU_SERVICE_NAME/AUX_SERVICE_NAME in rigcontrol-agent.conf
sudo tee /etc/systemd/system/keryx-miner.service > /dev/null << 'EOF'
[Unit]
Description=Keryx Miner
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
WorkingDirectory=/opt/miners/keryx-miner
#ExecStartPre=/usr/local/bin/gpu_apply_ocs.sh
#ExecStopPost=/usr/local/bin/gpu_reset_poststop.sh
ExecStartPre=/bin/mkdir -p /run/rigcontrol
ExecStartPre=/bin/rm -f /run/rigcontrol/gpu_miner.log
ExecStart=/bin/bash -c '\
    ( while true; do \
        sleep 60; \
        sz=$(stat -c%%s /run/rigcontrol/gpu_miner.log 2>/dev/null || echo 0); \
        if [ "$sz" -gt 10485760 ]; then \
            tail -c 10485760 /run/rigcontrol/gpu_miner.log > /run/rigcontrol/gpu_miner.log.tmp 2>/dev/null && cat /run/rigcontrol/gpu_miner.log.tmp > /run/rigcontrol/gpu_miner.log && rm -f /run/rigcontrol/gpu_miner.log.tmp; \
        fi; \
    done ) & \
    /opt/miners/keryx-miner/keryx-miner --mining-address keryx:************* --keryxd-address your-node-ip-address:22110 2>&1 | tee -a /run/rigcontrol/gpu_miner.log'
Restart=on-failure
RestartSec=5
#LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable keryx-miner.service
sudo systemctl start keryx-miner.service
# watch miner output/service logs - press ctrl+c to exit
journalctl -u keryx-miner.service -f
journalctl -u keryx-miner.service -e
sudo systemctl stop keryx-miner.service
sudo systemctl disable keryx-miner.service
# cuda support dependencies
sudo apt install -y libcurand10
sudo apt install -y libcublas12
sudo apt install -y libcudart12
scp C:\Users\user-name\Downloads\GLM-4-9B-0414.zip user@rig-ip:/home/user/
sudo rm -rv /opt/miners/keryx-miner/models/GLM-4-9B-0414
sudo unzip GLM-4-9B-0414.zip -d /opt/miners/keryx-miner/models/
sudo ls -lh /opt/miners/keryx-miner/models/
sudo mkdir -p /opt/miners/keryx-miner
sudo systemctl stop keryx-miner.service
cd /opt/miners/keryx-miner
sudo wget https://github.com/Keryx-Labs/keryx-miner/releases/download/v0.4.9-PoM/keryx-miner-v0.4.9-PoM-linux-amd64.zip
sudo unzip -o keryx-miner-v0.4.9-PoM-linux-amd64.zip
sudo rm -v keryx-miner-v0.4.9-PoM-linux-amd64.zip
/opt/miners/keryx-miner/keryx-miner --version
sudo systemctl start keryx-miner.service
# watch miner output/service logs - press ctrl+c to exit
journalctl -u keryx-miner.service -f
