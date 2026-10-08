#!/bin/bash

set -Eeuo pipefail

# ============================================================
# MAGE Kernel Build / Install Script for AMD2
#
# This script performs:
#   1. Kernel config normalization
#   2. Kernel + in-tree modules build
#   3. modules_install
#   4. Intel ICE 1.13.7 rebuild
#   5. Intel irdma 1.13.43 rebuild
#   6. External Intel E810 module installation
#   7. depmod
#   8. Custom initramfs generation
#   9. Kernel + initramfs copy to /boot
#
# This script DOES NOT:
#   - modify CONFIG options
#   - register GRUB entries
#   - change default kernel
#   - reboot
# ============================================================

KERNEL_SRC="/root/workspace_ych/mage/mage-kernel/mind_linux"
ICE_SRC="/root/ice-mage415-1.13.7/src"
IRDMA_ROOT="/root/irdma-srpm/kmod-irdma-1.13.43"

JOBS="$(nproc)"

LOG_DIR="/root/workspace_ych/mage/build-logs"
mkdir -p "$LOG_DIR"

LOG_FILE="${LOG_DIR}/build-$(date +%Y%m%d-%H%M%S).log"

exec > >(tee "$LOG_FILE") 2>&1

trap 'echo; echo "[ERROR] Build failed at line ${LINENO}"; echo "[ERROR] Log: ${LOG_FILE}"' ERR


echo "============================================================"
echo " MAGE Kernel Build"
echo "============================================================"
echo
echo "Kernel source : $KERNEL_SRC"
echo "ICE source    : $ICE_SRC"
echo "irdma source  : $IRDMA_ROOT"
echo "Build jobs    : $JOBS"
echo "Log           : $LOG_FILE"
echo


# ------------------------------------------------------------
# Sanity checks
# ------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] Run this script as root."
    exit 1
fi

if [ ! -f "$KERNEL_SRC/Makefile" ]; then
    echo "[ERROR] Kernel source not found: $KERNEL_SRC"
    exit 1
fi

if [ ! -f "$ICE_SRC/Makefile" ]; then
    echo "[ERROR] ICE source not found: $ICE_SRC"
    exit 1
fi

if [ ! -f "$IRDMA_ROOT/build.sh" ]; then
    echo "[ERROR] irdma source not found: $IRDMA_ROOT"
    exit 1
fi


# ------------------------------------------------------------
# 1. Kernel config / release 확인
# ------------------------------------------------------------

echo
echo "============================================================"
echo "[1/9] Kernel configuration"
echo "============================================================"

cd "$KERNEL_SRC"

make olddefconfig

KREL="$(make -s kernelrelease)"

if [ -z "$KREL" ]; then
    echo "[ERROR] Could not determine kernel release."
    exit 1
fi

echo
echo "Kernel release: $KREL"

if grep -q '^CONFIG_NR_CPUS=' .config; then
    grep '^CONFIG_NR_CPUS=' .config
fi

if grep -q '^CONFIG_LOCALVERSION=' .config; then
    grep '^CONFIG_LOCALVERSION=' .config
fi


# ------------------------------------------------------------
# 2. Kernel build
# ------------------------------------------------------------

echo
echo "============================================================"
echo "[2/9] Building kernel and modules"
echo "============================================================"

make -j"$JOBS" bzImage modules

echo
echo "[OK] Kernel build completed"
echo "bzImage: $KERNEL_SRC/arch/x86/boot/bzImage"


# ------------------------------------------------------------
# 3. Kernel modules_install
# ------------------------------------------------------------

echo
echo "============================================================"
echo "[3/9] Installing kernel modules"
echo "============================================================"

make INSTALL_MOD_STRIP=1 modules_install

if [ ! -d "/lib/modules/$KREL" ]; then
    echo "[ERROR] /lib/modules/$KREL was not created."
    exit 1
fi

echo "[OK] /lib/modules/$KREL"


# ------------------------------------------------------------
# 4. Intel ICE 1.13.7 build
# ------------------------------------------------------------

echo
echo "============================================================"
echo "[4/9] Building Intel ICE 1.13.7"
echo "============================================================"

cd "$ICE_SRC"

make \
    KSRC="$KERNEL_SRC" \
    BUILD_KERNEL="$KREL" \
    clean

make \
    KSRC="$KERNEL_SRC" \
    BUILD_KERNEL="$KREL" \
    -j"$JOBS"

if [ ! -f "$ICE_SRC/ice.ko" ]; then
    echo "[ERROR] ice.ko was not generated."
    exit 1
fi

if [ ! -f "$ICE_SRC/intel_auxiliary.ko" ]; then
    echo "[ERROR] intel_auxiliary.ko was not generated."
    exit 1
fi

echo
modinfo "$ICE_SRC/ice.ko" | grep -E '^(version|depends|vermagic):'


# ------------------------------------------------------------
# 5. Intel irdma 1.13.43 build
# ------------------------------------------------------------

echo
echo "============================================================"
echo "[5/9] Building Intel irdma 1.13.43"
echo "============================================================"

cd "$IRDMA_ROOT"

KBUILD_EXTRA_SYMBOLS="$ICE_SRC/Module.symvers" \
KSRC="$KERNEL_SRC" \
BUILD_KERNEL="$KREL" \
./build.sh noinstall "$ICE_SRC"

IRDMA_KO="$IRDMA_ROOT/src/irdma/irdma.ko"

if [ ! -f "$IRDMA_KO" ]; then
    echo "[ERROR] irdma.ko was not generated."
    exit 1
fi

echo
modinfo "$IRDMA_KO" | grep -E '^(version|depends|vermagic):'


# ------------------------------------------------------------
# 6. Install Intel E810 modules
# ------------------------------------------------------------

echo
echo "============================================================"
echo "[6/9] Installing Intel E810 modules"
echo "============================================================"

INTEL_MODULE_DIR="/lib/modules/$KREL/extra/intel-e810"

mkdir -p "$INTEL_MODULE_DIR"

cp "$ICE_SRC/intel_auxiliary.ko" \
   "$INTEL_MODULE_DIR/"

cp "$ICE_SRC/ice.ko" \
   "$INTEL_MODULE_DIR/"

cp "$IRDMA_KO" \
   "$INTEL_MODULE_DIR/"

depmod -a "$KREL"

echo
echo "Installed modules:"

modinfo -k "$KREL" ice | \
    grep -E '^(filename|version|vermagic):'

echo

modinfo -k "$KREL" irdma | \
    grep -E '^(filename|version|vermagic):'


# ------------------------------------------------------------
# 7. Generate custom initramfs
# ------------------------------------------------------------

echo
echo "============================================================"
echo "[7/9] Generating initramfs"
echo "============================================================"

INITRAMFS_TMP="/tmp/initramfs-${KREL}.img"

dracut -f \
    --add-drivers "intel_auxiliary ice irdma ib_core ib_uverbs rdma_cm iw_cm ib_cm" \
    "$INITRAMFS_TMP" \
    "$KREL"

if [ ! -f "$INITRAMFS_TMP" ]; then
    echo "[ERROR] initramfs generation failed."
    exit 1
fi

echo
echo "Checking RDMA modules in initramfs..."

for MOD in intel_auxiliary ice irdma ib_core ib_uverbs rdma_cm iw_cm ib_cm
do
    if ! lsinitrd "$INITRAMFS_TMP" | grep -q "/${MOD}\.ko"; then
        echo "[ERROR] ${MOD}.ko is missing from initramfs."
        exit 1
    fi
    echo "[OK] $MOD"
done


# ------------------------------------------------------------
# 8. Check /boot space
# ------------------------------------------------------------

echo
echo "============================================================"
echo "[8/9] Checking /boot space"
echo "============================================================"

VMLINUX_SRC="$KERNEL_SRC/arch/x86/boot/bzImage"

BOOT_KERNEL="/boot/vmlinuz-${KREL}"
BOOT_INITRAMFS="/boot/initramfs-${KREL}.img"

NEW_KERNEL_SIZE="$(stat -c %s "$VMLINUX_SRC")"
NEW_INITRAMFS_SIZE="$(stat -c %s "$INITRAMFS_TMP")"

OLD_KERNEL_SIZE=0
OLD_INITRAMFS_SIZE=0

if [ -f "$BOOT_KERNEL" ]; then
    OLD_KERNEL_SIZE="$(stat -c %s "$BOOT_KERNEL")"
fi

if [ -f "$BOOT_INITRAMFS" ]; then
    OLD_INITRAMFS_SIZE="$(stat -c %s "$BOOT_INITRAMFS")"
fi

KERNEL_EXTRA=$((NEW_KERNEL_SIZE - OLD_KERNEL_SIZE))
INITRAMFS_EXTRA=$((NEW_INITRAMFS_SIZE - OLD_INITRAMFS_SIZE))

if [ "$KERNEL_EXTRA" -lt 0 ]; then
    KERNEL_EXTRA=0
fi

if [ "$INITRAMFS_EXTRA" -lt 0 ]; then
    INITRAMFS_EXTRA=0
fi

# Additional 5 MiB safety margin
REQUIRED=$((KERNEL_EXTRA + INITRAMFS_EXTRA + 5 * 1024 * 1024))
AVAILABLE="$(df -B1 --output=avail /boot | tail -n 1 | tr -d ' ')"

echo "Available /boot : $((AVAILABLE / 1024 / 1024)) MiB"
echo "Required        : $((REQUIRED / 1024 / 1024)) MiB"

if [ "$AVAILABLE" -lt "$REQUIRED" ]; then
    echo
    echo "[ERROR] Not enough space in /boot."
    echo
    df -h /boot
    exit 1
fi


# ------------------------------------------------------------
# 9. Install kernel + initramfs to /boot
# ------------------------------------------------------------

echo
echo "============================================================"
echo "[9/9] Installing boot images"
echo "============================================================"

cp -f "$VMLINUX_SRC" "$BOOT_KERNEL"
cp -f "$INITRAMFS_TMP" "$BOOT_INITRAMFS"

sync

echo
ls -lh "$BOOT_KERNEL"
ls -lh "$BOOT_INITRAMFS"


# ------------------------------------------------------------
# Final verification
# ------------------------------------------------------------

echo
echo "============================================================"
echo " BUILD COMPLETE"
echo "============================================================"
echo
echo "Kernel release:"
echo "  $KREL"
echo
echo "Kernel:"
echo "  $BOOT_KERNEL"
echo
echo "Initramfs:"
echo "  $BOOT_INITRAMFS"
echo
echo "Modules:"
echo "  /lib/modules/$KREL"
echo
echo "Log:"
echo "  $LOG_FILE"
echo
echo "NOTE:"
echo "  GRUB was NOT modified."
echo "  Default kernel was NOT changed."
echo "  System was NOT rebooted."
echo
echo "Next step:"
echo "  Register/select this kernel with grubby if necessary."
echo "============================================================"
