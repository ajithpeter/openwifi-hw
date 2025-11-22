#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2025 OpenWiFi Project
# SPDX-License-Identifier: AGPL-3.0-only

"""
Enhanced XPU Python Bindings

This module provides a Pythonic interface to the Enhanced XPU hardware
for WiFi monitoring, frame injection, and Remote ID functionality.

Example usage:
    from enhanced_xpu import XPU, RemoteIDLocation

    # Open device
    xpu = XPU()

    # Enable monitor mode
    xpu.set_monitor_mode(True)

    # Capture packets
    for packet in xpu.capture(count=10):
        print(f"Received {len(packet)} bytes")

    # Transmit Remote ID
    msg = RemoteIDLocation(
        latitude=37.7749,
        longitude=-122.4194,
        altitude=100.0
    )
    xpu.remote_id_transmit(msg)

    xpu.close()
"""

import ctypes
import os
import struct
from ctypes import (
    c_void_p, c_char_p, c_int, c_uint, c_size_t, c_ssize_t, c_bool,
    c_uint8, c_uint16, c_uint32, c_uint64, c_int8, c_int16, c_int32,
    c_float, c_double,
    POINTER, Structure, Union, byref
)
from enum import IntEnum
from typing import List, Optional, Iterator, Tuple

__version__ = "1.0.0"
__author__ = "OpenWiFi Team"

##############################################################################
# Constants
##############################################################################

# Configuration flags
XPU_CONFIG_MONITOR = 1 << 0
XPU_CONFIG_INJECT = 1 << 1
XPU_CONFIG_PROMISCUOUS = 1 << 2
XPU_CONFIG_REMOTE_ID = 1 << 3

# Filter flags
XPU_FILTER_MAC_ADDR = 1 << 0
XPU_FILTER_BSSID = 1 << 1
XPU_FILTER_FRAME_TYPE = 1 << 2
XPU_FILTER_MANAGEMENT = 1 << 3
XPU_FILTER_DATA = 1 << 4
XPU_FILTER_CONTROL = 1 << 5

# Frame type masks
XPU_FRAME_BEACON = 1 << 0
XPU_FRAME_PROBE_REQ = 1 << 1
XPU_FRAME_PROBE_RESP = 1 << 2
XPU_FRAME_DATA = 1 << 3
XPU_FRAME_QOS_DATA = 1 << 4
XPU_FRAME_ACTION = 1 << 5
XPU_FRAME_NAN = 1 << 6

# TX flags
XPU_TX_NO_ACK = 1 << 0
XPU_TX_USE_CTS_PROTECT = 1 << 1
XPU_TX_USE_RTS_CTS = 1 << 2

# Remote ID message types
REMOTE_ID_BASIC_ID = 0
REMOTE_ID_LOCATION = 1
REMOTE_ID_AUTH = 2
REMOTE_ID_SELF_ID = 3
REMOTE_ID_SYSTEM = 4
REMOTE_ID_OPERATOR_ID = 5
REMOTE_ID_MESSAGE_PACK = 0xF

##############################################################################
# C Structure Definitions
##############################################################################

class XPUConfig(Structure):
    _fields_ = [
        ("flags", c_uint32),
        ("rx_buffer_size", c_uint32),
        ("tx_buffer_size", c_uint32),
        ("channel", c_uint32),
        ("bandwidth", c_uint32),
        ("tx_power", c_uint32),
        ("reserved", c_uint32 * 10),
    ]

class XPUFilterConfig(Structure):
    _fields_ = [
        ("flags", c_uint32),
        ("mac_addr", c_uint8 * 6),
        ("bssid", c_uint8 * 6),
        ("frame_type_mask", c_uint32),
        ("reserved", c_uint32 * 8),
    ]

class XPUStats(Structure):
    _fields_ = [
        ("rx_packets", c_uint64),
        ("rx_bytes", c_uint64),
        ("rx_dropped", c_uint64),
        ("tx_packets", c_uint64),
        ("tx_bytes", c_uint64),
        ("tx_errors", c_uint64),
        ("errors", c_uint64),
        ("remote_id_rx", c_uint64),
        ("remote_id_tx", c_uint64),
        ("reserved", c_uint32 * 16),
    ]

class XPUTxParams(Structure):
    _fields_ = [
        ("rate", c_uint32),
        ("power", c_int32),
        ("retries", c_uint32),
        ("flags", c_uint32),
        ("reserved", c_uint32 * 4),
    ]

class RemoteIDBasicID(Structure):
    _pack_ = 1
    _fields_ = [
        ("msg_type", c_uint8),
        ("id_type", c_uint8),
        ("ua_type", c_uint8),
        ("uas_id", c_uint8 * 20),
        ("reserved", c_uint8 * 2),
    ]

class RemoteIDLocationStruct(Structure):
    _pack_ = 1
    _fields_ = [
        ("msg_type", c_uint8),
        ("status", c_uint8),
        ("direction", c_uint8),
        ("speed_horiz", c_uint8),
        ("speed_vert", c_int8),
        ("latitude", c_int32),
        ("longitude", c_int32),
        ("altitude_baro", c_int16),
        ("altitude_geo", c_int16),
        ("height_agl", c_uint16),
        ("horiz_accuracy", c_uint8),
        ("vert_accuracy", c_uint8),
        ("baro_accuracy", c_uint8),
        ("speed_accuracy", c_uint8),
        ("timestamp", c_uint16),
        ("reserved", c_uint8),
    ]

class RemoteIDSelfID(Structure):
    _pack_ = 1
    _fields_ = [
        ("msg_type", c_uint8),
        ("description_type", c_uint8),
        ("description", c_uint8 * 23),
    ]

class RemoteIDOperatorID(Structure):
    _pack_ = 1
    _fields_ = [
        ("msg_type", c_uint8),
        ("operator_id_type", c_uint8),
        ("operator_id", c_uint8 * 20),
        ("reserved", c_uint8 * 3),
    ]

class RemoteIDMessage(Union):
    _pack_ = 1
    _fields_ = [
        ("msg_type", c_uint8),
        ("basic_id", RemoteIDBasicID),
        ("location", RemoteIDLocationStruct),
        ("self_id", RemoteIDSelfID),
        ("operator_id", RemoteIDOperatorID),
        ("raw", c_uint8 * 25),
    ]

##############################################################################
# Library Loading
##############################################################################

def _find_library():
    """Find the libenhanced_xpu shared library."""
    search_paths = [
        "./lib/libenhanced_xpu.so",
        "../lib/libenhanced_xpu.so",
        "/usr/local/lib/libenhanced_xpu.so",
        "/usr/lib/libenhanced_xpu.so",
    ]

    for path in search_paths:
        if os.path.exists(path):
            return path

    raise RuntimeError("libenhanced_xpu.so not found")

# Load library
_lib_path = _find_library()
_lib = ctypes.CDLL(_lib_path)

# Define function prototypes
_lib.xpu_open.argtypes = [c_char_p]
_lib.xpu_open.restype = c_void_p

_lib.xpu_close.argtypes = [c_void_p]
_lib.xpu_close.restype = None

_lib.xpu_get_fd.argtypes = [c_void_p]
_lib.xpu_get_fd.restype = c_int

_lib.xpu_set_config.argtypes = [c_void_p, POINTER(XPUConfig)]
_lib.xpu_set_config.restype = c_int

_lib.xpu_get_config.argtypes = [c_void_p, POINTER(XPUConfig)]
_lib.xpu_get_config.restype = c_int

_lib.xpu_reset.argtypes = [c_void_p]
_lib.xpu_reset.restype = c_int

_lib.xpu_set_monitor_mode.argtypes = [c_void_p, c_bool]
_lib.xpu_set_monitor_mode.restype = c_int

_lib.xpu_configure_filters.argtypes = [c_void_p, POINTER(XPUFilterConfig)]
_lib.xpu_configure_filters.restype = c_int

_lib.xpu_receive_packet.argtypes = [c_void_p, c_void_p, c_size_t, c_int]
_lib.xpu_receive_packet.restype = c_ssize_t

_lib.xpu_set_inject_mode.argtypes = [c_void_p, c_bool]
_lib.xpu_set_inject_mode.restype = c_int

_lib.xpu_inject_frame.argtypes = [c_void_p, c_void_p, c_size_t, POINTER(XPUTxParams)]
_lib.xpu_inject_frame.restype = c_ssize_t

_lib.xpu_get_stats.argtypes = [c_void_p, POINTER(XPUStats)]
_lib.xpu_get_stats.restype = c_int

_lib.xpu_remote_id_transmit.argtypes = [c_void_p, POINTER(RemoteIDMessage)]
_lib.xpu_remote_id_transmit.restype = c_int

_lib.xpu_remote_id_decode.argtypes = [c_void_p, c_size_t, POINTER(RemoteIDMessage)]
_lib.xpu_remote_id_decode.restype = c_int

_lib.xpu_get_error.argtypes = []
_lib.xpu_get_error.restype = c_char_p

_lib.xpu_set_debug_level.argtypes = [c_int]
_lib.xpu_set_debug_level.restype = None

##############################################################################
# Python Classes
##############################################################################

class XPUError(Exception):
    """Exception raised for XPU errors."""
    pass

class XPU:
    """
    Enhanced XPU Device Interface.

    This class provides high-level access to the Enhanced XPU hardware
    for WiFi monitoring, frame injection, and Remote ID.
    """

    def __init__(self, device_path: str = "/dev/enhanced_xpu"):
        """
        Open XPU device.

        Args:
            device_path: Path to device node (default: /dev/enhanced_xpu)

        Raises:
            XPUError: If device cannot be opened
        """
        self._handle = _lib.xpu_open(device_path.encode())
        if not self._handle:
            error = _lib.xpu_get_error().decode()
            raise XPUError(f"Failed to open device: {error}")

    def __del__(self):
        """Close device on deletion."""
        self.close()

    def __enter__(self):
        """Context manager entry."""
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit."""
        self.close()

    def close(self):
        """Close device."""
        if self._handle:
            _lib.xpu_close(self._handle)
            self._handle = None

    def get_fd(self) -> int:
        """Get file descriptor for select/poll."""
        return _lib.xpu_get_fd(self._handle)

    def reset(self):
        """Reset hardware."""
        if _lib.xpu_reset(self._handle) < 0:
            raise XPUError("Failed to reset hardware")

    def set_monitor_mode(self, enable: bool):
        """Enable/disable monitor mode."""
        if _lib.xpu_set_monitor_mode(self._handle, enable) < 0:
            raise XPUError("Failed to set monitor mode")

    def set_inject_mode(self, enable: bool):
        """Enable/disable frame injection mode."""
        if _lib.xpu_set_inject_mode(self._handle, enable) < 0:
            raise XPUError("Failed to set inject mode")

    def configure_filters(self, mac_addr: Optional[bytes] = None,
                         frame_types: Optional[int] = None):
        """
        Configure packet filters.

        Args:
            mac_addr: MAC address to filter (6 bytes)
            frame_types: Frame type mask (XPU_FRAME_*)
        """
        config = XPUFilterConfig()

        if mac_addr:
            config.flags |= XPU_FILTER_MAC_ADDR
            for i in range(6):
                config.mac_addr[i] = mac_addr[i]

        if frame_types is not None:
            config.flags |= XPU_FILTER_FRAME_TYPE
            config.frame_type_mask = frame_types

        if _lib.xpu_configure_filters(self._handle, byref(config)) < 0:
            raise XPUError("Failed to configure filters")

    def receive_packet(self, timeout_ms: int = 1000) -> Optional[bytes]:
        """
        Receive a captured packet.

        Args:
            timeout_ms: Timeout in milliseconds (0=non-blocking, -1=blocking)

        Returns:
            Packet data as bytes, or None on timeout

        Raises:
            XPUError: On error
        """
        buffer = ctypes.create_string_buffer(4096)
        length = _lib.xpu_receive_packet(self._handle, buffer, len(buffer),
                                         timeout_ms)

        if length < 0:
            import errno
            if ctypes.get_errno() == errno.EAGAIN:
                return None
            raise XPUError("Failed to receive packet")

        return buffer.raw[:length]

    def capture(self, count: Optional[int] = None,
                timeout_ms: int = 1000) -> Iterator[bytes]:
        """
        Capture packets (generator).

        Args:
            count: Number of packets to capture (None=infinite)
            timeout_ms: Timeout per packet in milliseconds

        Yields:
            Packet data as bytes
        """
        captured = 0
        while count is None or captured < count:
            packet = self.receive_packet(timeout_ms)
            if packet:
                yield packet
                captured += 1

    def inject_frame(self, frame: bytes, rate: int = 6, power: int = 15) -> int:
        """
        Inject 802.11 frame.

        Args:
            frame: Frame data
            rate: TX rate in Mbps
            power: TX power in dBm

        Returns:
            Number of bytes transmitted

        Raises:
            XPUError: On error
        """
        params = XPUTxParams()
        params.rate = rate
        params.power = power
        params.flags = XPU_TX_NO_ACK

        buffer = ctypes.create_string_buffer(frame)
        length = _lib.xpu_inject_frame(self._handle, buffer, len(frame),
                                       byref(params))

        if length < 0:
            raise XPUError("Failed to inject frame")

        return length

    def get_stats(self) -> dict:
        """
        Get statistics.

        Returns:
            Dictionary with statistics
        """
        stats = XPUStats()
        if _lib.xpu_get_stats(self._handle, byref(stats)) < 0:
            raise XPUError("Failed to get statistics")

        return {
            "rx_packets": stats.rx_packets,
            "rx_bytes": stats.rx_bytes,
            "rx_dropped": stats.rx_dropped,
            "tx_packets": stats.tx_packets,
            "tx_bytes": stats.tx_bytes,
            "tx_errors": stats.tx_errors,
            "errors": stats.errors,
            "remote_id_rx": stats.remote_id_rx,
            "remote_id_tx": stats.remote_id_tx,
        }

    def remote_id_transmit(self, message):
        """
        Transmit Remote ID message.

        Args:
            message: RemoteIDBasicID, RemoteIDLocation, etc.

        Raises:
            XPUError: On error
        """
        msg = RemoteIDMessage()

        if isinstance(message, RemoteIDBasicID):
            msg.basic_id = message
        elif isinstance(message, RemoteIDLocationClass):
            msg.location = message._to_struct()
        elif isinstance(message, RemoteIDSelfID):
            msg.self_id = message
        elif isinstance(message, RemoteIDOperatorID):
            msg.operator_id = message
        else:
            raise ValueError("Invalid message type")

        if _lib.xpu_remote_id_transmit(self._handle, byref(msg)) < 0:
            raise XPUError("Failed to transmit Remote ID message")

    def remote_id_decode(self, frame: bytes):
        """
        Decode Remote ID message from frame.

        Args:
            frame: Frame data

        Returns:
            RemoteID message object, or None if not Remote ID

        Raises:
            XPUError: On error
        """
        msg = RemoteIDMessage()
        buffer = ctypes.create_string_buffer(frame)

        ret = _lib.xpu_remote_id_decode(buffer, len(frame), byref(msg))
        if ret < 0:
            return None

        # Convert to Python object based on type
        if msg.msg_type == REMOTE_ID_BASIC_ID:
            return msg.basic_id
        elif msg.msg_type == REMOTE_ID_LOCATION:
            return RemoteIDLocationClass._from_struct(msg.location)
        elif msg.msg_type == REMOTE_ID_SELF_ID:
            return msg.self_id
        elif msg.msg_type == REMOTE_ID_OPERATOR_ID:
            return msg.operator_id
        else:
            return None

##############################################################################
# Remote ID Helper Classes
##############################################################################

class RemoteIDLocationClass:
    """Remote ID Location Message (Pythonic interface)."""

    def __init__(self, latitude: float, longitude: float, altitude: float,
                 speed_horiz: float = 0.0, speed_vert: float = 0.0,
                 direction: int = 0, status: int = 1):
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speed_horiz = speed_horiz
        self.speed_vert = speed_vert
        self.direction = direction
        self.status = status

    def _to_struct(self) -> RemoteIDLocationStruct:
        """Convert to C structure."""
        s = RemoteIDLocationStruct()
        s.msg_type = REMOTE_ID_LOCATION
        s.status = self.status
        s.latitude = int(self.latitude * 1e7)
        s.longitude = int(self.longitude * 1e7)
        s.altitude_baro = int(self.altitude * 2.0)
        s.altitude_geo = int(self.altitude * 2.0)
        s.height_agl = int(self.altitude)
        s.speed_horiz = int(self.speed_horiz * 4.0)
        s.speed_vert = int(self.speed_vert * 2.0)
        s.direction = self.direction
        s.timestamp = 0  # Will be set by library
        return s

    @staticmethod
    def _from_struct(s: RemoteIDLocationStruct):
        """Create from C structure."""
        return RemoteIDLocationClass(
            latitude=s.latitude / 1e7,
            longitude=s.longitude / 1e7,
            altitude=s.altitude_geo * 0.5,
            speed_horiz=s.speed_horiz * 0.25,
            speed_vert=s.speed_vert * 0.5,
            direction=s.direction,
            status=s.status
        )

    def __str__(self):
        return (f"Location: {self.latitude:.6f}, {self.longitude:.6f} "
                f"@ {self.altitude:.1f}m")

##############################################################################
# Utility Functions
##############################################################################

def set_debug_level(level: int):
    """
    Set library debug level.

    Args:
        level: 0=none, 1=error, 2=warning, 3=info, 4=debug
    """
    _lib.xpu_set_debug_level(level)

def parse_mac_address(mac_str: str) -> bytes:
    """Parse MAC address from string."""
    parts = mac_str.replace('-', ':').split(':')
    if len(parts) != 6:
        raise ValueError("Invalid MAC address format")
    return bytes([int(p, 16) for p in parts])

def format_mac_address(mac_bytes: bytes) -> str:
    """Format MAC address as string."""
    if len(mac_bytes) != 6:
        raise ValueError("MAC address must be 6 bytes")
    return ':'.join([f'{b:02x}' for b in mac_bytes])

##############################################################################
# Main (for testing)
##############################################################################

if __name__ == "__main__":
    print(f"Enhanced XPU Python Bindings v{__version__}")
    print(f"Library: {_lib_path}")

    try:
        # Test opening device
        xpu = XPU()
        print("Device opened successfully")

        # Get stats
        stats = xpu.get_stats()
        print(f"Statistics: {stats}")

        xpu.close()
        print("Device closed")

    except XPUError as e:
        print(f"Error: {e}")
