#!/bin/bash
set -euo pipefail

FH="${1:-1}"
LOG_ROOT=/tmp/logs

OUT="$LOG_ROOT/gapbs.${FH}.log"
NET="$LOG_ROOT/gapbs.net.${FH}.log"

if [[ ! -f "$OUT" ]]; then
    echo "Missing: $OUT"
    exit 1
fi

if [[ ! -f "$NET" ]]; then
    echo "Missing: $NET"
    exit 1
fi

READ_TIME=$(awk '/^Read Time:/ {print $3; exit}' "$OUT")
TRIAL_TIME=$(awk '/^Trial Time:/ {print $3; exit}' "$OUT")
AVG_TIME=$(awk '/^Average Time:/ {print $3; exit}' "$OUT")

START_TS=$(awk '/^START_TS / {print $2; exit}' "$OUT")
END_TS=$(awk '/^END_TS / {print $2; exit}' "$OUT")

if [[ -z "$READ_TIME" || -z "$TRIAL_TIME" || -z "$AVG_TIME" ]]; then
    echo "ERROR: Failed to parse GapBS timing"
    exit 1
fi

if [[ -z "$START_TS" || -z "$END_TS" ]]; then
    echo "ERROR: Failed to parse execution timestamps"
    exit 1
fi

# Trial starts after Read Time
TRIAL_START=$(awk -v s="$START_TS" -v r="$READ_TIME" 'BEGIN {
    printf "%.9f", s + r
}')

# Use Trial Time to define trial end
TRIAL_END=$(awk -v s="$TRIAL_START" -v t="$TRIAL_TIME" 'BEGIN {
    printf "%.9f", s + t
}')

# Find first network sample at or after trial start
PRE_LINE=$(awk -v start="$TRIAL_START" '
$1 >= start {
    print
    exit
}
' "$NET")

# Find last network sample at or before trial end
POST_LINE=$(awk -v end="$TRIAL_END" '
$1 <= end {
    line=$0
}
END {
    print line
}
' "$NET")

if [[ -z "$PRE_LINE" || -z "$POST_LINE" ]]; then
    echo "ERROR: Could not find network samples for trial window"
    exit 1
fi

PRE_TS=$(echo "$PRE_LINE" | awk '{print $1}')
RX_PRE=$(echo "$PRE_LINE" | awk '{print $2}')
TX_PRE=$(echo "$PRE_LINE" | awk '{print $3}')

POST_TS=$(echo "$POST_LINE" | awk '{print $1}')
RX_POST=$(echo "$POST_LINE" | awk '{print $2}')
TX_POST=$(echo "$POST_LINE" | awk '{print $3}')

MEASURED_TIME=$(awk -v a="$PRE_TS" -v b="$POST_TS" 'BEGIN {
    printf "%.6f", b - a
}')

RX_GBPS=$(awk -v pre="$RX_PRE" -v post="$RX_POST" -v t="$MEASURED_TIME" 'BEGIN {
    printf "%.3f", (post - pre) * 8 / t / 1e9
}')

TX_GBPS=$(awk -v pre="$TX_PRE" -v post="$TX_POST" -v t="$MEASURED_TIME" 'BEGIN {
    printf "%.3f", (post - pre) * 8 / t / 1e9
}')

TPUT=$(awk -v t="$AVG_TIME" 'BEGIN {
    printf "%.3f", 3600 / t
}')

ELAPSED=$(awk -v s="$START_TS" -v e="$END_TS" 'BEGIN {
    printf "%.3f", e - s
}')

SUM_TIME=$(awk -v r="$READ_TIME" -v t="$TRIAL_TIME" 'BEGIN {
    printf "%.3f", r + t
}')

echo "============================================================"
echo " GapBS PageRank Result"
echo "============================================================"
printf "%-20s : %s\n" "Threads" "$FH"
printf "%-20s : %s s\n" "Read Time" "$READ_TIME"
printf "%-20s : %s s\n" "Trial Time" "$TRIAL_TIME"
printf "%-20s : %s s\n" "Average Time" "$AVG_TIME"
printf "%-20s : %s jobs/hr\n" "Throughput" "$TPUT"
printf "%-20s : %s Gbps\n" "Network RX" "$RX_GBPS"
printf "%-20s : %s Gbps\n" "Network TX" "$TX_GBPS"
printf "%-20s : %s s\n" "Measured Net Time" "$MEASURED_TIME"
printf "%-20s : %s s\n" "Read + Trial" "$SUM_TIME"
printf "%-20s : %s s\n" "Total Elapsed" "$ELAPSED"
echo "============================================================"
