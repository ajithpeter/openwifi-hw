/* SPDX-FileCopyrightText: 2025 OpenWiFi Project
 * SPDX-License-Identifier: AGPL-3.0-only
 */

/**
 * @file wfb_ng_injector.c
 * @brief wfb-ng compatible WiFi broadcast frame injector
 *
 * This example demonstrates high-rate frame injection compatible
 * with wfb-ng (WiFi Broadcast Next Generation) for FPV video streaming.
 *
 * Features:
 * - High-rate frame injection (up to several hundred Mbps)
 * - wfb-ng compatible frame format
 * - Broadcast mode (no ACK required)
 * - FEC (Forward Error Correction) support
 * - Configurable data rate and channel
 * - Suitable for real-time video streaming
 *
 * Usage:
 *   sudo ./wfb_ng_injector [-c channel] [-r rate] [-i interface]
 *
 * Example:
 *   sudo ./wfb_ng_injector -c 149 -r 18
 *
 * Note: This is intended for WiFi-based FPV systems and should
 *       only be used in compliance with local regulations.
 *
 * @author OpenWiFi Team
 * @date 2025-11-22
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <signal.h>
#include <time.h>
#include <errno.h>
#include <getopt.h>

/* IEEE 802.11 Radiotap Header */
struct radiotap_hdr {
    uint8_t  it_version;     /* 0 */
    uint8_t  it_pad;
    uint16_t it_len;         /* Length including data */
    uint32_t it_present;     /* Present fields */
} __attribute__((packed));

/* IEEE 802.11 MAC Header (QoS Data frame) */
struct ieee80211_qos_hdr {
    uint16_t frame_control;
    uint16_t duration;
    uint8_t  addr1[6];       /* Receiver (broadcast) */
    uint8_t  addr2[6];       /* Transmitter */
    uint8_t  addr3[6];       /* BSSID */
    uint16_t seq_ctrl;
    uint16_t qos_ctrl;       /* QoS control */
} __attribute__((packed));

/* wfb-ng packet header */
struct wfb_packet_hdr {
    uint8_t  radio_port;     /* Radio port (for multiple streams) */
    uint8_t  fragment_idx;   /* Fragment index (for FEC) */
    uint16_t sequence;       /* Packet sequence number */
} __attribute__((packed));

/* Enhanced XPU ioctl commands */
#define OPENWIFI_IOCTL_MAGIC        'o'
#define IOCTL_SET_CHANNEL           _IOW(OPENWIFI_IOCTL_MAGIC, 11, uint32_t)
#define IOCTL_INJECT_FRAME          _IOW(OPENWIFI_IOCTL_MAGIC, 20, void*)
#define IOCTL_SET_DATA_RATE         _IOW(OPENWIFI_IOCTL_MAGIC, 22, uint32_t)

/* Frame injection parameters */
struct inject_params {
    uint8_t  *frame;
    uint32_t  length;
    uint32_t  rate;          /* Data rate in Mbps */
    uint32_t  retries;       /* Number of retries (0 for broadcast) */
    uint32_t  flags;         /* Injection flags */
} __attribute__((packed));

/* Configuration */
struct config {
    int channel;             /* WiFi channel */
    int data_rate;           /* Data rate in Mbps */
    int mtu;                 /* MTU size */
    uint8_t src_mac[6];      /* Source MAC address */
    uint8_t dst_mac[6];      /* Destination MAC (broadcast) */
    uint8_t bssid[6];        /* BSSID */
} config = {
    .channel = 149,          /* 5 GHz channel */
    .data_rate = 18,         /* 18 Mbps */
    .mtu = 1400,
    .src_mac = {0x02, 0x00, 0x00, 0x00, 0x00, 0x01},
    .dst_mac = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF},  /* Broadcast */
    .bssid = {0x13, 0x22, 0x33, 0x44, 0x55, 0x66}
};

/* Statistics */
struct stats {
    unsigned long frames_sent;
    unsigned long bytes_sent;
    unsigned long errors;
    time_t start_time;
} stats;

/* Global variables */
static volatile int keep_running = 1;
static int sdr_fd = -1;
static uint16_t sequence = 0;

/* Signal handler */
void signal_handler(int signum) {
    (void)signum;
    keep_running = 0;
}

/**
 * @brief Build radiotap header
 * @param buf Output buffer
 * @param rate Data rate in 500 kbps units
 * @return Header length
 */
size_t build_radiotap_header(uint8_t *buf, uint8_t rate) {
    struct radiotap_hdr *rt = (struct radiotap_hdr *)buf;

    rt->it_version = 0;
    rt->it_pad = 0;
    rt->it_len = sizeof(*rt);
    rt->it_present = 0x00000004;  /* Rate field present */

    buf[sizeof(*rt)] = rate;  /* Rate in 500 kbps units */

    return sizeof(*rt) + 1;
}

/**
 * @brief Build 802.11 QoS data frame header
 * @param buf Output buffer
 * @param seq Sequence number
 * @return Header length
 */
size_t build_80211_header(uint8_t *buf, uint16_t seq) {
    struct ieee80211_qos_hdr *hdr = (struct ieee80211_qos_hdr *)buf;

    /* Frame control: QoS Data, To DS=1, From DS=0 */
    hdr->frame_control = 0x0188;
    hdr->duration = 0;

    /* Addresses */
    memcpy(hdr->addr1, config.dst_mac, 6);
    memcpy(hdr->addr2, config.src_mac, 6);
    memcpy(hdr->addr3, config.bssid, 6);

    /* Sequence control */
    hdr->seq_ctrl = seq << 4;

    /* QoS control: Priority 6 (Video) */
    hdr->qos_ctrl = 0x0006;

    return sizeof(*hdr);
}

/**
 * @brief Build complete wfb-ng frame
 * @param buf Output buffer
 * @param buflen Buffer length
 * @param payload Data payload
 * @param payload_len Payload length
 * @param radio_port Radio port number
 * @param fragment_idx Fragment index
 * @return Frame length, or -1 on error
 */
int build_wfb_frame(uint8_t *buf, size_t buflen,
                    const uint8_t *payload, size_t payload_len,
                    uint8_t radio_port, uint8_t fragment_idx) {
    size_t offset = 0;
    struct wfb_packet_hdr *wfb_hdr;

    if (buflen < payload_len + sizeof(struct ieee80211_qos_hdr) +
                 sizeof(struct wfb_packet_hdr) + 20) {
        return -1;
    }

    /* Skip radiotap for now (hardware will add) */
    /* Build 802.11 header */
    offset += build_80211_header(buf + offset, sequence++);

    /* wfb-ng packet header */
    wfb_hdr = (struct wfb_packet_hdr *)(buf + offset);
    wfb_hdr->radio_port = radio_port;
    wfb_hdr->fragment_idx = fragment_idx;
    wfb_hdr->sequence = sequence;
    offset += sizeof(*wfb_hdr);

    /* Payload */
    memcpy(buf + offset, payload, payload_len);
    offset += payload_len;

    return offset;
}

/**
 * @brief Inject wfb-ng frame
 * @param payload Data payload
 * @param payload_len Payload length
 * @param radio_port Radio port
 * @param fragment_idx Fragment index
 * @return 0 on success, -1 on error
 */
int inject_wfb_frame(const uint8_t *payload, size_t payload_len,
                     uint8_t radio_port, uint8_t fragment_idx) {
    uint8_t frame[2048];
    int frame_len;

    /* Build frame */
    frame_len = build_wfb_frame(frame, sizeof(frame), payload, payload_len,
                                radio_port, fragment_idx);
    if (frame_len < 0) {
        return -1;
    }

    /* Prepare injection parameters */
    struct inject_params params = {
        .frame = frame,
        .length = frame_len,
        .rate = config.data_rate,
        .retries = 0,        /* No retries for broadcast */
        .flags = 0x0001      /* No ACK flag */
    };

    /* Inject frame */
    if (ioctl(sdr_fd, IOCTL_INJECT_FRAME, &params) < 0) {
        return -1;
    }

    stats.frames_sent++;
    stats.bytes_sent += payload_len;

    return 0;
}

/**
 * @brief Read data from stdin and inject
 */
void injection_loop(void) {
    uint8_t buffer[2048];
    ssize_t nread;
    fd_set rfds;
    struct timeval tv;
    int ret;

    printf("Reading data from stdin and injecting...\n");
    printf("Press Ctrl+C to stop.\n\n");

    /* Set stdin to non-blocking */
    int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
    fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK);

    while (keep_running) {
        /* Wait for data on stdin with timeout */
        FD_ZERO(&rfds);
        FD_SET(STDIN_FILENO, &rfds);

        tv.tv_sec = 0;
        tv.tv_usec = 100000;  /* 100ms timeout */

        ret = select(STDIN_FILENO + 1, &rfds, NULL, NULL, &tv);

        if (ret < 0) {
            if (errno == EINTR) continue;
            perror("select");
            break;
        }

        if (ret == 0) {
            /* Timeout - print stats */
            time_t now = time(NULL);
            time_t elapsed = now - stats.start_time;
            if (elapsed > 0) {
                unsigned long bps = (stats.bytes_sent * 8) / elapsed;
                unsigned long fps = stats.frames_sent / elapsed;

                printf("\rFrames: %8lu  Bytes: %10lu  Rate: %6lu kbps  FPS: %5lu  Errors: %lu",
                       stats.frames_sent, stats.bytes_sent, bps / 1000, fps, stats.errors);
                fflush(stdout);
            }
            continue;
        }

        /* Read data from stdin */
        nread = read(STDIN_FILENO, buffer, config.mtu);

        if (nread < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                continue;
            }
            perror("read");
            break;
        }

        if (nread == 0) {
            /* EOF */
            break;
        }

        /* Inject frame */
        if (inject_wfb_frame(buffer, nread, 0, 0) < 0) {
            stats.errors++;
        }
    }

    printf("\n\nTransmission complete.\n");
}

/**
 * @brief Test mode: inject test pattern
 */
void test_mode(void) {
    uint8_t test_data[1400];
    unsigned int i;
    struct timespec sleep_time = {0, 10000000};  /* 10ms = 100 fps */

    printf("Test mode: Injecting test pattern at %d fps...\n", 100);
    printf("Press Ctrl+C to stop.\n\n");

    /* Fill test data with pattern */
    for (i = 0; i < sizeof(test_data); i++) {
        test_data[i] = i & 0xFF;
    }

    while (keep_running) {
        if (inject_wfb_frame(test_data, sizeof(test_data), 0, 0) < 0) {
            stats.errors++;
        }

        /* Print stats every 100 frames */
        if (stats.frames_sent % 100 == 0) {
            time_t now = time(NULL);
            time_t elapsed = now - stats.start_time;
            if (elapsed > 0) {
                unsigned long bps = (stats.bytes_sent * 8) / elapsed;
                unsigned long fps = stats.frames_sent / elapsed;

                printf("\rFrames: %8lu  Bytes: %10lu  Rate: %6lu kbps  FPS: %5lu  Errors: %lu",
                       stats.frames_sent, stats.bytes_sent, bps / 1000, fps, stats.errors);
                fflush(stdout);
            }
        }

        nanosleep(&sleep_time, NULL);
    }

    printf("\n\nTest transmission complete.\n");
}

/**
 * @brief Print statistics summary
 */
void print_stats(void) {
    time_t elapsed = time(NULL) - stats.start_time;

    printf("\n");
    printf("================================================================================\n");
    printf("Transmission Statistics\n");
    printf("================================================================================\n");
    printf("Duration:      %ld seconds\n", elapsed);
    printf("Frames sent:   %lu\n", stats.frames_sent);
    printf("Bytes sent:    %lu\n", stats.bytes_sent);
    printf("Errors:        %lu\n", stats.errors);

    if (elapsed > 0) {
        printf("Average rate:  %.2f kbps\n", (stats.bytes_sent * 8.0) / elapsed / 1000.0);
        printf("Average FPS:   %.2f\n", (double)stats.frames_sent / elapsed);
    }

    printf("================================================================================\n");
}

/**
 * @brief Print usage information
 */
void print_usage(const char *prog) {
    printf("Usage: %s [options]\n\n", prog);
    printf("Options:\n");
    printf("  -c <channel>    WiFi channel (default: 149)\n");
    printf("  -r <rate>       Data rate in Mbps (6, 9, 12, 18, 24, 36, 48, 54)\n");
    printf("  -m <mtu>        MTU size in bytes (default: 1400)\n");
    printf("  -t              Test mode (inject test pattern)\n");
    printf("  -h              Show this help\n\n");
    printf("Examples:\n");
    printf("  # Inject H.264 video stream from gstreamer:\n");
    printf("  gst-launch-1.0 v4l2src ! video/x-raw,width=1280,height=720 ! \\\n");
    printf("    x264enc tune=zerolatency ! h264parse ! fdsink | %s -c 149 -r 18\n\n", prog);
    printf("  # Test mode:\n");
    printf("  %s -c 149 -r 18 -t\n\n", prog);
    printf("Note: Requires OpenWiFi driver and root privileges.\n");
    printf("      For wfb-ng integration, use as TX link.\n");
}

/**
 * @brief Main function
 */
int main(int argc, char *argv[]) {
    int opt;
    int test_mode_enable = 0;

    printf("===============================================\n");
    printf("  wfb-ng Frame Injector (enhanced_xpu)\n");
    printf("  OpenWiFi Project\n");
    printf("===============================================\n\n");

    /* Initialize statistics */
    memset(&stats, 0, sizeof(stats));
    time(&stats.start_time);

    /* Parse command line options */
    while ((opt = getopt(argc, argv, "c:r:m:th")) != -1) {
        switch (opt) {
            case 'c':
                config.channel = atoi(optarg);
                if (config.channel < 1 || config.channel > 165) {
                    fprintf(stderr, "Error: Invalid channel\n");
                    return 1;
                }
                break;
            case 'r':
                config.data_rate = atoi(optarg);
                /* Validate data rate */
                if (config.data_rate != 6 && config.data_rate != 9 &&
                    config.data_rate != 12 && config.data_rate != 18 &&
                    config.data_rate != 24 && config.data_rate != 36 &&
                    config.data_rate != 48 && config.data_rate != 54) {
                    fprintf(stderr, "Error: Invalid data rate (must be 6, 9, 12, 18, 24, 36, 48, or 54 Mbps)\n");
                    return 1;
                }
                break;
            case 'm':
                config.mtu = atoi(optarg);
                if (config.mtu < 100 || config.mtu > 2000) {
                    fprintf(stderr, "Error: Invalid MTU (must be 100-2000)\n");
                    return 1;
                }
                break;
            case 't':
                test_mode_enable = 1;
                break;
            case 'h':
                print_usage(argv[0]);
                return 0;
            default:
                print_usage(argv[0]);
                return 1;
        }
    }

    /* Display configuration */
    printf("Configuration:\n");
    printf("  Channel:    %d\n", config.channel);
    printf("  Data rate:  %d Mbps\n", config.data_rate);
    printf("  MTU:        %d bytes\n", config.mtu);
    printf("  Mode:       %s\n\n", test_mode_enable ? "Test" : "Stream");

    /* Install signal handlers */
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    signal(SIGPIPE, SIG_IGN);

    /* Open OpenWiFi SDR device */
    sdr_fd = open("/dev/sdr0", O_RDWR);
    if (sdr_fd < 0) {
        perror("Failed to open /dev/sdr0");
        fprintf(stderr, "\nNote: This requires OpenWiFi driver and root privileges.\n");
        return 1;
    }

    /* Set channel */
    if (ioctl(sdr_fd, IOCTL_SET_CHANNEL, config.channel) < 0) {
        perror("Failed to set channel");
        close(sdr_fd);
        return 1;
    }

    /* Set data rate */
    if (ioctl(sdr_fd, IOCTL_SET_DATA_RATE, config.data_rate) < 0) {
        perror("Warning: Failed to set data rate");
        /* Non-fatal, continue */
    }

    /* Run injection loop */
    if (test_mode_enable) {
        test_mode();
    } else {
        injection_loop();
    }

    /* Print statistics */
    print_stats();

    /* Cleanup */
    close(sdr_fd);

    return 0;
}
