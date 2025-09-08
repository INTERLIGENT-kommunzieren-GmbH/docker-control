#!/bin/bash

# Test script for JSON deployment configuration functionality
# This script validates that the JSON configuration system works correctly

set -e

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_ROOT/lib"

# Source required functions
. "$LIB_DIR/util-functions.sh"
. "$LIB_DIR/json-config-functions.sh"

# Test configuration
TEST_DIR="/tmp/docker-control-json-test-$$"
TEST_JSON_FILE="$TEST_DIR/.deploy.json"
TEST_LEGACY_FILE="$TEST_DIR/.deploy.conf"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

function setup_test_env() {
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
}

function cleanup_test_env() {
    cd /
    rm -rf "$TEST_DIR"
}

function run_test() {
    local TEST_NAME="$1"
    local TEST_FUNCTION="$2"
    
    echo "Running test: $TEST_NAME"
    ((TESTS_RUN++))
    
    if $TEST_FUNCTION; then
        echo "✓ PASSED: $TEST_NAME"
        ((TESTS_PASSED++))
    else
        echo "✗ FAILED: $TEST_NAME"
        ((TESTS_FAILED++))
    fi
    echo
}

function test_create_json_config() {
    createJsonConfig "$TEST_JSON_FILE"
    
    # Verify file exists and has valid JSON
    [[ -f "$TEST_JSON_FILE" ]] || return 1
    jq empty "$TEST_JSON_FILE" || return 1
    
    # Verify required fields
    local VERSION
    VERSION=$(jq -r '.version' "$TEST_JSON_FILE")
    [[ "$VERSION" == "1.0" ]] || return 1
    
    # Verify structure
    jq -e '.environments' "$TEST_JSON_FILE" >/dev/null || return 1
    jq -e '.metadata' "$TEST_JSON_FILE" >/dev/null || return 1
    
    return 0
}

function test_add_json_environment() {
    createJsonConfig "$TEST_JSON_FILE"
    
    # Add test environment
    addJsonEnvironment "$TEST_JSON_FILE" "test" "main" "n" "testuser" "test.example.com" "/var/www/html" "Test environment"
    
    # Verify environment was added
    local USER
    USER=$(jq -r '.environments.test.user' "$TEST_JSON_FILE")
    [[ "$USER" == "testuser" ]] || return 1
    
    local DOMAIN
    DOMAIN=$(jq -r '.environments.test.domain' "$TEST_JSON_FILE")
    [[ "$DOMAIN" == "test.example.com" ]] || return 1
    
    # Verify environment is in order
    local ORDER
    ORDER=$(jq -r '.environmentOrder[]' "$TEST_JSON_FILE")
    [[ "$ORDER" == "test" ]] || return 1
    
    return 0
}

function test_validate_json_config() {
    createJsonConfig "$TEST_JSON_FILE"
    addJsonEnvironment "$TEST_JSON_FILE" "test" "main" "n" "testuser" "test.example.com" "/var/www/html" "Test environment"
    
    # Valid configuration should pass
    validateJsonConfig "$TEST_JSON_FILE" || return 1
    
    # Test invalid JSON
    echo "invalid json" > "$TEST_JSON_FILE.invalid"
    ! validateJsonConfig "$TEST_JSON_FILE.invalid" || return 1
    
    # Test missing required fields
    echo '{"version": "1.0"}' > "$TEST_JSON_FILE.missing"
    ! validateJsonConfig "$TEST_JSON_FILE.missing" || return 1
    
    return 0
}

function test_load_json_config() {
    createJsonConfig "$TEST_JSON_FILE"
    addJsonEnvironment "$TEST_JSON_FILE" "test" "main" "n" "testuser" "test.example.com" "/var/www/html" "Test environment"
    
    # Load configuration
    loadJsonConfig "$TEST_JSON_FILE" || return 1
    
    # Verify loaded data
    [[ -n "${JSON_DEPLOY_ENVS[test]}" ]] || return 1
    
    # Verify environment configuration format
    local ENV_CONFIG="${JSON_DEPLOY_ENVS[test]}"
    echo "$ENV_CONFIG" | grep -q "USER=testuser" || return 1
    echo "$ENV_CONFIG" | grep -q "DOMAIN=test.example.com" || return 1
    
    return 0
}

function test_migration_functionality() {
    # Create legacy configuration
    cat > "$TEST_LEGACY_FILE" << 'EOF'
declare -A DEPLOY_ENVS
declare -a DEPLOY_ENVS_ORDER

DEPLOY_ENVS["production"]="BRANCH=env/production ALLOW_BRANCH_DEPLOYMENT=n USER=deploy DOMAIN=production.example.com SERVICE_ROOT=/var/www/html"
DEPLOY_ENVS["staging"]="BRANCH=env/staging ALLOW_BRANCH_DEPLOYMENT=y USER=deploy DOMAIN=staging.example.com SERVICE_ROOT=/var/www/html"
DEPLOY_ENVS_ORDER+=("production")
DEPLOY_ENVS_ORDER+=("staging")
EOF
    
    # Migrate to JSON
    migrateLegacyToJson "$TEST_LEGACY_FILE" "$TEST_JSON_FILE" false || return 1
    
    # Verify migration
    [[ -f "$TEST_JSON_FILE" ]] || return 1
    validateJsonConfig "$TEST_JSON_FILE" || return 1
    
    # Verify environments were migrated
    local PROD_USER
    PROD_USER=$(jq -r '.environments.production.user' "$TEST_JSON_FILE")
    [[ "$PROD_USER" == "deploy" ]] || return 1
    
    local STAGING_ALLOW
    STAGING_ALLOW=$(jq -r '.environments.staging.allowBranchDeployment' "$TEST_JSON_FILE")
    [[ "$STAGING_ALLOW" == "true" ]] || return 1
    
    return 0
}

function test_config_detection() {
    # Test JSON detection
    createJsonConfig "$TEST_JSON_FILE"
    local CONFIG_FILE
    CONFIG_FILE=$(getConfigFile "$TEST_DIR")
    [[ "$CONFIG_FILE" == "$TEST_JSON_FILE" ]] || return 1
    
    # Test legacy detection when no JSON exists
    rm -f "$TEST_JSON_FILE"
    touch "$TEST_LEGACY_FILE"
    CONFIG_FILE=$(getConfigFile "$TEST_DIR")
    [[ "$CONFIG_FILE" == "$TEST_LEGACY_FILE" ]] || return 1
    
    # Test JSON preference over legacy
    createJsonConfig "$TEST_JSON_FILE"
    CONFIG_FILE=$(getConfigFile "$TEST_DIR")
    [[ "$CONFIG_FILE" == "$TEST_JSON_FILE" ]] || return 1
    
    return 0
}

function test_error_handling() {
    # Test invalid user format
    createJsonConfig "$TEST_JSON_FILE"
    ! addJsonEnvironment "$TEST_JSON_FILE" "test" "main" "n" "invalid user!" "test.example.com" "/var/www/html" "Test" || return 1
    
    # Test missing required fields
    ! addJsonEnvironment "$TEST_JSON_FILE" "test" "main" "n" "" "test.example.com" "/var/www/html" "Test" || return 1
    ! addJsonEnvironment "$TEST_JSON_FILE" "test" "main" "n" "user" "" "/var/www/html" "Test" || return 1
    
    return 0
}

function run_all_tests() {
    echo "Starting JSON Configuration Tests"
    echo "================================="
    echo
    
    setup_test_env
    
    run_test "Create JSON Configuration" test_create_json_config
    run_test "Add JSON Environment" test_add_json_environment
    run_test "Validate JSON Configuration" test_validate_json_config
    run_test "Load JSON Configuration" test_load_json_config
    run_test "Migration Functionality" test_migration_functionality
    run_test "Configuration Detection" test_config_detection
    run_test "Error Handling" test_error_handling
    
    cleanup_test_env
    
    echo "Test Results"
    echo "============"
    echo "Tests run: $TESTS_RUN"
    echo "Passed: $TESTS_PASSED"
    echo "Failed: $TESTS_FAILED"
    echo
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo "✓ All tests passed!"
        return 0
    else
        echo "✗ Some tests failed!"
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
