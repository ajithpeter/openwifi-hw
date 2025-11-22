# Minimal Beacon Monitor (Zynq 7010 Experimental)

**Branch:** `claude/minimal-z7010-016NinPPubrhjENgJbg7a1qj`

## ⚠️ IMPORTANT WARNINGS ⚠️

### This Configuration is NOT RECOMMENDED

**Status:** ❌ EXPERIMENTAL / NOT TESTED / NOT RECOMMENDED

**Why:** Even this minimal configuration may not fit on Zynq 7010 because:

1. **Base OpenWiFi alone is too large**
   - Base OpenWiFi: ~45,000 LUTs
   - Zynq 7010 capacity: **28,000 LUTs**
   - **Deficit: -17,000 LUTs (161% over capacity)**

2. **Massive rewrite required**
   - Would need to remove TX path from base OpenWiFi
   - Simplify RX path significantly
   - Reduce buffer sizes
   - Remove CSMA/CA state machine
   - Total rewrite of ~30-40% of base OpenWiFi

3. **Extremely limited functionality**
   - Beacon scanning only
   - No Remote ID
   - No monitor mode
   - No advanced features

### **STRONG RECOMMENDATION:**

**Buy antsdr or antsdr_e200 (~$150-200) instead**

Benefits of upgrading to Zynq 7020:
- ✅ 1.9× more LUTs (53,200 vs 28,000)
- ✅ Full RX-Only configuration works (41% utilization)
- ✅ Complete Remote ID support
- ✅ Full monitor mode
- ✅ Professional-quality implementation
- ✅ Well-tested and documented

The $150-200 cost is **FAR less** than the development effort to make this work on Zynq 7010.

---

## What This Branch Contains

This branch demonstrates what a **minimal beacon-only** configuration would look like for Zynq 7010, but it is **not a complete working implementation**.

### Minimal Modules Created

1. **minimal_beacon_filter.v** (~400 LUTs)
   - Detects beacon frames only
   - Basic FCS validation
   - No NAN parsing
   - No Remote ID
   - No promiscuous mode

2. **ssid_extractor.v** (~300 LUTs)
   - Extracts SSID from beacons
   - Extracts BSSID
   - Basic information element parsing
   - Limited to 32-byte SSIDs

### Resource Estimate

| Module | LUTs | Description |
|--------|------|-------------|
| Base OpenWiFi (modified) | ~18,000 | Heavily stripped-down version |
| minimal_beacon_filter | ~400 | Beacon detection only |
| ssid_extractor | ~300 | SSID extraction |
| Integration overhead | ~500 | Wiring, muxes |
| **Total** | **~19,200** | **69% of Zynq 7010** ⚠️ |

**Status:** ⚠️ **TIGHT** - May not meet timing, may not fit

### Features

✅ **Minimal Features:**
- Beacon frame reception (802.11a/g/n OFDM only)
- SSID extraction (up to 32 characters)
- BSSID extraction (MAC address)
- Basic FCS validation
- Channel detection (from RF tuning)

❌ **Everything Else Excluded:**
- Remote ID support
- NAN parsing
- Vendor IE parsing
- Full monitor mode
- Data/control frames
- Promiscuous mode
- Frame transmission
- Advanced filtering
- PCAP export

---

## Why This Doesn't Work

### Problem 1: Base OpenWiFi is Too Large

The base OpenWiFi implementation uses approximately **45,000 LUTs** on Zynq 7020:

```
Component Breakdown:
- XPU (MAC controller):      ~22,000 LUTs
- OPENOFDM_TX:               ~12,000 LUTs
- OPENOFDM_RX:               ~11,000 LUTs
--------------------------------------------
Total:                       ~45,000 LUTs

Zynq 7010 capacity:           28,000 LUTs
Deficit:                     -17,000 LUTs  ❌
```

**To fit on Zynq 7010, you would need to remove ~17,000 LUTs!**

### Problem 2: Can't Just Remove TX

The TX and RX paths are deeply integrated:

- CSMA/CA state machine coordinates both TX and RX
- DMA engine handles both directions
- Timing/synchronization shared between TX and RX
- MAC control logic assumes TX capability

**Removing TX requires rewriting large parts of the base system.**

### Problem 3: RX Path Also Too Large

Even if you remove all TX functionality:

```
Hypothetical RX-only OpenWiFi:
- XPU (MAC, RX-only):        ~15,000 LUTs  (optimistic)
- OPENOFDM_RX:               ~11,000 LUTs
- DMA (RX only):              ~2,000 LUTs
--------------------------------------------
Subtotal:                    ~28,000 LUTs  (100% of Z7010!) ⚠️

Add minimal beacon filter:       ~700 LUTs
--------------------------------------------
Total:                       ~28,700 LUTs  (102% of Z7010!) ❌
```

**Still doesn't fit, even without TX!**

### Problem 4: Timing Closure at 100% Utilization

Even if you could fit it at 100% LUT utilization:

- ❌ Routing congestion
- ❌ Timing failures
- ❌ Unpredictable behavior
- ❌ Build times 5-10× longer
- ❌ Success rate <20%

**Industry best practice: <80% utilization for reliable designs**

---

## What Would Be Required

To make this work on Zynq 7010, you would need to:

### Major Modifications to Base OpenWiFi

1. **Remove entire TX path**
   - Delete OPENOFDM_TX module
   - Delete TX_INTF module
   - Remove CSMA/CA state machine
   - Remove TX DMA engine
   - Rewrite MAC control for RX-only

2. **Simplify RX path**
   - Reduce OFDM FFT from 64-point to 32-point
   - Simplify Viterbi decoder
   - Reduce buffer sizes (4KB → 1KB)
   - Remove channel estimation refinement
   - Single-stage synchronization only

3. **Minimize memory**
   - Reduce RX buffer: 4KB → 1KB (saves ~6 BRAMs)
   - Remove TX buffers entirely
   - Simplified packet queue

4. **Simplify MAC layer**
   - Remove retry logic
   - Remove ACK handling
   - Remove frame scheduling
   - Passive receiver only

### Estimated Effort

- **Time:** 4-6 weeks of full-time FPGA development
- **Expertise:** Advanced Verilog, OFDM, WiFi protocols
- **Risk:** High (may still not fit or meet timing)
- **Result:** Very limited beacon scanner

### Cost-Benefit Analysis

| Option | Cost | Time | Functionality |
|--------|------|------|---------------|
| **Upgrade to antsdr** | $150-200 | 0 | Full RX + Remote ID |
| **Rewrite for Z7010** | $0 hardware<br>$10K+ labor | 4-6 weeks | Beacon scan only |

**Decision:** Upgrade to antsdr is obvious choice.

---

## Hardware Comparison

### ADALM-PLUTO (Zynq 7010)

| Feature | Specification |
|---------|---------------|
| **FPGA** | Zynq 7010 |
| **LUTs** | 28,000 ❌ |
| **BRAMs** | 60 |
| **DSP48** | 80 |
| **RF** | AD9363 (1RX/1TX) |
| **Cost** | ~$150 |
| **OpenWiFi** | ❌ Doesn't fit |

### antsdr (Zynq 7020) - RECOMMENDED

| Feature | Specification |
|---------|---------------|
| **FPGA** | Zynq 7020 |
| **LUTs** | 53,200 ✅ (1.9× more) |
| **BRAMs** | 140 ✅ (2.3× more) |
| **DSP48** | 220 ✅ (2.75× more) |
| **RF** | AD9361 (2RX/2TX) ✅ |
| **Cost** | ~$200 (+$50) |
| **OpenWiFi** | ✅ Works great (RX-Only: 41%) |
| **Remote ID** | ✅ Full support |

**Verdict:** Pay $50 more, get 1.9× resources and full functionality.

### antsdr_e200 (Zynq 7020) - BEST VALUE

| Feature | Specification |
|---------|---------------|
| **FPGA** | Zynq 7020 ✅ |
| **LUTs** | 53,200 ✅ |
| **RF** | AD9361 ✅ |
| **Ethernet** | PL-based (faster) ✅ |
| **Cost** | ~$150 (same as PlutoSDR!) |
| **OpenWiFi** | ✅ Works great |

**Verdict:** Best value - same price as PlutoSDR, 1.9× resources!

---

## Alternative Solutions

### Option 1: Buy antsdr/antsdr_e200 (RECOMMENDED) ✅

**Cost:** $150-200

**Benefits:**
- Drop-in replacement for PlutoSDR
- Same AD9361 RF chip
- 1.9× more FPGA resources
- Full RX-Only configuration works perfectly
- Complete Remote ID support
- Professional documentation
- Tested and working

**Where to buy:**
- AliExpress: ~$150-200
- Amazon: ~$220-250
- MicroPhase Direct: https://github.com/MicroPhase/

### Option 2: Use External WiFi Adapter

**Cost:** $10-30 for USB WiFi adapter

**Benefits:**
- Works with any SDR
- Can use aircrack-ng, Wireshark
- No FPGA programming needed

**Limitations:**
- No Remote ID support
- Separate hardware
- Driver compatibility issues

### Option 3: Larger FPGA Boards

**Zynq 7035-based boards** (~$500-800):
- adrv9361z7035
- 5× more LUTs than Z7010
- Full TX+RX+injection fits easily

**UltraScale+ boards** ($1000+):
- 802.11ac/ax support possible
- 10-20× more resources
- Professional SDR platform

---

## For Developers Only

### If You REALLY Want to Try This (Not Recommended)

The minimal modules are provided as **reference implementations** for educational purposes. They demonstrate:

1. **How to minimize resource usage**
   - Simplified state machines
   - Minimal buffering
   - Basic functionality only

2. **What trade-offs are required**
   - Lost features
   - Reduced capability
   - Simplified design

### Files in This Branch

- `src/minimal_beacon_filter.v` - Beacon detector (~400 LUTs)
- `src/ssid_extractor.v` - SSID extractor (~300 LUTs)
- `BUILD_CONFIG_MINIMAL.txt` - Configuration description
- `README_MINIMAL_Z7010.md` - This file

### What's NOT Included

❌ Modified base OpenWiFi (too large, requires major rewrite)
❌ Build scripts (won't work without base OpenWiFi changes)
❌ Software tools (not worth implementing for beacon-only)
❌ Test benches (minimal, not production-ready)
❌ Documentation (limited, not supported)

### Testing

**Status:** ❌ **NOT TESTED** on actual hardware

This configuration is purely theoretical. To actually test it, you would need to:

1. Heavily modify base OpenWiFi to remove ~17K LUTs
2. Port the minimal modules
3. Integrate with simplified base
4. Run synthesis (may not fit)
5. Debug timing failures
6. Iterate for weeks

---

## Conclusion

### Summary

This branch demonstrates a **minimal beacon monitor** for Zynq 7010, but it is:

- ❌ **Not recommended**
- ❌ **Not tested**
- ❌ **Not supported**
- ❌ **May not work even with extensive modifications**

### Our Strong Recommendation

**Buy antsdr or antsdr_e200 (~$150-200)**

You will save:
- ✅ Weeks of development time
- ✅ Debugging frustration
- ✅ Get full functionality
- ✅ Professional support
- ✅ Tested and working

### For PlutoSDR Owners

If you already own an ADALM-PLUTO:

1. **Keep it** - It's still great for many SDR applications
2. **Add antsdr** - Use for OpenWiFi and Remote ID
3. **Total investment** - $150 PlutoSDR + $150 antsdr = $300 for complete SDR suite

Both devices are valuable, just for different purposes:
- **PlutoSDR:** General SDR experimentation, learning, GNU Radio
- **antsdr:** OpenWiFi, Remote ID, WiFi monitor, professional use

---

## License

SPDX-License-Identifier: AGPL-3.0-only

Copyright (c) 2025 OpenWiFi Project

---

## Getting Help

**For questions about antsdr:** https://github.com/MicroPhase/
**For OpenWiFi questions:** https://github.com/open-sdr/openwifi-hw

**This minimal Z7010 configuration is not supported.**
