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

install_packages() {

    for package in "$@"
    do

    # check if package is not installed
    #    if ! (dpkg -s $package >/dev/null 2>&1); then
    if ! dpkg -l | grep -wq "^ii\s*$package\s"; then
        print "[blue]Installing $package..."


        # install package
        if ! apt install $package -y &> /dev/null; then
        apt --fix-broken install -y &> /dev/null
        apt install $package -y &> /dev/null
        fi

        sleep 0.5
        clear_logs 1
    fi

    done
}


ban_speedtest() {
    log "Starting speedtest blocking procedure..."

    domains=(
        speedtest.net
        www.speedtest.net
        c.speedtest.net
        speedcheck.org
        www.speedcheck.org
        a1.etrality.com
        net.etrality.com
        api.speedspot.org
        fast.com
        www.fast.com
    )

    speedtest_ips=()

    install_packages iptables ipset dnsutils

    if ! ipset list wepn_speedtest_set &> /dev/null; then

        for domain in "${domains[@]}"; do
            _speedtest_ips=($(host "$domain" | awk '/has address/ {print $NF}'))
            speedtest_ips+=("${_speedtest_ips[@]}")
        done

        create_or_add_to_table wepn_speedtest BLOCK_WEBSITE "${speedtest_ips[@]}"
        success "Speedtest blocking has been successfully configured!"
    fi
}


create_or_add_to_table(){
    local set="$1_set"
    local chain="$1_chain"
    local rule="$2"
    shift 2
    local ips=("$@")

    if [ "$rule" != "BLOCK_IPSCAN" ] && [ "$rule" != "BLOCK_BITTORRENT" ]; then
        # Create set if it does not exist
        if ! ipset list "$set" &>/dev/null; then
            ipset create "$set" hash:net comment maxelem 20000
        fi

        # Add all IPs to the set
        for ip_data in "${ips[@]}"; do
            # Parse IP and comment (if any)
            if [[ "$ip_data" =~ ">" ]]; then
                ip=$(echo "$ip_data" | cut -d '>' -f 1)
                comment=$(echo "$ip_data" | cut -d '>' -f 2)
            else
                ip="$ip_data"
                comment=""
            fi

            # Add IP to the set
            if ! ipset test "$set" "$ip" &>/dev/null; then
                if [[ -z "$comment" ]]; then
                    ipset add "$set" "$ip"
                else
                    ipset add "$set" "$ip" comment "$comment"
                fi
            fi
        done
    fi

    # Create chain
    if ! iptables -nL "$chain" >/dev/null 2>&1; then
        iptables -N "$chain"

        if [ "$rule" == "BLOCK_WEBSITE" ]; then
            iptables -I "$chain" -p tcp --dport 80 -m set --match-set "$set" dst -j REJECT
            iptables -I "$chain" -p tcp --dport 443 -m set --match-set "$set" dst -j REJECT
            iptables -I OUTPUT 1 -j "$chain"
            iptables -I FORWARD 1 -j "$chain"
        elif [ "$rule" == "ALLOW_WEBSITE" ]; then
            iptables -I "$chain" -p tcp --dport 80 -m set --match-set "$set" dst -j ACCEPT
            iptables -I "$chain" -p tcp --dport 443 -m set --match-set "$set" dst -j ACCEPT
            iptables -I OUTPUT 1 -j "$chain"
            iptables -I FORWARD 1 -j "$chain"
        fi

        # Save rules
        iptables-save > /root/.wepn/iptables-rules
        ipset save > /root/.wepn/ipset-rules
    fi
}


unban_speedtest() {
    log "Removing speedtest blocks..."
    domains=(
    speedtest.net
    www.speedtest.net
    c.speedtest.net
    speedcheck.org
    www.speedcheck.org
    a1.etrality.com
    net.etrality.com
    api.speedspot.org
    fast.com
    www.fast.com
    )

    speedtest_ips=()


    install_packages iptables ipset dnsutils

    if ! ipset list wepn_speedtest_set &> /dev/null; then


    for domain in "${domains[@]}"; do
    _speedtest_ips=($(host "$domain" | awk '/has address/ {print $NF}'))
    speedtest_ips+=("${_speedtest_ips[@]}")
    done

    create_or_add_to_table wepn_speedtest ALLOW_WEBSITE "${speedtest_ips[@]}"
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
