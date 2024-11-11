#!/bin/bash

# Strict mode
set -euo pipefail
IFS=$'\n\t'

# Global constants
readonly SCRIPT_NAME="banner"
readonly BRANCH="speedtest"
readonly REPO_URL="https://github.com/erfjab/${SCRIPT_NAME}"
readonly RAW_CONTENT_URL="https://raw.githubusercontent.com/erfjab/${SCRIPT_NAME}/${BRANCH}"
readonly INSTALL_DIR="/usr/local/bin"
readonly SCRIPT_PATH="$INSTALL_DIR/$SCRIPT_NAME"

# ANSI color codes
declare -r -A COLORS=(
    [RED]='\033[0;31m'
    [GREEN]='\033[0;32m'
    [YELLOW]='\033[0;33m'
    [BLUE]='\033[0;34m'
    [RESET]='\033[0m'
)

# Ban types and their corresponding remote lists
declare -A ban_lists=(
    [speedtest]="${RAW_CONTENT_URL}/lists/speedtest.list"
    [iranian]="${RAW_CONTENT_URL}/lists/iranian.list"
)

# Dependencies
declare -a DEPENDENCIES=(
    "iptables"
    "curl"
)

# Logging functions
log() { printf "${COLORS[BLUE]}[INFO]${COLORS[RESET]} %s\n" "$*"; }
warn() { printf "${COLORS[YELLOW]}[WARN]${COLORS[RESET]} %s\n" "$*" >&2; }
error() { printf "${COLORS[RED]}[ERROR]${COLORS[RESET]} %s\n" "$*" >&2; exit 1; }
success() { printf "${COLORS[GREEN]}[SUCCESS]${COLORS[RESET]} %s\n" "$*"; }

# Error handling
trap 'error "An error occurred. Exiting..."' ERR

# Utility functions
check_root() {
    [[ $EUID -eq 0 ]] || error "This script must be run as root"
}

check_dependencies() {
    local missing_deps=()
    for dep in "${DEPENDENCIES[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing_deps+=("$dep")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log "Installing missing dependencies: ${missing_deps[*]}"
        if command -v apt &>/dev/null; then
            apt update && apt install -y "${missing_deps[@]}" || error "Failed to install dependencies"
        elif command -v yum &>/dev/null; then
            yum install -y "${missing_deps[@]}" || error "Failed to install dependencies"
        else
            error "Package manager not found. Please install manually: ${missing_deps[*]}"
        fi
    fi
    success "All dependencies are installed."
}

# Installation functions
install_script() {
    log "Installing $SCRIPT_NAME..."
    check_dependencies
    
    if [[ -f "$SCRIPT_PATH" ]]; then
        warn "Previous installation found. Please use 'update' command to update."
        exit 1
    fi
    
    curl -sL "${RAW_CONTENT_URL}/install.sh" -o "$SCRIPT_PATH" || error "Failed to download the script"
    chmod +x "$SCRIPT_PATH" || error "Failed to set execute permissions"
    success "Installation completed successfully!"
}

update_script() {
    log "Updating $SCRIPT_NAME..."
    [[ -f "$SCRIPT_PATH" ]] || error "Script is not installed. Please use 'install' command first."
    
    curl -sL "${RAW_CONTENT_URL}/install.sh" -o "$SCRIPT_PATH" || error "Failed to download the script"
    chmod +x "$SCRIPT_PATH" || error "Failed to set execute permissions"
    success "Update completed successfully!"
}

uninstall_script() {
    log "Uninstalling $SCRIPT_NAME..."
    if [[ -f "$SCRIPT_PATH" ]]; then
        # Remove all ban rules
        for type in "${!ban_lists[@]}"; do
            unban_sites "$type" 2>/dev/null || true
        done
        
        rm -f "$SCRIPT_PATH" || error "Failed to remove script"
        success "Uninstallation completed successfully!"
    else
        warn "Script is not installed."
    fi
}

# Ban management functions
ban_sites() {
    local type="$1"
    [[ -n "${ban_lists[$type]:-}" ]] || error "Invalid ban type: $type"
    
    log "Applying $type bans..."
    
    # Download and process the list
    local temp_file
    temp_file=$(mktemp)
    if curl -sL "${ban_lists[$type]}" -o "$temp_file"; then
        while IFS= read -r site; do
            [[ -z "$site" ]] && continue
            
            # Add string match rules for all protocols
            iptables -A INPUT -m string --string "$site" --algo bm -j DROP
            iptables -A OUTPUT -m string --string "$site" --algo bm -j DROP
            
            success "Banned: $site"
        done < "$temp_file"
        rm -f "$temp_file"
    else
        error "Failed to download ban list for type: $type"
    fi
}

unban_sites() {
    local type="$1"
    [[ -n "${ban_lists[$type]:-}" ]] || error "Invalid ban type: $type"
    
    log "Removing $type bans..."
    
    local temp_file
    temp_file=$(mktemp)
    if curl -sL "${ban_lists[$type]}" -o "$temp_file"; then
        while IFS= read -r site; do
            [[ -z "$site" ]] && continue
            
            # Remove all matching string rules
            iptables -D INPUT -m string --string "$site" --algo bm -j DROP 2>/dev/null || true
            iptables -D OUTPUT -m string --string "$site" --algo bm -j DROP 2>/dev/null || true
            
            success "Unbanned: $site"
        done < "$temp_file"
        rm -f "$temp_file"
    fi
}

show_ban_lists() {
    log "Available ban lists:"
    for type in "${!ban_lists[@]}"; do
        echo -e "\n${COLORS[BLUE]}$type:${COLORS[RESET]}"
        if curl -sL "${ban_lists[$type]}"; then
            echo
        else
            warn "Failed to fetch list"
        fi
    done
}

check_status() {
    log "Checking ban status..."
    for type in "${!ban_lists[@]}"; do
        echo -e "\n${COLORS[BLUE]}$type status:${COLORS[RESET]}"
        
        # Check iptables rules for each site
        local temp_file
        temp_file=$(mktemp)
        if curl -sL "${ban_lists[$type]}" -o "$temp_file"; then
            while IFS= read -r site; do
                [[ -z "$site" ]] && continue
                if iptables -C INPUT -m string --string "$site" --algo bm -j DROP 2>/dev/null && \
                   iptables -C OUTPUT -m string --string "$site" --algo bm -j DROP 2>/dev/null; then
                    success "$site: Banned"
                else
                    warn "$site: Not Banned"
                fi
            done < "$temp_file"
            rm -f "$temp_file"
        else
            warn "Failed to fetch ban list"
        fi
    done
}

print_help() {
    cat <<EOF
${COLORS[BLUE]}Banner Script${COLORS[RESET]} - Simple website blocking tool

${COLORS[YELLOW]}Usage:${COLORS[RESET]} $SCRIPT_NAME <command> [options]

${COLORS[YELLOW]}Commands:${COLORS[RESET]}
  install           Install the script
  update            Update to the latest version
  uninstall         Remove the script and all ban rules
  ban <type>        Block websites of specified type (speedtest/iranian)
  unban <type>      Remove blocks for specified type
  ban list          Show all available ban lists
  status            Show current ban status for all types
  help              Show this help message

${COLORS[YELLOW]}Ban Types:${COLORS[RESET]}
  speedtest         Speed test websites
  iranian          Iranian websites and services

${COLORS[YELLOW]}Features:${COLORS[RESET]}
- Simple string-based blocking using iptables
- Blocks both incoming and outgoing traffic
- Downloads ban lists directly from repository
- Persistent across reboots (when used with iptables-persistent)

${COLORS[YELLOW]}Examples:${COLORS[RESET]}
  $SCRIPT_NAME install
  $SCRIPT_NAME ban speedtest
  $SCRIPT_NAME ban iranian
  $SCRIPT_NAME unban speedtest
  $SCRIPT_NAME ban list
  $SCRIPT_NAME status

${COLORS[YELLOW]}Notes:${COLORS[RESET]}
- This script must be run as root
- Requires working internet connection to fetch ban lists
- Ban lists are maintained in the GitHub repository
EOF
}

# Main function
main() {
    check_root

    if [ $# -eq 0 ]; then
        print_help
        exit 0
    fi

    case "$1" in
        install)
            install_script
            ;;
        update)
            update_script
            ;;
        uninstall)
            uninstall_script
            ;;
        ban)
            if [ "$2" = "list" ]; then
                show_ban_lists
            elif [ $# -eq 2 ] && [[ -n "${ban_lists[$2]:-}" ]]; then
                ban_sites "$2"
            else
                error "Usage: $SCRIPT_NAME ban <type|list>"
            fi
            ;;
        unban)
            if [ $# -eq 2 ] && [[ -n "${ban_lists[$2]:-}" ]]; then
                unban_sites "$2"
            else
                error "Usage: $SCRIPT_NAME unban <type>"
            fi
            ;;
        status)
            check_status
            ;;
        help)
            print_help
            ;;
        *)
            error "Unknown command: $1"
            ;;
    esac
}

# Execute main function
main "$@"