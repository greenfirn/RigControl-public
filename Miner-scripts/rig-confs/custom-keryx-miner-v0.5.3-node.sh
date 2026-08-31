# -- keryx-miner v0.5.3-PoM (custom, download via miner_alt/install_url) write rig-gpu.json       --
# -- %URL% substitutes the first pool_urls[] entry into miner_config.url and any %URL% token      --
# -- inside user_config (here, --keryxd-address); %WAL% substitutes miner_config.wallet_address   --
mkdir -p /etc/rigcontrol
tee /etc/rigcontrol/rig-gpu.json > /dev/null <<'EOF'
{
  "items": [
    {
      "coin": "KRX",
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
        "install_url": "https://github.com/Keryx-Labs/keryx-miner/releases/download/v0.5.3-PoM/keryx-miner-v0.5.3-PoM-linux-amd64.zip",
        "user_config": "--resident-tree --models-dir /opt/miners/models --escrow-cert-file /opt/miners/escrow.cert --escrow-key-file /opt/miners/escrow.key --escrow-state-file /opt/miners/escrow_state.json --mining-address %WAL% --keryxd-address %URL%",
        "wallet_address": "keryx:****"
      },
      "pool_urls": [
        "10.20.0.104:22110"
      ],
      "restart": "true"
    }
  ]
}
EOF
sudo systemctl restart docker_events_gpu
