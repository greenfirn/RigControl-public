mkdir -p /etc/rigcontrol
tee /etc/rigcontrol/rig-gpu.json > /dev/null <<'EOF'
{
  "items": [
    {
      "pool_ssl": true,
      "pool_urls": [
        "ca.quai.herominers.com:1185",
        "us2.quai.herominers.com:1185"
      ],
      "miner": "srbminer-gpu",
      "target_image": "ubuntu:24.04",
      "target_name": "clore-default-",
      "reset_oc": "false",
      "miner_config": {
        "url": "ca.quai.herominers.com:1185",
        "algo": "kawpow",
        "pass": "x",
        "template": "******************",
        "user_config": "--tls true --worker %WORKER_NAME%"
      }
    }
  ]
}
EOF
sudo systemctl enable docker_events_gpu
sudo systemctl restart docker_events_gpu
sudo systemctl is-active docker_events_gpu

mkdir -p /etc/rigcontrol
tee /etc/rigcontrol/rig-cpu.json > /dev/null <<'EOF'
{
  "items": [
    {
      "pool_ssl": true,
      "pool_urls": [
        "ca.xelis.herominers.com:1225",
        "us2.xelis.herominers.com:1225"
      ],
      "miner": "srbminer-cpu",
      "target_image": "ubuntu:24.04",
      "target_name": "clore-default-",
      "reset_oc": "false",
      "miner_config": {
        "url": "ca.xelis.herominers.com:1225",
        "algo": "xelishashv3",
        "pass": "x",
        "template": "********************",
        "user_config": "--tls true --worker %WORKER_NAME%"
      }
    }
  ]
}
EOF
sudo systemctl enable docker_events_cpu
sudo systemctl restart docker_events_cpu
sudo systemctl is-active docker_events_cpu
