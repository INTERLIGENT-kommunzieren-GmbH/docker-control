#!/bin/bash

# shellcheck disable=SC2034
DEFAULT_IFS=$IFS

function _initUtils() {
    GUM_EXECUTABLE=$(which gum)

    if [[ -z "$GUM_EXECUTABLE" ]]; then
        critical "Gum executable not found in PATH"
        exit 1
    fi
}

function choose() {
    local HEADER
    local OPTION
    local HEIGHT
    HEADER=$(text "$1")
    local -n _OPTIONS_MAP="$2"
    local -n _OPTIONS_ORDER="$3"

    HEIGHT=$((${#_OPTIONS_ORDER[@]} + 2))
    if [ "$HEIGHT" -gt 22 ]; then
        HEIGHT=22
    fi

    OPTION=$("$GUM_EXECUTABLE" choose --header="$HEADER" --height="$HEIGHT" "${_OPTIONS_ORDER[@]}")

    if [ "${_OPTIONS_MAP[$OPTION]}" == 255 ]; then
        return 255
    else
        echo -n "${_OPTIONS_MAP[$OPTION]}"
    fi
}

function choose_multiple() {
    local HEADER
    local OPTIONS
    local HEIGHT
    HEADER=$(text "$1")
    local -n _OPTIONS_MAP="$2"
    local -n _OPTIONS_ORDER="$3"

    HEIGHT=$((${#_OPTIONS_ORDER[@]} + 2))
    if [ "$HEIGHT" -gt 22 ]; then
        HEIGHT=22
    fi

    OPTIONS=$("$GUM_EXECUTABLE" choose --no-limit --header="$HEADER" --height="$HEIGHT" "${_OPTIONS_ORDER[@]}")

    if [ "$OPTIONS" == "" ]; then
      return 255
    fi

    for OPTION in $OPTIONS; do
      echo "${_OPTIONS_MAP[$OPTION]}"
    done
}

function confirm() {
    local DEFAULT="true"
    local QUESTION=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -n)
                DEFAULT="false"
                shift
                ;;
            *)
                QUESTION="$1"
                shift
                ;;
        esac
    done

    if "$GUM_EXECUTABLE" confirm "${QUESTION}" --default="$DEFAULT"; then
        RESULT="y"
    else
        RESULT="n"
    fi
    echo $RESULT
}

function wait_for_keypress() {
    "$GUM_EXECUTABLE" input --placeholder "Press Enter to continue..." --prompt "" --no-show-help
}

function critical() {
    text -f 9 "$@"
}

function debug() {
    text '{{ Foreground "8" (Blink "'"$1"'") }}'
}

function fatal() {
    critical "$1"
    exit 1
}

function headline() {
    local MESSAGE
    MESSAGE=$(text "$1")
    local TERM_WIDTH
    local PADDING=1
    local BORDER_WIDTH=1 # double border left+right
    local EFFECTIVE_WIDTH
    TERM_WIDTH=${COLUMNS:-80}
    EFFECTIVE_WIDTH=$((TERM_WIDTH - PADDING - BORDER_WIDTH))
    if (( EFFECTIVE_WIDTH < 20 )); then
        EFFECTIVE_WIDTH=20
    fi
    "$GUM_EXECUTABLE" style --foreground="0" --background="2" --border=double --border-background="2" --border-foreground="0" --padding="0 2" --width="$EFFECTIVE_WIDTH" --align="center" "$MESSAGE"

    return 0
}

function info() {
    text -f 12 "$@"
}

function printHelp() {
    local TITLE=$1
    local -n HELP_COMMANDS=$2

    sub_headline "$1"
    printf '%s\n' "${HELP_COMMANDS[@]}" | awk -F'\t' '{printf "%-30s %s\n", $1, $2}' | "$GUM_EXECUTABLE" style --foreground 12 --padding "0 0 0 2"
    newline
}

function input() {
    local ALLOW_EMPTY=1
    local DEFAULT_VALUE=""
    local HEADER
    local ECHO=1
    local PARAM
    local PLACEHOLDER

    while [[ $# -gt 0 ]]; do
        case $1 in
            -r | --reference)
                local -n OUTPUT="$2"
                ECHO=0
                shift 2
                ;;
            -d | --default-value)
                DEFAULT_VALUE="$2"
                shift 2
                ;;
            -l | --label)
                HEADER="$(text "$2")"
                shift 2
                ;;
            -n | --not-empty)
                ALLOW_EMPTY=0
                shift
                ;;
            -p | --placeholder)
                PLACEHOLDER="$2"
                shift 2
                ;;
            *)
                critical "unknown option: $1"
                ;;
        esac
    done

    if [ -z "$PLACEHOLDER" ] && [ -n "$DEFAULT_VALUE" ]; then
        PLACEHOLDER="$DEFAULT_VALUE"
    fi

    OUTPUT=""
    while [ -z "$OUTPUT" ]; do
        OUTPUT=$("$GUM_EXECUTABLE" input --header.foreground="12" --header="$HEADER" --placeholder="$PLACEHOLDER")
        if [ -z "$OUTPUT" ] && [ -n "$DEFAULT_VALUE" ]; then
            OUTPUT="$DEFAULT_VALUE"
        fi
        if [ "$ALLOW_EMPTY" -eq 1 ]; then
            break
        fi
    done

    if [ "$ECHO" -eq 1 ]; then
        echo -n "$OUTPUT"
    fi
}

function menu() {
    local HEADER
    local ACTION
    HEADER=$1
    local -n _ACTIONS_MAP="$2"
    local -n _ACTIONS_ORDER="$3"

    while true; do
        ACTION=$(choose "$HEADER" _ACTIONS_MAP _ACTIONS_ORDER)
        if [ "$?" == 255 ]; then
            break
        else
            $ACTION
        fi
    done
}

function newline() {
    echo
}

function prompt() {
    local MESSAGE=$1
    echo -e "$MESSAGE"
}

function select_file() {
    local FILES_DIR="$1"

    sudo "$GUM_EXECUTABLE" file --height 5 "$FILES_DIR"
}

function sub_headline() {
    local MESSAGE
    MESSAGE=$(text "$1")
    local TERM_WIDTH
    TERM_WIDTH=${COLUMNS:-80}
    newline
    "$GUM_EXECUTABLE" style --foreground="0" --background="5" --italic --width="$TERM_WIDTH" --align="center" "$MESSAGE"
}

function text() {
    local MESSAGE
    local ARG
    local FG
    local BG

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--foreground)
                FG=$2
                shift 2
                ;;

            -b|--background)
                BG=$2
                shift 2
                ;;

            *)
                if [[ "$1" == \{\{* ]] || { [[ -z "$FG" ]] && [[ -z "$BG" ]]; }; then
                    MESSAGE="${MESSAGE} $1"
                else
                    if [[ -n "$FG" ]] && [[ -n "$BG" ]]; then
                        MESSAGE="${MESSAGE}"' {{ Color "'"${FG}"'" "'"${BG}"'" "'"$1"'" }}'
                    else
                        if [[ -n "$FG" ]]; then
                            MESSAGE="${MESSAGE}"' {{ Foreground "'"${FG}"'" "'"$1"'" }}'
                        fi

                        if [[ -n "$BG" ]]; then
                            MESSAGE="${MESSAGE}"' {{ Background "'"${BG}"'" "'"$1"'" }}'
                        fi
                    fi
                fi
                shift
                ;;
        esac
    done
    "$GUM_EXECUTABLE" format -t template "$MESSAGE"
    newline
}

function warning() {
    local MESSAGE
    MESSAGE=$(text "$1")

    newline
    "$GUM_EXECUTABLE" style --foreground="11" "$MESSAGE"
}

function validateTeamsWebhookUrl() {
    local url="$1"

    if [[ -z "$url" ]]; then
        return 0  # Empty URL is valid (user chose to skip)
    fi

    # Microsoft Teams webhook URLs follow this pattern:
    # https://outlook.office.com/webhook/...
    # or https://<tenant>.webhook.office.com/webhookb2/...
    if [[ "$url" =~ ^https://outlook\.office\.com/webhook/ ]] || \
       [[ "$url" =~ ^https://[a-zA-Z0-9-]+\.webhook\.office\.com/webhookb2/ ]]; then
        return 0
    else
        critical "Invalid Microsoft Teams webhook URL format"
        critical "Expected format: https://outlook.office.com/webhook/... or https://<tenant>.webhook.office.com/webhookb2/..."
        return 1
    fi
}

function getTeamsWebhookUrlForEnvironment() {
    local environment="$1"

    # Try to get from JSON configuration first
    if [[ -n "${JSON_DEPLOY_ENVS[$environment]:-}" ]]; then
        local env_config="${JSON_DEPLOY_ENVS[$environment]}"
        # Extract TEAMS_WEBHOOK_URL from the configuration string
        if [[ "$env_config" =~ TEAMS_WEBHOOK_URL=([^[:space:]]*) ]]; then
            echo "${BASH_REMATCH[1]}"
            return 0
        fi
    fi

    # Try legacy configuration if JSON not available
    if [[ -n "${DEPLOY_ENVS[$environment]:-}" ]]; then
        local env_config="${DEPLOY_ENVS[$environment]}"
        # Extract TEAMS_WEBHOOK_URL from the configuration string
        if [[ "$env_config" =~ TEAMS_WEBHOOK_URL=([^[:space:]]*) ]]; then
            echo "${BASH_REMATCH[1]}"
            return 0
        fi
    fi

    # No webhook URL found
    echo ""
    return 1
}

function getChangelogFromRelease() {
    local release="$1"
    local project_dir="$2"

    # Validate inputs
    if [[ -z "$release" || -z "$project_dir" ]]; then
        echo "No changelog available"
        return 1
    fi

    # Check if htdocs directory exists
    if [[ ! -d "$project_dir/htdocs" ]]; then
        echo "No changelog available"
        return 1
    fi

    # Try to extract CHANGELOG.md from the specific release using git
    local changelog=""
    if command -v git >/dev/null 2>&1; then
        # Try to get CHANGELOG.md from the specific commit/tag/branch
        changelog=$(git -C "$project_dir/htdocs" show "$release:CHANGELOG.md" 2>/dev/null | head -20 | sed 's/"/\\"/g' | tr '\n' ' ' | sed 's/[[:space:]]*$//')

        # If that fails, try alternative paths
        if [[ -z "$changelog" ]]; then
            changelog=$(git -C "$project_dir/htdocs" show "$release:changelog.md" 2>/dev/null | head -20 | sed 's/"/\\"/g' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        fi

        # If still no changelog found, try CHANGELOG (without extension)
        if [[ -z "$changelog" ]]; then
            changelog=$(git -C "$project_dir/htdocs" show "$release:CHANGELOG" 2>/dev/null | head -20 | sed 's/"/\\"/g' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        fi
    fi

    # If we couldn't extract from git, fall back to current working directory as last resort
    if [[ -z "$changelog" ]]; then
        if [[ -f "$project_dir/htdocs/CHANGELOG.md" ]]; then
            changelog=$(head -20 "$project_dir/htdocs/CHANGELOG.md" | sed 's/"/\\"/g' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        elif [[ -f "$project_dir/htdocs/changelog.md" ]]; then
            changelog=$(head -20 "$project_dir/htdocs/changelog.md" | sed 's/"/\\"/g' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        elif [[ -f "$project_dir/htdocs/CHANGELOG" ]]; then
            changelog=$(head -20 "$project_dir/htdocs/CHANGELOG" | sed 's/"/\\"/g' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        fi
    fi

    # Return the changelog or default message
    if [[ -n "$changelog" ]]; then
        echo "$changelog"
    else
        echo "No changelog available for release $release"
    fi
}

# Sanitize names for use as identifiers, environment variables, or file names
function sanitizeName() {
    local input="$1"
    echo "$input" | tr "[:upper:]/\\.:,-" "[:lower:]______"
}

function sendTeamsDeploymentNotification() {
    local webhook_url="$1"
    local project_name="$2"
    local environment="$3"
    local release="$4"
    local status="$5"
    local changelog="$6"

    # Skip if no webhook URL is provided
    if [[ -z "$webhook_url" ]]; then
        return 0
    fi

    # Validate required parameters
    if [[ -z "$project_name" || -z "$environment" || -z "$release" || -z "$status" ]]; then
        warning "Missing required parameters for Teams notification"
        return 1
    fi

    # Set default values
    if [[ -z "$changelog" ]]; then
        changelog="No changelog available"
    fi

    # Determine color and title based on status
    local color=""
    local title=""
    case "$status" in
        "started")
            color="0078D4"  # Blue
            title="🚀 Deployment Started"
            ;;
        "success")
            color="107C10"  # Green
            title="✅ Deployment Successful"
            ;;
        "failed")
            color="D13438"  # Red
            title="❌ Deployment Failed"
            ;;
        *)
            color="605E5C"  # Gray
            title="📋 Deployment Update"
            ;;
    esac

    # Create Teams message card payload
    local payload
    payload=$(cat <<EOF
{
    "@type": "MessageCard",
    "@context": "http://schema.org/extensions",
    "themeColor": "$color",
    "summary": "$title: $project_name ($environment)",
    "sections": [{
        "activityTitle": "$title",
        "activitySubtitle": "$project_name",
        "facts": [{
            "name": "Project:",
            "value": "$project_name"
        }, {
            "name": "Environment:",
            "value": "$environment"
        }, {
            "name": "Release:",
            "value": "$release"
        }, {
            "name": "Status:",
            "value": "$status"
        }],
        "text": "**Changelog:**\\n\\n$changelog"
    }]
}
EOF
)

    # Send the webhook notification
    if command -v curl >/dev/null 2>&1; then
        if curl -s -X POST \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "$webhook_url" >/dev/null 2>&1; then
            debug "Teams notification sent successfully"
            return 0
        else
            warning "Failed to send Teams notification to $webhook_url"
            return 1
        fi
    else
        warning "curl not available - cannot send Teams notification"
        return 1
    fi
}
