#!/bin/bash
# SPDX-FileCopyrightText: 2025 OpenWiFi Project
# SPDX-License-Identifier: AGPL-3.0-only

################################################################################
# Enhanced XPU Integration Test Runner
#
# Description:
#   Automated test execution script for all enhanced_xpu integration tests.
#   Supports multiple simulators and generates comprehensive test reports.
#
# Usage:
#   ./run_integration_tests.sh [OPTIONS]
#
# Options:
#   -s, --simulator <name>   Specify simulator: xsim, iverilog, modelsim
#   -t, --test <name>        Run specific test only
#   -w, --waveforms          Generate waveform dumps
#   -h, --html               Generate HTML report
#   -v, --verbose            Verbose output
#   -c, --clean              Clean previous build artifacts
#   --help                   Show this help message
#
# Examples:
#   ./run_integration_tests.sh                    # Run all tests with auto-detect
#   ./run_integration_tests.sh -s iverilog -w    # Use iverilog, generate waves
#   ./run_integration_tests.sh -t monitor_mode   # Run only monitor mode test
#
# Author: OpenWiFi Team
# Date: 2025-11-22
################################################################################

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default configuration
SIMULATOR="auto"
SPECIFIC_TEST=""
GENERATE_WAVES=0
GENERATE_HTML=1
VERBOSE=0
CLEAN=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/../../src"
BUILD_DIR="${SCRIPT_DIR}/build"
REPORT_FILE="${SCRIPT_DIR}/test_report.html"

# Test list
TESTS=(
    "monitor_mode_integration_tb"
    "injection_integration_tb"
    "remote_id_e2e_tb"
    "stress_test_tb"
)

# Test descriptions
declare -A TEST_DESC
TEST_DESC["monitor_mode_integration_tb"]="Monitor Mode Integration Test (RX Path)"
TEST_DESC["injection_integration_tb"]="Frame Injection Integration Test (TX Path)"
TEST_DESC["remote_id_e2e_tb"]="Remote ID End-to-End Round-Trip Test"
TEST_DESC["stress_test_tb"]="High-Load Stress Test"

# Results
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
declare -A TEST_RESULTS
declare -A TEST_TIMES

################################################################################
# Functions
################################################################################

print_banner() {
    echo -e "${CYAN}"
    echo "================================================================================"
    echo "  Enhanced XPU Integration Test Suite"
    echo "  OpenWiFi Hardware - Drone Remote ID & Monitor Mode"
    echo "================================================================================"
    echo -e "${NC}"
}

print_usage() {
    grep '^#' "$0" | grep -v '#!/bin/bash' | sed 's/^# \?//'
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_verbose() {
    if [ $VERBOSE -eq 1 ]; then
        echo -e "${CYAN}[VERB]${NC} $1"
    fi
}

detect_simulator() {
    log_info "Auto-detecting simulator..."

    if command -v xsim &> /dev/null; then
        echo "xsim"
    elif command -v iverilog &> /dev/null; then
        echo "iverilog"
    elif command -v vsim &> /dev/null; then
        echo "modelsim"
    else
        log_error "No supported simulator found!"
        log_error "Please install one of: Vivado (xsim), Icarus Verilog (iverilog), ModelSim (vsim)"
        exit 1
    fi
}

clean_build() {
    log_info "Cleaning previous build artifacts..."
    rm -rf "${BUILD_DIR}"
    rm -f *.vcd *.wdb *.log xsim.dir *.jou *.pb
    rm -f work-obj*.cf *.o *.vvp
    log_success "Clean complete"
}

setup_build_dir() {
    mkdir -p "${BUILD_DIR}"
    cd "${BUILD_DIR}"
}

compile_test_xsim() {
    local test_name=$1
    log_info "Compiling ${test_name} with Vivado xsim..."

    xvlog -sv "${SRC_DIR}/enhanced_pkt_filter.v" \
              "${SCRIPT_DIR}/${test_name}.v" \
              > "${test_name}_compile.log" 2>&1

    if [ $? -ne 0 ]; then
        log_error "Compilation failed for ${test_name}"
        cat "${test_name}_compile.log"
        return 1
    fi

    xelab -debug typical ${test_name} -s ${test_name}_sim \
          >> "${test_name}_compile.log" 2>&1

    if [ $? -ne 0 ]; then
        log_error "Elaboration failed for ${test_name}"
        cat "${test_name}_compile.log"
        return 1
    fi

    log_verbose "Compilation successful"
    return 0
}

compile_test_iverilog() {
    local test_name=$1
    log_info "Compiling ${test_name} with Icarus Verilog..."

    iverilog -g2012 \
             -o "${test_name}_sim" \
             "${SRC_DIR}/enhanced_pkt_filter.v" \
             "${SCRIPT_DIR}/${test_name}.v" \
             > "${test_name}_compile.log" 2>&1

    if [ $? -ne 0 ]; then
        log_error "Compilation failed for ${test_name}"
        cat "${test_name}_compile.log"
        return 1
    fi

    log_verbose "Compilation successful"
    return 0
}

compile_test_modelsim() {
    local test_name=$1
    log_info "Compiling ${test_name} with ModelSim..."

    vlib work > "${test_name}_compile.log" 2>&1
    vlog -sv "${SRC_DIR}/enhanced_pkt_filter.v" \
             "${SCRIPT_DIR}/${test_name}.v" \
             >> "${test_name}_compile.log" 2>&1

    if [ $? -ne 0 ]; then
        log_error "Compilation failed for ${test_name}"
        cat "${test_name}_compile.log"
        return 1
    fi

    log_verbose "Compilation successful"
    return 0
}

run_test_xsim() {
    local test_name=$1
    log_info "Running ${test_name} with xsim..."

    local wave_opts=""
    if [ $GENERATE_WAVES -eq 1 ]; then
        wave_opts="-wdb ${test_name}.wdb"
    fi

    xsim ${test_name}_sim -runall ${wave_opts} \
         > "${test_name}_run.log" 2>&1

    local result=$?
    return $result
}

run_test_iverilog() {
    local test_name=$1
    log_info "Running ${test_name} with vvp..."

    vvp "${test_name}_sim" > "${test_name}_run.log" 2>&1

    local result=$?
    return $result
}

run_test_modelsim() {
    local test_name=$1
    log_info "Running ${test_name} with ModelSim..."

    local wave_opts=""
    if [ $GENERATE_WAVES -eq 1 ]; then
        wave_opts="-do \"log -r /*; run -all; quit\""
    else
        wave_opts="-do \"run -all; quit\""
    fi

    vsim -c ${test_name} ${wave_opts} \
         > "${test_name}_run.log" 2>&1

    local result=$?
    return $result
}

check_test_result() {
    local test_name=$1
    local log_file="${test_name}_run.log"

    # Check if log file exists
    if [ ! -f "$log_file" ]; then
        log_error "Log file not found: $log_file"
        return 1
    fi

    # Extract test statistics
    local total=$(grep "Total tests:" "$log_file" | tail -1 | awk '{print $3}')
    local passed=$(grep "Passed:" "$log_file" | tail -1 | awk '{print $2}')
    local failed=$(grep "Failed:" "$log_file" | tail -1 | awk '{print $2}')

    # Check for "ALL TESTS PASSED" message
    if grep -q "ALL TESTS PASSED" "$log_file" || grep -q "ALL.*PASSED" "$log_file"; then
        return 0
    elif grep -q "SOME TESTS FAILED" "$log_file" || grep -q "FAIL" "$log_file"; then
        return 1
    elif [ ! -z "$total" ] && [ ! -z "$passed" ] && [ ! -z "$failed" ]; then
        if [ "$failed" -eq 0 ] && [ "$passed" -eq "$total" ]; then
            return 0
        else
            return 1
        fi
    else
        # Unable to determine - check for errors
        if grep -qi "error" "$log_file"; then
            return 1
        else
            log_warn "Unable to determine test result for ${test_name}"
            return 2
        fi
    fi
}

run_single_test() {
    local test_name=$1
    local start_time=$(date +%s)

    echo ""
    echo -e "${CYAN}--------------------------------------------------------------------------------${NC}"
    echo -e "${CYAN} Running: ${TEST_DESC[$test_name]}${NC}"
    echo -e "${CYAN}--------------------------------------------------------------------------------${NC}"

    # Compile
    case $SIMULATOR in
        xsim)
            compile_test_xsim "$test_name" || return 1
            ;;
        iverilog)
            compile_test_iverilog "$test_name" || return 1
            ;;
        modelsim)
            compile_test_modelsim "$test_name" || return 1
            ;;
        *)
            log_error "Unknown simulator: $SIMULATOR"
            return 1
            ;;
    esac

    # Run
    case $SIMULATOR in
        xsim)
            run_test_xsim "$test_name"
            ;;
        iverilog)
            run_test_iverilog "$test_name"
            ;;
        modelsim)
            run_test_modelsim "$test_name"
            ;;
    esac

    # Check result
    check_test_result "$test_name"
    local result=$?

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    TESTS_RUN=$((TESTS_RUN + 1))
    TEST_TIMES[$test_name]=$duration

    if [ $result -eq 0 ]; then
        log_success "${test_name} completed successfully (${duration}s)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        TEST_RESULTS[$test_name]="PASS"

        # Show summary
        if [ $VERBOSE -eq 1 ]; then
            echo ""
            tail -20 "${test_name}_run.log"
        fi
    else
        log_error "${test_name} failed (${duration}s)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        TEST_RESULTS[$test_name]="FAIL"

        # Show error details
        echo ""
        log_error "Test output (last 30 lines):"
        tail -30 "${test_name}_run.log"
    fi

    return $result
}

generate_html_report() {
    log_info "Generating HTML report..."

    cat > "$REPORT_FILE" << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Enhanced XPU Integration Test Report</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            margin: 20px;
            background-color: #f5f5f5;
        }
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            border-radius: 10px;
            margin-bottom: 20px;
        }
        h1 {
            margin: 0;
            font-size: 2.5em;
        }
        .summary {
            background-color: white;
            padding: 20px;
            border-radius: 10px;
            margin-bottom: 20px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        .summary-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin-top: 20px;
        }
        .summary-item {
            text-align: center;
            padding: 20px;
            border-radius: 8px;
            background-color: #f8f9fa;
        }
        .summary-item h3 {
            margin: 0 0 10px 0;
            color: #666;
            font-size: 0.9em;
            text-transform: uppercase;
        }
        .summary-item .value {
            font-size: 2.5em;
            font-weight: bold;
            margin: 0;
        }
        .value.pass { color: #28a745; }
        .value.fail { color: #dc3545; }
        .value.total { color: #007bff; }
        table {
            width: 100%;
            border-collapse: collapse;
            background-color: white;
            border-radius: 10px;
            overflow: hidden;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        th {
            background-color: #667eea;
            color: white;
            padding: 15px;
            text-align: left;
        }
        td {
            padding: 12px 15px;
            border-bottom: 1px solid #e0e0e0;
        }
        tr:hover {
            background-color: #f8f9fa;
        }
        .pass {
            color: #28a745;
            font-weight: bold;
        }
        .fail {
            color: #dc3545;
            font-weight: bold;
        }
        .timestamp {
            color: #6c757d;
            font-size: 0.9em;
        }
        .footer {
            margin-top: 30px;
            padding: 20px;
            background-color: white;
            border-radius: 10px;
            text-align: center;
            color: #6c757d;
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>Enhanced XPU Integration Test Report</h1>
        <p>OpenWiFi Hardware - Drone Remote ID & Monitor Mode</p>
    </div>

    <div class="summary">
        <h2>Test Summary</h2>
        <div class="summary-grid">
            <div class="summary-item">
                <h3>Total Tests</h3>
                <p class="value total">__TOTAL__</p>
            </div>
            <div class="summary-item">
                <h3>Passed</h3>
                <p class="value pass">__PASSED__</p>
            </div>
            <div class="summary-item">
                <h3>Failed</h3>
                <p class="value fail">__FAILED__</p>
            </div>
            <div class="summary-item">
                <h3>Success Rate</h3>
                <p class="value">__RATE__%</p>
            </div>
        </div>
    </div>

    <h2>Test Results</h2>
    <table>
        <thead>
            <tr>
                <th>Test Name</th>
                <th>Description</th>
                <th>Result</th>
                <th>Duration</th>
            </tr>
        </thead>
        <tbody>
__RESULTS__
        </tbody>
    </table>

    <div class="footer">
        <p class="timestamp">Report generated: __TIMESTAMP__</p>
        <p>Simulator: __SIMULATOR__ | Build directory: __BUILDDIR__</p>
    </div>
</body>
</html>
EOF

    # Replace placeholders
    local success_rate=0
    if [ $TESTS_RUN -gt 0 ]; then
        success_rate=$(( TESTS_PASSED * 100 / TESTS_RUN ))
    fi

    sed -i "s/__TOTAL__/${TESTS_RUN}/" "$REPORT_FILE"
    sed -i "s/__PASSED__/${TESTS_PASSED}/" "$REPORT_FILE"
    sed -i "s/__FAILED__/${TESTS_FAILED}/" "$REPORT_FILE"
    sed -i "s/__RATE__/${success_rate}/" "$REPORT_FILE"
    sed -i "s/__TIMESTAMP__/$(date)/" "$REPORT_FILE"
    sed -i "s|__SIMULATOR__|${SIMULATOR}|" "$REPORT_FILE"
    sed -i "s|__BUILDDIR__|${BUILD_DIR}|" "$REPORT_FILE"

    # Generate result rows
    local results_html=""
    for test in "${TESTS[@]}"; do
        if [ ! -z "${TEST_RESULTS[$test]}" ]; then
            local result="${TEST_RESULTS[$test]}"
            local duration="${TEST_TIMES[$test]}"
            local desc="${TEST_DESC[$test]}"
            local result_class="pass"
            if [ "$result" == "FAIL" ]; then
                result_class="fail"
            fi

            results_html+="            <tr>\n"
            results_html+="                <td>${test}</td>\n"
            results_html+="                <td>${desc}</td>\n"
            results_html+="                <td class=\"${result_class}\">${result}</td>\n"
            results_html+="                <td>${duration}s</td>\n"
            results_html+="            </tr>\n"
        fi
    done

    # Replace results placeholder (using perl for multi-line)
    perl -i -pe "s/__RESULTS__/${results_html}/s" "$REPORT_FILE" 2>/dev/null || {
        # Fallback if perl not available
        awk -v r="$results_html" '{gsub(/__RESULTS__/,r)}1' "$REPORT_FILE" > "$REPORT_FILE.tmp"
        mv "$REPORT_FILE.tmp" "$REPORT_FILE"
    }

    log_success "HTML report generated: ${REPORT_FILE}"
}

print_summary() {
    echo ""
    echo -e "${CYAN}================================================================================${NC}"
    echo -e "${CYAN} Final Summary${NC}"
    echo -e "${CYAN}================================================================================${NC}"
    echo ""
    echo -e "  Total Tests Run:  ${BLUE}${TESTS_RUN}${NC}"
    echo -e "  Tests Passed:     ${GREEN}${TESTS_PASSED}${NC}"
    echo -e "  Tests Failed:     ${RED}${TESTS_FAILED}${NC}"
    echo ""

    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}  *** ALL TESTS PASSED ***${NC}"
        echo ""
        return 0
    else
        echo -e "${RED}  *** SOME TESTS FAILED ***${NC}"
        echo ""
        echo -e "  Failed tests:"
        for test in "${TESTS[@]}"; do
            if [ "${TEST_RESULTS[$test]}" == "FAIL" ]; then
                echo -e "    ${RED}✗${NC} ${test}"
            fi
        done
        echo ""
        return 1
    fi
}

################################################################################
# Main Script
################################################################################

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--simulator)
            SIMULATOR="$2"
            shift 2
            ;;
        -t|--test)
            SPECIFIC_TEST="$2"
            shift 2
            ;;
        -w|--waveforms)
            GENERATE_WAVES=1
            shift
            ;;
        -h|--html)
            GENERATE_HTML=1
            shift
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -c|--clean)
            CLEAN=1
            shift
            ;;
        --help)
            print_usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# Print banner
print_banner

# Clean if requested
if [ $CLEAN -eq 1 ]; then
    clean_build
fi

# Auto-detect simulator if needed
if [ "$SIMULATOR" == "auto" ]; then
    SIMULATOR=$(detect_simulator)
fi

log_info "Using simulator: ${SIMULATOR}"
log_info "Source directory: ${SRC_DIR}"
log_info "Build directory: ${BUILD_DIR}"

# Setup build directory
setup_build_dir

# Run tests
if [ ! -z "$SPECIFIC_TEST" ]; then
    # Run specific test
    if [[ " ${TESTS[@]} " =~ " ${SPECIFIC_TEST} " ]]; then
        run_single_test "$SPECIFIC_TEST"
    else
        log_error "Unknown test: ${SPECIFIC_TEST}"
        log_info "Available tests: ${TESTS[@]}"
        exit 1
    fi
else
    # Run all tests
    for test in "${TESTS[@]}"; do
        run_single_test "$test"
    done
fi

# Generate HTML report
if [ $GENERATE_HTML -eq 1 ]; then
    generate_html_report
fi

# Print summary
cd "${SCRIPT_DIR}"
print_summary
exit_code=$?

echo -e "${CYAN}================================================================================${NC}"
echo ""

exit $exit_code
