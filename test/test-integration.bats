#!/usr/bin/env bats

# Integration Tests for Docker Plugin
# Tests complete workflows and interactions between components

load test-helpers

@test "integration: complete project initialization workflow" {
    # Setup
    source_lib_functions
    
    # Mock all required commands for initialization
    create_simple_mock "cp" ""
    create_simple_mock "mv" ""
    create_simple_mock "mkdir" ""
    create_simple_mock "nc" "" 1  # Port not in use
    create_simple_mock "find" ""  # Empty directory
    create_simple_mock "git" ""
    
    # Mock input functions
    input() {
        case "$*" in
            *"Project name"*) echo "test-project" ;;
            *"clone url"*) echo "git@github.com:test/repo.git" ;;
            *) echo "default-value" ;;
        esac
    }
    select_php_version() { echo "8.4"; }
    confirm() { echo "y"; }
    export -f input select_php_version confirm
    
    # Create empty project directory
    rm -rf "$PROJECT_DIR"
    mkdir -p "$PROJECT_DIR"
    
    # Test complete initialization
    run parseArguments init
    
    [ "$status" -eq 0 ]
    assert_mock_called "cp"
    assert_mock_called "git"
}

@test "integration: basic JSON config creation workflow" {
    # Setup
    source_lib_functions
    create_test_project

    # Mock date command for JSON timestamps
    create_simple_mock "date" "2023-12-01T12:00:00Z"

    # Test that we can create a basic JSON config file manually
    cat > "$PROJECT_DIR/.deploy.json" << 'EOF'
{
  "version": "1.0",
  "environments": {},
  "environmentOrder": [],
  "defaults": {
    "serviceRoot": "/var/www/html",
    "domainSuffix": ".projects.interligent.com"
  },
  "metadata": {
    "createdAt": "2023-12-01T12:00:00Z",
    "lastModified": "2023-12-01T12:00:00Z",
    "createdBy": "docker-control-plugin"
  }
}
EOF

    [ -f "$PROJECT_DIR/.deploy.json" ]

    # Test that getJsonConfigFile can find it
    config_file=$(getJsonConfigFile "$PROJECT_DIR")
    [ "$config_file" = "$PROJECT_DIR/.deploy.json" ]
}

@test "integration: JSON configuration loading workflow" {
    # Setup
    source_lib_functions
    create_test_project

    # Mock date command for JSON config creation
    create_simple_mock "date" "2023-12-01T12:00:00Z"

    # Create test JSON config manually
    create_test_json_config "$PROJECT_DIR/.deploy.json" "production" "produser" "prod.example.com"

    # Test that we can find and load the configuration
    config_file=$(getJsonConfigFile "$PROJECT_DIR")
    [ "$config_file" = "$PROJECT_DIR/.deploy.json" ]

    # Test loading the configuration
    run loadJsonConfig "$config_file"
    [ "$status" -eq 0 ]

    # Verify the configuration was loaded correctly
    [ -n "${JSON_DEPLOY_ENVS[production]}" ]
    [[ "${JSON_DEPLOY_ENVS[production]}" == *"USER=produser"* ]]
    [[ "${JSON_DEPLOY_ENVS[production]}" == *"DOMAIN=prod.example.com"* ]]
}

@test "integration: Docker container management workflow" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Mock docker commands
    create_simple_mock "docker" "container_id"
    
    # Test start workflow
    run parseArguments start
    [ "$status" -eq 0 ]
    assert_mock_called_with "docker" "compose --project-directory $PROJECT_DIR up -d"
    
    # Reset mock calls log
    echo "# Reset for next test" > "$MOCK_CALLS_LOG"
    
    # Test status workflow
    run parseArguments status
    [ "$status" -eq 0 ]
    assert_mock_called_with "docker" "compose --project-directory $PROJECT_DIR ps"
    
    # Reset mock calls log
    echo "# Reset for next test" > "$MOCK_CALLS_LOG"
    
    # Test stop workflow
    run parseArguments stop
    [ "$status" -eq 0 ]
    assert_mock_called_with "docker" "compose --project-directory $PROJECT_DIR down"
}

@test "integration: console access workflow" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Mock docker commands
    create_simple_mock "docker" ""
    
    # Mock service selection
    select_docker_service() { echo "php"; }
    export -f select_docker_service
    
    # Test console access with default service
    run parseArguments console
    
    [ "$status" -eq 0 ]
    assert_mock_called "docker"
}

@test "integration: help system with custom commands" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Create custom control script
    mkdir -p "$PROJECT_DIR/control-scripts"
    cat > "$PROJECT_DIR/control-scripts/custom-command.sh" << 'EOF'
#!/bin/bash
if [[ "$1" == "_desc_" ]]; then
    echo "Custom command description"
    exit 0
fi
echo "Custom command executed"
EOF
    chmod +x "$PROJECT_DIR/control-scripts/custom-command.sh"
    
    # Test help display
    run _help
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"Custom Commands"* ]]
    [[ "$output" == *"custom-command"* ]]
}

@test "integration: project status display workflow" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Create git repository
    mkdir -p "$PROJECT_DIR/htdocs/.git"
    
    # Mock git commands for status
    create_mock "git" 'case "$3" in
        "branch") echo "main" ;;
        "diff-index") exit 0 ;;  # No changes
        "config") echo "origin" ;;
    esac'
    
    # Mock docker commands
    create_simple_mock "docker" "container1 Up"
    create_simple_mock "wc" "2"
    create_simple_mock "grep" "1"
    
    # Test status display
    run _showProjectStatus
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"Project Status"* ]]
    [[ "$output" == *"Plugin Management"* ]]
    [[ "$output" == *"Git Repository"* ]]
    [[ "$output" == *"Docker Status"* ]]
}

@test "integration: error handling in deployment workflow" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Test deployment without environment parameter
    run _deploy ""
    
    [ "$status" -eq 1 ]
    [[ "$output" == *"Environment parameter missing"* ]]
    
    # Test deployment with non-existent environment
    create_test_json_config "$PROJECT_DIR/.deploy.json" "production" "produser" "prod.example.com"
    
    run _deploy "nonexistent"
    
    [ "$status" -eq 1 ]
    [[ "$output" == *"Environment 'nonexistent' is not configured"* ]]
}

@test "integration: configuration file location precedence" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Create configurations in both locations
    mkdir -p "$PROJECT_DIR/htdocs/.docker-control"
    create_test_json_config "$PROJECT_DIR/.deploy.json" "root-env" "rootuser" "root.example.com"
    create_test_json_config "$PROJECT_DIR/htdocs/.docker-control/.deploy.json" "control-env" "controluser" "control.example.com"
    
    # Test that .docker-control location is preferred
    config_file=$(getJsonConfigFile "$PROJECT_DIR")
    
    [ "$config_file" = "$PROJECT_DIR/htdocs/.docker-control/.deploy.json" ]
    
    # Test loading the preferred configuration
    loadJsonConfig "$config_file"
    
    [ -n "${JSON_DEPLOY_ENVS[control-env]}" ]
    [ -z "${JSON_DEPLOY_ENVS[root-env]}" ]
}

@test "integration: plugin metadata and version handling" {
    # Setup
    source_lib_functions
    export VERSION="1.2.3"
    
    # Test metadata output
    run initializePlugin "docker-cli-plugin-metadata" "$VERSION"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"SchemaVersion"* ]]
    [[ "$output" == *"1.2.3"* ]]
    [[ "$output" == *"Interligent"* ]]
    
    # Test version command
    run parseArguments version
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"1.2.3"* ]]
}

@test "integration: SSH authentication setup" {
    # Setup
    source_lib_functions
    create_simple_mock "socat" ""
    
    # Test SSH auth setup
    export SSH_AUTH_PORT="2222"
    run initializePlugin "test" "1.0.0"
    
    [ "$status" -eq 0 ]
    assert_mock_called "socat"
    [ "$SSH_AUTH_SOCK" = "/tmp/ssh-agent.sock" ]
}

@test "integration: directory validation workflow" {
    # Setup
    source_lib_functions
    
    # Test with unmanaged directory
    mkdir -p "$PROJECT_DIR"
    # Don't create .managed-by-docker-control-plugin file
    
    run checkDir
    
    [ "$status" -eq 1 ]
    [[ "$output" == *"not managed by docker control plugin"* ]]
    
    # Test with managed directory
    touch "$PROJECT_DIR/.managed-by-docker-control-plugin"
    
    run checkDir
    
    [ "$status" -eq 0 ]
}
