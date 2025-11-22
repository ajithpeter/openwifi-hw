/* SPDX-FileCopyrightText: 2025 OpenWiFi Project
 * SPDX-License-Identifier: AGPL-3.0-only
 */

/**
 * @file libenhanced_xpu.c
 * @brief Userspace Library Implementation for Enhanced XPU
 *
 * @author OpenWiFi Team
 * @date 2025-11-22
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <poll.h>
#include "libenhanced_xpu.h"

/* ========================================================================
 * Internal Structures
 * ======================================================================== */

struct xpu_handle_s {
    int fd;                     /* Device file descriptor */
    char device_path[256];      /* Device path */
    struct xpu_config config;   /* Current configuration */
    struct xpu_stats stats;     /* Statistics */
    char error_msg[256];        /* Last error message */
};

/* Global error message (for non-handle errors) */
static char global_error[256] = {0};

/* Debug level */
static int debug_level = 1;  /* Default: errors only */

/* ========================================================================
 * Debug/Error Handling
 * ======================================================================== */

#define XPU_ERROR(handle, fmt, ...) do { \
    snprintf((handle) ? (handle)->error_msg : global_error, 256, \
             fmt, ##__VA_ARGS__); \
    if (debug_level >= 1) \
        fprintf(stderr, "[XPU ERROR] " fmt "\n", ##__VA_ARGS__); \
} while (0)

#define XPU_WARN(fmt, ...) do { \
    if (debug_level >= 2) \
        fprintf(stderr, "[XPU WARN] " fmt "\n", ##__VA_ARGS__); \
} while (0)

#define XPU_INFO(fmt, ...) do { \
    if (debug_level >= 3) \
        fprintf(stderr, "[XPU INFO] " fmt "\n", ##__VA_ARGS__); \
} while (0)

#define XPU_DEBUG(fmt, ...) do { \
    if (debug_level >= 4) \
        fprintf(stderr, "[XPU DEBUG] " fmt "\n", ##__VA_ARGS__); \
} while (0)

void xpu_set_debug_level(int level)
{
    debug_level = level;
}

const char *xpu_get_error(void)
{
    return global_error;
}

/* ========================================================================
 * Device Management
 * ======================================================================== */

xpu_handle_t xpu_open(const char *device_path)
{
    struct xpu_handle_s *handle;
    int fd;

    if (!device_path)
        device_path = "/dev/enhanced_xpu";

    XPU_INFO("Opening XPU device: %s", device_path);

    fd = open(device_path, O_RDWR);
    if (fd < 0) {
        XPU_ERROR(NULL, "Failed to open %s: %s", device_path, strerror(errno));
        return NULL;
    }

    handle = calloc(1, sizeof(*handle));
    if (!handle) {
        XPU_ERROR(NULL, "Failed to allocate handle: %s", strerror(errno));
        close(fd);
        return NULL;
    }

    handle->fd = fd;
    strncpy(handle->device_path, device_path, sizeof(handle->device_path) - 1);

    /* Get initial configuration */
    if (ioctl(fd, XPU_IOC_GET_CONFIG, &handle->config) < 0) {
        XPU_WARN("Failed to get initial config: %s", strerror(errno));
    }

    XPU_INFO("XPU device opened successfully (fd=%d)", fd);
    return handle;
}

void xpu_close(xpu_handle_t handle)
{
    if (!handle)
        return;

    XPU_INFO("Closing XPU device (fd=%d)", handle->fd);

    /* Disable monitor and inject modes */
    xpu_set_monitor_mode(handle, false);
    xpu_set_inject_mode(handle, false);

    close(handle->fd);
    free(handle);
}

int xpu_get_fd(xpu_handle_t handle)
{
    if (!handle) {
        XPU_ERROR(NULL, "Invalid handle");
        return -1;
    }

    return handle->fd;
}

/* ========================================================================
 * Configuration
 * ======================================================================== */

int xpu_set_config(xpu_handle_t handle, const struct xpu_config *config)
{
    if (!handle || !config) {
        XPU_ERROR(handle, "Invalid arguments");
        return -1;
    }

    if (ioctl(handle->fd, XPU_IOC_SET_CONFIG, config) < 0) {
        XPU_ERROR(handle, "Failed to set config: %s", strerror(errno));
        return -1;
    }

    memcpy(&handle->config, config, sizeof(*config));
    XPU_DEBUG("Configuration updated");
    return 0;
}

int xpu_get_config(xpu_handle_t handle, struct xpu_config *config)
{
    if (!handle || !config) {
        XPU_ERROR(handle, "Invalid arguments");
        return -1;
    }

    if (ioctl(handle->fd, XPU_IOC_GET_CONFIG, config) < 0) {
        XPU_ERROR(handle, "Failed to get config: %s", strerror(errno));
        return -1;
    }

    memcpy(&handle->config, config, sizeof(*config));
    return 0;
}

int xpu_reset(xpu_handle_t handle)
{
    if (!handle) {
        XPU_ERROR(NULL, "Invalid handle");
        return -1;
    }

    XPU_INFO("Resetting XPU hardware");

    if (ioctl(handle->fd, XPU_IOC_RESET) < 0) {
        XPU_ERROR(handle, "Failed to reset: %s", strerror(errno));
        return -1;
    }

    return 0;
}

/* ========================================================================
 * Monitor Mode
 * ======================================================================== */

int xpu_set_monitor_mode(xpu_handle_t handle, bool enable)
{
    if (!handle) {
        XPU_ERROR(NULL, "Invalid handle");
        return -1;
    }

    XPU_INFO("Setting monitor mode: %s", enable ? "enabled" : "disabled");

    if (ioctl(handle->fd, XPU_IOC_SET_MONITOR, enable ? 1 : 0) < 0) {
        XPU_ERROR(handle, "Failed to set monitor mode: %s", strerror(errno));
        return -1;
    }

    return 0;
}

int xpu_configure_filters(xpu_handle_t handle,
                          const struct xpu_filter_config *filter)
{
    if (!handle || !filter) {
        XPU_ERROR(handle, "Invalid arguments");
        return -1;
    }

    XPU_DEBUG("Configuring packet filters (flags=0x%x)", filter->flags);

    if (ioctl(handle->fd, XPU_IOC_SET_FILTER, filter) < 0) {
        XPU_ERROR(handle, "Failed to set filter: %s", strerror(errno));
        return -1;
    }

    return 0;
}

ssize_t xpu_receive_packet(xpu_handle_t handle,
                           void *buffer,
                           size_t buffer_size,
                           int timeout_ms)
{
    ssize_t ret;
    struct pollfd pfd;

    if (!handle || !buffer || buffer_size == 0) {
        XPU_ERROR(handle, "Invalid arguments");
        return -1;
    }

    /* Check for data with timeout */
    if (timeout_ms >= 0) {
        pfd.fd = handle->fd;
        pfd.events = POLLIN;

        ret = poll(&pfd, 1, timeout_ms);
        if (ret < 0) {
            XPU_ERROR(handle, "Poll failed: %s", strerror(errno));
            return -1;
        }
        if (ret == 0) {
            /* Timeout */
            errno = EAGAIN;
            return -1;
        }
    }

    /* Read packet */
    ret = read(handle->fd, buffer, buffer_size);
    if (ret < 0) {
        if (errno != EAGAIN)
            XPU_ERROR(handle, "Read failed: %s", strerror(errno));
        return -1;
    }

    XPU_DEBUG("Received packet: %zd bytes", ret);
    return ret;
}

/* ========================================================================
 * Frame Injection
 * ======================================================================== */

int xpu_set_inject_mode(xpu_handle_t handle, bool enable)
{
    if (!handle) {
        XPU_ERROR(NULL, "Invalid handle");
        return -1;
    }

    XPU_INFO("Setting inject mode: %s", enable ? "enabled" : "disabled");

    if (ioctl(handle->fd, XPU_IOC_SET_INJECT, enable ? 1 : 0) < 0) {
        XPU_ERROR(handle, "Failed to set inject mode: %s", strerror(errno));
        return -1;
    }

    return 0;
}

ssize_t xpu_inject_frame(xpu_handle_t handle,
                         const void *frame,
                         size_t frame_len,
                         const struct xpu_tx_params *params)
{
    ssize_t ret;

    if (!handle || !frame || frame_len == 0) {
        XPU_ERROR(handle, "Invalid arguments");
        return -1;
    }

    /* Set TX parameters if provided */
    if (params) {
        if (ioctl(handle->fd, XPU_IOC_SET_TX_PARAMS, params) < 0) {
            XPU_WARN("Failed to set TX params: %s", strerror(errno));
        }
    }

    XPU_DEBUG("Injecting frame: %zu bytes", frame_len);

    /* Write frame to device */
    ret = write(handle->fd, frame, frame_len);
    if (ret < 0) {
        XPU_ERROR(handle, "Frame injection failed: %s", strerror(errno));
        return -1;
    }

    if ((size_t)ret != frame_len) {
        XPU_WARN("Partial write: %zd/%zu bytes", ret, frame_len);
    }

    return ret;
}

/* ========================================================================
 * Statistics
 * ======================================================================== */

int xpu_get_stats(xpu_handle_t handle, struct xpu_stats *stats)
{
    if (!handle || !stats) {
        XPU_ERROR(handle, "Invalid arguments");
        return -1;
    }

    if (ioctl(handle->fd, XPU_IOC_GET_STATS, stats) < 0) {
        XPU_ERROR(handle, "Failed to get stats: %s", strerror(errno));
        return -1;
    }

    memcpy(&handle->stats, stats, sizeof(*stats));
    return 0;
}

int xpu_reset_stats(xpu_handle_t handle)
{
    if (!handle) {
        XPU_ERROR(NULL, "Invalid handle");
        return -1;
    }

    if (ioctl(handle->fd, XPU_IOC_RESET_STATS) < 0) {
        XPU_ERROR(handle, "Failed to reset stats: %s", strerror(errno));
        return -1;
    }

    return 0;
}

/* ========================================================================
 * Remote ID Functions
 * ======================================================================== */

int xpu_set_remote_id(xpu_handle_t handle,
                      const struct xpu_remote_id_config *config)
{
    if (!handle || !config) {
        XPU_ERROR(handle, "Invalid arguments");
        return -1;
    }

    XPU_INFO("Setting Remote ID: %s", config->enabled ? "enabled" : "disabled");

    if (ioctl(handle->fd, XPU_IOC_SET_REMOTE_ID, config) < 0) {
        XPU_ERROR(handle, "Failed to set Remote ID config: %s", strerror(errno));
        return -1;
    }

    return 0;
}

int xpu_remote_id_encode(const remote_id_message_t *msg,
                         void *frame_buffer,
                         size_t buffer_size)
{
    int ret;

    if (!msg || !frame_buffer || buffer_size == 0) {
        XPU_ERROR(NULL, "Invalid arguments");
        return -1;
    }

    ret = remote_id_encode_nan_frame(msg, frame_buffer, buffer_size);
    if (ret < 0) {
        XPU_ERROR(NULL, "Failed to encode Remote ID message");
        return -1;
    }

    XPU_DEBUG("Encoded Remote ID message: %d bytes", ret);
    return ret;
}

int xpu_remote_id_decode(const void *frame_buffer,
                         size_t frame_len,
                         remote_id_message_t *msg)
{
    int ret;

    if (!frame_buffer || frame_len == 0 || !msg) {
        XPU_ERROR(NULL, "Invalid arguments");
        return -1;
    }

    ret = remote_id_decode_nan_frame(frame_buffer, frame_len, msg);
    if (ret < 0) {
        XPU_DEBUG("Failed to decode Remote ID message");
        return -1;
    }

    XPU_DEBUG("Decoded Remote ID message type %d", msg->msg_type);
    return 0;
}

int xpu_remote_id_transmit(xpu_handle_t handle,
                           const remote_id_message_t *msg)
{
    uint8_t frame_buffer[512];
    int frame_len;

    if (!handle || !msg) {
        XPU_ERROR(handle, "Invalid arguments");
        return -1;
    }

    /* Encode message */
    frame_len = xpu_remote_id_encode(msg, frame_buffer, sizeof(frame_buffer));
    if (frame_len < 0)
        return -1;

    /* Transmit */
    if (xpu_inject_frame(handle, frame_buffer, frame_len, NULL) < 0)
        return -1;

    XPU_DEBUG("Transmitted Remote ID message type %d", msg->msg_type);
    return 0;
}

int xpu_remote_id_format(const remote_id_message_t *msg,
                         char *buffer,
                         size_t buffer_size)
{
    if (!msg || !buffer || buffer_size == 0) {
        XPU_ERROR(NULL, "Invalid arguments");
        return -1;
    }

    return remote_id_format_message(msg, buffer, buffer_size);
}

/* ========================================================================
 * Utility Functions
 * ======================================================================== */

int xpu_parse_mac_address(const char *str, uint8_t mac_addr[6])
{
    int values[6];
    int i;

    if (!str || !mac_addr) {
        XPU_ERROR(NULL, "Invalid arguments");
        return -1;
    }

    if (sscanf(str, "%02x:%02x:%02x:%02x:%02x:%02x",
               &values[0], &values[1], &values[2],
               &values[3], &values[4], &values[5]) != 6) {
        XPU_ERROR(NULL, "Invalid MAC address format: %s", str);
        return -1;
    }

    for (i = 0; i < 6; i++)
        mac_addr[i] = (uint8_t)values[i];

    return 0;
}

int xpu_format_mac_address(const uint8_t mac_addr[6], char *str)
{
    if (!mac_addr || !str) {
        XPU_ERROR(NULL, "Invalid arguments");
        return -1;
    }

    sprintf(str, "%02x:%02x:%02x:%02x:%02x:%02x",
            mac_addr[0], mac_addr[1], mac_addr[2],
            mac_addr[3], mac_addr[4], mac_addr[5]);

    return 0;
}
