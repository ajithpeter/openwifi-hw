/* SPDX-FileCopyrightText: 2025 OpenWiFi Project
 * SPDX-License-Identifier: AGPL-3.0-only
 */

/**
 * @file simple_monitor.c
 * @brief Simple Monitor Mode Example
 *
 * This example demonstrates basic monitor mode usage.
 *
 * Compile:
 *   gcc -o simple_monitor simple_monitor.c -lenhanced_xpu -lpthread -lm
 *
 * Run:
 *   ./simple_monitor
 */

#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include "../lib/libenhanced_xpu.h"

static volatile int running = 1;

static void signal_handler(int signum)
{
    (void)signum;
    running = 0;
}

int main(int argc, char *argv[])
{
    xpu_handle_t handle;
    uint8_t packet[2048];
    ssize_t len;
    int count = 0;

    (void)argc;
    (void)argv;

    printf("Enhanced XPU Simple Monitor Example\n");
    printf("====================================\n\n");

    /* Setup signal handler */
    signal(SIGINT, signal_handler);

    /* Open device */
    handle = xpu_open("/dev/enhanced_xpu");
    if (!handle) {
        fprintf(stderr, "Failed to open device: %s\n", xpu_get_error());
        return 1;
    }

    printf("Device opened successfully\n");

    /* Enable monitor mode */
    if (xpu_set_monitor_mode(handle, 1) < 0) {
        fprintf(stderr, "Failed to enable monitor mode\n");
        xpu_close(handle);
        return 1;
    }

    printf("Monitor mode enabled\n");
    printf("Capturing packets (press Ctrl+C to stop)...\n\n");

    /* Capture loop */
    while (running) {
        /* Receive packet (1 second timeout) */
        len = xpu_receive_packet(handle, packet, sizeof(packet), 1000);

        if (len < 0) {
            if (errno == EAGAIN)
                continue;  /* Timeout */

            fprintf(stderr, "Error receiving packet\n");
            break;
        }

        count++;
        printf("[%d] Received packet: %zd bytes\n", count, len);

        /* Limit to 10 packets for this example */
        if (count >= 10)
            break;
    }

    printf("\nTotal packets captured: %d\n", count);

    /* Cleanup */
    xpu_close(handle);
    printf("Device closed\n");

    return 0;
}
