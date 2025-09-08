#!/bin/bash

# Test script to verify JSON configuration loading from different locations

set -e

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_ROOT/lib"

# Source required functions
. "$LIB_DIR/util-functions.sh"
. "$LIB_DIR/json-config-functions.sh"

# Test configuration
TEST_DIR="/tmp/docker-control-location-test-$$"

function setup_test_env() {
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
}

function cleanup_test_env() {
    cd /
    rm -rf "$TEST_DIR"
}

function test_project_root_location() {
    echo "Testing project root location..."
    
    # Create config in project root
    createJsonConfig "$TEST_DIR/.deploy.json"
    addJsonEnvironment "$TEST_DIR/.deploy.json" "test" "main" "n" "testuser" "test.example.com" "/var/www/html" "Test environment"
    
    # Test that getJsonConfigFile finds it
    local CONFIG_FILE
    CONFIG_FILE=$(getJsonConfigFile "$TEST_DIR")
    
    if [[ "$CONFIG_FILE" == "$TEST_DIR/.deploy.json" ]]; then
        echo "✓ Found configuration in project root"
        return 0
    else
        echo "✗ Failed to find configuration in project root"
        return 1
    fi
}

function test_docker_control_location() {
    echo "Testing .docker-control location..."
    
    # Create .docker-control directory structure
    mkdir -p "$TEST_DIR/htdocs/.docker-control"
    
    # Create config in .docker-control directory
    createJsonConfig "$TEST_DIR/htdocs/.docker-control/.deploy.json"
    addJsonEnvironment "$TEST_DIR/htdocs/.docker-control/.deploy.json" "test" "main" "n" "testuser" "test.example.com" "/var/www/html" "Test environment"
    
    # Test that getJsonConfigFile finds it
    local CONFIG_FILE
    CONFIG_FILE=$(getJsonConfigFile "$TEST_DIR")
    
    if [[ "$CONFIG_FILE" == "$TEST_DIR/htdocs/.docker-control/.deploy.json" ]]; then
        echo "✓ Found configuration in .docker-control directory"
        return 0
    else
        echo "✗ Failed to find configuration in .docker-control directory"
        echo "Expected: $TEST_DIR/htdocs/.docker-control/.deploy.json"
        echo "Got: $CONFIG_FILE"
        return 1
    fi
}

function test_preference_order() {
    echo "Testing preference order (.docker-control over project root)..."
    
    # Create both configurations
    mkdir -p "$TEST_DIR/htdocs/.docker-control"
    createJsonConfig "$TEST_DIR/.deploy.json"
    createJsonConfig "$TEST_DIR/htdocs/.docker-control/.deploy.json"
    
    # Add different environments to distinguish them
    addJsonEnvironment "$TEST_DIR/.deploy.json" "root" "main" "n" "rootuser" "root.example.com" "/var/www/html" "Root environment"
    addJsonEnvironment "$TEST_DIR/htdocs/.docker-control/.deploy.json" "control" "main" "n" "controluser" "control.example.com" "/var/www/html" "Control environment"
    
    # Test that getJsonConfigFile prefers .docker-control
    local CONFIG_FILE
    CONFIG_FILE=$(getJsonConfigFile "$TEST_DIR")
    
    if [[ "$CONFIG_FILE" == "$TEST_DIR/htdocs/.docker-control/.deploy.json" ]]; then
        echo "✓ Correctly prefers .docker-control over project root"
        return 0
    else
        echo "✗ Failed to prefer .docker-control over project root"
        echo "Expected: $TEST_DIR/htdocs/.docker-control/.deploy.json"
        echo "Got: $CONFIG_FILE"
        return 1
    fi
}

function test_load_from_both_locations() {
    echo "Testing loading configuration from both locations..."
    
    # Test loading from project root
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
    
    createJsonConfig "$TEST_DIR/.deploy.json"
    addJsonEnvironment "$TEST_DIR/.deploy.json" "test" "main" "n" "testuser" "test.example.com" "/var/www/html" "Test environment"
    
    if loadJsonConfig "$TEST_DIR/.deploy.json" && [[ -n "${JSON_DEPLOY_ENVS[test]}" ]]; then
        echo "✓ Successfully loaded from project root"
    else
        echo "✗ Failed to load from project root"
        return 1
    fi
    
    # Test loading from .docker-control
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR/htdocs/.docker-control"
    cd "$TEST_DIR"
    
    createJsonConfig "$TEST_DIR/htdocs/.docker-control/.deploy.json"
    addJsonEnvironment "$TEST_DIR/htdocs/.docker-control/.deploy.json" "test" "main" "n" "testuser" "test.example.com" "/var/www/html" "Test environment"
    
    if loadJsonConfig "$TEST_DIR/htdocs/.docker-control/.deploy.json" && [[ -n "${JSON_DEPLOY_ENVS[test]}" ]]; then
        echo "✓ Successfully loaded from .docker-control"
        return 0
    else
        echo "✗ Failed to load from .docker-control"
        return 1
    fi
}

function run_all_tests() {
    echo "Testing JSON Configuration Location Support"
    echo "=========================================="
    echo
    
    local TESTS_PASSED=0
    local TESTS_FAILED=0
    
    setup_test_env
    
    if test_project_root_location; then
        ((TESTS_PASSED++))
    else
        ((TESTS_FAILED++))
    fi
    echo
    
    cleanup_test_env
    setup_test_env
    
    if test_docker_control_location; then
        ((TESTS_PASSED++))
    else
        ((TESTS_FAILED++))
    fi
    echo
    
    cleanup_test_env
    setup_test_env
    
    if test_preference_order; then
        ((TESTS_PASSED++))
    else
        ((TESTS_FAILED++))
    fi
    echo
    
    cleanup_test_env
    setup_test_env
    
    if test_load_from_both_locations; then
        ((TESTS_PASSED++))
    else
        ((TESTS_FAILED++))
    fi
    echo
    
    cleanup_test_env
    
    echo "Test Results"
    echo "============"
    echo "Passed: $TESTS_PASSED"
    echo "Failed: $TESTS_FAILED"
    echo
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo "✓ All location tests passed!"
        return 0
    else
        echo "✗ Some location tests failed!"
        return 1
    fi
}

# Check dependencies
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required for JSON configuration tests"
    echo "Please install jq: apt-get install jq (Ubuntu/Debian) or brew install jq (macOS)"
    exit 1
fi

# Run tests
run_all_tests
