#!/bin/bash
set -euo pipefail

FH="${1:-1}"
LOG_ROOT=/tmp/logs

PROFILE="$LOG_ROOT/post.${FH}.log"
APP_LOG="$LOG_ROOT/${FH}.log"

NIC_PRE="$LOG_ROOT/pre.hwcounter.${FH}.log"
NIC_POST="$LOG_ROOT/post.hwcounter.${FH}.log"

if [[ ! -f "$PROFILE" ]]; then
    echo "Missing: $PROFILE"
    exit 1
fi

if [[ ! -f "$APP_LOG" ]]; then
    echo "Missing: $APP_LOG"
    exit 1
fi

if [[ ! -f "$NIC_PRE" || ! -f "$NIC_POST" ]]; then
    echo "Missing NIC counter logs"
    exit 1
fi

# ------------------------------------------------------------
# Application-level throughput
#
# One operation = one execution of:
#     acc += data[i] + frobnicate(i, iteration);
#
# Counted only during the 30-second benchmark window.
# ------------------------------------------------------------
TOTAL_OPS=$(awk '
/^TOTAL_OPS / {
    print $2
    exit
}
' "$APP_LOG")

if [[ -z "$TOTAL_OPS" ]]; then
    echo "ERROR: TOTAL_OPS not found in $APP_LOG"
    exit 1
fi

APP_OPS_SEC=$(awk -v ops="$TOTAL_OPS" 'BEGIN {
    printf "%.3f", ops / 30.0
}')

APP_MOPS_SEC=$(awk -v ops="$TOTAL_OPS" 'BEGIN {
    printf "%.3f", ops / 30.0 / 1e6
}')

# ------------------------------------------------------------
# MAGE fault-handling throughput
# FH_total = number of completed page-fault operations
# 4 KiB/page, 30 sec measurement window
# ------------------------------------------------------------
TOTAL_NR=$(awk -F'nr: ' '
/pp: FH_total, cpu:/ { sum += $2 }
END { printf "%.0f", sum }
' "$PROFILE")

THROUGHPUT=$(awk -v nr="$TOTAL_NR" 'BEGIN {
    printf "%.3f", nr * 4096 * 8 / 1e9 / 30
}')

# ------------------------------------------------------------
# P99 latency
# ------------------------------------------------------------
P99_NS=$(
awk '
/Begin Sampled Latencies\(FH_total\)/ { in_block=1; next }
/End Sampled Latencies\(FH_total\)/   { in_block=0 }

in_block {
    if ($0 ~ /Sampled Latencies from CPU/)
        next

    line=$0
    sub(/^\[[^]]+\][[:space:]]*/, "", line)

    n=split(line, a, /[[:space:]]+/)
    for (i=1; i<=n; i++) {
        if (a[i] ~ /^[0-9]+$/)
            print a[i]
    }
}
' "$PROFILE" | sort -n | awk '
{
    v[NR]=$1
}
END {
    if (NR == 0) {
        exit 1
    }

    idx = int(0.99 * NR)
    if (idx < 0.99 * NR)
        idx++

    print v[idx]
}'
)

P99_US=$(awk -v ns="$P99_NS" 'BEGIN {
    printf "%.3f", ns / 1000.0
}')

# ------------------------------------------------------------
# Network bandwidth
# ------------------------------------------------------------
RX_PRE=$(awk '$1=="rx_bytes:" {print $2; exit}' "$NIC_PRE")
TX_PRE=$(awk '$1=="tx_bytes:" {print $2; exit}' "$NIC_PRE")

RX_POST=$(awk '$1=="rx_bytes:" {print $2; exit}' "$NIC_POST")
TX_POST=$(awk '$1=="tx_bytes:" {print $2; exit}' "$NIC_POST")

RX_GBPS=$(awk -v pre="$RX_PRE" -v post="$RX_POST" 'BEGIN {
    printf "%.3f", (post - pre) * 8 / 30 / 1e9
}')

TX_GBPS=$(awk -v pre="$TX_PRE" -v post="$TX_POST" 'BEGIN {
    printf "%.3f", (post - pre) * 8 / 30 / 1e9
}')

# ------------------------------------------------------------
# Page Faults
# ------------------------------------------------------------
PAGE_FAULTS_M=$(awk -v nr="$TOTAL_NR" 'BEGIN {
    printf "%.3f", nr / 1e6
}')

echo "============================================================"
echo " Sequential Read Result"
echo "============================================================"
printf "%-20s : %s\n" "Threads" "$FH"
printf "%-20s : %s Mops/s\n" "Application Ops" "$APP_MOPS_SEC"
printf "%-20s : %s ops/s\n" "Application Ops raw" "$APP_OPS_SEC"
printf "%-20s : %s Gbps\n" "FH Throughput" "$THROUGHPUT"
printf "%-20s : %s us\n" "P99 FH Latency" "$P99_US"
printf "%-20s : %s Gbps\n" "Network RX" "$RX_GBPS"
printf "%-20s : %s Gbps\n" "Network TX" "$TX_GBPS"
printf "%-20s : %s M\n" "Page Faults" "$PAGE_FAULTS_M"
echo "============================================================"
