#!/bin/bash
# SPDX-FileCopyrightText: 2025 OpenWiFi Project
# SPDX-License-Identifier: AGPL-3.0-only
#
# Build script for enhanced_xpu IP core - All board variants
# This script builds and validates the IP core for all supported boards

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_LOG="${SCRIPT_DIR}/build_all.log"

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}Enhanced XPU IP Build - All Board Variants${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

# Check if Vivado is in PATH
if ! command -v vivado &> /dev/null; then
    echo -e "${RED}ERROR: Vivado not found in PATH${NC}"
    echo "Please source Vivado settings: source /opt/Xilinx/Vivado/2021.1/settings64.sh"
    exit 1
fi

VIVADO_VERSION=$(vivado -version | head -n1 | awk '{print $2}')
echo -e "${YELLOW}Using Vivado version: ${VIVADO_VERSION}${NC}"
echo ""

# Initialize build log
echo "Enhanced XPU IP Build Log - $(date)" > "${BUILD_LOG}"
echo "Vivado Version: ${VIVADO_VERSION}" >> "${BUILD_LOG}"
echo "================================================" >> "${BUILD_LOG}"
echo "" >> "${BUILD_LOG}"

# Define supported board variants
BOARDS=("antsdr" "antsdr_e200")
BUILD_RESULTS=()
BUILD_TIMES=()

# Build for each board
for BOARD in "${BOARDS[@]}"; do
    echo -e "${GREEN}------------------------------------------------${NC}"
    echo -e "${GREEN}Building for: ${BOARD}${NC}"
    echo -e "${GREEN}------------------------------------------------${NC}"

    START_TIME=$(date +%s)

    # Run board-specific build script
    BUILD_SCRIPT="${SCRIPT_DIR}/build_${BOARD}.sh"

    if [ ! -f "${BUILD_SCRIPT}" ]; then
        echo -e "${RED}ERROR: Build script not found: ${BUILD_SCRIPT}${NC}"
        BUILD_RESULTS+=("${BOARD}: FAILED (script not found)")
        continue
    fi

    # Make sure build script is executable
    chmod +x "${BUILD_SCRIPT}"

    # Run build and capture output
    echo "Building ${BOARD}..." >> "${BUILD_LOG}"
    if bash "${BUILD_SCRIPT}" >> "${BUILD_LOG}" 2>&1; then
        END_TIME=$(date +%s)
        BUILD_TIME=$((END_TIME - START_TIME))
        BUILD_TIMES+=("${BOARD}: ${BUILD_TIME}s")
        BUILD_RESULTS+=("${BOARD}: SUCCESS")
        echo -e "${GREEN}${BOARD}: Build successful (${BUILD_TIME}s)${NC}"
    else
        END_TIME=$(date +%s)
        BUILD_TIME=$((END_TIME - START_TIME))
        BUILD_TIMES+=("${BOARD}: ${BUILD_TIME}s")
        BUILD_RESULTS+=("${BOARD}: FAILED")
        echo -e "${RED}${BOARD}: Build failed (${BUILD_TIME}s)${NC}"
        echo -e "${YELLOW}Check ${BUILD_LOG} for details${NC}"
    fi

    echo "" >> "${BUILD_LOG}"
    echo ""
done

# Print summary
echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}Build Summary${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

echo -e "${YELLOW}Build Results:${NC}"
for RESULT in "${BUILD_RESULTS[@]}"; do
    if [[ $RESULT == *"SUCCESS"* ]]; then
        echo -e "  ${GREEN}${RESULT}${NC}"
    else
        echo -e "  ${RED}${RESULT}${NC}"
    fi
done

echo ""
echo -e "${YELLOW}Build Times:${NC}"
for TIME in "${BUILD_TIMES[@]}"; do
    echo -e "  ${TIME}"
done

echo ""
echo -e "${YELLOW}IP Core Validation:${NC}"

# Verify that both boards use the same core RTL
VALIDATION_PASSED=true

# Check if source files are identical across builds
echo -e "  Verifying core RTL consistency..."

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ANTSDR_SRC="${REPO_ROOT}/boards/antsdr/ip_repo/enhanced_xpu/src"
E200_SRC="${REPO_ROOT}/boards/antsdr_e200/ip_repo/enhanced_xpu/src"

if [ -d "${ANTSDR_SRC}" ] && [ -d "${E200_SRC}" ]; then
    # Compare enhanced_pkt_filter.v
    if diff -q "${ANTSDR_SRC}/enhanced_pkt_filter.v" "${E200_SRC}/enhanced_pkt_filter.v" > /dev/null 2>&1; then
        echo -e "    ${GREEN}enhanced_pkt_filter.v: IDENTICAL${NC}"
    else
        echo -e "    ${RED}enhanced_pkt_filter.v: DIFFERENT${NC}"
        VALIDATION_PASSED=false
    fi

    # Compare remote_id_codec.v
    if diff -q "${ANTSDR_SRC}/remote_id_codec.v" "${E200_SRC}/remote_id_codec.v" > /dev/null 2>&1; then
        echo -e "    ${GREEN}remote_id_codec.v: IDENTICAL${NC}"
    else
        echo -e "    ${RED}remote_id_codec.v: DIFFERENT${NC}"
        VALIDATION_PASSED=false
    fi
else
    echo -e "    ${YELLOW}WARNING: Cannot verify - source directories not found${NC}"
    VALIDATION_PASSED=false
fi

echo ""
echo -e "${YELLOW}Resource Utilization Comparison:${NC}"
echo "  Both boards use Zynq7020 (xc7z020clg400-1)"
echo "  Expected resources (estimated):"
echo "    LUTs:       ~2500-3500 (4.6-6.5% of 53200)"
echo "    Registers:  ~1800-2500 (1.7-2.4% of 106400)"
echo "    BRAMs:      4-6 (2.9-4.3% of 140)"
echo "    DSPs:       0 (0% of 220)"
echo ""
echo -e "${YELLOW}Note:${NC} Actual resource usage may vary based on:"
echo "  - Synthesis strategy (antsdr uses Flow_PerfOptimized_high)"
echo "  - Board-specific optimizations"
echo "  - Vivado version"

echo ""
echo -e "${YELLOW}Board Differences:${NC}"
echo "  ANTSDR:"
echo "    - Standard configuration"
echo "    - Ethernet on PS side"
echo "    - Multiple constraint files (LVDS, CCBOB)"
echo ""
echo "  ANTSDR E200:"
echo "    - Compact design"
echo "    - Ethernet on PL side (higher bandwidth)"
echo "    - Single constraint file"
echo "    - UHD driver support available"

echo ""
if [ "$VALIDATION_PASSED" = true ]; then
    echo -e "${GREEN}================================================${NC}"
    echo -e "${GREEN}All validations passed!${NC}"
    echo -e "${GREEN}Same IP core works on both board variants${NC}"
    echo -e "${GREEN}================================================${NC}"
else
    echo -e "${YELLOW}================================================${NC}"
    echo -e "${YELLOW}WARNING: Some validations failed${NC}"
    echo -e "${YELLOW}Check ${BUILD_LOG} for details${NC}"
    echo -e "${YELLOW}================================================${NC}"
fi

echo ""
echo -e "${BLUE}Build log saved to: ${BUILD_LOG}${NC}"

# Check if all builds succeeded
ALL_SUCCESS=true
for RESULT in "${BUILD_RESULTS[@]}"; do
    if [[ $RESULT != *"SUCCESS"* ]]; then
        ALL_SUCCESS=false
        break
    fi
done

if [ "$ALL_SUCCESS" = true ]; then
    echo -e "${GREEN}All builds completed successfully!${NC}"
    exit 0
else
    echo -e "${RED}Some builds failed. Check ${BUILD_LOG} for details.${NC}"
    exit 1
fi
