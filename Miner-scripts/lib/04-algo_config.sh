################################################################################
# WARNING - FOR TESTING / EXPERIMENTAL PURPOSES ONLY
# OctaSpace gives a clear warning about mining outside of its own idle mining
# platform (idle jobs). A miner or other heavy workload started on a node any
# other way keeps running during a rental and takes the GPU, CPU or memory the
# renter paid for, and a node caught doing this can be taken off the marketplace.
# https://docs.octa.space/idle-jobs  (section: Do not run workloads outside idle jobs)
# Use at your own risk.
################################################################################
WARTHOG_TARGET=""
if [[ "$ALGO" == "warthog" ]]; then
    if (( TOTAL_THREADS >= 32 )); then
        WARTHOG_TARGET=47000000
    elif (( TOTAL_THREADS >= 24 )); then
        WARTHOG_TARGET=37000000
    else
        WARTHOG_TARGET=30000000
    fi
fi
