mkdir -p /etc/rigcontrol
tee /etc/rigcontrol/rig-gpu.json > /dev/null <<'EOF'
{
  "items": [
    {
      "pool_ssl": false,
      "miner": "wildrig-multi",
      "reset_oc": "true",
      "apply_oc": "false",
      "miner_config": {
        "url": "pool.pearlhash.xyz:9000",
        "algo": "pearlhash",
        "pass": "x",
        "template": "prl1*********************.%WORKER_NAME%",
        "user_config": "--gpu-reset-oc --gpu-powerlimit 300 --gpu-core-clock 2490 --gpu-core-offset 325 --gpu-memory-clock 7001"
      }
    }
  ]
}
EOF
sudo systemctl restart docker_events_gpu
sudo systemctl is-active docker_events_gpu
