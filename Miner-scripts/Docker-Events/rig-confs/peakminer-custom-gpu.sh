mkdir -p /etc/rigcontrol
tee /etc/rigcontrol/rig-gpu.json > /dev/null <<'EOF'
{
  "items": [
    {
      "pool_ssl": false,
      "miner": "custom",
      "miner_alt": "peakminer",
      "reset_oc": "true",
      "apply_oc": "false",
      "miner_config": {
        "url": "",
        "algo": "",
        "pass": "x",
        "template": "",
        "miner": "peakminer",
        "install_url": "https://github.com/peakminer/peakminer/releases/download/v2.0.0/peakminer-2.0.0.tar.gz",
        "user_config": "--api-port 4068 --coin pearl --url ca.pearl.herominers.com:1200 --user prl******************.%WORKER_NAME% --gpu-power 300 --gpu-lcore 2475 --gpu-core 375 --gpu-lmem 7001"
      }
    }
  ]
}
EOF
sudo systemctl restart docker_events_gpu
