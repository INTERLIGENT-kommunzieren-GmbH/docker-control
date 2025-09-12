#!/usr/bin/env bats

# Tests for lib/util-functions.sh

load test-helpers

@test "util-functions: _initUtils should find gum executable" {
    # Create a mock gum executable
    create_simple_mock "gum" "mock gum output"

    # Mock which command to return the path to our mock gum
    create_mock "which" 'echo "$TEST_TEMP_DIR/mocks/gum"' 0

    # Source util-functions
    source "$LIB_DIR/util-functions.sh"

    # Test _initUtils (don't use run since we need to check the variable)
    _initUtils

    # Check that GUM_EXECUTABLE was set correctly
    [ -n "$GUM_EXECUTABLE" ]
    [ "$GUM_EXECUTABLE" = "$TEST_TEMP_DIR/mocks/gum" ]
    assert_mock_called "which"
}

@test "util-functions: _initUtils should fail when gum is not found" {
    # Mock which to return empty string when gum is not found
    create_mock "which" 'echo ""' 1

    # Source util-functions
    source "$LIB_DIR/util-functions.sh"

    # Test _initUtils should fail - it will fail because critical calls text which calls empty GUM_EXECUTABLE
    run _initUtils

    # The function should fail (non-zero exit code) and call which
    [ "$status" -ne 0 ]
    assert_mock_called "which"
}

@test "util-functions: choose should call gum with correct parameters" {
    # Setup
    create_simple_mock "gum" "Option 1"
    export GUM_EXECUTABLE="$TEST_TEMP_DIR/mocks/gum"
    source "$LIB_DIR/util-functions.sh"

    # Create test options
    declare -A test_options=( ["Option 1"]="value1" ["Option 2"]="value2" )
    declare -a test_order=( "Option 1" "Option 2" )

    # Test choose function
    run choose "Test Header" test_options test_order
    
    [ "$status" -eq 0 ]
    assert_mock_called "gum"
}

@test "util-functions: confirm should return 'y' for positive confirmation" {
    # Setup mock gum that returns success (0) for confirm command
    create_mock "gum" '
        case "$1" in
            "confirm") exit 0 ;;  # Simulate user confirming
            *) echo "mock gum" ;;
        esac
    ' 0

    # Set GUM_EXECUTABLE directly to avoid _initUtils complexity
    export GUM_EXECUTABLE="$TEST_TEMP_DIR/mocks/gum"
    source "$LIB_DIR/util-functions.sh"

    # Test confirm function
    run confirm "Test question?"

    [ "$status" -eq 0 ]
    [ "$output" = "y" ]
    assert_mock_called "gum"
}

@test "util-functions: confirm should return 'n' for negative confirmation" {
    # Setup mock gum that returns failure (1) for confirm command
    create_mock "gum" '
        case "$1" in
            "confirm") exit 1 ;;  # Simulate user declining
            *) echo "mock gum" ;;
        esac
    ' 1

    # Set GUM_EXECUTABLE directly to avoid _initUtils complexity
    export GUM_EXECUTABLE="$TEST_TEMP_DIR/mocks/gum"
    source "$LIB_DIR/util-functions.sh"

    # Test confirm function
    run confirm "Test question?"

    [ "$status" -eq 0 ]
    [ "$output" = "n" ]
    assert_mock_called "gum"
}

@test "util-functions: confirm should handle -n flag for default false" {
    # Setup mock gum that returns failure (1) for confirm command
    create_mock "gum" '
        case "$1" in
            "confirm")
                # Check if --default=false is passed
                if [[ "$*" == *"--default=false"* ]]; then
                    exit 1  # Simulate default false behavior
                else
                    exit 0
                fi
                ;;
            *) echo "mock gum" ;;
        esac
    ' 1

    # Set GUM_EXECUTABLE directly to avoid _initUtils complexity
    export GUM_EXECUTABLE="$TEST_TEMP_DIR/mocks/gum"
    source "$LIB_DIR/util-functions.sh"

    # Test confirm function with -n flag
    run confirm -n "Test question?"

    [ "$status" -eq 0 ]
    [ "$output" = "n" ]
    assert_mock_called "gum"
}

@test "util-functions: critical should call text with red foreground" {
    # Setup
    create_simple_mock "gum" ""
    export GUM_EXECUTABLE="$TEST_TEMP_DIR/mocks/gum"
    source "$LIB_DIR/util-functions.sh"

    # Test critical function
    run critical "Test error message"

    [ "$status" -eq 0 ]
    assert_mock_called "gum"
}

@test "util-functions: info should call text with blue foreground" {
    # Setup
    create_simple_mock "gum" ""
    export GUM_EXECUTABLE="$TEST_TEMP_DIR/mocks/gum"
    source "$LIB_DIR/util-functions.sh"

    # Test info function
    run info "Test info message"

    [ "$status" -eq 0 ]
    assert_mock_called "gum"
}

@test "util-functions: warning should call text with yellow foreground" {
    # Setup
    create_simple_mock "gum" ""
    export GUM_EXECUTABLE="$TEST_TEMP_DIR/mocks/gum"
    source "$LIB_DIR/util-functions.sh"

    # Test warning function
    run warning "Test warning message"

    [ "$status" -eq 0 ]
    assert_mock_called "gum"
}

@test "util-functions: headline should create styled header" {
    # Setup
    create_simple_mock "gum" ""
    export GUM_EXECUTABLE="$TEST_TEMP_DIR/mocks/gum"
    source "$LIB_DIR/util-functions.sh"

    # Test headline function
    run headline "Test Headline"

    [ "$status" -eq 0 ]
    assert_mock_called "gum"
}

@test "util-functions: sub_headline should create styled subheader" {
    # Setup
    create_simple_mock "gum" ""
    export GUM_EXECUTABLE="$TEST_TEMP_DIR/mocks/gum"
    source "$LIB_DIR/util-functions.sh"

    # Test sub_headline function
    run sub_headline "Test Sub Headline"

    [ "$status" -eq 0 ]
    assert_mock_called "gum"
}

@test "util-functions: text should handle basic text output" {
    # Setup
    create_simple_mock "gum" "test output"
    export GUM_EXECUTABLE="$TEST_TEMP_DIR/mocks/gum"
    source "$LIB_DIR/util-functions.sh"

    # Test text function
    run text "Test message"

    [ "$status" -eq 0 ]
    assert_mock_called "gum"
}

@test "util-functions: text should handle foreground color flag" {
    # Setup
    create_simple_mock "gum" "colored output"
    export GUM_EXECUTABLE="$TEST_TEMP_DIR/mocks/gum"
    source "$LIB_DIR/util-functions.sh"

    # Test text function with color
    run text -f 12 "Blue text"

    [ "$status" -eq 0 ]
    assert_mock_called "gum"
}

@test "util-functions: input should prompt for user input" {
    # Setup
    create_simple_mock "gum" "user input"
    export GUM_EXECUTABLE="$TEST_TEMP_DIR/mocks/gum"
    source "$LIB_DIR/util-functions.sh"

    # Test input function
    run input -l "test label" -r TEST_VAR

    [ "$status" -eq 0 ]
    assert_mock_called "gum"
}

@test "util-functions: input should handle default values" {
    # Setup
    create_simple_mock "gum" ""  # Empty input to trigger default
    export GUM_EXECUTABLE="$TEST_TEMP_DIR/mocks/gum"
    source "$LIB_DIR/util-functions.sh"

    # Test input function with default
    run input -l "test label" -d "default value" -r TEST_VAR

    [ "$status" -eq 0 ]
    assert_mock_called "gum"
}

@test "util-functions: newline should output empty line" {
    # Setup
    source "$LIB_DIR/util-functions.sh"
    
    # Test newline function
    run newline
    
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "util-functions: wait_for_keypress should call gum input" {
    # Setup
    create_simple_mock "gum" ""
    export GUM_EXECUTABLE="$TEST_TEMP_DIR/mocks/gum"
    source "$LIB_DIR/util-functions.sh"

    # Test wait_for_keypress function
    run wait_for_keypress

    [ "$status" -eq 0 ]
    assert_mock_called "gum"
}

@test "util-functions: fatal should call critical and exit" {
    # Setup mocks
    create_simple_mock "gum" ""

    # Mock critical function to capture its call
    create_mock "critical" 'echo "CRITICAL: $1"' 0

    # Mock exit to prevent actual process termination
    create_mock "exit" 'echo "EXIT: $1"; return $1' 0

    # Set GUM_EXECUTABLE directly
    export GUM_EXECUTABLE="$TEST_TEMP_DIR/mocks/gum"
    source "$LIB_DIR/util-functions.sh"

    # Test fatal function (should call critical and exit)
    run fatal "Fatal error message"

    [ "$status" -eq 1 ]
    assert_mock_called "critical"
    assert_mock_called "exit"
}
