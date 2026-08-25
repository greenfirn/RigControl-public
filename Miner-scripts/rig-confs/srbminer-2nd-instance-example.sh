tee /etc/rigcontrol/rig-gpu.json > /dev/null <<'EOF'
{
  "items": [
    {
      "pool_ssl": false,
      "miner": "srbminer-cpu",
      "reset_oc": "false",
      "apply_oc": "false",
      "pool_urls": [
        "pool.supportxmr.com:9000"
      ],
      "miner_config": {
        "url": "%URL%",
        "algo": "randomx",
        "pass": "x",
        "template": "%WAL%.%WORKER_NAME%",
        "wallet_address": "************",
        "user_config": "--tls true",
        "tls": 1
      },
      "restart": "false"
    }
  ]
}
EOF
