mkdir -p /etc/rigcontrol
tee /etc/rigcontrol/rig-gpu.json > /dev/null <<'EOF'
{
  "items": [
    {
      "pool_ssl": true,
      "miner": "srbminer",
      "reset_oc": "true",
      "apply_oc": "false",
      "miner_config": {
        "url": "btx-us-east.lproute.com:8660",
        "algo": "btx",
        "pass": "x",
        "template": "btx1********************.%WORKER_NAME%",
        "user_config": "--tls true --disable-cpu --gpu-id 0 --gpu-cclock0 2490 --gpu-coffset0 300 --gpu-mclock0 7001 --gpu-plimit0 300"
      }
    }
  ]
}
EOF
sudo systemctl restart docker_events_gpu
sudo systemctl is-active docker_events_gpu
