#!/usr/bin/env bats

# Simple test to verify the test framework works

load test-helpers

@test "simple: basic test framework functionality" {
    # Test that we can create temporary directories
    [ -d "$TEST_TEMP_DIR" ]
    
    # Test that we can create files
    echo "test content" > "$TEST_TEMP_DIR/test.txt"
    [ -f "$TEST_TEMP_DIR/test.txt" ]
    
    # Test that we can read files
    content=$(cat "$TEST_TEMP_DIR/test.txt")
    [ "$content" = "test content" ]
}

@test "simple: mock system works" {
    # Test creating a simple mock
    create_simple_mock "testcmd" "mocked output"

    # Test calling the mock
    result=$(testcmd "test")
    [ "$result" = "mocked output" ]

    # Test mock logging
    assert_mock_called "testcmd"
}

@test "simple: project structure creation works" {
    # Test creating a test project
    create_test_project "test-project"
    
    # Verify project structure
    [ -d "$PROJECT_DIR" ]
    [ -d "$PROJECT_DIR/htdocs" ]
    [ -f "$PROJECT_DIR/.managed-by-docker-control-plugin" ]
    [ -f "$PROJECT_DIR/.env" ]
}

@test "simple: JSON config creation works" {
    skip_if_no_command jq
    
    # Test creating JSON config
    config_file="$TEST_TEMP_DIR/test.json"
    create_test_json_config "$config_file" "test" "testuser" "test.example.com"
    
    # Verify JSON is valid
    jq empty "$config_file"
    
    # Verify content
    user=$(jq -r '.environments.test.user' "$config_file")
    [ "$user" = "testuser" ]
}
