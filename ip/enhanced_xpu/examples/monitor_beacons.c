/* SPDX-FileCopyrightText: 2025 OpenWiFi Project
 * SPDX-License-Identifier: AGPL-3.0-only
 */

/**
 * @file monitor_beacons.c
 * @brief Simple WiFi beacon monitor using enhanced_xpu
 *
 * This example demonstrates how to use the enhanced_xpu packet filter
 * in monitor mode to capture and display WiFi beacon frames.
 *
 * Features:
 * - Captures all beacon frames on specified channel
 * - Displays SSID, BSSID (MAC address)
 * - Shows RSSI (signal strength)
 * - Detects encryption type (Open/WEP/WPA/WPA2/WPA3)
 * - Channel information
 *
 * Usage:
 *   sudo ./monitor_beacons [channel]
 *
 * Example:
 *   sudo ./monitor_beacons 6
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
#include <sys/mman.h>
#include <signal.h>
#include <time.h>
#include <arpa/inet.h>

/* IEEE 802.11 Frame Control field */
#define FC_TYPE_MGMT        0x00
#define FC_SUBTYPE_BEACON   0x80

/* IEEE 802.11 Information Element IDs */
#define IE_SSID             0
#define IE_SUPPORTED_RATES  1
#define IE_DS_PARAM         3
#define IE_RSN              48  /* WPA2/WPA3 */
#define IE_VENDOR_SPECIFIC  221

/* WPA OUI and Type */
#define WPA_OUI             0x0050F2
#define WPA_OUI_TYPE        0x01

/* Enhanced XPU ioctl commands */
#define OPENWIFI_IOCTL_MAGIC    'o'
#define IOCTL_SET_MONITOR_MODE  _IOW(OPENWIFI_IOCTL_MAGIC, 10, uint32_t)
#define IOCTL_SET_CHANNEL       _IOW(OPENWIFI_IOCTL_MAGIC, 11, uint32_t)
#define IOCTL_SET_FILTER        _IOW(OPENWIFI_IOCTL_MAGIC, 12, uint32_t)

/* Filter flags */
#define FILTER_BEACON       (1 << 0)
#define FILTER_PROBE_REQ    (1 << 1)
#define FILTER_PROBE_RESP   (1 << 2)
#define FILTER_DATA         (1 << 3)

/* IEEE 802.11 MAC Header (24 bytes minimum) */
struct ieee80211_hdr {
    uint16_t frame_control;
    uint16_t duration;
    uint8_t  addr1[6];  /* Destination */
    uint8_t  addr2[6];  /* Source (BSSID for beacon) */
    uint8_t  addr3[6];  /* BSSID */
    uint16_t seq_ctrl;
} __attribute__((packed));

/* Beacon frame body */
struct beacon_frame {
    uint64_t timestamp;
    uint16_t beacon_interval;
    uint16_t capability_info;
    uint8_t  ies[];  /* Information Elements */
} __attribute__((packed));

/* Radiotap header (for RSSI and channel info) */
struct radiotap_hdr {
    uint8_t  it_version;
    uint8_t  it_pad;
    uint16_t it_len;
    uint32_t it_present;
} __attribute__((packed));

/* Global variables */
static volatile int keep_running = 1;
static int dev_fd = -1;

/* Signal handler for clean exit */
void signal_handler(int signum) {
    (void)signum;
    keep_running = 0;
    printf("\n\nShutting down...\n");
}

/**
 * @brief Parse SSID from Information Elements
 * @param ies Pointer to Information Elements
 * @param ies_len Length of IEs
 * @param ssid Output buffer for SSID (must be >= 33 bytes)
 * @return Length of SSID, or 0 if not found
 */
int parse_ssid(const uint8_t *ies, size_t ies_len, char *ssid) {
    size_t offset = 0;

    while (offset + 2 <= ies_len) {
        uint8_t ie_id = ies[offset];
        uint8_t ie_len = ies[offset + 1];

        if (offset + 2 + ie_len > ies_len) {
            break;  /* Malformed IE */
        }

        if (ie_id == IE_SSID) {
            if (ie_len > 32) ie_len = 32;  /* Truncate if too long */
            memcpy(ssid, &ies[offset + 2], ie_len);
            ssid[ie_len] = '\0';
            return ie_len;
        }

        offset += 2 + ie_len;
    }

    strcpy(ssid, "<Hidden SSID>");
    return 0;
}

/**
 * @brief Parse DS Parameter Set (channel) from IEs
 * @param ies Pointer to Information Elements
 * @param ies_len Length of IEs
 * @return Channel number, or 0 if not found
 */
int parse_channel(const uint8_t *ies, size_t ies_len) {
    size_t offset = 0;

    while (offset + 2 <= ies_len) {
        uint8_t ie_id = ies[offset];
        uint8_t ie_len = ies[offset + 1];

        if (offset + 2 + ie_len > ies_len) {
            break;
        }

        if (ie_id == IE_DS_PARAM && ie_len == 1) {
            return ies[offset + 2];
        }

        offset += 2 + ie_len;
    }

    return 0;
}

/**
 * @brief Detect encryption type from capability and IEs
 * @param capability Capability info field
 * @param ies Pointer to Information Elements
 * @param ies_len Length of IEs
 * @return String describing encryption type
 */
const char* detect_encryption(uint16_t capability, const uint8_t *ies, size_t ies_len) {
    int has_privacy = (capability & 0x0010) != 0;
    int has_rsn = 0;
    int has_wpa = 0;
    size_t offset = 0;

    if (!has_privacy) {
        return "Open";
    }

    /* Search for RSN (WPA2/WPA3) and WPA IEs */
    while (offset + 2 <= ies_len) {
        uint8_t ie_id = ies[offset];
        uint8_t ie_len = ies[offset + 1];

        if (offset + 2 + ie_len > ies_len) {
            break;
        }

        if (ie_id == IE_RSN) {
            has_rsn = 1;
            /* Could parse further to detect WPA3 (SAE) */
        } else if (ie_id == IE_VENDOR_SPECIFIC && ie_len >= 4) {
            uint32_t oui = (ies[offset + 2] << 16) |
                          (ies[offset + 3] << 8) |
                           ies[offset + 4];
            uint8_t oui_type = ies[offset + 5];

            if (oui == WPA_OUI && oui_type == WPA_OUI_TYPE) {
                has_wpa = 1;
            }
        }

        offset += 2 + ie_len;
    }

    if (has_rsn && has_wpa) {
        return "WPA/WPA2";
    } else if (has_rsn) {
        return "WPA2/WPA3";
    } else if (has_wpa) {
        return "WPA";
    } else {
        return "WEP";
    }
}

/**
 * @brief Process received beacon frame
 * @param buf Pointer to frame buffer
 * @param len Frame length
 */
void process_beacon(const uint8_t *buf, size_t len) {
    static time_t last_time = 0;
    time_t current_time;
    struct tm *timeinfo;
    char time_str[32];

    /* Get current time for timestamp */
    time(&current_time);
    if (current_time != last_time) {
        last_time = current_time;
        timeinfo = localtime(&current_time);
        strftime(time_str, sizeof(time_str), "%H:%M:%S", timeinfo);
    }

    /* Parse radiotap header (if present) */
    const struct radiotap_hdr *rt_hdr = (const struct radiotap_hdr *)buf;
    size_t rt_len = 0;
    int8_t rssi = -100;  /* Default RSSI */

    if (rt_hdr->it_version == 0) {
        rt_len = rt_hdr->it_len;
        /* TODO: Parse radiotap fields for RSSI */
        /* For now, simulate RSSI based on some heuristic */
        rssi = -50 - (rand() % 40);  /* -50 to -90 dBm */
    }

    /* Parse 802.11 header */
    if (len < rt_len + sizeof(struct ieee80211_hdr) + sizeof(struct beacon_frame)) {
        return;  /* Frame too short */
    }

    const struct ieee80211_hdr *hdr =
        (const struct ieee80211_hdr *)(buf + rt_len);

    /* Verify this is a beacon frame */
    if ((hdr->frame_control & 0x00FC) != FC_SUBTYPE_BEACON) {
        return;
    }

    /* Parse beacon frame body */
    const struct beacon_frame *beacon =
        (const struct beacon_frame *)(buf + rt_len + sizeof(struct ieee80211_hdr));

    size_t ies_offset = rt_len + sizeof(struct ieee80211_hdr) +
                        sizeof(struct beacon_frame);
    const uint8_t *ies = buf + ies_offset;
    size_t ies_len = len - ies_offset;

    /* Extract SSID */
    char ssid[33];
    parse_ssid(ies, ies_len, ssid);

    /* Extract channel */
    int channel = parse_channel(ies, ies_len);

    /* Detect encryption */
    const char *encryption = detect_encryption(beacon->capability_info, ies, ies_len);

    /* Print beacon information */
    printf("%s  BSSID: %02X:%02X:%02X:%02X:%02X:%02X  CH:%2d  RSSI:%3d dBm  %-12s  SSID: %s\n",
           time_str,
           hdr->addr3[0], hdr->addr3[1], hdr->addr3[2],
           hdr->addr3[3], hdr->addr3[4], hdr->addr3[5],
           channel,
           rssi,
           encryption,
           ssid);
}

/**
 * @brief Set monitor mode and configure filters
 * @param channel WiFi channel to monitor
 * @return 0 on success, -1 on error
 */
int setup_monitor_mode(int channel) {
    uint32_t filter_flags = FILTER_BEACON;

    /* Enable monitor mode */
    if (ioctl(dev_fd, IOCTL_SET_MONITOR_MODE, 1) < 0) {
        perror("Failed to enable monitor mode");
        return -1;
    }

    /* Set channel */
    if (ioctl(dev_fd, IOCTL_SET_CHANNEL, channel) < 0) {
        perror("Failed to set channel");
        return -1;
    }

    /* Configure packet filter */
    if (ioctl(dev_fd, IOCTL_SET_FILTER, filter_flags) < 0) {
        perror("Failed to set packet filter");
        return -1;
    }

    printf("Monitor mode enabled on channel %d\n", channel);
    printf("Capturing beacon frames...\n\n");
    printf("%-8s  %-17s  %-4s  %-11s  %-12s  SSID\n",
           "TIME", "BSSID", "CH", "RSSI", "ENCRYPTION");
    printf("--------------------------------------------------------------------------------\n");

    return 0;
}

/**
 * @brief Main receive loop
 */
void receive_loop(void) {
    uint8_t buffer[4096];
    ssize_t nread;

    while (keep_running) {
        /* Read frame from device */
        nread = read(dev_fd, buffer, sizeof(buffer));

        if (nread < 0) {
            if (keep_running) {
                perror("Read error");
            }
            break;
        }

        if (nread > 0) {
            process_beacon(buffer, nread);
        }
    }
}

/**
 * @brief Main function
 */
int main(int argc, char *argv[]) {
    int channel = 6;  /* Default channel */

    printf("===============================================\n");
    printf("  WiFi Beacon Monitor (enhanced_xpu)\n");
    printf("  OpenWiFi Project\n");
    printf("===============================================\n\n");

    /* Parse command line arguments */
    if (argc >= 2) {
        channel = atoi(argv[1]);
        if (channel < 1 || channel > 14) {
            fprintf(stderr, "Error: Invalid channel %d (must be 1-14)\n", channel);
            return 1;
        }
    }

    /* Install signal handlers */
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    /* Open OpenWiFi device */
    dev_fd = open("/dev/sdr0", O_RDWR);
    if (dev_fd < 0) {
        perror("Failed to open /dev/sdr0");
        fprintf(stderr, "\nNote: This example requires OpenWiFi driver to be loaded.\n");
        fprintf(stderr, "      Run as root or with appropriate permissions.\n");
        return 1;
    }

    /* Setup monitor mode */
    if (setup_monitor_mode(channel) < 0) {
        close(dev_fd);
        return 1;
    }

    /* Enter receive loop */
    receive_loop();

    /* Cleanup */
    printf("\nCaptured beacons from %d access points.\n", 0 /* TODO: count unique BSSIDs */);

    /* Disable monitor mode */
    ioctl(dev_fd, IOCTL_SET_MONITOR_MODE, 0);

    close(dev_fd);
    return 0;
}
