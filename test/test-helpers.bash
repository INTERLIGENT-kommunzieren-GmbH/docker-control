#!/bin/bash

# Test Helpers for Docker Plugin Tests
# Provides common setup, teardown, and utility functions for bats tests

# Add Homebrew to PATH for tools like bats, shellcheck, etc.
export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"

# Get the directory of this script and project root
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$TEST_DIR")"
LIB_DIR="$PROJECT_ROOT/lib"

# Test environment variables
export TEST_TEMP_DIR=""
export MOCK_CALLS_LOG=""
export ORIGINAL_PATH="$PATH"

# Setup function called before each test
setup() {
    # Create temporary directory for test
    TEST_TEMP_DIR="$(mktemp -d)"
    MOCK_CALLS_LOG="$TEST_TEMP_DIR/mock_calls.log"
    
    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/mocks"
    mkdir -p "$TEST_TEMP_DIR/project"
    mkdir -p "$TEST_TEMP_DIR/project/htdocs"
    
    # Set up test project directory
    export PROJECT_DIR="$TEST_TEMP_DIR/project"
    export TEMPLATE_DIR="$PROJECT_ROOT/template"
    export INGRESS_COMPOSE_DIR="$PROJECT_ROOT/ingress"
    export INGRESS_COMPOSE_FILE="$PROJECT_ROOT/ingress/compose.yml"
    
    # Add mocks to PATH
    export PATH="$TEST_TEMP_DIR/mocks:$ORIGINAL_PATH"
    
    # Initialize mock calls log
    echo "# Mock calls log for test: $BATS_TEST_DESCRIPTION" > "$MOCK_CALLS_LOG"
}

# Teardown function called after each test
teardown() {
    # Clean up temporary directory
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
    
    # Restore original PATH
    export PATH="$ORIGINAL_PATH"
}

# Mock command creation function
create_mock() {
    local command_name="$1"
    local mock_behavior="$2"
    local exit_code="${3:-0}"
    
    cat > "$TEST_TEMP_DIR/mocks/$command_name" << EOF
#!/bin/bash
# Mock for $command_name
echo "\$(date '+%Y-%m-%d %H:%M:%S') $command_name \$*" >> "$MOCK_CALLS_LOG"
$mock_behavior
exit $exit_code
EOF
    chmod +x "$TEST_TEMP_DIR/mocks/$command_name"
}

# Create a simple mock that just logs calls
create_simple_mock() {
    local command_name="$1"
    local output="${2:-}"
    local exit_code="${3:-0}"
    
    create_mock "$command_name" "echo '$output'" "$exit_code"
}

# Create a mock that fails
create_failing_mock() {
    local command_name="$1"
    local error_message="${2:-Command failed}"
    
    create_mock "$command_name" "echo '$error_message' >&2" "1"
}

# Check if a command was called with specific arguments
assert_mock_called_with() {
    local command_name="$1"
    local expected_args="$2"
    
    if grep -q "$command_name $expected_args" "$MOCK_CALLS_LOG"; then
        return 0
    else
        echo "Expected mock call not found: $command_name $expected_args"
        echo "Mock calls log:"
        cat "$MOCK_CALLS_LOG"
        return 1
    fi
}

# Check if a command was called (with any arguments)
assert_mock_called() {
    local command_name="$1"
    
    if grep -q "$command_name" "$MOCK_CALLS_LOG"; then
        return 0
    else
        echo "Expected mock call not found: $command_name"
        echo "Mock calls log:"
        cat "$MOCK_CALLS_LOG"
        return 1
    fi
}

# Create a test project structure
create_test_project() {
    local project_name="${1:-test-project}"
    
    # Create basic project structure
    mkdir -p "$PROJECT_DIR/htdocs"
    mkdir -p "$PROJECT_DIR/logs"
    mkdir -p "$PROJECT_DIR/volumes"
    
    # Create the managed-by-docker-control-plugin marker
    touch "$PROJECT_DIR/.managed-by-docker-control-plugin"
    
    # Create basic .env file
    cat > "$PROJECT_DIR/.env" << EOF
BASE_DOMAIN=$project_name.lvh.me
ENVIRONMENT=development
DB_HOST_PORT=33060
PHP_VERSION=8.1
PROJECTNAME=$project_name
XDEBUG_IP=host.docker.internal
IDE_KEY=$project_name.lvh.me
EOF
}

# Create test JSON configuration
create_test_json_config() {
    local config_file="$1"
    local env_name="${2:-test}"
    local user="${3:-testuser}"
    local domain="${4:-test.example.com}"
    
    cat > "$config_file" << EOF
{
  "version": "1.0",
  "environments": {
    "$env_name": {
      "branch": "main",
      "user": "$user",
      "domain": "$domain",
      "serviceRoot": "/var/www/html",
      "description": "Test environment"
    }
  },
  "environmentOrder": ["$env_name"],
  "defaults": {
    "serviceRoot": "/var/www/html",
    "domainSuffix": ".projects.interligent.com"
  },
  "metadata": {
    "createdAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "lastModified": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "createdBy": "docker-control-plugin"
  }
}
EOF
}

# Check if a command was NOT called
assert_mock_not_called() {
    local command_name="$1"

    if ! grep -q "$command_name" "$MOCK_CALLS_LOG"; then
        return 0
    else
        echo "Unexpected mock call found: $command_name"
        echo "Mock calls log:"
        cat "$MOCK_CALLS_LOG"
        return 1
    fi
}

# Skip test if dependency is not available
skip_if_no_command() {
    local command="$1"
    if ! command -v "$command" >/dev/null 2>&1; then
        skip "$command is not available"
    fi
}

# Helper to capture command output
capture_output() {
    local output_file="$TEST_TEMP_DIR/command_output"
    "$@" > "$output_file" 2>&1
    cat "$output_file"
}

# Helper to run command and capture both output and exit code
run_and_capture() {
    local output_file="$TEST_TEMP_DIR/command_output"
    local exit_code_file="$TEST_TEMP_DIR/exit_code"

    "$@" > "$output_file" 2>&1
    echo $? > "$exit_code_file"

    export captured_output
    captured_output="$(cat "$output_file")"
    export captured_exit_code
    captured_exit_code="$(cat "$exit_code_file")"
}

# Source required library functions for testing
# Create a sophisticated gum mock that handles text output
create_gum_mock() {
    cat > "$TEST_TEMP_DIR/mocks/gum" << 'EOF'
#!/bin/bash
# Sophisticated gum mock for testing

# Log the call
echo "$(date '+%Y-%m-%d %H:%M:%S') gum $*" >> "$MOCK_CALLS_LOG"

# Handle different gum commands
case "$1" in
    style)
        # For style commands, output the text content
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --foreground|--background|--bold|--italic|--underline|--strikethrough|--faint)
                    shift 2  # Skip flag and its value
                    ;;
                --*)
                    shift    # Skip other flags
                    ;;
                *)
                    echo "$1"  # Output the text
                    shift
                    ;;
            esac
        done
        ;;
    input)
        # For input commands, return a default value
        if [[ "$*" == *"Project name"* ]]; then
            echo "test-project"
        else
            echo "default-value"
        fi
        ;;
    confirm)
        # For confirm commands, return 'y' by default
        echo "y"
        ;;
    choose)
        # For choose commands, return the first option
        shift
        while [[ $# -gt 0 ]]; do
            if [[ "$1" != --* ]]; then
                echo "$1"
                break
            fi
            shift
        done
        ;;
    *)
        # For other commands, just echo the arguments
        echo "$*"
        ;;
esac
EOF
    chmod +x "$TEST_TEMP_DIR/mocks/gum"
}

source_lib_functions() {
    # Create sophisticated gum mock
    create_gum_mock
    export GUM_EXECUTABLE="$TEST_TEMP_DIR/mocks/gum"

    # Source the library functions
    source "$LIB_DIR/util-functions.sh"
    source "$LIB_DIR/json-config-functions.sh"
    source "$LIB_DIR/git-functions.sh"
    source "$LIB_DIR/deploy-functions.sh"
    source "$LIB_DIR/plugin-functions.sh"
}
