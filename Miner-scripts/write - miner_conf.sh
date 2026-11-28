################################################################################
# WARNING - FOR TESTING / EXPERIMENTAL PURPOSES ONLY
# OctaSpace gives a clear warning about mining outside of its own idle mining
# platform (idle jobs). A miner or other heavy workload started on a node any
# other way keeps running during a rental and takes the GPU, CPU or memory the
# renter paid for, and a node caught doing this can be taken off the marketplace.
# https://docs.octa.space/idle-jobs  (section: Do not run workloads outside idle jobs)
# Use at your own risk.
################################################################################
sudo mkdir -p /etc/rigcontrol
sudo tee /etc/rigcontrol/miner.conf > /dev/null <<'EOF'
XMRIG_VERSION "6.26.0"
BZMINER_VERSION "v25.0.1b2"
WILDRIG_VERSION "0.50.2"
SRBMINER_VERSION "3.5.4"
SRBMINER-CPU_VERSION "3.5.4"
RIGEL_VERSION "1.23.2"
LOLMINER_VERSION "1.98a"
ONEZEROMINER_VERSION "1.7.4"
GMINER_VERSION "3.44"
TEAMREDMINER_VERSION "0.10.21"
TREXMINER_VERSION "0.26.8"
EOF
