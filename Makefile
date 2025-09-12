# Makefile for Docker Plugin

.PHONY: help test test-unit test-integration test-shellcheck test-verbose clean install-deps

# Default target
help:
	@echo "Docker Plugin - Available Commands"
	@echo "=================================="
	@echo ""
	@echo "Testing:"
	@echo "  test              Run all tests (unit, integration, shellcheck)"
	@echo "  test-unit         Run only unit tests"
	@echo "  test-integration  Run only integration tests"
	@echo "  test-shellcheck   Run only shellcheck static analysis"
	@echo "  test-verbose      Run all tests with verbose output"
	@echo ""
	@echo "Development:"
	@echo "  install-deps      Install test dependencies"
	@echo "  clean             Clean up test artifacts"
	@echo "  lint              Run shellcheck on all shell scripts"
	@echo ""
	@echo "Examples:"
	@echo "  make test                    # Run all tests"
	@echo "  make test-unit               # Run only unit tests"
	@echo "  make test TEST_PATTERN=util  # Run tests matching 'util'"

# Test targets
test:
	@echo "Running all tests (sequential mode)..."
	./test/run-tests.sh

test-unit:
	@echo "Running unit tests (sequential mode)..."
	./test/run-tests.sh --unit-only

test-integration:
	@echo "Running integration tests (sequential mode)..."
	./test/run-tests.sh --integration-only

test-shellcheck:
	@echo "Running shellcheck..."
	./test/run-tests.sh --shellcheck-only

# Development targets
install-deps:
	@echo "Installing test dependencies..."
	@if command -v brew >/dev/null 2>&1; then \
		echo "Installing via Homebrew..."; \
		brew install bats-core jq shellcheck; \
	elif command -v apt-get >/dev/null 2>&1; then \
		echo "Installing via apt-get..."; \
		sudo apt-get update && sudo apt-get install -y bats jq shellcheck; \
	elif command -v dnf >/dev/null 2>&1; then \
		echo "Installing via dnf..."; \
		sudo dnf install -y bats jq ShellCheck; \
	else \
		echo "Please install bats-core, jq, and shellcheck manually"; \
		exit 1; \
	fi
	@echo "Dependencies installed successfully!"

lint:
	@echo "Running shellcheck on all shell scripts..."
	@find . -name "*.sh" -type f -exec shellcheck {} \;
	@echo "Shellcheck completed!"

clean:
	@echo "Cleaning up test artifacts..."
	@rm -rf /tmp/docker-plugin-tests-*
	@rm -f test/*.log test/*.xml
	@echo "Cleanup completed!"

# Check if test runner is executable
check-test-runner:
	@if [ ! -x "test/run-tests.sh" ]; then \
		echo "Making test runner executable..."; \
		chmod +x test/run-tests.sh; \
	fi

# Ensure test runner is executable before running tests
test test-unit test-integration test-shellcheck: check-test-runner

# Development workflow targets
dev-setup: install-deps
	@echo "Setting up development environment..."
	@chmod +x test/run-tests.sh
	@chmod +x install.sh
	@chmod +x entrypoint.sh
	@echo "Development environment ready!"

# Quick validation before commit
pre-commit: test-shellcheck test-unit
	@echo "Pre-commit validation completed successfully!"

# Full validation (like CI)
ci: test
	@echo "CI validation completed successfully!"
