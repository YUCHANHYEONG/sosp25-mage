#!/bin/bash
set -e

MIND_ROOT=/root/workspace_ych/mage/mage-kernel

MN_DATA_IP=192.168.100.114
TCP_DAEMON_IP=165.194.35.18

echo "===== 1. Check MAGE kernel ====="

if [[ "$(uname -r)" != 4.15.0* ]]; then
    echo "ERROR: MAGE kernel is not running: $(uname -r)"
    exit 1
fi

echo "Kernel: $(uname -r)"


echo
echo "===== 2. Load Intel RDMA driver ====="

modprobe irdma


echo
echo "===== 3. Detect RDMA interface ====="

CN_NIC=$(nmcli -g connection.interface-name connection show rdma100g)

if [ -z "$CN_NIC" ]; then
    echo "ERROR: rdma100g interface not found"
    exit 1
fi

CN_RDMA_DEV=""

for dev in /sys/class/infiniband/*; do
    if [ -d "$dev/device/net/$CN_NIC" ]; then
        CN_RDMA_DEV=$(basename "$dev")
        break
    fi
done

if [ -z "$CN_RDMA_DEV" ]; then
    echo "ERROR: RDMA device for $CN_NIC not found"

    echo
    echo "Available RDMA devices:"
    for dev in /sys/class/infiniband/*; do
        echo -n "$(basename "$dev"): "
        ls "$dev/device/net" 2>/dev/null || true
    done

    exit 1
fi

echo "NIC       : $CN_NIC"
echo "RDMA DEV  : $CN_RDMA_DEV"


echo
echo "===== 4. Configure RDMA network ====="

ip link set dev "$CN_NIC" mtu 4200

echo "Testing connectivity to Memory Node through $CN_NIC..."

if ! ping -I "$CN_NIC" -c 1 -W 2 "$MN_DATA_IP" >/dev/null; then
    echo "ERROR: Cannot reach $MN_DATA_IP through $CN_NIC"
    echo
    echo "Route:"
    ip route get "$MN_DATA_IP" || true
    exit 1
fi

MN_MAC=$(ip neigh show "$MN_DATA_IP" dev "$CN_NIC" | \
	awk '/lladdr/ {print $3; exit}')

if [ -z "$MN_MAC" ]; then
    echo "ERROR: Cannot resolve MAC address for $MN_DATA_IP on $CN_NIC"
    echo
    echo "Neighbor table:"
    ip neigh show dev "$CN_NIC"
    exit 1
fi

ip neigh replace "$MN_DATA_IP" \
    lladdr "$MN_MAC" \
    nud permanent \
    dev "$CN_NIC"

echo "CN IP     : $(ip -4 -br addr show "$CN_NIC" | awk '{print $3}')"
echo "MN IP     : $MN_DATA_IP"
echo "MN MAC    : $MN_MAC"
echo "Neighbor  : $(ip neigh show "$MN_DATA_IP" dev "$CN_NIC")"


echo
echo "===== 5. Start Frontend ====="

cd "$MIND_ROOT/frontend"

nohup unbuffer taskset -c 0 \
    ./build/tna_disagg_switch_base 18 90 \
    > frontend.log 2>&1 &

sleep 2

pgrep -f './build/tna_disagg_switch_base 18 90' >/dev/null || {
    echo "ERROR: Frontend failed"
    tail -n 50 frontend.log
    exit 1
}

echo "Frontend: RUNNING"


echo
echo "===== 6. Start TCP daemon ====="

cd "$MIND_ROOT/mind_linux/test_programs/90_mind_daemons/05_tcp_daemon"

nohup unbuffer taskset -c 1 \
    ./tcp_daemon "$TCP_DAEMON_IP" \
    > tcp_daemon.log 2>&1 &

sleep 2

pgrep -f "./tcp_daemon $TCP_DAEMON_IP" >/dev/null || {
    echo "ERROR: TCP daemon failed"
    tail -n 50 tcp_daemon.log
    exit 1
}

echo "TCP daemon: RUNNING"


echo
echo "===== 7. Load MAGE module ====="

if lsmod | grep -q '^roce4disagg'; then
    echo "ERROR: roce4disagg already loaded"
    exit 1
fi

cd "$MIND_ROOT/mind_linux/roce_modules"

insmod ./roce4disagg.ko \
    ip_addr=192.168.100.112 \
    frontend_ip_addr=165.194.35.18

echo
echo "===== 8. Wait for MAGE initialization ====="

sleep 20

if dmesg | tail -n 200 | grep -q 'RDMA tests succeeded'; then
    echo "RDMA test: SUCCESS"
else
    echo "ERROR: RDMA test failed"
    echo
    dmesg | tail -n 120
    exit 1
fi


echo
echo "===== MAGE initialization complete ====="

echo "CN NIC     : $CN_NIC"
echo "CN RDMA DEV: $CN_RDMA_DEV"
echo "MN IP      : $MN_DATA_IP"
echo "MN MAC     : $MN_MAC"

echo
dmesg | tail -n 30
