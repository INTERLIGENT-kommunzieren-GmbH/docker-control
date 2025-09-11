#!/bin/bash

# Source JSON configuration functions
. "$LIB_DIR/json-config-functions.sh"

function _addDeployConfig() {
    # Check for existing JSON configuration file
    local CONFIG_FILE
    CONFIG_FILE=$(getJsonConfigFile "$PROJECT_DIR" 2>/dev/null)

    if [[ -n "$CONFIG_FILE" ]]; then
        # JSON configuration exists, add to it
        addJsonDeployConfig "$CONFIG_FILE"
    else
        # No configuration exists, create new JSON configuration
        createJsonDeployConfig
    fi
}

function checkDir() {
    if [[ ! -f "$PROJECT_DIR"/.managed-by-docker-control-plugin ]]; then
        critical "$PROJECT_DIR not managed by docker control plugin"
        exit 1
    fi
}

function _createControlScript {
    local COMMAND=$1
    local CONTROL_SCRIPTS_DIR

    # Check for .docker-control directory first, fallback to legacy location
    if [[ -d "$PROJECT_DIR/htdocs/.docker-control/control-scripts" ]]; then
        CONTROL_SCRIPTS_DIR="$PROJECT_DIR/htdocs/.docker-control/control-scripts"
        # Ensure the directory is accessible
        if [[ ! -w "$CONTROL_SCRIPTS_DIR" ]]; then
            critical "Directory $CONTROL_SCRIPTS_DIR exists but is not writable"
            exit 1
        fi
    else
        CONTROL_SCRIPTS_DIR="$PROJECT_DIR/control-scripts"
        # Create legacy directory if it doesn't exist
        if ! mkdir -p "$CONTROL_SCRIPTS_DIR"; then
            critical "Failed to create control scripts directory: $CONTROL_SCRIPTS_DIR"
            exit 1
        fi
    fi

    if [[ -f "${CONTROL_SCRIPTS_DIR}/${COMMAND}.sh" ]]; then
        critical "command '$COMMAND' already exists in $CONTROL_SCRIPTS_DIR"
        exit 1
    else
        cat << EOF | tee "$CONTROL_SCRIPTS_DIR/${COMMAND}.sh" 1>/dev/null
#!/bin/bash
set -e

. "\$LIB_DIR/util-functions.sh"

if [[ "\$1" == "_desc_" ]]; then
    # output command description
    echo "EMPTY DESCRIPTION"

    exit 0
fi

info "WAITING FOR IMPLEMENTATION"

exit 0
EOF
        chmod u+x "$CONTROL_SCRIPTS_DIR/${COMMAND}.sh"

        text 'command {{ Foreground "14" "'"$COMMAND"'"}} created under {{ Foreground "14" "'"$CONTROL_SCRIPTS_DIR"'"}}'
    fi
}

function _createNewRelease() {
    local CREATED_RELEASE

    sub_headline "create new release"
    newline

    # Call the enhanced gitCreateRelease workflow (no parameters needed)
    if gitCreateRelease; then
        # Get the created release from REPLY variable
        CREATED_RELEASE="$REPLY"

        if [[ -n "$CREATED_RELEASE" ]]; then
            newline
            info "Successfully created release: $CREATED_RELEASE"
            text 'Release {{ Foreground "14" "'"$CREATED_RELEASE"'"}} has been created and is ready for use'
        else
            warning "Release creation completed but no release name was returned"
        fi
    else
        critical "Failed to create release"
        exit 1
    fi
}

function _console() {
    local SERVICE="$1"
    if [[ -z "$SERVICE" ]]; then
        SERVICE=$(select_docker_service)
    fi

    if [[ "$SERVICE" == "help" ]]; then
        sub_headline "Available containers"
        for SERVICE in $(dockerCompose ps --services); do
            info "$SERVICE"
        done
        newline
    elif [[ "$SERVICE" == "php" ]]; then
        dockerCompose exec -itu www-data "$SERVICE" bash
    else
        dockerCompose exec "$SERVICE" bash
    fi
}

function _deploy() {
    local RELEASE
    local ENV="$1"

    sub_headline "Deploy to Environment"
    newline

    # Validate environment parameter first
    if [[ -z "$ENV" ]]; then
        critical "Environment parameter missing"
        newline
        text 'Usage: {{ Foreground "14" "docker control deploy <environment>" }}'
        newline
        text 'Example: {{ Foreground "14" "docker control deploy production" }}'
        exit 1
    fi

    # Load deployment configuration
    local CONFIG_FILE

    if [[ -z "$DEPLOY_ENVS" && -z "$JSON_DEPLOY_ENVS" ]]; then
        CONFIG_FILE=$(getJsonConfigFile "$PROJECT_DIR" 2>/dev/null)

        if [[ -z "$CONFIG_FILE" ]]; then
            info "No deployment configuration found. Creating one..."
            createJsonDeployConfig
            # Get the config file path after creation
            CONFIG_FILE=$(getJsonConfigFile "$PROJECT_DIR")
            if [[ -z "$CONFIG_FILE" ]]; then
                critical "Failed to locate created configuration file"
                exit 1
            fi
        fi

        if ! loadJsonConfig "$CONFIG_FILE"; then
            critical "Failed to load JSON deployment configuration from $CONFIG_FILE"
            critical "The configuration file may be malformed"
            exit 1
        fi

        # Copy JSON config to legacy format for compatibility with existing deployment code
        declare -gA DEPLOY_ENVS
        for env in "${!JSON_DEPLOY_ENVS[@]}"; do
            DEPLOY_ENVS["$env"]="${JSON_DEPLOY_ENVS[$env]}"
        done
    fi

    # Validate that configuration was loaded properly
    if [[ -z "$DEPLOY_ENVS" ]]; then
        critical "Deployment configuration is empty or malformed"
        critical "Please check $CONFIG_FILE"
        exit 1
    fi

    # Check if the specified environment exists
    if [[ -z "${DEPLOY_ENVS[$ENV]+set}" ]]; then
        critical "Environment '$ENV' is not configured"
        newline
        if [[ ${#DEPLOY_ENVS[@]} -gt 0 ]]; then
            text 'The following environments are configured: {{ Foreground "14" "'"${!DEPLOY_ENVS[*]}"'"}}'
        else
            text 'No environments are currently configured. Use {{ Foreground "14" "docker control add-deploy-config" }} to add one.'
        fi
        exit 1
    fi

    info "Deploying to environment: $ENV"
    newline

    # Load environment-specific configuration
    local BRANCH
    local USER
    local DOMAIN
    local SERVICE_ROOT

    # Evaluate the environment configuration with error handling
    if ! eval "${DEPLOY_ENVS[$ENV]}"; then
        critical "Failed to load configuration for environment '$ENV'"
        critical "The environment configuration may be malformed"
        exit 1
    fi

    # Validate required configuration variables
    if [[ -z "$USER" ]]; then
        critical "USER not configured for environment '$ENV'"
        exit 1
    fi

    if [[ -z "$DOMAIN" ]]; then
        critical "DOMAIN not configured for environment '$ENV'"
        exit 1
    fi

    if [[ -z "$SERVICE_ROOT" ]]; then
        warning "SERVICE_ROOT not configured for environment '$ENV', using default: /var/www/html"
        SERVICE_ROOT="/var/www/html"
    fi

    info "Configuration loaded:"
    text "  • User: {{ Foreground \"14\" \"$USER\" }}"
    text "  • Domain: {{ Foreground \"14\" \"$DOMAIN\" }}"
    text "  • Service Root: {{ Foreground \"14\" \"$SERVICE_ROOT\" }}"
    if [[ -n "$BRANCH" ]]; then
        text "  • Default Branch: {{ Foreground \"14\" \"$BRANCH\" }}"
    fi
    newline

    # Select release/tag for deployment
    info "Selecting release for deployment..."
    RELEASE=$(select_release_tag)

    # Check if release selection was successful
    if [[ $? -ne 0 ]] || [[ -z "$RELEASE" ]]; then
        critical "Failed to select release for deployment"
        exit 1
    fi

    info "Selected release: $RELEASE"
    newline

    # Confirm deployment
    if [[ $(confirm "Proceed with deployment of '$RELEASE' to '$ENV' environment?") != "y" ]]; then
        info "Deployment cancelled"
        exit 0
    fi

    # Execute deployment with error handling
    info "Starting deployment..."
    if deploy "$ENV" "$USER" "$DOMAIN" "$SERVICE_ROOT" "$RELEASE"; then
        newline
        info "Deployment completed successfully!"
        text 'Release {{ Foreground "14" "'"$RELEASE"'"}} has been deployed to {{ Foreground "14" "'"$ENV"'"}} environment'
    else
        critical "Deployment failed"
        exit 1
    fi
}

function _showRunningProjects() {
    (
      echo "PROJECT DIRECTORY"
      docker ps -a \
        --filter 'label=com.interligent.dockerplugin.project' \
        --filter 'label=com.interligent.dockerplugin.dir' \
        --format '{{.ID}}' \
      | xargs -I {} docker inspect \
          --format '{{ index .Config.Labels "com.interligent.dockerplugin.project" }} {{ index .Config.Labels "com.interligent.dockerplugin.dir" }}' {} \
      | sort -u
    ) | column -t
}

function addDeployConfig() {
    local ENV
    input -n -l "environment" -r ENV

    local BRANCH
    input -l "branch" -d "env/$ENV" -r BRANCH

    local USER
    input -n -l "user" -r USER
    local DOMAIN
    input -n -l "domain" -d "$USER.projects.interligent.com" -r DOMAIN
    input -n -l "server root" -d "/var/www/html" -r SERVICE_ROOT

    cat <<EOF | tee -a "$PROJECT_DIR/.deploy.conf" 1>/dev/null
DEPLOY_ENVS["$ENV"]="BRANCH=$BRANCH USER=$USER DOMAIN=$DOMAIN SERVICE_ROOT=$SERVICE_ROOT"
DEPLOY_ENVS_ORDER+=("$ENV")

EOF
}

function createDeployConfig() {
    cat <<EOF | tee "$PROJECT_DIR/.deploy.conf" 1>/dev/null
declare -A DEPLOY_ENVS
declare -A DEPLOY_ENVS_ORDER

EOF
    addDeployConfig
}

function createJsonDeployConfig() {
    local CONFIG_FILE

    # Check for .docker-control directory first, fallback to project root
    if [[ -d "$PROJECT_DIR/htdocs/.docker-control" ]]; then
        CONFIG_FILE="$PROJECT_DIR/htdocs/.docker-control/.deploy.json"
        # Ensure the directory is accessible
        if [[ ! -w "$PROJECT_DIR/htdocs/.docker-control" ]]; then
            critical "Directory $PROJECT_DIR/htdocs/.docker-control exists but is not writable"
            exit 1
        fi
    else
        CONFIG_FILE="$PROJECT_DIR/.deploy.json"
    fi

    info "Creating JSON deployment configuration at $CONFIG_FILE..."

    if ! createJsonConfig "$CONFIG_FILE"; then
        critical "Failed to create JSON deployment configuration"
        exit 1
    fi

    addJsonDeployConfig "$CONFIG_FILE"
}

function addJsonDeployConfig() {
    local CONFIG_FILE="$1"

    # If no config file specified, determine the appropriate location
    if [[ -z "$CONFIG_FILE" ]]; then
        CONFIG_FILE=$(getJsonConfigFile "$PROJECT_DIR" 2>/dev/null)
        if [[ -z "$CONFIG_FILE" ]]; then
            critical "No JSON configuration file found"
            exit 1
        fi
    fi

    local ENV
    input -n -l "environment" -r ENV

    local BRANCH
    input -l "branch" -d "env/$ENV" -r BRANCH

    local USER
    input -n -l "user" -r USER
    local DOMAIN
    input -n -l "domain" -d "$USER.projects.interligent.com" -r DOMAIN
    local SERVICE_ROOT
    input -n -l "server root" -d "/var/www/html" -r SERVICE_ROOT

    local DESCRIPTION
    input -l "description (optional)" -d "Deployment environment: $ENV" -r DESCRIPTION

    if ! addJsonEnvironment "$CONFIG_FILE" "$ENV" "$BRANCH" "$USER" "$DOMAIN" "$SERVICE_ROOT" "$DESCRIPTION"; then
        critical "Failed to add environment '$ENV' to JSON configuration"
        exit 1
    fi

    info "Environment '$ENV' added to JSON deployment configuration"
}

function dockerCompose() {
    docker compose --project-directory "$PROJECT_DIR" "$@"
}

function dockerComposeIngress() {
    docker compose --project-directory "$INGRESS_COMPOSE_DIR" -f "$INGRESS_COMPOSE_FILE" "$@"
}

function _help() {
    # shellcheck disable=SC2034
    local BASIC_COMMANDS=(
        $'console [container]\tEnter container console (defaults to php)'
        $'deploy <env>\tDeploy selected release to specified environment'
        $'help\tShow this help and project status'
        $'init\tInitialize empty directory with project template'
        $'merge\tMerge release branch to main using cherry-pick'
        $'release\tCreate new release branch with automated versioning'
        $'restart\tRestart project containers (stop and start)'
        $'start\tStart project containers'
        $'stop\tStop project containers'
        $'version\tShow version information'
    )
    # shellcheck disable=SC2034
    local ADVANCED_COMMANDS=(
        $'add-deploy-config\tAdd deployment configuration for environments'
        $'create-control-script <name>\tCreate a custom control script'
        $'install-plugin\tInstall Docker CLI plugin system-wide'
        $'pull\tPull latest Docker images for project containers'
        $'pull-ingress\tPull latest ingress-related Docker images'
        $'restart-ingress\tRestart ingress containers (stop and start)'
        $'show-running\tShow all running Docker projects'
        $'start-ingress\tStart ingress containers'
        $'status\tShow status of project containers'
        $'status-ingress\tShow status of ingress containers'
        $'stop-ingress\tStop ingress containers'
        $'update\tUpdate project with current template and restart'
        $'update-plugin\tUpdate Docker plugin to latest version'
    )
    local OPTIONS
    # shellcheck disable=SC2034
    OPTIONS=(
        $'-d|--dir\tProject directory (default: current directory)'
    )

    headline "IK Docker Control $SERVICE"
    newline

    printHelp "Options" OPTIONS
    printHelp "Basic Usage" BASIC_COMMANDS
    printHelp "Advanced Usage" ADVANCED_COMMANDS

    # Check for control scripts in .docker-control directory first, then fallback to legacy location
    local CONTROL_SCRIPTS_DIR=""
    if [[ -d "$PROJECT_DIR/htdocs/.docker-control/control-scripts" ]] && [[ -r "$PROJECT_DIR/htdocs/.docker-control/control-scripts" ]] && ls "$PROJECT_DIR/htdocs/.docker-control/control-scripts"/*.sh 1> /dev/null 2>&1; then
        CONTROL_SCRIPTS_DIR="$PROJECT_DIR/htdocs/.docker-control/control-scripts"
    elif [[ -d "$PROJECT_DIR/control-scripts" ]] && [[ -r "$PROJECT_DIR/control-scripts" ]] && ls "$PROJECT_DIR"/control-scripts/*.sh 1> /dev/null 2>&1; then
        CONTROL_SCRIPTS_DIR="$PROJECT_DIR/control-scripts"
    fi

    if [[ -n "$CONTROL_SCRIPTS_DIR" ]]; then
        local SUB_COMMANDS=()
        local COMMAND
        local TAB=$'\t'

        for COMMAND in "$CONTROL_SCRIPTS_DIR"/*.sh; do
            SUB_COMMANDS+=( "$(basename "$COMMAND" .sh)${TAB}$(LIB_DIR="$LIB_DIR" "$COMMAND" _desc_)" )
        done

        printHelp "Custom Commands" SUB_COMMANDS
    fi

    # Add project status information
    _showProjectStatus
}

function _showProjectStatus() {
    local PAD=" "  # Changed from "    " to "  " to match printHelp's 2-space padding
    sub_headline "Project Status"

    # Project Directory Information
    text "${PAD}Project Directory: {{ Foreground \"14\" \"$PROJECT_DIR\" }}"

    # Check if project is managed by docker control plugin
    if [[ -f "$PROJECT_DIR/.managed-by-docker-control-plugin" ]]; then
        text "${PAD}Plugin Management: {{ Foreground \"10\" \"✓ Managed by Docker Control Plugin\" }}"
    else
        text "${PAD}Plugin Management: {{ Foreground \"11\" \"✗ Not managed by Docker Control Plugin\" }}"
        text "${PAD}  Run {{ Foreground \"14\" \"docker control init\" }} to initialize this directory"
    fi

    # Git Repository Status
    _showGitStatus "$PAD"

    # Deployment Configuration Status
    _showDeploymentStatus "$PAD"

    # Docker Status
    _showDockerStatus "$PAD"

    newline
}

function _showGitStatus() {
    local PAD="$1"
    local GIT_STATUS=""
    local CURRENT_BRANCH=""
    local GIT_REMOTE=""

    if [[ -d "$PROJECT_DIR/htdocs/.git" ]]; then
        # Get current branch
        if CURRENT_BRANCH=$(git -C "$PROJECT_DIR/htdocs" branch --show-current 2>/dev/null); then
            if [[ -n "$CURRENT_BRANCH" ]]; then
                GIT_STATUS="on branch {{ Foreground \"14\" \"$CURRENT_BRANCH\" }}"

                # Check if there are uncommitted changes
                if ! git -C "$PROJECT_DIR/htdocs" diff-index --quiet HEAD -- 2>/dev/null; then
                    GIT_STATUS="$GIT_STATUS {{ Foreground \"11\" \"(uncommitted changes)\" }}"
                fi

                # Check for remote tracking
                if GIT_REMOTE=$(git -C "$PROJECT_DIR/htdocs" config --get "branch.$CURRENT_BRANCH.remote" 2>/dev/null); then
                    GIT_STATUS="$GIT_STATUS, tracking {{ Foreground \"14\" \"$GIT_REMOTE\" }}"
                fi
            else
                GIT_STATUS="{{ Foreground \"11\" \"detached HEAD\" }}"
            fi
        else
            GIT_STATUS="{{ Foreground \"11\" \"unknown state\" }}"
        fi
        text "${PAD}Git Repository: {{ Foreground \"10\" \"✓ Initialized\" }} ($GIT_STATUS)"
    else
        text "${PAD}Git Repository: {{ Foreground \"11\" \"✗ Not a git repository\" }}"
        text "${PAD}  Initialize with {{ Foreground \"14\" \"git init\" }} in the htdocs directory"
    fi
}

function _showDeploymentStatus() {
    local PAD="$1"
    local CONFIG_FILE
    CONFIG_FILE=$(getJsonConfigFile "$PROJECT_DIR" 2>/dev/null)

    if [[ -n "$CONFIG_FILE" ]]; then
        text "${PAD}Deployment Config: {{ Foreground \"10\" \"✓ Configured (JSON)\" }}"

        # Load deployment configuration to show environments
        local DEPLOY_ENVS_LOCAL=()
        local CONFIG_VALID=false

        if loadJsonConfig "$CONFIG_FILE" 2>/dev/null && [[ -n "$JSON_DEPLOY_ENVS" ]]; then
            DEPLOY_ENVS_LOCAL=("${!JSON_DEPLOY_ENVS[@]}")
            CONFIG_VALID=true
        fi

        if [[ "$CONFIG_VALID" == "true" ]]; then
            if [[ ${#DEPLOY_ENVS_LOCAL[@]} -gt 0 ]]; then
                text "${PAD}  Environments: {{ Foreground \"14\" \"${DEPLOY_ENVS_LOCAL[*]}\" }}"
                text "${PAD}  Configuration file: {{ Foreground \"14\" \"$(basename "$CONFIG_FILE")\" }}"
            else
                text "${PAD}  {{ Foreground \"11\" \"No environments configured\" }}"
            fi
        else
            text "${PAD}  {{ Foreground \"11\" \"Configuration file exists but is malformed\" }}"
        fi
    else
        text "${PAD}Deployment Config: {{ Foreground \"11\" \"✗ Not configured\" }}"
        text "${PAD}  Run {{ Foreground \"14\" \"docker control add-deploy-config\" }} to add deployment environments"
    fi
}

function _showDockerStatus() {
    local PAD="$1"
    local CONTAINER_COUNT=0
    local RUNNING_COUNT=0
    local PROJECT_CONTAINERS=""

    # Check if Docker is available
    if ! command -v docker &> /dev/null; then
        text "${PAD}Docker Status: {{ Foreground \"11\" \"✗ Docker not available\" }}"
        return
    fi

    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        text "${PAD}Docker Status: {{ Foreground \"11\" \"✗ Docker daemon not running\" }}"
        return
    fi

    # Get project containers
    if PROJECT_CONTAINERS=$(docker ps -a --filter "label=com.interligent.dockerplugin.dir=$PROJECT_DIR" --format "{{.Names}}\t{{.Status}}" 2>/dev/null); then
        if [[ -n "$PROJECT_CONTAINERS" ]]; then
            CONTAINER_COUNT=$(echo "$PROJECT_CONTAINERS" | wc -l)
            RUNNING_COUNT=$(echo "$PROJECT_CONTAINERS" | grep -c "Up" || true)

            if [[ $RUNNING_COUNT -gt 0 ]]; then
                text "${PAD}Docker Status: {{ Foreground \"10\" \"✓ $RUNNING_COUNT/$CONTAINER_COUNT containers running\" }}"
            else
                text "${PAD}Docker Status: {{ Foreground \"11\" \"○ $CONTAINER_COUNT containers stopped\" }}"
                text "${PAD}  Run {{ Foreground \"14\" \"docker control start\" }} to start containers"
            fi
        else
            text "${PAD}Docker Status: {{ Foreground \"11\" \"○ No project containers found\" }}"
            text "${PAD}  Run {{ Foreground \"14\" \"docker control start\" }} to create and start containers"
        fi
    else
        text "${PAD}Docker Status: {{ Foreground \"11\" \"✗ Unable to query container status\" }}"
    fi
}

function _init() {
    info "Creating project template"
    cp -r "$TEMPLATE_DIR"/. "$PROJECT_DIR/"
    mv "$PROJECT_DIR/.gitignore-dist" "$PROJECT_DIR/.gitignore"
    mkdir "$PROJECT_DIR/htdocs"

    local PROJECT_NAME
    PROJECT_NAME=$(input -n -l "Project name")
    local PHP_VERSION
    PHP_VERSION=$(select_php_version)
    local DB_HOST_PORT=""

    for i in {33060..33099}; do
        DB_HOST_PORT=$i
        DB_HOST_PORT_IN_USE=$(nc -zv host.docker.internal "$DB_HOST_PORT" 2>/dev/null && echo "yes" || echo "no")
        if [ "$DB_HOST_PORT_IN_USE" == "no" ]; then
            break
        fi
        info "Automatically selected DB_HOST_PORT $DB_HOST_PORT as it seems to be free. Please verify it and adjust accordingly in .env file."
    done
    if [ -z "$DB_HOST_PORT" ]; then
        critical "No empty port found between 33060 and 33099 for external database connection, please select one manually and update your .env file."
        newline
    fi

    cat << EOF | tee "$PROJECT_DIR/.env" 1>/dev/null
BASE_DOMAIN=${PROJECT_NAME}.lvh.me
ENVIRONMENT=development
DB_HOST_PORT=${DB_HOST_PORT}
PHP_VERSION=${PHP_VERSION}
PROJECTNAME=${PROJECT_NAME}
XDEBUG_IP=host.docker.internal
IDE_KEY=${PROJECT_NAME}.lvh.me
EOF

    local CHECKOUT_PROJECT
    CHECKOUT_PROJECT=$(confirm -n "Do you want to checkout a project into htdocs folder?")
    if [ "$CHECKOUT_PROJECT" == "y" ]; then
        local PROJECT_GIT_URL
        PROJECT_GIT_URL=$(input -p "clone url (use ssh link)" -n)
        git checkout "$PROJECT_GIT_URL" "$PROJECT_DIR/htdocs"
    fi
}

function _install_plugin() {
    local DOCKER_CLI_PLUGIN_PATH="/cli-plugins"

    if [[ -f "$DOCKER_CLI_PLUGIN_PATH/docker-control" ]]; then
        info "Removing old plugin"
        rm "$DOCKER_CLI_PLUGIN_PATH/docker-control"
    fi

    info "Installing plugin"
    cp "$DIR/plugin/docker-control-wrapper-script" "$DOCKER_CLI_PLUGIN_PATH/docker-control"
    chmod 755 "$DOCKER_CLI_PLUGIN_PATH/docker-control"
    info "Installation successful. You can start using the plugin with: docker control help"
    exit
}


function _mergeReleaseToMain() {
    local RELEASE_BRANCH
    local TARGET_BRANCH
    local MERGE_BRANCH
    local COMMITS_TO_CHERRY_PICK
    local COMMIT_MESSAGE
    local CHOICE
    local RELEASE_WORKTREE_DIR
    local MERGE_WORKTREE_DIR

    sub_headline "Merge Release to Main"
    newline

    # Validate that we're in a Git repository
    if ! _git rev-parse --git-dir >/dev/null 2>&1; then
        critical "Not in a Git repository or Git repository not accessible"
        critical "Expected Git repository at: $PROJECT_DIR/htdocs"
        critical "Please ensure the Git repository exists and is accessible"
        exit 1
    fi

    # Get the release branch using existing function
    RELEASE_BRANCH=$(getLatestReleaseBranch)
    if [[ $? -ne 0 ]] || [[ -z "$RELEASE_BRANCH" ]]; then
        critical "Failed to select release branch"
        exit 1
    fi

    info "Selected release branch: $RELEASE_BRANCH"

    # Get the target branch using existing function
    TARGET_BRANCH=$(getPrimaryBranch)
    if [[ $? -ne 0 ]] || [[ -z "$TARGET_BRANCH" ]]; then
        critical "Failed to determine target branch"
        exit 1
    fi

    info "Target branch: $TARGET_BRANCH"

    # Create merge branch name following the convention: {source-branch-name}-merge
    MERGE_BRANCH="${RELEASE_BRANCH}-merge"
    info "Merge branch: $MERGE_BRANCH"
    newline

    # Pre-flight check: Ensure merge branch doesn't already exist
    info "Checking for existing merge branch..."
    local MERGE_BRANCH_EXISTS_LOCAL=false
    local MERGE_BRANCH_EXISTS_REMOTE=false

    # Check if merge branch exists locally
    if _git rev-parse --verify "$MERGE_BRANCH" >/dev/null 2>&1; then
        MERGE_BRANCH_EXISTS_LOCAL=true
    fi

    # Check if merge branch exists remotely
    if _git rev-parse --verify "origin/$MERGE_BRANCH" >/dev/null 2>&1; then
        MERGE_BRANCH_EXISTS_REMOTE=true
    fi

    # If merge branch exists anywhere, abort with instructions
    if [[ "$MERGE_BRANCH_EXISTS_LOCAL" == "true" ]] || [[ "$MERGE_BRANCH_EXISTS_REMOTE" == "true" ]]; then
        critical "Merge branch '$MERGE_BRANCH' already exists!"
        newline
        if [[ "$MERGE_BRANCH_EXISTS_LOCAL" == "true" ]] && [[ "$MERGE_BRANCH_EXISTS_REMOTE" == "true" ]]; then
            critical "The branch exists both locally and remotely."
        elif [[ "$MERGE_BRANCH_EXISTS_LOCAL" == "true" ]]; then
            critical "The branch exists locally."
        else
            critical "The branch exists remotely."
        fi
        newline
        critical "This indicates there may be a pending merge operation."
        critical "Please resolve this before proceeding:"
        newline
        text "Option 1: Complete the existing merge"
        text "  - Check the existing merge branch for pending changes"
        text "  - Create a merge/pull request if not already done"
        text "  - Merge or close the existing request"
        newline
        text "Option 2: Delete the existing merge branch"
        if [[ "$MERGE_BRANCH_EXISTS_LOCAL" == "true" ]]; then
            text "  - Delete local branch: git branch -D $MERGE_BRANCH"
        fi
        if [[ "$MERGE_BRANCH_EXISTS_REMOTE" == "true" ]]; then
            text "  - Delete remote branch: git push origin --delete $MERGE_BRANCH"
        fi
        newline
        critical "Operation aborted to prevent conflicts."
        exit 1
    fi

    info "✓ No existing merge branch found. Safe to proceed."
    newline

    # Set up worktree directories
    RELEASE_WORKTREE_DIR="$PROJECT_DIR/releases/$RELEASE_BRANCH"
    MERGE_WORKTREE_DIR="$PROJECT_DIR/releases/$MERGE_BRANCH"

    info "Using separate worktrees for source and merge branches"
    info "Release worktree: $RELEASE_WORKTREE_DIR"
    info "Merge worktree: $MERGE_WORKTREE_DIR"

    # Create releases directory if it doesn't exist
    mkdir -p "$PROJECT_DIR/releases"

    # Create worktree for release branch
    # First check if the branch exists locally, if not, track it from origin
    if ! _git rev-parse --verify "$RELEASE_BRANCH" >/dev/null 2>&1; then
        if _git rev-parse --verify "origin/$RELEASE_BRANCH" >/dev/null 2>&1; then
            info "Creating local tracking branch for $RELEASE_BRANCH"
            _git branch "$RELEASE_BRANCH" "origin/$RELEASE_BRANCH"
        else
            critical "Release branch $RELEASE_BRANCH not found locally or on origin"
            exit 1
        fi
    fi

    if ! _git worktree add "$RELEASE_WORKTREE_DIR" "$RELEASE_BRANCH"; then
        critical "Error: Failed to create release worktree for $RELEASE_BRANCH"
        exit 1
    fi

    # Pull latest changes in release worktree to ensure we have the most current state
    info "Updating release worktree with latest changes from origin/$RELEASE_BRANCH"
    if ! git -C "$RELEASE_WORKTREE_DIR" pull origin "$RELEASE_BRANCH"; then
        critical "Failed to pull latest changes for release branch $RELEASE_BRANCH"
        # Clean up release worktree
        if ! _git worktree remove "$RELEASE_WORKTREE_DIR" --force; then
            warning "Could not remove release worktree automatically: $RELEASE_WORKTREE_DIR"
        fi
        exit 1
    fi

    # Ensure target branch exists locally and is up-to-date
    if ! _git rev-parse --verify "$TARGET_BRANCH" >/dev/null 2>&1; then
        if _git rev-parse --verify "origin/$TARGET_BRANCH" >/dev/null 2>&1; then
            info "Creating local tracking branch for $TARGET_BRANCH"
            _git branch "$TARGET_BRANCH" "origin/$TARGET_BRANCH"
        else
            critical "Target branch $TARGET_BRANCH not found locally or on origin"
            # Clean up release worktree
            if ! _git worktree remove "$RELEASE_WORKTREE_DIR" --force; then
                warning "Could not remove release worktree automatically: $RELEASE_WORKTREE_DIR"
            fi
            exit 1
        fi
    fi

    # Fetch latest changes for target branch
    info "Fetching latest changes for $TARGET_BRANCH"
    if ! _git fetch origin "$TARGET_BRANCH"; then
        critical "Failed to fetch latest changes for target branch $TARGET_BRANCH"
        # Clean up release worktree
        if ! _git worktree remove "$RELEASE_WORKTREE_DIR" --force; then
            warning "Could not remove release worktree automatically: $RELEASE_WORKTREE_DIR"
        fi
        exit 1
    fi

    # Create merge branch from target branch
    info "Creating merge branch $MERGE_BRANCH from $TARGET_BRANCH"
    if ! _git worktree add "$MERGE_WORKTREE_DIR" -b "$MERGE_BRANCH" "origin/$TARGET_BRANCH"; then
        critical "Error: Failed to create merge worktree for $MERGE_BRANCH"
        # Clean up release worktree
        if ! _git worktree remove "$RELEASE_WORKTREE_DIR" --force; then
            warning "Could not remove release worktree automatically: $RELEASE_WORKTREE_DIR"
        fi
        exit 1
    fi

    info "Both worktrees created successfully"

    # Get the current HEAD commits from both worktrees to ensure we're using the updated states
    local RELEASE_HEAD
    local TARGET_HEAD
    RELEASE_HEAD=$(git -C "$RELEASE_WORKTREE_DIR" rev-parse HEAD)
    TARGET_HEAD=$(git -C "$MERGE_WORKTREE_DIR" rev-parse HEAD)

    # Get commits that exist in release branch but not in target branch
    # Use the release worktree for commit analysis to ensure we're using the updated state
    local ALL_COMMITS_IN_RANGE
    ALL_COMMITS_IN_RANGE=$(git -C "$RELEASE_WORKTREE_DIR" log --reverse --pretty=format:"%H %s" "$TARGET_HEAD".."$RELEASE_HEAD" 2>/dev/null)

    # Filter out commits with "release:" prefix
    local ALL_COMMIT_HASHES
    mapfile -t ALL_COMMIT_HASHES < <(git -C "$RELEASE_WORKTREE_DIR" log --reverse --pretty=format:"%H" "$TARGET_HEAD".."$RELEASE_HEAD" 2>/dev/null)

    # Process each commit and build the filtered list
    local FILTERED_COMMITS=()
    for commit_hash in "${ALL_COMMIT_HASHES[@]}"; do
        if [[ -n "$commit_hash" ]]; then
            commit_msg=$(git -C "$RELEASE_WORKTREE_DIR" log -1 --pretty=format:"%s" "$commit_hash" 2>/dev/null)
            if [[ -n "$commit_msg" ]]; then
                if [[ ! "$commit_msg" =~ ^release: ]]; then
                    FILTERED_COMMITS+=("$commit_hash")
                fi
            else
                # Include commits with empty messages (they're not "release:" commits)
                FILTERED_COMMITS+=("$commit_hash")
            fi
        fi
    done

    # Convert array to newline-separated string
    COMMITS_TO_CHERRY_PICK=""
    if [[ ${#FILTERED_COMMITS[@]} -gt 0 ]]; then
        printf -v COMMITS_TO_CHERRY_PICK '%s\n' "${FILTERED_COMMITS[@]}"
        # Remove trailing newline
        COMMITS_TO_CHERRY_PICK="${COMMITS_TO_CHERRY_PICK%$'\n'}"
    fi

    # Check if we have any commits after filtering
    if [[ -z "$COMMITS_TO_CHERRY_PICK" ]]; then
        # Check if there were commits in the range but all were filtered out
        if [[ -n "$ALL_COMMITS_IN_RANGE" ]]; then
            warning "All commits in the range start with 'release:' prefix and have been filtered out."
            info "No commits to cherry-pick from $RELEASE_BRANCH to $MERGE_BRANCH"
        else
            info "No commits found in the range between $TARGET_BRANCH and $RELEASE_BRANCH"
            info "The branches may already be in sync, or $RELEASE_BRANCH may be behind $TARGET_BRANCH"
        fi
        # Clean up worktrees
        if ! _git worktree remove "$RELEASE_WORKTREE_DIR" --force; then
            warning "Could not remove release worktree automatically: $RELEASE_WORKTREE_DIR"
        fi
        if ! _git worktree remove "$MERGE_WORKTREE_DIR" --force; then
            warning "Could not remove merge worktree automatically: $MERGE_WORKTREE_DIR"
        fi
        return 0
    fi

    # Display commits that will be cherry-picked (only if we have commits)
    info "Found commits to cherry-pick into merge branch $MERGE_BRANCH:"
    echo "$COMMITS_TO_CHERRY_PICK" | while read -r commit_hash; do
        if [[ -n "$commit_hash" ]]; then
            commit_msg=$(git -C "$RELEASE_WORKTREE_DIR" log -1 --pretty=format:"%s" "$commit_hash")
            text "  • $commit_hash - $commit_msg"
        fi
    done
    newline

    # Confirm before proceeding (only if we have commits)
    if [[ $(confirm "Proceed with cherry-picking these commits into $MERGE_BRANCH?") != "y" ]]; then
        info "Cherry-pick operation cancelled"
        # Clean up worktrees
        if ! _git worktree remove "$RELEASE_WORKTREE_DIR" --force; then
            warning "Could not remove release worktree automatically: $RELEASE_WORKTREE_DIR"
        fi
        if ! _git worktree remove "$MERGE_WORKTREE_DIR" --force; then
            warning "Could not remove merge worktree automatically: $MERGE_WORKTREE_DIR"
        fi
        return 0
    fi

    # Cherry-pick each commit in the merge worktree
    local COMMIT_ARRAY
    mapfile -t COMMIT_ARRAY < <(echo "$COMMITS_TO_CHERRY_PICK")

    for commit_hash in "${COMMIT_ARRAY[@]}"; do
        if [[ -n "$commit_hash" ]]; then
            COMMIT_MESSAGE=$(git -C "$RELEASE_WORKTREE_DIR" log -1 --pretty=format:"%s" "$commit_hash")
            info "Cherry-picking: $commit_hash - $COMMIT_MESSAGE"

            # Cherry-pick into merge worktree
            local CHERRY_PICK_SUCCESS=false
            if git -C "$MERGE_WORKTREE_DIR" cherry-pick "$commit_hash"; then
                CHERRY_PICK_SUCCESS=true
            fi

            if [[ "$CHERRY_PICK_SUCCESS" != "true" ]]; then
                critical "Cherry-pick failed for commit: $commit_hash"
                critical "Conflict detected. Choose an option:"
                newline

                # Offer conflict resolution options
                local CONFLICT_OPTIONS
                # shellcheck disable=SC2034
                declare -A CONFLICT_OPTIONS=(
                    ["Abort cherry-pick"]="abort"
                    ["Start merge tool"]="mergetool"
                )
                # shellcheck disable=SC2034
                local CONFLICT_ORDER=("Abort cherry-pick" "Start merge tool")

                CHOICE=$(choose "Conflict resolution" CONFLICT_OPTIONS CONFLICT_ORDER)

                if [[ "$CHOICE" == "abort" ]]; then
                    git -C "$MERGE_WORKTREE_DIR" cherry-pick --abort
                    critical "Cherry-pick operation aborted"
                    # Clean up worktrees
                    if ! _git worktree remove "$RELEASE_WORKTREE_DIR" --force; then
                        warning "Could not remove release worktree automatically: $RELEASE_WORKTREE_DIR"
                    fi
                    if ! _git worktree remove "$MERGE_WORKTREE_DIR" --force; then
                        warning "Could not remove merge worktree automatically: $MERGE_WORKTREE_DIR"
                    fi
                    exit 1
                elif [[ "$CHOICE" == "mergetool" ]]; then
                    # Loop until conflicts are resolved or user aborts
                    while true; do
                        info "Starting merge tool in merge worktree..."
                        git -C "$MERGE_WORKTREE_DIR" mergetool

                        # Check if conflicts are resolved by checking git status
                        # Look for unmerged paths (UU, AA, DD) and also check for any remaining conflicted files
                        local CONFLICT_STATUS
                        CONFLICT_STATUS=$(git -C "$MERGE_WORKTREE_DIR" status --porcelain)

                        if echo "$CONFLICT_STATUS" | grep -q "^UU\|^AA\|^DD"; then
                            warning "Merge conflicts still exist. Choose an option:"
                            # Show which files still have conflicts
                            local CONFLICTED_FILES
                            CONFLICTED_FILES=$(echo "$CONFLICT_STATUS" | grep "^UU\|^AA\|^DD" | cut -c4-)
                            if [[ -n "$CONFLICTED_FILES" ]]; then
                                text "Files with unresolved conflicts:"
                                echo "$CONFLICTED_FILES" | while read -r file; do
                                    text "  • $file"
                                done
                                newline
                            fi
                            newline

                            # Offer options for remaining conflicts
                            local RETRY_OPTIONS
                            # shellcheck disable=SC2034
                            declare -A RETRY_OPTIONS=(
                                ["Try merge tool again"]="retry"
                                ["Abort cherry-pick"]="abort"
                            )
                            # shellcheck disable=SC2034
                            local RETRY_ORDER=("Try merge tool again" "Abort cherry-pick")

                            local RETRY_CHOICE
                            RETRY_CHOICE=$(choose "Conflict resolution" RETRY_OPTIONS RETRY_ORDER)

                            if [[ "$RETRY_CHOICE" == "abort" ]]; then
                                git -C "$MERGE_WORKTREE_DIR" cherry-pick --abort
                                critical "Cherry-pick operation aborted"
                                # Clean up worktrees
                                if ! _git worktree remove "$RELEASE_WORKTREE_DIR" --force; then
                                    warning "Could not remove release worktree automatically: $RELEASE_WORKTREE_DIR"
                                fi
                                if ! _git worktree remove "$MERGE_WORKTREE_DIR" --force; then
                                    warning "Could not remove merge worktree automatically: $MERGE_WORKTREE_DIR"
                                fi
                                exit 1
                            fi
                            # If retry is chosen, continue the loop
                        else
                            # All conflicts resolved, stage the resolved files
                            info "All conflicts resolved. Staging resolved files..."
                            local STAGING_SUCCESS=false
                            if git -C "$MERGE_WORKTREE_DIR" add .; then
                                STAGING_SUCCESS=true
                            fi

                            if [[ "$STAGING_SUCCESS" != "true" ]]; then
                                critical "Failed to stage resolved files"
                                # Clean up worktrees
                                if ! _git worktree remove "$RELEASE_WORKTREE_DIR" --force; then
                                    warning "Could not remove release worktree automatically: $RELEASE_WORKTREE_DIR"
                                fi
                                if ! _git worktree remove "$MERGE_WORKTREE_DIR" --force; then
                                    warning "Could not remove merge worktree automatically: $MERGE_WORKTREE_DIR"
                                fi
                                exit 1
                            fi

                            info "Continuing cherry-pick..."
                            local CONTINUE_SUCCESS=false
                            if git -C "$MERGE_WORKTREE_DIR" cherry-pick --continue; then
                                CONTINUE_SUCCESS=true
                            fi

                            if [[ "$CONTINUE_SUCCESS" != "true" ]]; then
                                critical "Failed to continue cherry-pick. Please resolve manually in $MERGE_WORKTREE_DIR"
                                # Clean up worktrees
                                if ! _git worktree remove "$RELEASE_WORKTREE_DIR" --force; then
                                    warning "Could not remove release worktree automatically: $RELEASE_WORKTREE_DIR"
                                fi
                                if ! _git worktree remove "$MERGE_WORKTREE_DIR" --force; then
                                    warning "Could not remove merge worktree automatically: $MERGE_WORKTREE_DIR"
                                fi
                                exit 1
                            fi

                            info "Successfully resolved and continued cherry-pick for commit $commit_hash"
                            break
                        fi
                    done
                fi
            else
                info "Successfully cherry-picked: $commit_hash"
            fi
        fi
    done

    info "Cherry-pick operation completed successfully"
    info "All commits from $RELEASE_BRANCH have been cherry-picked to $MERGE_BRANCH"
    newline

    # Push the merge branch to remote
    info "Pushing merge branch $MERGE_BRANCH to remote repository..."
    if git -C "$MERGE_WORKTREE_DIR" push -u origin "$MERGE_BRANCH"; then
        info "Successfully pushed merge branch $MERGE_BRANCH to remote repository"
        newline

        info "=== Merge Request Information ==="
        info "Merge branch '$MERGE_BRANCH' has been created and pushed to remote repository"
        newline
        info "Source branch: $MERGE_BRANCH"
        info "Target branch: $TARGET_BRANCH"
        newline
        info "Next steps:"
        text "1. Go to your Git hosting service web interface"
        text "2. Create a merge/pull request from '$MERGE_BRANCH' to '$TARGET_BRANCH'"
        text "3. Review the changes and merge when ready"
        newline
        info "The merge branch contains all cherry-picked commits from $RELEASE_BRANCH"
        newline

        # Clean up worktrees after successful push
        info "Cleaning up local worktrees and branches..."
        if ! _git worktree remove "$MERGE_WORKTREE_DIR" --force; then
            warning "Could not remove merge worktree automatically: $MERGE_WORKTREE_DIR"
        fi

        # Delete the local merge branch after successful push
        if _git branch -D "$MERGE_BRANCH" >/dev/null 2>&1; then
            info "✓ Removed local merge branch: $MERGE_BRANCH"
        else
            warning "Could not remove local merge branch: $MERGE_BRANCH"
        fi

        if ! _git worktree remove "$RELEASE_WORKTREE_DIR" --force; then
            warning "Could not remove release worktree automatically: $RELEASE_WORKTREE_DIR"
        fi

        info "✓ Local cleanup completed successfully"
        info "The merge branch exists only on the remote repository for the merge request"
    else
        critical "Failed to push merge branch $MERGE_BRANCH to remote repository"
        critical "The merge branch was created locally but could not be pushed"
        critical "Please check your network connection and repository access rights"
        newline
        critical "The local merge branch has been preserved for manual investigation:"
        text "  - Merge branch: $MERGE_BRANCH"
        text "  - Worktree location: $MERGE_WORKTREE_DIR"
        newline
        critical "You can:"
        text "  1. Investigate the issue and retry: git push -u origin $MERGE_BRANCH"
        text "  2. Or clean up manually if no longer needed:"
        text "     - Remove worktree: git worktree remove $MERGE_WORKTREE_DIR --force"
        text "     - Delete branch: git branch -D $MERGE_BRANCH"
        newline

        # Clean up only the release worktree on push failure, keep merge branch for investigation
        if ! _git worktree remove "$RELEASE_WORKTREE_DIR" --force; then
            warning "Could not remove release worktree automatically: $RELEASE_WORKTREE_DIR"
        fi

        # Exit with error code to indicate failure
        exit 1
    fi
}

function _update() {
    sub_headline "Updating"
    local BACKUP_DIR
    BACKUP_DIR="${PROJECT_DIR}/backup_$(date +%Y%m%d%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    text 'Creating backup {{ Foreground "14" "'"$(basename "$BACKUP_DIR")"'"}}'
    rsync -a --quiet --exclude "backup_*" --exclude .git --exclude htdocs --exclude logs --exclude volumes "$PROJECT_DIR/" "$BACKUP_DIR/" 1>/dev/null
    info "Updating project with current template"
    rsync -a --quiet --exclude logs --exclude volumes "$TEMPLATE_DIR/" "$PROJECT_DIR/"
    cat "$PROJECT_DIR"/.gitignore-dist >> "$PROJECT_DIR"/.gitignore
    sort -u "$PROJECT_DIR"/.gitignore -o "$PROJECT_DIR"/.gitignore
    rm "$PROJECT_DIR"/.gitignore-dist
    info "Update completed."
    newline
}

function _update_plugin() {
    local IMAGE
    local OUT

    IMAGE="ghcr.io/interligent-kommunzieren-gmbh/docker-plugin:latest"

    sub_headline "updating docker image"
    OUT=$(docker pull "$IMAGE")

    if [[ $OUT == *"Image is up to date"* ]]; then
        info "Image is already up-to-date. No new image pulled."
        newline
    else
        info "New image pulled."
        newline
        docker run --rm \
          -v "/cli-plugins":"/cli-plugins" \
          -u "$(id -u):$(id -g)" \
          "$IMAGE" install-plugin
    fi
}

function initializePlugin() {
    if [[ "$1" == "docker-cli-plugin-metadata"  ]] || [[ "$DOCKER_CLI_PLUGIN_METADATA" == "1" ]]; then
      cat <<EOF
{
  "SchemaVersion": "0.1.0",
  "Vendor": "Interligent kommunizieren GmbH",
  "Version": "$2",
  "ShortDescription": "Docker CLI plugin to control ik docker stack",
  "URL": "https://interligent.com"
}
EOF
      exit 0
    fi

    if [[ -n "$SSH_AUTH_PORT" ]]; then
        socat UNIX-LISTEN:/tmp/ssh-agent.sock,fork,mode=666 TCP:"$SSH_AUTH_PORT" >/dev/null &
        export SSH_AUTH_SOCK=/tmp/ssh-agent.sock
    fi

    shopt -s checkwinsize
    (: Refresh LINES and COLUMNS)
}

function parseArguments() {
    if [[ "$1" == "control"  ]]; then
        # skip plugin command itself
        shift
    fi

    if [[ "$1" == "controllocal"  ]]; then
        # skip plugin command itself
        shift
    fi

    if [[ $# -eq 0 ]]; then
        # show help page as no parameters where given
        _help
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dir|-d)
                shift
                PROJECT_DIR=$(realpath "$1")
                shift
                ;;
            add-deploy-config)
                checkDir
                _addDeployConfig
                exit 0
                ;;
            console)
                checkDir
                shift
                _console "${1:-php}"
                exit 0
                ;;
            deploy)
                checkDir
                shift
                _deploy "$@"
                exit 0
                ;;
            merge)
                checkDir
                shift
                _mergeReleaseToMain
                exit 0
                ;;
            help)
                _help
                exit 0
                ;;
            init)
                if [[ -z $(find "$PROJECT_DIR" -mindepth 1 -print -quit) ]]; then
                    _init
                    exit 0
                else
                    critical "Current directory is not empty"
                    exit 1
                fi
                ;;
            install-plugin)
                _install_plugin
                ;;
            pull)
                checkDir
                dockerCompose pull
                exit 0
                ;;
            pull-ingress)
                dockerComposeIngress pull
                exit 0
                ;;
            release)
                checkDir
                _createNewRelease
                exit 0
                ;;
            restart)
                checkDir
                dockerCompose down
                dockerCompose up -d
                exit 0
                ;;
            restart-ingress)
                dockerComposeIngress down
                dockerComposeIngress up -d
                exit 0
                ;;
            show-running)
                _showRunningProjects
                exit 0
                ;;
            start)
                checkDir
                dockerCompose up -d
                exit 0
                ;;
            start-ingress)
                dockerComposeIngress up -d
                exit 0
                ;;
            status)
                checkDir
                dockerCompose ps
                exit 0
                ;;
            status-ingress)
                dockerComposeIngress ps
                exit 0
                ;;
            stop)
                checkDir
                dockerCompose down
                exit 0
                ;;
            stop-ingress)
                checkDir
                dockerComposeIngress down
                exit 0
                ;;
            update)
                checkDir
                dockerCompose down
                _update
                dockerCompose up -d
                exit 0
                ;;
            update-plugin)
                _update_plugin
                ;;
            version)
                headline "IK Docker Control $VERSION"
                info "Version: $VERSION"
                exit 0
                ;;
            *)
                checkDir
                COMMAND=$1
                shift

                # Check for control scripts in .docker-control directory first, then fallback to legacy location
                local CONTROL_SCRIPT_PATH=""
                if [[ -f "$PROJECT_DIR/htdocs/.docker-control/control-scripts/${COMMAND}.sh" ]] && [[ -r "$PROJECT_DIR/htdocs/.docker-control/control-scripts/${COMMAND}.sh" ]]; then
                    CONTROL_SCRIPT_PATH="$PROJECT_DIR/htdocs/.docker-control/control-scripts/${COMMAND}.sh"
                elif [[ -f "${PROJECT_DIR}/control-scripts/${COMMAND}.sh" ]] && [[ -r "${PROJECT_DIR}/control-scripts/${COMMAND}.sh" ]]; then
                    CONTROL_SCRIPT_PATH="${PROJECT_DIR}/control-scripts/${COMMAND}.sh"
                fi

                if [[ -n "$CONTROL_SCRIPT_PATH" ]]; then
                    LIB_DIR="$LIB_DIR" "$CONTROL_SCRIPT_PATH" "$@"
                    exit 0
                else
                    critical "Invalid parameter: $COMMAND"
                    newline
                    _help
                    exit 1
                fi
                ;;
        esac
    done
}

function select_docker_service() {
    local SERVICES
    SERVICES="db php"

    local SERVICE_MAP
    # shellcheck disable=SC2034
    declare -A SERVICE_MAP=()
    local SERVICE_ORDER
    # shellcheck disable=SC2034
    declare -a SERVICE_ORDER=()

    IFS="$DEFAULT_IFS"
    for SERVICE in $SERVICES; do
        # shellcheck disable=SC2034
        SERVICE_MAP["$SERVICE"]="$SERVICE"
        SERVICE_ORDER+=("$SERVICE")
    done

    choose "Service" SERVICE_MAP SERVICE_ORDER
}

function select_php_version() {
    local SERVICES
    SERVICES="7.4 7.4-oci 8.2 8.2-oci 8.4 8.4-oci"

    local SERVICE_MAP
    # shellcheck disable=SC2034
    declare -A SERVICE_MAP=()
    local SERVICE_ORDER
    # shellcheck disable=SC2034
    declare -a SERVICE_ORDER=()

    IFS="$DEFAULT_IFS"
    for SERVICE in $SERVICES; do
        # shellcheck disable=SC2034
        SERVICE_MAP["$SERVICE"]="$SERVICE"
        SERVICE_ORDER+=("$SERVICE")
    done

    choose "PHP Version" SERVICE_MAP SERVICE_ORDER
}

function select_release_tag() {
    local TAGS
    local NEED_MANUAL_INPUT=false
    local ERROR_MESSAGE=""

    # Try to get tags, but handle potential Git/authentication errors
    # Only get releases/tags, no branches
    if ! TAGS="$(getLatestTags "" 2>/dev/null)"; then
        NEED_MANUAL_INPUT=true
        ERROR_MESSAGE="Failed to fetch tags from repository (authentication or Git configuration issue)"
    elif [[ -z "${TAGS// }" ]]; then
        # Validate that TAGS is not empty, null, unset, or contains only whitespace
        NEED_MANUAL_INPUT=true
        ERROR_MESSAGE="No tags could be automatically determined from the repository"
    fi

    # Handle manual input if needed
    if [[ "$NEED_MANUAL_INPUT" == "true" ]]; then
        warning "$ERROR_MESSAGE" >&2

        # Check if this might be an initial repository setup (no existing tags/branches)
        if [[ "$ERROR_MESSAGE" == *"No tags could be automatically determined"* ]]; then
            info "This appears to be a new repository with no existing releases." >&2
            info "Will proceed with initial release creation..." >&2
            # Return special marker to indicate initial release without tag lookup
            echo -n "INITIAL_RELEASE"
            return 0
        fi

        info "Please manually enter an existing tag/release identifier to proceed" >&2
        newline >&2

        local MANUAL_TAG
        while true; do
            MANUAL_TAG=$(input -n -l "Tag/Release identifier" -p "Enter an existing tag or release name")

            # Validate that the user input is not empty
            if [[ -n "${MANUAL_TAG// }" ]]; then
                echo -n "$MANUAL_TAG"
                return 0
            else
                warning "Tag identifier cannot be empty. Please enter a valid tag or release name." >&2
                newline >&2
            fi
        done
    fi

    local TAG_MAP
    # shellcheck disable=SC2034
    declare -A TAG_MAP=()
    local TAG_ORDER
    # shellcheck disable=SC2034
    declare -a TAG_ORDER=()

    IFS="$DEFAULT_IFS"
    for TAG in $TAGS; do
        # shellcheck disable=SC2034
        TAG_MAP["$TAG"]="$TAG"
        TAG_ORDER+=("$TAG")
    done

    choose "Previous Tag / Release Branch" TAG_MAP TAG_ORDER
}

