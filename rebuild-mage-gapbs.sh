#!/bin/bash
set -euo pipefail

# ============================================================
# MAGE GapBS rebuild script
#
# Usage:
#   ./rebuild-mage-gapbs.sh <local_mem_mib>
#   ./rebuild-mage-gapbs.sh <local_mem_mib> --reboot
#
# Example:
#   ./rebuild-mage-gapbs.sh 11000
#   ./rebuild-mage-gapbs.sh 11000 --reboot
#
# Optional environment overrides:
#   NUM_CNTHREADS=4
#   RECLAIM_BATCH_SIZE=256
#   CACHE_PRESSURE=0.9
#   JOBS=128
#   MN_IP=192.168.100.114
# ============================================================


# ------------------------------------------------------------
# 1. Arguments
# ------------------------------------------------------------

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "Usage: $0 <local_mem_mib> [--reboot]"
    echo "Example: $0 11000"
    echo "Example: $0 11000 --reboot"
    exit 1
fi

LOCAL_MEM_MIB="$1"
DO_REBOOT=0

if [ "${2:-}" = "--reboot" ]; then
    DO_REBOOT=1
elif [ $# -eq 2 ]; then
    echo "ERROR: Unknown option: $2"
    exit 1
fi

if ! [[ "$LOCAL_MEM_MIB" =~ ^[0-9]+$ ]] || [ "$LOCAL_MEM_MIB" -le 0 ]; then
    echo "ERROR: local_mem_mib must be a positive integer."
    exit 1
fi


# ------------------------------------------------------------
# 2. Paths
# ------------------------------------------------------------

export MIND_ROOT="${MIND_ROOT:-/root/workspace_ych/mage/mage-kernel}"

KERNEL_SRC="$MIND_ROOT/mind_linux"
ROCE_SRC="$KERNEL_SRC/roce_modules"

ICE_SRC="${ICE_SRC:-/root/ice-mage415-1.13.7/src}"
IRDMA_SRC="${IRDMA_SRC:-/root/irdma-srpm/kmod-irdma-1.13.43}"

CONFIG_H="$KERNEL_SRC/include/disagg/config.h"
CNTHREAD_H="$KERNEL_SRC/include/disagg/cnthread_disagg.h"
ROCE_H="$ROCE_SRC/roce_for_disagg/roce_disagg.h"


# ------------------------------------------------------------
# 3. Experiment configuration
# ------------------------------------------------------------

PROGRAM_NAME="${PROGRAM_NAME:-gapbs_pr}"
PROGRAM_DIGIT="${PROGRAM_DIGIT:-8}"

NUM_CNTHREADS="${NUM_CNTHREADS:-4}"
RECLAIM_BATCH_SIZE="${RECLAIM_BATCH_SIZE:-256}"
CACHE_PRESSURE="${CACHE_PRESSURE:-0.9}"

MN_IP="${MN_IP:-192.168.100.114}"

JOBS="${JOBS:-$(nproc)}"

EXPECTED_KERNEL_RELEASE="${EXPECTED_KERNEL_RELEASE:-4.15.0-mage128}"


# ------------------------------------------------------------
# 4. Calculate local-memory pages
# ------------------------------------------------------------

PAGE_SIZE="$(getconf PAGE_SIZE)"
BYTES_PER_MIB=$((1024 * 1024))

if [ $((BYTES_PER_MIB % PAGE_SIZE)) -ne 0 ]; then
    echo "ERROR: PAGE_SIZE does not divide 1 MiB exactly."
    exit 1
fi

PAGES_PER_MIB=$((BYTES_PER_MIB / PAGE_SIZE))
LOCAL_MEM_PAGES=$((LOCAL_MEM_MIB * PAGES_PER_MIB))


# ------------------------------------------------------------
# 5. Detect NIC / RDMA device automatically
# ------------------------------------------------------------

CN_NIC="$(ip route get "$MN_IP" | awk '/dev/ {for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')"

if [ -z "$CN_NIC" ]; then
    echo "ERROR: Cannot determine NIC for Memory Node $MN_IP"
    exit 1
fi

CN_RDMA_DEV=""

for dev in /sys/class/infiniband/*; do
    [ -e "$dev" ] || continue

    if [ -d "$dev/device/net/$CN_NIC" ]; then
        CN_RDMA_DEV="$(basename "$dev")"
        break
    fi
done

if [ -z "$CN_RDMA_DEV" ]; then
    echo "ERROR: Cannot find RDMA device for NIC $CN_NIC"
    exit 1
fi


# ------------------------------------------------------------
# 6. Helper function for #define replacement
# ------------------------------------------------------------

set_define()
{
    local file="$1"
    local macro="$2"
    local value="$3"

    if ! grep -qE "^#define[[:space:]]+$macro([[:space:]]|$)" "$file"; then
        echo "ERROR: Cannot find #define $macro in $file"
        exit 1
    fi

    sed -Ei \
        "s|^#define[[:space:]]+$macro.*|#define $macro $value|" \
        "$file"
}


# ------------------------------------------------------------
# 7. Show requested configuration
# ------------------------------------------------------------

echo
echo "============================================================"
echo " MAGE GapBS rebuild"
echo "============================================================"
echo "Program             : $PROGRAM_NAME"
echo "Program digit       : $PROGRAM_DIGIT"
echo "Local memory        : $LOCAL_MEM_MIB MiB"
echo "Page size           : $PAGE_SIZE bytes"
echo "Pages per MiB       : $PAGES_PER_MIB"
echo "Local memory pages  : $LOCAL_MEM_PAGES"
echo "CN threads          : $NUM_CNTHREADS"
echo "Reclaim batch       : $RECLAIM_BATCH_SIZE"
echo "Cache pressure      : $CACHE_PRESSURE"
echo "Memory Node         : $MN_IP"
echo "CN NIC              : $CN_NIC"
echo "CN RDMA device      : $CN_RDMA_DEV"
echo "Build jobs          : $JOBS"
echo "============================================================"
echo


# ------------------------------------------------------------
# 8. Backup current configuration
# ------------------------------------------------------------

BACKUP_DIR="/root/mage-config-backup-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"

cp "$CONFIG_H" "$BACKUP_DIR/"
cp "$CNTHREAD_H" "$BACKUP_DIR/"
cp "$ROCE_H" "$BACKUP_DIR/"

echo "Configuration backup: $BACKUP_DIR"


# ------------------------------------------------------------
# 9. Apply MAGE experiment configuration
# ------------------------------------------------------------

set_define "$CONFIG_H" \
    TEST_PROGRAM_NAME "\"$PROGRAM_NAME\""

set_define "$CONFIG_H" \
    TEST_PROGRAM_DIGIT "$PROGRAM_DIGIT"

set_define "$CNTHREAD_H" \
    NUM_CNTHREADS "$NUM_CNTHREADS"

set_define "$CNTHREAD_H" \
    CNTHREAD_RECLAIM_BATCH_SIZE "$RECLAIM_BATCH_SIZE"

set_define "$CNTHREAD_H" \
    CNTHREAD_MAX_CACHE_BLOCK_NUMBER "${LOCAL_MEM_PAGES}UL"

set_define "$CNTHREAD_H" \
    CNTHREAD_CACHED_PRESSURE "$CACHE_PRESSURE"

set_define "$ROCE_H" \
    MIND_RDMA_IB_DEVNAME "\"$CN_RDMA_DEV\""


# ------------------------------------------------------------
# 10. Verify resulting configuration
# ------------------------------------------------------------

echo
echo "===== MAGE CONFIG ====="

grep -E \
    'TEST_PROGRAM_NAME|TEST_PROGRAM_DIGIT' \
    "$CONFIG_H"

grep -E \
    'NUM_CNTHREADS|CNTHREAD_RECLAIM_BATCH_SIZE|CNTHREAD_MAX_CACHE_BLOCK_NUMBER|CNTHREAD_CACHED_PRESSURE' \
    "$CNTHREAD_H"

grep 'MIND_RDMA_IB_DEVNAME' "$ROCE_H"


# ------------------------------------------------------------
# 11. Determine kernel release
# ------------------------------------------------------------

cd "$KERNEL_SRC"

KERNEL_RELEASE="$(make -s kernelrelease)"

echo
echo "===== KERNEL RELEASE ====="
echo "$KERNEL_RELEASE"

if [ "$KERNEL_RELEASE" != "$EXPECTED_KERNEL_RELEASE" ]; then
    echo
    echo "ERROR: Unexpected kernel release."
    echo "Expected : $EXPECTED_KERNEL_RELEASE"
    echo "Actual   : $KERNEL_RELEASE"
    exit 1
fi

MODULE_DIR="/lib/modules/$KERNEL_RELEASE"
E810_MODULE_DIR="$MODULE_DIR/extra/intel-e810"

BOOT_KERNEL="/boot/vmlinuz-$KERNEL_RELEASE"
BOOT_INITRAMFS="/boot/initramfs-$KERNEL_RELEASE.img"

TMP_INITRAMFS="/tmp/initramfs-$KERNEL_RELEASE.img"


# ------------------------------------------------------------
# 12. Build MAGE kernel
# ------------------------------------------------------------

echo
echo "===== BUILD MAGE KERNEL ====="

cd "$KERNEL_SRC"

make -j"$JOBS" bzImage modules

echo
echo "===== BUILD OUTPUT ====="

make kernelrelease

ls -lh \
    arch/x86/boot/bzImage \
    vmlinux \
    System.map \
    Module.symvers


# ------------------------------------------------------------
# 13. Install kernel modules
# ------------------------------------------------------------

echo
echo "===== INSTALL KERNEL MODULES ====="

make INSTALL_MOD_STRIP=1 modules_install


# ------------------------------------------------------------
# 14. Build ICE / intel_auxiliary
# ------------------------------------------------------------

echo
echo "===== BUILD ICE / INTEL_AUXILIARY ====="

cd "$ICE_SRC"

make \
    KSRC="$KERNEL_SRC" \
    BUILD_KERNEL="$KERNEL_RELEASE" \
    clean

make \
    KSRC="$KERNEL_SRC" \
    BUILD_KERNEL="$KERNEL_RELEASE" \
    -j"$JOBS"


# ------------------------------------------------------------
# 15. Build irdma
# ------------------------------------------------------------

echo
echo "===== BUILD IRDMA ====="

cd "$IRDMA_SRC"

KBUILD_EXTRA_SYMBOLS="$ICE_SRC/Module.symvers" \
KSRC="$KERNEL_SRC" \
BUILD_KERNEL="$KERNEL_RELEASE" \
./build.sh noinstall "$ICE_SRC"


# ------------------------------------------------------------
# 16. Verify Intel driver vermagic before installation
# ------------------------------------------------------------

echo
echo "===== VERIFY BUILT E810 MODULES ====="

modinfo "$ICE_SRC/intel_auxiliary.ko" | \
    grep -E '^(filename|version|vermagic):'

modinfo "$ICE_SRC/ice.ko" | \
    grep -E '^(filename|version|vermagic):'

modinfo "$IRDMA_SRC/src/irdma/irdma.ko" | \
    grep -E '^(filename|version|vermagic|depends):'


# ------------------------------------------------------------
# 17. Install Intel E810 modules
# ------------------------------------------------------------

echo
echo "===== INSTALL E810 MODULES ====="

mkdir -p "$E810_MODULE_DIR"

cp "$ICE_SRC/intel_auxiliary.ko" \
    "$E810_MODULE_DIR/"

cp "$ICE_SRC/ice.ko" \
    "$E810_MODULE_DIR/"

cp "$IRDMA_SRC/src/irdma/irdma.ko" \
    "$E810_MODULE_DIR/"

depmod -a "$KERNEL_RELEASE"


# ------------------------------------------------------------
# 18. Build MAGE RoCE module
# ------------------------------------------------------------

echo
echo "===== BUILD MAGE ROCE MODULE ====="

cd "$ROCE_SRC"

make clean
make -j"$JOBS"

echo
echo "===== VERIFY MAGE ROCE MODULE ====="

modinfo ./roce4disagg.ko | \
    grep -E '^(filename|vermagic):'


# ------------------------------------------------------------
# 19. Verify all module vermagic
# ------------------------------------------------------------

echo
echo "===== VERIFY INSTALLED MODULES ====="

modinfo -k "$KERNEL_RELEASE" ice | \
    grep -E '^(filename|version|vermagic):'

modinfo -k "$KERNEL_RELEASE" intel_auxiliary | \
    grep -E '^(filename|version|vermagic):'

modinfo -k "$KERNEL_RELEASE" irdma | \
    grep -E '^(filename|version|vermagic|depends):'


# ------------------------------------------------------------
# 20. Build initramfs
# ------------------------------------------------------------

echo
echo "===== BUILD INITRAMFS ====="

rm -f "$TMP_INITRAMFS"

dracut -f \
    --add-drivers "intel_auxiliary ice ib_core ib_uverbs rdma_cm iw_cm ib_cm" \
    "$TMP_INITRAMFS" \
    "$KERNEL_RELEASE"


# ------------------------------------------------------------
# 21. Verify initramfs
# ------------------------------------------------------------

echo
echo "===== VERIFY INITRAMFS ====="

lsinitrd "$TMP_INITRAMFS" | \
    grep -E \
    'intel_auxiliary\.ko|ice\.ko|ib_core\.ko|ib_uverbs\.ko|rdma_cm\.ko|iw_cm\.ko|ib_cm\.ko'


# ------------------------------------------------------------
# 22. Install kernel image + initramfs
# ------------------------------------------------------------

echo
echo "===== INSTALL BOOT FILES ====="

cp "$KERNEL_SRC/arch/x86/boot/bzImage" \
    "$BOOT_KERNEL"

cp "$TMP_INITRAMFS" \
    "$BOOT_INITRAMFS"

sync


# ------------------------------------------------------------
# 23. Create/update GRUB entry
# ------------------------------------------------------------

echo
echo "===== CONFIGURE GRUB ====="

MACHINE_ID="$(cat /etc/machine-id)"
BLS_ENTRY="/boot/loader/entries/${MACHINE_ID}-${KERNEL_RELEASE}.conf"

# Remove duplicate custom entries previously created by grubby
rm -f /boot/loader/entries/${MACHINE_ID}-${KERNEL_RELEASE}.*~custom.conf

if [[ -f "$BLS_ENTRY" ]]; then

    echo "Existing BLS entry found:"
    echo "  $BLS_ENTRY"

    # Keep exactly one canonical entry and update its contents.
    sed -i \
        -e "s|^title .*|title MAGE Linux ${KERNEL_RELEASE}|" \
        -e "s|^linux .*|linux /vmlinuz-${KERNEL_RELEASE}|" \
        -e "s|^initrd .*|initrd /initramfs-${KERNEL_RELEASE}.img|" \
        "$BLS_ENTRY"

    # Remove any existing cma=22G occurrences first.
    sed -i -E \
        '/^options / s/( cma=22G)+//g' \
        "$BLS_ENTRY"

    # Then add exactly one cma=22G.
    sed -i \
        '/^options / s/$/ cma=22G/' \
        "$BLS_ENTRY"

else

    echo "No existing BLS entry found."
    echo "Creating new GRUB entry."

    grubby \
        --add-kernel="$BOOT_KERNEL" \
        --initrd="$BOOT_INITRAMFS" \
        --title="MAGE Linux $KERNEL_RELEASE" \
        --copy-default \
        --args="cma=22G"

fi

grubby --set-default "$BOOT_KERNEL"

echo
echo "Current MAGE GRUB entry:"
grubby --info=ALL | grep -B5 -A5 "$KERNEL_RELEASE"


# ------------------------------------------------------------
# 24. Final verification
# ------------------------------------------------------------

echo
echo "===== FINAL VERIFY ====="

echo "Default kernel:"
grubby --default-kernel

echo
echo "MAGE kernel entry:"
grubby --info "$BOOT_KERNEL"

echo
echo "Kernel checksums:"
sha256sum \
    "$KERNEL_SRC/arch/x86/boot/bzImage" \
    "$BOOT_KERNEL"

echo
echo "RDMA device configured in MAGE:"
grep 'MIND_RDMA_IB_DEVNAME' "$ROCE_H"

echo
echo "============================================================"
echo " MAGE rebuild complete"
echo " Kernel      : $KERNEL_RELEASE"
echo " Local memory: $LOCAL_MEM_MIB MiB"
echo " CN threads  : $NUM_CNTHREADS"
echo " RDMA device : $CN_RDMA_DEV"
echo " Boot kernel : $BOOT_KERNEL"
echo "============================================================"


# ------------------------------------------------------------
# 25. Optional reboot
# ------------------------------------------------------------

if [ "$DO_REBOOT" -eq 1 ]; then
    echo
    echo "Rebooting..."
    sync
    reboot
else
    echo
    echo "Reboot was NOT requested."
    echo "When ready:"
    echo "  reboot"
fi
