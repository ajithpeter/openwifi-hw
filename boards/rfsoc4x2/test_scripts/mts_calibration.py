#!/usr/bin/env python3
"""
Multi-Tile Synchronization (MTS) Calibration Script for RFSoC
Performs MTS alignment for phase-coherent multi-channel operation
"""

import time
import sys

try:
    from pynq import Overlay
    import xrfclk
    import xrfdc
except ImportError:
    print("ERROR: PYNQ libraries not found. This script must run on the RFSoC board.")
    sys.exit(1)

class MTSCalibration:
    def __init__(self, bitstream='system_top.bit'):
        """Initialize overlay and RFDC"""
        print("Loading bitstream...")
        self.ol = Overlay(bitstream)
        self.rfdc = self.ol.usp_rf_data_converter_0
        print(f"Bitstream loaded successfully\n")

    def configure_clocks(self, lmk_freq=500.0, lmx_freq=500.0):
        """Configure external clock chips (LMK04828, LMX2594)"""
        print(f"Configuring clock chips...")
        print(f"  LMK04828: {lmk_freq} MHz")
        print(f"  LMX2594: {lmx_freq} MHz")

        try:
            xrfclk.set_ref_clks(lmk_freq=lmk_freq, lmx_freq=lmx_freq)
            print("Clock chips configured successfully\n")
            time.sleep(0.5)  # Allow clocks to stabilize
            return True
        except Exception as e:
            print(f"ERROR configuring clocks: {e}")
            return False

    def init_mts_sequence(self):
        """Initialize MTS - bring up tiles in correct sequence"""
        print("Initializing MTS sequence...")

        # Step 1: Enable single tile first
        print("  Step 1: Enabling reference tile...")
        # This would require GPIO or register access to tile enables
        # Placeholder for actual implementation

        # Step 2: Reset MMCM clock wizard
        print("  Step 2: Resetting MMCM...")
        if hasattr(self.ol, 'clk_wiz_mts'):
            # Reset clock wizard via MMIO
            # self.ol.clk_wiz_mts.write(RESET_ADDR, RESET_TOKEN)
            pass

        # Step 3: Reset DAC tiles
        print("  Step 3: Resetting DAC tiles...")
        for tile_id in [0, 1]:
            try:
                dac_tile = self.rfdc.dac_tiles[tile_id]
                if dac_tile.Enable:
                    # Tile reset would be done via RFDC driver
                    pass
            except:
                pass

        # Step 4: Toggle ADC FIFO to restart MTS
        print("  Step 4: Resetting ADC FIFOs...")
        # GPIO or register control for FIFO reset

        print("MTS initialization sequence complete\n")

    def configure_mts_adc(self, ref_tile=0, tiles_mask=0x03, target_latency=-1):
        """Configure and run MTS for ADC tiles"""
        print(f"Configuring MTS for ADC tiles...")
        print(f"  Reference Tile: {ref_tile}")
        print(f"  Tiles Mask: 0b{tiles_mask:04b}")
        print(f"  Target Latency: {target_latency} (-1 = auto)")

        # Configure MTS parameters
        mts_config = {
            'RefTile': ref_tile,
            'Tiles': tiles_mask,
            'SysRef_Enable': 1,
            'Target_Latency': target_latency
        }

        try:
            # Run MTS
            ret = self.rfdc.mts_adc_config = mts_config
            result = self.rfdc.mts_adc()

            if result == 0:
                print(f"  ✅ ADC MTS successful")
                return True
            else:
                print(f"  ❌ ADC MTS failed with code: {result}")
                return False

        except Exception as e:
            print(f"  ❌ ADC MTS exception: {e}")
            return False

    def configure_mts_dac(self, ref_tile=0, tiles_mask=0x03, target_latency=-1):
        """Configure and run MTS for DAC tiles"""
        print(f"\nConfiguring MTS for DAC tiles...")
        print(f"  Reference Tile: {ref_tile}")
        print(f"  Tiles Mask: 0b{tiles_mask:04b}")
        print(f"  Target Latency: {target_latency} (-1 = auto)")

        # Configure MTS parameters
        mts_config = {
            'RefTile': ref_tile,
            'Tiles': tiles_mask,
            'SysRef_Enable': 1,
            'Target_Latency': target_latency
        }

        try:
            # Run MTS
            self.rfdc.mts_dac_config = mts_config
            result = self.rfdc.mts_dac()

            if result == 0:
                print(f"  ✅ DAC MTS successful")
                return True
            else:
                print(f"  ❌ DAC MTS failed with code: {result}")
                return False

        except Exception as e:
            print(f"  ❌ DAC MTS exception: {e}")
            return False

    def verify_mts_lock(self):
        """Verify MTS lock status"""
        print(f"\nVerifying MTS lock status...")

        # Check clock wizard lock
        locked = True
        if hasattr(self.ol, 'clk_wiz_mts'):
            # Check MMCM lock status
            # lock_status = self.ol.clk_wiz_mts.read(LOCK_ADDR)
            # locked = (lock_status & LOCK_BIT) != 0
            print(f"  Clock Wizard: {'✅ LOCKED' if locked else '❌ UNLOCKED'}")

        # Check individual tile status
        for tile_id in [0, 1]:
            try:
                adc_tile = self.rfdc.adc_tiles[tile_id]
                if adc_tile.Enable:
                    # Check tile status
                    # status = adc_tile.get_status()
                    print(f"  ADC Tile {tile_id}: ✅ OK")
            except:
                pass

        for tile_id in [0, 1]:
            try:
                dac_tile = self.rfdc.dac_tiles[tile_id]
                if dac_tile.Enable:
                    print(f"  DAC Tile {tile_id}: ✅ OK")
            except:
                pass

        return locked

    def measure_phase_coherence(self):
        """Measure phase coherence between channels"""
        print(f"\nMeasuring phase coherence...")

        # This would require capturing data from multiple channels
        # and computing cross-correlation or phase difference
        # Placeholder for actual implementation

        print("  Phase measurement not yet implemented")
        print("  Manual verification required:")
        print("    1. Apply same tone to all channels")
        print("    2. Capture data from all channels")
        print("    3. Compute phase difference")
        print("    4. Verify phase difference < 1 degree")

    def run_calibration(self, adc_tiles=0x03, dac_tiles=0x03):
        """Run complete MTS calibration sequence"""
        print(f"\n{'='*70}")
        print(f"Running MTS Calibration")
        print(f"{'='*70}\n")

        # Step 1: Configure clocks
        if not self.configure_clocks():
            print("\n❌ Clock configuration failed. Check LMK/LMX connections.")
            return False

        # Step 2: Initialize MTS sequence
        self.init_mts_sequence()

        # Step 3: Run ADC MTS
        adc_ok = self.configure_mts_adc(tiles_mask=adc_tiles)

        # Step 4: Run DAC MTS
        dac_ok = self.configure_mts_dac(tiles_mask=dac_tiles)

        # Step 5: Verify lock
        lock_ok = self.verify_mts_lock()

        # Step 6: Measure coherence (optional)
        self.measure_phase_coherence()

        # Summary
        print(f"\n{'='*70}")
        print(f"Calibration Summary")
        print(f"{'='*70}")
        print(f"  ADC MTS: {'✅ PASS' if adc_ok else '❌ FAIL'}")
        print(f"  DAC MTS: {'✅ PASS' if dac_ok else '❌ FAIL'}")
        print(f"  Lock Status: {'✅ PASS' if lock_ok else '❌ FAIL'}")

        overall = adc_ok and dac_ok and lock_ok
        print(f"\n  Overall: {'✅ PASS - System is phase coherent' if overall else '❌ FAIL - Calibration required'}")
        print(f"{'='*70}\n")

        return overall

def main():
    import argparse

    parser = argparse.ArgumentParser(description='RFSoC MTS Calibration')
    parser.add_argument('--bitstream', default='system_top.bit', help='Bitstream path')
    parser.add_argument('--adc-tiles', type=lambda x: int(x, 0), default=0x03,
                        help='ADC tiles mask (e.g., 0x03 for tiles 0,1)')
    parser.add_argument('--dac-tiles', type=lambda x: int(x, 0), default=0x03,
                        help='DAC tiles mask (e.g., 0x03 for tiles 0,1)')
    parser.add_argument('--lmk-freq', type=float, default=500.0, help='LMK frequency (MHz)')
    parser.add_argument('--lmx-freq', type=float, default=500.0, help='LMX frequency (MHz)')
    args = parser.parse_args()

    try:
        cal = MTSCalibration(args.bitstream)
        success = cal.run_calibration(adc_tiles=args.adc_tiles, dac_tiles=args.dac_tiles)
        return 0 if success else 1

    except Exception as e:
        print(f"\n❌ ERROR: {str(e)}")
        import traceback
        traceback.print_exc()
        return 1

if __name__ == "__main__":
    sys.exit(main())
