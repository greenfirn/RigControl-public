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
        "user_config": "--resident-tree --models-dir /opt/miners/models --escrow-cert-file /opt/miners/escrow.cert --escrow-key-file /opt/miners/escrow.key --escrow-state-file /opt/miners/escrow_state.json --mining-address %WAL% --keryxd-address %URL%",
        "wallet_address": "keryx:****"
      },
      "pool_urls": [
        "10.10.0.126:22110"
      ],
      "restart": "true"
    }
  ],
  "apply_to_workers": [
    "5950x-1-5070ti",
    "5950x-4-4070tis",
    "5950x-5-5070ti",
    "5950x-6-5070ti",
    "5950x-8-5070ti"
  ]
}
EOF
sudo systemctl restart docker_events_gpu