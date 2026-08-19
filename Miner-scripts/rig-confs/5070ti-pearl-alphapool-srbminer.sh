mkdir -p /etc/rigcontrol
tee /etc/rigcontrol/rig-gpu.json > /dev/null <<'EOF'
{
  "items": [
    {
      "pool_ssl": false,
      "miner": "srbminer",
      "reset_oc": "true",
      "apply_oc": "false",
      "miner_config": {
        "url": "us1.alphapool.tech:5571, us2.alphapool.tech:5571",
        "algo": "pearlhash",
        "pass": "x",
        "template": "prl1***********+mdl1*******************",
        "user_config": "--worker %WORKER_NAME% --tls false --disable-cpu --gpu-id 0 --gpu-cclock0 2490 --gpu-coffset0 300 --gpu-mclock0 7001 --gpu-plimit0 300"
      }
    }
  ]
}
EOF
sudo systemctl restart docker_events_gpu
sudo systemctl is-active docker_events_gpu
