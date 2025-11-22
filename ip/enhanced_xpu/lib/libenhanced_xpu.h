/* SPDX-FileCopyrightText: 2025 OpenWiFi Project
 * SPDX-License-Identifier: AGPL-3.0-only
 */

/**
 * @file libenhanced_xpu.h
 * @brief Userspace Library for Enhanced XPU
 *
 * This library provides a high-level interface for controlling the
 * Enhanced XPU hardware from userspace applications.
 *
 * @author OpenWiFi Team
 * @date 2025-11-22
 */

#ifndef _LIBENHANCED_XPU_H_
#define _LIBENHANCED_XPU_H_

#include <stdint.h>
#include <stdbool.h>
#include <sys/types.h>
#include "../driver/enhanced_xpu_ioctl.h"
#include "../include/remote_id_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ========================================================================
 * Library Context
 * ======================================================================== */

/**
 * @brief XPU device handle
 */
typedef struct xpu_handle_s *xpu_handle_t;

/* ========================================================================
 * Device Management
 * ======================================================================== */

/**
 * @brief Open XPU device
 *
 * @param device_path Path to device node (default: /dev/enhanced_xpu)
 * @return Device handle on success, NULL on error
 */
xpu_handle_t xpu_open(const char *device_path);

/**
 * @brief Close XPU device
 *
 * @param handle Device handle
 */
void xpu_close(xpu_handle_t handle);

/**
 * @brief Get file descriptor for select/poll
 *
 * @param handle Device handle
 * @return File descriptor, or -1 on error
 */
int xpu_get_fd(xpu_handle_t handle);

/* ========================================================================
 * Configuration
 * ======================================================================== */

/**
 * @brief Set XPU configuration
 *
 * @param handle Device handle
 * @param config Configuration structure
 * @return 0 on success, -1 on error
 */
int xpu_set_config(xpu_handle_t handle, const struct xpu_config *config);

/**
 * @brief Get XPU configuration
 *
 * @param handle Device handle
 * @param config Output configuration structure
 * @return 0 on success, -1 on error
 */
int xpu_get_config(xpu_handle_t handle, struct xpu_config *config);

/**
 * @brief Reset XPU hardware
 *
 * @param handle Device handle
 * @return 0 on success, -1 on error
 */
int xpu_reset(xpu_handle_t handle);

/* ========================================================================
 * Monitor Mode
 * ======================================================================== */

/**
 * @brief Enable/disable monitor mode
 *
 * @param handle Device handle
 * @param enable True to enable, false to disable
 * @return 0 on success, -1 on error
 */
int xpu_set_monitor_mode(xpu_handle_t handle, bool enable);

/**
 * @brief Configure packet filters
 *
 * @param handle Device handle
 * @param filter Filter configuration
 * @return 0 on success, -1 on error
 */
int xpu_configure_filters(xpu_handle_t handle,
                          const struct xpu_filter_config *filter);

/**
 * @brief Receive captured packet
 *
 * @param handle Device handle
 * @param buffer Output buffer for packet data
 * @param buffer_size Size of output buffer
 * @param timeout_ms Timeout in milliseconds (0 = non-blocking, -1 = blocking)
 * @return Number of bytes received, or -1 on error
 */
ssize_t xpu_receive_packet(xpu_handle_t handle,
                           void *buffer,
                           size_t buffer_size,
                           int timeout_ms);

/* ========================================================================
 * Frame Injection
 * ======================================================================== */

/**
 * @brief Enable/disable frame injection mode
 *
 * @param handle Device handle
 * @param enable True to enable, false to disable
 * @return 0 on success, -1 on error
 */
int xpu_set_inject_mode(xpu_handle_t handle, bool enable);

/**
 * @brief Inject 802.11 frame
 *
 * @param handle Device handle
 * @param frame Pointer to 802.11 frame data
 * @param frame_len Length of frame
 * @param params TX parameters (NULL for defaults)
 * @return Number of bytes transmitted, or -1 on error
 */
ssize_t xpu_inject_frame(xpu_handle_t handle,
                         const void *frame,
                         size_t frame_len,
                         const struct xpu_tx_params *params);

/* ========================================================================
 * Statistics
 * ======================================================================== */

/**
 * @brief Get XPU statistics
 *
 * @param handle Device handle
 * @param stats Output statistics structure
 * @return 0 on success, -1 on error
 */
int xpu_get_stats(xpu_handle_t handle, struct xpu_stats *stats);

/**
 * @brief Reset statistics counters
 *
 * @param handle Device handle
 * @return 0 on success, -1 on error
 */
int xpu_reset_stats(xpu_handle_t handle);

/* ========================================================================
 * Remote ID Functions
 * ======================================================================== */

/**
 * @brief Enable/disable Remote ID transmission
 *
 * @param handle Device handle
 * @param config Remote ID configuration
 * @return 0 on success, -1 on error
 */
int xpu_set_remote_id(xpu_handle_t handle,
                      const struct xpu_remote_id_config *config);

/**
 * @brief Encode Remote ID message to NAN frame
 *
 * Wrapper around remote_id_encode_nan_frame() with error handling.
 *
 * @param msg Remote ID message
 * @param frame_buffer Output buffer for NAN frame
 * @param buffer_size Size of output buffer
 * @return Length of encoded frame, or -1 on error
 */
int xpu_remote_id_encode(const remote_id_message_t *msg,
                         void *frame_buffer,
                         size_t buffer_size);

/**
 * @brief Decode Remote ID message from NAN frame
 *
 * Wrapper around remote_id_decode_nan_frame() with error handling.
 *
 * @param frame_buffer NAN frame data
 * @param frame_len Length of frame
 * @param msg Output Remote ID message
 * @return 0 on success, -1 on error
 */
int xpu_remote_id_decode(const void *frame_buffer,
                         size_t frame_len,
                         remote_id_message_t *msg);

/**
 * @brief Transmit Remote ID message
 *
 * Encodes and transmits a Remote ID message as NAN frame.
 *
 * @param handle Device handle
 * @param msg Remote ID message
 * @return 0 on success, -1 on error
 */
int xpu_remote_id_transmit(xpu_handle_t handle,
                           const remote_id_message_t *msg);

/**
 * @brief Format Remote ID message as human-readable string
 *
 * @param msg Remote ID message
 * @param buffer Output buffer
 * @param buffer_size Size of buffer
 * @return 0 on success, -1 on error
 */
int xpu_remote_id_format(const remote_id_message_t *msg,
                         char *buffer,
                         size_t buffer_size);

/* ========================================================================
 * Utility Functions
 * ======================================================================== */

/**
 * @brief Get last error message
 *
 * @return Error message string
 */
const char *xpu_get_error(void);

/**
 * @brief Set library debug level
 *
 * @param level Debug level (0=none, 1=error, 2=warning, 3=info, 4=debug)
 */
void xpu_set_debug_level(int level);

/**
 * @brief Parse MAC address from string
 *
 * @param str MAC address string (e.g., "00:11:22:33:44:55")
 * @param mac_addr Output MAC address (6 bytes)
 * @return 0 on success, -1 on error
 */
int xpu_parse_mac_address(const char *str, uint8_t mac_addr[6]);

/**
 * @brief Format MAC address as string
 *
 * @param mac_addr MAC address (6 bytes)
 * @param str Output string buffer (min 18 bytes)
 * @return 0 on success, -1 on error
 */
int xpu_format_mac_address(const uint8_t mac_addr[6], char *str);

#ifdef __cplusplus
}
#endif

#endif /* _LIBENHANCED_XPU_H_ */
