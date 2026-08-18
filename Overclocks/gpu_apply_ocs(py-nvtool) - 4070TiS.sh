# https://github.com/Akisoft41/py-nvtool/releases
sudo tee /usr/local/bin/gpu_apply_ocs.sh > /dev/null <<'EOF'
#!/bin/bash
echo "copy escrow.cert..."
sudo cp -v --update=none /escrow.cert /opt/miners/keryx-miner/current/
echo "Setting 4070TiS for mining... Keryx"
py-nvtool --setcore 2100 --setcoreoffset 300 --setmem 0 --setmemoffset 2000
EOF
# make it executable
sudo chmod +x /usr/local/bin/gpu_apply_ocs.sh
# manual test
sudo /usr/local/bin/gpu_apply_ocs.sh
