sudo apt install -y unzip

sudo mkdir -p /opt/miners/keryx-node
cd /opt/miners
#keryx-node in zip
sudo wget https://github.com/Keryx-Labs/keryx-node/releases/download/v1.5.0-PoM/keryx-node-v1.5.0-PoM-linux-amd64.zip
sudo unzip -o keryx-node-v1.5.0-PoM-linux-amd64.zip
sudo rm -v keryx-node-v1.5.0-PoM-linux-amd64.zip
/opt/miners/keryx-node/keryxd --version

# if using different location, update details below in the service file:
# ** must be the full absolute path, can not be the home shortcut ~/ **
# 'WorkingDirectory=/' - your node location
# 'ExecStart=/' - path to the node itself

# copy/paste from 'write the service file' to 'reload the daemon' into your rigs console and press enter to write and load the service file
# enable, start the node, watch node output/service logs

# --disable-upnp
# --ram-scale=10.0

# write the service file
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
    /opt/miners/keryx-node/keryxd --utxoindex --disable-upnp --ram-scale=10.0 --addpeer=141.95.35.181 --rpclisten=0.0.0.0:22110 --rpclisten-json=0.0.0.0:24110 --rpclisten-borsh=0.0.0.0:23110 2>&1 | tee -a /run/rigcontrol/aux_miner.log'
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF

# reload the daemon to let it know about new service
sudo systemctl daemon-reload

# enable if you want it to start on boot
sudo systemctl enable keryxd.service

# start the node
sudo systemctl restart keryxd.service

# watch node output/service logs - ctrl+c to exit
journalctl -u keryxd.service -f

# show extended logs
journalctl -u keryxd.service -e

# show service status
sudo systemctl status keryxd.service

# stop the node
sudo systemctl stop keryxd.service

# disable so it doesnt start on boot
sudo systemctl disable keryxd.service


# -- extra notes --

# datadir location
/root/.keryx-labs/keryx-mainnet/datadir

# check total size
sudo du -sh /root/.keryx-labs/keryx-mainnet/datadir

# copy from windows pc

scp C:\Users\user-name\Downloads\datadir.zip user@node-ip:/home/user/
sudo mkdir -p /root/.keryx-labs/keryx-mainnet/
sudo unzip datadir.zip -d /root/.keryx-labs/keryx-mainnet/

# remove broken datadir

sudo rm -rf /root/.keryx-labs/keryx-mainnet/datadir

# copy to different rig
sudo rsync -avz --progress /root/.keryx-labs/keryx-mainnet/datadir user@node-ip:/home/user/
sudo mkdir -p /root/.keryx-labs/keryx-mainnet/
sudo mv -v /home/user/datadir /root/.keryx-labs/keryx-mainnet/

#update
#stop the node
sudo systemctl stop keryxd.service

cd /opt/miners
#keryx-node in zip
sudo wget https://github.com/Keryx-Labs/keryx-node/releases/download/v1.5.0-PoM/keryx-node-v1.5.0-PoM-linux-amd64.zip
sudo unzip -o keryx-node-v1.5.0-PoM-linux-amd64.zip
sudo rm -v keryx-node-v1.5.0-PoM-linux-amd64.zip
/opt/miners/keryx-node/keryxd --version

#start the node
sudo systemctl start keryxd.service

#watch logs
journalctl -u keryxd.service -f
