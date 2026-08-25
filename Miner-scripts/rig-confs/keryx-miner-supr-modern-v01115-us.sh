# -- keryx-miner-supr (the "supr"/suprnova-pool variant) v0.11.15 modern, write rig-gpu.json --
# -- CUSTOM_MINER_SUPR_API_HOST/PORT in rigcontrol-agent.conf map to --api-bind here --
# -- pool_urls[0] is the local keryxd node; the rest are suprnova failover stratum endpoints --
mkdir -p /etc/rigcontrol
tee /etc/rigcontrol/rig-gpu.json > /dev/null <<'EOF'
{
  "items": [
    {
      "pool_ssl": false,
      "miner": "custom",
      "pool": "suprnova",
      "miner_config": {
        "url": "%URL%",
        "algo": "keryxhash",
        "pass": "x",
        "template": "%WAL%",
        "wallet_address": "keryx:****",
        "miner": "keryx-miner-supr",
        "install_url": "https://github.com/ocminer/keryx-miner-supr/releases/download/v0.11.15/keryx-miner-supr-modern-0.11.15-linux-x86_64.tar.gz",
        "user_config": "--resident-tree --model-dir /opt/miners/models --escrow-cert-file /opt/miners/escrow.cert --escrow-key-file /opt/miners/escrow.key --escrow-state-file /opt/miners/escrow_state.json -s %URL% -a %WAL% --api-bind 127.0.0.1:3338"
      },
      "pool_urls": [
        "10.10.0.126:22110",
        "stratum-us.suprnova.cc:4404",
        "krx.suprnova.cc:4404"
      ],
      "miner_alt": "keryx-miner-supr",
      "reset_oc": "true",
      "apply_oc": "true",
      "restart": "true"
    }
  ]
}
EOF
sudo systemctl restart docker_events_gpu
