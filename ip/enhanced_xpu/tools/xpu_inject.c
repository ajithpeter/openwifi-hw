/* SPDX-FileCopyrightText: 2025 OpenWiFi Project
 * SPDX-License-Identifier: AGPL-3.0-only
 */

/**
 * @file xpu_inject.c
 * @brief Frame Injection Tool for Enhanced XPU
 *
 * This tool injects arbitrary 802.11 frames using the Enhanced XPU hardware.
 *
 * Usage: xpu_inject [options]
 *
 * Options:
 *   -i <device>      Device path (default: /dev/enhanced_xpu)
 *   -f <file>        Read frame from file (hex or binary)
 *   -x <hex>         Frame data as hex string
 *   -t <type>        Frame type template (beacon, probe-req, data, action)
 *   -r <rate>        TX rate in Mbps (1, 2, 5.5, 6, 9, 11, 12, 18, 24, 36, 48, 54)
 *   -p <power>       TX power in dBm
 *   -c <count>       Number of times to send (default: 1, 0=infinite)
 *   -d <delay>       Delay between frames in ms (default: 1000)
 *   -v               Verbose output
 *   -h               Show help
 *
 * @author OpenWiFi Team
 * @date 2025-11-22
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <getopt.h>
#include <ctype.h>
#include "../lib/libenhanced_xpu.h"

/* ========================================================================
 * Configuration
 * ======================================================================== */

struct inject_config {
    char device_path[256];
    char input_file[256];
    uint8_t frame_data[2048];
    size_t frame_len;
    int count;
    int delay_ms;
    struct xpu_tx_params tx_params;
    bool verbose;
};

static volatile bool running = true;
static unsigned long inject_count = 0;

/* ========================================================================
 * Signal Handler
 * ======================================================================== */

static void signal_handler(int signum)
{
    (void)signum;
    running = false;
}

/* ========================================================================
 * Frame Templates
 * ======================================================================== */

/**
 * @brief Create a beacon frame template
 */
static int create_beacon_template(uint8_t *frame, size_t max_len,
                                   const char *ssid)
{
    size_t offset = 0;

    if (max_len < 128)
        return -1;

    /* Frame Control: Beacon */
    frame[offset++] = 0x80;
    frame[offset++] = 0x00;

    /* Duration */
    frame[offset++] = 0x00;
    frame[offset++] = 0x00;

    /* DA: Broadcast */
    memset(&frame[offset], 0xFF, 6);
    offset += 6;

    /* SA: Default source */
    frame[offset++] = 0x00;
    frame[offset++] = 0x11;
    frame[offset++] = 0x22;
    frame[offset++] = 0x33;
    frame[offset++] = 0x44;
    frame[offset++] = 0x55;

    /* BSSID: Same as SA */
    memcpy(&frame[offset], &frame[10], 6);
    offset += 6;

    /* Sequence Control */
    frame[offset++] = 0x00;
    frame[offset++] = 0x00;

    /* Beacon body */
    /* Timestamp (8 bytes) */
    memset(&frame[offset], 0, 8);
    offset += 8;

    /* Beacon Interval (100 TU = 102.4 ms) */
    frame[offset++] = 0x64;
    frame[offset++] = 0x00;

    /* Capability Info */
    frame[offset++] = 0x01;
    frame[offset++] = 0x04;

    /* SSID IE */
    frame[offset++] = 0x00;  /* Element ID */
    if (ssid && strlen(ssid) > 0) {
        size_t ssid_len = strlen(ssid);
        if (ssid_len > 32)
            ssid_len = 32;
        frame[offset++] = ssid_len;
        memcpy(&frame[offset], ssid, ssid_len);
        offset += ssid_len;
    } else {
        frame[offset++] = 0;  /* Empty SSID */
    }

    /* Supported Rates IE */
    frame[offset++] = 0x01;  /* Element ID */
    frame[offset++] = 0x08;  /* Length */
    frame[offset++] = 0x82;  /* 1 Mbps */
    frame[offset++] = 0x84;  /* 2 Mbps */
    frame[offset++] = 0x8B;  /* 5.5 Mbps */
    frame[offset++] = 0x96;  /* 11 Mbps */
    frame[offset++] = 0x0C;  /* 6 Mbps */
    frame[offset++] = 0x12;  /* 9 Mbps */
    frame[offset++] = 0x18;  /* 12 Mbps */
    frame[offset++] = 0x24;  /* 18 Mbps */

    /* DS Parameter Set IE */
    frame[offset++] = 0x03;  /* Element ID */
    frame[offset++] = 0x01;  /* Length */
    frame[offset++] = 0x06;  /* Channel 6 */

    return offset;
}

/**
 * @brief Create a probe request template
 */
static int create_probe_req_template(uint8_t *frame, size_t max_len,
                                      const char *ssid)
{
    size_t offset = 0;

    if (max_len < 128)
        return -1;

    /* Frame Control: Probe Request */
    frame[offset++] = 0x40;
    frame[offset++] = 0x00;

    /* Duration */
    frame[offset++] = 0x00;
    frame[offset++] = 0x00;

    /* DA: Broadcast */
    memset(&frame[offset], 0xFF, 6);
    offset += 6;

    /* SA: Default source */
    frame[offset++] = 0x00;
    frame[offset++] = 0x11;
    frame[offset++] = 0x22;
    frame[offset++] = 0x33;
    frame[offset++] = 0x44;
    frame[offset++] = 0x55;

    /* BSSID: Broadcast */
    memset(&frame[offset], 0xFF, 6);
    offset += 6;

    /* Sequence Control */
    frame[offset++] = 0x00;
    frame[offset++] = 0x00;

    /* SSID IE */
    frame[offset++] = 0x00;  /* Element ID */
    if (ssid && strlen(ssid) > 0) {
        size_t ssid_len = strlen(ssid);
        if (ssid_len > 32)
            ssid_len = 32;
        frame[offset++] = ssid_len;
        memcpy(&frame[offset], ssid, ssid_len);
        offset += ssid_len;
    } else {
        frame[offset++] = 0;  /* Broadcast probe */
    }

    /* Supported Rates IE */
    frame[offset++] = 0x01;  /* Element ID */
    frame[offset++] = 0x08;  /* Length */
    frame[offset++] = 0x82;  /* 1 Mbps */
    frame[offset++] = 0x84;  /* 2 Mbps */
    frame[offset++] = 0x8B;  /* 5.5 Mbps */
    frame[offset++] = 0x96;  /* 11 Mbps */
    frame[offset++] = 0x0C;  /* 6 Mbps */
    frame[offset++] = 0x12;  /* 9 Mbps */
    frame[offset++] = 0x18;  /* 12 Mbps */
    frame[offset++] = 0x24;  /* 18 Mbps */

    return offset;
}

/* ========================================================================
 * Utility Functions
 * ======================================================================== */

/**
 * @brief Parse hex string to binary
 */
static int parse_hex_string(const char *hex, uint8_t *data, size_t max_len)
{
    size_t len = strlen(hex);
    size_t i, j = 0;

    /* Remove whitespace and colons */
    for (i = 0; i < len && j < max_len * 2; i++) {
        if (isxdigit(hex[i])) {
            char tmp[3] = {hex[i], 0, 0};
            if (i + 1 < len && isxdigit(hex[i + 1])) {
                tmp[1] = hex[i + 1];
                i++;
            }
            data[j / 2] = (uint8_t)strtol(tmp, NULL, 16);
            j++;
        }
    }

    return j / 2;
}

/**
 * @brief Read frame from file
 */
static int read_frame_from_file(const char *filename, uint8_t *data,
                                 size_t max_len)
{
    FILE *fp;
    char line[1024];
    size_t len = 0;

    fp = fopen(filename, "r");
    if (!fp) {
        fprintf(stderr, "Failed to open file: %s\n", filename);
        return -1;
    }

    /* Try to parse as hex first */
    if (fgets(line, sizeof(line), fp)) {
        /* Check if it looks like hex */
        if (strstr(line, "0x") || strchr(line, ':')) {
            len = parse_hex_string(line, data, max_len);
        } else {
            /* Try binary read */
            fseek(fp, 0, SEEK_SET);
            len = fread(data, 1, max_len, fp);
        }
    }

    fclose(fp);
    return len;
}

/**
 * @brief Display frame in hex
 */
static void display_frame(const uint8_t *data, size_t len)
{
    size_t i;

    printf("Frame (%zu bytes):\n", len);
    for (i = 0; i < len; i++) {
        printf("%02x ", data[i]);
        if ((i + 1) % 16 == 0)
            printf("\n");
    }
    if (len % 16 != 0)
        printf("\n");
}

/* ========================================================================
 * Main Injection Function
 * ======================================================================== */

static int inject_frames(xpu_handle_t handle, struct inject_config *config)
{
    int i;
    int sent = 0;

    printf("Starting frame injection...\n");
    if (config->verbose) {
        display_frame(config->frame_data, config->frame_len);
    }

    printf("TX Rate: %u Mbps, Power: %d dBm\n",
           config->tx_params.rate, config->tx_params.power);

    if (config->count == 0) {
        printf("Sending frames continuously (press Ctrl+C to stop)...\n");
    } else {
        printf("Sending %d frame(s)...\n", config->count);
    }

    i = 0;
    while (running && (config->count == 0 || i < config->count)) {
        /* Inject frame */
        if (xpu_inject_frame(handle, config->frame_data,
                            config->frame_len,
                            &config->tx_params) < 0) {
            fprintf(stderr, "Failed to inject frame: %s\n", xpu_get_error());
            return -1;
        }

        inject_count++;
        sent++;

        if (config->verbose) {
            printf("Sent frame %d\n", sent);
        } else {
            printf(".");
            fflush(stdout);
        }

        /* Delay between frames */
        if (config->count == 0 || i + 1 < config->count) {
            usleep(config->delay_ms * 1000);
        }

        i++;
    }

    printf("\n");
    printf("Successfully sent %d frame(s)\n", sent);

    return 0;
}

/* ========================================================================
 * Main Function
 * ======================================================================== */

static void print_usage(const char *prog)
{
    printf("Usage: %s [options]\n\n", prog);
    printf("Frame Injection Tool for Enhanced XPU\n\n");
    printf("Options:\n");
    printf("  -i <device>      Device path (default: /dev/enhanced_xpu)\n");
    printf("  -f <file>        Read frame from file (hex or binary)\n");
    printf("  -x <hex>         Frame data as hex string\n");
    printf("  -t <type>        Frame type template:\n");
    printf("                   beacon[:SSID], probe-req[:SSID], data, action\n");
    printf("  -r <rate>        TX rate in Mbps (default: 6)\n");
    printf("  -p <power>       TX power in dBm (default: 15)\n");
    printf("  -c <count>       Number of times to send (default: 1, 0=infinite)\n");
    printf("  -d <delay>       Delay between frames in ms (default: 1000)\n");
    printf("  -v               Verbose output\n");
    printf("  -h               Show this help\n\n");
    printf("Examples:\n");
    printf("  %s -t beacon:TestAP -c 10       # Send 10 beacon frames\n", prog);
    printf("  %s -t probe-req -c 0 -d 100     # Send probe requests every 100ms\n", prog);
    printf("  %s -f frame.hex -r 54 -p 20     # Inject frame from file\n", prog);
    printf("  %s -x \"40 00 00 00 ff ff...\"     # Inject hex frame\n", prog);
}

int main(int argc, char *argv[])
{
    struct inject_config config = {
        .device_path = "/dev/enhanced_xpu",
        .count = 1,
        .delay_ms = 1000,
        .tx_params = {
            .rate = 6,
            .power = 15,
            .retries = 0,
            .flags = XPU_TX_NO_ACK
        },
        .verbose = false
    };
    xpu_handle_t handle = NULL;
    int opt;
    int ret = 0;
    bool have_frame = false;

    /* Parse command line options */
    while ((opt = getopt(argc, argv, "i:f:x:t:r:p:c:d:vh")) != -1) {
        switch (opt) {
        case 'i':
            strncpy(config.device_path, optarg, sizeof(config.device_path) - 1);
            break;

        case 'f':
            strncpy(config.input_file, optarg, sizeof(config.input_file) - 1);
            config.frame_len = read_frame_from_file(config.input_file,
                                                     config.frame_data,
                                                     sizeof(config.frame_data));
            if (config.frame_len <= 0) {
                fprintf(stderr, "Failed to read frame from file\n");
                return 1;
            }
            have_frame = true;
            break;

        case 'x':
            config.frame_len = parse_hex_string(optarg, config.frame_data,
                                                sizeof(config.frame_data));
            if (config.frame_len <= 0) {
                fprintf(stderr, "Failed to parse hex string\n");
                return 1;
            }
            have_frame = true;
            break;

        case 't': {
            char *ssid = strchr(optarg, ':');
            if (ssid) {
                *ssid = '\0';
                ssid++;
            }

            if (strcmp(optarg, "beacon") == 0) {
                config.frame_len = create_beacon_template(config.frame_data,
                                                          sizeof(config.frame_data),
                                                          ssid);
            } else if (strcmp(optarg, "probe-req") == 0) {
                config.frame_len = create_probe_req_template(config.frame_data,
                                                             sizeof(config.frame_data),
                                                             ssid);
            } else {
                fprintf(stderr, "Unknown template type: %s\n", optarg);
                return 1;
            }

            if (config.frame_len <= 0) {
                fprintf(stderr, "Failed to create frame template\n");
                return 1;
            }
            have_frame = true;
            break;
        }

        case 'r':
            config.tx_params.rate = atoi(optarg);
            break;

        case 'p':
            config.tx_params.power = atoi(optarg);
            break;

        case 'c':
            config.count = atoi(optarg);
            break;

        case 'd':
            config.delay_ms = atoi(optarg);
            break;

        case 'v':
            config.verbose = true;
            xpu_set_debug_level(3);
            break;

        case 'h':
            print_usage(argv[0]);
            return 0;

        default:
            print_usage(argv[0]);
            return 1;
        }
    }

    /* Check if we have a frame */
    if (!have_frame) {
        fprintf(stderr, "Error: No frame specified (-f, -x, or -t required)\n\n");
        print_usage(argv[0]);
        return 1;
    }

    /* Setup signal handlers */
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    /* Open XPU device */
    handle = xpu_open(config.device_path);
    if (!handle) {
        fprintf(stderr, "Failed to open XPU device: %s\n", xpu_get_error());
        return 1;
    }

    printf("Enhanced XPU Frame Injection\n");
    printf("===========================\n");
    printf("Device: %s\n\n", config.device_path);

    /* Enable inject mode */
    if (xpu_set_inject_mode(handle, true) < 0) {
        fprintf(stderr, "Failed to enable inject mode\n");
        ret = 1;
        goto cleanup;
    }

    /* Inject frames */
    ret = inject_frames(handle, &config);

cleanup:
    xpu_close(handle);
    return ret;
}
