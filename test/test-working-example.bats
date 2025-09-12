#!/usr/bin/env bats

# Working example tests to demonstrate the test framework

load test-helpers

@test "working: test framework setup works" {
    # Verify test environment
    [ -d "$TEST_TEMP_DIR" ]
    [ -d "$LIB_DIR" ]
    [ -f "$LIB_DIR/util-functions.sh" ]
}

@test "working: mock system creates executable files" {
    # Create a mock command
    create_simple_mock "testcmd" "test output"
    
    # Verify mock file exists and is executable
    [ -f "$TEST_TEMP_DIR/mocks/testcmd" ]
    [ -x "$TEST_TEMP_DIR/mocks/testcmd" ]
    
    # Test mock execution
    result=$(testcmd)
    [ "$result" = "test output" ]
}

@test "working: mock logging works" {
    # Create and call a mock
    create_simple_mock "logtest" "output"
    logtest arg1 arg2
    
    # Verify mock was called
    assert_mock_called "logtest"
    assert_mock_called_with "logtest" "arg1 arg2"
}

@test "working: project creation works" {
    # Create test project
    create_test_project "test-project"
    
    # Verify project structure
    [ -d "$PROJECT_DIR" ]
    [ -d "$PROJECT_DIR/htdocs" ]
    [ -f "$PROJECT_DIR/.managed-by-docker-control-plugin" ]
    [ -f "$PROJECT_DIR/.env" ]
    
    # Verify .env content
    grep -q "PROJECTNAME=test-project" "$PROJECT_DIR/.env"
}

@test "working: JSON config creation works" {
    skip_if_no_command jq
    
    # Create JSON config
    config_file="$TEST_TEMP_DIR/config.json"
    create_test_json_config "$config_file" "test" "testuser" "test.example.com"
    
    # Verify JSON is valid
    jq empty "$config_file"
    
    # Verify specific content
    user=$(jq -r '.environments.test.user' "$config_file")
    [ "$user" = "testuser" ]
    
    domain=$(jq -r '.environments.test.domain' "$config_file")
    [ "$domain" = "test.example.com" ]
}

@test "working: library functions can be sourced" {
    # Mock external dependencies
    create_simple_mock "gum" ""
    export GUM_EXECUTABLE="$TEST_TEMP_DIR/mocks/gum"
    
    # Source library functions
    source "$LIB_DIR/util-functions.sh"
    source "$LIB_DIR/json-config-functions.sh"
    
    # Verify functions are available
    type -t text >/dev/null
    type -t validateJsonConfig >/dev/null
}

@test "working: text function works with mocked gum" {
    # Setup mocks
    create_simple_mock "gum" "styled text"
    export GUM_EXECUTABLE="$TEST_TEMP_DIR/mocks/gum"
    
    # Source functions
    source "$LIB_DIR/util-functions.sh"
    
    # Test text function
    run text "hello world"
    [ "$status" -eq 0 ]
    assert_mock_called "gum"
}

@test "working: file operations work in test environment" {
    # Create test file
    test_file="$TEST_TEMP_DIR/test.txt"
    echo "test content" > "$test_file"
    
    # Verify file operations
    [ -f "$test_file" ]
    content=$(cat "$test_file")
    [ "$content" = "test content" ]
    
    # Test file modification
    echo "modified" >> "$test_file"
    lines=$(wc -l < "$test_file")
    [ "$lines" -eq 2 ]
}

@test "working: environment variables work" {
    # Set test environment variable
    export TEST_VAR="test_value"
    
    # Verify it's accessible
    [ "$TEST_VAR" = "test_value" ]
    
    # Test in subshell
    result=$(echo "$TEST_VAR")
    [ "$result" = "test_value" ]
}
