################################################################################
# WARNING - FOR TESTING / EXPERIMENTAL PURPOSES ONLY
# OctaSpace gives a clear warning about mining outside of its own idle mining
# platform (idle jobs). A miner or other heavy workload started on a node any
# other way keeps running during a rental and takes the GPU, CPU or memory the
# renter paid for, and a node caught doing this can be taken off the marketplace.
# https://docs.octa.space/idle-jobs  (section: Do not run workloads outside idle jobs)
# Use at your own risk.
################################################################################
mkdir -p /etc/rigcontrol
tee /etc/rigcontrol/rig-gpu.json > /dev/null <<'EOF'
{
  "items": [
    {
      "coin": "KRX",
      "pool_ssl": false,
      "miner": "custom",
      "pool": "suprnova",
      "miner_config": {
        "url": "%URL%",
        "algo": "keryxhash",
        "pass": "x",
        "template": "%WAL%",
        "wallet_address": "keryx:*****",
        "miner": "keryx-miner-supr",
        "install_url": "https://github.com/ocminer/keryx-miner-supr/releases/download/v0.12.2/keryx-miner-supr-modern-0.12.2-linux-x86_64.tar.gz",
        "user_config": "--high --resident-tree --model-dir /opt/miners/models --escrow-cert-file /opt/miners/escrow.cert --escrow-key-file /opt/miners/escrow.key --escrow-state-file /opt/miners/escrow_state.json -s %URL% -a %WAL% --api-bind 127.0.0.1:3338"
      },
      "pool_urls": [
        "10.20.0.104:22110"
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
