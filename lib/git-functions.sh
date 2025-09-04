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

    # Fetch all remote branches to ensure we have up-to-date information
    _git fetch origin >/dev/null 2>&1

    # Add branch names like '*.*.x' to BRANCHES array
    # Include both local branches and remote branches (strip origin/ prefix)
    mapfile -t BRANCHES < <(_git branch -a --format='%(refname:short)' | sed 's|^origin/||' | grep -E '^[0-9]+\.[0-9]+\.x$' | sort -u)

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

function validateGitRepository() {
    # Check if we're in a git repository
    if ! _git rev-parse --git-dir >/dev/null 2>&1; then
        critical "Not in a git repository"
        exit 1
    fi

    # Check if remote origin exists
    if ! _git remote get-url origin >/dev/null 2>&1; then
        critical "No remote 'origin' configured"
        exit 1
    fi

    # Test remote connection
    if ! _git ls-remote origin >/dev/null 2>&1; then
        critical "Cannot connect to remote repository"
        critical "Please check your network connection and authentication"
        exit 1
    fi

    return 0
}

function validateBranchExists() {
    local BRANCH="$1"

    if [[ -z "$BRANCH" ]]; then
        critical "Branch name cannot be empty"
        exit 1
    fi

    # Check if branch exists locally or remotely
    if ! _git rev-parse --verify "$BRANCH" >/dev/null 2>&1 && \
       ! _git rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1; then
        critical "Branch '$BRANCH' does not exist locally or remotely"
        exit 1
    fi

    return 0
}

function getHighestReleaseBranch() {
    # Get all release branches and find the highest semantic version
    local BRANCHES=()

    # Fetch latest remote branches to ensure we have up-to-date information
    _git fetch origin >/dev/null 2>&1

    # Get both local and remote release branches (format: X.Y.x)
    mapfile -t BRANCHES < <(_git branch -a --format='%(refname:short)' | grep -E '^[0-9]+\.[0-9]+\.x$' | sort -u)

    if [[ ${#BRANCHES[@]} -eq 0 ]]; then
        echo ""
        return
    fi

    # Extract version numbers and sort by semantic version
    local HIGHEST_BRANCH=""
    local HIGHEST_MAJOR=0
    local HIGHEST_MINOR=0

    for branch in "${BRANCHES[@]}"; do
        # Extract version from branch name (e.g., 1.2.x -> 1.2)
        if [[ "$branch" =~ ^([0-9]+)\.([0-9]+)\.x$ ]]; then
            local MAJOR="${BASH_REMATCH[1]}"
            local MINOR="${BASH_REMATCH[2]}"

            # Compare versions
            if [[ $MAJOR -gt $HIGHEST_MAJOR ]] || [[ $MAJOR -eq $HIGHEST_MAJOR && $MINOR -gt $HIGHEST_MINOR ]]; then
                HIGHEST_MAJOR=$MAJOR
                HIGHEST_MINOR=$MINOR
                HIGHEST_BRANCH="$branch"
            fi
        fi
    done

    echo "$HIGHEST_BRANCH"
}

function getNextMajorVersion() {
    local HIGHEST_BRANCH
    HIGHEST_BRANCH=$(getHighestReleaseBranch)

    if [[ -z "$HIGHEST_BRANCH" ]]; then
        echo "1.0.x"
        return
    fi

    # Extract major version and increment
    if [[ "$HIGHEST_BRANCH" =~ ^([0-9]+)\.([0-9]+)\.x$ ]]; then
        local MAJOR="${BASH_REMATCH[1]}"
        echo "$((MAJOR + 1)).0.x"
    else
        critical "Invalid release branch format: $HIGHEST_BRANCH"
        exit 1
    fi
}

function getNextMinorVersion() {
    local HIGHEST_BRANCH
    HIGHEST_BRANCH=$(getHighestReleaseBranch)

    if [[ -z "$HIGHEST_BRANCH" ]]; then
        echo "1.0.x"
        return
    fi

    # Extract major and minor versions and increment minor
    if [[ "$HIGHEST_BRANCH" =~ ^([0-9]+)\.([0-9]+)\.x$ ]]; then
        local MAJOR="${BASH_REMATCH[1]}"
        local MINOR="${BASH_REMATCH[2]}"
        echo "$MAJOR.$((MINOR + 1)).x"
    else
        critical "Invalid release branch format: $HIGHEST_BRANCH"
        exit 1
    fi
}

function selectPatchReleaseBranch() {
    # Get all existing release branches
    local BRANCHES=()

    # Fetch latest remote branches to ensure we have up-to-date information
    _git fetch origin >/dev/null 2>&1

    # Get both local and remote release branches (format: X.Y.x)
    mapfile -t BRANCHES < <(_git branch -a --format='%(refname:short)' | grep -E '^[0-9]+\.[0-9]+\.x$' | sort -V -r)

    if [[ ${#BRANCHES[@]} -eq 0 ]]; then
        critical "No existing release branches found for patch release"
        exit 1
    fi

    # Use the same pattern as getLatestReleaseBranch with choose utility
    local BRANCH_MAP
    declare -A BRANCH_MAP=()
    local BRANCH_ORDER
    declare -a BRANCH_ORDER=()

    # Build the associative array and order array for the choose function
    for BRANCH in "${BRANCHES[@]}"; do
        BRANCH_MAP["$BRANCH"]="$BRANCH"
        BRANCH_ORDER+=("$BRANCH")
    done

    choose "Select release branch to patch" BRANCH_MAP BRANCH_ORDER
}

function gitCreateRelease() {
    local TAG="$1"
    local RELEASE_TYPE=""
    local RELEASE=""

    info "Starting release creation workflow..."

    # Pre-flight checks
    info "Performing pre-flight checks..."

    # Validate git repository
    validateGitRepository

    local PRIMARY_BRANCH
    PRIMARY_BRANCH=$(getPrimaryBranch)

    # Validate primary branch exists
    validateBranchExists "$PRIMARY_BRANCH"

    # Ensure primary branch is up-to-date
    info "Ensuring $PRIMARY_BRANCH branch is up-to-date..."
    if ! _git fetch origin "$PRIMARY_BRANCH"; then
        critical "Failed to fetch latest changes from remote"
        exit 1
    fi

    if ! _git checkout "$PRIMARY_BRANCH"; then
        critical "Failed to checkout $PRIMARY_BRANCH branch"
        exit 1
    fi

    if ! _git reset --hard "origin/$PRIMARY_BRANCH"; then
        critical "Failed to sync with remote $PRIMARY_BRANCH branch"
        exit 1
    fi

    info "Pre-flight checks completed successfully"
    echo

    # Step 1: Check for existing release branches
    info "=== Checking for existing release branches ==="
    local EXISTING_BRANCHES=()
    mapfile -t EXISTING_BRANCHES < <(_git branch -a --format='%(refname:short)' | grep -E '^[0-9]+\.[0-9]+\.x$' | sort -u)

    if [[ ${#EXISTING_BRANCHES[@]} -eq 0 ]]; then
        # No existing release branches - create initial release automatically
        info "No existing release branches found in repository"
        info "Creating initial release branch automatically..."
        echo

        RELEASE="1.0.x"
        RELEASE_TYPE="INITIAL"

        sub_headline "Creating Initial Release Branch"
        info "Automatically creating initial release: $RELEASE"
        gitCreateReleaseBranch "$RELEASE"
        info "✓ Successfully created initial release branch: $RELEASE"

        newline
        info "=== Release Creation Complete ==="
        info "✓ Initial release '$RELEASE' has been successfully created"
        info "✓ Changelog has been generated and committed"
        info "✓ Release branch has been pushed to remote repository"
        newline

        REPLY="$RELEASE"
        return 0
    fi

    # Existing release branches found - proceed with normal classification
    info "Found existing release branches: ${EXISTING_BRANCHES[*]}"
    echo

    # Step 2: Release Type Classification
    info "=== Release Type Classification ==="
    local IS_BREAKING_CHANGE
    IS_BREAKING_CHANGE=$(confirm -n "Is this a Breaking Change? (y/n)")

    if [[ "$IS_BREAKING_CHANGE" == "y" ]]; then
        RELEASE_TYPE="MAJOR"
        info "Classified as: Breaking Change (Major version increment)"
    else
        local IS_NEW_FEATURE
        IS_NEW_FEATURE=$(confirm -n "Is this a new Feature? (y/n)")

        if [[ "$IS_NEW_FEATURE" == "y" ]]; then
            RELEASE_TYPE="MINOR"
            info "Classified as: New Feature (Minor version increment)"
        else
            RELEASE_TYPE="PATCH"
            info "Classified as: Patch (Bug fix or maintenance)"
        fi
    fi

    echo

    # Step 3: Branch Selection Logic (only for existing repositories)
    info "=== Branch Selection ==="
    case "$RELEASE_TYPE" in
        "MAJOR")
            RELEASE=$(getNextMajorVersion)
            info "Automatically selected branch for breaking change: $RELEASE"
            sub_headline "Creating Major Release Branch"
            gitCreateReleaseBranch "$RELEASE"
            info "✓ Successfully created major release branch: $RELEASE"
            ;;
        "MINOR")
            RELEASE=$(getNextMinorVersion)
            info "Automatically selected branch for new feature: $RELEASE"
            sub_headline "Creating Minor Release Branch"
            gitCreateReleaseBranch "$RELEASE"
            info "✓ Successfully created minor release branch: $RELEASE"
            ;;
        "PATCH")
            info "Patch release requires selecting an existing release branch:"
            newline
            local SELECTED_BRANCH
            SELECTED_BRANCH=$(selectPatchReleaseBranch)

            if [[ -z "$SELECTED_BRANCH" ]]; then
                critical "No release branch selected for patch"
                exit 1
            fi

            info "✓ Selected release branch for patching: $SELECTED_BRANCH"

            # Extract version components for patch logic (format: X.Y.x)
            local MAJOR MINOR
            MAJOR=$(echo "$SELECTED_BRANCH" | awk -F. '{print $1}')
            MINOR=$(echo "$SELECTED_BRANCH" | awk -F. '{print $2}')

            info "Determining next patch version for $MAJOR.$MINOR.x..."
            info "Searching for existing tags with pattern: ^$MAJOR\\.$MINOR\\.[0-9]\\+$"

            # Find the latest existing patch tag for this major.minor version
            local EXISTING_PATCHES
            mapfile -t EXISTING_PATCHES < <(_git tag -l | grep "^$MAJOR\.$MINOR\.[0-9]\+$" | sort -V)

            info "Found ${#EXISTING_PATCHES[@]} existing patch tags: ${EXISTING_PATCHES[*]}"

            if [[ ${#EXISTING_PATCHES[@]} -eq 0 ]]; then
                # No existing patches, this is the first tag on this release branch
                # Always start with .0 for the first tag on any release branch
                RELEASE="$MAJOR.$MINOR.0"
                info "No existing tags found for release branch $SELECTED_BRANCH"
                info "Creating first tag on this release branch: $RELEASE"
                info "This is the initial release for the $SELECTED_BRANCH branch"
            else
                # Get the highest existing patch number and increment it
                local HIGHEST_PATCH_TAG="${EXISTING_PATCHES[-1]}"
                local HIGHEST_PATCH_NUM
                HIGHEST_PATCH_NUM="$(echo "$HIGHEST_PATCH_TAG" | awk -F. '{print $3}')"
                RELEASE="$MAJOR.$MINOR.$((HIGHEST_PATCH_NUM + 1))"
                info "Latest patch: $HIGHEST_PATCH_TAG, incrementing to: $RELEASE"
                info "This is a patch release (bug fix) on the $SELECTED_BRANCH branch"
            fi

            sub_headline "Creating Patch Release Tag"
            info "Creating patch tag: $RELEASE on branch $SELECTED_BRANCH"
            # Create Patch Tag on existing Release Branch (includes automatic changelog generation)
            gitCreateTag "$SELECTED_BRANCH" "$RELEASE"
            info "✓ Successfully created patch release: $RELEASE"
            ;;
    esac

    newline
    info "=== Release Creation Complete ==="
    info "✓ Release '$RELEASE' has been successfully created"
    info "✓ Changelog has been generated and committed"
    if [[ "$RELEASE_TYPE" != "PATCH" ]]; then
        info "✓ Release branch has been pushed to remote repository"
    else
        info "✓ Release tag has been pushed to remote repository"
    fi
    newline

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

    # Generate changelog content based on commits since last release
    generateAndEditChangelogForReleaseBranch "$RELEASE" "$WORKTREE_DIR"

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

    # Fetch latest remote state and sync the worktree
    info "Fetching latest remote state and syncing worktree"
    git -C "$WORKTREE_DIR" fetch --all --tags
    git -C "$WORKTREE_DIR" reset --hard "origin/$BRANCH_NAME"

    # Update composer.json with the tag version
    sub_headline "Updating composer.json version for $RELEASE"

    local COMPOSER_JSON
    COMPOSER_JSON=$(cat "$WORKTREE_DIR/composer.json")
    UPDATED_COMPOSER_JSON=$(echo "$COMPOSER_JSON" | jq --arg ver "$RELEASE" '.version = $ver')
    echo "$UPDATED_COMPOSER_JSON" > "$WORKTREE_DIR/composer.json"

    git -C "$WORKTREE_DIR" add composer.json
    git -C "$WORKTREE_DIR" commit -m "release: Updated version in composer.json for $RELEASE"

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

    # Clean up tag format (remove 'v' prefix if present)
    local CLEAN_TAG="$TAG"
    if [[ "$TAG" =~ ^v(.+)$ ]]; then
        CLEAN_TAG="${BASH_REMATCH[1]}"
    fi

    # Get all existing tags and sort them by semver
    local ALL_TAGS
    ALL_TAGS=$(git -C "$WORKTREE_DIR" tag -l | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | sort -V)

    # Find the most recent tag before this one
    local PREVIOUS_TAG=""
    local CURRENT_COMMIT
    CURRENT_COMMIT=$(git -C "$WORKTREE_DIR" rev-parse HEAD)

    # For tag creation, we use current HEAD since the tag doesn't exist yet
    # If tag exists (for existing tag changelog generation), use it
    if git -C "$WORKTREE_DIR" rev-parse --verify "$TAG" >/dev/null 2>&1; then
        CURRENT_COMMIT=$(git -C "$WORKTREE_DIR" rev-parse "$TAG")
    fi

    # Find the previous tag by looking at tags that are ancestors of current commit
    # but exclude the current tag itself
    for tag in $ALL_TAGS; do
        if [[ "$tag" != "$TAG" ]] && [[ "$tag" != "$CLEAN_TAG" ]]; then
            if git -C "$WORKTREE_DIR" merge-base --is-ancestor "$tag" "$CURRENT_COMMIT" 2>/dev/null; then
                PREVIOUS_TAG="$tag"
            fi
        fi
    done

    # Generate changelog content
    if [ -z "$PREVIOUS_TAG" ]; then
        # First tag on this release branch - use the same logic as release branch changelog generation
        # to ensure consistency between release branch and tag changelogs

        # Get existing release branches (excluding the current one being tagged)
        local EXISTING_BRANCHES=()
        local CURRENT_BRANCH_NAME=""
        CURRENT_BRANCH_NAME=$(git -C "$WORKTREE_DIR" branch --show-current)

        # Use the main repository context to get accurate branch information
        mapfile -t EXISTING_BRANCHES < <(_git branch -a --format='%(refname:short)' | grep -E '^[0-9]+\.[0-9]+\.x$' | grep -v "^$CURRENT_BRANCH_NAME$" | sort -V -r)

        if [[ ${#EXISTING_BRANCHES[@]} -gt 0 ]]; then
            # Use the highest existing release branch to determine commit range
            local HIGHEST_EXISTING_BRANCH="${EXISTING_BRANCHES[0]}"
            info "Found highest existing release branch: $HIGHEST_EXISTING_BRANCH" >&2

            # Try to find the branch HEAD - check both local and remote references
            local HIGHEST_BRANCH_HEAD=""
            if _git rev-parse --verify "origin/$HIGHEST_EXISTING_BRANCH" >/dev/null 2>&1; then
                HIGHEST_BRANCH_HEAD="origin/$HIGHEST_EXISTING_BRANCH"
            elif _git rev-parse --verify "$HIGHEST_EXISTING_BRANCH" >/dev/null 2>&1; then
                HIGHEST_BRANCH_HEAD="$HIGHEST_EXISTING_BRANCH"
            fi

            if [[ -n "$HIGHEST_BRANCH_HEAD" ]]; then
                # Find the merge base (common ancestor) between the highest existing release branch and primary branch
                local MERGE_BASE
                MERGE_BASE=$(_git merge-base "$HIGHEST_BRANCH_HEAD" "$PRIMARY_BRANCH" 2>/dev/null)

                if [[ -n "$MERGE_BASE" ]]; then
                    # Get commits from the merge base to current release branch HEAD
                    # This gives us commits that were added to primary branch since the previous release branch was created
                    # PLUS commits that were added to the current release branch after it was created
                    CHANGELOG_CONTENT=$(_git log "$MERGE_BASE..$CURRENT_COMMIT" --pretty=format:"* %h - %s (%an, %ad)" --date=short --no-merges 2>/dev/null | \
                        grep -v "release: " || echo "")
                    info "Generating changelog for first tag: using commit range $MERGE_BASE..$CURRENT_COMMIT (commits added since $HIGHEST_EXISTING_BRANCH was created, including release branch commits)" >&2
                else
                    # Fallback: use commits from the highest existing release branch to current release branch HEAD
                    CHANGELOG_CONTENT=$(_git log "$HIGHEST_BRANCH_HEAD..$CURRENT_COMMIT" --pretty=format:"* %h - %s (%an, %ad)" --date=short --no-merges 2>/dev/null | \
                        grep -v "release: " || echo "")
                    info "Generating changelog for first tag: using commit range $HIGHEST_BRANCH_HEAD..$CURRENT_COMMIT" >&2
                fi
            else
                # Can't find the highest existing release branch, use all commits from current release branch
                CHANGELOG_CONTENT=$(_git log "$CURRENT_COMMIT" --pretty=format:"* %h - %s (%an, %ad)" --date=short --no-merges 2>/dev/null | \
                    grep -v "release: " || echo "")
                info "Generating changelog for first tag: using all commits from current release branch HEAD $CURRENT_COMMIT" >&2
            fi
        else
            # No existing release branches - this is the very first release, include all commits from current release branch
            CHANGELOG_CONTENT=$(_git log "$CURRENT_COMMIT" --pretty=format:"* %h - %s (%an, %ad)" --date=short --no-merges 2>/dev/null | \
                grep -v "release: " || echo "")
            info "Generating changelog for first tag: using all commits from current release branch HEAD $CURRENT_COMMIT (first release)" >&2
        fi
    else
        # Subsequent tags - show commits between previous tag and current tag, excluding release preparation commits
        CHANGELOG_CONTENT=$(git -C "$WORKTREE_DIR" log "$PREVIOUS_TAG".."$CURRENT_COMMIT" --pretty=format:"* %h - %s (%an, %ad)" --date=short --no-merges | \
            grep -v "release: " || echo "")

        # Debug: log the commit range being used (to stderr to avoid contaminating output)
        info "Generating changelog for subsequent tag: using commit range $PREVIOUS_TAG..$CURRENT_COMMIT" >&2
    fi

    # Format the changelog entry with header
    local RELEASE_DATE
    RELEASE_DATE=$(date '+%Y-%m-%d')

    echo "## [$CLEAN_TAG] - $RELEASE_DATE"
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
    local TEMP_EDIT_FILE="$WORKTREE_DIR/CHANGELOG_EDIT.tmp"

    # Clean up tag format for comparison (remove 'v' prefix if present)
    local CLEAN_TAG="$TAG"
    if [[ "$TAG" =~ ^v(.+)$ ]]; then
        CLEAN_TAG="${BASH_REMATCH[1]}"
    fi

    # Generate new changelog entry
    local NEW_ENTRY
    NEW_ENTRY=$(generateChangelogEntry "$TAG" "$WORKTREE_DIR")

    # Create or update CHANGELOG.md with interactive editing
    if [ -f "$CHANGELOG_FILE" ]; then
        # Check if this exact version already exists in the changelog
        # Use the clean tag for comparison to handle both v1.0.0 and 1.0.0 formats
        if grep -q "## \[$CLEAN_TAG\]" "$CHANGELOG_FILE"; then
            info "Entry for $CLEAN_TAG already exists in CHANGELOG.md, skipping" >&2
            return 0
        fi

        # Check if there's an "Unreleased" section that should be replaced
        if grep -q "## \[Unreleased\]" "$CHANGELOG_FILE"; then
            # Replace the Unreleased section with the actual tag entry using awk
            awk -v new_entry="$NEW_ENTRY" '
                /^## \[Unreleased\]/ {
                    # Found Unreleased section, print new entry instead and skip until next ## section
                    print new_entry
                    # Add extra blank line to separate from next section
                    print ""
                    while ((getline > 0) && !/^## \[/) continue
                    if (/^## \[/) print  # Print the line that broke the loop (next section header)
                    next
                }
                { print }
            ' "$CHANGELOG_FILE" > "$TEMP_EDIT_FILE"
        else
            # Insert new entry after the header but before existing entries
            {
                # Extract header (everything before the first ## entry)
                sed '/^## \[/,$d' "$CHANGELOG_FILE"
                echo "$NEW_ENTRY"
                # Add extra blank line to separate from existing entries
                echo ""
                # Extract existing entries (everything from the first ## entry onwards)
                sed -n '/^## \[/,$p' "$CHANGELOG_FILE"
            } > "$TEMP_EDIT_FILE"
        fi
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
        } > "$TEMP_EDIT_FILE"
    fi

    # Open changelog in nano for user editing
    info "Opening changelog for review and editing..." >&2
    echo "Review and edit the changelog below. Save (Ctrl+O) and exit (Ctrl+X) when ready to proceed." >&2
    echo >&2

    if command -v nano >/dev/null 2>&1; then
        nano "$TEMP_EDIT_FILE"
    else
        warning "nano editor not found, using vi instead" >&2
        vi "$TEMP_EDIT_FILE"
    fi

    # Move the edited changelog to final location
    mv "$TEMP_EDIT_FILE" "$CHANGELOG_FILE"

    if [ -f "$CHANGELOG_FILE" ]; then
        info "Updated CHANGELOG.md with entry for $CLEAN_TAG" >&2
    else
        info "Created new CHANGELOG.md with entry for $CLEAN_TAG" >&2
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

            # Sync with remote before pushing
            local CURRENT_BRANCH
            CURRENT_BRANCH=$(git -C "$WORKTREE_DIR" branch --show-current)

            info "Syncing with remote branch before pushing changelog changes"
            if git -C "$WORKTREE_DIR" pull --rebase origin "$CURRENT_BRANCH"; then
                info "Successfully synced with remote branch"

                # Push the changes to remote repository with upstream tracking
                if git -C "$WORKTREE_DIR" push --set-upstream origin "$CURRENT_BRANCH"; then
                    info "Successfully pushed changelog changes to remote repository"
                else
                    warning "Failed to push changelog changes to remote repository"
                    warning "The changelog was committed locally but may not be available on the remote"
                    warning "You may need to manually push the changes later"
                fi
            else
                warning "Failed to sync with remote branch"
                warning "There may be conflicts that need manual resolution"
                warning "The changelog was committed locally but could not be pushed"
                warning "Please manually resolve conflicts and push the changes"
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

function generateAndEditChangelogForReleaseBranch() {
    local RELEASE="$1"
    local WORKTREE_DIR="$2"
    local CHANGELOG_FILE="$WORKTREE_DIR/CHANGELOG.md"
    local TEMP_CHANGELOG="$WORKTREE_DIR/CHANGELOG.tmp"
    local PRIMARY_BRANCH
    PRIMARY_BRANCH=$(getPrimaryBranch)

    info "Generating changelog content for release branch $RELEASE..."

    # Get the highest existing release branch to determine commit range
    # Note: We need to exclude the current release being created
    local EXISTING_BRANCHES=()
    mapfile -t EXISTING_BRANCHES < <(_git branch -a --format='%(refname:short)' | grep -E '^[0-9]+\.[0-9]+\.x$' | grep -v "^$RELEASE$" | sort -V -r)

    local COMMIT_RANGE=""
    local CHANGELOG_CONTENT=""

    if [[ ${#EXISTING_BRANCHES[@]} -gt 0 ]]; then
        # Use the highest existing release branch (excluding the one being created)
        local HIGHEST_EXISTING_BRANCH="${EXISTING_BRANCHES[0]}"
        info "Found highest existing release branch: $HIGHEST_EXISTING_BRANCH"

        # Try to find the branch HEAD - check both local and remote references
        local HIGHEST_BRANCH_HEAD=""
        if _git rev-parse --verify "origin/$HIGHEST_EXISTING_BRANCH" >/dev/null 2>&1; then
            HIGHEST_BRANCH_HEAD="origin/$HIGHEST_EXISTING_BRANCH"
        elif _git rev-parse --verify "$HIGHEST_EXISTING_BRANCH" >/dev/null 2>&1; then
            HIGHEST_BRANCH_HEAD="$HIGHEST_EXISTING_BRANCH"
        else
            warning "Could not find HEAD of highest existing release branch: $HIGHEST_EXISTING_BRANCH"
            warning "Using all commits from primary branch instead"
            HIGHEST_BRANCH_HEAD=""
        fi

        if [[ -n "$HIGHEST_BRANCH_HEAD" ]]; then
            # Find the merge base (common ancestor) between the highest existing release branch and primary branch
            local MERGE_BASE
            MERGE_BASE=$(_git merge-base "$HIGHEST_BRANCH_HEAD" "$PRIMARY_BRANCH" 2>/dev/null)

            if [[ -n "$MERGE_BASE" ]]; then
                # Get commits from the merge base to current primary branch HEAD
                # This gives us commits that were added to primary branch since the release branch was created
                COMMIT_RANGE="$MERGE_BASE..$PRIMARY_BRANCH"
                info "Using commit range: $MERGE_BASE..$PRIMARY_BRANCH (commits added to $PRIMARY_BRANCH since $HIGHEST_EXISTING_BRANCH was created)"
            else
                # Fallback: use commits from the release branch to primary branch
                COMMIT_RANGE="$HIGHEST_BRANCH_HEAD..$PRIMARY_BRANCH"
                info "Could not find merge base, using commit range: $COMMIT_RANGE"
            fi
        else
            # Fallback: use all commits from primary branch
            COMMIT_RANGE="$PRIMARY_BRANCH"
            info "Using all commits from: $COMMIT_RANGE"
        fi
    else
        # No existing release branches, include all commits from primary branch
        COMMIT_RANGE="$PRIMARY_BRANCH"
        info "No existing release branches found, using all commits from: $COMMIT_RANGE"
    fi

    # Generate changelog content from commits using the main repository (not worktree)
    # This ensures we get the full commit history from the primary branch
    info "Generating changelog from commit range: $COMMIT_RANGE"
    CHANGELOG_CONTENT=$(_git log "$COMMIT_RANGE" --pretty=format:"* %h - %s (%an, %ad)" --date=short --no-merges 2>/dev/null | \
        grep -v "release: " || echo "")

    # If no content was generated, provide a fallback message
    if [[ -z "$CHANGELOG_CONTENT" ]]; then
        CHANGELOG_CONTENT="* No significant changes recorded"
        warning "No commits found in range $COMMIT_RANGE, using fallback message"
    else
        info "Generated changelog with $(echo "$CHANGELOG_CONTENT" | wc -l) entries"
    fi

    # Create initial changelog content
    # For release branches, we create a placeholder that will be replaced by actual tag entries
    local RELEASE_DATE
    RELEASE_DATE=$(date '+%Y-%m-%d')

    {
        echo "# Changelog"
        echo ""
        echo "All notable changes to this project will be documented in this file."
        echo ""
        echo "The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),"
        echo "and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)."
        echo ""
        echo "## [Unreleased] - Release branch $RELEASE"
        echo ""
        echo "### Changes planned for this release:"
        echo ""
        echo "$CHANGELOG_CONTENT"
        echo ""
        echo "<!-- Release tags will be added above this line -->"
        echo ""
    } > "$TEMP_CHANGELOG"

    # Open changelog in nano for user editing
    info "Opening changelog for review and editing..."
    echo "Review and edit the changelog below. Save (Ctrl+O) and exit (Ctrl+X) when ready to proceed."
    echo

    if command -v nano >/dev/null 2>&1; then
        nano "$TEMP_CHANGELOG"
    else
        warning "nano editor not found, using vi instead"
        vi "$TEMP_CHANGELOG"
    fi

    # Move the edited changelog to final location
    mv "$TEMP_CHANGELOG" "$CHANGELOG_FILE"

    # Commit the changelog
    git -C "$WORKTREE_DIR" add CHANGELOG.md
    git -C "$WORKTREE_DIR" commit -m "release: Add changelog for release branch $RELEASE"
    info "Committed changelog for release branch $RELEASE"
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