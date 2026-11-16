#!/usr/bin/env bash

set -e

# Logging colors and helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# Enforce root privileges for system-level sshd changes
if [ "$EUID" -ne 0 ]; then
    log_error "Run this script with sudo: sudo ./secure_ssh_setup.sh"
fi

# Resolve the non-root user invoking sudo
ACTUAL_USER="${SUDO_USER:-$USER}"
USER_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
SSH_DIR="$USER_HOME/.ssh"
KEY_PATH="$SSH_DIR/id_ed25519"
CONFIG_PATH="$SSH_DIR/config"

# ==========================================
# INTERACTIVE CONFIGURATION
# ==========================================
log_info "Starting Interactive Configuration (Press Enter for defaults)..."

read -r -p "1. Allowed outbound hosts (space-separated) [Default: github.com]: " input_outbound
if [ -z "$input_outbound" ]; then
    OUTBOUND_HOSTS=("github.com")
else
    read -r -a OUTBOUND_HOSTS <<< "$input_outbound"
fi

read -r -p "2. Allowed inbound users/IPs (e.g., admin@192.168.1.50) [Default: Skip restriction]: " INBOUND_ALLOW_USERS

read -r -p "3. Dedicated SCP/SFTP username [Default: file_agent]: " TRANSFER_USER
TRANSFER_USER=${TRANSFER_USER:-file_agent}

read -r -p "4. Dedicated SCP/SFTP chroot path [Default: /var/secure_transfer]: " TRANSFER_DIR
TRANSFER_DIR=${TRANSFER_DIR:-/var/secure_transfer}
echo ""

# ==========================================
# PHASE 1: CLIENT SETUP (OUTBOUND)
# ==========================================
log_info "[Phase 1] Configuring outbound SSH/SCP client for $ACTUAL_USER..."

# Secure .ssh directory
sudo -u "$ACTUAL_USER" mkdir -p "$SSH_DIR" || log_error "Failed to create $SSH_DIR"
sudo -u "$ACTUAL_USER" chmod 700 "$SSH_DIR"

# Generate Ed25519 key if missing
if [ ! -f "$KEY_PATH" ]; then
    sudo -u "$ACTUAL_USER" ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -q || log_error "Key generation failed."
    log_success "Ed25519 key generated at $KEY_PATH"
else
    log_info "Existing key found at $KEY_PATH. Skipping generation."
fi
sudo -u "$ACTUAL_USER" chmod 600 "$KEY_PATH"
sudo -u "$ACTUAL_USER" chmod 644 "${KEY_PATH}.pub"

# Backup existing client config
if [ -f "$CONFIG_PATH" ]; then
    sudo -u "$ACTUAL_USER" cp "$CONFIG_PATH" "${CONFIG_PATH}.backup_$(date +%s)"
    log_info "Backed up existing client config."
fi

# Write hardened global defaults
sudo -u "$ACTUAL_USER" bash -c "cat << EOF > \"$CONFIG_PATH\"
Host *
    HostKeyAlgorithms ssh-ed25519,cert-authority@openssh.com
    Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
    KexAlgorithms curve25519-sha256@libssh.org,curve25519-sha256
    MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
    HashKnownHosts yes
    StrictHostKeyChecking ask
    VerifyHostKeyDNS yes
    ServerAliveInterval 300
    ServerAliveCountMax 2
    IdentityFile $KEY_PATH
EOF"

# Append allowed outbound hosts
for HOST in "${OUTBOUND_HOSTS[@]}"; do
sudo -u "$ACTUAL_USER" bash -c "cat << EOF >> \"$CONFIG_PATH\"

Host $HOST
    HostName $HOST
    User $ACTUAL_USER
    IdentityFile $KEY_PATH
EOF"
done

sudo -u "$ACTUAL_USER" chmod 600 "$CONFIG_PATH"
log_success "Outbound SSH/SCP client configuration complete."

# ==========================================
# PHASE 2: SERVER SETUP (INBOUND & JAIL)
# ==========================================
log_info "[Phase 2] Configuring inbound SSHD restrictions and SCP/SFTP jail..."

# Ensure sshd_config includes drop-in directory
mkdir -p /etc/ssh/sshd_config.d
if ! grep -q "^Include /etc/ssh/sshd_config.d/\*.conf" /etc/ssh/sshd_config; then
    sed -i '1s|^|Include /etc/ssh/sshd_config.d/*.conf\n|' /etc/ssh/sshd_config
    log_info "Added Include directive to /etc/ssh/sshd_config"
fi

# Create restricted transfer group and user (no shell)
if ! getent group sftponly >/dev/null; then
    groupadd sftponly
fi

if ! id "$TRANSFER_USER" >/dev/null 2>&1; then
    useradd -m -G sftponly -s /bin/false "$TRANSFER_USER"
    log_success "Created transfer user: $TRANSFER_USER"
else
    usermod -aG sftponly -s /bin/false "$TRANSFER_USER"
fi

# Prepare authorized_keys file for the transfer user
TRANSFER_HOME=$(getent passwd "$TRANSFER_USER" | cut -d: -f6)
mkdir -p "$TRANSFER_HOME/.ssh"
touch "$TRANSFER_HOME/.ssh/authorized_keys"
chown -R "$TRANSFER_USER:sftponly" "$TRANSFER_HOME/.ssh"
chmod 700 "$TRANSFER_HOME/.ssh"
chmod 600 "$TRANSFER_HOME/.ssh/authorized_keys"

# Build Chroot directory structure (root-owned parent, user-owned upload child)
mkdir -p "$TRANSFER_DIR/uploads"
chown root:root "$TRANSFER_DIR"
chmod 755 "$TRANSFER_DIR"
chown "$TRANSFER_USER:sftponly" "$TRANSFER_DIR/uploads"
chmod 700 "$TRANSFER_DIR/uploads"

# Apply Inbound AllowUsers (auto-append TRANSFER_USER so SCP isn't blocked)
if [ -n "$INBOUND_ALLOW_USERS" ]; then
    echo "AllowUsers $INBOUND_ALLOW_USERS $TRANSFER_USER" > /etc/ssh/sshd_config.d/99-allowlist.conf
    log_success "Inbound access restricted to: $INBOUND_ALLOW_USERS $TRANSFER_USER"
fi

# Write SFTP/SCP Chroot Jail rules
cat << EOF > /etc/ssh/sshd_config.d/98-sftp-jail.conf
Match Group sftponly
    ChrootDirectory $TRANSFER_DIR
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
    AllowAgentForwarding no
    PermitTunnel no
EOF

# Validate SSHD syntax before reloading to prevent lockouts
sshd -t || log_error "SSHD configuration syntax test failed! Check /etc/ssh/sshd_config.d/ files."

if systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null; then
    log_success "SSH daemon validated and reloaded."
else
    log_error "Failed to reload SSH daemon."
fi

log_success "Setup finished."
log_info "Client Public Key: ${KEY_PATH}.pub"
log_info "Transfer User Authorized Keys: $TRANSFER_HOME/.ssh/authorized_keys"
