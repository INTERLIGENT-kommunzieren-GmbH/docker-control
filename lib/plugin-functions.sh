#!/bin/bash

function _addDeployConfig() {
    if [[ ! -f "$PROJECT_DIR/.deploy.conf" ]]; then
        createDeployConfig
    else
        addDeployConfig
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
    local RELEASE
    local CREATED_RELEASE

    sub_headline "create new release"
    newline

    RELEASE=$(select_release_tag 1)

    # Check if release selection was successful
    if [[ $? -ne 0 ]]; then
        critical "Failed to select base release/tag"
        exit 1
    fi

    # Handle special case for initial release
    if [[ "$RELEASE" == "INITIAL_RELEASE" ]]; then
        info "No base release specified - will create initial release"

        # Directly create initial release without calling gitCreateRelease
        # to avoid the getLatestTags call that causes authentication issues
        local INITIAL_RELEASE="1.0.x"
        if gitCreateReleaseBranch "$INITIAL_RELEASE"; then
            info "Successfully created initial release: $INITIAL_RELEASE"
            text 'Release {{ Foreground "14" "'"$INITIAL_RELEASE"'"}} has been created and is ready for use'
            return 0
        else
            critical "Failed to create initial release"
            exit 1
        fi
    fi

    info "Selected base release/tag: $RELEASE"
    newline

    # Call gitCreateRelease and check for success
    if gitCreateRelease "$RELEASE"; then
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
    if [[ -z "$DEPLOY_ENVS" ]]; then
        if [[ ! -f "$PROJECT_DIR/.deploy.conf" ]]; then
            info "No deployment configuration found. Creating one..."
            createDeployConfig
        fi

        # Source the configuration file with error handling
        if ! . "$PROJECT_DIR/.deploy.conf"; then
            critical "Failed to load deployment configuration from $PROJECT_DIR/.deploy.conf"
            critical "The configuration file may be malformed"
            exit 1
        fi
    fi

    # Validate that DEPLOY_ENVS was loaded properly
    if [[ -z "$DEPLOY_ENVS" ]]; then
        critical "Deployment configuration is empty or malformed"
        critical "Please check $PROJECT_DIR/.deploy.conf"
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
    local ALLOW_BRANCH_DEPLOYMENT
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
    RELEASE=$(select_release_tag "$ALLOW_BRANCH_DEPLOYMENT")

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
    local ALLOW_BRANCH_DEPLOYMENT="n"
    if [[ -n "$BRANCH" ]]; then
        ALLOW_BRANCH_DEPLOYMENT=$(confirm -n "Is this an unstable environment?")
    fi

    local USER
    input -n -l "user" -r USER
    local DOMAIN
    input -n -l "domain" -d "$USER.projects.interligent.com" -r DOMAIN
    input -n -l "server root" -d "/var/www/html" -r SERVICE_ROOT

    cat <<EOF | tee -a "$PROJECT_DIR/.deploy.conf" 1>/dev/null
DEPLOY_ENVS["$ENV"]="BRANCH=$BRANCH ALLOW_BRANCH_DEPLOYMENT=$ALLOW_BRANCH_DEPLOYMENT USER=$USER DOMAIN=$DOMAIN SERVICE_ROOT=$SERVICE_ROOT"
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

function dockerCompose() {
    docker compose --project-directory "$PROJECT_DIR" "$@"
}

function dockerComposeIngress() {
    docker compose --project-directory "$INGRESS_COMPOSE_DIR" -f "$INGRESS_COMPOSE_FILE" "$@"
}

function _help() {
    local COMMANDS
    # shellcheck disable=SC2034
    COMMANDS=(
            $'add-deploy-config\tAdd deployment configuration for environments'
            $'build [options]\tBuild Docker containers (accepts docker-compose build options)'
            $'console [container]\tEnter container console (defaults to php)'
            $'create-control-script <name>\tCreate a custom control script'
            $'deploy <env>\tDeploy selected release to specified environment'
            $'help\tShow this help and project status'
            $'init\tInitialize empty directory with project template'
            $'install-plugin\tInstall Docker CLI plugin system-wide'
            $'merge\tMerge release branch to main using cherry-pick'
            $'pull\tPull latest Docker images for project containers'
            $'pull-ingress\tPull latest ingress-related Docker images'
            $'release\tCreate new release branch with automated versioning'
            $'restart\tRestart project containers (stop and start)'
            $'restart-ingress\tRestart ingress containers (stop and start)'
            $'show-running\tShow all running Docker projects'
            $'start\tStart project containers'
            $'start-ingress\tStart ingress containers'
            $'status\tShow status of project containers'
            $'status-ingress\tShow status of ingress containers'
            $'stop\tStop project containers'
            $'stop-ingress\tStop ingress containers'
            $'update\tUpdate project with current template and restart'
            $'update-plugin\tUpdate Docker plugin to latest version'
            $'version\tShow version information'
    )
    local OPTIONS
    # shellcheck disable=SC2034
    OPTIONS=(
        $'-d|--dir\tProject directory (default: current directory)'
    )

    headline "IK Docker Control $SERVICE"
    newline

    printHelp "Options" OPTIONS
    printHelp "Commands" COMMANDS

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

        printHelp "Custom commands" SUB_COMMANDS
    fi

    # Add project status information
    _showProjectStatus
}

function _showProjectStatus() {
    sub_headline "Project Status"

    # Project Directory Information
    text "Project Directory: {{ Foreground \"14\" \"$PROJECT_DIR\" }}"

    # Check if project is managed by docker control plugin
    if [[ -f "$PROJECT_DIR/.managed-by-docker-control-plugin" ]]; then
        text "Plugin Management: {{ Foreground \"10\" \"✓ Managed by Docker Control Plugin\" }}"
    else
        text "Plugin Management: {{ Foreground \"11\" \"✗ Not managed by Docker Control Plugin\" }}"
        text "  Run {{ Foreground \"14\" \"docker control init\" }} to initialize this directory"
    fi

    # Git Repository Status
    _showGitStatus

    # Deployment Configuration Status
    _showDeploymentStatus

    # Docker Status
    _showDockerStatus

    newline
}

function _showGitStatus() {
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
        text "Git Repository: {{ Foreground \"10\" \"✓ Initialized\" }} ($GIT_STATUS)"
    else
        text "Git Repository: {{ Foreground \"11\" \"✗ Not a git repository\" }}"
        text "  Initialize with {{ Foreground \"14\" \"git init\" }} in the htdocs directory"
    fi
}

function _showDeploymentStatus() {
    if [[ -f "$PROJECT_DIR/.deploy.conf" ]]; then
        text "Deployment Config: {{ Foreground \"10\" \"✓ Configured\" }}"

        # Load deployment configuration to show environments
        local DEPLOY_ENVS_LOCAL
        if . "$PROJECT_DIR/.deploy.conf" 2>/dev/null && [[ -n "$DEPLOY_ENVS" ]]; then
            DEPLOY_ENVS_LOCAL=("${!DEPLOY_ENVS[@]}")
            if [[ ${#DEPLOY_ENVS_LOCAL[@]} -gt 0 ]]; then
                text "  Environments: {{ Foreground \"14\" \"${DEPLOY_ENVS_LOCAL[*]}\" }}"
            else
                text "  {{ Foreground \"11\" \"No environments configured\" }}"
            fi
        else
            text "  {{ Foreground \"11\" \"Configuration file exists but is malformed\" }}"
        fi
    else
        text "Deployment Config: {{ Foreground \"11\" \"✗ Not configured\" }}"
        text "  Run {{ Foreground \"14\" \"docker control add-deploy-config\" }} to add deployment environments"
    fi
}

function _showDockerStatus() {
    local CONTAINER_COUNT=0
    local RUNNING_COUNT=0
    local PROJECT_CONTAINERS=""

    # Check if Docker is available
    if ! command -v docker &> /dev/null; then
        text "Docker Status: {{ Foreground \"11\" \"✗ Docker not available\" }}"
        return
    fi

    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        text "Docker Status: {{ Foreground \"11\" \"✗ Docker daemon not running\" }}"
        return
    fi

    # Get project containers
    if PROJECT_CONTAINERS=$(docker ps -a --filter "label=com.interligent.dockerplugin.dir=$PROJECT_DIR" --format "{{.Names}}\t{{.Status}}" 2>/dev/null); then
        if [[ -n "$PROJECT_CONTAINERS" ]]; then
            CONTAINER_COUNT=$(echo "$PROJECT_CONTAINERS" | wc -l)
            RUNNING_COUNT=$(echo "$PROJECT_CONTAINERS" | grep -c "Up" || true)

            if [[ $RUNNING_COUNT -gt 0 ]]; then
                text "Docker Status: {{ Foreground \"10\" \"✓ $RUNNING_COUNT/$CONTAINER_COUNT containers running\" }}"
            else
                text "Docker Status: {{ Foreground \"11\" \"○ $CONTAINER_COUNT containers stopped\" }}"
                text "  Run {{ Foreground \"14\" \"docker control start\" }} to start containers"
            fi
        else
            text "Docker Status: {{ Foreground \"11\" \"○ No project containers found\" }}"
            text "  Run {{ Foreground \"14\" \"docker control start\" }} to create and start containers"
        fi
    else
        text "Docker Status: {{ Foreground \"11\" \"✗ Unable to query container status\" }}"
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
    local COMMITS_TO_CHERRY_PICK
    local COMMIT_MESSAGE
    local CHOICE
    local RELEASE_WORKTREE_DIR
    local TARGET_WORKTREE_DIR

    sub_headline "Merge Release to Main"
    newline

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
    newline

    # Set up worktree directories
    RELEASE_WORKTREE_DIR="$PROJECT_DIR/releases/$RELEASE_BRANCH"
    TARGET_WORKTREE_DIR="$PROJECT_DIR/releases/$TARGET_BRANCH"

    # Create releases directory if it doesn't exist
    mkdir -p "$PROJECT_DIR/releases"

    # Create worktree for release branch
    if ! _git worktree add "$RELEASE_WORKTREE_DIR" "$RELEASE_BRANCH"; then
        critical "Error: Failed to create release worktree for $RELEASE_BRANCH"
        exit 1
    fi

    # Create worktree for target branch
    if ! _git worktree add "$TARGET_WORKTREE_DIR" "$TARGET_BRANCH"; then
        critical "Error: Failed to create target worktree for $TARGET_BRANCH"
        # Clean up release worktree
        if ! _git worktree remove "$RELEASE_WORKTREE_DIR" --force; then
            warning "Could not remove release worktree automatically: $RELEASE_WORKTREE_DIR"
        fi
        exit 1
    fi

    # Pull latest changes in target worktree
    git -C "$TARGET_WORKTREE_DIR" pull origin "$TARGET_BRANCH"

    # Get commits that exist in release branch but not in target branch
    # Exclude commits with "release:" prefix in commit message
    COMMITS_TO_CHERRY_PICK=$(git -C "$RELEASE_WORKTREE_DIR" log --reverse --pretty=format:"%H" "$TARGET_BRANCH".."$RELEASE_BRANCH" | while read -r commit_hash; do
        commit_msg=$(git -C "$RELEASE_WORKTREE_DIR" log -1 --pretty=format:"%s" "$commit_hash")
        if [[ ! "$commit_msg" =~ ^release: ]]; then
            echo "$commit_hash"
        fi
    done)

    if [[ -z "$COMMITS_TO_CHERRY_PICK" ]]; then
        info "No commits to cherry-pick from $RELEASE_BRANCH to $TARGET_BRANCH"
        # Clean up worktrees
        if ! _git worktree remove "$RELEASE_WORKTREE_DIR" --force; then
            warning "Could not remove release worktree automatically: $RELEASE_WORKTREE_DIR"
        fi
        if ! _git worktree remove "$TARGET_WORKTREE_DIR" --force; then
            warning "Could not remove target worktree automatically: $TARGET_WORKTREE_DIR"
        fi
        return 0
    fi

    info "Found commits to cherry-pick:"
    echo "$COMMITS_TO_CHERRY_PICK" | while read -r commit_hash; do
        if [[ -n "$commit_hash" ]]; then
            commit_msg=$(git -C "$RELEASE_WORKTREE_DIR" log -1 --pretty=format:"%s" "$commit_hash")
            text "  • $commit_hash - $commit_msg"
        fi
    done
    newline

    # Confirm before proceeding
    if [[ $(confirm "Proceed with cherry-picking these commits?") != "y" ]]; then
        info "Cherry-pick operation cancelled"
        # Clean up worktrees
        if ! _git worktree remove "$RELEASE_WORKTREE_DIR" --force; then
            warning "Could not remove release worktree automatically: $RELEASE_WORKTREE_DIR"
        fi
        if ! _git worktree remove "$TARGET_WORKTREE_DIR" --force; then
            warning "Could not remove target worktree automatically: $TARGET_WORKTREE_DIR"
        fi
        return 0
    fi

    # Cherry-pick each commit in the target worktree
    local COMMIT_ARRAY
    mapfile -t COMMIT_ARRAY < <(echo "$COMMITS_TO_CHERRY_PICK")

    for commit_hash in "${COMMIT_ARRAY[@]}"; do
        if [[ -n "$commit_hash" ]]; then
            COMMIT_MESSAGE=$(git -C "$TARGET_WORKTREE_DIR" log -1 --pretty=format:"%s" "$commit_hash")
            info "Cherry-picking: $commit_hash - $COMMIT_MESSAGE"

            if ! git -C "$TARGET_WORKTREE_DIR" cherry-pick "$commit_hash"; then
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
                    git -C "$TARGET_WORKTREE_DIR" cherry-pick --abort
                    critical "Cherry-pick operation aborted"
                    # Clean up worktrees
                    if ! _git worktree remove "$RELEASE_WORKTREE_DIR" --force; then
                        warning "Could not remove release worktree automatically: $RELEASE_WORKTREE_DIR"
                    fi
                    if ! _git worktree remove "$TARGET_WORKTREE_DIR" --force; then
                        warning "Could not remove target worktree automatically: $TARGET_WORKTREE_DIR"
                    fi
                    exit 1
                elif [[ "$CHOICE" == "mergetool" ]]; then
                    # Loop until conflicts are resolved or user aborts
                    while true; do
                        info "Starting merge tool in target worktree..."
                        git -C "$TARGET_WORKTREE_DIR" mergetool

                        # Check if conflicts are resolved by checking git status
                        # Look for unmerged paths (UU, AA, DD) and also check for any remaining conflicted files
                        local CONFLICT_STATUS
                        CONFLICT_STATUS=$(git -C "$TARGET_WORKTREE_DIR" status --porcelain)

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
                                git -C "$TARGET_WORKTREE_DIR" cherry-pick --abort
                                critical "Cherry-pick operation aborted"
                                # Clean up worktrees
                                if ! _git worktree remove "$RELEASE_WORKTREE_DIR" --force; then
                                    warning "Could not remove release worktree automatically: $RELEASE_WORKTREE_DIR"
                                fi
                                if ! _git worktree remove "$TARGET_WORKTREE_DIR" --force; then
                                    warning "Could not remove target worktree automatically: $TARGET_WORKTREE_DIR"
                                fi
                                exit 1
                            fi
                            # If retry is chosen, continue the loop
                        else
                            # All conflicts resolved, stage the resolved files
                            info "All conflicts resolved. Staging resolved files..."
                            if ! git -C "$TARGET_WORKTREE_DIR" add .; then
                                critical "Failed to stage resolved files"
                                # Clean up worktrees
                                if ! _git worktree remove "$RELEASE_WORKTREE_DIR" --force; then
                                    warning "Could not remove release worktree automatically: $RELEASE_WORKTREE_DIR"
                                fi
                                if ! _git worktree remove "$TARGET_WORKTREE_DIR" --force; then
                                    warning "Could not remove target worktree automatically: $TARGET_WORKTREE_DIR"
                                fi
                                exit 1
                            fi

                            info "Continuing cherry-pick..."
                            if ! git -C "$TARGET_WORKTREE_DIR" cherry-pick --continue; then
                                critical "Failed to continue cherry-pick. Please resolve manually in $TARGET_WORKTREE_DIR"
                                # Clean up worktrees
                                if ! _git worktree remove "$RELEASE_WORKTREE_DIR" --force; then
                                    warning "Could not remove release worktree automatically: $RELEASE_WORKTREE_DIR"
                                fi
                                if ! _git worktree remove "$TARGET_WORKTREE_DIR" --force; then
                                    warning "Could not remove target worktree automatically: $TARGET_WORKTREE_DIR"
                                fi
                                exit 1
                            fi

                            # Push the resolved cherry-picked commit immediately
                            info "Pushing resolved cherry-picked commit to remote..."
                            if git -C "$TARGET_WORKTREE_DIR" push origin "$TARGET_BRANCH"; then
                                info "Successfully pushed resolved commit $commit_hash to remote $TARGET_BRANCH"
                            else
                                warning "Failed to push resolved commit $commit_hash. Continuing with next commit..."
                            fi
                            break
                        fi
                    done
                fi
            else
                info "Successfully cherry-picked: $commit_hash"

                # Push the cherry-picked commit immediately
                info "Pushing cherry-picked commit to remote..."
                if git -C "$TARGET_WORKTREE_DIR" push origin "$TARGET_BRANCH"; then
                    info "Successfully pushed commit $commit_hash to remote $TARGET_BRANCH"
                else
                    warning "Failed to push commit $commit_hash. Continuing with next commit..."
                fi
            fi
        fi
    done

    info "Cherry-pick operation completed successfully"
    info "All commits from $RELEASE_BRANCH have been merged and pushed to $TARGET_BRANCH"
    newline

    # Clean up worktrees
    if ! _git worktree remove "$RELEASE_WORKTREE_DIR" --force; then
        warning "Could not remove release worktree automatically: $RELEASE_WORKTREE_DIR"
    fi
    if ! _git worktree remove "$TARGET_WORKTREE_DIR" --force; then
        warning "Could not remove target worktree automatically: $TARGET_WORKTREE_DIR"
    fi

    info "Worktrees cleaned up successfully"
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
}

function parseArguments() {
    if [[ "$1" == "control"  ]]; then
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
            build)
                checkDir
                shift
                dockerCompose build "$@"
                exit 0
                ;;
            create-control-script)
                checkDir
                shift
                _createControlScript "$@"
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
    local INCLUDE_BRANCHES="$1"
    local TAGS
    local NEED_MANUAL_INPUT=false
    local ERROR_MESSAGE=""

    # Try to get tags, but handle potential Git/authentication errors
    if ! TAGS="$(getLatestTags "$INCLUDE_BRANCHES" 2>/dev/null)"; then
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

