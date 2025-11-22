/* SPDX-FileCopyrightText: 2025 OpenWiFi Project
 * SPDX-License-Identifier: AGPL-3.0-only
 */

/**
 * @file inject_beacon.c
 * @brief Beacon frame injector using enhanced_xpu frame injection
 *
 * This example demonstrates how to transmit custom beacon frames
 * using the enhanced_xpu frame injection capabilities.
 *
 * Features:
 * - Transmits custom beacon frames
 * - Configurable SSID, BSSID, channel
 * - Configurable beacon interval
 * - Supports encryption advertisement (Open/WPA2)
 * - Can create fake AP or test beacon
 *
 * Usage:
 *   sudo ./inject_beacon -s <SSID> [-c channel] [-i interval_ms] [-b BSSID]
 *
 * Example:
 *   sudo ./inject_beacon -s "TestAP" -c 6 -i 100
 *
 * WARNING: Frame injection may be illegal in some jurisdictions.
 *          Use only for testing in controlled environments!
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
#include <signal.h>
#include <time.h>
#include <getopt.h>

/* IEEE 802.11 Frame Control */
#define FC_TYPE_MGMT        0x00
#define FC_SUBTYPE_BEACON   0x80

/* IEEE 802.11 Capability bits */
#define CAP_ESS             0x0001
#define CAP_IBSS            0x0002
#define CAP_PRIVACY         0x0010
#define CAP_SHORT_PREAMBLE  0x0020
#define CAP_SHORT_SLOT      0x0400

/* Information Element IDs */
#define IE_SSID             0
#define IE_SUPPORTED_RATES  1
#define IE_DS_PARAM         3
#define IE_TIM              5
#define IE_ERP              42
#define IE_EXT_RATES        50
#define IE_RSN              48
#define IE_HT_CAP           45
#define IE_HT_INFO          61

/* Enhanced XPU ioctl commands */
#define OPENWIFI_IOCTL_MAGIC        'o'
#define IOCTL_SET_CHANNEL           _IOW(OPENWIFI_IOCTL_MAGIC, 11, uint32_t)
#define IOCTL_INJECT_FRAME          _IOW(OPENWIFI_IOCTL_MAGIC, 20, void*)
#define IOCTL_SET_TX_POWER          _IOW(OPENWIFI_IOCTL_MAGIC, 21, uint32_t)

/* IEEE 802.11 MAC Header */
struct ieee80211_hdr {
    uint16_t frame_control;
    uint16_t duration;
    uint8_t  addr1[6];  /* DA (broadcast for beacon) */
    uint8_t  addr2[6];  /* SA (BSSID) */
    uint8_t  addr3[6];  /* BSSID */
    uint16_t seq_ctrl;
} __attribute__((packed));

/* Beacon frame body */
struct beacon_frame {
    uint64_t timestamp;
    uint16_t beacon_interval;
    uint16_t capability_info;
} __attribute__((packed));

/* Frame injection parameters */
struct inject_params {
    uint8_t  *frame;
    uint32_t  length;
    uint32_t  rate;       /* Data rate (Mbps) */
    uint32_t  retries;    /* Number of retries (0 for broadcast) */
    uint32_t  flags;      /* Injection flags */
} __attribute__((packed));

/* Global variables */
static volatile int keep_running = 1;
static int dev_fd = -1;
static uint16_t seq_num = 0;

/* Configuration */
struct config {
    char ssid[33];
    uint8_t bssid[6];
    int channel;
    int interval_ms;
    int encryption;  /* 0=Open, 1=WPA2 */
    int tx_power;    /* dBm */
} config = {
    .ssid = "OpenWiFi-Test",
    .bssid = {0x02, 0x00, 0x00, 0x00, 0x00, 0x01},  /* Locally administered */
    .channel = 6,
    .interval_ms = 100,
    .encryption = 0,
    .tx_power = 20
};

/* Signal handler */
void signal_handler(int signum) {
    (void)signum;
    keep_running = 0;
    printf("\n\nStopping beacon transmission...\n");
}

/**
 * @brief Build SSID Information Element
 * @param buf Output buffer
 * @param ssid SSID string
 * @return Number of bytes written
 */
size_t build_ssid_ie(uint8_t *buf, const char *ssid) {
    size_t ssid_len = strlen(ssid);
    if (ssid_len > 32) ssid_len = 32;

    buf[0] = IE_SSID;
    buf[1] = ssid_len;
    memcpy(&buf[2], ssid, ssid_len);

    return 2 + ssid_len;
}

/**
 * @brief Build Supported Rates IE
 * @param buf Output buffer
 * @return Number of bytes written
 */
size_t build_rates_ie(uint8_t *buf) {
    /* 802.11g rates: 1, 2, 5.5, 11, 6, 9, 12, 18 Mbps */
    const uint8_t rates[] = {
        0x82,  /* 1 Mbps (basic) */
        0x84,  /* 2 Mbps (basic) */
        0x8B,  /* 5.5 Mbps (basic) */
        0x96,  /* 11 Mbps (basic) */
        0x0C,  /* 6 Mbps */
        0x12,  /* 9 Mbps */
        0x18,  /* 12 Mbps */
        0x24   /* 18 Mbps */
    };

    buf[0] = IE_SUPPORTED_RATES;
    buf[1] = sizeof(rates);
    memcpy(&buf[2], rates, sizeof(rates));

    return 2 + sizeof(rates);
}

/**
 * @brief Build Extended Supported Rates IE
 * @param buf Output buffer
 * @return Number of bytes written
 */
size_t build_ext_rates_ie(uint8_t *buf) {
    /* 802.11g extended rates: 24, 36, 48, 54 Mbps */
    const uint8_t ext_rates[] = {
        0x30,  /* 24 Mbps */
        0x48,  /* 36 Mbps */
        0x60,  /* 48 Mbps */
        0x6C   /* 54 Mbps */
    };

    buf[0] = IE_EXT_RATES;
    buf[1] = sizeof(ext_rates);
    memcpy(&buf[2], ext_rates, sizeof(ext_rates));

    return 2 + sizeof(ext_rates);
}

/**
 * @brief Build DS Parameter Set IE (channel)
 * @param buf Output buffer
 * @param channel Channel number
 * @return Number of bytes written
 */
size_t build_ds_param_ie(uint8_t *buf, int channel) {
    buf[0] = IE_DS_PARAM;
    buf[1] = 1;
    buf[2] = channel;

    return 3;
}

/**
 * @brief Build TIM (Traffic Indication Map) IE
 * @param buf Output buffer
 * @return Number of bytes written
 */
size_t build_tim_ie(uint8_t *buf) {
    buf[0] = IE_TIM;
    buf[1] = 4;  /* Length */
    buf[2] = 0;  /* DTIM Count */
    buf[3] = 1;  /* DTIM Period */
    buf[4] = 0;  /* Bitmap Control */
    buf[5] = 0;  /* Partial Virtual Bitmap */

    return 6;
}

/**
 * @brief Build RSN (WPA2) Information Element
 * @param buf Output buffer
 * @return Number of bytes written
 */
size_t build_rsn_ie(uint8_t *buf) {
    /* WPA2-PSK with AES-CCMP */
    const uint8_t rsn[] = {
        0x30,        /* IE ID: RSN */
        0x14,        /* Length: 20 bytes */
        0x01, 0x00,  /* Version: 1 */
        0x00, 0x0F, 0xAC, 0x04,  /* Group Cipher: CCMP */
        0x01, 0x00,  /* Pairwise Cipher Count: 1 */
        0x00, 0x0F, 0xAC, 0x04,  /* Pairwise Cipher: CCMP */
        0x01, 0x00,  /* AKM Suite Count: 1 */
        0x00, 0x0F, 0xAC, 0x02,  /* AKM Suite: PSK */
        0x00, 0x00   /* RSN Capabilities */
    };

    memcpy(buf, rsn, sizeof(rsn));
    return sizeof(rsn);
}

/**
 * @brief Build complete beacon frame
 * @param buf Output buffer
 * @param buflen Buffer length
 * @return Frame length, or -1 on error
 */
int build_beacon_frame(uint8_t *buf, size_t buflen) {
    size_t offset = 0;

    /* MAC Header */
    struct ieee80211_hdr *hdr = (struct ieee80211_hdr *)buf;
    memset(hdr, 0, sizeof(*hdr));

    hdr->frame_control = FC_TYPE_MGMT | FC_SUBTYPE_BEACON;
    hdr->duration = 0;

    /* Destination: Broadcast */
    memset(hdr->addr1, 0xFF, 6);

    /* Source & BSSID */
    memcpy(hdr->addr2, config.bssid, 6);
    memcpy(hdr->addr3, config.bssid, 6);

    /* Sequence control */
    hdr->seq_ctrl = seq_num++ << 4;

    offset += sizeof(*hdr);

    /* Beacon Frame Body */
    struct beacon_frame *beacon = (struct beacon_frame *)(buf + offset);

    /* Timestamp (will be filled by hardware) */
    beacon->timestamp = 0;

    /* Beacon interval (in TUs, 1 TU = 1024 μs) */
    beacon->beacon_interval = (config.interval_ms * 1000) / 1024;

    /* Capability Info */
    beacon->capability_info = CAP_ESS | CAP_SHORT_PREAMBLE | CAP_SHORT_SLOT;
    if (config.encryption) {
        beacon->capability_info |= CAP_PRIVACY;
    }

    offset += sizeof(*beacon);

    /* Information Elements */
    offset += build_ssid_ie(buf + offset, config.ssid);
    offset += build_rates_ie(buf + offset);
    offset += build_ds_param_ie(buf + offset, config.channel);
    offset += build_tim_ie(buf + offset);
    offset += build_ext_rates_ie(buf + offset);

    /* Add RSN IE if encryption is enabled */
    if (config.encryption) {
        offset += build_rsn_ie(buf + offset);
    }

    if (offset > buflen) {
        fprintf(stderr, "Error: Frame too large (%zu > %zu)\n", offset, buflen);
        return -1;
    }

    return offset;
}

/**
 * @brief Inject beacon frame
 * @return 0 on success, -1 on error
 */
int inject_beacon(void) {
    uint8_t frame[2048];
    int frame_len;

    /* Build beacon frame */
    frame_len = build_beacon_frame(frame, sizeof(frame));
    if (frame_len < 0) {
        return -1;
    }

    /* Prepare injection parameters */
    struct inject_params params = {
        .frame = frame,
        .length = frame_len,
        .rate = 6,      /* 6 Mbps (management frames) */
        .retries = 0,   /* No retries for broadcast */
        .flags = 0
    };

    /* Inject frame */
    if (ioctl(dev_fd, IOCTL_INJECT_FRAME, &params) < 0) {
        perror("Frame injection failed");
        return -1;
    }

    return 0;
}

/**
 * @brief Beacon transmission loop
 */
void beacon_loop(void) {
    struct timespec sleep_time;
    unsigned long count = 0;

    sleep_time.tv_sec = config.interval_ms / 1000;
    sleep_time.tv_nsec = (config.interval_ms % 1000) * 1000000L;

    printf("Transmitting beacons (Ctrl+C to stop)...\n\n");

    while (keep_running) {
        if (inject_beacon() == 0) {
            count++;
            if (count % 10 == 0) {
                printf("\rBeacons transmitted: %lu", count);
                fflush(stdout);
            }
        } else {
            fprintf(stderr, "\nError injecting beacon #%lu\n", count);
        }

        nanosleep(&sleep_time, NULL);
    }

    printf("\n\nTotal beacons transmitted: %lu\n", count);
}

/**
 * @brief Parse MAC address from string
 * @param str MAC address string (format: XX:XX:XX:XX:XX:XX)
 * @param mac Output MAC address
 * @return 0 on success, -1 on error
 */
int parse_mac(const char *str, uint8_t *mac) {
    return sscanf(str, "%hhx:%hhx:%hhx:%hhx:%hhx:%hhx",
                  &mac[0], &mac[1], &mac[2], &mac[3], &mac[4], &mac[5]) == 6 ? 0 : -1;
}

/**
 * @brief Print usage information
 */
void print_usage(const char *prog) {
    printf("Usage: %s -s <SSID> [options]\n\n", prog);
    printf("Options:\n");
    printf("  -s <SSID>       Set SSID (required)\n");
    printf("  -c <channel>    Set channel (1-14, default: 6)\n");
    printf("  -i <interval>   Set beacon interval in ms (default: 100)\n");
    printf("  -b <BSSID>      Set BSSID (format: XX:XX:XX:XX:XX:XX)\n");
    printf("  -e              Enable WPA2 encryption advertisement\n");
    printf("  -p <power>      Set TX power in dBm (default: 20)\n");
    printf("  -h              Show this help\n\n");
    printf("Example:\n");
    printf("  %s -s \"TestAP\" -c 6 -i 100 -e\n\n", prog);
    printf("WARNING: Unauthorized frame injection may be illegal!\n");
}

/**
 * @brief Main function
 */
int main(int argc, char *argv[]) {
    int opt;
    int ssid_set = 0;

    printf("===============================================\n");
    printf("  WiFi Beacon Injector (enhanced_xpu)\n");
    printf("  OpenWiFi Project\n");
    printf("===============================================\n\n");

    /* Parse command line options */
    while ((opt = getopt(argc, argv, "s:c:i:b:ep:h")) != -1) {
        switch (opt) {
            case 's':
                strncpy(config.ssid, optarg, sizeof(config.ssid) - 1);
                ssid_set = 1;
                break;
            case 'c':
                config.channel = atoi(optarg);
                if (config.channel < 1 || config.channel > 14) {
                    fprintf(stderr, "Error: Invalid channel (must be 1-14)\n");
                    return 1;
                }
                break;
            case 'i':
                config.interval_ms = atoi(optarg);
                if (config.interval_ms < 10 || config.interval_ms > 10000) {
                    fprintf(stderr, "Error: Invalid interval (must be 10-10000 ms)\n");
                    return 1;
                }
                break;
            case 'b':
                if (parse_mac(optarg, config.bssid) < 0) {
                    fprintf(stderr, "Error: Invalid BSSID format\n");
                    return 1;
                }
                break;
            case 'e':
                config.encryption = 1;
                break;
            case 'p':
                config.tx_power = atoi(optarg);
                break;
            case 'h':
                print_usage(argv[0]);
                return 0;
            default:
                print_usage(argv[0]);
                return 1;
        }
    }

    if (!ssid_set) {
        fprintf(stderr, "Error: SSID is required\n\n");
        print_usage(argv[0]);
        return 1;
    }

    /* Display configuration */
    printf("Configuration:\n");
    printf("  SSID:       %s\n", config.ssid);
    printf("  BSSID:      %02X:%02X:%02X:%02X:%02X:%02X\n",
           config.bssid[0], config.bssid[1], config.bssid[2],
           config.bssid[3], config.bssid[4], config.bssid[5]);
    printf("  Channel:    %d\n", config.channel);
    printf("  Interval:   %d ms\n", config.interval_ms);
    printf("  Encryption: %s\n", config.encryption ? "WPA2" : "Open");
    printf("  TX Power:   %d dBm\n\n", config.tx_power);

    /* Install signal handlers */
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    /* Open OpenWiFi device */
    dev_fd = open("/dev/sdr0", O_RDWR);
    if (dev_fd < 0) {
        perror("Failed to open /dev/sdr0");
        fprintf(stderr, "\nNote: This requires OpenWiFi driver and root privileges.\n");
        return 1;
    }

    /* Set channel */
    if (ioctl(dev_fd, IOCTL_SET_CHANNEL, config.channel) < 0) {
        perror("Failed to set channel");
        close(dev_fd);
        return 1;
    }

    /* Set TX power */
    if (ioctl(dev_fd, IOCTL_SET_TX_POWER, config.tx_power) < 0) {
        perror("Failed to set TX power");
        /* Non-fatal, continue */
    }

    /* Start beacon transmission */
    beacon_loop();

    /* Cleanup */
    close(dev_fd);
    return 0;
}
