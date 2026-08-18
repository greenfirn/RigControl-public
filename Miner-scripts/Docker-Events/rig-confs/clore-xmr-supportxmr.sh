mkdir -p /etc/rigcontrol
tee /etc/rigcontrol/rig-cpu.json > /dev/null <<'EOF'
{
  "items": [
    {
      "pool_ssl": false,
      "miner": "xmrig",
      "target_image": "ubuntu:24.04",
      "target_name": "clore-default-",
      "reset_oc": "false",
      "apply_oc": "false",
      "miner_config": {
        "url": "pool.supportxmr.com:9000",
        "algo": "rx/0",
        "pass": "%WORKER_NAME%",
        "template": "***********************",
        "user_config": "-t %CPU_THREADS% --tls -k --randomx-1gb-pages --huge-pages"
      }
    }
  ]
}
EOF
sudo systemctl enable docker_events_cpu
sudo systemctl restart docker_events_cpu
sudo systemctl is-active docker_events_cpu
