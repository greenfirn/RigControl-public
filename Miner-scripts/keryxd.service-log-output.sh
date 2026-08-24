sudo apt install -y unzip
sudo mkdir -p /opt/miners/keryx-node
cd /opt/miners
sudo wget https://github.com/Keryx-Labs/keryx-node/releases/download/v1.5.0-PoM/keryx-node-v1.5.0-PoM-linux-amd64.zip
sudo unzip -o keryx-node-v1.5.0-PoM-linux-amd64.zip
sudo rm -v keryx-node-v1.5.0-PoM-linux-amd64.zip
/opt/miners/keryx-node/keryxd --version
# WorkingDirectory / ExecStart below must be full absolute paths if using a different install location
# optional extra flags available: --disable-upnp, --ram-scale=10.0
sudo tee /etc/systemd/system/keryxd.service > /dev/null << 'EOF'
[Unit]
Description=Keryx Node
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
WorkingDirectory=/opt/miners/keryx-node
ExecStartPre=/bin/mkdir -p /run/rigcontrol
ExecStartPre=/bin/rm -f /run/rigcontrol/aux_miner.log
ExecStart=/bin/bash -c '\
    ( while true; do \
        sleep 60; \
        sz=$(stat -c%%s /run/rigcontrol/aux_miner.log 2>/dev/null || echo 0); \
        if [ "$sz" -gt 10485760 ]; then \
            tail -c 10485760 /run/rigcontrol/aux_miner.log > /run/rigcontrol/aux_miner.log.tmp 2>/dev/null && cat /run/rigcontrol/aux_miner.log.tmp > /run/rigcontrol/aux_miner.log && rm -f /run/rigcontrol/aux_miner.log.tmp; \
        fi; \
    done ) & \
    /opt/miners/keryx-node/keryxd --utxoindex --addpeer=141.95.35.181 --rpclisten=0.0.0.0:22110 --rpclisten-json=0.0.0.0:24110 --rpclisten-borsh=0.0.0.0:23110 2>&1 | tee -a /run/rigcontrol/aux_miner.log'
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable keryxd.service
sudo systemctl restart keryxd.service
# watch node output/service logs - ctrl+c to exit
journalctl -u keryxd.service -f
journalctl -u keryxd.service -e
sudo systemctl status keryxd.service
sudo systemctl stop keryxd.service
sudo systemctl disable keryxd.service
# datadir location
/root/.keryx-labs/keryx-mainnet/datadir
sudo du -sh /root/.keryx-labs/keryx-mainnet/datadir
scp C:\Users\user-name\Downloads\datadir.zip user@node-ip:/home/user/
sudo mkdir -p /root/.keryx-labs/keryx-mainnet/
sudo unzip datadir.zip -d /root/.keryx-labs/keryx-mainnet/
# remove broken datadir
sudo rm -rf /root/.keryx-labs/keryx-mainnet/datadir
# copy to different rig
sudo rsync -avz --progress /root/.keryx-labs/keryx-mainnet/datadir user@node-ip:/home/user/
sudo mkdir -p /root/.keryx-labs/keryx-mainnet/
sudo mv -v /home/user/datadir /root/.keryx-labs/keryx-mainnet/
sudo systemctl stop keryxd.service
cd /opt/miners
sudo wget https://github.com/Keryx-Labs/keryx-node/releases/download/v1.5.0-PoM/keryx-node-v1.5.0-PoM-linux-amd64.zip
sudo unzip -o keryx-node-v1.5.0-PoM-linux-amd64.zip
sudo rm -v keryx-node-v1.5.0-PoM-linux-amd64.zip
/opt/miners/keryx-node/keryxd --version
sudo systemctl start keryxd.service
journalctl -u keryxd.service -f
