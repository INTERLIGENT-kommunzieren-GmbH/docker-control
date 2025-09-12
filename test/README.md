# Docker Plugin Test Suite

This directory contains a comprehensive test suite for the docker-plugin project, providing unit tests, integration tests, and static analysis for all shell script components.

## Overview

The test suite is designed to:
- Ensure code quality and reliability
- Prevent regressions during development
- Validate all public functions and workflows
- Test error handling and edge cases
- Provide fast feedback during development

## Test Structure

```
test/
├── README.md                    # This documentation
├── run-tests.sh                 # Main test runner script
├── test-framework.sh            # Legacy bash-based test framework
├── test-helpers.bash            # Common test utilities and mocks
├── test-util-functions.bats     # Tests for lib/util-functions.sh
├── test-json-config-functions.bats # Tests for lib/json-config-functions.sh
├── test-git-functions.bats      # Tests for lib/git-functions.sh
├── test-deploy-functions.bats   # Tests for lib/deploy-functions.sh
├── test-plugin-functions.bats   # Tests for lib/plugin-functions.sh
└── test-integration.bats        # Integration tests for complete workflows
```

## Dependencies

The test suite requires the following tools:

### Required
- **bats-core**: Testing framework for shell scripts
- **jq**: JSON processor for configuration tests
- **bash**: Shell interpreter (version 4.0+)

### Optional but Recommended
- **shellcheck**: Static analysis for shell scripts
- **git**: For Git-related tests (usually available)

### Installation

On systems with Homebrew (including Linux):
```bash
brew install bats-core jq shellcheck
```

On Ubuntu/Debian:
```bash
sudo apt-get install bats jq shellcheck
```

On RHEL/CentOS/Fedora:
```bash
sudo dnf install bats jq ShellCheck
```

## Running Tests

### Quick Start

Run all tests with default settings:
```bash
./test/run-tests.sh
```

### Test Runner Options

The test runner provides several options for different testing scenarios:

```bash
# Run all tests with verbose output
./test/run-tests.sh --verbose

# Run only unit tests
./test/run-tests.sh --unit-only

# Run only integration tests
./test/run-tests.sh --integration-only

# Skip static analysis
./test/run-tests.sh --no-shellcheck

# Run tests matching a pattern
./test/run-tests.sh --pattern util

# Use parallel execution with custom job count
./test/run-tests.sh --jobs 8

# Show help
./test/run-tests.sh --help
```

### Running Individual Test Files

You can also run individual test files directly with bats:

```bash
# Run specific test file
export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"
bats test/test-util-functions.bats

# Run with verbose output
bats --verbose-run test/test-util-functions.bats

# Run specific test by name pattern
bats --filter "util-functions: confirm" test/test-util-functions.bats
```

## Test Categories

### Unit Tests

Unit tests focus on individual functions and components:

- **test-util-functions.bats**: Tests utility functions like text formatting, user input, and confirmation dialogs
- **test-json-config-functions.bats**: Tests JSON configuration management functions
- **test-git-functions.bats**: Tests Git operations and repository management
- **test-deploy-functions.bats**: Tests deployment functions and SSH operations
- **test-plugin-functions.bats**: Tests main plugin functions and command parsing

### Integration Tests

Integration tests validate complete workflows:

- **test-integration.bats**: Tests end-to-end scenarios like project initialization, deployment workflows, and component interactions

### Static Analysis

- **ShellCheck**: Analyzes all shell scripts for common issues, best practices, and potential bugs

## Test Utilities

### Mock System

The test suite includes a comprehensive mocking system for external dependencies:

```bash
# Create a simple mock
create_simple_mock "docker" "mock output"

# Create a mock that fails
create_failing_mock "git" "connection failed"

# Create a complex mock with conditional behavior
create_mock "git" 'case "$3" in
    "status") echo "clean" ;;
    "branch") echo "main" ;;
esac'

# Verify mock was called
assert_mock_called "docker"
assert_mock_called_with "git" "status"
```

### Test Helpers

Common test setup and utilities:

```bash
# Create a test project structure
create_test_project "my-project"

# Create test JSON configuration
create_test_json_config "$config_file" "env" "user" "domain"

# Source library functions with mocks
source_lib_functions
```

## Writing Tests

### Test File Structure

Each test file follows this structure:

```bash
#!/usr/bin/env bats

# Tests for lib/example-functions.sh

load test-helpers

@test "function-name: should do something when condition" {
    # Setup
    source_lib_functions
    create_test_project
    
    # Test
    run function_name "argument"
    
    # Assertions
    [ "$status" -eq 0 ]
    [ "$output" = "expected output" ]
    assert_mock_called "external_command"
}
```

### Best Practices

1. **Descriptive Test Names**: Use format `component: should behavior when condition`
2. **Isolated Tests**: Each test should be independent and not affect others
3. **Mock External Dependencies**: Mock all external commands (docker, git, ssh, etc.)
4. **Test Both Success and Failure**: Include positive and negative test cases
5. **Verify Side Effects**: Check that functions call expected external commands
6. **Use Assertions**: Use appropriate assertion functions for clear error messages

### Common Patterns

```bash
# Test successful execution
@test "function: should succeed with valid input" {
    run function_name "valid_input"
    [ "$status" -eq 0 ]
}

# Test failure cases
@test "function: should fail with invalid input" {
    run function_name "invalid_input"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error message"* ]]
}

# Test external command calls
@test "function: should call external command with correct arguments" {
    create_simple_mock "external_cmd" ""
    run function_name
    assert_mock_called_with "external_cmd" "expected arguments"
}

# Test file operations
@test "function: should create expected files" {
    run function_name
    [ -f "$expected_file" ]
    [[ "$(cat "$expected_file")" == *"expected content"* ]]
}
```

## Continuous Integration

### GitHub Actions

Example workflow file (`.github/workflows/test.yml`):

```yaml
name: Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y bats jq shellcheck
      - name: Run tests
        run: ./test/run-tests.sh
```

### Local Pre-commit Hook

Add to `.git/hooks/pre-commit`:

```bash
#!/bin/bash
./test/run-tests.sh --unit-only
```

## Troubleshooting

### Common Issues

1. **bats command not found**: Ensure bats-core is installed and in PATH
2. **jq command not found**: Install jq package
3. **Permission denied**: Make sure test files are executable
4. **Mock not working**: Check that mock directory is in PATH

### Debug Mode

Run tests with verbose output to see detailed execution:

```bash
./test/run-tests.sh --verbose
```

### Manual Test Execution

For debugging specific tests:

```bash
# Set up environment
export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"
cd /path/to/docker-plugin

# Run single test with debug output
bats --verbose-run --print-output-on-failure test/test-util-functions.bats
```

## Contributing

When adding new functionality:

1. Write tests for new functions
2. Update existing tests if behavior changes
3. Run the full test suite before submitting
4. Follow the established testing patterns
5. Update documentation if needed

### Test Coverage

Aim for comprehensive coverage of:
- All public functions
- Error conditions and edge cases
- Integration between components
- Command-line argument parsing
- Configuration file handling
- External command interactions
