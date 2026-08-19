mkdir -p /etc/rigcontrol
tee /etc/rigcontrol/rig-gpu.json > /dev/null <<'EOF'
{
  "items": [
    {
      "pool_ssl": false,
      "miner": "custom",
      "miner_alt": "keryx-miner",
      "reset_oc": "true",
      "apply_oc": "true",
      "miner_config": {
        "url": "",
        "algo": "",
        "pass": "",
        "template": "",
        "miner": "keryx-miner",
        "install_url": "https://github.com/Keryx-Labs/keryx-miner/releases/download/v0.4.2-OPoI/keryx-miner-v0.4.2-OPoI-linux-gnu-amd64.zip",
        "user_config": "--escrow-key-file /opt/miners/escrow.key --mining-address keryx:*************** --keryxd-address 10.10.0.126:22110"
      }
    }
  ]
}
EOF
sudo systemctl restart docker_events_gpu
sudo systemctl is-active docker_events_gpu
