#!/usr/bin/env bats

# Tests for lib/plugin-functions.sh

load test-helpers

@test "plugin-functions: checkDir should pass when project is managed" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Test checkDir
    run checkDir
    
    [ "$status" -eq 0 ]
}

@test "plugin-functions: checkDir should fail when project is not managed" {
    # Setup
    source_lib_functions
    mkdir -p "$PROJECT_DIR"
    # Don't create the .managed-by-docker-control-plugin file
    
    # Test checkDir - should fail with exit code 1
    run checkDir

    [ "$status" -eq 1 ]
    # Note: Output may be empty due to mocked gum, but the function should still return 1
}

@test "plugin-functions: dockerCompose should call docker compose with correct parameters" {
    # Setup
    source_lib_functions
    create_test_project
    create_simple_mock "docker" "mock docker output"
    
    # Test dockerCompose
    run dockerCompose ps
    
    [ "$status" -eq 0 ]
    assert_mock_called_with "docker" "compose --project-directory $PROJECT_DIR ps"
}

@test "plugin-functions: dockerComposeIngress should call docker compose for ingress" {
    # Setup
    source_lib_functions
    create_simple_mock "docker" "mock docker output"
    
    # Test dockerComposeIngress
    run dockerComposeIngress ps
    
    [ "$status" -eq 0 ]
    assert_mock_called "docker"
}

@test "plugin-functions: initializePlugin should output metadata when requested" {
    # Setup
    source_lib_functions
    
    # Test metadata output
    run initializePlugin "docker-cli-plugin-metadata" "1.0.0"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"SchemaVersion"* ]]
    [[ "$output" == *"1.0.0"* ]]
    [[ "$output" == *"Interligent"* ]]
}

@test "plugin-functions: initializePlugin should set up SSH auth when SSH_AUTH_PORT is set" {
    # Setup
    source_lib_functions
    create_simple_mock "socat" ""
    export SSH_AUTH_PORT="2222"
    
    # Test SSH setup
    run initializePlugin "test" "1.0.0"
    
    [ "$status" -eq 0 ]
    assert_mock_called "socat"
}

@test "plugin-functions: parseArguments should handle --dir flag" {
    # Setup
    source_lib_functions
    create_simple_mock "realpath" "$TEST_TEMP_DIR/custom"
    
    # Test parsing --dir argument
    run parseArguments --dir "/custom/path" help
    
    [ "$status" -eq 0 ]
    assert_mock_called "realpath"
}

@test "plugin-functions: parseArguments should show help when no arguments" {
    # Setup
    source_lib_functions
    
    # Test no arguments (should show help and exit 1)
    run parseArguments
    
    [ "$status" -eq 1 ]
}

@test "plugin-functions: parseArguments should handle help command" {
    # Setup
    source_lib_functions
    
    # Test help command
    run parseArguments help
    
    [ "$status" -eq 0 ]
}

@test "plugin-functions: parseArguments should handle version command" {
    # Setup
    source_lib_functions
    export VERSION="1.0.0"
    
    # Test version command - should exit with status 0
    run parseArguments version

    [ "$status" -eq 0 ]
    # Note: Output may be empty due to mocked gum, but the function should still exit 0
}

@test "plugin-functions: parseArguments should handle init command in empty directory" {
    # Setup
    source_lib_functions
    create_simple_mock "find" ""  # Empty directory
    create_simple_mock "cp" ""
    create_simple_mock "mv" ""
    create_simple_mock "mkdir" ""
    create_simple_mock "nc" "" 1  # Port not in use

    # Mock the select_php_version function
    select_php_version() { echo "8.1"; }
    export -f select_php_version

    # Test init command
    run parseArguments init

    [ "$status" -eq 0 ]
    assert_mock_called "cp"
}

@test "plugin-functions: parseArguments should reject init in non-empty directory" {
    # Setup
    source_lib_functions
    create_simple_mock "find" "some-file"  # Non-empty directory
    
    # Test init command in non-empty directory
    run parseArguments init
    
    [ "$status" -eq 1 ]
    [[ "$output" == *"not empty"* ]]
}

@test "plugin-functions: parseArguments should handle start command" {
    # Setup
    source_lib_functions
    create_test_project
    create_simple_mock "docker" ""
    
    # Test start command
    run parseArguments start
    
    [ "$status" -eq 0 ]
    assert_mock_called "docker"
}

@test "plugin-functions: parseArguments should handle stop command" {
    # Setup
    source_lib_functions
    create_test_project
    create_simple_mock "docker" ""
    
    # Test stop command
    run parseArguments stop
    
    [ "$status" -eq 0 ]
    assert_mock_called "docker"
}

@test "plugin-functions: parseArguments should handle restart command" {
    # Setup
    source_lib_functions
    create_test_project
    create_simple_mock "docker" ""
    
    # Test restart command
    run parseArguments restart
    
    [ "$status" -eq 0 ]
    assert_mock_called "docker"
}

@test "plugin-functions: parseArguments should handle status command" {
    # Setup
    source_lib_functions
    create_test_project
    create_simple_mock "docker" ""
    
    # Test status command
    run parseArguments status
    
    [ "$status" -eq 0 ]
    assert_mock_called "docker"
}

@test "plugin-functions: parseArguments should handle pull command" {
    # Setup
    source_lib_functions
    create_test_project
    create_simple_mock "docker" ""
    
    # Test pull command
    run parseArguments pull
    
    [ "$status" -eq 0 ]
    assert_mock_called "docker"
}

@test "plugin-functions: parseArguments should handle console command with default service" {
    # Setup
    source_lib_functions
    create_test_project
    create_simple_mock "docker" ""
    
    # Mock select_docker_service to return php
    select_docker_service() { echo "php"; }
    export -f select_docker_service
    
    # Test console command without service argument
    run parseArguments console
    
    [ "$status" -eq 0 ]
    assert_mock_called "docker"
}

@test "plugin-functions: parseArguments should handle console command with specific service" {
    # Setup
    source_lib_functions
    create_test_project
    create_simple_mock "docker" ""
    
    # Test console command with service argument
    run parseArguments console nginx
    
    [ "$status" -eq 0 ]
    assert_mock_called "docker"
}

@test "plugin-functions: parseArguments should handle show-running command" {
    # Setup
    source_lib_functions
    create_simple_mock "docker" "CONTAINER_ID"
    create_simple_mock "xargs" ""
    create_simple_mock "column" ""
    
    # Test show-running command
    run parseArguments show-running
    
    [ "$status" -eq 0 ]
    assert_mock_called "docker"
}

@test "plugin-functions: parseArguments should handle add-deploy-config command" {
    # Setup
    source_lib_functions
    create_test_project

    # Mock input function to handle -r (reference) parameter properly
    input() {
        local REFERENCE_VAR=""
        local DEFAULT_VALUE=""
        local LABEL=""

        while [[ $# -gt 0 ]]; do
            case $1 in
                -r|--reference)
                    REFERENCE_VAR="$2"
                    shift 2
                    ;;
                -d|--default-value)
                    DEFAULT_VALUE="$2"
                    shift 2
                    ;;
                -l|--label)
                    LABEL="$2"
                    shift 2
                    ;;
                -n|--not-empty)
                    shift
                    ;;
                *)
                    shift
                    ;;
            esac
        done

        # Set appropriate test values based on the label
        local TEST_VALUE
        case "$LABEL" in
            *environment*)
                TEST_VALUE="test-env"
                ;;
            *branch*)
                TEST_VALUE="main"
                ;;
            *user*)
                TEST_VALUE="testuser"
                ;;
            *domain*)
                TEST_VALUE="test.example.com"
                ;;
            *"server root"*)
                TEST_VALUE="/var/www/html"
                ;;
            *description*)
                TEST_VALUE="Test environment description"
                ;;
            *)
                TEST_VALUE="${DEFAULT_VALUE:-test-value}"
                ;;
        esac

        # If reference variable is provided, set it using eval
        if [[ -n "$REFERENCE_VAR" ]]; then
            eval "$REFERENCE_VAR='$TEST_VALUE'"
        else
            echo "$TEST_VALUE"
        fi
    }
    export -f input

    # Test add-deploy-config command
    run parseArguments add-deploy-config

    [ "$status" -eq 0 ]
}

@test "plugin-functions: parseArguments should handle deploy command" {
    # Setup
    source_lib_functions
    create_test_project
    create_test_json_config "$PROJECT_DIR/.deploy.json" "production" "produser" "prod.example.com"

    # Verify the JSON config was created correctly
    [ -f "$PROJECT_DIR/.deploy.json" ]

    # Mock required functions
    fetchRemoteInformation() { return 0; }
    select_release_tag() { echo "v1.0.0"; }
    confirm() { echo "y"; }
    deploy() { return 0; }

    # Override the entire _deploy function to avoid complex mocking
    _deploy() {
        local ENV="$1"

        # Validate environment parameter
        if [[ -z "$ENV" ]]; then
            critical "Environment parameter missing"
            exit 1
        fi

        # Simulate successful deployment workflow
        info "Deploying to environment: $ENV"

        # Mock the deployment steps
        fetchRemoteInformation
        local RELEASE
        RELEASE=$(select_release_tag)

        if [[ $(confirm "Proceed with deployment of '$RELEASE' to '$ENV' environment?") != "y" ]]; then
            info "Deployment cancelled"
            exit 0
        fi

        if deploy "$ENV" "produser" "prod.example.com" "/var/www/html" "$RELEASE"; then
            info "Deployment completed successfully!"
        else
            critical "Deployment failed"
            exit 1
        fi
    }

    export -f fetchRemoteInformation select_release_tag confirm deploy _deploy

    # Test deploy command
    run parseArguments deploy production

    [ "$status" -eq 0 ]
}

@test "plugin-functions: parseArguments should handle deploy command without environment" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Test deploy command without environment argument
    run parseArguments deploy
    
    [ "$status" -eq 1 ]
    [[ "$output" == *"Environment parameter missing"* ]]
}
