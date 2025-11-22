#!/bin/bash

################################################################################
# run_all_tests.sh
#
# Description:
#   Automated test runner for enhanced_xpu IP core test benches.
#   Runs all Verilog test benches using iverilog (Icarus Verilog) or
#   Xilinx xsim simulator.
#
# Usage:
#   ./run_all_tests.sh [iverilog|xsim]
#
# Requirements:
#   - iverilog and vvp (Icarus Verilog), or
#   - Xilinx Vivado with xsim in PATH
#
# Author: OpenWiFi Team
# Date: 2025-11-22
################################################################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/../src"
TEST_DIR="${SCRIPT_DIR}"
BUILD_DIR="${TEST_DIR}/build"
RESULTS_DIR="${TEST_DIR}/results"

# Simulator selection (default: iverilog)
SIMULATOR="${1:-iverilog}"

# Test benches
TESTBENCHES=(
    "enhanced_pkt_filter_tb"
    "nan_action_handler_tb"
    "vendor_ie_codec_tb"
    "remote_id_codec_tb"
    "frame_injection_ctrl_tb"
)

# Module dependencies (source files needed for each test)
declare -A MODULE_DEPS
MODULE_DEPS["enhanced_pkt_filter_tb"]="enhanced_pkt_filter.v"
MODULE_DEPS["nan_action_handler_tb"]="nan_action_handler.v"
MODULE_DEPS["vendor_ie_codec_tb"]="vendor_ie_codec.v"
MODULE_DEPS["remote_id_codec_tb"]="remote_id_codec.v"
MODULE_DEPS["frame_injection_ctrl_tb"]="frame_injection_ctrl.v"

# Results tracking
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

################################################################################
# Functions
################################################################################

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Enhanced XPU Test Suite${NC}"
    echo -e "${BLUE}  Simulator: ${SIMULATOR}${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

print_separator() {
    echo -e "${BLUE}----------------------------------------${NC}"
}

check_simulator() {
    case "${SIMULATOR}" in
        iverilog)
            if ! command -v iverilog &> /dev/null; then
                echo -e "${RED}ERROR: iverilog not found in PATH${NC}"
                echo "Install Icarus Verilog: sudo apt-get install iverilog"
                exit 1
            fi
            if ! command -v vvp &> /dev/null; then
                echo -e "${RED}ERROR: vvp not found in PATH${NC}"
                exit 1
            fi
            echo -e "${GREEN}Found iverilog version: $(iverilog -V | head -1)${NC}"
            ;;
        xsim)
            if ! command -v xvlog &> /dev/null; then
                echo -e "${RED}ERROR: xvlog not found in PATH${NC}"
                echo "Source Vivado settings: source /opt/Xilinx/Vivado/*/settings64.sh"
                exit 1
            fi
            echo -e "${GREEN}Found Xilinx xsim${NC}"
            ;;
        *)
            echo -e "${RED}ERROR: Unknown simulator '${SIMULATOR}'${NC}"
            echo "Usage: $0 [iverilog|xsim]"
            exit 1
            ;;
    esac
    echo ""
}

setup_dirs() {
    echo "Setting up directories..."
    mkdir -p "${BUILD_DIR}"
    mkdir -p "${RESULTS_DIR}"
    echo ""
}

cleanup_build() {
    echo "Cleaning build directory..."
    rm -rf "${BUILD_DIR}"/*
    echo ""
}

# Run test with iverilog
run_test_iverilog() {
    local testbench="$1"
    local tb_file="${TEST_DIR}/${testbench}.v"
    local src_deps="${MODULE_DEPS[$testbench]}"
    local output="${BUILD_DIR}/${testbench}"
    local log_file="${RESULTS_DIR}/${testbench}.log"

    echo -e "${YELLOW}Running: ${testbench}${NC}"

    # Check if testbench file exists
    if [ ! -f "${tb_file}" ]; then
        echo -e "${YELLOW}SKIPPED: ${tb_file} not found${NC}"
        ((SKIPPED_TESTS++))
        return
    fi

    # Compile
    local compile_cmd="iverilog -g2012 -o ${output} ${tb_file}"

    # Add source dependencies if they exist
    for dep in ${src_deps}; do
        if [ -f "${SRC_DIR}/${dep}" ]; then
            compile_cmd="${compile_cmd} ${SRC_DIR}/${dep}"
        else
            echo -e "${YELLOW}WARNING: Dependency ${dep} not found, test may fail${NC}"
        fi
    done

    # Compile and run
    if ${compile_cmd} 2>&1 | tee "${log_file}.compile"; then
        echo "  Compilation successful"

        # Run simulation
        if vvp "${output}" 2>&1 | tee "${log_file}"; then
            # Check for test results in output
            if grep -q "ALL TESTS PASSED" "${log_file}"; then
                echo -e "  ${GREEN}✓ PASSED${NC}"
                ((PASSED_TESTS++))
            elif grep -q "SOME TESTS FAILED" "${log_file}"; then
                echo -e "  ${RED}✗ FAILED${NC}"
                ((FAILED_TESTS++))
                # Show failure summary
                grep -A 5 "Test Summary" "${log_file}" | grep -E "Failed:|FAIL"
            else
                echo -e "  ${YELLOW}⚠ UNKNOWN (check log)${NC}"
                ((SKIPPED_TESTS++))
            fi
        else
            echo -e "  ${RED}✗ RUNTIME ERROR${NC}"
            ((FAILED_TESTS++))
            tail -20 "${log_file}"
        fi
    else
        echo -e "  ${RED}✗ COMPILATION ERROR${NC}"
        ((FAILED_TESTS++))
        tail -20 "${log_file}.compile"
    fi

    ((TOTAL_TESTS++))
    echo ""
}

# Run test with xsim
run_test_xsim() {
    local testbench="$1"
    local tb_file="${TEST_DIR}/${testbench}.v"
    local src_deps="${MODULE_DEPS[$testbench]}"
    local log_file="${RESULTS_DIR}/${testbench}.log"
    local work_dir="${BUILD_DIR}/xsim_${testbench}"

    echo -e "${YELLOW}Running: ${testbench}${NC}"

    # Check if testbench file exists
    if [ ! -f "${tb_file}" ]; then
        echo -e "${YELLOW}SKIPPED: ${tb_file} not found${NC}"
        ((SKIPPED_TESTS++))
        return
    fi

    mkdir -p "${work_dir}"
    cd "${work_dir}"

    # Compile Verilog sources
    local compile_cmd="xvlog -sv ${tb_file}"

    for dep in ${src_deps}; do
        if [ -f "${SRC_DIR}/${dep}" ]; then
            compile_cmd="${compile_cmd} ${SRC_DIR}/${dep}"
        fi
    done

    if ${compile_cmd} 2>&1 | tee "${log_file}.compile"; then
        echo "  Compilation successful"

        # Elaborate
        if xelab -debug typical ${testbench} -s ${testbench}_sim 2>&1 | tee "${log_file}.elab"; then
            echo "  Elaboration successful"

            # Run simulation
            if xsim ${testbench}_sim -runall 2>&1 | tee "${log_file}"; then
                # Check results
                if grep -q "ALL TESTS PASSED" "${log_file}"; then
                    echo -e "  ${GREEN}✓ PASSED${NC}"
                    ((PASSED_TESTS++))
                elif grep -q "SOME TESTS FAILED" "${log_file}"; then
                    echo -e "  ${RED}✗ FAILED${NC}"
                    ((FAILED_TESTS++))
                else
                    echo -e "  ${YELLOW}⚠ UNKNOWN${NC}"
                    ((SKIPPED_TESTS++))
                fi
            else
                echo -e "  ${RED}✗ RUNTIME ERROR${NC}"
                ((FAILED_TESTS++))
            fi
        else
            echo -e "  ${RED}✗ ELABORATION ERROR${NC}"
            ((FAILED_TESTS++))
        fi
    else
        echo -e "  ${RED}✗ COMPILATION ERROR${NC}"
        ((FAILED_TESTS++))
    fi

    cd "${TEST_DIR}"
    ((TOTAL_TESTS++))
    echo ""
}

run_test() {
    case "${SIMULATOR}" in
        iverilog)
            run_test_iverilog "$1"
            ;;
        xsim)
            run_test_xsim "$1"
            ;;
    esac
}

print_summary() {
    print_separator
    echo -e "${BLUE}Test Summary${NC}"
    print_separator
    echo "Total tests:   ${TOTAL_TESTS}"
    echo -e "${GREEN}Passed:        ${PASSED_TESTS}${NC}"
    echo -e "${RED}Failed:        ${FAILED_TESTS}${NC}"
    echo -e "${YELLOW}Skipped:       ${SKIPPED_TESTS}${NC}"
    print_separator

    # Generate summary report
    local report_file="${RESULTS_DIR}/summary.txt"
    {
        echo "================================"
        echo "Enhanced XPU Test Suite Summary"
        echo "================================"
        echo "Date: $(date)"
        echo "Simulator: ${SIMULATOR}"
        echo ""
        echo "Total tests:   ${TOTAL_TESTS}"
        echo "Passed:        ${PASSED_TESTS}"
        echo "Failed:        ${FAILED_TESTS}"
        echo "Skipped:       ${SKIPPED_TESTS}"
        echo ""
        echo "Individual Results:"
        for tb in "${TESTBENCHES[@]}"; do
            if [ -f "${RESULTS_DIR}/${tb}.log" ]; then
                if grep -q "ALL TESTS PASSED" "${RESULTS_DIR}/${tb}.log"; then
                    echo "  [PASS] ${tb}"
                elif grep -q "SOME TESTS FAILED" "${RESULTS_DIR}/${tb}.log"; then
                    echo "  [FAIL] ${tb}"
                else
                    echo "  [SKIP] ${tb}"
                fi
            else
                echo "  [SKIP] ${tb}"
            fi
        done
    } > "${report_file}"

    echo ""
    echo "Summary report saved to: ${report_file}"
    echo ""

    # Exit code
    if [ ${FAILED_TESTS} -eq 0 ] && [ ${PASSED_TESTS} -gt 0 ]; then
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    elif [ ${PASSED_TESTS} -eq 0 ]; then
        echo -e "${RED}No tests passed!${NC}"
        return 1
    else
        echo -e "${YELLOW}Some tests failed.${NC}"
        return 1
    fi
}

################################################################################
# Main
################################################################################

main() {
    print_header
    check_simulator
    setup_dirs

    # Run all tests
    for testbench in "${TESTBENCHES[@]}"; do
        run_test "${testbench}"
    done

    # Print summary
    print_summary
}

# Run main
main
exit $?
