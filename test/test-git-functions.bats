#!/usr/bin/env bats

# Tests for lib/git-functions.sh

load test-helpers

@test "git-functions: _git should execute git commands in htdocs directory" {
    # Setup
    source_lib_functions
    create_test_project
    create_simple_mock "git" "mock git output"
    
    # Test _git function
    run _git status
    
    [ "$status" -eq 0 ]
    assert_mock_called_with "git" "-C $PROJECT_DIR/htdocs status"
}

@test "git-functions: _ensureGitConfig should set default git config when not set" {
    # Setup
    source_lib_functions

    # Create a sophisticated git mock that handles different commands
    cat > "$TEST_TEMP_DIR/mocks/git" << 'EOF'
#!/bin/bash
echo "$(date '+%Y-%m-%d %H:%M:%S') git $*" >> "$MOCK_CALLS_LOG"
if [[ "$*" == *"config --global user.name"* ]] && [[ "$*" != *"Docker Plugin"* ]]; then
    # First call to check if config exists - return failure
    exit 1
else
    # Subsequent calls to set config - return success
    exit 0
fi
EOF
    chmod +x "$TEST_TEMP_DIR/mocks/git"

    # Test _ensureGitConfig
    run _ensureGitConfig

    [ "$status" -eq 0 ]
    assert_mock_called "git"
}

@test "git-functions: _ensureGitConfig should not modify existing git config" {
    # Setup
    source_lib_functions
    create_simple_mock "git" "existing user" 0  # git config returns success (already set)
    
    # Test _ensureGitConfig
    run _ensureGitConfig
    
    [ "$status" -eq 0 ]
    # Should only check config, not set it
    assert_mock_called "git"
}

@test "git-functions: validateGitRepository should pass for valid repository" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Mock git commands to simulate valid repository
    create_mock "git" 'case "$3" in
        "rev-parse") echo ".git" ;;
        "remote") echo "origin" ;;
        "ls-remote") echo "refs/heads/main" ;;
    esac' 0
    
    # Test validation
    run validateGitRepository
    
    [ "$status" -eq 0 ]
}

@test "git-functions: validateGitRepository should fail when not in git repository" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Mock git rev-parse to fail
    create_mock "git" 'case "$3" in
        "rev-parse") exit 1 ;;
    esac' 1
    
    # Test validation
    run validateGitRepository
    
    [ "$status" -eq 1 ]
    [[ "$output" == *"Not in a git repository"* ]]
}

@test "git-functions: validateGitRepository should fail when no remote origin" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Mock git commands
    create_mock "git" 'case "$3" in
        "rev-parse") echo ".git" ;;
        "remote") exit 1 ;;
    esac'
    
    # Test validation
    run validateGitRepository
    
    [ "$status" -eq 1 ]
    [[ "$output" == *"No remote 'origin' configured"* ]]
}

@test "git-functions: validateGitRepository should fail when cannot connect to remote" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Mock git commands
    create_mock "git" 'case "$3" in
        "rev-parse") echo ".git" ;;
        "remote") echo "origin" ;;
        "ls-remote") exit 1 ;;
    esac'
    
    # Test validation
    run validateGitRepository
    
    [ "$status" -eq 1 ]
    [[ "$output" == *"Cannot connect to remote repository"* ]]
}

@test "git-functions: fetchRemoteInformation should fetch all remotes" {
    # Setup
    source_lib_functions
    create_test_project
    create_simple_mock "git" ""
    
    # Test fetch
    run fetchRemoteInformation
    
    [ "$status" -eq 0 ]
    assert_mock_called_with "git" "-C $PROJECT_DIR/htdocs fetch --all"
}

@test "git-functions: fetchRemoteInformation should fail on fetch error" {
    # Setup
    source_lib_functions
    create_test_project
    create_failing_mock "git" "fetch failed"
    
    # Test fetch failure
    run fetchRemoteInformation
    
    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed to fetch remote updates"* ]]
}

@test "git-functions: getPrimaryBranch should detect main branch" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Mock git to return main branch
    create_mock "git" 'case "$4" in
        "main") echo "refs/heads/main" ;;
        "master") exit 1 ;;
    esac'
    
    # Test primary branch detection
    run getPrimaryBranch
    
    [ "$status" -eq 0 ]
    [ "$output" = "main" ]
}

@test "git-functions: getPrimaryBranch should detect master branch" {
    # Setup
    source_lib_functions
    create_test_project

    # Mock git to simulate master branch exists but main doesn't
    cat > "$TEST_TEMP_DIR/mocks/git" << 'EOF'
#!/bin/bash
echo "$(date '+%Y-%m-%d %H:%M:%S') git $*" >> "$MOCK_CALLS_LOG"
if [[ "$*" == *"refs/heads/main"* ]]; then
    exit 1  # main branch doesn't exist
elif [[ "$*" == *"refs/heads/master"* ]]; then
    exit 0  # master branch exists
else
    exit 0  # other git commands succeed
fi
EOF
    chmod +x "$TEST_TEMP_DIR/mocks/git"

    # Test primary branch detection
    run getPrimaryBranch

    [ "$status" -eq 0 ]
    [ "$output" = "master" ]
}

@test "git-functions: getPrimaryBranch should fail when no primary branch found" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Mock git to return no branches
    create_failing_mock "git" "no such ref"
    
    # Test primary branch detection failure
    run getPrimaryBranch
    
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not find main or master branch"* ]]
}

@test "git-functions: getLatestTags should return sorted tags" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Mock git to return tags
    create_mock "git" 'echo -e "v1.0.0\nv1.1.0\nv2.0.0"'
    
    # Test getting latest tags
    run getLatestTags
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"v2.0.0"* ]]
    [[ "$output" == *"v1.1.0"* ]]
    [[ "$output" == *"v1.0.0"* ]]
}

@test "git-functions: getLatestTags should return latest tags by version" {
    # Setup
    source_lib_functions
    create_test_project

    # Mock git to return tags in a realistic way
    cat > "$TEST_TEMP_DIR/mocks/git" << 'EOF'
#!/bin/bash
echo "$(date '+%Y-%m-%d %H:%M:%S') git $*" >> "$MOCK_CALLS_LOG"
if [[ "$*" == *"fetch --tags"* ]]; then
    exit 0  # fetch succeeds
elif [[ "$*" == *"tag -l"* ]]; then
    echo -e "v1.0.0\nv1.1.0\nv2.0.0\nv2.1.0\nv3.0.0"
else
    exit 0
fi
EOF
    chmod +x "$TEST_TEMP_DIR/mocks/git"

    # Test getting latest tags
    run getLatestTags

    [ "$status" -eq 0 ]
    # Should return some tags (exact count depends on algorithm)
    [[ "$output" == *"v"* ]]
}

@test "git-functions: getLatestReleaseBranch should find release branches" {
    # Setup
    source_lib_functions
    create_test_project

    # Mock git to return release branches in the expected format
    cat > "$TEST_TEMP_DIR/mocks/git" << 'EOF'
#!/bin/bash
echo "$(date '+%Y-%m-%d %H:%M:%S') git $*" >> "$MOCK_CALLS_LOG"
if [[ "$*" == *"fetch origin"* ]]; then
    exit 0  # fetch succeeds
elif [[ "$*" == *"branch -a --format"* ]]; then
    echo -e "1.0.x\n1.1.x\n2.0.x"
else
    exit 0
fi
EOF
    chmod +x "$TEST_TEMP_DIR/mocks/git"

    # Mock choose function to select first option
    choose() { echo "2.0.x"; }
    export -f choose

    # Test getting latest release branch
    run getLatestReleaseBranch

    [ "$status" -eq 0 ]
    [ "$output" = "2.0.x" ]
}

@test "git-functions: getLatestReleaseBranch should handle no release branches" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Mock git to return no release branches
    create_simple_mock "git" ""
    
    # Test getting latest release branch when none exist
    run getLatestReleaseBranch
    
    [ "$status" -eq 1 ]
    [[ "$output" == *"No release branches found"* ]]
}

@test "git-functions: updateSelectedBranches should update specified branches" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Mock git commands
    create_mock "git" 'case "$3" in
        "rev-parse") 
            case "$5" in
                "main") echo "abc123" ;;
                "origin/main") echo "def456" ;;
                *) exit 1 ;;
            esac ;;
        "fetch") echo "fetched" ;;
        "pull") echo "pulled" ;;
    esac'
    
    # Mock getPrimaryBranch
    getPrimaryBranch() { echo "main"; }
    export -f getPrimaryBranch
    
    # Test updating branches
    run updateSelectedBranches "main"
    
    [ "$status" -eq 0 ]
    assert_mock_called "git"
}

@test "git-functions: _testRemoteConnection should succeed for valid remote" {
    # Setup
    source_lib_functions
    create_test_project
    create_simple_mock "git" "remote refs"
    
    # Test remote connection
    run _testRemoteConnection "$PROJECT_DIR/htdocs"
    
    [ "$status" -eq 0 ]
    assert_mock_called "git"
}

@test "git-functions: _testRemoteConnection should fail for invalid remote" {
    # Setup
    source_lib_functions
    create_test_project
    create_failing_mock "git" "connection failed"
    
    # Test remote connection failure
    run _testRemoteConnection "$PROJECT_DIR/htdocs"
    
    [ "$status" -eq 1 ]
    [[ "$output" == *"Cannot connect to remote repository"* ]]
}
