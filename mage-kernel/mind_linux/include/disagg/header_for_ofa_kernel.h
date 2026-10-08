#ifndef __OFA_KERNEL_HEADER_FIX__
#define __OFA_KERNEL_HEADER_FIX__

/*
 * Intel E810 / native Linux 4.15 RDMA build.
 *
 * The original Mage artifact pulled RDMA headers from MLNX_OFED using
 * absolute paths under /usr/src/ofa_kernel/default.
 * We use the RDMA headers provided by the Mage Linux 4.15 tree instead.
 */

#include <rdma/ib_verbs.h>
#include <rdma/rdma_cm.h>

#endif
