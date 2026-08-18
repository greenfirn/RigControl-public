sudo apt install -y unzip
sudo mkdir -p /opt/miners/keryx-miner
cd /opt/miners/keryx-miner
sudo wget https://github.com/Keryx-Labs/keryx-miner/releases/download/v0.4.2-OPoI/keryx-miner-v0.4.2-OPoI-linux-gnu-amd64.zip
sudo unzip -o keryx-miner-v0.4.2-OPoI-linux-gnu-amd64.zip
sudo rm -v keryx-miner-v0.4.2-OPoI-linux-gnu-amd64.zip
# enable, start the miner, watch miner output/service logs
# write the service file
sudo tee /etc/systemd/system/keryx-miner.service > /dev/null << 'EOF'
[Unit]
Description=Keryx Miner
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
WorkingDirectory=/opt/miners/keryx-miner
ExecStart=/opt/miners/keryx-miner/keryx-miner --mining-address keryx:************* --keryxd-address your-node-ip-address:22110
Restart=on-failure
RestartSec=5
# LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
# reload the daemon to let it know about new service
sudo systemctl daemon-reload
# enable if you want it to start on boot
sudo systemctl enable keryx-miner.service
# start the miner
sudo systemctl start keryx-miner.service
# watch miner output/service logs - press ctrl+c to exit
journalctl -u keryx-miner.service -f
# extended logs
journalctl -u keryx-miner.service -e
# stop the miner
sudo systemctl stop keryx-miner.service
# disable so it doesnt start on boot
sudo systemctl disable keryx-miner.service
# -- extra notes --
# installs I needed for miner cuda support...
sudo apt install -y libcurand10
sudo apt install -y libcublas12
sudo apt install -y libcudart12
# copy model from windows pc:
scp C:\Users\user-name\Downloads\GLM-4-9B-0414.zip user@rig-ip:/home/user/
# remove partialy downloaded model
sudo rm -rv /opt/miners/keryx-miner/models/GLM-4-9B-0414
# unzip to models folder
sudo unzip GLM-4-9B-0414.zip -d /opt/miners/keryx-miner/models/
# show extracted
sudo ls -lh /opt/miners/keryx-miner/models/
