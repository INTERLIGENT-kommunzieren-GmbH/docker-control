#!/usr/bin/env bats

# Tests for lib/deploy-functions.sh

load test-helpers

@test "deploy-functions: copySSH should execute scp with correct parameters" {
    # Setup
    source_lib_functions
    create_simple_mock "scp" ""
    
    # Test copySSH
    run copySSH "testuser" "test.example.com" "/local/file" "/remote/path"
    
    [ "$status" -eq 0 ]
    assert_mock_called_with "scp" "-o StrictHostKeyChecking=no -A /local/file testuser@test.example.com:/remote/path"
}

@test "deploy-functions: copySSH should return scp exit code" {
    # Setup
    source_lib_functions
    create_failing_mock "scp" "scp failed"
    
    # Test copySSH failure
    run copySSH "testuser" "test.example.com" "/local/file" "/remote/path"
    
    [ "$status" -eq 1 ]
    assert_mock_called "scp"
}

@test "deploy-functions: execSSH should execute ssh with correct parameters" {
    # Setup
    source_lib_functions
    create_simple_mock "ssh" ""
    
    # Test execSSH
    run execSSH "testuser" "test.example.com" "ls -la"
    
    [ "$status" -eq 0 ]
    assert_mock_called_with "ssh" "-o LogLevel=QUIET -o StrictHostKeyChecking=accept-new -tA testuser@test.example.com -- ls -la"
}

@test "deploy-functions: execSSH should return ssh exit code" {
    # Setup
    source_lib_functions
    create_failing_mock "ssh" "ssh failed"
    
    # Test execSSH failure
    run execSSH "testuser" "test.example.com" "failing-command"
    
    [ "$status" -eq 1 ]
    assert_mock_called "ssh"
}

@test "deploy-functions: createDeploymentZip should create deployment archive" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Mock required commands
    create_simple_mock "date" "20231201120000"
    create_simple_mock "git" "abc123"
    create_simple_mock "7z" ""
    create_simple_mock "mkdir" ""
    
    # Test createDeploymentZip
    run createDeploymentZip "production" "main"
    
    [ "$status" -eq 0 ]
    assert_mock_called "7z"
    assert_mock_called "git"
}

@test "deploy-functions: createDeploymentZip should prompt for branch when not provided" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Mock required commands
    create_simple_mock "date" "20231201120000"
    create_simple_mock "git" "abc123"
    create_simple_mock "7z" ""
    create_simple_mock "mkdir" ""
    
    # Mock input function
    input() { echo "develop"; }
    export -f input
    
    # Test createDeploymentZip without branch
    run createDeploymentZip "staging"
    
    [ "$status" -eq 0 ]
    assert_mock_called "7z"
}

@test "deploy-functions: deploy should execute full deployment workflow" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Mock all required commands
    create_simple_mock "date" "20231201120000"
    create_simple_mock "git" "abc123"
    create_simple_mock "7z" ""
    create_simple_mock "mkdir" ""
    create_simple_mock "scp" ""
    create_simple_mock "ssh" ""
    create_simple_mock "basename" "deployment.7z"
    
    # Mock required functions
    createDeploymentZip() { echo "$TEST_TEMP_DIR/deployment.7z"; }
    confirm() { echo "y"; }
    wait_for_keypress() { return 0; }
    export -f createDeploymentZip confirm wait_for_keypress
    
    # Create deployment script
    mkdir -p "$PROJECT_DIR/deployments"
    cat > "$PROJECT_DIR/deployments/production.sh" << 'EOF'
#!/bin/bash
# Test deployment script
EOF
    
    # Test deploy function
    run deploy "production" "testuser" "test.example.com" "/var/www/html" "main"
    
    [ "$status" -eq 0 ]
    assert_mock_called "scp"
    assert_mock_called "ssh"
}

@test "deploy-functions: deploy should handle missing deployment script" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Mock required commands
    create_simple_mock "date" "20231201120000"
    create_simple_mock "git" "abc123"
    create_simple_mock "7z" ""
    create_simple_mock "mkdir" ""
    
    # Mock createDeploymentZip
    createDeploymentZip() { echo "$TEST_TEMP_DIR/deployment.7z"; }
    export -f createDeploymentZip
    
    # Test deploy without deployment script
    run deploy "production" "testuser" "test.example.com" "/var/www/html" "main"
    
    [ "$status" -eq 1 ]
    [[ "$output" == *"Deployment script not found"* ]]
}

@test "deploy-functions: deploy should use default server root when not provided" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Mock all required commands
    create_simple_mock "date" "20231201120000"
    create_simple_mock "git" "abc123"
    create_simple_mock "7z" ""
    create_simple_mock "mkdir" ""
    create_simple_mock "scp" ""
    create_simple_mock "ssh" ""
    create_simple_mock "basename" "deployment.7z"
    
    # Mock required functions
    createDeploymentZip() { echo "$TEST_TEMP_DIR/deployment.7z"; }
    confirm() { echo "y"; }
    wait_for_keypress() { return 0; }
    export -f createDeploymentZip confirm wait_for_keypress
    
    # Create deployment script
    mkdir -p "$PROJECT_DIR/deployments"
    cat > "$PROJECT_DIR/deployments/production.sh" << 'EOF'
#!/bin/bash
# Test deployment script
EOF
    
    # Test deploy without server root (should default to /var/www/html)
    run deploy "production" "testuser" "test.example.com" "" "main"
    
    [ "$status" -eq 0 ]
    assert_mock_called "scp"
    assert_mock_called "ssh"
}

@test "deploy-functions: deploy should execute pre-deploy hooks if they exist" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Mock all required commands
    create_simple_mock "date" "20231201120000"
    create_simple_mock "git" "abc123"
    create_simple_mock "7z" ""
    create_simple_mock "mkdir" ""
    create_simple_mock "scp" ""
    create_simple_mock "ssh" ""
    create_simple_mock "basename" "deployment.7z"
    
    # Mock required functions
    createDeploymentZip() { echo "$TEST_TEMP_DIR/deployment.7z"; }
    confirm() { echo "y"; }
    wait_for_keypress() { return 0; }
    export -f createDeploymentZip confirm wait_for_keypress
    
    # Create deployment script with pre-deploy hook
    mkdir -p "$PROJECT_DIR/deployments"
    cat > "$PROJECT_DIR/deployments/production.sh" << 'EOF'
#!/bin/bash
function pre_deploy_hook_production() {
    echo "Pre-deploy hook executed"
}
EOF
    
    # Test deploy with pre-deploy hook
    run deploy "production" "testuser" "test.example.com" "/var/www/html" "main"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"Pre-deploy hook executed"* ]]
}

@test "deploy-functions: deploy should handle SSH connection failures" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Mock commands with SSH failure
    create_simple_mock "date" "20231201120000"
    create_simple_mock "git" "abc123"
    create_simple_mock "7z" ""
    create_simple_mock "mkdir" ""
    create_failing_mock "scp" "connection failed"
    
    # Mock required functions
    createDeploymentZip() { echo "$TEST_TEMP_DIR/deployment.7z"; }
    export -f createDeploymentZip
    
    # Create deployment script
    mkdir -p "$PROJECT_DIR/deployments"
    cat > "$PROJECT_DIR/deployments/production.sh" << 'EOF'
#!/bin/bash
# Test deployment script
EOF
    
    # Test deploy with SSH failure
    run deploy "production" "testuser" "test.example.com" "/var/www/html" "main"
    
    [ "$status" -eq 1 ]
    assert_mock_called "scp"
}

@test "deploy-functions: deploy should clean up old deployments" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Mock all required commands
    create_simple_mock "date" "20231201120000"
    create_simple_mock "git" "abc123"
    create_simple_mock "7z" ""
    create_simple_mock "mkdir" ""
    create_simple_mock "scp" ""
    create_simple_mock "ssh" ""
    create_simple_mock "basename" "deployment.7z"
    
    # Mock required functions
    createDeploymentZip() { echo "$TEST_TEMP_DIR/deployment.7z"; }
    confirm() { echo "y"; }
    wait_for_keypress() { return 0; }
    export -f createDeploymentZip confirm wait_for_keypress
    
    # Create deployment script
    mkdir -p "$PROJECT_DIR/deployments"
    cat > "$PROJECT_DIR/deployments/production.sh" << 'EOF'
#!/bin/bash
# Test deployment script
EOF
    
    # Test deploy (should include cleanup command)
    run deploy "production" "testuser" "test.example.com" "/var/www/html" "main"
    
    [ "$status" -eq 0 ]
    # Should call ssh with cleanup command
    assert_mock_called "ssh"
}

@test "deploy-functions: deploy should handle deployment confirmation" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Mock commands
    create_simple_mock "date" "20231201120000"
    create_simple_mock "git" "abc123"
    create_simple_mock "7z" ""
    create_simple_mock "mkdir" ""
    
    # Mock createDeploymentZip
    createDeploymentZip() { echo "$TEST_TEMP_DIR/deployment.7z"; }
    export -f createDeploymentZip
    
    # Mock confirm to return 'n' (no)
    confirm() { echo "n"; }
    export -f confirm
    
    # Create deployment script
    mkdir -p "$PROJECT_DIR/deployments"
    cat > "$PROJECT_DIR/deployments/production.sh" << 'EOF'
#!/bin/bash
# Test deployment script
EOF
    
    # Test deploy with negative confirmation
    run deploy "production" "testuser" "test.example.com" "/var/www/html" "main"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"Deployment cancelled"* ]]
}
