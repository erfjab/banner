#!/bin/bash

# Strict mode
set -euo pipefail
IFS=$'\n\t'

# Global constants
readonly SCRIPT_NAME="banner"
readonly BRANCH="master"
readonly REPO_URL="https://github.com/erfjab/${SCRIPT_NAME}"
readonly RAW_CONTENT_URL="https://raw.githubusercontent.com/erfjab/${SCRIPT_NAME}/${BRANCH}"
readonly INSTALL_DIR="/usr/local/bin"
readonly SCRIPT_PATH="$INSTALL_DIR/$SCRIPT_NAME"
readonly VERSION="0.2.0"

# ANSI color codes
declare -r -A COLORS=(
    [RED]='\033[0;31m'
    [GREEN]='\033[0;32m'
    [YELLOW]='\033[0;33m'
    [BLUE]='\033[0;34m'
    [RESET]='\033[0m'
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

# Install required packages
install_dependencies() {
    local packages=("iptables" "ipset" "dnsutils" "iptables-persistent" "curl")
    
    for pkg in "${packages[@]}"; do
        if ! command -v "$pkg" &>/dev/null; then
            log "Installing $pkg..."
            if command -v apt &>/dev/null; then
                apt update && apt install -y "$pkg" || error "Failed to install $pkg"
            elif command -v yum &>/dev/null; then
                yum install -y "$pkg" || error "Failed to install $pkg"
            else
                error "Package manager not found. Please install manually: $pkg"
            fi
        fi
    done
}


declare -a SPEEDTEST_DOMAINS=(
    "speedtest.net"
    "www.speedtest.net"
    "c.speedtest.net"
    "speedcheck.org"
    "www.speedcheck.org"
    "a1.etrality.com"
    "net.etrality.com"
    "api.speedspot.org"
    "fast.com"
    "www.fast.com"
)


# Installation functions
install_script() {
    log "Installing $SCRIPT_NAME..."
    
    if [[ -f "$SCRIPT_PATH" ]]; then
        warn "Previous installation found!"
        rm -f "$SCRIPT_PATH" || error "Failed to remove script"
    fi
    
    curl -sL "${RAW_CONTENT_URL}/install.sh" -o "$SCRIPT_PATH" || error "Failed to download the script"
    chmod +x "$SCRIPT_PATH" || error "Failed to set execute permissions"
    success "Installation completed successfully!"
}


uninstall_script() {
    log "Uninstalling $SCRIPT_NAME..."
    if [[ -f "$SCRIPT_PATH" ]]; then
        rm -f "$SCRIPT_PATH" || error "Failed to remove script"
        success "Uninstallation completed successfully!"
    else
        warn "Script is not installed."
    fi
}


ban_speedtest() {
    local chain="speedtest_chain"
    local set="speedtest_set"
    local speedtest_ips=()
    
    log "Starting speedtest blocking procedure..."
    
    # Create ipset if it doesn't exist
    if ! ipset list "$set" &>/dev/null; then
        ipset create "$set" hash:net comment maxelem 20000
    fi
    
    # Resolve domains to IPs
    for domain in "${SPEEDTEST_DOMAINS[@]}"; do
        log "Resolving $domain..."
        while IFS= read -r ip; do
            [[ -n "$ip" ]] && speedtest_ips+=("$ip")
        done < <(host "$domain" | awk '/has address/ {print $NF}')
    done
    
    # Add IPs to ipset
    for ip in "${speedtest_ips[@]}"; do
        if ! ipset test "$set" "$ip" &>/dev/null; then
            ipset add "$set" "$ip" comment "speedtest"
            success "Added $ip to blocklist"
        fi
    done
    
    # Create and configure iptables chain
    if ! iptables -nL "$chain" >/dev/null 2>&1; then
        iptables -N "$chain"
        
        # Block by IP using ipset
        iptables -I "$chain" -m set --match-set "$set" dst -j DROP
        
        # Block by string matching
        iptables -I "$chain" -m string --string "speedtest" --algo bm -j DROP
        iptables -I "$chain" -m string --string "speedcheck" --algo bm -j DROP
        iptables -I "$chain" -m string --string "fast.com" --algo bm -j DROP
        
        # Apply chain to both INPUT and OUTPUT
        iptables -I INPUT -j "$chain"
        iptables -I OUTPUT -j "$chain"
    fi
    
    # Save rules
    iptables-save > /etc/iptables/rules.v4
    ipset save > /etc/iptables/ipset.rules
    
    systemctl enable iptables-persistent
    systemctl start iptables-persistent
    
    success "Speedtest blocking has been successfully configured!"
}


# Unban function
unban_speedtest() {
    local chain="speedtest_chain"
    local set="speedtest_set"
    
    log "Removing speedtest blocks..."
    
    # Remove iptables chain
    if iptables -nL "$chain" >/dev/null 2>&1; then
        iptables -D INPUT -j "$chain" 2>/dev/null || true
        iptables -D OUTPUT -j "$chain" 2>/dev/null || true
        iptables -F "$chain" 2>/dev/null || true
        iptables -X "$chain" 2>/dev/null || true
    fi
    
    # Remove ipset
    if ipset list "$set" &>/dev/null; then
        ipset destroy "$set"
    fi
    
    # Save changes
    iptables-save > /etc/iptables/rules.v4
    ipset save > /etc/iptables/ipset.rules
    
    success "Speedtest blocks have been removed!"
}


# Check status
check_status() {
    local chain="speedtest_chain"
    local set="speedtest_set"
    
    log "Checking speedtest blocking status..."
    
    if iptables -nL "$chain" >/dev/null 2>&1; then
        success "Speedtest blocking is active"
        if ipset list "$set" &>/dev/null; then
            echo -e "\nBlocked IPs:"
            ipset list "$set"
        fi
    else
        warn "Speedtest blocking is not active"
    fi
}


# Main function
main() {
    check_root
    
    case "${1:-}" in
        install)
            install_script
            ;;
        update)
            uninstall_script
            sudo bash -c "$(curl -sL https://raw.githubusercontent.com/erfjab/banner/master/install.sh)" @ install
            ;;
        uninstall)
            uninstall_script
            ;;
        ban)
            install_dependencies
            ban_speedtest
            ;;
        unban)
            unban_speedtest
            ;;
        status)
            check_status
            ;;
        v|version)
            success "$VERSION"
            ;;
        *)
            echo "Usage: $0 {ban|unban|status}"
            exit 1
            ;;
    esac
}

# Execute main function
main "$@"
