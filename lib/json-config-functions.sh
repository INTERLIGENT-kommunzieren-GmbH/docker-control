#!/bin/bash

# JSON Configuration Functions for Docker Control Plugin
# Provides functions to read, validate, and manipulate JSON deployment configurations

# Source utility functions for sanitizeName and other utilities
. "${LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/util-functions.sh"

# Global variables for JSON configuration
declare -A JSON_DEPLOY_ENVS
declare -a JSON_DEPLOY_ENVS_ORDER

function validateJsonConfig() {
    local CONFIG_FILE="$1"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 1
    fi
    
    # Check if jq is available for JSON validation
    if ! command -v jq &> /dev/null; then
        critical "jq is required for JSON configuration support but is not installed"
        critical "Please install jq: apt-get install jq (Ubuntu/Debian) or brew install jq (macOS)"
        return 1
    fi
    
    # Validate JSON syntax
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        critical "Invalid JSON syntax in configuration file: $CONFIG_FILE"
        return 1
    fi
    
    # Validate required fields
    local VERSION
    VERSION=$(jq -r '.version // empty' "$CONFIG_FILE" 2>/dev/null)
    if [[ -z "$VERSION" ]]; then
        critical "Missing required field 'version' in configuration file: $CONFIG_FILE"
        return 1
    fi
    
    if [[ "$VERSION" != "1.0" ]]; then
        critical "Unsupported configuration version: $VERSION (expected: 1.0)"
        return 1
    fi
    
    # Check if environments object exists
    if ! jq -e '.environments' "$CONFIG_FILE" >/dev/null 2>&1; then
        critical "Missing required field 'environments' in configuration file: $CONFIG_FILE"
        return 1
    fi
    
    # Validate each environment has required fields
    local ENV_NAMES
    ENV_NAMES=$(jq -r '.environments | keys[]' "$CONFIG_FILE" 2>/dev/null)
    
    while IFS= read -r env; do
        if [[ -n "$env" ]]; then
            # Sanitize environment name for internal use
            local SANITIZED_ENV
            SANITIZED_ENV=$(sanitizeName "$env")

            # Check required fields for each environment
            local USER DOMAIN
            USER=$(jq -r ".environments[\"$env\"].user // empty" "$CONFIG_FILE" 2>/dev/null)
            DOMAIN=$(jq -r ".environments[\"$env\"].domain // empty" "$CONFIG_FILE" 2>/dev/null)
            
            if [[ -z "$USER" ]]; then
                critical "Missing required field 'user' for environment '$env' in configuration file: $CONFIG_FILE"
                return 1
            fi
            
            if [[ -z "$DOMAIN" ]]; then
                critical "Missing required field 'domain' for environment '$env' in configuration file: $CONFIG_FILE"
                return 1
            fi
            
            # Validate field formats
            if [[ ! "$USER" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                critical "Invalid user format for environment '$env': $USER (must contain only alphanumeric characters, underscores, and hyphens)"
                return 1
            fi
            
            # Basic domain validation
            if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]]; then
                critical "Invalid domain format for environment '$env': $DOMAIN"
                return 1
            fi
            
            # Validate serviceRoot if present
            local SERVICE_ROOT
            SERVICE_ROOT=$(jq -r ".environments[\"$env\"].serviceRoot // empty" "$CONFIG_FILE" 2>/dev/null)
            if [[ -n "$SERVICE_ROOT" && ! "$SERVICE_ROOT" =~ ^/.* ]]; then
                critical "Invalid serviceRoot for environment '$env': $SERVICE_ROOT (must be an absolute path starting with /)"
                return 1
            fi
        fi
    done <<< "$ENV_NAMES"
    
    return 0
}

function loadJsonConfig() {
    local CONFIG_FILE="$1"
    
    # Clear existing configuration
    unset JSON_DEPLOY_ENVS
    declare -gA JSON_DEPLOY_ENVS
    unset JSON_DEPLOY_ENVS_ORDER
    declare -ga JSON_DEPLOY_ENVS_ORDER
    
    # Validate configuration first
    if ! validateJsonConfig "$CONFIG_FILE"; then
        return 1
    fi
    
    # Load environment configurations
    local ENV_NAMES
    ENV_NAMES=$(jq -r '.environments | keys[]' "$CONFIG_FILE" 2>/dev/null)
    
    while IFS= read -r env; do
        if [[ -n "$env" ]]; then
            # Sanitize environment name for variable storage
            local SANITIZED_ENV
            SANITIZED_ENV=$(sanitizeName "$env")

            local USER DOMAIN SERVICE_ROOT TEAMS_WEBHOOK_URL SHARED_DIRECTORIES SHARED_FILES

            # Extract configuration values with defaults
            USER=$(jq -r ".environments[\"$env\"].user" "$CONFIG_FILE" 2>/dev/null)
            DOMAIN=$(jq -r ".environments[\"$env\"].domain" "$CONFIG_FILE" 2>/dev/null)
            SERVICE_ROOT=$(jq -r ".environments[\"$env\"].serviceRoot // \"/var/www/html\"" "$CONFIG_FILE" 2>/dev/null)
            TEAMS_WEBHOOK_URL=$(jq -r ".environments[\"$env\"].teamsWebhookUrl // empty" "$CONFIG_FILE" 2>/dev/null)

            # Extract shared paths arrays
            SHARED_DIRECTORIES=$(jq -r ".environments[\"$env\"].sharedDirectories // [] | join(\",\")" "$CONFIG_FILE" 2>/dev/null)
            SHARED_FILES=$(jq -r ".environments[\"$env\"].sharedFiles // [] | join(\",\")" "$CONFIG_FILE" 2>/dev/null)

            # Extract COPS integration setting
            COPS_INTEGRATION=$(jq -r ".environments[\"$env\"].copsIntegration // false" "$CONFIG_FILE" 2>/dev/null)

            # Store using sanitized name for internal processing
            JSON_DEPLOY_ENVS["$SANITIZED_ENV"]="USER=$USER DOMAIN=$DOMAIN SERVICE_ROOT=$SERVICE_ROOT TEAMS_WEBHOOK_URL=$TEAMS_WEBHOOK_URL COPS_INTEGRATION=$COPS_INTEGRATION SHARED_DIRECTORIES=$SHARED_DIRECTORIES SHARED_FILES=$SHARED_FILES"
            # Also store original name mapping
            JSON_DEPLOY_ENVS["${SANITIZED_ENV}_ORIGINAL"]="$env"
        fi
    done <<< "$ENV_NAMES"
    
    # Load environment order if specified
    if jq -e '.environmentOrder' "$CONFIG_FILE" >/dev/null 2>&1; then
        local ORDER_ITEMS
        ORDER_ITEMS=$(jq -r '.environmentOrder[]' "$CONFIG_FILE" 2>/dev/null)
        while IFS= read -r env; do
            if [[ -n "$env" ]]; then
                JSON_DEPLOY_ENVS_ORDER+=("$env")
            fi
        done <<< "$ORDER_ITEMS"
    else
        # Use alphabetical order if no order specified
        mapfile -t JSON_DEPLOY_ENVS_ORDER < <(printf '%s\n' "${!JSON_DEPLOY_ENVS[@]}" | sort)
    fi
    
    return 0
}

function getJsonConfigValue() {
    local CONFIG_FILE="$1"
    local JSON_PATH="$2"
    local DEFAULT_VALUE="$3"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "$DEFAULT_VALUE"
        return 1
    fi
    
    local VALUE
    VALUE=$(jq -r "$JSON_PATH // empty" "$CONFIG_FILE" 2>/dev/null)
    
    if [[ -z "$VALUE" || "$VALUE" == "null" ]]; then
        echo "$DEFAULT_VALUE"
    else
        echo "$VALUE"
    fi
}

function getJsonConfigFile() {
    local PROJECT_DIR="$1"

    # Check for .docker-control directory first, then fallback to project root
    if [[ -f "$PROJECT_DIR/htdocs/.docker-control/.deploy.json" ]] && [[ -r "$PROJECT_DIR/htdocs/.docker-control/.deploy.json" ]]; then
        echo "$PROJECT_DIR/htdocs/.docker-control/.deploy.json"
        return 0
    elif [[ -f "$PROJECT_DIR/.deploy.json" ]]; then
        echo "$PROJECT_DIR/.deploy.json"
        return 0
    else
        return 1
    fi
}

function createJsonConfig() {
    local CONFIG_FILE="$1"
    local CREATED_AT
    CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Create initial JSON configuration structure
    cat > "$CONFIG_FILE" << EOF
{
  "version": "1.0",
  "environments": {},
  "environmentOrder": [],
  "defaults": {
    "serviceRoot": "/var/www/html",
    "domainSuffix": ".projects.interligent.com"
  },
  "metadata": {
    "createdAt": "$CREATED_AT",
    "lastModified": "$CREATED_AT",
    "createdBy": "docker-control-plugin"
  }
}
EOF

    if [[ -f "$CONFIG_FILE" ]]; then
        return 0
    else
        critical "Failed to create JSON configuration file: $CONFIG_FILE"
        return 1
    fi
}

function addJsonEnvironment() {
    local CONFIG_FILE="$1"
    local ENV_NAME="$2"
    local USER="$3"
    local DOMAIN="$4"
    local SERVICE_ROOT="$5"
    local DESCRIPTION="$6"
    local TEAMS_WEBHOOK_URL="$7"
    local COPS_INTEGRATION="$8"
    local -n SHARED_DIRECTORIES_REF=$9
    local -n SHARED_FILES_REF=${10}

    # Validate inputs
    if [[ -z "$ENV_NAME" || -z "$USER" || -z "$DOMAIN" ]]; then
        critical "Missing required parameters for environment configuration"
        return 1
    fi

    # Set defaults
    if [[ -z "$SERVICE_ROOT" ]]; then
        SERVICE_ROOT="/var/www/html"
    fi

    if [[ -z "$DESCRIPTION" ]]; then
        DESCRIPTION="Deployment environment: $ENV_NAME"
    fi

    # Get current timestamp
    local MODIFIED_AT
    MODIFIED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Create temporary file for atomic update
    local TEMP_FILE
    TEMP_FILE=$(mktemp)

    # Build shared directories and files arrays
    local SHARED_DIRS_JSON="[]"
    local SHARED_FILES_JSON="[]"

    if [[ ${#SHARED_DIRECTORIES_REF[@]} -gt 0 ]]; then
        SHARED_DIRS_JSON=$(printf '%s\n' "${SHARED_DIRECTORIES_REF[@]}" | jq -R . | jq -s .)
    fi

    if [[ ${#SHARED_FILES_REF[@]} -gt 0 ]]; then
        SHARED_FILES_JSON=$(printf '%s\n' "${SHARED_FILES_REF[@]}" | jq -R . | jq -s .)
    fi

    # Convert COPS integration to boolean
    local COPS_INTEGRATION_BOOL="false"
    if [[ "$COPS_INTEGRATION" == "y" ]]; then
        COPS_INTEGRATION_BOOL="true"
    fi

    # Build the new environment object
    local ENV_OBJECT
    ENV_OBJECT=$(jq -n \
        --arg user "$USER" \
        --arg domain "$DOMAIN" \
        --arg serviceRoot "$SERVICE_ROOT" \
        --arg description "$DESCRIPTION" \
        --arg teamsWebhookUrl "$TEAMS_WEBHOOK_URL" \
        --argjson copsIntegration "$COPS_INTEGRATION_BOOL" \
        --argjson sharedDirectories "$SHARED_DIRS_JSON" \
        --argjson sharedFiles "$SHARED_FILES_JSON" \
        '{
            user: $user,
            domain: $domain,
            serviceRoot: $serviceRoot,
            description: $description,
            teamsWebhookUrl: $teamsWebhookUrl,
            copsIntegration: $copsIntegration,
            sharedDirectories: $sharedDirectories,
            sharedFiles: $sharedFiles
        }' | jq 'with_entries(select(.value != "" and .value != null and .value != []))')

    # Update the configuration file
    if jq \
        --arg env "$ENV_NAME" \
        --argjson envObj "$ENV_OBJECT" \
        --arg modifiedAt "$MODIFIED_AT" \
        '.environments[$env] = $envObj |
         .environmentOrder |= (if . | index($env) then . else . + [$env] end) |
         .metadata.lastModified = $modifiedAt' \
        "$CONFIG_FILE" > "$TEMP_FILE"; then

        mv "$TEMP_FILE" "$CONFIG_FILE"
        return 0
    else
        rm -f "$TEMP_FILE"
        critical "Failed to add environment '$ENV_NAME' to configuration file: $CONFIG_FILE"
        return 1
    fi
}

function removeJsonEnvironment() {
    local CONFIG_FILE="$1"
    local ENV_NAME="$2"

    if [[ -z "$ENV_NAME" ]]; then
        critical "Environment name is required"
        return 1
    fi

    # Get current timestamp
    local MODIFIED_AT
    MODIFIED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Create temporary file for atomic update
    local TEMP_FILE
    TEMP_FILE=$(mktemp)

    # Remove the environment
    if jq \
        --arg env "$ENV_NAME" \
        --arg modifiedAt "$MODIFIED_AT" \
        'del(.environments[$env]) |
         .environmentOrder |= map(select(. != $env)) |
         .metadata.lastModified = $modifiedAt' \
        "$CONFIG_FILE" > "$TEMP_FILE"; then

        mv "$TEMP_FILE" "$CONFIG_FILE"
        return 0
    else
        rm -f "$TEMP_FILE"
        critical "Failed to remove environment '$ENV_NAME' from configuration file: $CONFIG_FILE"
        return 1
    fi
}

function updateJsonEnvironment() {
    local CONFIG_FILE="$1"
    local ENV_NAME="$2"
    local FIELD="$3"
    local VALUE="$4"

    if [[ -z "$ENV_NAME" || -z "$FIELD" ]]; then
        critical "Environment name and field are required"
        return 1
    fi

    # Get current timestamp
    local MODIFIED_AT
    MODIFIED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Create temporary file for atomic update
    local TEMP_FILE
    TEMP_FILE=$(mktemp)

    # Handle field values
    local JSON_VALUE="\"$VALUE\""

    # Update the specific field
    if jq \
        --arg env "$ENV_NAME" \
        --arg field "$FIELD" \
        --argjson value "$JSON_VALUE" \
        --arg modifiedAt "$MODIFIED_AT" \
        '.environments[$env][$field] = $value |
         .metadata.lastModified = $modifiedAt' \
        "$CONFIG_FILE" > "$TEMP_FILE"; then

        mv "$TEMP_FILE" "$CONFIG_FILE"
        return 0
    else
        rm -f "$TEMP_FILE"
        critical "Failed to update field '$FIELD' for environment '$ENV_NAME' in configuration file: $CONFIG_FILE"
        return 1
    fi
}


