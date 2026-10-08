#!/bin/bash
set -euo pipefail

MIND_ROOT=/root/workspace_ych/mage/mage-kernel
LOG_ROOT=/tmp/logs

MN_IP=192.168.100.114

# Usage:
#   ./test-one-baremetal.sh <threads>
#
# Example:
#   ./test-one-baremetal.sh 122

FH="${1:-1}"

mkdir -p "$LOG_ROOT"

OUT="$LOG_ROOT/gapbs.${FH}.log"
NET="$LOG_ROOT/gapbs.net.${FH}.log"

# Find NIC used to reach Memory Node
NIC=$(ip route get "$MN_IP" | awk '
/dev/ {
    for (i = 1; i <= NF; i++) {
        if ($i == "dev") {
            print $(i+1)
            exit
        }
    }
}')

if [ -z "$NIC" ]; then
    echo "ERROR: Cannot determine NIC for MN $MN_IP"
    exit 1
fi

echo "============================================================"
echo " GapBS PageRank"
echo "============================================================"
echo "Threads : $FH"
echo "MN IP   : $MN_IP"
echo "NIC     : $NIC"
echo "Log     : $OUT"
echo "Net log : $NET"
echo "============================================================"

rm -f "$OUT" "$NET"

cd "$MIND_ROOT/apps/page-rank"

export OMP_NUM_THREADS="$FH"

echo
echo "[1] Starting network logging"

# timestamp, rx_bytes, tx_bytes
(
    while true; do
        TS=$(date +%s.%N)

        RX=$(ethtool -S "$NIC" | awk '$1=="rx_bytes:" {print $2; exit}')
        TX=$(ethtool -S "$NIC" | awk '$1=="tx_bytes:" {print $2; exit}')

        echo "$TS $RX $TX"
        sleep 1
    done
) > "$NET" &

NET_PID=$!

cleanup() {
    kill "$NET_PID" 2>/dev/null || true
    wait "$NET_PID" 2>/dev/null || true
}

trap cleanup EXIT

echo
echo "[2] Starting GapBS: threads=$FH"

START_TS=$(date +%s.%N)

/usr/bin/time -v ./gapbs/gapbs_pr \
    -f /scratch/kron.sg \
    -i1000 \
    -t1e-4 \
    -n1 \
    > "$OUT" 2>&1

END_TS=$(date +%s.%N)

cleanup
trap - EXIT

echo
echo "START_TS $START_TS" >> "$OUT"
echo "END_TS $END_TS" >> "$OUT"

echo
echo "============================================================"
echo " DONE"
echo "============================================================"
echo "Application log : $OUT"
echo "Network log     : $NET"
echo "============================================================"
