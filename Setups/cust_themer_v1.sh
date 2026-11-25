#!/usr/bin/env bash

# Service Name: vm-ubuntu-customizer

set -Eeuo pipefail
umask 077

readonly APP_NAME="ubuntu-vm-customizer"
readonly CONFIG_DIR="/etc/ubuntu-vm-customizer"
readonly MOTD_SCRIPT="/etc/update-motd.d/99-ubuntu-vm-customizer"
readonly PROFILE_SCRIPT="/etc/profile.d/99-ubuntu-vm-customizer.sh"
readonly BACKUP_ROOT="/var/backups/ubuntu-vm-customizer"
readonly LOG_FILE="/var/log/ubuntu-vm-customizer.log"

PROFILE="minimal"
VIRT_TYPE="unknown"
BACKUP_DIR=""

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

backup_file() {
    local file="$1"

    if [[ -e "$file" ]]; then
        mkdir -p "$BACKUP_DIR"
        cp -a --parents "$file" "$BACKUP_DIR/"
        log "Backed up: $file"
    fi
}

write_file() {
    local file="$1"
    local permissions="$2"

    backup_file "$file"
    mkdir -p "$(dirname "$file")"

    # Read the file content from standard input.
    cat > "$file"
    chmod "$permissions" "$file"

    log "Configured: $file"
}

check_environment() {
    [[ "$EUID" -eq 0 ]] || die "Run with sudo: sudo bash $0"

    [[ -f /etc/os-release ]] || die "Cannot identify operating system."

    source /etc/os-release

    [[ "$ID" == "ubuntu" ]] || die "This script supports Ubuntu only."
    [[ "$VERSION_ID" == "24.04" ]] || die "This version targets Ubuntu 24.04 LTS."

    command -v systemd-detect-virt >/dev/null 2>&1 ||
        die "systemd-detect-virt is required."

    VIRT_TYPE="$(systemd-detect-virt --vm 2>/dev/null || true)"

    [[ -n "$VIRT_TYPE" && "$VIRT_TYPE" != "none" ]] ||
        die "No virtual machine detected. Physical machines are not supported by this script."

    command -v apt-get >/dev/null 2>&1 || die "apt-get is unavailable."

    log "Environment validated."
    log "Virtualization: $VIRT_TYPE"
    log "OS: $PRETTY_NAME"
}

show_menu() {
    echo
    echo "=========================================="
    echo "       UBUNTU VM CUSTOMIZER"
    echo "=========================================="
    echo
    echo "Choose your customization level:"
    echo
    echo "  1) Minimal   [DEFAULT]"
    echo "     Clean MOTD, colored prompt, basic info."
    echo "     No additional packages."
    echo
    echo "  2) Standard"
    echo "     Minimal + htop + tmux."
    echo
    echo "  3) Enhanced"
    echo "     Standard + ncdu + extended system info."
    echo
    read -r -p "Select [1-3, default 1]: " choice

    case "${choice:-1}" in
        1) PROFILE="minimal" ;;
        2) PROFILE="standard" ;;
        3) PROFILE="enhanced" ;;
        *) die "Invalid selection." ;;
    esac

    echo
    log "Selected profile: $PROFILE"
}

prepare_backup() {
    BACKUP_DIR="${BACKUP_ROOT}/$(date '+%Y%m%d-%H%M%S')"

    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_ROOT" "$BACKUP_DIR"

    log "Backup location: $BACKUP_DIR"
}

configure_motd() {
    write_file "$MOTD_SCRIPT" 755 <<'MOTD'
#!/usr/bin/env bash

[[ -r /etc/os-release ]] && source /etc/os-release

PROFILE_FILE="/etc/ubuntu-vm-customizer/profile"
PROFILE="minimal"

[[ -r "$PROFILE_FILE" ]] && PROFILE="$(cat "$PROFILE_FILE")"

echo
echo "================================================"
echo "             UBUNTU SERVER"
echo "================================================"
printf " Hostname : %s\n" "$(hostname)"
printf " OS       : %s\n" "${PRETTY_NAME:-Ubuntu}"
printf " Kernel   : %s\n" "$(uname -r)"
printf " Uptime   : %s\n" "$(uptime -p 2>/dev/null || echo unavailable)"
printf " Disk     : %s used on /\n" 
    "$(df -hP / | awk 'NR==2 {print $5}')"
printf " Profile  : %s\n" "$PROFILE"

if [[ "$PROFILE" == "standard" || "$PROFILE" == "enhanced" ]]; then
    if command -v free >/dev/null 2>&1; then
        printf " Memory   : %s\n" 
            "$(free -h | awk '/^Mem:/ {print $3 " / " $2}')"
    fi
fi

if [[ "$PROFILE" == "enhanced" ]]; then
    printf " VM       : %s\n" 
        "$(systemd-detect-virt --vm 2>/dev/null || echo unknown)"
fi

echo "================================================"
echo
MOTD

    log "MOTD customization applied."
}

configure_prompt() {
    write_file "$PROFILE_SCRIPT" 644 <<'PROMPT'
# Ubuntu VM Customizer: interactive Bash prompt

# Do not affect non-interactive shells.
case "$-" in
    *i*) ;;
    *) return ;;
esac

# Green username/hostname, blue working directory.
if [[ "$EUID" -eq 0 ]]; then
    PS1='\[\033[0;33m\]\u@\h\[\033[0m\] \[\033[0;34m\]\w\[\033[0m\] # '
else
    PS1='\[\033[0;32m\]\u@\h\[\033[0m\] \[\033[0;34m\]\w\[\033[0m\] \$ '
fi
PROMPT

    log "Bash prompt customization applied."
}

configure_profile() {
    write_file "$CONFIG_DIR/profile" 644 <<EOF
$PROFILE
EOF

    log "Profile configuration saved."
}

install_optional_packages() {
    local packages=()

    case "$PROFILE" in
        minimal)
            log "Minimal profile: no additional packages."
            return
            ;;
        standard)
            packages=(htop tmux)
            ;;
        enhanced)
            packages=(htop tmux ncdu)
            ;;
    esac

    echo
    echo "The following packages will be installed:"
    printf '  - %s\n' "${packages[@]}"
    echo

    read -r -p "Continue with package installation? [y/N]: " answer

    case "$answer" in
        y|Y|yes|YES)
            log "Updating APT package indexes."
            apt-get update

            log "Installing selected packages."
            DEBIAN_FRONTEND=noninteractive \
                apt-get install -y --no-install-recommends "${packages[@]}"
            ;;
        *)
            log "Package installation skipped."
            ;;
    esac
}

validate_configuration() {
    [[ -x "$MOTD_SCRIPT" ]] || die "MOTD script validation failed."
    [[ -r "$PROFILE_SCRIPT" ]] || die "Prompt configuration validation failed."
    [[ -r "$CONFIG_DIR/profile" ]] || die "Profile configuration missing."

    bash -n "$MOTD_SCRIPT" || die "MOTD syntax validation failed."
    bash -n "$PROFILE_SCRIPT" || die "Prompt syntax validation failed."

    log "Configuration validation successful."
}

show_summary() {
    echo
    echo "=========================================="
    echo "       CUSTOMIZATION COMPLETED"
    echo "=========================================="
    echo
    echo " Profile       : $PROFILE"
    echo " VM Type       : $VIRT_TYPE"
    echo " MOTD          : $MOTD_SCRIPT"
    echo " Bash Prompt   : $PROFILE_SCRIPT"
    echo " Configuration : $CONFIG_DIR"
    echo " Backups       : $BACKUP_DIR"
    echo " Log           : $LOG_FILE"
    echo
    echo "To preview the welcome screen:"
    echo "  $MOTD_SCRIPT"
    echo
    echo "To apply the prompt in the current shell:"
    echo "  source $PROFILE_SCRIPT"
    echo
    echo "Log out and reconnect to see the complete login experience."
    echo
}

main() {
    check_environment

    # Protect the execution log from other local users.
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1

    show_menu
    prepare_backup

    configure_profile
    configure_motd
    configure_prompt

    install_optional_packages

    validate_configuration
    show_summary
}

main "$@"
