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
    if [[ -f "${PROJECT_DIR}/control-scripts/${COMMAND}.sh" ]]; then
        critical "command '$COMMAND' already exists in $PROJECT_DIR"
        exit 1
    else
        cat << EOF | tee "$PROJECT_DIR/control-scripts/${COMMAND}.sh" 1>/dev/null
#!/bin/bash
set -e

. "$LIB_DIR/util-functions.sh"

if [[ "\$1" == "_desc_" ]]; then
    # output command description
    echo "EMPTY DESCRIPTION"

    exit 0
fi

info "WAITING FOR IMPLEMENTATION"

exit 0
EOF
        chmod u+x "$PROJECT_DIR/control-scripts/${COMMAND}.sh"

        text 'command {{ Foreground "14" "'"$COMMAND"'"}} created under {{ Foreground "14" "'"$PROJECT_DIR"'"}}'
    fi
}

function _createNewRelease() {
    local SRC_BRANCH
    local RELEASE
    local TODAY
    local BASE_TAG
    local NEXT_INDEX
    local EXISTING_TAGS
    local REPO_DIR="$PROJECT_DIR/htdocs"
    local WORKTREE_DIR

    sub_headline "create new release"
    newline

    TODAY=$(date '+%Y%m%d')
    git -C "$REPO_DIR" fetch --all --prune

    EXISTING_TAGS=$(git -C "$REPO_DIR" branch -r --list "origin/releases/$TODAY*" \
        | sed 's|.*/releases/||' | sed 's/\r//g' | sort)

    NEXT_INDEX=1
    if [[ -n "$EXISTING_TAGS" ]]; then
        local max=0
        while IFS= read -r tag; do
            local idx="${tag##*_}"
            if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx > max )); then
                max=$idx
            fi
        done <<< "$EXISTING_TAGS"
        NEXT_INDEX=$((max + 1))
    fi

    BASE_TAG="${TODAY}_${NEXT_INDEX}"

    input -l "source branch" -d "master" -r SRC_BRANCH
    input -l "release tag" -d "$BASE_TAG" -r RELEASE

    # 🔍 Check branch existence
    if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/releases/$RELEASE" \
        || git -C "$REPO_DIR" show-ref --verify --quiet "refs/remotes/origin/releases/$RELEASE"; then
        critical "Branch releases/$RELEASE already exists (local or remote)"
        exit 1
    fi

    WORKTREE_DIR="$PROJECT_DIR/releases/$RELEASE"

    if [[ -d "$WORKTREE_DIR" ]]; then
        critical "Worktree directory already exists: $WORKTREE_DIR"
        exit 1
    fi
    if git -C "$REPO_DIR" worktree list | grep -q "releases/$RELEASE"; then
        critical "Branch releases/$RELEASE is already checked out in another worktree"
        exit 1
    fi

    # Ensure source branch up-to-date
    git -C "$REPO_DIR" fetch origin "$SRC_BRANCH"
    git -C "$REPO_DIR" branch -f "$SRC_BRANCH" "origin/$SRC_BRANCH"
    git -C "$REPO_DIR" worktree prune

    # Create worktree & branch
    git -C "$REPO_DIR" worktree add -b "releases/$RELEASE" "$WORKTREE_DIR" "$SRC_BRANCH" \
        || { critical "Failed to create worktree"; exit 1; }

    if [[ ! -f "$WORKTREE_DIR/composer.lock" ]]; then
        sub_headline "Create composer.lock"

        info "Installing packages"
        # shellcheck disable=SC2034
        local BASE_DOMAIN
        # shellcheck disable=SC2034
        local ENVIRONMENT
        # shellcheck disable=SC2034
        local DB_HOST_PORT
        local PHP_VERSION
        # shellcheck disable=SC2034
        local PROJECTNAME
        # shellcheck disable=SC2034
        local XDEBUG_IP
        # shellcheck disable=SC2034
        local IDE_KEY
        . "$PROJECT_DIR"/.env
        docker run \
            -u "$(id -u):$(id -g)" \
            --group-add www-data \
            -v "\$SSH_AUTH_SOCK":"\$SSH_AUTH_SOCK" \
            -e SSH_AUTH_SOCK="\$SSH_AUTH_SOCK" \
            -v "$PROJECT_DIR/volumes/composer-cache:/var/www/.composer/cache" \
            -v "$WORKTREE_DIR":/var/www/html fduarte42/docker-php:"$PHP_VERSION" \
            composer i -o

        info "Cleaning up vendor folder"
        rm -rf "$WORKTREE_DIR/vendor"

        git -C "$WORKTREE_DIR" add composer.lock
        git -C "$WORKTREE_DIR" commit -m "Add composer.lock for $RELEASE"
    fi

    # Push to origin
    git -C "$WORKTREE_DIR" push -u origin "releases/$RELEASE"

    info "Created and pushed release branch releases/$RELEASE (temporary worktree: $WORKTREE_DIR)"

    # Remove worktree
    if git -C "$REPO_DIR" worktree remove "$WORKTREE_DIR" --force; then
        info "Temporary worktree removed"
    else
        warning "Could not remove worktree automatically: $WORKTREE_DIR"
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
    if [[ -z "$DEPLOY_ENVS" ]]; then
        if [[ ! -f "$PROJECT_DIR/.deploy.conf" ]]; then
            createDeployConfig
        fi
        . "$PROJECT_DIR/.deploy.conf"
    fi

    local ENV="$1"
    if [[ -z "$ENV" ]]; then
        critical "Environment parameter missing"
        newline
        text 'The following environments are configured: {{ Foreground "14" "'"${!DEPLOY_ENVS[*]}"'"}}'
        exit 1
    fi

    if [[ -z "${DEPLOY_ENVS[$ENV]+set}" ]]; then
        critical "Environment $ENV not configured"
        newline
        text 'The following environments are configured: {{ Foreground "14" "'"${!DEPLOY_ENVS[*]}"'"}}'
        exit 1
    fi

    local BRANCH
    local IS_MERGE_STOP
    local USER
    local DOMAIN
    local SERSERVICE_ROOT
    eval "${DEPLOY_ENVS[$ENV]}"

    local DEPLOY_BRANCH="${2:-$BRANCH}"
    deploy "$ENV" "$USER" "$DOMAIN" "$SERSERVICE_ROOT" "$DEPLOY_BRANCH"
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
    local IS_MERGE_STOP="n"
    if [[ -n "$BRANCH" ]]; then
        IS_MERGE_STOP=$(confirm -n "Is this a merge stop?")
    fi

    local USER
    input -n -l "user" -r USER
    local DOMAIN
    input -n -l "domain" -d "$USER.projects.interligent.com" -r DOMAIN
    input -n -l "server root" -d "/var/www/html" -r SERVICE_ROOT

    cat <<EOF | tee -a "$PROJECT_DIR/.deploy.conf" 1>/dev/null
DEPLOY_ENVS["$ENV"]="BRANCH=$BRANCH IS_MERGE_STOP=$IS_MERGE_STOP USER=$USER DOMAIN=$DOMAIN SERVICE_ROOT=$SERVICE_ROOT"
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
    local FIRST_COL_WIDTH=30
    headline "IK Docker Control $SERVICE"
    newline
    sub_headline "Options"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "-d|--dir") Project directory (default: current directory)"
    newline
    sub_headline "Commands"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "add-deploy-config") Add deployment config"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "build") Build containers"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "create-control-script <name>") Create a custom control script"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "console <container>") Enter container console (defaults to php)"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "deploy <env> <branch>") Deploy branch to environment"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "merge") Automatic branch merging"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "help") Show this help"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "init") Initialize empty directory with template"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "install-plugin") Install docker plugin"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "pull") Pull current container images"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "pull-ingress") Pull current ingress images"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "release") Create new release"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "restart") Restart project containers"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "restart-ingress") Restart ingress containers"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "show-running") Show running projects"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "start") Start project containers"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "start-ingress") Start ingress containers"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "status") Show status of project containers"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "status-ingress") Show status of ingress containers"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "stop") Stop project containers"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "stop-ingress") Stop ingress containers"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "update") Update docker plugin"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "update-plugin") Update project with current template"
    info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "version") Show version information"
    newline

    if ls "$PROJECT_DIR"/control-scripts/*.sh 1> /dev/null 2>&1; then
        sub_headline "Custom commands"
        for COMMAND in "$PROJECT_DIR"/control-scripts/*.sh; do
            local SHORT_COMMAND
            SHORT_COMMAND=$(basename "$COMMAND" .sh)
            local DESCRIPTION
            DESCRIPTION=$("$COMMAND" _desc_)
            info "  $(printf "%-${FIRST_COL_WIDTH}s\n" "${SHORT_COMMAND}") ${DESCRIPTION}"
        done
        newline
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
    cat << EOF | tee "$DOCKER_CLI_PLUGIN_PATH/docker-control" 1>/dev/null
#!/usr/bin/env bash

IMAGE="ghcr.io/interligent-kommunzieren-gmbh/docker-plugin:latest"
PROJECT_DIR=\$(pwd)
PARAMETER=()
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        docker-cli-plugin-metadata)
            docker run --rm "\$IMAGE" docker-cli-plugin-metadata
            exit
            ;;
        --dir|-d)
            shift
            PROJECT_DIR=\$(realpath "\$1")
            shift
            ;;
        *)
            PARAMETER+=("\$1")
            shift
    esac
done

OPTS=(
    --rm -it
    --network host
    --add-host host.docker.internal:host-gateway
    -u "\$(id -u):\$(id -g)"
    -e UID="\$(id -u)"
    -e GID="\$(id -g)"
    -v "\$PROJECT_DIR":"\$PROJECT_DIR"
    -w "\$PROJECT_DIR"
    -v "\$HOME/.docker/cli-plugins":"/cli-plugins"
    -v "\$HOME/.ik/docker-plugin-mounts":"/docker-plugin-mounts"
    -e PLUGIN_MOUNTS_DIR="\$HOME/.ik/docker-plugin-mounts"
    -e DOCKER_HOST=tcp://host.docker.internal:2375
)

NC_SSH_AGENT_CMD="docker run --rm --quiet --add-host host.docker.internal:host-gateway -it --entrypoint "/usr/bin/nc" "\$IMAGE" -zv host.docker.internal 2222"
if ! \$NC_SSH_AGENT_CMD >/dev/null; then
    if [[ -z "$SSH_AUTH_SOCK ]]; then
        echo "SSH agent seems to not be running."
        exit 1
    fi
    docker run --rm --name docker-plugin-ssh-agent -v "\$SSH_AUTH_SOCK":"/tmp/ssh-agent.sock" --detach --entrypoint "/usr/bin/socat" -p 127.0.0.1:2222:2222 "\$IMAGE" tcp-listen:2222,fork,reuseaddr unix-connect:/tmp/ssh-agent.sock 1>/dev/null
fi

NC_DOCKER_CMD="docker run --rm --quiet --add-host host.docker.internal:host-gateway -it --entrypoint "/usr/bin/nc" "\$IMAGE" -zv host.docker.internal 2375"
if ! \$NC_DOCKER_CMD >/dev/null; then
    DOCKER_SOCK="\$(docker context inspect --format '{{(index .Endpoints.docker.Host)}}' | sed -e 's|^unix://||')"
    docker run --name docker-plugin-port -v "\$DOCKER_SOCK":/var/run/docker.sock --detach --restart always --entrypoint "/usr/bin/socat" -p 127.0.0.1:2375:2375 "\$IMAGE" tcp-listen:2375,fork,reuseaddr unix-connect:/var/run/docker.sock 1>/dev/null
fi

docker run "\${OPTS[@]}" "\$IMAGE" "\${PARAMETER[@]}"
EOF
    chmod 755 "$DOCKER_CLI_PLUGIN_PATH/docker-control"
    info "Installation successful. You can start using the plugin with: docker control help"
    exit
}

function _merge() {
    merge
}

function _update() {
    sub_headline "Updating"
    local BACKUP_DIR
    BACKUP_DIR="${PROJECT_DIR}/backup_$(date +%Y%m%d%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    text 'Creating backup {{ Foreground "14" "'"$(basename "$BACKUP_DIR")"'"}}'
    rsync -a --quiet --exclude "backup_*" --exclude .git --exclude htdocs --exclude volumes "$PROJECT_DIR/" "$BACKUP_DIR/" 1>/dev/null
    info "Updating project with current template"
    rsync -a --quiet "$TEMPLATE_DIR/" "$PROJECT_DIR/"
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

    socat UNIX-LISTEN:/tmp/ssh-agent.sock,fork,mode=666 TCP:host.docker.internal:2222 >/dev/null &
    export SSH_AUTH_SOCK=/tmp/ssh-agent.sock
}

function merge() {
        if [[ -z "$DEPLOY_ENVS" ]]; then
            if [[ ! -f "$PROJECT_DIR/.deploy.conf" ]]; then
                createDeployConfig
            fi
            . "$PROJECT_DIR/.deploy.conf"
        fi

        local MERGE_STOPS=("development")
        local MERGE_STOPS_REVERSE=("development")
        local ENV
        local ENV_BRANCHES=("development")
        local ENV_BRANCHES_REVERSE=("development")

        for ENV in "${!DEPLOY_ENVS_ORDER[@]}"; do
            local BRANCH
            local IS_MERGE_STOP
            local USER
            local DOMAIN
            local SERSERVICE_ROOT
            eval "${DEPLOY_ENVS[$ENV]}"

            if [[ "$IS_MERGE_STOP" == "y" ]]; then
                MERGE_STOPS+=("$BRANCH")
                MERGE_STOPS_REVERSE=("$BRANCH" "${MERGE_STOPS[@]}")
            fi

            ENV_BRANCHES+=("$BRANCH")
            ENV_BRANCHES_REVERSE=("$BRANCH" "${ENV_BRANCHES_REVERSE[@]}")
        done

        local MERGE_MENU_MAP
        declare -A MERGE_MENU_MAP=(
            ["quit"]=255
        )
        local MERGE_MENU_ORDER
        declare -a MERGE_MENU_ORDER=(
            "quit"
        )

        local MERGE_STOP
        local PREVIOUS_MERGE_STOP=""
        local MENU_ENTRY
        for MERGE_STOP in "${MERGE_STOPS[@]}"; do
            if [[ -n "$PREVIOUS_MERGE_STOP" ]]; then
                MENU_ENTRY="merge $PREVIOUS_MERGE_STOP up to $MERGE_STOP"
                # shellcheck disable=SC2034
                MERGE_MENU_MAP["$MENU_ENTRY"]="$PREVIOUS_MERGE_STOP:$MERGE_STOP"
                MERGE_MENU_ORDER+=("$MENU_ENTRY")
            fi
            PREVIOUS_MERGE_STOP="$MERGE_STOP"
        done

        MENU_ENTRY="merge ${MERGE_STOPS_REVERSE[0]} down to ${MERGE_STOPS[0]}"
        # shellcheck disable=SC2034
        MERGE_MENU_MAP["$MENU_ENTRY"]="development"
        MERGE_MENU_ORDER+=("$MENU_ENTRY")

        while true; do
            newline

            local ACTION
            ACTION=$(choose "$HEADER" MERGE_MENU_MAP MERGE_MENU_ORDER)
            local EXIT_CODE="$?"

            if [ "$EXIT_CODE" == 255 ]; then
                break
            elif [ "$ACTION" == "development" ]; then
                info "Merging ${ENV_BRANCHES_REVERSE[0]} down to ${ENV_BRANCHES[0]}"
                local BRANCH
                local PREVIOUS_BRANCH=""
                for BRANCH in "${ENV_BRANCHES_REVERSE[@]}"; do
                    git -C "$PROJECT_DIR/htdocs" switch "$BRANCH"
                    git -C "$PROJECT_DIR/htdocs" pull

                    if [[ -n "$PREVIOUS_BRANCH" ]]; then
                        git -C "$PROJECT_DIR/htdocs" merge "$PREVIOUS_BRANCH"
                        git -C "$PROJECT_DIR/htdocs" push
                    fi

                    PREVIOUS_BRANCH="$BRANCH"
                done
            else
                local BOUNDARIES
                # shellcheck disable=SC2206
                BOUNDARIES=(${ACTION//:/ })

                info "Merging ${BOUNDARIES[0]} up to ${BOUNDARIES[1]}"
                local BRANCH
                local PREVIOUS_BRANCH=""
                local SKIP=1
                for BRANCH in "${ENV_BRANCHES[@]}"; do
                    if [[ "$BRANCH" == "${BOUNDARIES[0]}" ]]; then
                        SKIP=0
                    fi

                    if [[ "$SKIP" == 0 ]]; then
                        git -C "$PROJECT_DIR/htdocs" switch "$BRANCH"
                        git -C "$PROJECT_DIR/htdocs" pull

                        if [[ -n "$PREVIOUS_BRANCH" ]]; then
                            git -C "$PROJECT_DIR/htdocs" merge "$PREVIOUS_BRANCH"
                            git -C "$PROJECT_DIR/htdocs" push
                        fi

                        if [[ "$BRANCH" == "${BOUNDARIES[1]}" ]]; then
                            break
                        fi
                    fi

                    PREVIOUS_BRANCH="$BRANCH"
                done
            fi
        done
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
                _merge "$@"
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
                if [[ -f "${PROJECT_DIR}/control-scripts/${COMMAND}.sh" ]]; then
                    "${PROJECT_DIR}/control-scripts/${COMMAND}.sh" "$@"
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

