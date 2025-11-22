/* SPDX-FileCopyrightText: 2025 OpenWiFi Project
 * SPDX-License-Identifier: AGPL-3.0-only
 */

/**
 * @file remote_id_transmitter.c
 * @brief Drone Remote ID transmitter using enhanced_xpu (ASTM F3411 compliant)
 *
 * This example implements a complete drone Remote ID transmitter
 * compliant with ASTM F3411-22 standard using WiFi NAN transport.
 *
 * Features:
 * - Reads GPS data from serial port (NMEA)
 * - Generates Location messages (Type 1) at 1 Hz
 * - Generates Basic ID message (Type 0)
 * - Transmits via WiFi NAN (Neighbor Awareness Networking)
 * - ASTM F3411 compliant message format
 * - Can integrate with flight controllers (MAVLink support optional)
 *
 * Usage:
 *   sudo ./remote_id_transmitter -i <UAS_ID> [-g /dev/ttyUSB0] [-c channel]
 *
 * Example:
 *   sudo ./remote_id_transmitter -i "DRONE123456789" -g /dev/ttyUSB0 -c 6
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
#include <errno.h>
#include <termios.h>
#include <getopt.h>
#include <math.h>

#include "../include/remote_id_types.h"

/* Enhanced XPU ioctl commands */
#define OPENWIFI_IOCTL_MAGIC        'o'
#define IOCTL_SET_CHANNEL           _IOW(OPENWIFI_IOCTL_MAGIC, 11, uint32_t)
#define IOCTL_INJECT_FRAME          _IOW(OPENWIFI_IOCTL_MAGIC, 20, void*)

/* Frame injection parameters */
struct inject_params {
    uint8_t  *frame;
    uint32_t  length;
    uint32_t  rate;
    uint32_t  retries;
    uint32_t  flags;
} __attribute__((packed));

/* GPS data structure */
struct gps_data {
    double latitude;       /* Degrees */
    double longitude;      /* Degrees */
    double altitude;       /* Meters (MSL) */
    double speed;          /* m/s */
    double track;          /* Degrees (0-360) */
    float  hdop;           /* Horizontal dilution of precision */
    int    satellites;     /* Number of satellites */
    int    fix_quality;    /* 0=invalid, 1=GPS, 2=DGPS */
    time_t timestamp;
};

/* Drone state */
struct drone_state {
    char uas_id[21];       /* UAS ID (Serial number) */
    uint8_t ua_type;       /* UA Type (1=Aeroplane, 2=Helicopter, 3=Multirotor, etc.) */
    struct gps_data gps;
    uint8_t operator_id[20];
    int channel;
};

/* Global variables */
static volatile int keep_running = 1;
static int sdr_fd = -1;
static int gps_fd = -1;
static struct drone_state drone;

/* NAN cluster ID (broadcast) */
static const uint8_t NAN_CLUSTER_ID[6] = {0x50, 0x6F, 0x9A, 0x01, 0x00, 0x00};

/* Signal handler */
void signal_handler(int signum) {
    (void)signum;
    keep_running = 0;
    printf("\n\nStopping Remote ID transmission...\n");
}

/**
 * @brief Parse NMEA GPGGA sentence (GPS fix data)
 * @param sentence NMEA sentence
 * @param gps Output GPS data
 * @return 0 on success, -1 on error
 */
int parse_gpgga(const char *sentence, struct gps_data *gps) {
    char talker[10], msg_id[10];
    double lat, lon, alt;
    int lat_deg, lon_deg;
    double lat_min, lon_min;
    char lat_dir, lon_dir;
    int fix_quality, num_sats;
    float hdop;

    /* Parse GPGGA: $GPGGA,hhmmss.ss,ddmm.mmmm,N,dddmm.mmmm,E,q,ss,h.h,a.a,M,g.g,M,,*hh */
    if (sscanf(sentence, "$%[^,],%*[^,],%lf,%c,%lf,%c,%d,%d,%f,%lf,M",
               talker, &lat, &lat_dir, &lon, &lon_dir,
               &fix_quality, &num_sats, &hdop, &alt) < 9) {
        return -1;
    }

    /* Convert from DDMM.MMMM to decimal degrees */
    lat_deg = (int)(lat / 100);
    lat_min = lat - (lat_deg * 100);
    gps->latitude = lat_deg + (lat_min / 60.0);
    if (lat_dir == 'S') gps->latitude = -gps->latitude;

    lon_deg = (int)(lon / 100);
    lon_min = lon - (lon_deg * 100);
    gps->longitude = lon_deg + (lon_min / 60.0);
    if (lon_dir == 'W') gps->longitude = -gps->longitude;

    gps->altitude = alt;
    gps->fix_quality = fix_quality;
    gps->satellites = num_sats;
    gps->hdop = hdop;
    time(&gps->timestamp);

    return 0;
}

/**
 * @brief Parse NMEA GPRMC sentence (Recommended Minimum)
 * @param sentence NMEA sentence
 * @param gps Output GPS data
 * @return 0 on success, -1 on error
 */
int parse_gprmc(const char *sentence, struct gps_data *gps) {
    char status;
    double lat, lon, speed_knots, track;
    char lat_dir, lon_dir;

    /* Parse GPRMC: $GPRMC,hhmmss.ss,A,ddmm.mmmm,N,dddmm.mmmm,E,s.s,t.t,ddmmyy,,,A*hh */
    if (sscanf(sentence, "$GPRMC,%*[^,],%c,%lf,%c,%lf,%c,%lf,%lf",
               &status, &lat, &lat_dir, &lon, &lon_dir, &speed_knots, &track) < 7) {
        return -1;
    }

    if (status != 'A') {
        return -1;  /* Invalid fix */
    }

    /* Convert speed from knots to m/s */
    gps->speed = speed_knots * 0.514444;
    gps->track = track;

    return 0;
}

/**
 * @brief Read and parse GPS data from serial port
 * @param gps Output GPS data
 * @return 0 on success, -1 on error
 */
int read_gps_data(struct gps_data *gps) {
    static char buffer[256];
    static size_t buf_len = 0;
    char c;
    ssize_t nread;

    if (gps_fd < 0) {
        /* Simulate GPS for testing */
        gps->latitude = 37.7749 + (rand() % 1000) / 100000.0;
        gps->longitude = -122.4194 + (rand() % 1000) / 100000.0;
        gps->altitude = 50.0 + (rand() % 100);
        gps->speed = 5.0 + (rand() % 10);
        gps->track = rand() % 360;
        gps->fix_quality = 1;
        gps->satellites = 8;
        gps->hdop = 1.2;
        time(&gps->timestamp);
        return 0;
    }

    /* Read NMEA sentences from GPS */
    while ((nread = read(gps_fd, &c, 1)) > 0) {
        if (c == '$') {
            buf_len = 0;
        }

        if (buf_len < sizeof(buffer) - 1) {
            buffer[buf_len++] = c;
        }

        if (c == '\n') {
            buffer[buf_len] = '\0';

            /* Parse sentence */
            if (strstr(buffer, "GPGGA") || strstr(buffer, "GNGGA")) {
                parse_gpgga(buffer, gps);
            } else if (strstr(buffer, "GPRMC") || strstr(buffer, "GNRMC")) {
                parse_gprmc(buffer, gps);
            }

            buf_len = 0;
            return 0;
        }
    }

    return -1;
}

/**
 * @brief Create Basic ID message (Type 0)
 * @param msg Output message
 * @param uas_id UAS ID string
 * @param ua_type UA type
 */
void create_basic_id_message(remote_id_message_t *msg, const char *uas_id, uint8_t ua_type) {
    memset(msg, 0, sizeof(*msg));

    msg->basic_id.msg_type = REMOTE_ID_BASIC_ID;
    msg->basic_id.id_type = 0;  /* Serial Number */
    msg->basic_id.ua_type = ua_type;

    /* Copy UAS ID (pad with zeros) */
    strncpy((char *)msg->basic_id.uas_id, uas_id, sizeof(msg->basic_id.uas_id));
}

/**
 * @brief Create Location message (Type 1)
 * @param msg Output message
 * @param gps GPS data
 */
void create_location_message(remote_id_message_t *msg, const struct gps_data *gps) {
    memset(msg, 0, sizeof(*msg));

    msg->location.msg_type = REMOTE_ID_LOCATION;
    msg->location.status = 0x00;  /* Undeclared */

    /* Direction (0-360 degrees, 1 degree resolution) */
    msg->location.direction = (uint8_t)gps->track;

    /* Horizontal speed (0-254.25 m/s, 0.25 m/s resolution) */
    msg->location.speed_horiz = (uint8_t)(gps->speed / 0.25);
    if (msg->location.speed_horiz > 254) msg->location.speed_horiz = 254;

    /* Vertical speed (assume 0 for now) */
    msg->location.speed_vert = 0;

    /* Latitude (±90 degrees, 1e-7 degree resolution) */
    msg->location.latitude = (int32_t)(gps->latitude * 1e7);

    /* Longitude (±180 degrees, 1e-7 degree resolution) */
    msg->location.longitude = (int32_t)(gps->longitude * 1e7);

    /* Altitude barometric (0.5 m resolution) */
    msg->location.altitude_baro = (int16_t)(gps->altitude / 0.5);

    /* Altitude geodetic (WGS84) */
    msg->location.altitude_geo = (int16_t)(gps->altitude / 0.5);

    /* Height AGL (assume 50m for testing) */
    msg->location.height_agl = 50;

    /* Accuracy (based on HDOP) */
    float horiz_accuracy = gps->hdop * 5.0;  /* Rough approximation */
    msg->location.horiz_accuracy = remote_id_encode_accuracy(horiz_accuracy);
    msg->location.vert_accuracy = remote_id_encode_accuracy(horiz_accuracy * 1.5);
    msg->location.baro_accuracy = 1;  /* 1 meter */
    msg->location.speed_accuracy = 1;  /* 1 m/s */

    /* Timestamp (tenths of seconds since hour) */
    struct tm *tm_info = localtime(&gps->timestamp);
    msg->location.timestamp = (tm_info->tm_min * 60 + tm_info->tm_sec) * 10;
}

/**
 * @brief Build NAN action frame with Remote ID message
 * @param buf Output buffer
 * @param buflen Buffer length
 * @param rid_msg Remote ID message
 * @return Frame length, or -1 on error
 */
int build_nan_remote_id_frame(uint8_t *buf, size_t buflen, const remote_id_message_t *rid_msg) {
    const uint8_t service_id[] = REMOTE_ID_SERVICE_ID;
    size_t offset = 0;

    if (buflen < 200) return -1;

    /* IEEE 802.11 MAC Header */
    nan_action_frame_t *frame = (nan_action_frame_t *)buf;

    frame->frame_control = 0x00D0;  /* Action frame */
    frame->duration = 0;

    /* Destination: Broadcast */
    memset(frame->da, 0xFF, 6);

    /* Source: Local MAC (use random locally administered) */
    frame->sa[0] = 0x02;  /* Locally administered */
    frame->sa[1] = 0x00;
    frame->sa[2] = 0x00;
    memcpy(&frame->sa[3], &rid_msg->location.timestamp, 3);

    /* BSSID: NAN Cluster ID */
    memcpy(frame->bssid, NAN_CLUSTER_ID, 6);

    /* Sequence control */
    static uint16_t seq = 0;
    frame->seq_ctrl = seq++ << 4;

    /* Public Action Frame fields */
    frame->category = 0x04;  /* Public Action */
    frame->action = 0x09;    /* Vendor Specific Protected */
    frame->oui[0] = 0x50;
    frame->oui[1] = 0x6F;
    frame->oui[2] = 0x9A;
    frame->oui_type = 0x13;  /* NAN */
    frame->oui_subtype = 0x00;
    frame->dialog_token = 0;

    offset = sizeof(nan_action_frame_t) - sizeof(frame->attributes);

    /* NAN Service Descriptor Attribute */
    nan_service_descriptor_t *desc = (nan_service_descriptor_t *)(buf + offset);

    desc->attr_id = NAN_ATTR_SERVICE_DESCRIPTOR;
    desc->length = 6 + 1 + 1 + 1 + 1 + 1 + REMOTE_ID_MESSAGE_SIZE;  /* service_id + 5 bytes + msg */

    memcpy(desc->service_id, service_id, 6);
    desc->instance_id = 0x01;
    desc->requestor_instance_id = 0x00;
    desc->service_control = 0x00;
    desc->binding_bitmap = 0x00;
    desc->service_info_len = REMOTE_ID_MESSAGE_SIZE;

    /* Copy Remote ID message into service info */
    memcpy(desc->service_info, rid_msg->raw, REMOTE_ID_MESSAGE_SIZE);

    offset += 3 + 6 + 5 + REMOTE_ID_MESSAGE_SIZE;  /* attr header + fields + msg */

    return offset;
}

/**
 * @brief Transmit Remote ID message
 * @param msg Remote ID message
 * @return 0 on success, -1 on error
 */
int transmit_remote_id(const remote_id_message_t *msg) {
    uint8_t frame[512];
    int frame_len;

    /* Build NAN frame */
    frame_len = build_nan_remote_id_frame(frame, sizeof(frame), msg);
    if (frame_len < 0) {
        fprintf(stderr, "Error building NAN frame\n");
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
    if (ioctl(sdr_fd, IOCTL_INJECT_FRAME, &params) < 0) {
        perror("Frame injection failed");
        return -1;
    }

    return 0;
}

/**
 * @brief Main Remote ID transmission loop
 */
void remote_id_loop(void) {
    remote_id_message_t basic_id_msg, location_msg;
    unsigned long count = 0;
    struct timespec sleep_time = {1, 0};  /* 1 second (1 Hz) */

    /* Create Basic ID message (static) */
    create_basic_id_message(&basic_id_msg, drone.uas_id, drone.ua_type);

    printf("Starting Remote ID transmission (Ctrl+C to stop)...\n\n");
    printf("%-8s  %-12s  %-12s  %-8s  %-8s  %-8s  %-4s\n",
           "COUNT", "LATITUDE", "LONGITUDE", "ALTITUDE", "SPEED", "TRACK", "SATS");
    printf("--------------------------------------------------------------------------------\n");

    while (keep_running) {
        /* Read GPS data */
        if (read_gps_data(&drone.gps) < 0) {
            fprintf(stderr, "Warning: GPS read failed\n");
        }

        /* Create Location message */
        create_location_message(&location_msg, &drone.gps);

        /* Transmit Basic ID message */
        if (transmit_remote_id(&basic_id_msg) < 0) {
            fprintf(stderr, "Error transmitting Basic ID\n");
        }

        usleep(100000);  /* 100ms delay between messages */

        /* Transmit Location message */
        if (transmit_remote_id(&location_msg) < 0) {
            fprintf(stderr, "Error transmitting Location\n");
        }

        count++;

        /* Print status */
        printf("\r%8lu  %12.7f  %12.7f  %8.1fm  %7.2fm/s  %7.1f°  %4d",
               count,
               drone.gps.latitude,
               drone.gps.longitude,
               drone.gps.altitude,
               drone.gps.speed,
               drone.gps.track,
               drone.gps.satellites);
        fflush(stdout);

        /* Sleep until next transmission (1 Hz) */
        nanosleep(&sleep_time, NULL);
    }

    printf("\n\nTotal transmissions: %lu\n", count);
}

/**
 * @brief Open GPS serial port
 * @param device GPS device path
 * @return File descriptor, or -1 on error
 */
int open_gps_port(const char *device) {
    int fd;
    struct termios tty;

    fd = open(device, O_RDONLY | O_NOCTTY);
    if (fd < 0) {
        return -1;
    }

    /* Configure serial port (9600 8N1) */
    memset(&tty, 0, sizeof(tty));
    if (tcgetattr(fd, &tty) != 0) {
        close(fd);
        return -1;
    }

    cfsetispeed(&tty, B9600);
    tty.c_cflag = (tty.c_cflag & ~CSIZE) | CS8;
    tty.c_iflag &= ~IGNBRK;
    tty.c_lflag = 0;
    tty.c_oflag = 0;
    tty.c_cc[VMIN]  = 1;
    tty.c_cc[VTIME] = 1;
    tty.c_iflag &= ~(IXON | IXOFF | IXANY);
    tty.c_cflag |= (CLOCAL | CREAD);
    tty.c_cflag &= ~(PARENB | PARODD);
    tty.c_cflag &= ~CSTOPB;

    if (tcsetattr(fd, TCSANOW, &tty) != 0) {
        close(fd);
        return -1;
    }

    return fd;
}

/**
 * @brief Print usage information
 */
void print_usage(const char *prog) {
    printf("Usage: %s -i <UAS_ID> [options]\n\n", prog);
    printf("Options:\n");
    printf("  -i <UAS_ID>     Set UAS ID / Serial Number (required, max 20 chars)\n");
    printf("  -g <device>     GPS device (e.g., /dev/ttyUSB0, default: simulated)\n");
    printf("  -t <type>       UA type (1=Aeroplane, 2=Helicopter, 3=Multirotor, default: 3)\n");
    printf("  -c <channel>    WiFi channel (1-14, default: 6)\n");
    printf("  -h              Show this help\n\n");
    printf("Example:\n");
    printf("  %s -i \"DRONE123456789\" -g /dev/ttyUSB0 -t 3 -c 6\n\n", prog);
    printf("Note: Requires OpenWiFi driver and root privileges.\n");
}

/**
 * @brief Main function
 */
int main(int argc, char *argv[]) {
    int opt;
    char gps_device[256] = "";
    int id_set = 0;

    /* Initialize drone state */
    memset(&drone, 0, sizeof(drone));
    drone.ua_type = 3;  /* Default: Multirotor */
    drone.channel = 6;

    printf("===============================================\n");
    printf("  Drone Remote ID Transmitter (ASTM F3411)\n");
    printf("  OpenWiFi Project\n");
    printf("===============================================\n\n");

    /* Parse command line options */
    while ((opt = getopt(argc, argv, "i:g:t:c:h")) != -1) {
        switch (opt) {
            case 'i':
                strncpy(drone.uas_id, optarg, sizeof(drone.uas_id) - 1);
                id_set = 1;
                break;
            case 'g':
                strncpy(gps_device, optarg, sizeof(gps_device) - 1);
                break;
            case 't':
                drone.ua_type = atoi(optarg);
                break;
            case 'c':
                drone.channel = atoi(optarg);
                if (drone.channel < 1 || drone.channel > 14) {
                    fprintf(stderr, "Error: Invalid channel (must be 1-14)\n");
                    return 1;
                }
                break;
            case 'h':
                print_usage(argv[0]);
                return 0;
            default:
                print_usage(argv[0]);
                return 1;
        }
    }

    if (!id_set) {
        fprintf(stderr, "Error: UAS ID is required\n\n");
        print_usage(argv[0]);
        return 1;
    }

    /* Display configuration */
    printf("Configuration:\n");
    printf("  UAS ID:     %s\n", drone.uas_id);
    printf("  UA Type:    %d\n", drone.ua_type);
    printf("  GPS Device: %s\n", gps_device[0] ? gps_device : "Simulated");
    printf("  Channel:    %d\n\n", drone.channel);

    /* Install signal handlers */
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    /* Open GPS device if specified */
    if (gps_device[0]) {
        gps_fd = open_gps_port(gps_device);
        if (gps_fd < 0) {
            fprintf(stderr, "Warning: Failed to open GPS device %s\n", gps_device);
            fprintf(stderr, "         Using simulated GPS data\n\n");
        } else {
            printf("GPS device opened: %s\n\n", gps_device);
        }
    }

    /* Open OpenWiFi SDR device */
    sdr_fd = open("/dev/sdr0", O_RDWR);
    if (sdr_fd < 0) {
        perror("Failed to open /dev/sdr0");
        fprintf(stderr, "\nNote: This requires OpenWiFi driver and root privileges.\n");
        if (gps_fd >= 0) close(gps_fd);
        return 1;
    }

    /* Set channel */
    if (ioctl(sdr_fd, IOCTL_SET_CHANNEL, drone.channel) < 0) {
        perror("Failed to set channel");
        close(sdr_fd);
        if (gps_fd >= 0) close(gps_fd);
        return 1;
    }

    /* Start Remote ID transmission loop */
    remote_id_loop();

    /* Cleanup */
    close(sdr_fd);
    if (gps_fd >= 0) close(gps_fd);

    return 0;
}
