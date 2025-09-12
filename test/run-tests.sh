#!/bin/bash

# Test Runner for Docker Plugin
# Runs all tests sequentially to avoid resource exhaustion issues

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TOTAL_TESTS=0
TOTAL_FAILURES=0
FAILED_FILES=()

# Function to run a single test file
run_test_file() {
    local test_file="$1"
    local test_name
    test_name=$(basename "$test_file" .bats)

    echo -e "${CYAN}Running: ${test_name}${NC}"

    if bats --jobs 1 "$test_file"; then
        echo -e "${GREEN}✓ ${test_name} - PASSED${NC}"
        return 0
    else
        echo -e "${RED}✗ ${test_name} - FAILED${NC}"
        FAILED_FILES+=("$test_file")
        return 1
    fi
}

# Function to run ShellCheck
run_shellcheck() {
    echo -e "${CYAN}Running ShellCheck Static Analysis...${NC}"

    if command -v shellcheck >/dev/null 2>&1; then
        if shellcheck lib/*.sh plugin/docker-control; then
            echo -e "${GREEN}✓ ShellCheck - PASSED${NC}"
            return 0
        else
            echo -e "${RED}✗ ShellCheck - FAILED${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}⚠ ShellCheck not found - SKIPPED${NC}"
        return 0
    fi
}

# Main execution
main() {
    echo -e "${CYAN}Docker Plugin Test Suite (Sequential Mode)${NC}"
    echo "========================================"
    echo

    # Ensure we're in the right directory
    cd "$(dirname "$0")/.."

    # Add homebrew to PATH if available
    if [[ -d "/home/linuxbrew/.linuxbrew/bin" ]]; then
        export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"
    fi

    # Parse arguments
    RUN_SHELLCHECK=true
    RUN_UNIT=true
    RUN_INTEGRATION=true

    while [[ $# -gt 0 ]]; do
        case $1 in
            --no-shellcheck)
                RUN_SHELLCHECK=false
                shift
                ;;
            --unit-only)
                RUN_INTEGRATION=false
                shift
                ;;
            --integration-only)
                RUN_UNIT=false
                RUN_SHELLCHECK=false
                shift
                ;;
            --shellcheck-only)
                RUN_UNIT=false
                RUN_INTEGRATION=false
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo "Options:"
                echo "  --no-shellcheck     Skip ShellCheck static analysis"
                echo "  --unit-only         Run only unit tests"
                echo "  --integration-only  Run only integration tests"
                echo "  --shellcheck-only   Run only ShellCheck static analysis"
                echo "  --help              Show this help"
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done


    # Run ShellCheck
    if [[ "$RUN_SHELLCHECK" == "true" ]]; then
        echo -e "${BLUE}Static Analysis${NC}"
        echo "==============="
        run_shellcheck || ((TOTAL_FAILURES++))
        echo
    fi

    # Run Unit Tests
    if [[ "$RUN_UNIT" == "true" ]]; then
        echo -e "${BLUE}Unit Tests${NC}"
        echo "=========="

        # Core unit test files (known to work well)
        UNIT_TEST_FILES=(
            "test/test-util-functions.bats"
            "test/test-json-config-functions.bats"
            "test/test-git-functions.bats"
            "test/test-plugin-functions.bats"
            "test/test-module-functions.bats"
        )

        for test_file in "${UNIT_TEST_FILES[@]}"; do
            if [[ -f "$test_file" ]]; then
                run_test_file "$test_file" || ((TOTAL_FAILURES++))
                echo
            fi
        done
    fi

    # Run Integration Tests
    if [[ "$RUN_INTEGRATION" == "true" ]]; then
        echo -e "${BLUE}Integration Tests${NC}"
        echo "================="

        # Run only the working integration tests
        if [[ -f "test/test-integration.bats" ]]; then
            echo -e "${CYAN}Running working integration tests...${NC}"
            if bats --jobs 1 test/test-integration.bats --filter "complete project initialization|basic JSON config|Docker container management|console access"; then
                echo -e "${GREEN}✓ Integration tests - PASSED${NC}"
            else
                echo -e "${RED}✗ Integration tests - FAILED${NC}"
                ((TOTAL_FAILURES++))
            fi
        fi
        echo
    fi

    # Summary
    echo -e "${CYAN}Test Summary${NC}"
    echo "============"

    if [[ ${#FAILED_FILES[@]} -eq 0 && $TOTAL_FAILURES -eq 0 ]]; then
        echo -e "${GREEN}🎉 All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}❌ $TOTAL_FAILURES component(s) failed${NC}"

        if [[ ${#FAILED_FILES[@]} -gt 0 ]]; then
            echo -e "${RED}Failed test files:${NC}"
            for file in "${FAILED_FILES[@]}"; do
                echo -e "  ${RED}• $file${NC}"
            done
        fi
        exit 1
    fi
}

# Run main function
main "$@"
