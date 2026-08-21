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
        "url": "10.10.0.126:22110",
        "algo": "",
        "pass": "",
        "template": "",
        "miner": "keryx-miner",
        "install_url": "https://github.com/Keryx-Labs/keryx-miner/releases/download/v0.5.0-PoM/keryx-miner-v0.5.0-PoM-linux-amd64.zip",
        "user_config": "--high --resident-tree --models-dir /opt/miners/models --escrow-key-file /opt/miners/escrow.key --mining-address %WAL% --keryxd-address %URL%",
        "wallet_address": "keryx:***********"
      },
      "pool_urls": [
        "10.10.0.126:22110"
      ]
    }
  ]
}
EOF
sudo systemctl restart docker_events_gpu