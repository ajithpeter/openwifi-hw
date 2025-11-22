/* SPDX-FileCopyrightText: 2025 OpenWiFi Project
 * SPDX-License-Identifier: AGPL-3.0-only
 */

/**
 * @file enhanced_xpu_ioctl.h
 * @brief IOCTL Interface for Enhanced XPU Driver
 *
 * This header defines the IOCTL commands and data structures for
 * userspace communication with the Enhanced XPU kernel driver.
 *
 * @author OpenWiFi Team
 * @date 2025-11-22
 */

#ifndef _ENHANCED_XPU_IOCTL_H_
#define _ENHANCED_XPU_IOCTL_H_

#include <linux/types.h>
#include <linux/ioctl.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ========================================================================
 * Configuration Structures
 * ======================================================================== */

/**
 * @brief XPU configuration
 */
struct xpu_config {
    __u32 flags;                /* Configuration flags */
    __u32 rx_buffer_size;       /* RX buffer size */
    __u32 tx_buffer_size;       /* TX buffer size */
    __u32 channel;              /* WiFi channel */
    __u32 bandwidth;            /* Bandwidth (MHz): 20, 40, 80, 160 */
    __u32 tx_power;             /* TX power (dBm) */
    __u32 reserved[10];         /* Reserved for future use */
};

/* Configuration flags */
#define XPU_CONFIG_MONITOR      (1 << 0)  /* Enable monitor mode */
#define XPU_CONFIG_INJECT       (1 << 1)  /* Enable injection mode */
#define XPU_CONFIG_PROMISCUOUS  (1 << 2)  /* Promiscuous mode */
#define XPU_CONFIG_REMOTE_ID    (1 << 3)  /* Remote ID enabled */

/**
 * @brief Packet filter configuration
 */
struct xpu_filter_config {
    __u32 flags;                /* Filter flags */
    __u8  mac_addr[6];          /* MAC address filter */
    __u8  bssid[6];             /* BSSID filter */
    __u32 frame_type_mask;      /* Frame type mask */
    __u32 reserved[8];          /* Reserved */
};

/* Filter flags */
#define XPU_FILTER_MAC_ADDR     (1 << 0)  /* Filter by MAC address */
#define XPU_FILTER_BSSID        (1 << 1)  /* Filter by BSSID */
#define XPU_FILTER_FRAME_TYPE   (1 << 2)  /* Filter by frame type */
#define XPU_FILTER_MANAGEMENT   (1 << 3)  /* Management frames only */
#define XPU_FILTER_DATA         (1 << 4)  /* Data frames only */
#define XPU_FILTER_CONTROL      (1 << 5)  /* Control frames only */

/* Frame type masks */
#define XPU_FRAME_BEACON        (1 << 0)
#define XPU_FRAME_PROBE_REQ     (1 << 1)
#define XPU_FRAME_PROBE_RESP    (1 << 2)
#define XPU_FRAME_DATA          (1 << 3)
#define XPU_FRAME_QOS_DATA      (1 << 4)
#define XPU_FRAME_ACTION        (1 << 5)
#define XPU_FRAME_NAN           (1 << 6)

/**
 * @brief Statistics
 */
struct xpu_stats {
    __u64 rx_packets;           /* Received packets */
    __u64 rx_bytes;             /* Received bytes */
    __u64 rx_dropped;           /* Dropped packets */
    __u64 tx_packets;           /* Transmitted packets */
    __u64 tx_bytes;             /* Transmitted bytes */
    __u64 tx_errors;            /* TX errors */
    __u64 errors;               /* General errors */
    __u64 remote_id_rx;         /* Remote ID messages received */
    __u64 remote_id_tx;         /* Remote ID messages transmitted */
    __u32 reserved[16];         /* Reserved */
};

/**
 * @brief TX parameters for frame injection
 */
struct xpu_tx_params {
    __u32 rate;                 /* TX rate (Mbps) */
    __s32 power;                /* TX power (dBm) */
    __u32 retries;              /* Number of retries */
    __u32 flags;                /* TX flags */
    __u32 reserved[4];          /* Reserved */
};

#define XPU_TX_NO_ACK           (1 << 0)  /* Don't wait for ACK */
#define XPU_TX_USE_CTS_PROTECT  (1 << 1)  /* Use CTS protection */
#define XPU_TX_USE_RTS_CTS      (1 << 2)  /* Use RTS/CTS */

/**
 * @brief Remote ID configuration
 */
struct xpu_remote_id_config {
    __u32 enabled;              /* Enable Remote ID */
    __u32 tx_interval_ms;       /* TX interval (ms), typically 1000 */
    __u8  uas_id[20];           /* UAS ID */
    __u8  operator_id[20];      /* Operator ID */
    __u32 reserved[8];          /* Reserved */
};

/* ========================================================================
 * IOCTL Commands
 * ======================================================================== */

#define XPU_IOC_MAGIC  'X'

/* Configuration */
#define XPU_IOC_SET_CONFIG      _IOW(XPU_IOC_MAGIC, 1, struct xpu_config)
#define XPU_IOC_GET_CONFIG      _IOR(XPU_IOC_MAGIC, 2, struct xpu_config)

/* Mode control */
#define XPU_IOC_SET_MONITOR     _IOW(XPU_IOC_MAGIC, 3, int)
#define XPU_IOC_SET_INJECT      _IOW(XPU_IOC_MAGIC, 4, int)

/* Filtering */
#define XPU_IOC_SET_FILTER      _IOW(XPU_IOC_MAGIC, 5, struct xpu_filter_config)
#define XPU_IOC_GET_FILTER      _IOR(XPU_IOC_MAGIC, 6, struct xpu_filter_config)

/* Statistics */
#define XPU_IOC_GET_STATS       _IOR(XPU_IOC_MAGIC, 7, struct xpu_stats)
#define XPU_IOC_RESET_STATS     _IO(XPU_IOC_MAGIC, 8)

/* TX parameters */
#define XPU_IOC_SET_TX_PARAMS   _IOW(XPU_IOC_MAGIC, 9, struct xpu_tx_params)
#define XPU_IOC_GET_TX_PARAMS   _IOR(XPU_IOC_MAGIC, 10, struct xpu_tx_params)

/* Remote ID */
#define XPU_IOC_SET_REMOTE_ID   _IOW(XPU_IOC_MAGIC, 11, struct xpu_remote_id_config)
#define XPU_IOC_GET_REMOTE_ID   _IOR(XPU_IOC_MAGIC, 12, struct xpu_remote_id_config)

/* Hardware control */
#define XPU_IOC_RESET           _IO(XPU_IOC_MAGIC, 20)

#ifdef __cplusplus
}
#endif

#endif /* _ENHANCED_XPU_IOCTL_H_ */
