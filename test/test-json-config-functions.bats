#!/usr/bin/env bats

# Tests for lib/json-config-functions.sh

load test-helpers

@test "json-config: validateJsonConfig should pass for valid JSON" {
    skip_if_no_command jq
    
    # Setup
    source_lib_functions
    create_test_json_config "$TEST_TEMP_DIR/valid.json"
    
    # Test validation
    run validateJsonConfig "$TEST_TEMP_DIR/valid.json"
    
    [ "$status" -eq 0 ]
}

@test "json-config: validateJsonConfig should fail for missing file" {
    skip_if_no_command jq
    
    # Setup
    source_lib_functions
    
    # Test validation with non-existent file
    run validateJsonConfig "$TEST_TEMP_DIR/nonexistent.json"
    
    [ "$status" -eq 1 ]
}

@test "json-config: validateJsonConfig should fail for invalid JSON syntax" {
    skip_if_no_command jq

    # Setup
    source_lib_functions

    # Create invalid JSON
    echo '{ "invalid": json, }' > "$TEST_TEMP_DIR/invalid.json"

    # Test validation - should fail with exit code 1
    run validateJsonConfig "$TEST_TEMP_DIR/invalid.json"

    [ "$status" -eq 1 ]
    # Note: Output may be empty due to mocked gum, but the function should still return 1
}

@test "json-config: validateJsonConfig should fail for missing version field" {
    skip_if_no_command jq

    # Setup
    source_lib_functions

    # Create JSON without version
    echo '{ "environments": {} }' > "$TEST_TEMP_DIR/no-version.json"

    # Test validation - should fail with exit code 1
    run validateJsonConfig "$TEST_TEMP_DIR/no-version.json"

    [ "$status" -eq 1 ]
    # Note: Output may be empty due to mocked gum, but the function should still return 1
}

@test "json-config: createJsonConfig should create valid JSON structure" {
    skip_if_no_command jq
    
    # Setup
    source_lib_functions
    
    # Test creation
    run createJsonConfig "$TEST_TEMP_DIR/new.json"
    
    [ "$status" -eq 0 ]
    [ -f "$TEST_TEMP_DIR/new.json" ]
    
    # Validate created JSON
    run validateJsonConfig "$TEST_TEMP_DIR/new.json"
    [ "$status" -eq 0 ]
    
    # Check structure
    version=$(jq -r '.version' "$TEST_TEMP_DIR/new.json")
    [ "$version" = "1.0" ]
    
    # Check that environments object exists
    jq -e '.environments' "$TEST_TEMP_DIR/new.json" >/dev/null
    jq -e '.metadata' "$TEST_TEMP_DIR/new.json" >/dev/null
}

@test "json-config: addJsonEnvironment should add environment to config" {
    skip_if_no_command jq
    
    # Setup
    source_lib_functions
    createJsonConfig "$TEST_TEMP_DIR/config.json"
    
    # Test adding environment
    run addJsonEnvironment "$TEST_TEMP_DIR/config.json" "staging" "develop" "testuser" "staging.example.com" "/var/www/html" "Staging environment"
    
    [ "$status" -eq 0 ]
    
    # Verify environment was added
    user=$(jq -r '.environments.staging.user' "$TEST_TEMP_DIR/config.json")
    [ "$user" = "testuser" ]
    
    domain=$(jq -r '.environments.staging.domain' "$TEST_TEMP_DIR/config.json")
    [ "$domain" = "staging.example.com" ]
    
    branch=$(jq -r '.environments.staging.branch' "$TEST_TEMP_DIR/config.json")
    [ "$branch" = "develop" ]
}

@test "json-config: addJsonEnvironment should add environment with branch" {
    skip_if_no_command jq

    # Setup
    source_lib_functions
    createJsonConfig "$TEST_TEMP_DIR/config.json"

    # Test adding environment with feature branch
    run addJsonEnvironment "$TEST_TEMP_DIR/config.json" "dev" "feature-branch" "devuser" "dev.example.com" "/var/www/html" "Development environment"

    [ "$status" -eq 0 ]

    # Verify environment was added with correct branch
    branch=$(jq -r '.environments.dev.branch' "$TEST_TEMP_DIR/config.json")
    [ "$branch" = "feature-branch" ]

    user=$(jq -r '.environments.dev.user' "$TEST_TEMP_DIR/config.json")
    [ "$user" = "devuser" ]
}

@test "json-config: loadJsonConfig should load environments correctly" {
    skip_if_no_command jq

    # Setup
    source_lib_functions
    create_test_json_config "$TEST_TEMP_DIR/config.json" "production" "produser" "prod.example.com"

    # Test loading (don't use run to avoid subshell issues with global variables)
    loadJsonConfig "$TEST_TEMP_DIR/config.json"

    # Check that JSON_DEPLOY_ENVS was populated
    [ -n "${JSON_DEPLOY_ENVS[production]}" ]

    # Verify the format
    [[ "${JSON_DEPLOY_ENVS[production]}" == *"USER=produser"* ]]
    [[ "${JSON_DEPLOY_ENVS[production]}" == *"DOMAIN=prod.example.com"* ]]
}

@test "json-config: getJsonConfigFile should find config in project root" {
    skip_if_no_command jq
    
    # Setup
    source_lib_functions
    create_test_json_config "$PROJECT_DIR/.deploy.json"
    
    # Test finding config
    run getJsonConfigFile "$PROJECT_DIR"
    
    [ "$status" -eq 0 ]
    [ "$output" = "$PROJECT_DIR/.deploy.json" ]
}

@test "json-config: getJsonConfigFile should prefer .docker-control location" {
    skip_if_no_command jq
    
    # Setup
    source_lib_functions
    mkdir -p "$PROJECT_DIR/htdocs/.docker-control"
    
    # Create configs in both locations
    create_test_json_config "$PROJECT_DIR/.deploy.json"
    create_test_json_config "$PROJECT_DIR/htdocs/.docker-control/.deploy.json"
    
    # Test finding config (should prefer .docker-control)
    run getJsonConfigFile "$PROJECT_DIR"
    
    [ "$status" -eq 0 ]
    [ "$output" = "$PROJECT_DIR/htdocs/.docker-control/.deploy.json" ]
}

@test "json-config: getJsonConfigFile should return empty for no config" {
    # Setup
    source_lib_functions
    
    # Test finding config when none exists
    run getJsonConfigFile "$PROJECT_DIR"
    
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "json-config: getJsonConfigValue should return correct values" {
    skip_if_no_command jq
    
    # Setup
    source_lib_functions
    create_test_json_config "$TEST_TEMP_DIR/config.json" "test" "testuser" "test.example.com"
    
    # Test getting values
    run getJsonConfigValue "$TEST_TEMP_DIR/config.json" ".environments.test.user" "default"
    
    [ "$status" -eq 0 ]
    [ "$output" = "testuser" ]
}

@test "json-config: getJsonConfigValue should return default for missing values" {
    skip_if_no_command jq

    # Setup
    source_lib_functions
    create_test_json_config "$TEST_TEMP_DIR/config.json"

    # Test getting non-existent value
    run getJsonConfigValue "$TEST_TEMP_DIR/config.json" ".nonexistent" "default_value"

    [ "$status" -eq 0 ]
    [ "$output" = "default_value" ]
}

@test "json-config: getJsonConfigValue should handle missing file" {
    skip_if_no_command jq
    
    # Setup
    source_lib_functions
    
    # Test getting value from non-existent file
    run getJsonConfigValue "$TEST_TEMP_DIR/nonexistent.json" ".test" "default_value"
    
    [ "$status" -eq 1 ]
    [ "$output" = "default_value" ]
}

@test "json-config: updateJsonEnvironment should modify existing environment" {
    skip_if_no_command jq

    # Setup
    source_lib_functions
    create_test_json_config "$TEST_TEMP_DIR/config.json" "test" "olduser" "old.example.com"

    # Test updating user field
    run updateJsonEnvironment "$TEST_TEMP_DIR/config.json" "test" "user" "newuser"

    [ "$status" -eq 0 ]

    # Verify user update
    user=$(jq -r '.environments.test.user' "$TEST_TEMP_DIR/config.json")
    [ "$user" = "newuser" ]

    # Test updating domain field
    run updateJsonEnvironment "$TEST_TEMP_DIR/config.json" "test" "domain" "new.example.com"

    [ "$status" -eq 0 ]

    # Verify domain update
    domain=$(jq -r '.environments.test.domain' "$TEST_TEMP_DIR/config.json")
    [ "$domain" = "new.example.com" ]
}

@test "json-config: removeJsonEnvironment should remove environment" {
    skip_if_no_command jq
    
    # Setup
    source_lib_functions
    create_test_json_config "$TEST_TEMP_DIR/config.json" "test" "testuser" "test.example.com"
    
    # Verify environment exists
    jq -e '.environments.test' "$TEST_TEMP_DIR/config.json" >/dev/null
    
    # Test removing environment
    run removeJsonEnvironment "$TEST_TEMP_DIR/config.json" "test"
    
    [ "$status" -eq 0 ]
    
    # Verify environment was removed
    run jq -e '.environments.test' "$TEST_TEMP_DIR/config.json"
    [ "$status" -ne 0 ]
}
