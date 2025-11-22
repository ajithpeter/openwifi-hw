#!/usr/bin/env python3
"""
OpenWiFi RFSoC4x2 Hardware Loopback Test
Tests RFDC ADC/DAC functionality without WiFi processing
"""

import numpy as np
import matplotlib.pyplot as plt
from pynq import Overlay, allocate
import time

class RFSoCLoopbackTest:
    def __init__(self, bitstream_path='system_top.bit'):
        """Initialize RFSoC overlay and configure for loopback"""
        print("Loading bitstream...")
        self.ol = Overlay(bitstream_path)
        self.rfdc = self.ol.usp_rf_data_converter_0

        print(f"Bitstream loaded: {bitstream_path}")
        print(f"RFDC IP version: {self.rfdc._version}")

    def configure_rfdc(self, freq_mhz=2412.0, sample_rate_gsps=0.98304):
        """Configure RFDC for WiFi frequency"""
        print(f"\nConfiguring RFDC...")
        print(f"  Frequency: {freq_mhz} MHz")
        print(f"  Sample Rate: {sample_rate_gsps} GSPS")

        # Configure ADC Tile 0
        adc_tile = self.rfdc.adc_tiles[0]
        adc_block = adc_tile.blocks[0]

        # Set mixer frequency
        adc_block.MixerSettings = {
            'CoarseMixFreq': 0,  # XRFDC_COARSE_MIX_BYPASS
            'Freq': freq_mhz,
            'MixerMode': 2,  # XRFDC_MIXER_MODE_C2R
            'MixerType': 3,  # XRFDC_MIXER_TYPE_FINE (NCO)
            'PhaseOffset': 0.0
        }
        adc_block.UpdateEvent(0x1)  # XRFDC_EVENT_MIXER

        # Configure DAC Tile 0
        dac_tile = self.rfdc.dac_tiles[0]
        dac_block = dac_tile.blocks[0]

        dac_block.MixerSettings = {
            'CoarseMixFreq': 0,
            'Freq': freq_mhz,
            'MixerMode': 1,  # XRFDC_MIXER_MODE_R2C
            'MixerType': 3,
            'PhaseOffset': 0.0
        }
        dac_block.UpdateEvent(0x1)

        print("RFDC configured successfully")

    def generate_test_tone(self, freq_mhz=10.0, amplitude=8000, length=8192):
        """Generate test tone for DAC"""
        sample_rate = 983.04e6  # RFDC sample rate
        t = np.arange(length) / sample_rate

        # Generate complex tone (I/Q)
        tone_i = (amplitude * np.cos(2 * np.pi * freq_mhz * 1e6 * t)).astype(np.int16)
        tone_q = (amplitude * np.sin(2 * np.pi * freq_mhz * 1e6 * t)).astype(np.int16)

        return tone_i, tone_q

    def run_loopback_test(self, tone_freq_mhz=10.0):
        """Run complete loopback test"""
        print(f"\n{'='*60}")
        print(f"Running Loopback Test - {tone_freq_mhz} MHz Tone")
        print(f"{'='*60}\n")

        # Generate test signal
        print("Generating test tone...")
        tone_i, tone_q = self.generate_test_tone(freq_mhz=tone_freq_mhz)

        # Allocate DMA buffers
        print("Allocating DMA buffers...")
        tx_buffer = allocate(shape=(len(tone_i)*2,), dtype=np.int16)  # *2 for interleaved I/Q
        rx_buffer = allocate(shape=(len(tone_i)*2,), dtype=np.int16)  # *2 for interleaved I/Q

        # Load TX data (interleaved I/Q)
        # Format: [I0, Q0, I1, Q1, ...]
        tx_data = np.empty(len(tone_i) * 2, dtype=np.int16)
        tx_data[0::2] = tone_i
        tx_data[1::2] = tone_q
        tx_buffer[:] = tx_data  # Copy full interleaved I/Q data

        # Start RX DMA
        print("Starting RX DMA...")
        if hasattr(self.ol, 'adc_dma'):
            self.ol.adc_dma.recvchannel.transfer(rx_buffer)
        else:
            print("WARNING: No ADC DMA found, using memory-mapped capture")

        # Transmit
        print("Transmitting tone...")
        if hasattr(self.ol, 'dac_dma'):
            self.ol.dac_dma.sendchannel.transfer(tx_buffer)
            self.ol.dac_dma.sendchannel.wait()
        else:
            print("WARNING: No DAC DMA found")

        # Wait for RX
        time.sleep(0.1)
        if hasattr(self.ol, 'adc_dma'):
            self.ol.adc_dma.recvchannel.wait()

        # Analyze results
        print("\nAnalyzing captured data...")
        self.analyze_capture(rx_buffer, tone_freq_mhz)

        return tx_buffer, rx_buffer

    def analyze_capture(self, rx_buffer, expected_freq_mhz):
        """Analyze captured data for tone presence"""
        data = np.array(rx_buffer)

        # Deinterleave I/Q
        i_data = data[0::2]
        q_data = data[1::2]

        # Compute FFT
        complex_data = i_data + 1j * q_data
        fft_result = np.fft.fft(complex_data)
        fft_freq = np.fft.fftfreq(len(complex_data), 1/983.04e6)

        # Find peak
        fft_mag = np.abs(fft_result)
        peak_idx = np.argmax(fft_mag)
        peak_freq = abs(fft_freq[peak_idx]) / 1e6  # Convert to MHz

        print(f"  Peak frequency: {peak_freq:.2f} MHz")
        print(f"  Expected: {expected_freq_mhz:.2f} MHz")
        print(f"  Error: {abs(peak_freq - expected_freq_mhz):.2f} MHz")

        # Compute SNR estimate
        signal_power = fft_mag[peak_idx]**2
        noise_indices = np.arange(len(fft_mag))
        noise_indices = noise_indices[np.abs(noise_indices - peak_idx) > 10]
        noise_power = np.mean(fft_mag[noise_indices]**2)
        snr_db = 10 * np.log10(signal_power / noise_power)

        print(f"  Estimated SNR: {snr_db:.1f} dB")

        # Pass/Fail criteria
        freq_error = abs(peak_freq - expected_freq_mhz)
        if freq_error < 1.0 and snr_db > 20:
            print(f"\n  ✅ PASS: Loopback test successful")
            result = "PASS"
        else:
            print(f"\n  ❌ FAIL: Loopback test failed")
            if freq_error >= 1.0:
                print(f"     Frequency error too large: {freq_error:.2f} MHz")
            if snr_db <= 20:
                print(f"     SNR too low: {snr_db:.1f} dB")
            result = "FAIL"

        # Plot results
        self.plot_results(i_data, q_data, fft_freq/1e6, fft_mag, expected_freq_mhz)

        return result

    def plot_results(self, i_data, q_data, fft_freq, fft_mag, expected_freq):
        """Plot time domain and frequency domain results"""
        fig, axes = plt.subplots(2, 2, figsize=(12, 8))

        # Time domain - I channel
        axes[0, 0].plot(i_data[:1000])
        axes[0, 0].set_title('Time Domain - I Channel')
        axes[0, 0].set_xlabel('Sample')
        axes[0, 0].set_ylabel('Amplitude')
        axes[0, 0].grid(True)

        # Time domain - Q channel
        axes[0, 1].plot(q_data[:1000])
        axes[0, 1].set_title('Time Domain - Q Channel')
        axes[0, 1].set_xlabel('Sample')
        axes[0, 1].set_ylabel('Amplitude')
        axes[0, 1].grid(True)

        # Frequency domain
        axes[1, 0].plot(fft_freq, 20*np.log10(fft_mag + 1e-10))
        axes[1, 0].set_title('Frequency Spectrum')
        axes[1, 0].set_xlabel('Frequency (MHz)')
        axes[1, 0].set_ylabel('Magnitude (dB)')
        axes[1, 0].axvline(expected_freq, color='r', linestyle='--', label=f'Expected: {expected_freq} MHz')
        axes[1, 0].legend()
        axes[1, 0].grid(True)
        axes[1, 0].set_xlim([-50, 50])

        # IQ constellation
        axes[1, 1].scatter(i_data[::10], q_data[::10], alpha=0.5, s=1)
        axes[1, 1].set_title('IQ Constellation')
        axes[1, 1].set_xlabel('I')
        axes[1, 1].set_ylabel('Q')
        axes[1, 1].grid(True)
        axes[1, 1].axis('equal')

        plt.tight_layout()
        plt.savefig('loopback_test_results.png', dpi=150)
        print(f"\n  Plot saved to: loopback_test_results.png")
        # plt.show()  # Uncomment for interactive display

    def check_rfdc_status(self):
        """Check and print RFDC configuration status"""
        print(f"\n{'='*60}")
        print("RFDC Status")
        print(f"{'='*60}\n")

        # Check ADC tiles
        for tile_id in range(4):
            try:
                adc_tile = self.rfdc.adc_tiles[tile_id]
                if adc_tile.Enable:
                    print(f"ADC Tile {tile_id}: ENABLED")
                    for block_id in range(4):
                        try:
                            block = adc_tile.blocks[block_id]
                            if block.Enable:
                                print(f"  Block {block_id}: ENABLED")
                                print(f"    Sampling Rate: {block.SamplingFrequency} GSPS")
                                print(f"    Fabric Freq: {block.FabricFrequency} MHz")
                        except:
                            pass
            except:
                pass

        print()

        # Check DAC tiles
        for tile_id in range(4):
            try:
                dac_tile = self.rfdc.dac_tiles[tile_id]
                if dac_tile.Enable:
                    print(f"DAC Tile {tile_id}: ENABLED")
                    for block_id in range(4):
                        try:
                            block = dac_tile.blocks[block_id]
                            if block.Enable:
                                print(f"  Block {block_id}: ENABLED")
                                print(f"    Sampling Rate: {block.SamplingFrequency} GSPS")
                                print(f"    Fabric Freq: {block.FabricFrequency} MHz")
                        except:
                            pass
            except:
                pass

def main():
    """Main test routine"""
    import argparse

    parser = argparse.ArgumentParser(description='RFSoC Loopback Test')
    parser.add_argument('--bitstream', default='system_top.bit', help='Path to bitstream')
    parser.add_argument('--freq', type=float, default=10.0, help='Tone frequency (MHz)')
    parser.add_argument('--wifi-channel', type=int, default=1, help='WiFi channel (1-11)')
    args = parser.parse_args()

    # WiFi channel to frequency mapping
    wifi_freq = {
        1: 2412.0, 2: 2417.0, 3: 2422.0, 4: 2427.0, 5: 2432.0,
        6: 2437.0, 7: 2442.0, 8: 2447.0, 9: 2452.0, 10: 2457.0, 11: 2462.0
    }

    try:
        # Initialize test
        test = RFSoCLoopbackTest(args.bitstream)

        # Check RFDC status
        test.check_rfdc_status()

        # Configure for WiFi frequency
        test.configure_rfdc(freq_mhz=wifi_freq[args.wifi_channel])

        # Run loopback test
        tx_buf, rx_buf = test.run_loopback_test(tone_freq_mhz=args.freq)

        print(f"\n{'='*60}")
        print("Test Complete!")
        print(f"{'='*60}\n")

    except Exception as e:
        print(f"\n❌ ERROR: {str(e)}")
        import traceback
        traceback.print_exc()
        return 1

    return 0

if __name__ == "__main__":
    exit(main())
