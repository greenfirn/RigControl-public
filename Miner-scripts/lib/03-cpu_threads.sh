################################################################################
# WARNING - FOR TESTING / EXPERIMENTAL PURPOSES ONLY
# OctaSpace gives a clear warning about mining outside of its own idle mining
# platform (idle jobs). A miner or other heavy workload started on a node any
# other way keeps running during a rental and takes the GPU, CPU or memory the
# renter paid for, and a node caught doing this can be taken off the marketplace.
# https://docs.octa.space/idle-jobs  (section: Do not run workloads outside idle jobs)
# Use at your own risk.
################################################################################
TOTAL_THREADS=$(nproc)
CPU_THREADS=$((TOTAL_THREADS - 1))
AUTOFILL_CPU=""
if [[ "$MINER_NAME" == "xmrig" && "$ALGO" == "rx/0" ]]; then
    RX_THREADS=-1
    if [[ "$TOTAL_THREADS" -eq 32 ]]; then
        RX_THREADS=31
        RX_CORES=(0 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31)
    elif [[ "$TOTAL_THREADS" -eq 24 ]]; then
        RX_THREADS=23
        RX_CORES=(0 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23)
    fi
    if [[ "$RX_THREADS" -ne -1 ]]; then
        BITMASK=0
        for core in "${RX_CORES[@]}"; do
            (( BITMASK |= (1 << core) ))
        done
        RX_MASK=$(printf "0x%X" "$BITMASK")
        AUTOFILL_CPU="$RX_THREADS --cpu-affinity=$RX_MASK"
    fi
fi
