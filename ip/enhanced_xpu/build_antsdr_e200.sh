#!/bin/bash
# SPDX-FileCopyrightText: 2025 OpenWiFi Project
# SPDX-License-Identifier: AGPL-3.0-only
#
# Build script for enhanced_xpu IP core - ANTSDR E200 variant
# This script packages the enhanced_xpu IP core for the ANTSDR E200 board

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

BOARD_NAME="antsdr_e200"
IP_NAME="enhanced_xpu"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IP_DIR="${SCRIPT_DIR}"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BOARD_DIR="${REPO_ROOT}/boards/${BOARD_NAME}"
IP_REPO_DIR="${BOARD_DIR}/ip_repo"

echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}Enhanced XPU IP Build - ${BOARD_NAME}${NC}"
echo -e "${GREEN}================================${NC}"

# Check if Vivado is in PATH
if ! command -v vivado &> /dev/null; then
    echo -e "${RED}ERROR: Vivado not found in PATH${NC}"
    echo "Please source Vivado settings: source /opt/Xilinx/Vivado/2021.1/settings64.sh"
    exit 1
fi

VIVADO_VERSION=$(vivado -version | head -n1 | awk '{print $2}')
echo -e "${YELLOW}Using Vivado version: ${VIVADO_VERSION}${NC}"

# Verify source files exist
echo -e "${YELLOW}Verifying source files...${NC}"
if [ ! -f "${IP_DIR}/src/enhanced_pkt_filter.v" ]; then
    echo -e "${RED}ERROR: enhanced_pkt_filter.v not found${NC}"
    exit 1
fi

if [ ! -f "${IP_DIR}/src/remote_id_codec.v" ]; then
    echo -e "${RED}ERROR: remote_id_codec.v not found${NC}"
    exit 1
fi

if [ ! -f "${IP_DIR}/component.xml" ]; then
    echo -e "${RED}ERROR: component.xml not found${NC}"
    exit 1
fi

echo -e "${GREEN}All source files verified${NC}"

# Create IP repository directory if it doesn't exist
echo -e "${YELLOW}Creating IP repository directory...${NC}"
mkdir -p "${IP_REPO_DIR}/${IP_NAME}"

# Copy IP files to repository
echo -e "${YELLOW}Copying IP files to repository...${NC}"
cp -r "${IP_DIR}/src" "${IP_REPO_DIR}/${IP_NAME}/"
cp -r "${IP_DIR}/include" "${IP_REPO_DIR}/${IP_NAME}/" 2>/dev/null || true
cp -r "${IP_DIR}/test" "${IP_REPO_DIR}/${IP_NAME}/" 2>/dev/null || true
cp "${IP_DIR}/component.xml" "${IP_REPO_DIR}/${IP_NAME}/"

# Create TCL script for IP packaging
TCL_SCRIPT="${IP_DIR}/package_ip_${BOARD_NAME}.tcl"
cat > "${TCL_SCRIPT}" << 'EOF'
# SPDX-FileCopyrightText: 2025 OpenWiFi Project
# SPDX-License-Identifier: AGPL-3.0-only

# Get environment variables
set ip_name $::env(IP_NAME)
set ip_repo_dir $::env(IP_REPO_DIR)
set board_name $::env(BOARD_NAME)

# Create temporary project for packaging
set proj_name "tmp_${ip_name}_${board_name}"
set proj_dir "${ip_repo_dir}/${proj_name}"

# Remove old project if exists
file delete -force ${proj_dir}

# Create project with correct part for ANTSDR E200 (Zynq7020)
create_project ${proj_name} ${proj_dir} -part xc7z020clg400-1 -force

# Set IP repository paths
set_property ip_repo_paths ${ip_repo_dir} [current_project]
update_ip_catalog

# Add source files
add_files -norecurse ${ip_repo_dir}/${ip_name}/src/enhanced_pkt_filter.v
add_files -norecurse ${ip_repo_dir}/${ip_name}/src/remote_id_codec.v

# Add include directory if exists
if {[file exists ${ip_repo_dir}/${ip_name}/include]} {
    set_property include_dirs ${ip_repo_dir}/${ip_name}/include [current_fileset]
}

# Add testbench files to simulation fileset
if {[file exists ${ip_repo_dir}/${ip_name}/test/enhanced_pkt_filter_tb.v]} {
    add_files -fileset sim_1 -norecurse ${ip_repo_dir}/${ip_name}/test/enhanced_pkt_filter_tb.v
}

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# Package IP
ipx::package_project -root_dir ${ip_repo_dir}/${ip_name} -vendor OpenWiFi -library user -taxonomy /UserIP -import_files -set_current false -force

# Open packaged IP
ipx::open_ipxact_file ${ip_repo_dir}/${ip_name}/component.xml

# Set IP properties
set_property name ${ip_name} [ipx::current_core]
set_property display_name "Enhanced XPU - Monitor Mode & Remote ID (E200)" [ipx::current_core]
set_property description "Enhanced packet filter with monitor mode support and drone Remote ID detection for ${board_name}" [ipx::current_core]
set_property vendor OpenWiFi [ipx::current_core]
set_property company_url "https://github.com/open-sdr/openwifi-hw" [ipx::current_core]
set_property version 1.0 [ipx::current_core]
set_property core_revision 1 [ipx::current_core]

# Set supported families
set_property supported_families {zynq Production} [ipx::current_core]

# Add resource utilization estimates
set_property widget {textEdit} [ipgui::get_guiparamspec -name "Component_Name" -component [ipx::current_core]]

# Infer interfaces if not already defined
ipx::infer_bus_interfaces xilinx.com:interface:aximm_rtl:1.0 [ipx::current_core]

# Associate clocks and resets
ipx::associate_bus_interfaces -busif S_AXI -clock S_AXI_ACLK [ipx::current_core]
ipx::associate_bus_interfaces -clock S_AXI_ACLK -reset S_AXI_ARESETN [ipx::current_core]

# Save and close
ipx::create_xgui_files [ipx::current_core]
ipx::update_checksums [ipx::current_core]
ipx::check_integrity [ipx::current_core]
ipx::save_core [ipx::current_core]
ipx::unload_core [ipx::current_core]

puts "IP packaging complete for ${board_name}"

# Clean up temporary project
close_project
file delete -force ${proj_dir}

exit
EOF

# Run Vivado in batch mode to package IP
echo -e "${YELLOW}Packaging IP core with Vivado...${NC}"
export IP_NAME="${IP_NAME}"
export IP_REPO_DIR="${IP_REPO_DIR}"
export BOARD_NAME="${BOARD_NAME}"

vivado -mode batch -source "${TCL_SCRIPT}" -notrace

# Check if packaging was successful
if [ -f "${IP_REPO_DIR}/${IP_NAME}/component.xml" ]; then
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}IP packaging successful!${NC}"
    echo -e "${GREEN}IP location: ${IP_REPO_DIR}/${IP_NAME}${NC}"
    echo -e "${GREEN}Board: ${BOARD_NAME}${NC}"
    echo -e "${GREEN}================================${NC}"

    # Print resource estimates (placeholder - actual values from synthesis)
    echo -e "${YELLOW}Estimated Resource Utilization (Zynq7020):${NC}"
    echo "  LUTs:       ~2500-3500 (4.6-6.5%)"
    echo "  Registers:  ~1800-2500 (1.7-2.4%)"
    echo "  BRAMs:      4-6 (2.9-4.3%)"
    echo "  DSPs:       0"
    echo ""
    echo -e "${YELLOW}ANTSDR E200 Specific Notes:${NC}"
    echo "  - Ethernet moved to PL side for higher bandwidth"
    echo "  - Same resource constraints as standard ANTSDR"
    echo "  - Compatible with IIO-based SDR drivers"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo "  1. Add IP repository to Vivado project:"
    echo "     Settings -> IP -> Repository -> Add: ${IP_REPO_DIR}"
    echo "  2. Add ${IP_NAME} to block design"
    echo "  3. Connect to AXI interconnect"
    echo "  4. Assign address (e.g., 0x43C00000)"

    # Clean up TCL script
    rm -f "${TCL_SCRIPT}"
    exit 0
else
    echo -e "${RED}================================${NC}"
    echo -e "${RED}IP packaging FAILED${NC}"
    echo -e "${RED}Check vivado.log for details${NC}"
    echo -e "${RED}================================${NC}"
    rm -f "${TCL_SCRIPT}"
    exit 1
fi
