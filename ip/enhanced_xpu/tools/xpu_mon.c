/* SPDX-FileCopyrightText: 2025 OpenWiFi Project
 * SPDX-License-Identifier: AGPL-3.0-only
 */

/**
 * @file xpu_mon.c
 * @brief WiFi Monitor Mode Tool for Enhanced XPU
 *
 * This tool enables WiFi monitor mode and displays captured packets,
 * similar to tcpdump but for 802.11 frames.
 *
 * Usage: xpu_mon [options]
 *
 * Options:
 *   -i <device>      Device path (default: /dev/enhanced_xpu)
 *   -c <channel>     WiFi channel
 *   -f <filter>      Frame type filter (beacon,probe,data,action,nan,all)
 *   -m <mac>         Filter by MAC address
 *   -w <file>        Write to pcap file
 *   -n <count>       Capture count packets and exit
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
#include <time.h>
#include <getopt.h>
#include <pcap/pcap.h>
#include "../lib/libenhanced_xpu.h"

/* ========================================================================
 * Configuration
 * ======================================================================== */

struct xpu_mon_config {
    char device_path[256];
    int channel;
    uint32_t frame_filter;
    uint8_t mac_filter[6];
    bool use_mac_filter;
    char pcap_file[256];
    bool write_pcap;
    int capture_count;
    bool verbose;
};

/* Global state */
static xpu_handle_t xpu_handle = NULL;
static pcap_dumper_t *pcap_dumper = NULL;
static pcap_t *pcap_handle = NULL;
static volatile bool running = true;
static unsigned long packet_count = 0;

/* ========================================================================
 * Signal Handler
 * ======================================================================== */

static void signal_handler(int signum)
{
    (void)signum;
    running = false;
}

/* ========================================================================
 * PCAP Support
 * ======================================================================== */

static int init_pcap(const char *filename)
{
    /* Create pcap handle with 802.11 + radiotap link type */
    pcap_handle = pcap_open_dead(DLT_IEEE802_11_RADIO, 65535);
    if (!pcap_handle) {
        fprintf(stderr, "Failed to create pcap handle\n");
        return -1;
    }

    /* Open pcap file for writing */
    pcap_dumper = pcap_dump_open(pcap_handle, filename);
    if (!pcap_dumper) {
        fprintf(stderr, "Failed to open pcap file: %s\n", pcap_geterr(pcap_handle));
        pcap_close(pcap_handle);
        return -1;
    }

    printf("Writing packets to: %s\n", filename);
    return 0;
}

static void close_pcap(void)
{
    if (pcap_dumper) {
        pcap_dump_close(pcap_dumper);
        pcap_dumper = NULL;
    }
    if (pcap_handle) {
        pcap_close(pcap_handle);
        pcap_handle = NULL;
    }
}

static void write_pcap_packet(const uint8_t *data, size_t len)
{
    struct pcap_pkthdr header;
    struct timespec ts;

    if (!pcap_dumper)
        return;

    clock_gettime(CLOCK_REALTIME, &ts);

    header.ts.tv_sec = ts.tv_sec;
    header.ts.tv_usec = ts.tv_nsec / 1000;
    header.caplen = len;
    header.len = len;

    pcap_dump((u_char *)pcap_dumper, &header, data);
    pcap_dump_flush(pcap_dumper);
}

/* ========================================================================
 * Packet Display
 * ======================================================================== */

static const char *get_frame_type_name(uint16_t frame_control)
{
    uint8_t type = (frame_control >> 2) & 0x03;
    uint8_t subtype = (frame_control >> 4) & 0x0F;

    switch (type) {
    case 0: /* Management */
        switch (subtype) {
        case 0: return "Assoc Req";
        case 1: return "Assoc Resp";
        case 2: return "Reassoc Req";
        case 3: return "Reassoc Resp";
        case 4: return "Probe Req";
        case 5: return "Probe Resp";
        case 8: return "Beacon";
        case 9: return "ATIM";
        case 10: return "Disassoc";
        case 11: return "Auth";
        case 12: return "Deauth";
        case 13: return "Action";
        default: return "Mgmt";
        }
    case 1: /* Control */
        switch (subtype) {
        case 10: return "PS-Poll";
        case 11: return "RTS";
        case 12: return "CTS";
        case 13: return "ACK";
        default: return "Control";
        }
    case 2: /* Data */
        if (subtype & 0x08)
            return "QoS Data";
        return "Data";
    default:
        return "Unknown";
    }
}

static void display_packet(const uint8_t *data, size_t len, bool verbose)
{
    uint16_t frame_control;
    char src[18], dst[18];
    time_t now;
    char time_str[32];

    if (len < 24) {
        printf("Packet too short: %zu bytes\n", len);
        return;
    }

    /* Parse 802.11 header */
    frame_control = data[0] | (data[1] << 8);

    /* Format MAC addresses */
    xpu_format_mac_address(&data[4], dst);   /* DA */
    xpu_format_mac_address(&data[10], src);  /* SA */

    /* Get timestamp */
    now = time(NULL);
    strftime(time_str, sizeof(time_str), "%H:%M:%S", localtime(&now));

    /* Display packet info */
    printf("[%lu] %s  %-12s  %s -> %s  (%zu bytes)\n",
           packet_count,
           time_str,
           get_frame_type_name(frame_control),
           src,
           dst,
           len);

    if (verbose && len >= 36) {
        /* Display BSSID */
        char bssid[18];
        xpu_format_mac_address(&data[16], bssid);
        printf("      BSSID: %s\n", bssid);

        /* Display sequence number */
        uint16_t seq = (data[22] | (data[23] << 8)) >> 4;
        printf("      Seq: %u\n", seq);
    }
}

/* ========================================================================
 * Main Capture Loop
 * ======================================================================== */

static int capture_loop(struct xpu_mon_config *config)
{
    uint8_t packet_buffer[4096];
    ssize_t len;
    struct xpu_stats stats;

    printf("Starting capture (press Ctrl+C to stop)...\n\n");

    while (running) {
        /* Receive packet (100ms timeout) */
        len = xpu_receive_packet(xpu_handle, packet_buffer,
                                 sizeof(packet_buffer), 100);

        if (len < 0) {
            if (errno == EAGAIN)
                continue;  /* Timeout */

            fprintf(stderr, "Error receiving packet: %s\n", strerror(errno));
            break;
        }

        packet_count++;

        /* Display packet */
        display_packet(packet_buffer, len, config->verbose);

        /* Write to pcap if enabled */
        if (config->write_pcap) {
            write_pcap_packet(packet_buffer, len);
        }

        /* Check capture count */
        if (config->capture_count > 0 &&
            (int)packet_count >= config->capture_count) {
            printf("\nCapture limit reached (%d packets)\n", config->capture_count);
            break;
        }
    }

    /* Display statistics */
    printf("\n");
    printf("=== Capture Statistics ===\n");
    printf("Packets captured: %lu\n", packet_count);

    if (xpu_get_stats(xpu_handle, &stats) == 0) {
        printf("RX packets: %llu\n", (unsigned long long)stats.rx_packets);
        printf("RX bytes: %llu\n", (unsigned long long)stats.rx_bytes);
        printf("RX dropped: %llu\n", (unsigned long long)stats.rx_dropped);
        printf("Errors: %llu\n", (unsigned long long)stats.errors);
    }

    return 0;
}

/* ========================================================================
 * Main Function
 * ======================================================================== */

static void print_usage(const char *prog)
{
    printf("Usage: %s [options]\n\n", prog);
    printf("WiFi Monitor Mode Tool for Enhanced XPU\n\n");
    printf("Options:\n");
    printf("  -i <device>      Device path (default: /dev/enhanced_xpu)\n");
    printf("  -c <channel>     WiFi channel (1-165)\n");
    printf("  -f <filter>      Frame type filter:\n");
    printf("                   beacon, probe, data, action, nan, all\n");
    printf("  -m <mac>         Filter by MAC address (xx:xx:xx:xx:xx:xx)\n");
    printf("  -w <file>        Write packets to pcap file\n");
    printf("  -n <count>       Capture <count> packets and exit\n");
    printf("  -v               Verbose output\n");
    printf("  -h               Show this help\n\n");
    printf("Examples:\n");
    printf("  %s -c 6                  # Monitor channel 6\n", prog);
    printf("  %s -f beacon -w out.pcap # Capture beacons to file\n", prog);
    printf("  %s -f nan -v             # Capture NAN frames (verbose)\n", prog);
    printf("  %s -m 00:11:22:33:44:55  # Filter by MAC address\n", prog);
}

int main(int argc, char *argv[])
{
    struct xpu_mon_config config = {
        .device_path = "/dev/enhanced_xpu",
        .channel = 6,
        .frame_filter = 0xFFFFFFFF,  /* All frames */
        .use_mac_filter = false,
        .write_pcap = false,
        .capture_count = 0,  /* Unlimited */
        .verbose = false
    };
    struct xpu_filter_config filter = {0};
    int opt;
    int ret = 0;

    /* Parse command line options */
    while ((opt = getopt(argc, argv, "i:c:f:m:w:n:vh")) != -1) {
        switch (opt) {
        case 'i':
            strncpy(config.device_path, optarg, sizeof(config.device_path) - 1);
            break;

        case 'c':
            config.channel = atoi(optarg);
            if (config.channel < 1 || config.channel > 165) {
                fprintf(stderr, "Invalid channel: %d\n", config.channel);
                return 1;
            }
            break;

        case 'f':
            if (strcmp(optarg, "beacon") == 0)
                config.frame_filter = XPU_FRAME_BEACON;
            else if (strcmp(optarg, "probe") == 0)
                config.frame_filter = XPU_FRAME_PROBE_REQ | XPU_FRAME_PROBE_RESP;
            else if (strcmp(optarg, "data") == 0)
                config.frame_filter = XPU_FRAME_DATA | XPU_FRAME_QOS_DATA;
            else if (strcmp(optarg, "action") == 0)
                config.frame_filter = XPU_FRAME_ACTION;
            else if (strcmp(optarg, "nan") == 0)
                config.frame_filter = XPU_FRAME_NAN;
            else if (strcmp(optarg, "all") == 0)
                config.frame_filter = 0xFFFFFFFF;
            else {
                fprintf(stderr, "Invalid filter: %s\n", optarg);
                return 1;
            }
            break;

        case 'm':
            if (xpu_parse_mac_address(optarg, config.mac_filter) < 0) {
                fprintf(stderr, "Invalid MAC address: %s\n", optarg);
                return 1;
            }
            config.use_mac_filter = true;
            break;

        case 'w':
            strncpy(config.pcap_file, optarg, sizeof(config.pcap_file) - 1);
            config.write_pcap = true;
            break;

        case 'n':
            config.capture_count = atoi(optarg);
            break;

        case 'v':
            config.verbose = true;
            xpu_set_debug_level(3);  /* Info level */
            break;

        case 'h':
            print_usage(argv[0]);
            return 0;

        default:
            print_usage(argv[0]);
            return 1;
        }
    }

    /* Setup signal handlers */
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    /* Open XPU device */
    xpu_handle = xpu_open(config.device_path);
    if (!xpu_handle) {
        fprintf(stderr, "Failed to open XPU device: %s\n", xpu_get_error());
        return 1;
    }

    printf("Enhanced XPU Monitor Mode\n");
    printf("========================\n");
    printf("Device: %s\n", config.device_path);
    printf("Channel: %d\n", config.channel);

    /* Initialize pcap if needed */
    if (config.write_pcap) {
        if (init_pcap(config.pcap_file) < 0) {
            xpu_close(xpu_handle);
            return 1;
        }
    }

    /* Enable monitor mode */
    if (xpu_set_monitor_mode(xpu_handle, true) < 0) {
        fprintf(stderr, "Failed to enable monitor mode\n");
        ret = 1;
        goto cleanup;
    }

    /* Configure filters */
    if (config.use_mac_filter) {
        filter.flags |= XPU_FILTER_MAC_ADDR;
        memcpy(filter.mac_addr, config.mac_filter, 6);

        char mac_str[18];
        xpu_format_mac_address(config.mac_filter, mac_str);
        printf("MAC Filter: %s\n", mac_str);
    }

    if (config.frame_filter != 0xFFFFFFFF) {
        filter.flags |= XPU_FILTER_FRAME_TYPE;
        filter.frame_type_mask = config.frame_filter;
    }

    if (filter.flags) {
        if (xpu_configure_filters(xpu_handle, &filter) < 0) {
            fprintf(stderr, "Failed to configure filters\n");
            ret = 1;
            goto cleanup;
        }
    }

    printf("\n");

    /* Run capture loop */
    ret = capture_loop(&config);

cleanup:
    /* Cleanup */
    if (config.write_pcap)
        close_pcap();

    xpu_close(xpu_handle);

    return ret;
}
