# This script acts as a "config file" for the cluster setup.

# MIND_ROOT should be set in shell init if possible.
export MIND_ROOT="${MIND_ROOT:-/root/workspace_ych/mage/mage-kernel}"

# ============================================================
# CLUSTER SETUP
# ============================================================

# Bare-metal environment: VM-related value is kept only because
# some Mage scripts expect this variable to exist.
cn_vm_name='baremetal-AMD2'

# Hostnames
cn_vm_hostname='AMD2'
mn_vm_hostname='amd4'

# ------------------------------------------------------------
# Compute Node (AMD2)
# ------------------------------------------------------------

# Control-plane / SSH
cn_control_sshname='165.194.35.18'
cn_control_ip='165.194.35.18'

# RDMA data-plane NIC
cn_nic='enp33s0f1'
cn_mac='b4:96:91:db:91:81'
cn_data_ip='192.168.100.112'

# ------------------------------------------------------------
# Memory Node (AMD4)
# ------------------------------------------------------------

# Control-plane / SSH
mn_control_sshname='165.194.35.90'
mn_control_ip='165.194.35.90'

# RDMA data-plane NIC
mn_nic='enp161s0f0'
mn_mac='b4:96:91:db:91:78'
mn_data_ip='192.168.100.114'

# enp161s0f0 is attached to NUMA node 1
mn_nic_numa=1

# RDMA devices
cn_rdma_dev='irdma1'
mn_rdma_dev='irdma2'

# ------------------------------------------------------------
# Frontend
# ------------------------------------------------------------

# Frontend runs on AMD2 bare metal
frontend_sshname='165.194.35.18'
frontend_ip='165.194.35.18'

# ------------------------------------------------------------
# RDMA Network
# ------------------------------------------------------------

# Intel E810 uses RoCE
using_roce='true'

# 192.168.100.0/24
data_subnet_prefix='24'
