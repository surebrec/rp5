#!/usr/bin/env bash
#
# install-rp5-wifi.sh
#
# Raspberry Pi 5 / Ubuntu Server 24.04+
# Configures:
#   - NetworkManager as the network manager
#   - Home Wi-Fi client connection on wlan0 (STA)
#   - RP5-Setup access point on virtual interface ap0 (AP)
#   - Shared IPv4 internet access, DHCP and DNS via NetworkManager
#   - AP address 192.168.77.1/24
#   - systemd service that creates ap0 and starts the AP on every boot
#
# Run:
#   sudo bash install-rp5-wifi.sh
#
# The script asks for Wi-Fi credentials interactively.
# It does not store credentials in this script.

set -Eeuo pipefail
umask 077

readonly AP_PROFILE="RP5-Setup"
readonly HOME_PROFILE="rp5-home-wifi"
readonly AP_SSID="RP5-Setup"
readonly AP_ADDRESS="192.168.77.1/24"
readonly AP_INTERFACE="ap0"
readonly STA_INTERFACE="wlan0"
readonly SERVICE_NAME="rp5-ap.service"
readonly START_SCRIPT="/usr/local/sbin/start-rp5-ap.sh"
readonly NETPLAN_FILE="/etc/netplan/90-rp5-networkmanager.yaml"
readonly NM_DROPIN="/etc/NetworkManager/conf.d/10-rp5-wifi.conf"

BACKUP_DIR="/root/rp5-wifi-backup-$(date +%Y%m%d-%H%M%S)"
LOG_FILE="/var/log/install-rp5-wifi.log"

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

on_error() {
    local line="$1"
    log "ERROR: installer stopped at line ${line}. See ${LOG_FILE}"
}
trap 'on_error "$LINENO"' ERR

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root: sudo bash $0" >&2
    exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log "Starting Raspberry Pi Wi-Fi setup."
log "Backup directory: ${BACKUP_DIR}"

if [[ ! -r /etc/os-release ]]; then
    die "Cannot identify operating system."
fi
# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
    die "This installer is intended for Ubuntu Server. Detected: ${PRETTY_NAME:-unknown}"
fi

if [[ ! -d /sys/class/net ]]; then
    die "Network interfaces are not available."
fi

mkdir -p "$BACKUP_DIR"
mkdir -p "$BACKUP_DIR/netplan" "$BACKUP_DIR/NetworkManager-conf.d" "$BACKUP_DIR/cloud"

# Save existing configuration before changing it.
if [[ -d /etc/netplan ]]; then
    cp -a /etc/netplan/. "$BACKUP_DIR/netplan/" 2>/dev/null || true
fi
if [[ -d /etc/NetworkManager/conf.d ]]; then
    cp -a /etc/NetworkManager/conf.d/. "$BACKUP_DIR/NetworkManager-conf.d/" 2>/dev/null || true
fi
if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    cp -a /etc/cloud/cloud.cfg.d/. "$BACKUP_DIR/cloud/" 2>/dev/null || true
fi

echo
echo "This installer will configure NetworkManager and replace active Netplan YAML"
echo "configuration with a NetworkManager renderer configuration."
echo "Existing files are backed up to:"
echo "  ${BACKUP_DIR}"
echo
echo "The network may briefly disconnect while the configuration is applied."
