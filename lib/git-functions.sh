#!/bin/bash

function _git() {
    git -C "$PROJECT_DIR"/htdocs "$@"
}

function _ensureGitConfig() {
    # Configure Git user if not already set (for container environments)
    if ! git config --global user.name >/dev/null 2>&1; then
        git config --global user.name "Docker Plugin"
        git config --global user.email "docker-plugin@interligent.com"
    fi
}

function _testRemoteConnection() {
    local WORKTREE_DIR="$1"

    # Test if we can reach the remote repository
    if git -C "$WORKTREE_DIR" ls-remote origin >/dev/null 2>&1; then
        return 0
    else
        warning "Cannot connect to remote repository"
        local REMOTE_URL
        REMOTE_URL=$(git -C "$WORKTREE_DIR" remote get-url origin 2>/dev/null || echo "Unknown")
        warning "Remote URL: $REMOTE_URL"
        warning "Please check your SSH keys and network connection"
        return 1
    fi
}

function _pushWithErrorHandling() {
    local WORKTREE_DIR="$1"
    local REF="$2"
    local REF_TYPE="$3"  # "branch" or "tag"
    local PUSH_ARGS="$4" # Additional push arguments (e.g., "-u origin")

    local PUSH_CMD="git -C \"$WORKTREE_DIR\" push"
    if [[ -n "$PUSH_ARGS" ]]; then
        PUSH_CMD="$PUSH_CMD $PUSH_ARGS"
    fi
    PUSH_CMD="$PUSH_CMD \"$REF\""

    if eval "$PUSH_CMD"; then
        info "Successfully pushed $REF_TYPE $REF to remote repository"
        return 0
    else
        critical "Failed to push $REF_TYPE $REF to remote repository"
        critical "The $REF_TYPE was created locally but is not available on the remote"
        critical "Please check your network connection and repository access rights"
        return 1
    fi
}

function getLatestReleaseBranches() {
    local BRANCHES=()
    local LATEST_BRANCHES=()
    local NUMBER_OF_MAJOR_VERSIONS=2
    local NUMBER_OF_MINOR_VERSIONS=3

    # Add branch names like '*.*.x' to BRANCHES array
    mapfile -t BRANCHES < <(_git branch -a --format='%(refname:short)' | grep -E '^[0-9]+\.[0-9]+\.x$')
    mapfile -t BRANCHES < <(printf "%s\n" "${BRANCHES[@]}" | sort -u)

    # Extract last N major versions (numerically descending)
    local MAJOR_VERSIONS=()
    mapfile -t MAJOR_VERSIONS < <(printf "%s\n" "${BRANCHES[@]}" | awk -F. '{print $1}' | sort -u -r | head -n "$NUMBER_OF_MAJOR_VERSIONS")

    for MAJOR_VERSION in "${MAJOR_VERSIONS[@]}"; do
        # Extract unique minors for this major, descending, limited to NUMBER_OF_MINOR_VERSIONS
        local MINOR_VERSIONS=()
        local M m p
        mapfile -t MINOR_VERSIONS < <(printf "%s\n" "${BRANCHES[@]}" | while IFS=. read -r M m p; do
            if [[ $M == "$MAJOR_VERSION" ]]; then
                echo "$M.$m.0"
            fi
        done | sort -u -r | head -n "$NUMBER_OF_MINOR_VERSIONS")

        local MINOR PREFIX BRANCH
        for MINOR in "${MINOR_VERSIONS[@]}"; do
            PREFIX="${MINOR%.*}."
            # From all branches, find those starting with prefix, then sort descending and pick latest
            LATEST_BRANCHES+=( "$(printf "%s\n" "${BRANCHES[@]}" | while IFS= read -r BRANCH; do
                if [[ $BRANCH == $PREFIX* ]]; then
                    echo "$BRANCH"
                fi
            done | sort -V -r | head -n 1)" )
        done
    done

    # Output or return the LATEST_BRANCHES array
    printf "%s\n" "${LATEST_BRANCHES[@]}"
}

function getLatestTags() {
    local INCL_BRANCHES="${1:-n}"
    local TAGS=()
    local LATEST_TAGS=()
    local NUMBER_OF_MAJOR_VERSIONS=2
    local NUMBER_OF_MINOR_VERSIONS=3

    # Read all tags into an array
    _git fetch --tags
    mapfile -t TAGS < <(_git tag -l | sort -u)

    if [[ "$INCL_BRANCHES" != "n" ]]; then
        # Add branch names like '*.*.x' to TAGS array
        local BRANCHES=()
        mapfile -t BRANCHES < <(_git branch -a --format='%(refname:short)' | grep -E '^[0-9]+\.[0-9]+\.x$')
        TAGS+=( "${BRANCHES[@]}" )
        mapfile -t TAGS < <(printf "%s\n" "${TAGS[@]}" | sort -u)
    fi

    # Extract last N major versions (numerically descending)
    local MAJOR_VERSIONS=()
    mapfile -t MAJOR_VERSIONS < <(printf "%s\n" "${TAGS[@]}" | awk -F. '{print $1}' | sort -u -r | head -n "$NUMBER_OF_MAJOR_VERSIONS")

    for MAJOR_VERSION in "${MAJOR_VERSIONS[@]}"; do
        # Extract unique minors for this major, descending, limited to NUMBER_OF_MINOR_VERSIONS
        local MINOR_VERSIONS=()
        local M m p
        mapfile -t MINOR_VERSIONS < <(printf "%s\n" "${TAGS[@]}" | while IFS=. read -r M m p; do
            if [[ $M == "$MAJOR_VERSION" ]]; then
                echo "$M.$m.0"
            fi
        done | sort -u -r | head -n "$NUMBER_OF_MINOR_VERSIONS")

        local MINOR PREFIX TAG
        for MINOR in "${MINOR_VERSIONS[@]}"; do
            PREFIX="${MINOR%.*}."
            # From all tags, find those starting with prefix, then sort descending and pick latest
            LATEST_TAGS+=( "$(printf "%s\n" "${TAGS[@]}" | while IFS= read -r TAG; do
                if [[ $TAG == $PREFIX* ]]; then
                    echo "$TAG"
                fi
            done | sort -V -r | head -n 1)" )
        done
    done

    # Output or return the LATEST_TAGS array
    printf "%s\n" "${LATEST_TAGS[@]}"
}

function gitCreateRelease() {
    local IS_NEW_MAJOR
    local IS_NEW_MINOR
    local TAGS
    local TAG="$1"
    local RELEASE
    local LATEST_MAJOR
    local LATEST_MINOR
    local LATEST_PATCH

    if [[ -z "$TAG" ]]; then
        # set latest tag if no tag was given
        mapfile -t TAGS < <(getLatestTags 1)

        if [[ ${#TAGS[@]} -eq 0 ]]; then
            RELEASE="1.0.x"

            gitCreateReleaseBranch "$RELEASE"
            info "No existing tags found, creating initial release: $RELEASE"
            REPLY="$RELEASE"
            return
        fi
        TAG="${TAGS[0]}"
    fi

    IS_NEW_MAJOR=$(confirm -n "Does the release include breaking changes?")
    LATEST_MAJOR="$(echo "$TAG" | awk -F. '{print $1}')"

    if [[ "$IS_NEW_MAJOR" == "y" ]]; then
        RELEASE="$((LATEST_MAJOR + 1)).0.x"

        # Create Major Release Worktree
        gitCreateReleaseBranch "$RELEASE"
        info "Created major release branch: $RELEASE"
    else
        LATEST_MINOR="$(echo "$TAG" | awk -F. '{print $2}')"
        IS_NEW_MINOR=$(confirm -n "Does the release include new features?")

        if [[ "$IS_NEW_MINOR" == "y" ]]; then
            RELEASE="$LATEST_MAJOR.$((LATEST_MINOR + 1)).x"

            # Create Minor Release Worktree
            gitCreateReleaseBranch "$RELEASE"
            info "Created minor release branch: $RELEASE"
        else
            # Patch Release Logic
            LATEST_PATCH="$(echo "$TAG" | awk -F. '{print $3}')"
            if [[ "$LATEST_PATCH" == "x" ]]; then
                RELEASE="$LATEST_MAJOR.$LATEST_MINOR.0"
            else
                RELEASE="$LATEST_MAJOR.$LATEST_MINOR.$((LATEST_PATCH + 1))"
            fi

            # Create Patch Tag on existing Release Branch (includes automatic changelog generation)
            gitCreateTag "$LATEST_MAJOR.$LATEST_MINOR.x" "$RELEASE"
        fi
    fi

    REPLY="$RELEASE"
}

function gitCreateReleaseBranch() {
    local RELEASE="$1"
    local WORKTREE_DIR="$PROJECT_DIR/releases/$RELEASE"

    # Ensure Git configuration is set
    _ensureGitConfig

    mkdir -p "$PROJECT_DIR/releases"
    if ! _git worktree add "$WORKTREE_DIR" -b "$RELEASE" "$(getPrimaryBranch)"; then
        critical "Error: Failed to create release worktree" >&2
        exit 1
    fi

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
        -e SSH_AUTH_PORT="$SSH_AUTH_PORT" \
        -e SSH_AUTH_SOCK=/tmp/ssh-agent.sock \
        --add-host "host.docker.internal:host-gateway" \
        -v "$PROJECT_DIR/volumes/composer-cache:/var/www/.composer/cache" \
        -v "$WORKTREE_DIR":/var/www/html fduarte42/docker-php:"$PHP_VERSION" \
        bash -c "/docker-php-init; composer i -o"

    info "Cleaning up vendor folder"
    rm -rf "$WORKTREE_DIR/vendor"

    git -C "$WORKTREE_DIR" add composer.lock
    git -C "$WORKTREE_DIR" commit -m "release: Add composer.lock for $RELEASE"

    local COMPOSER_JSON
    COMPOSER_JSON=$(cat "$WORKTREE_DIR/composer.json")
    UPDATED_COMPOSER_JSON=$(echo "$COMPOSER_JSON" | jq --arg ver "$RELEASE" '.version = $ver')
    echo "$UPDATED_COMPOSER_JSON" > "$WORKTREE_DIR/composer.json"

    git -C "$WORKTREE_DIR" add composer.json
    git -C "$WORKTREE_DIR" commit -m "release: Updated version in composer.json for $RELEASE"

    # Generate and commit changelog for release branch
    sub_headline "Generating changelog for release branch $RELEASE"

    # For release branches, we'll create a placeholder changelog entry
    local CHANGELOG_FILE="$WORKTREE_DIR/CHANGELOG.md"
    local RELEASE_DATE
    RELEASE_DATE=$(date '+%Y-%m-%d')

    if [ ! -f "$CHANGELOG_FILE" ]; then
        # Create new changelog file for release branch
        {
            echo "# Changelog"
            echo ""
            echo "All notable changes to this project will be documented in this file."
            echo ""
            echo "The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),"
            echo "and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)."
            echo ""
            echo "## [$RELEASE] - $RELEASE_DATE"
            echo ""
            echo "* Release branch created"
            echo ""
        } > "$CHANGELOG_FILE"

        git -C "$WORKTREE_DIR" add CHANGELOG.md
        git -C "$WORKTREE_DIR" commit -m "release: Add initial changelog for $RELEASE"
        info "Created initial CHANGELOG.md for release branch $RELEASE"
    fi

    # Test remote connection before attempting to push
    if ! _testRemoteConnection "$WORKTREE_DIR"; then
        critical "Cannot establish connection to remote repository"
        critical "Please ensure:"
        critical "  - SSH keys are properly configured and added to SSH agent"
        critical "  - You have push access to the repository"
        critical "  - The remote repository URL is correct"
        exit 1
    fi

    # Push the release branch to remote with upstream tracking
    if ! _pushWithErrorHandling "$WORKTREE_DIR" "$RELEASE" "branch" "-u origin"; then
        exit 1
    fi

    info "Created and pushed release branch $RELEASE"

    # Remove worktree
    if ! _git worktree remove "$WORKTREE_DIR" --force; then
        warning "Could not remove worktree automatically: $WORKTREE_DIR"
    fi
}

function gitCreateTag() {
    local BRANCH_NAME="$1"
    local RELEASE="$2"
    local WORKTREE_DIR="$PROJECT_DIR/releases/$BRANCH_NAME"

    # Ensure Git configuration is set
    _ensureGitConfig

    _git worktree add "$WORKTREE_DIR" "$BRANCH_NAME"

    if [[ ! -d "$WORKTREE_DIR" ]]; then
        critical "Error: Release branch worktree not found: $WORKTREE_DIR"
        critical "Please create the release branch first."
        exit 1
    fi

    # Generate and commit changelog before creating tag
    sub_headline "Generating changelog for $RELEASE"

    # Generate and write changelog based on current HEAD
    writeChangelogToFile "$RELEASE" "$WORKTREE_DIR"

    # Commit the changelog
    commitChangelog "$WORKTREE_DIR" "$RELEASE"

    # Create the tag after changelog is committed
    if git -C "$WORKTREE_DIR" tag "$RELEASE"; then
        info "Created local tag: $RELEASE"

        # Test remote connection before attempting to push tag
        if ! _testRemoteConnection "$PROJECT_DIR/htdocs"; then
            critical "Cannot establish connection to remote repository for tag push"
            critical "The tag was created locally but cannot be pushed to remote"
            exit 1
        fi

        # Push the tag to remote repository using _git (which operates from htdocs)
        if _git push origin "$RELEASE"; then
            info "Successfully pushed tag $RELEASE to remote repository"
            info "Created patch tag: $RELEASE with changelog"
        else
            critical "Failed to push tag $RELEASE to remote repository"
            critical "The tag was created locally but is not available on the remote"
            critical "Please check your network connection and repository access rights"
            exit 1
        fi
    else
        critical "Error: Failed to create local tag '$RELEASE'" >&2
        exit 1
    fi

    # Remove worktree
    if ! _git worktree remove "$WORKTREE_DIR" --force; then
        warning "Could not remove worktree automatically: $WORKTREE_DIR"
    fi
}


function getGitChangeLog() {
    local CURRENT_TAG="$1"
    local PRIMARY_BRANCH
    PRIMARY_BRANCH=$(getPrimaryBranch)

    # Get all tags and sort them by semver
    local ALL_TAGS
    ALL_TAGS=$(_git tag -l | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V)

    # Find previous tag
    local PREVIOUS_TAG=""
    local FOUND_CURRENT=false

    for tag in $ALL_TAGS; do
        if [ "$tag" = "$CURRENT_TAG" ]; then
            FOUND_CURRENT=true
            break
        fi
        PREVIOUS_TAG="$tag"
    done

    # Check if current tag exists
    if [ "$FOUND_CURRENT" = false ]; then
        critical "Error: Tag '$CURRENT_TAG' not found"
        exit 1
    fi

    # Generate changelog
    if [ -z "$PREVIOUS_TAG" ]; then
        # First tag - show all commits from branch
        _git log "$PRIMARY_BRANCH" --pretty=format:"* %h - %s (%an, %ad)" --date=short --no-merges
    else
        # Show commits between previous and current tag
        _git log "$PREVIOUS_TAG".."$CURRENT_TAG" --pretty=format:"* %h - %s (%an, %ad)" --date=short --no-merges
    fi
}

function generateChangelogEntry() {
    local TAG="$1"
    local WORKTREE_DIR="$2"
    local CHANGELOG_CONTENT
    local PRIMARY_BRANCH
    PRIMARY_BRANCH=$(getPrimaryBranch)

    # Get all existing tags and sort them by semver
    local ALL_TAGS
    ALL_TAGS=$(git -C "$WORKTREE_DIR" tag -l | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | sort -V)

    # Find the most recent tag before this one
    local PREVIOUS_TAG=""
    local CURRENT_COMMIT
    CURRENT_COMMIT=$(git -C "$WORKTREE_DIR" rev-parse HEAD)

    # If tag exists, use it; otherwise use current HEAD
    if git -C "$WORKTREE_DIR" rev-parse --verify "$TAG" >/dev/null 2>&1; then
        CURRENT_COMMIT=$(git -C "$WORKTREE_DIR" rev-parse "$TAG")
    fi

    # Find the previous tag by looking at tags that are ancestors of current commit
    for tag in $ALL_TAGS; do
        if git -C "$WORKTREE_DIR" merge-base --is-ancestor "$tag" "$CURRENT_COMMIT" 2>/dev/null; then
            PREVIOUS_TAG="$tag"
        fi
    done

    # Generate changelog content
    if [ -z "$PREVIOUS_TAG" ]; then
        # First tag - show all commits from primary branch to current commit
        CHANGELOG_CONTENT=$(git -C "$WORKTREE_DIR" log "$CURRENT_COMMIT" --pretty=format:"* %h - %s (%an, %ad)" --date=short --no-merges)
    else
        # Show commits between previous tag and current commit
        CHANGELOG_CONTENT=$(git -C "$WORKTREE_DIR" log "$PREVIOUS_TAG".."$CURRENT_COMMIT" --pretty=format:"* %h - %s (%an, %ad)" --date=short --no-merges)
    fi

    # Format the changelog entry with header
    local RELEASE_DATE
    RELEASE_DATE=$(date '+%Y-%m-%d')

    echo "## [$TAG] - $RELEASE_DATE"
    echo ""
    if [ -n "$CHANGELOG_CONTENT" ]; then
        echo "$CHANGELOG_CONTENT"
    else
        echo "* No changes recorded"
    fi
    echo ""
}

function writeChangelogToFile() {
    local TAG="$1"
    local WORKTREE_DIR="$2"
    local CHANGELOG_FILE="$WORKTREE_DIR/CHANGELOG.md"
    local TEMP_FILE="$WORKTREE_DIR/CHANGELOG.tmp"

    # Generate new changelog entry
    local NEW_ENTRY
    NEW_ENTRY=$(generateChangelogEntry "$TAG" "$WORKTREE_DIR")

    # Create or update CHANGELOG.md
    if [ -f "$CHANGELOG_FILE" ]; then
        # Prepend new entry to existing changelog
        {
            echo "$NEW_ENTRY"
            cat "$CHANGELOG_FILE"
        } > "$TEMP_FILE"
        mv "$TEMP_FILE" "$CHANGELOG_FILE"
        info "Updated existing CHANGELOG.md with entry for $TAG"
    else
        # Create new changelog file
        {
            echo "# Changelog"
            echo ""
            echo "All notable changes to this project will be documented in this file."
            echo ""
            echo "The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),"
            echo "and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)."
            echo ""
            echo "$NEW_ENTRY"
        } > "$CHANGELOG_FILE"
        info "Created new CHANGELOG.md with entry for $TAG"
    fi
}

function commitChangelog() {
    local WORKTREE_DIR="$1"
    local TAG="$2"

    # Ensure Git configuration is set
    _ensureGitConfig

    # Stage and commit the changelog
    if git -C "$WORKTREE_DIR" add CHANGELOG.md; then
        if git -C "$WORKTREE_DIR" commit -m "release: update changelog"; then
            info "Committed CHANGELOG.md to release branch"

            # Push the changes to remote repository
            if git -C "$WORKTREE_DIR" push; then
                info "Successfully pushed changelog changes to remote repository"
            else
                warning "Failed to push changelog changes to remote repository"
                warning "The changelog was committed locally but may not be available on the remote"
                warning "You may need to manually push the changes later"
            fi
        else
            warning "Failed to commit CHANGELOG.md"
        fi
    else
        warning "Failed to stage CHANGELOG.md"
    fi
}

function gitGenerateAndCommitChangelog() {
    local TAG="$1"
    local BRANCH_NAME="$2"
    local WORKTREE_DIR
    local TEMP_WORKTREE=false

    if [[ -z "$TAG" ]]; then
        critical "Error: TAG parameter is required"
        exit 1
    fi

    # If branch name is provided, use it; otherwise derive from tag
    if [[ -z "$BRANCH_NAME" ]]; then
        # Extract branch name from tag (e.g., v1.2.3 -> 1.2.x)
        if [[ "$TAG" =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
            BRANCH_NAME="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.x"
        else
            critical "Error: Cannot derive branch name from tag '$TAG'. Please provide branch name."
            exit 1
        fi
    fi

    WORKTREE_DIR="$PROJECT_DIR/releases/$BRANCH_NAME"

    # Check if worktree already exists
    if [[ ! -d "$WORKTREE_DIR" ]]; then
        # Create temporary worktree
        _git worktree add "$WORKTREE_DIR" "$BRANCH_NAME"
        TEMP_WORKTREE=true
        info "Created temporary worktree for $BRANCH_NAME"
    fi

    # Verify tag exists
    if ! git -C "$WORKTREE_DIR" rev-parse --verify "$TAG" >/dev/null 2>&1; then
        critical "Error: Tag '$TAG' not found in repository"
        if [[ "$TEMP_WORKTREE" == "true" ]]; then
            _git worktree remove "$WORKTREE_DIR" --force
        fi
        exit 1
    fi

    sub_headline "Generating changelog for $TAG"

    # Generate and write changelog
    writeChangelogToFile "$TAG" "$WORKTREE_DIR"

    # Commit the changelog
    commitChangelog "$WORKTREE_DIR" "$TAG"

    info "Successfully generated and committed changelog for $TAG"

    # Clean up temporary worktree if created
    if [[ "$TEMP_WORKTREE" == "true" ]]; then
        if ! _git worktree remove "$WORKTREE_DIR" --force; then
            warning "Could not remove temporary worktree automatically: $WORKTREE_DIR"
        fi
    fi
}

function getTagComment() {
    local TAG="$1"

    # Check if TAG is a tag (exists as a Git tag) or is a branch name
    if _git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
        # For tags, get annotation/message (empty if lightweight tag)
        COMMENT=$(_git tag -n99 | grep "^$TAG" | sed "s/^$TAG\s*//")
    else
        # For branches, no comment available
        COMMENT=""
    fi
    printf "%s" "$COMMENT"
}

function getPrimaryBranch() {
    if _git rev-parse --verify --quiet refs/heads/main  >/dev/null; then
        echo "main"
    elif _git rev-parse --verify --quiet refs/heads/master >/dev/null; then
        echo "master"
    else
        critical "could not find main or master branch"
        exit 1
    fi
}

function getLatestReleaseBranch() {
    local BRANCHES
    BRANCHES=$(getLatestReleaseBranches)

    if [[ -z "$BRANCHES" ]]; then
        critical "No release branches found"
        exit 1
    fi

    local BRANCH_MAP
    declare -A BRANCH_MAP=()
    local BRANCH_ORDER
    declare -a BRANCH_ORDER=()

    IFS=$'\n'
    for BRANCH in $BRANCHES; do
        BRANCH_MAP["$BRANCH"]="$BRANCH"
        BRANCH_ORDER+=("$BRANCH")
    done
    IFS="$DEFAULT_IFS"

    choose "Select release branch" BRANCH_MAP BRANCH_ORDER
}