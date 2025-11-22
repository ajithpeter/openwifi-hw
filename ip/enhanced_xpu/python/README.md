# Enhanced XPU Python Bindings

Python interface for the Enhanced XPU WiFi monitoring and Remote ID hardware.

## Installation

```bash
# Install system library first
cd ..
make && sudo make install

# Install Python bindings
cd python
pip install .
```

## Quick Start

### Monitor Mode

```python
from enhanced_xpu import XPU

# Open device
with XPU() as xpu:
    # Enable monitor mode
    xpu.set_monitor_mode(True)

    # Capture 10 packets
    for packet in xpu.capture(count=10):
        print(f"Received {len(packet)} bytes")
```

### Frame Injection

```python
from enhanced_xpu import XPU

# Create beacon frame
beacon = bytes.fromhex("80 00 00 00 ff ff ff ff ff ff ...")

with XPU() as xpu:
    xpu.set_inject_mode(True)
    xpu.inject_frame(beacon, rate=6, power=15)
```

### Remote ID

```python
from enhanced_xpu import XPU, RemoteIDLocationClass

with XPU() as xpu:
    # Transmit location
    location = RemoteIDLocationClass(
        latitude=37.7749,
        longitude=-122.4194,
        altitude=100.0
    )

    xpu.set_inject_mode(True)
    xpu.remote_id_transmit(location)

    # Monitor Remote ID
    xpu.set_monitor_mode(True)
    xpu.configure_filters(frame_types=XPU_FRAME_NAN)

    for packet in xpu.capture():
        msg = xpu.remote_id_decode(packet)
        if msg:
            print(f"Remote ID: {msg}")
```

## API Reference

### XPU Class

- `XPU(device_path="/dev/enhanced_xpu")` - Open device
- `close()` - Close device
- `set_monitor_mode(enable)` - Enable/disable monitor mode
- `set_inject_mode(enable)` - Enable/disable injection
- `configure_filters(mac_addr, frame_types)` - Configure packet filters
- `receive_packet(timeout_ms)` - Receive single packet
- `capture(count, timeout_ms)` - Capture packets (generator)
- `inject_frame(frame, rate, power)` - Inject 802.11 frame
- `get_stats()` - Get statistics
- `remote_id_transmit(message)` - Transmit Remote ID
- `remote_id_decode(frame)` - Decode Remote ID from frame

### RemoteIDLocationClass

- `RemoteIDLocationClass(latitude, longitude, altitude, ...)` - Create location message

## License

AGPL-3.0-only
