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
ExecStart=/opt/miners/keryx-node/keryxd --utxoindex --rpclisten=0.0.0.0:22110 --rpclisten-json=0.0.0.0:24110 --rpclisten-borsh=0.0.0.0:23110
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload

# enable if you want it to start on boot
sudo systemctl enable keryxd.service

sudo systemctl start keryxd.service

# watch node output/service logs - ctrl+c to exit
journalctl -u keryxd.service -f

journalctl -u keryxd.service -e

sudo systemctl status keryxd.service

sudo systemctl stop keryxd.service

# disable so it doesnt start on boot
sudo systemctl disable keryxd.service


# -- extra notes --

# datadir location
/root/.keryx-labs/keryx-mainnet/datadir

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

# check DAA score:

./keryx-cli
network mainnet
connect localhost
rpc get-block-dag-info

# Update / Test

sudo systemctl stop keryxd.service

cd /opt/miners
sudo wget https://github.com/Keryx-Labs/keryx-node/releases/download/v1.5.0-PoM/keryx-node-v1.5.0-PoM-linux-amd64.zip
sudo unzip -o keryx-node-v1.5.0-PoM-linux-amd64.zip
sudo rm -v keryx-node-v1.5.0-PoM-linux-amd64.zip
/opt/miners/keryx-node/keryxd --version

sudo systemctl start keryxd.service

journalctl -u keryxd.service -f

journalctl -u keryxd.service -n 50 --no-pager