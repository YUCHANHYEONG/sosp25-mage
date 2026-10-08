#!/bin/bash

# same for both nodes :)

if [[ -z $MIND_ROOT ]]; then
        echo '$MIND_ROOT not set!' >/dev/stderr
        exit 1
fi

source $MIND_ROOT/scripts/config.sh
cd $MIND_ROOT/scripts/bricks

if [[ "$(hostname)" = $mn_vm_hostname ]]; then
        nic=$mn_nic
        rdma_dev=$mn_rdma_dev
        laddr=$mn_data_ip
        rmac=$cn_mac
        raddr=$cn_data_ip

elif [[ "$(hostname)" = $cn_vm_hostname ]]; then
        nic=$cn_nic
        rdma_dev=$cn_rdma_dev
        laddr=$cn_data_ip
        rmac=$mn_mac
        raddr=$mn_data_ip

else
        echo 'Unknown hostname, not sure what IP to assign!' >/dev/stderr
        exit 1
fi

sudo ip link set $nic up

if [[ "$using_roce" = 'true' ]]; then
        # NIC MTU should be large enough for 4KB RDMA traffic.
        sudo ip link set $nic mtu 4200

        # Intel E810 / irdma link check
        rdma_state="$(rdma link show "$rdma_dev/1" | \
                grep -o 'state [A-Z]*' | head -1 | awk '{print $2}')"

        if [[ "$rdma_state" != "ACTIVE" ]]; then
                echo "$0: error: RDMA link is not ACTIVE! ($rdma_dev: $rdma_state)"
                exit 1
        fi

        # Permanent neighbor entry for the other RoCE node.
        sudo ip neigh replace $raddr dev $nic lladdr $rmac nud permanent

else
        sudo systemctl start opensm
        sleep 3
fi

sudo ip addr replace "$laddr/$data_subnet_prefix" dev $nic
