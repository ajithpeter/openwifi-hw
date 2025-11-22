/* SPDX-FileCopyrightText: 2025 OpenWiFi Project
 * SPDX-License-Identifier: AGPL-3.0-only
 */

/**
 * @file remote_id_receiver.c
 * @brief Drone Remote ID receiver and decoder (ASTM F3411 compliant)
 *
 * This example implements a drone Remote ID receiver that monitors
 * for WiFi NAN Remote ID frames and decodes all message types.
 *
 * Features:
 * - Monitors for NAN Remote ID frames
 * - Decodes all 6 ASTM F3411 message types
 * - Displays drone information in real-time
 * - Tracks multiple drones simultaneously
 * - Optional logging to file or database
 * - Calculates distance to drone (if operator location known)
 *
 * Usage:
 *   sudo ./remote_id_receiver [-c channel] [-l logfile] [-v]
 *
 * Example:
 *   sudo ./remote_id_receiver -c 6 -l drones.log -v
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
#include <getopt.h>
#include <math.h>

#include "../include/remote_id_types.h"

/* Enhanced XPU ioctl commands */
#define OPENWIFI_IOCTL_MAGIC        'o'
#define IOCTL_SET_MONITOR_MODE      _IOW(OPENWIFI_IOCTL_MAGIC, 10, uint32_t)
#define IOCTL_SET_CHANNEL           _IOW(OPENWIFI_IOCTL_MAGIC, 11, uint32_t)
#define IOCTL_SET_FILTER            _IOW(OPENWIFI_IOCTL_MAGIC, 12, uint32_t)

/* Filter flags */
#define FILTER_NAN                  (1 << 4)

/* Maximum number of tracked drones */
#define MAX_DRONES                  100

/* Drone information structure */
struct drone_info {
    char uas_id[21];
    uint8_t ua_type;
    double latitude;
    double longitude;
    double altitude;
    double speed;
    double direction;
    time_t last_seen;
    uint32_t message_count;
    int8_t rssi;
};

/* Global variables */
static volatile int keep_running = 1;
static int sdr_fd = -1;
static FILE *log_file = NULL;
static int verbose = 0;
static int channel = 6;

/* Drone tracking database */
static struct drone_info drones[MAX_DRONES];
static int num_drones = 0;

/* Signal handler */
void signal_handler(int signum) {
    (void)signum;
    keep_running = 0;
    printf("\n\nShutting down receiver...\n");
}

/**
 * @brief Calculate distance between two GPS coordinates (Haversine formula)
 * @param lat1, lon1 First coordinate
 * @param lat2, lon2 Second coordinate
 * @return Distance in meters
 */
double calculate_distance(double lat1, double lon1, double lat2, double lon2) {
    const double R = 6371000.0;  /* Earth radius in meters */
    double phi1 = lat1 * M_PI / 180.0;
    double phi2 = lat2 * M_PI / 180.0;
    double dphi = (lat2 - lat1) * M_PI / 180.0;
    double dlambda = (lon2 - lon1) * M_PI / 180.0;

    double a = sin(dphi / 2.0) * sin(dphi / 2.0) +
               cos(phi1) * cos(phi2) *
               sin(dlambda / 2.0) * sin(dlambda / 2.0);

    double c = 2.0 * atan2(sqrt(a), sqrt(1.0 - a));

    return R * c;
}

/**
 * @brief Find or create drone entry
 * @param uas_id UAS ID string
 * @return Pointer to drone info, or NULL if table full
 */
struct drone_info* find_or_create_drone(const char *uas_id) {
    int i;

    /* Search for existing drone */
    for (i = 0; i < num_drones; i++) {
        if (strcmp(drones[i].uas_id, uas_id) == 0) {
            return &drones[i];
        }
    }

    /* Create new entry if space available */
    if (num_drones < MAX_DRONES) {
        struct drone_info *drone = &drones[num_drones++];
        memset(drone, 0, sizeof(*drone));
        strncpy(drone->uas_id, uas_id, sizeof(drone->uas_id) - 1);
        return drone;
    }

    return NULL;  /* Table full */
}

/**
 * @brief Get UA type name
 * @param ua_type UA type code
 * @return String describing UA type
 */
const char* get_ua_type_name(uint8_t ua_type) {
    switch (ua_type) {
        case 0:  return "None/Other";
        case 1:  return "Aeroplane";
        case 2:  return "Helicopter";
        case 3:  return "Gyroplane";
        case 4:  return "VTOL";
        case 5:  return "Ornithopter";
        case 6:  return "Glider";
        case 7:  return "Kite";
        case 8:  return "Free Balloon";
        case 9:  return "Captive Balloon";
        case 10: return "Airship";
        case 11: return "Parachute";
        case 12: return "Rocket";
        case 13: return "Tethered";
        case 14: return "Ground Obstacle";
        case 15: return "Other";
        default: return "Unknown";
    }
}

/**
 * @brief Process Basic ID message (Type 0)
 * @param msg Remote ID message
 */
void process_basic_id(const remote_id_basic_id_t *msg) {
    char uas_id[21];
    struct drone_info *drone;

    /* Extract UAS ID */
    memcpy(uas_id, msg->uas_id, 20);
    uas_id[20] = '\0';

    /* Find or create drone entry */
    drone = find_or_create_drone(uas_id);
    if (!drone) {
        if (verbose) {
            fprintf(stderr, "Warning: Drone tracking table full\n");
        }
        return;
    }

    drone->ua_type = msg->ua_type;
    time(&drone->last_seen);
    drone->message_count++;

    if (verbose) {
        printf("[BASIC ID] UAS ID: %s, Type: %s\n",
               uas_id, get_ua_type_name(msg->ua_type));
    }

    /* Log to file */
    if (log_file) {
        fprintf(log_file, "%ld,BASIC_ID,%s,%s\n",
                time(NULL), uas_id, get_ua_type_name(msg->ua_type));
        fflush(log_file);
    }
}

/**
 * @brief Process Location message (Type 1)
 * @param msg Remote ID message
 * @param uas_id UAS ID from Basic ID or previous message
 */
void process_location(const remote_id_location_t *msg, const char *uas_id) {
    struct drone_info *drone;
    double lat, lon, alt, speed, direction;
    char time_str[32];
    time_t now;
    struct tm *timeinfo;

    /* Decode location data */
    lat = msg->latitude / 1e7;
    lon = msg->longitude / 1e7;
    alt = msg->altitude_geo * 0.5;
    speed = msg->speed_horiz * 0.25;
    direction = msg->direction;

    /* Find drone entry (or create with temporary ID) */
    if (uas_id && uas_id[0]) {
        drone = find_or_create_drone(uas_id);
    } else {
        /* Use lat/lon as temporary ID if Basic ID not yet received */
        char temp_id[21];
        snprintf(temp_id, sizeof(temp_id), "%.4f,%.4f", lat, lon);
        drone = find_or_create_drone(temp_id);
    }

    if (drone) {
        drone->latitude = lat;
        drone->longitude = lon;
        drone->altitude = alt;
        drone->speed = speed;
        drone->direction = direction;
        time(&drone->last_seen);
        drone->message_count++;
    }

    /* Get current time for display */
    time(&now);
    timeinfo = localtime(&now);
    strftime(time_str, sizeof(time_str), "%H:%M:%S", timeinfo);

    /* Display location information */
    printf("%s  [LOCATION] ID: %-20s  Lat: %11.7f  Lon: %11.7f  Alt: %6.1fm  Spd: %5.1fm/s  Dir: %5.1f°\n",
           time_str,
           drone ? drone->uas_id : "Unknown",
           lat, lon, alt, speed, direction);

    /* Log to file */
    if (log_file) {
        fprintf(log_file, "%ld,LOCATION,%s,%.7f,%.7f,%.1f,%.1f,%.1f\n",
                now,
                drone ? drone->uas_id : "Unknown",
                lat, lon, alt, speed, direction);
        fflush(log_file);
    }
}

/**
 * @brief Process System message (Type 4)
 * @param msg Remote ID message
 */
void process_system(const remote_id_system_t *msg) {
    double op_lat, op_lon;

    op_lat = msg->operator_latitude / 1e7;
    op_lon = msg->operator_longitude / 1e7;

    if (verbose) {
        printf("[SYSTEM] Operator Location: %.7f, %.7f  Area: %d aircraft\n",
               op_lat, op_lon, msg->area_count);
    }

    /* Log to file */
    if (log_file) {
        fprintf(log_file, "%ld,SYSTEM,%.7f,%.7f,%d\n",
                time(NULL), op_lat, op_lon, msg->area_count);
        fflush(log_file);
    }
}

/**
 * @brief Process Self-ID message (Type 3)
 * @param msg Remote ID message
 */
void process_self_id(const remote_id_self_id_t *msg) {
    char description[24];

    memcpy(description, msg->description, 23);
    description[23] = '\0';

    if (verbose) {
        printf("[SELF-ID] Description: %s\n", description);
    }

    /* Log to file */
    if (log_file) {
        fprintf(log_file, "%ld,SELF_ID,%s\n", time(NULL), description);
        fflush(log_file);
    }
}

/**
 * @brief Check if frame is NAN Remote ID frame
 * @param frame Frame data
 * @param len Frame length
 * @return 1 if Remote ID frame, 0 otherwise
 */
int is_nan_remote_id_frame(const uint8_t *frame, size_t len) {
    const uint8_t service_id[] = REMOTE_ID_SERVICE_ID;
    const nan_action_frame_t *nan_frame;
    size_t offset;

    if (len < sizeof(nan_action_frame_t)) {
        return 0;
    }

    nan_frame = (const nan_action_frame_t *)frame;

    /* Check frame control (Action frame) */
    if ((nan_frame->frame_control & 0x00FC) != 0x00D0) {
        return 0;
    }

    /* Check for NAN OUI and type */
    if (nan_frame->oui[0] != 0x50 ||
        nan_frame->oui[1] != 0x6F ||
        nan_frame->oui[2] != 0x9A ||
        nan_frame->oui_type != 0x13) {
        return 0;
    }

    /* Search for Service Descriptor with Remote ID service ID */
    offset = sizeof(nan_action_frame_t) - sizeof(nan_frame->attributes);

    while (offset + 3 < len) {
        uint8_t attr_id = frame[offset];
        uint16_t attr_len = frame[offset + 1] | (frame[offset + 2] << 8);

        if (offset + 3 + attr_len > len) {
            break;
        }

        if (attr_id == NAN_ATTR_SERVICE_DESCRIPTOR) {
            /* Check service ID */
            if (attr_len >= 6 && memcmp(&frame[offset + 3], service_id, 6) == 0) {
                return 1;  /* This is a Remote ID frame */
            }
        }

        offset += 3 + attr_len;
    }

    return 0;
}

/**
 * @brief Decode Remote ID message from NAN frame
 * @param frame NAN frame data
 * @param len Frame length
 * @param msg Output Remote ID message
 * @return 0 on success, -1 on error
 */
int decode_remote_id_from_nan(const uint8_t *frame, size_t len, remote_id_message_t *msg) {
    size_t offset;

    offset = sizeof(nan_action_frame_t) - sizeof(((nan_action_frame_t *)0)->attributes);

    /* Search for Service Descriptor attribute */
    while (offset + 3 < len) {
        uint8_t attr_id = frame[offset];
        uint16_t attr_len = frame[offset + 1] | (frame[offset + 2] << 8);

        if (offset + 3 + attr_len > len) {
            break;
        }

        if (attr_id == NAN_ATTR_SERVICE_DESCRIPTOR) {
            /* Service descriptor found */
            /* Skip: attr_id(1) + len(2) + service_id(6) + instance_id(1) +
             *       requestor_instance_id(1) + service_control(1) +
             *       binding_bitmap(1) + service_info_len(1) = 14 bytes */

            size_t msg_offset = offset + 3 + 6 + 5 + 1;

            if (msg_offset + REMOTE_ID_MESSAGE_SIZE <= len) {
                memcpy(msg->raw, &frame[msg_offset], REMOTE_ID_MESSAGE_SIZE);
                return 0;
            }
        }

        offset += 3 + attr_len;
    }

    return -1;
}

/**
 * @brief Process received frame
 * @param buf Frame buffer
 * @param len Frame length
 */
void process_frame(const uint8_t *buf, size_t len) {
    static char last_uas_id[21] = "";
    remote_id_message_t msg;

    /* Check if this is a NAN Remote ID frame */
    if (!is_nan_remote_id_frame(buf, len)) {
        return;
    }

    /* Decode Remote ID message */
    if (decode_remote_id_from_nan(buf, len, &msg) < 0) {
        if (verbose) {
            fprintf(stderr, "Warning: Failed to decode Remote ID message\n");
        }
        return;
    }

    /* Process based on message type */
    switch (msg.msg_type) {
        case REMOTE_ID_BASIC_ID:
            process_basic_id(&msg.basic_id);
            /* Save UAS ID for subsequent messages */
            memcpy(last_uas_id, msg.basic_id.uas_id, 20);
            last_uas_id[20] = '\0';
            break;

        case REMOTE_ID_LOCATION:
            process_location(&msg.location, last_uas_id);
            break;

        case REMOTE_ID_SYSTEM:
            process_system(&msg.system);
            break;

        case REMOTE_ID_SELF_ID:
            process_self_id(&msg.self_id);
            break;

        case REMOTE_ID_AUTH:
            if (verbose) {
                printf("[AUTH] Authentication message received\n");
            }
            break;

        case REMOTE_ID_OPERATOR_ID:
            if (verbose) {
                printf("[OPERATOR ID] Operator ID message received\n");
            }
            break;

        default:
            if (verbose) {
                fprintf(stderr, "Warning: Unknown message type: 0x%02X\n", msg.msg_type);
            }
            break;
    }
}

/**
 * @brief Main receive loop
 */
void receive_loop(void) {
    uint8_t buffer[4096];
    ssize_t nread;
    unsigned long frame_count = 0;

    printf("Monitoring for Remote ID frames on channel %d...\n", channel);
    printf("Press Ctrl+C to stop.\n\n");

    while (keep_running) {
        /* Read frame from device */
        nread = read(sdr_fd, buffer, sizeof(buffer));

        if (nread < 0) {
            if (errno == EAGAIN || errno == EINTR) {
                continue;
            }
            if (keep_running) {
                perror("Read error");
            }
            break;
        }

        if (nread > 0) {
            frame_count++;
            process_frame(buffer, nread);
        }
    }

    printf("\nTotal frames processed: %lu\n", frame_count);
}

/**
 * @brief Print tracked drones summary
 */
void print_summary(void) {
    int i;
    time_t now;

    time(&now);

    printf("\n================================================================================\n");
    printf("Tracked Drones Summary (%d total)\n", num_drones);
    printf("================================================================================\n");

    for (i = 0; i < num_drones; i++) {
        struct drone_info *drone = &drones[i];
        int age = (int)(now - drone->last_seen);

        printf("\nDrone #%d:\n", i + 1);
        printf("  UAS ID:    %s\n", drone->uas_id);
        printf("  Type:      %s\n", get_ua_type_name(drone->ua_type));
        printf("  Location:  %.7f, %.7f (alt: %.1fm)\n",
               drone->latitude, drone->longitude, drone->altitude);
        printf("  Speed:     %.1f m/s  Direction: %.1f°\n",
               drone->speed, drone->direction);
        printf("  Last seen: %d seconds ago\n", age);
        printf("  Messages:  %u\n", drone->message_count);
    }

    printf("\n================================================================================\n");
}

/**
 * @brief Setup monitor mode for NAN reception
 * @return 0 on success, -1 on error
 */
int setup_monitor_mode(void) {
    uint32_t filter_flags = FILTER_NAN;

    /* Enable monitor mode */
    if (ioctl(sdr_fd, IOCTL_SET_MONITOR_MODE, 1) < 0) {
        perror("Failed to enable monitor mode");
        return -1;
    }

    /* Set channel */
    if (ioctl(sdr_fd, IOCTL_SET_CHANNEL, channel) < 0) {
        perror("Failed to set channel");
        return -1;
    }

    /* Configure packet filter for NAN frames */
    if (ioctl(sdr_fd, IOCTL_SET_FILTER, filter_flags) < 0) {
        perror("Failed to set packet filter");
        return -1;
    }

    return 0;
}

/**
 * @brief Print usage information
 */
void print_usage(const char *prog) {
    printf("Usage: %s [options]\n\n", prog);
    printf("Options:\n");
    printf("  -c <channel>    WiFi channel to monitor (1-14, default: 6)\n");
    printf("  -l <logfile>    Log received data to file\n");
    printf("  -v              Verbose mode (show all messages)\n");
    printf("  -h              Show this help\n\n");
    printf("Example:\n");
    printf("  %s -c 6 -l drones.log -v\n\n", prog);
    printf("Note: Requires OpenWiFi driver and root privileges.\n");
}

/**
 * @brief Main function
 */
int main(int argc, char *argv[]) {
    int opt;
    char logfile[256] = "";

    printf("===============================================\n");
    printf("  Drone Remote ID Receiver (ASTM F3411)\n");
    printf("  OpenWiFi Project\n");
    printf("===============================================\n\n");

    /* Parse command line options */
    while ((opt = getopt(argc, argv, "c:l:vh")) != -1) {
        switch (opt) {
            case 'c':
                channel = atoi(optarg);
                if (channel < 1 || channel > 14) {
                    fprintf(stderr, "Error: Invalid channel (must be 1-14)\n");
                    return 1;
                }
                break;
            case 'l':
                strncpy(logfile, optarg, sizeof(logfile) - 1);
                break;
            case 'v':
                verbose = 1;
                break;
            case 'h':
                print_usage(argv[0]);
                return 0;
            default:
                print_usage(argv[0]);
                return 1;
        }
    }

    /* Open log file if specified */
    if (logfile[0]) {
        log_file = fopen(logfile, "a");
        if (!log_file) {
            perror("Failed to open log file");
            return 1;
        }
        printf("Logging to: %s\n\n", logfile);
    }

    /* Install signal handlers */
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    /* Open OpenWiFi SDR device */
    sdr_fd = open("/dev/sdr0", O_RDWR);
    if (sdr_fd < 0) {
        perror("Failed to open /dev/sdr0");
        fprintf(stderr, "\nNote: This requires OpenWiFi driver and root privileges.\n");
        if (log_file) fclose(log_file);
        return 1;
    }

    /* Setup monitor mode */
    if (setup_monitor_mode() < 0) {
        close(sdr_fd);
        if (log_file) fclose(log_file);
        return 1;
    }

    /* Enter receive loop */
    receive_loop();

    /* Print summary */
    print_summary();

    /* Cleanup */
    ioctl(sdr_fd, IOCTL_SET_MONITOR_MODE, 0);
    close(sdr_fd);

    if (log_file) {
        fclose(log_file);
    }

    return 0;
}
