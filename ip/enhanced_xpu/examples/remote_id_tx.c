/* SPDX-FileCopyrightText: 2025 OpenWiFi Project
 * SPDX-License-Identifier: AGPL-3.0-only
 */

/**
 * @file remote_id_tx.c
 * @brief Simple Remote ID Transmission Example
 *
 * This example demonstrates Remote ID message transmission.
 *
 * Compile:
 *   gcc -o remote_id_tx remote_id_tx.c -lenhanced_xpu -lpthread -lm
 *
 * Run:
 *   ./remote_id_tx
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include "../lib/libenhanced_xpu.h"
#include "../include/remote_id_types.h"

static volatile int running = 1;

static void signal_handler(int signum)
{
    (void)signum;
    running = 0;
}

int main(int argc, char *argv[])
{
    xpu_handle_t handle;
    remote_id_message_t msg;
    int count = 0;

    (void)argc;
    (void)argv;

    printf("Enhanced XPU Remote ID Transmission Example\n");
    printf("===========================================\n\n");

    /* Setup signal handler */
    signal(SIGINT, signal_handler);

    /* Open device */
    handle = xpu_open("/dev/enhanced_xpu");
    if (!handle) {
        fprintf(stderr, "Failed to open device: %s\n", xpu_get_error());
        return 1;
    }

    printf("Device opened successfully\n");

    /* Enable inject mode */
    if (xpu_set_inject_mode(handle, 1) < 0) {
        fprintf(stderr, "Failed to enable inject mode\n");
        xpu_close(handle);
        return 1;
    }

    printf("Inject mode enabled\n");

    /* Build Basic ID message */
    memset(&msg, 0, sizeof(msg));
    msg.basic_id.msg_type = REMOTE_ID_BASIC_ID;
    msg.basic_id.id_type = 0;   /* Serial Number */
    msg.basic_id.ua_type = 1;   /* Aeroplane */
    strncpy((char *)msg.basic_id.uas_id, "EXAMPLE-DRONE-001", 20);

    printf("\nTransmitting Remote ID Basic ID message:\n");
    printf("  UAS ID: %s\n", msg.basic_id.uas_id);
    printf("  ID Type: %d (Serial Number)\n", msg.basic_id.id_type);
    printf("  UA Type: %d (Aeroplane)\n\n", msg.basic_id.ua_type);

    printf("Transmitting every 1 second (press Ctrl+C to stop)...\n\n");

    /* Transmission loop */
    while (running && count < 10) {
        /* Transmit message */
        if (xpu_remote_id_transmit(handle, &msg) < 0) {
            fprintf(stderr, "Failed to transmit message\n");
            break;
        }

        count++;
        printf("[%d] Message transmitted\n", count);

        /* Wait 1 second (ASTM F3411 requires 1 Hz) */
        sleep(1);
    }

    printf("\nTotal messages transmitted: %d\n", count);

    /* Cleanup */
    xpu_close(handle);
    printf("Device closed\n");

    return 0;
}
