#!/bin/bash

# Enhanced Test Framework for Docker Plugin
# Provides comprehensive utilities for testing shell scripts

set -e

# Test framework variables
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_TEST=""
TEST_OUTPUT_DIR=""
VERBOSE=${VERBOSE:-0}
MOCK_CALLS_LOG=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Test framework functions
function test_framework_init() {
    local TEST_NAME="$1"
    TEST_OUTPUT_DIR="/tmp/docker-plugin-tests-$$"
    mkdir -p "$TEST_OUTPUT_DIR"
    MOCK_CALLS_LOG="$TEST_OUTPUT_DIR/mock_calls.log"

    # Add Homebrew to PATH for tools like bats, shellcheck, etc.
    export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"

    echo -e "${BLUE}Starting Test Suite: $TEST_NAME${NC}"
    echo "========================================"
    echo
}

function test_framework_cleanup() {
    if [[ -n "$TEST_OUTPUT_DIR" && -d "$TEST_OUTPUT_DIR" ]]; then
        rm -rf "$TEST_OUTPUT_DIR"
    fi
}

function run_test() {
    local TEST_NAME="$1"
    local TEST_FUNCTION="$2"
    
    CURRENT_TEST="$TEST_NAME"
    ((TESTS_RUN++))
    
    if [[ $VERBOSE -eq 1 ]]; then
        echo -e "${BLUE}Running test: $TEST_NAME${NC}"
    fi
    
    # Create isolated test environment
    local TEST_DIR="$TEST_OUTPUT_DIR/test-$TESTS_RUN"
    mkdir -p "$TEST_DIR"
    
    # Run test in subshell to isolate environment
    if (
        cd "$TEST_DIR"
        export TEST_DIR
        export TEST_NAME
        $TEST_FUNCTION
    ); then
        echo -e "${GREEN}✓ PASSED: $TEST_NAME${NC}"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${RED}✗ FAILED: $TEST_NAME${NC}"
        ((TESTS_FAILED++))
        return 1
    fi
}

function assert_equals() {
    local EXPECTED="$1"
    local ACTUAL="$2"
    local MESSAGE="${3:-Values should be equal}"
    
    if [[ "$EXPECTED" == "$ACTUAL" ]]; then
        return 0
    else
        echo -e "${RED}Assertion failed: $MESSAGE${NC}"
        echo -e "${RED}Expected: '$EXPECTED'${NC}"
        echo -e "${RED}Actual:   '$ACTUAL'${NC}"
        return 1
    fi
}

function assert_not_equals() {
    local NOT_EXPECTED="$1"
    local ACTUAL="$2"
    local MESSAGE="${3:-Values should not be equal}"
    
    if [[ "$NOT_EXPECTED" != "$ACTUAL" ]]; then
        return 0
    else
        echo -e "${RED}Assertion failed: $MESSAGE${NC}"
        echo -e "${RED}Not expected: '$NOT_EXPECTED'${NC}"
        echo -e "${RED}Actual:       '$ACTUAL'${NC}"
        return 1
    fi
}

function assert_contains() {
    local HAYSTACK="$1"
    local NEEDLE="$2"
    local MESSAGE="${3:-String should contain substring}"
    
    if [[ "$HAYSTACK" == *"$NEEDLE"* ]]; then
        return 0
    else
        echo -e "${RED}Assertion failed: $MESSAGE${NC}"
        echo -e "${RED}String: '$HAYSTACK'${NC}"
        echo -e "${RED}Should contain: '$NEEDLE'${NC}"
        return 1
    fi
}

function assert_file_exists() {
    local FILE_PATH="$1"
    local MESSAGE="${2:-File should exist}"
    
    if [[ -f "$FILE_PATH" ]]; then
        return 0
    else
        echo -e "${RED}Assertion failed: $MESSAGE${NC}"
        echo -e "${RED}File does not exist: '$FILE_PATH'${NC}"
        return 1
    fi
}

function assert_file_not_exists() {
    local FILE_PATH="$1"
    local MESSAGE="${2:-File should not exist}"
    
    if [[ ! -f "$FILE_PATH" ]]; then
        return 0
    else
        echo -e "${RED}Assertion failed: $MESSAGE${NC}"
        echo -e "${RED}File exists: '$FILE_PATH'${NC}"
        return 1
    fi
}

function assert_directory_exists() {
    local DIR_PATH="$1"
    local MESSAGE="${2:-Directory should exist}"
    
    if [[ -d "$DIR_PATH" ]]; then
        return 0
    else
        echo -e "${RED}Assertion failed: $MESSAGE${NC}"
        echo -e "${RED}Directory does not exist: '$DIR_PATH'${NC}"
        return 1
    fi
}

function assert_command_success() {
    local COMMAND="$1"
    local MESSAGE="${2:-Command should succeed}"
    
    if eval "$COMMAND" >/dev/null 2>&1; then
        return 0
    else
        echo -e "${RED}Assertion failed: $MESSAGE${NC}"
        echo -e "${RED}Command failed: '$COMMAND'${NC}"
        return 1
    fi
}

function assert_command_failure() {
    local COMMAND="$1"
    local MESSAGE="${2:-Command should fail}"
    
    if ! eval "$COMMAND" >/dev/null 2>&1; then
        return 0
    else
        echo -e "${RED}Assertion failed: $MESSAGE${NC}"
        echo -e "${RED}Command succeeded when it should have failed: '$COMMAND'${NC}"
        return 1
    fi
}

function assert_exit_code() {
    local EXPECTED_CODE="$1"
    local COMMAND="$2"
    local MESSAGE="${3:-Command should exit with expected code}"
    
    local ACTUAL_CODE
    eval "$COMMAND" >/dev/null 2>&1
    ACTUAL_CODE=$?
    
    if [[ $ACTUAL_CODE -eq $EXPECTED_CODE ]]; then
        return 0
    else
        echo -e "${RED}Assertion failed: $MESSAGE${NC}"
        echo -e "${RED}Expected exit code: $EXPECTED_CODE${NC}"
        echo -e "${RED}Actual exit code:   $ACTUAL_CODE${NC}"
        return 1
    fi
}

function mock_command() {
    local COMMAND_NAME="$1"
    local MOCK_BEHAVIOR="$2"
    local MOCK_DIR="$TEST_DIR/mocks"
    
    mkdir -p "$MOCK_DIR"
    
    cat > "$MOCK_DIR/$COMMAND_NAME" << EOF
#!/bin/bash
$MOCK_BEHAVIOR
EOF
    
    chmod +x "$MOCK_DIR/$COMMAND_NAME"
    export PATH="$MOCK_DIR:$PATH"
}

function capture_output() {
    local COMMAND="$1"
    local OUTPUT_FILE="$TEST_DIR/command_output"
    
    eval "$COMMAND" > "$OUTPUT_FILE" 2>&1
    echo "$OUTPUT_FILE"
}

function test_framework_summary() {
    echo
    echo "========================================"
    echo -e "${BLUE}Test Results Summary${NC}"
    echo "========================================"
    echo -e "Total tests run: ${BLUE}$TESTS_RUN${NC}"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
    echo
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}✓ All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}✗ Some tests failed!${NC}"
        return 1
    fi
}

# Trap to ensure cleanup on exit
trap test_framework_cleanup EXIT
