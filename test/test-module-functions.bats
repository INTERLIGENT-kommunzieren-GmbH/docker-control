#!/usr/bin/env bats

# Tests for module functionality in lib/git-functions.sh

load test-helpers

@test "module-functions: validateModulePath should accept empty module path" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Test empty module path (should be valid)
    run validateModulePath ""
    
    [ "$status" -eq 0 ]
}

@test "module-functions: validateModulePath should reject invalid paths" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Test path starting with /
    run validateModulePath "/invalid/path"
    [ "$status" -eq 1 ]
    
    # Test path containing ..
    run validateModulePath "invalid/../path"
    [ "$status" -eq 1 ]
}

@test "module-functions: validateModulePath should reject non-existent module" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Test non-existent module path
    run validateModulePath "non/existent"
    
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Module directory does not exist" ]]
}

@test "module-functions: validateModulePath should reject directory without Git repo" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Create module directory without Git repo
    mkdir -p "$PROJECT_DIR/htdocs/vendor/test/module"
    
    # Test module without Git repository
    run validateModulePath "test/module"
    
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Module directory is not a Git repository" ]]
}

@test "module-functions: validateModulePath should accept valid module with Git repo" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Create module directory with Git repo
    mkdir -p "$PROJECT_DIR/htdocs/vendor/test/module"
    git init "$PROJECT_DIR/htdocs/vendor/test/module"
    
    # Test valid module with Git repository
    run validateModulePath "test/module"
    
    [ "$status" -eq 0 ]
}

@test "module-functions: setModuleContext should set MODULE_PATH correctly" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Create valid module
    mkdir -p "$PROJECT_DIR/htdocs/vendor/ik/shared"
    git init "$PROJECT_DIR/htdocs/vendor/ik/shared"
    
    # Test setting module context
    run setModuleContext "ik/shared"
    
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Working with module: ik/shared" ]]
}

@test "module-functions: getWorktreeBasePath should return correct paths" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Test without module (should return default path)
    MODULE_PATH=""
    result=$(getWorktreeBasePath)
    [ "$result" = "$PROJECT_DIR/releases" ]
    
    # Test with module (should return module-specific path)
    MODULE_PATH="ik/shared"
    result=$(getWorktreeBasePath)
    [ "$result" = "$PROJECT_DIR/releases/vendor/ik/shared" ]
}

@test "module-functions: _git should use correct repository path" {
    # Setup
    source_lib_functions
    create_test_project
    create_simple_mock "git" "mock git output"
    
    # Test without module (should use htdocs)
    MODULE_PATH=""
    run _git status
    
    [ "$status" -eq 0 ]
    assert_mock_called_with "git" "-C $PROJECT_DIR/htdocs status"
    
    # Test with module (should use vendor module path)
    MODULE_PATH="ik/shared"
    run _git status
    
    [ "$status" -eq 0 ]
    assert_mock_called_with "git" "-C $PROJECT_DIR/htdocs/vendor/ik/shared status"
}
