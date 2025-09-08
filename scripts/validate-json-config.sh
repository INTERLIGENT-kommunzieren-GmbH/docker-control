#!/bin/bash

# JSON Configuration Validation Script
# Validates a .deploy.json file against the schema and provides detailed feedback

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_ROOT/lib"
SCHEMA_FILE="$LIB_DIR/deployment-config-schema.json"

# Source required functions
. "$LIB_DIR/util-functions.sh"
. "$LIB_DIR/json-config-functions.sh"

function usage() {
    echo "Usage: $0 <json-config-file>"
    echo
    echo "Validates a JSON deployment configuration file against the schema."
    echo
    echo "Examples:"
    echo "  $0 .deploy.json"
    echo "  $0 /path/to/project/.deploy.json"
    echo "  $0 examples/deploy-config-simple.json"
}

function validate_with_schema() {
    local CONFIG_FILE="$1"
    
    # Check if ajv-cli is available for schema validation
    if command -v ajv &> /dev/null; then
        echo "Validating against JSON schema..."
        if ajv validate -s "$SCHEMA_FILE" -d "$CONFIG_FILE"; then
            echo "✓ Schema validation passed"
            return 0
        else
            echo "✗ Schema validation failed"
            return 1
        fi
    else
        echo "Note: ajv-cli not available for schema validation"
        echo "Install with: npm install -g ajv-cli"
        return 0
    fi
}

function validate_config_file() {
    local CONFIG_FILE="$1"
    local VALIDATION_PASSED=true
    
    echo "Validating JSON deployment configuration: $CONFIG_FILE"
    echo "=================================================="
    echo
    
    # Check if file exists
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "✗ File not found: $CONFIG_FILE"
        return 1
    fi
    
    # Basic JSON syntax validation
    echo "Checking JSON syntax..."
    if jq empty "$CONFIG_FILE" 2>/dev/null; then
        echo "✓ Valid JSON syntax"
    else
        echo "✗ Invalid JSON syntax"
        echo "JSON parsing error:"
        jq empty "$CONFIG_FILE" 2>&1 || true
        return 1
    fi
    echo
    
    # Schema validation (if available)
    if [[ -f "$SCHEMA_FILE" ]]; then
        validate_with_schema "$CONFIG_FILE" || VALIDATION_PASSED=false
        echo
    fi
    
    # Custom validation using our functions
    echo "Checking configuration structure..."
    if validateJsonConfig "$CONFIG_FILE"; then
        echo "✓ Configuration structure is valid"
    else
        echo "✗ Configuration structure validation failed"
        VALIDATION_PASSED=false
    fi
    echo
    
    # Load and display configuration summary
    echo "Configuration Summary:"
    echo "====================="
    
    local VERSION
    VERSION=$(jq -r '.version // "unknown"' "$CONFIG_FILE")
    echo "Version: $VERSION"
    
    local ENV_COUNT
    ENV_COUNT=$(jq '.environments | length' "$CONFIG_FILE")
    echo "Environments: $ENV_COUNT"
    
    if [[ $ENV_COUNT -gt 0 ]]; then
        echo "Environment list:"
        jq -r '.environments | keys[]' "$CONFIG_FILE" | while read -r env; do
            local USER DOMAIN SERVICE_ROOT ALLOW_BRANCH
            USER=$(jq -r ".environments[\"$env\"].user" "$CONFIG_FILE")
            DOMAIN=$(jq -r ".environments[\"$env\"].domain" "$CONFIG_FILE")
            SERVICE_ROOT=$(jq -r ".environments[\"$env\"].serviceRoot // \"/var/www/html\"" "$CONFIG_FILE")
            ALLOW_BRANCH=$(jq -r ".environments[\"$env\"].allowBranchDeployment // false" "$CONFIG_FILE")
            
            echo "  - $env:"
            echo "    User: $USER"
            echo "    Domain: $DOMAIN"
            echo "    Service Root: $SERVICE_ROOT"
            echo "    Allow Branch Deployment: $ALLOW_BRANCH"
        done
    fi
    echo
    
    # Check for common issues
    echo "Checking for common issues..."
    
    # Check for duplicate domains
    local DOMAINS
    DOMAINS=$(jq -r '.environments[].domain' "$CONFIG_FILE" | sort)
    local UNIQUE_DOMAINS
    UNIQUE_DOMAINS=$(echo "$DOMAINS" | sort -u)
    
    if [[ "$(echo "$DOMAINS" | wc -l)" != "$(echo "$UNIQUE_DOMAINS" | wc -l)" ]]; then
        echo "⚠ Warning: Duplicate domains found"
        echo "$DOMAINS" | sort | uniq -d | while read -r domain; do
            echo "  Duplicate domain: $domain"
        done
        VALIDATION_PASSED=false
    else
        echo "✓ No duplicate domains"
    fi
    
    # Check for missing descriptions
    local MISSING_DESC
    MISSING_DESC=$(jq -r '.environments | to_entries[] | select(.value.description == null or .value.description == "") | .key' "$CONFIG_FILE")
    if [[ -n "$MISSING_DESC" ]]; then
        echo "⚠ Warning: Environments without descriptions:"
        echo "$MISSING_DESC" | while read -r env; do
            echo "  - $env"
        done
    else
        echo "✓ All environments have descriptions"
    fi
    
    echo
    
    if [[ "$VALIDATION_PASSED" == "true" ]]; then
        echo "✓ Validation completed successfully!"
        return 0
    else
        echo "✗ Validation completed with errors or warnings"
        return 1
    fi
}

# Main script
if [[ $# -ne 1 ]]; then
    usage
    exit 1
fi

CONFIG_FILE="$1"

# Check dependencies
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required for JSON validation"
    echo "Please install jq: apt-get install jq (Ubuntu/Debian) or brew install jq (macOS)"
    exit 1
fi

validate_config_file "$CONFIG_FILE"
