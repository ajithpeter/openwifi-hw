#!/bin/bash
# OpenWiFi RFSoC4x2 Automated Build Script
# Builds FPGA bitstream and exports hardware for software development

set -e  # Exit on error

# Configuration
BOARD=rfsoc4x2
JOBS=8
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENWIFI_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}OpenWiFi RFSoC4x2 Build Script${NC}"
echo -e "${GREEN}========================================${NC}"

# Check prerequisites
if [ -z "$XILINX_DIR" ]; then
    echo -e "${RED}ERROR: XILINX_DIR not set${NC}"
    echo "Please set XILINX_DIR to your Xilinx installation directory"
    echo "Example: export XILINX_DIR=/opt/Xilinx"
    exit 1
fi

if [ -z "$OPENWIFI_HW_IMG_DIR" ]; then
    echo -e "${YELLOW}WARNING: OPENWIFI_HW_IMG_DIR not set${NC}"
    echo "Using default: $OPENWIFI_ROOT/deploy"
    export OPENWIFI_HW_IMG_DIR="$OPENWIFI_ROOT/deploy"
    mkdir -p "$OPENWIFI_HW_IMG_DIR"
fi

# Check Vivado
if ! command -v vivado &> /dev/null; then
    echo -e "${RED}ERROR: Vivado not found in PATH${NC}"
    echo "Please source Vivado settings:"
    echo "  source $XILINX_DIR/Vivado/2022.2/settings64.sh"
    exit 1
fi

echo -e "${GREEN}Environment:${NC}"
echo "  XILINX_DIR: $XILINX_DIR"
echo "  BOARD: $BOARD"
echo "  JOBS: $JOBS"
echo "  OUTPUT: $OPENWIFI_HW_IMG_DIR"
echo ""

# Step 1: Get openofdm_rx submodule
echo -e "${GREEN}[1/5] Checking openofdm_rx submodule...${NC}"
cd "$OPENWIFI_ROOT"
if [ ! -f "ip/openofdm_rx/verilog/Xilinx/openofdm_rx.v" ]; then
    echo "Fetching openofdm_rx submodule..."
    ./get_ip_openofdm_rx.sh
else
    echo "openofdm_rx already present"
fi

# Step 2: Generate IP repository
echo -e "${GREEN}[2/5] Generating IP repository...${NC}"
cd "$SCRIPT_DIR"
if [ ! -d "ip_repo" ]; then
    ../create_ip_repo.sh "$XILINX_DIR"
else
    echo "IP repository already exists, regenerating..."
    rm -rf ip_repo
    ../create_ip_repo.sh "$XILINX_DIR"
fi

# Step 3: Create Vivado project and build
echo -e "${GREEN}[3/5] Building FPGA bitstream (this will take a while)...${NC}"
cd "$OPENWIFI_ROOT/boards"

# Create build TCL script
cat > build_${BOARD}_auto.tcl <<EOF
# Auto-generated build script for $BOARD
set BOARD_NAME "$BOARD"
set NUM_JOBS $JOBS

# Source main build script
source openwifi.tcl

# Run synthesis
reset_run synth_1
launch_runs synth_1 -jobs \$NUM_JOBS
wait_on_run synth_1

# Check synthesis results
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: Synthesis failed!"
    exit 1
}

# Run implementation
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs \$NUM_JOBS
wait_on_run impl_1

# Check implementation results
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Implementation failed!"
    exit 1
}

# Check timing
open_run impl_1
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]

puts "Worst Negative Slack (Setup): \$wns"
puts "Worst Hold Slack: \$whs"

if {\$wns < 0} {
    puts "WARNING: Timing constraints not met (WNS: \$wns)"
}

# Export hardware
write_hw_platform -fixed -include_bit -force \\
    -file openwifi_${BOARD}/system_top.xsa

puts "Build completed successfully!"
exit 0
EOF

# Run Vivado build
vivado -mode batch -source build_${BOARD}_auto.tcl -notrace | tee build_${BOARD}.log

# Check build result
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo -e "${RED}Build failed! Check build_${BOARD}.log for details${NC}"
    exit 1
fi

# Step 4: Export hardware
echo -e "${GREEN}[4/5] Exporting hardware platform...${NC}"
./sdk_update.sh "$BOARD" "$OPENWIFI_HW_IMG_DIR"

# Step 5: Generate summary
echo -e "${GREEN}[5/5] Generating build summary...${NC}"
cd "$OPENWIFI_ROOT/boards"

# Extract utilization and timing
if [ -f "openwifi_${BOARD}/openwifi_${BOARD}.runs/impl_1/system_top_utilization_placed.rpt" ]; then
    echo "" > "$OPENWIFI_HW_IMG_DIR/boards/$BOARD/build_summary.txt"
    echo "========================================" >> "$OPENWIFI_HW_IMG_DIR/boards/$BOARD/build_summary.txt"
    echo "OpenWiFi RFSoC4x2 Build Summary" >> "$OPENWIFI_HW_IMG_DIR/boards/$BOARD/build_summary.txt"
    echo "========================================" >> "$OPENWIFI_HW_IMG_DIR/boards/$BOARD/build_summary.txt"
    echo "Build Date: $(date)" >> "$OPENWIFI_HW_IMG_DIR/boards/$BOARD/build_summary.txt"
    echo "" >> "$OPENWIFI_HW_IMG_DIR/boards/$BOARD/build_summary.txt"

    echo "Resource Utilization:" >> "$OPENWIFI_HW_IMG_DIR/boards/$BOARD/build_summary.txt"
    grep -A 20 "Slice LUTs" "openwifi_${BOARD}/openwifi_${BOARD}.runs/impl_1/system_top_utilization_placed.rpt" >> "$OPENWIFI_HW_IMG_DIR/boards/$BOARD/build_summary.txt" || true

    if [ -f "openwifi_${BOARD}/openwifi_${BOARD}.runs/impl_1/system_top_timing_summary_routed.rpt" ]; then
        echo "" >> "$OPENWIFI_HW_IMG_DIR/boards/$BOARD/build_summary.txt"
        echo "Timing Summary:" >> "$OPENWIFI_HW_IMG_DIR/boards/$BOARD/build_summary.txt"
        grep -A 10 "Design Timing Summary" "openwifi_${BOARD}/openwifi_${BOARD}.runs/impl_1/system_top_timing_summary_routed.rpt" >> "$OPENWIFI_HW_IMG_DIR/boards/$BOARD/build_summary.txt" || true
    fi
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Build Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Output files:"
echo "  Bitstream: $OPENWIFI_HW_IMG_DIR/boards/$BOARD/sdk/system_top.bit"
echo "  XSA: $OPENWIFI_HW_IMG_DIR/boards/$BOARD/sdk/system_top.xsa"
echo "  Summary: $OPENWIFI_HW_IMG_DIR/boards/$BOARD/build_summary.txt"
echo ""
echo "Next steps:"
echo "  1. Copy bitstream to RFSoC4x2 board"
echo "  2. Build software using the XSA file"
echo "  3. See RFSOC_PORTING_GUIDE.md for testing procedures"
echo ""
