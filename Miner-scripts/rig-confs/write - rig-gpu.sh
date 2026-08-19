mkdir -p /etc/rigcontrol
tee /etc/rigcontrol/rig-gpu.json > /dev/null <<'EOF'
{
  "items": [
    {
      "pool_ssl": false,
      "miner": "",
      "reset_oc": "true",
      "apply_oc": "false",
      "miner_config": {
        "url": "",
        "algo": "",
        "pass": "x",
        "template": ".%WORKER_NAME%"
      }
    }
  ]
}
EOF
sudo systemctl restart docker_events_gpu
