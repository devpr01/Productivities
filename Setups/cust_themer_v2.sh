
#!/usr/bin/env bash
# Ubuntu Server 24.04 VM Customizer
# Supports VirtualBox, VMware and KVM guests.

set -Eeuo pipefail
umask 077

readonly APP_NAME="ubuntu-vm-customizer"
readonly CONFIG_DIR="/etc/ubuntu-vm-customizer"
readonly MOTD_SCRIPT="/etc/update-motd.d/99-ubuntu-vm-customizer"
readonly PROFILE_SCRIPT="/etc/profile.d/99-ubuntu-vm-customizer.sh"
readonly COLOR_SERVICE="/etc/systemd/system/ubuntu-vm-console-colors.service"
readonly BACKUP_ROOT="/var/backups/ubuntu-vm-customizer"
readonly LOG_FILE="/var/log/ubuntu-vm-customizer.log"

SYSTEM_PROFILE="minimal"
VISUAL_PROFILE="minimal"
VIRT_TYPE="unknown"
BACKUP_DIR=""
TTY_COLORS_CONFIGURED=false

declare -A BACKED_UP=()

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

backup_file() {
    local file="$1"

    if [[ -e "$file" && -z "${BACKED_UP[$file]+exists}" ]]; then
        mkdir -p "$BACKUP_DIR"
        cp -a --parents "$file" "$BACKUP_DIR/"
        BACKED_UP["$file"]=1
        log "Backup created: $file"
    fi
}

# Writes files atomically and preserves the previous version.
write_file() {
    local file="$1"
    local permissions="$2"
    local tmp

    mkdir -p "$(dirname "$file")"
    backup_file "$file"

    tmp="$(mktemp "$(dirname "$file")/.customizer.XXXXXX")"

    cat > "$tmp"
    chmod "$permissions" "$tmp"
    mv -f "$tmp" "$file"

    log "Configured: $file"
}

set_config_value() {
    local file="$1"
    local key="$2"
    local value="$3"
    local tmp

    mkdir -p "$(dirname "$file")"
    backup_file "$file"

    tmp="$(mktemp "$(dirname "$file")/.customizer.XXXXXX")"

    if [[ -f "$file" ]]; then
        awk -v key="$key" \
            '$0 !~ "^[[:space:]]*" key "[[:space:]]*="' \
            "$file" > "$tmp"
    fi

    printf '%s="%s"\n' "$key" "$value" >> "$tmp"

    chmod 644 "$tmp"
    mv -f "$tmp" "$file"
}

check_environment() {
    [[ "$EUID" -eq 0 ]] || die "Run using sudo."

    [[ -f /etc/os-release ]] || die "OS identification failed."

    source /etc/os-release

    [[ "$ID" == "ubuntu" ]] ||
        die "Only Ubuntu is supported."

    [[ "$VERSION_ID" == "24.04" ]] ||
        die "This script targets Ubuntu 24.04 LTS."

    command -v systemd-detect-virt >/dev/null 2>&1 ||
        die "systemd-detect-virt is required."

    VIRT_TYPE="$(systemd-detect-virt --vm 2>/dev/null || true)"

    [[ -n "$VIRT_TYPE" && "$VIRT_TYPE" != "none" ]] ||
        die "No virtual machine detected."

    command -v apt-get >/dev/null 2>&1 ||
        die "APT package manager is unavailable."

    command -v systemctl >/dev/null 2>&1 ||
        die "systemd is required."

    log "Environment validation successful."
    log "Operating system: $PRETTY_NAME"
    log "Virtualization: $VIRT_TYPE"
}

select_profile() {
    local choice

    echo
    echo "=========================================="
    echo "       UBUNTU VM CUSTOMIZER"
    echo "=========================================="

    echo
    echo "SELECT SYSTEM PROFILE"
    echo "1) Minimal  - Basic login information"
    echo "2) Standard - System information + utilities"
    echo "3) Enhanced - Extended information + utilities"

    read -r -p "System profile [1-3, default 1]: " choice

    case "${choice:-1}" in
        1) SYSTEM_PROFILE="minimal" ;;
        2) SYSTEM_PROFILE="standard" ;;
        3) SYSTEM_PROFILE="enhanced" ;;
        *) die "Invalid system profile." ;;
    esac

    echo
    echo "SELECT VISUAL PROFILE"
    echo "1) Minimal  - Muted dark colors, default-size font"
    echo "2) Standard - Balanced colors, larger font"
    echo "3) Enhanced - High contrast, larger font"

    read -r -p "Visual profile [1-3, default 1]: " choice

    case "${choice:-1}" in
        1) VISUAL_PROFILE="minimal" ;;
        2) VISUAL_PROFILE="standard" ;;
        3) VISUAL_PROFILE="enhanced" ;;
        *) die "Invalid visual profile." ;;
    esac

    log "System profile: $SYSTEM_PROFILE"
    log "Visual profile: $VISUAL_PROFILE"
}

prepare_backup() {
    BACKUP_DIR="${BACKUP_ROOT}/$(date '+%Y%m%d-%H%M%S')"

    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_ROOT" "$BACKUP_DIR"

    log "Backup directory: $BACKUP_DIR"
}

collect_packages() {
    local packages=()

    # Console palette support.
    if ! command -v setvtrgb >/dev/null 2>&1; then
        packages+=(kbd)
    fi

    # Fonts and console configuration for Standard/Enhanced.
    if [[ "$VISUAL_PROFILE" != "minimal" ]]; then
        packages+=(console-setup console-terminus)
    fi

    # Optional monitoring utilities.
    case "$SYSTEM_PROFILE" in
        standard)
            packages+=(htop tmux)
            ;;
        enhanced)
            packages+=(htop tmux ncdu)
            ;;
    esac

    # Remove duplicates.
    PACKAGES=()

    local package
    for package in "${packages[@]}"; do
        if [[ ! " ${PACKAGES[*]} " =~ " ${package} " ]]; then
            PACKAGES+=("$package")
        fi
    done
}

install_packages() {
    collect_packages

    if [[ ${#PACKAGES[@]} -eq 0 ]]; then
        log "No additional packages required."
        return
    fi

    echo
    echo "Packages required for selected profiles:"
    printf '  - %s\n' "${PACKAGES[@]}"
    echo

    read -r -p "Install these packages? [y/N]: " answer

    case "$answer" in
        y|Y|yes|YES)
            apt-get update

            DEBIAN_FRONTEND=noninteractive \
                apt-get install -y --no-install-recommends "${PACKAGES[@]}"

            log "Package installation completed."
            ;;
        *)
            log "Package installation skipped. Unsupported features will be skipped."
            ;;
    esac
}

configure_profile() {
    write_file "$CONFIG_DIR/system-profile" 644 <<EOF
$SYSTEM_PROFILE
EOF

    write_file "$CONFIG_DIR/visual-profile" 644 <<EOF
$VISUAL_PROFILE
EOF
}

configure_motd() {
    write_file "$MOTD_SCRIPT" 755 <<'MOTD'
#!/usr/bin/env bash

[[ -r /etc/os-release ]] && source /etc/os-release

CONFIG_DIR="/etc/ubuntu-vm-customizer"
SYSTEM_PROFILE="minimal"

[[ -r "$CONFIG_DIR/system-profile" ]] &&
    SYSTEM_PROFILE="$(cat "$CONFIG_DIR/system-profile")"

echo
echo "================================================"
echo "             UBUNTU SERVER"
echo "================================================"

printf " Hostname : %s\n" "$(hostname)"
printf " OS       : %s\n" "${PRETTY_NAME:-Ubuntu}"
printf " Kernel   : %s\n" "$(uname -r)"
printf " Uptime   : %s\n" "$(uptime -p 2>/dev/null || echo unavailable)"
printf " Disk     : %s used\n" \
    "$(df -hP / | awk 'NR==2 {print $5}')"

if [[ "$SYSTEM_PROFILE" != "minimal" ]]; then
    printf " Memory   : %s\n" \
        "$(free -h | awk '/^Mem:/ {print $3 " / " $2}')"

    printf " Load     : %s\n" "$(cut -d' ' -f1-3 /proc/loadavg)"
fi

if [[ "$SYSTEM_PROFILE" == "enhanced" ]]; then
    printf " Virtual  : %s\n" \
        "$(systemd-detect-virt --vm 2>/dev/null || echo unknown)"

    printf " Processes: %s\n" "$(ps -e --no-headers | wc -l)"
fi

echo "================================================"
echo
MOTD

    log "MOTD configured."
}

configure_prompt() {
    case "$VISUAL_PROFILE" in

        minimal)
            write_file "$PROFILE_SCRIPT" 644 <<'PROMPT'
# Minimal interactive Bash prompt.
case "$-" in
    *i*) ;;
    *) return ;;
esac

PS1='\[\033[0;32m\]\u@\h\[\033[0m\] \[\033[0;34m\]\w\[\033[0m\] \$ '
PROMPT
            ;;

        standard)
            write_file "$PROFILE_SCRIPT" 644 <<'PROMPT'
# Standard two-line Bash prompt.
case "$-" in
    *i*) ;;
    *) return ;;
esac

PS1='\[\033[0;32m\]\u@\h\[\033[0m\]:\[\033[0;36m\]\w\[\033[0m\]\n\$ '
PROMPT
            ;;

        enhanced)
            write_file "$PROFILE_SCRIPT" 644 <<'PROMPT'
# Enhanced Bash prompt with time.
case "$-" in
    *i*) ;;
    *) return ;;
esac

PS1='\[\033[0;90m\]\A \[\033[0;32m\]\u@\h\[\033[0m\]\n\[\033[0;34m\]\w\[\033[0m\] \$ '
PROMPT
            ;;
    esac

    log "Bash prompt configured."
}

configure_color_palette() {
    local setvtrgb_bin

    setvtrgb_bin="$(command -v setvtrgb || true)"

    if [[ -z "$setvtrgb_bin" ]]; then
        log "TTY colors skipped: setvtrgb is unavailable."
        return
    fi

    case "$VISUAL_PROFILE" in

        minimal)
            write_file "$CONFIG_DIR/vtrgb" 644 <<'COLORS'
11 224 152 229 97 198 86 216 92 255 169 240 121 215 112 255
15 108 195 192 175 120 182 222 99 122 220 198 184 165 214 255
20 117 121 123 239 221 194 233 112 133 118 116 255 255 223 255
COLORS
            ;;

        standard)
            write_file "$CONFIG_DIR/vtrgb" 644 <<'COLORS'
15 255 80 255 80 190 40 220 100 255 120 255 120 220 100 255
20 95 200 190 150 100 190 220 110 140 255 220 200 180 230 255
30 86 120 50 255 230 220 235 130 130 150 90 255 255 240 255
COLORS
            ;;

        enhanced)
            write_file "$CONFIG_DIR/vtrgb" 644 <<'COLORS'
8 255 70 255 60 220 0 240 90 255 100 255 100 255 80 255
12 70 230 210 180 80 210 240 100 120 255 230 220 160 245 255
24 90 100 40 255 255 240 255 120 140 130 80 255 255 255 255
COLORS
            ;;
    esac

    write_file "$COLOR_SERVICE" 644 <<EOF
[Unit]
Description=Ubuntu VM Custom Console Colors
After=systemd-vconsole-setup.service

[Service]
Type=oneshot
ExecStart=$setvtrgb_bin $CONFIG_DIR/vtrgb
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ubuntu-vm-console-colors.service

    TTY_COLORS_CONFIGURED=true

    # Apply immediately, including when invoked over SSH.
    "$setvtrgb_bin" "$CONFIG_DIR/vtrgb"

    log "TTY color palette configured."
}

configure_console_font() {
    local fontface
    local fontsize

    if ! command -v setupcon >/dev/null 2>&1; then
        log "Console font skipped: setupcon is unavailable."
        return
    fi

    case "$VISUAL_PROFILE" in
        minimal)
            fontface="Fixed"
            fontsize="8x16"
            ;;
        standard)
            fontface="Terminus"
            fontsize="10x20"
            ;;
        enhanced)
            fontface="Terminus"
            fontsize="12x24"
            ;;
    esac

    if [[ "$VISUAL_PROFILE" != "minimal" ]] &&
       ! compgen -G "/usr/share/consolefonts/*Terminus*${fontsize}*" >/dev/null &&
       ! compgen -G "/usr/share/consolefonts/*${fontsize}*" >/dev/null; then
        log "Requested Terminus font not found. Font configuration skipped."
        return
    fi

    if [[ "$VISUAL_PROFILE" == "minimal" ]] &&
       [[ ! -d /usr/share/consolefonts ]]; then
        log "Default console font retained."
        return
    fi

    set_config_value /etc/default/console-setup FONTFACE "$fontface"
    set_config_value /etc/default/console-setup FONTSIZE "$fontsize"

    # Apply immediately only on a local Linux virtual console.
    if [[ -t 0 ]] && [[ "$(tty)" =~ ^/dev/tty[0-9]+$ ]]; then
        setupcon
        log "Console font applied."
    else
        log "Console font configured for the next console initialization."
    fi
}

validate_configuration() {
    [[ -x "$MOTD_SCRIPT" ]] ||
        die "MOTD validation failed."

    [[ -r "$PROFILE_SCRIPT" ]] ||
        die "Prompt validation failed."

    [[ -r "$CONFIG_DIR/system-profile" ]] ||
        die "System profile missing."

    [[ -r "$CONFIG_DIR/visual-profile" ]] ||
        die "Visual profile missing."

    bash -n "$MOTD_SCRIPT" ||
        die "MOTD syntax error."

    bash -n "$PROFILE_SCRIPT" ||
        die "Prompt syntax error."

    if [[ "$TTY_COLORS_CONFIGURED" == true ]]; then
        systemctl is-enabled --quiet ubuntu-vm-console-colors.service ||
            die "TTY color service is not enabled."
    fi

    log "Configuration validation successful."
}

show_summary() {
    echo
    echo "=========================================="
    echo "       CUSTOMIZATION COMPLETED"
    echo "=========================================="

    echo
    echo "Virtualization : $VIRT_TYPE"
    echo "System profile : $SYSTEM_PROFILE"
    echo "Visual profile : $VISUAL_PROFILE"
    echo
    echo "Configuration:"
    echo "  $CONFIG_DIR"
    echo
    echo "MOTD:"
    echo "  $MOTD_SCRIPT"
    echo
    echo "Bash prompt:"
    echo "  $PROFILE_SCRIPT"
    echo
    echo "TTY colors:"
    if [[ "$TTY_COLORS_CONFIGURED" == true ]]; then
        echo "  Configured and enabled"
    else
        echo "  Skipped (utility unavailable)"
    fi
    echo
    echo "Backups:"
    echo "  $BACKUP_DIR"
    echo
    echo "Log:"
    echo "  $LOG_FILE"
    echo
    echo "To preview MOTD:"
    echo "  $MOTD_SCRIPT"
    echo
    echo "To reload Bash prompt:"
    echo "  source $PROFILE_SCRIPT"
    echo
    echo "Reboot or log out and reconnect to see all changes."
    echo
}

main() {
    check_environment

    mkdir -p /var/log
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"

    exec > >(tee -a "$LOG_FILE") 2>&1

    select_profile
    prepare_backup

    install_packages

    mkdir -p "$CONFIG_DIR"
    chmod 755 "$CONFIG_DIR"

    configure_profile
    configure_motd
    configure_prompt
    configure_color_palette
    configure_console_font

    validate_configuration
    show_summary
}

main "$@"
