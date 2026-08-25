# -- keryx-miner v0.5.2-PoM --high variant (custom, download via miner_alt/install_url) --
# -- same as custom-keryx-miner-node-v052.sh but with --high added to user_config --
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
        "url": "%URL%",
        "algo": "keryxhash",
        "pass": "",
        "template": "",
        "miner": "keryx-miner",
        "install_url": "https://github.com/Keryx-Labs/keryx-miner/releases/download/v0.5.2-PoM/keryx-miner-v0.5.2-PoM-linux-amd64.zip",
        "user_config": "--high --resident-tree --models-dir /opt/miners/models --escrow-cert-file /opt/miners/escrow.cert --escrow-key-file /opt/miners/escrow.key --escrow-state-file /opt/miners/escrow_state.json --mining-address %WAL% --keryxd-address %URL%",
        "wallet_address": "keryx:YOUR_MINING_ADDRESS"
      },
      "pool_urls": [
        "10.10.0.126:22110"
      ],
      "restart": "true"
    }
  ]
}
EOF
sudo systemctl restart docker_events_gpu
