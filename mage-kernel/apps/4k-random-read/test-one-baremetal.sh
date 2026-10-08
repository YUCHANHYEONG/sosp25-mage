#!/bin/bash
set -euo pipefail

MIND_ROOT=/root/workspace_ych/mage/mage-kernel
UTIL="$MIND_ROOT/mind_linux/util_modules"
LOG_ROOT=/tmp/logs

MN_IP=192.168.100.114

# Usage:
#   ./test-one-baremetal.sh <threads> [array_size_bytes]
#
# Examples:
#   ./test-one-baremetal.sh 1
#   ./test-one-baremetal.sh 48
#   ./test-one-baremetal.sh 122
#
# Default array size = 4 GiB (current artifact setting)

FH="${1:-1}"
ARRAY_SIZE="${2:-4294967296}"

mkdir -p "$LOG_ROOT"

OUT="$LOG_ROOT/${FH}.log"
PRE="$LOG_ROOT/pre.${FH}.log"
POST="$LOG_ROOT/post.${FH}.log"

PRE_HW="$LOG_ROOT/pre.hwcounter.${FH}.log"
POST_HW="$LOG_ROOT/post.hwcounter.${FH}.log"

DSTAT_LOG="$LOG_ROOT/dstat.${FH}.csv"
DSTAT_TXT="$LOG_ROOT/dstat.${FH}.log"

# Find the NIC actually used to reach the Memory Node.
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
echo " 4K Random Read"
echo "============================================================"
echo "FH threads : $FH"
echo "Array size : $ARRAY_SIZE bytes"
echo "MN IP      : $MN_IP"
echo "NIC        : $NIC"
echo "Logs       : $LOG_ROOT"
echo "============================================================"

rm -f \
    "$OUT" \
    "$PRE" \
    "$POST" \
    "$PRE_HW" \
    "$POST_HW" \
    "$DSTAT_LOG" \
    "$DSTAT_TXT"

cd "$MIND_ROOT/apps/4k-random-read"

echo
echo "[1] Building benchmark"

make clean
make

echo
echo "[2] Starting benchmark: FH=$FH"

nohup ./bin/test_4k_random_read "$FH" "$ARRAY_SIZE" \
    > "$OUT" 2>&1 &

BENCH_PID=$!

echo
echo "[3] Waiting for BEGIN_BENCHMARK..."

while ! grep -q 'BEGIN_BENCHMARK' "$OUT"; do
    if ! kill -0 "$BENCH_PID" 2>/dev/null; then
        echo "ERROR: Benchmark exited before BEGIN_BENCHMARK"
        cat "$OUT"
        exit 1
    fi

    sleep 0.2
done

echo
echo "[4] BEGIN_BENCHMARK detected"
echo "    Resetting profiling counters"

cd "$UTIL"

# Disable profiling first.
rmmod fbs_psample 2>/dev/null || true
insmod ./fbs_psample.ko sample=0
rmmod fbs_psample

# Clear previous profiling values.
rmmod fbs_pclean 2>/dev/null || true
insmod ./fbs_pclean.ko
rmmod fbs_pclean

# Save state immediately before measurement.
dmesg > "$PRE"

date +%s > "$PRE_HW"
echo "NIC=$NIC" >> "$PRE_HW"
ethtool -S "$NIC" >> "$PRE_HW"

echo
echo "[5] Starting dstat (1-second interval)"

dstat -n -N "$NIC" \
    --output "$DSTAT_LOG" \
    1 > "$DSTAT_TXT" 2>&1 &

DSTAT_PID=$!

# Start FH profiling.
insmod ./fbs_psample.ko sample=1
rmmod fbs_psample

echo
echo "[6] Measurement running..."
echo "    Waiting for END_BENCHMARK"

while ! grep -q 'END_BENCHMARK' "$OUT"; do
    if ! kill -0 "$BENCH_PID" 2>/dev/null; then
        echo "ERROR: Benchmark exited before END_BENCHMARK"

        kill "$DSTAT_PID" 2>/dev/null || true
        wait "$DSTAT_PID" 2>/dev/null || true

        cat "$OUT"
        exit 1
    fi

    sleep 0.2
done

echo
echo "[7] END_BENCHMARK detected"
echo "    Stopping profiling and dstat"

# Stop profiling.
insmod ./fbs_psample.ko sample=0
rmmod fbs_psample

# Stop dstat.
kill "$DSTAT_PID" 2>/dev/null || true
wait "$DSTAT_PID" 2>/dev/null || true

# Save NIC counters immediately after measurement.
date +%s > "$POST_HW"
echo "NIC=$NIC" >> "$POST_HW"
ethtool -S "$NIC" >> "$POST_HW"

echo
echo "[8] Printing kernel profiling results"

# Capture only the profiling information printed from this point.
dmesg -w > "$POST" &
DMESG_PID=$!

sleep 0.2

insmod ./fbs_pprint.ko
rmmod fbs_pprint

sleep 2

kill "$DMESG_PID" 2>/dev/null || true
wait "$DMESG_PID" 2>/dev/null || true

wait "$BENCH_PID"

echo
echo "============================================================"
echo " DONE"
echo "============================================================"
echo "Benchmark log : $OUT"
echo "Profile log   : $POST"
echo "NIC pre       : $PRE_HW"
echo "NIC post      : $POST_HW"
echo "dstat CSV     : $DSTAT_LOG"
echo "dstat text    : $DSTAT_TXT"
echo "============================================================"
