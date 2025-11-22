/* SPDX-FileCopyrightText: 2025 OpenWiFi Project
 * SPDX-License-Identifier: AGPL-3.0-only
 */

/**
 * @file xpu_remote_id.c
 * @brief Drone Remote ID Tool for Enhanced XPU
 *
 * This tool implements ASTM F3411 Remote ID transmission and monitoring.
 *
 * Modes:
 *   transmit    - Transmit Remote ID messages (1 Hz)
 *   monitor     - Monitor and decode Remote ID from other drones
 *   test        - Test mode (transmit and monitor simultaneously)
 *
 * Usage: xpu_remote_id <mode> [options]
 *
 * @author OpenWiFi Team
 * @date 2025-11-22
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <getopt.h>
#include <pthread.h>
#include <math.h>
#include "../lib/libenhanced_xpu.h"

/* ========================================================================
 * Configuration
 * ======================================================================== */

enum remote_id_mode {
    MODE_TRANSMIT,
    MODE_MONITOR,
    MODE_TEST
};

struct remote_id_config {
    enum remote_id_mode mode;
    char device_path[256];

    /* Transmit configuration */
    char uas_id[21];
    char operator_id[21];
    char description[24];
    double latitude;
    double longitude;
    float altitude;
    int interval_ms;

    /* Monitor configuration */
    bool verbose;
};

static volatile bool running = true;
static unsigned long tx_count = 0;
static unsigned long rx_count = 0;

/* ========================================================================
 * Signal Handler
 * ======================================================================== */

static void signal_handler(int signum)
{
    (void)signum;
    running = false;
}

/* ========================================================================
 * Remote ID Message Building
 * ======================================================================== */

/**
 * @brief Build Basic ID message
 */
static int build_basic_id_msg(remote_id_message_t *msg, const char *uas_id)
{
    memset(msg, 0, sizeof(*msg));

    msg->basic_id.msg_type = REMOTE_ID_BASIC_ID;
    msg->basic_id.id_type = 0;  /* Serial Number */
    msg->basic_id.ua_type = 1;  /* Aeroplane */

    strncpy((char *)msg->basic_id.uas_id, uas_id, 20);

    return 0;
}

/**
 * @brief Build Location message
 */
static int build_location_msg(remote_id_message_t *msg,
                               double lat, double lon, float alt)
{
    struct timespec ts;
    uint16_t timestamp;

    memset(msg, 0, sizeof(*msg));

    msg->location.msg_type = REMOTE_ID_LOCATION;
    msg->location.status = 0x01;  /* Airborne */

    /* Position */
    msg->location.latitude = (int32_t)(lat * 1e7);
    msg->location.longitude = (int32_t)(lon * 1e7);
    msg->location.altitude_baro = (int16_t)(alt * 2.0f);
    msg->location.altitude_geo = (int16_t)(alt * 2.0f);
    msg->location.height_agl = (uint16_t)alt;

    /* Mock velocity */
    msg->location.speed_horiz = 20;   /* 5 m/s */
    msg->location.speed_vert = 0;     /* 0 m/s */
    msg->location.direction = 90;     /* East */

    /* Accuracy (good) */
    msg->location.horiz_accuracy = remote_id_encode_accuracy(3.0f);
    msg->location.vert_accuracy = remote_id_encode_accuracy(5.0f);
    msg->location.baro_accuracy = remote_id_encode_accuracy(10.0f);
    msg->location.speed_accuracy = remote_id_encode_accuracy(1.0f);

    /* Timestamp (tenths of seconds since hour) */
    clock_gettime(CLOCK_REALTIME, &ts);
    timestamp = ((ts.tv_sec % 3600) * 10) + (ts.tv_nsec / 100000000);
    msg->location.timestamp = timestamp;

    return 0;
}

/**
 * @brief Build Self-ID message
 */
static int build_self_id_msg(remote_id_message_t *msg, const char *description)
{
    memset(msg, 0, sizeof(*msg));

    msg->self_id.msg_type = REMOTE_ID_SELF_ID;
    msg->self_id.description_type = 0;  /* Text */

    strncpy((char *)msg->self_id.description, description, 23);

    return 0;
}

/**
 * @brief Build Operator ID message
 */
static int build_operator_id_msg(remote_id_message_t *msg, const char *operator_id)
{
    memset(msg, 0, sizeof(*msg));

    msg->operator_id.msg_type = REMOTE_ID_OPERATOR_ID;
    msg->operator_id.operator_id_type = 0;  /* Operator ID */

    strncpy((char *)msg->operator_id.operator_id, operator_id, 20);

    return 0;
}

/* ========================================================================
 * Transmit Thread
 * ======================================================================== */

static void *transmit_thread(void *arg)
{
    struct remote_id_config *config = arg;
    xpu_handle_t handle;
    remote_id_message_t msg;
    int msg_seq = 0;

    /* Open device */
    handle = xpu_open(config->device_path);
    if (!handle) {
        fprintf(stderr, "TX: Failed to open device: %s\n", xpu_get_error());
        return NULL;
    }

    /* Enable inject mode */
    if (xpu_set_inject_mode(handle, true) < 0) {
        fprintf(stderr, "TX: Failed to enable inject mode\n");
        xpu_close(handle);
        return NULL;
    }

    printf("TX: Starting Remote ID transmission (1 Hz)...\n");
    printf("TX: UAS ID: %s\n", config->uas_id);
    printf("TX: Operator: %s\n", config->operator_id);
    printf("TX: Location: %.6f, %.6f @ %.1f m\n",
           config->latitude, config->longitude, config->altitude);

    while (running) {
        /* Rotate through message types */
        switch (msg_seq % 4) {
        case 0:
            build_basic_id_msg(&msg, config->uas_id);
            break;
        case 1:
            build_location_msg(&msg, config->latitude,
                              config->longitude, config->altitude);
            break;
        case 2:
            build_self_id_msg(&msg, config->description);
            break;
        case 3:
            build_operator_id_msg(&msg, config->operator_id);
            break;
        }

        /* Transmit message */
        if (xpu_remote_id_transmit(handle, &msg) == 0) {
            tx_count++;
            if (config->verbose) {
                printf("TX: Sent message type %d (#%lu)\n",
                       msg.msg_type, tx_count);
            }
        } else {
            fprintf(stderr, "TX: Failed to transmit message\n");
        }

        msg_seq++;

        /* Wait for next interval (1 Hz) */
        usleep(config->interval_ms * 1000);
    }

    xpu_close(handle);
    return NULL;
}

/* ========================================================================
 * Monitor Thread
 * ======================================================================== */

static void display_remote_id_message(const remote_id_message_t *msg)
{
    char buffer[1024];
    time_t now;
    char time_str[32];

    now = time(NULL);
    strftime(time_str, sizeof(time_str), "%H:%M:%S", localtime(&now));

    printf("\n[%s] Remote ID Message Received (#%lu)\n", time_str, rx_count);
    printf("========================================\n");

    if (xpu_remote_id_format(msg, buffer, sizeof(buffer)) == 0) {
        printf("%s", buffer);
    } else {
        printf("(Failed to format message)\n");
    }

    printf("\n");
}

static void *monitor_thread(void *arg)
{
    struct remote_id_config *config = arg;
    xpu_handle_t handle;
    struct xpu_filter_config filter = {0};
    uint8_t packet_buffer[2048];
    ssize_t len;
    remote_id_message_t msg;

    /* Open device */
    handle = xpu_open(config->device_path);
    if (!handle) {
        fprintf(stderr, "RX: Failed to open device: %s\n", xpu_get_error());
        return NULL;
    }

    /* Enable monitor mode */
    if (xpu_set_monitor_mode(handle, true) < 0) {
        fprintf(stderr, "RX: Failed to enable monitor mode\n");
        xpu_close(handle);
        return NULL;
    }

    /* Configure filter for NAN frames */
    filter.flags = XPU_FILTER_FRAME_TYPE;
    filter.frame_type_mask = XPU_FRAME_NAN | XPU_FRAME_ACTION;

    if (xpu_configure_filters(handle, &filter) < 0) {
        fprintf(stderr, "RX: Failed to configure filters\n");
        xpu_close(handle);
        return NULL;
    }

    printf("RX: Monitoring for Remote ID messages...\n\n");

    while (running) {
        /* Receive packet (1 second timeout) */
        len = xpu_receive_packet(handle, packet_buffer,
                                 sizeof(packet_buffer), 1000);

        if (len < 0) {
            if (errno == EAGAIN)
                continue;  /* Timeout */

            fprintf(stderr, "RX: Error receiving packet: %s\n", strerror(errno));
            break;
        }

        /* Try to decode as Remote ID */
        if (xpu_remote_id_decode(packet_buffer, len, &msg) == 0) {
            rx_count++;
            display_remote_id_message(&msg);
        }
    }

    xpu_close(handle);
    return NULL;
}

/* ========================================================================
 * Main Function
 * ======================================================================== */

static void print_usage(const char *prog)
{
    printf("Usage: %s <mode> [options]\n\n", prog);
    printf("Drone Remote ID Tool for Enhanced XPU (ASTM F3411)\n\n");
    printf("Modes:\n");
    printf("  transmit    Transmit Remote ID messages (1 Hz)\n");
    printf("  monitor     Monitor and decode Remote ID from other drones\n");
    printf("  test        Test mode (transmit and monitor simultaneously)\n\n");
    printf("Options:\n");
    printf("  -i <device>     Device path (default: /dev/enhanced_xpu)\n");
    printf("  -u <id>         UAS ID (serial number, max 20 chars)\n");
    printf("  -o <id>         Operator ID (max 20 chars)\n");
    printf("  -d <desc>       Description text (max 23 chars)\n");
    printf("  -l <lat,lon>    Location (decimal degrees)\n");
    printf("  -a <altitude>   Altitude in meters\n");
    printf("  -t <ms>         TX interval in ms (default: 1000)\n");
    printf("  -v              Verbose output\n");
    printf("  -h              Show this help\n\n");
    printf("Examples:\n");
    printf("  # Transmit Remote ID\n");
    printf("  %s transmit -u \"DRONE-12345\" -o \"OP-001\" \\\n", prog);
    printf("      -l 37.7749,-122.4194 -a 100\n\n");
    printf("  # Monitor Remote ID from other drones\n");
    printf("  %s monitor -v\n\n", prog);
    printf("  # Test mode (TX + RX)\n");
    printf("  %s test -u \"TEST-001\" -l 0,0 -a 50\n", prog);
}

int main(int argc, char *argv[])
{
    struct remote_id_config config = {
        .mode = MODE_TRANSMIT,
        .device_path = "/dev/enhanced_xpu",
        .uas_id = "OPENWIFI-001",
        .operator_id = "OP-OPENWIFI",
        .description = "OpenWiFi Test Drone",
        .latitude = 0.0,
        .longitude = 0.0,
        .altitude = 100.0f,
        .interval_ms = 1000,  /* 1 Hz */
        .verbose = false
    };
    pthread_t tx_tid, rx_tid;
    int opt;

    /* Parse mode */
    if (argc < 2) {
        print_usage(argv[0]);
        return 1;
    }

    if (strcmp(argv[1], "transmit") == 0) {
        config.mode = MODE_TRANSMIT;
    } else if (strcmp(argv[1], "monitor") == 0) {
        config.mode = MODE_MONITOR;
    } else if (strcmp(argv[1], "test") == 0) {
        config.mode = MODE_TEST;
    } else {
        fprintf(stderr, "Unknown mode: %s\n", argv[1]);
        print_usage(argv[0]);
        return 1;
    }

    /* Reset optind for getopt */
    optind = 2;

    /* Parse options */
    while ((opt = getopt(argc, argv, "i:u:o:d:l:a:t:vh")) != -1) {
        switch (opt) {
        case 'i':
            strncpy(config.device_path, optarg, sizeof(config.device_path) - 1);
            break;

        case 'u':
            strncpy(config.uas_id, optarg, sizeof(config.uas_id) - 1);
            break;

        case 'o':
            strncpy(config.operator_id, optarg, sizeof(config.operator_id) - 1);
            break;

        case 'd':
            strncpy(config.description, optarg, sizeof(config.description) - 1);
            break;

        case 'l':
            if (sscanf(optarg, "%lf,%lf", &config.latitude, &config.longitude) != 2) {
                fprintf(stderr, "Invalid location format: %s\n", optarg);
                fprintf(stderr, "Expected: lat,lon (e.g., 37.7749,-122.4194)\n");
                return 1;
            }
            break;

        case 'a':
            config.altitude = atof(optarg);
            break;

        case 't':
            config.interval_ms = atoi(optarg);
            if (config.interval_ms < 100 || config.interval_ms > 10000) {
                fprintf(stderr, "Invalid interval: %d ms (range: 100-10000)\n",
                        config.interval_ms);
                return 1;
            }
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

    /* Validate configuration */
    if (config.mode != MODE_MONITOR) {
        if (strlen(config.uas_id) == 0) {
            fprintf(stderr, "Error: UAS ID required for transmit mode (-u)\n");
            return 1;
        }
    }

    /* Setup signal handlers */
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    printf("Enhanced XPU Remote ID Tool\n");
    printf("===========================\n");
    printf("Device: %s\n", config.device_path);
    printf("Mode: %s\n",
           config.mode == MODE_TRANSMIT ? "Transmit" :
           config.mode == MODE_MONITOR ? "Monitor" : "Test");
    printf("\n");

    /* Start threads based on mode */
    if (config.mode == MODE_TRANSMIT || config.mode == MODE_TEST) {
        if (pthread_create(&tx_tid, NULL, transmit_thread, &config) != 0) {
            fprintf(stderr, "Failed to create TX thread\n");
            return 1;
        }
    }

    if (config.mode == MODE_MONITOR || config.mode == MODE_TEST) {
        if (pthread_create(&rx_tid, NULL, monitor_thread, &config) != 0) {
            fprintf(stderr, "Failed to create RX thread\n");
            return 1;
        }
    }

    /* Wait for threads */
    if (config.mode == MODE_TRANSMIT || config.mode == MODE_TEST) {
        pthread_join(tx_tid, NULL);
    }

    if (config.mode == MODE_MONITOR || config.mode == MODE_TEST) {
        pthread_join(rx_tid, NULL);
    }

    /* Display final statistics */
    printf("\n");
    printf("=== Statistics ===\n");
    if (config.mode == MODE_TRANSMIT || config.mode == MODE_TEST) {
        printf("TX Messages: %lu\n", tx_count);
    }
    if (config.mode == MODE_MONITOR || config.mode == MODE_TEST) {
        printf("RX Messages: %lu\n", rx_count);
    }

    return 0;
}
