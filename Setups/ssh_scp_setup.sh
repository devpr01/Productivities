#!/usr/bin/env bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${YELLOW}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()    { echo -e "${CYAN}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

if [ "$EUID" -ne 0 ]; then
    log_error "Root privileges required. Run with: sudo ./secure_ssh_setup.sh"
fi

ACTUAL_USER="${SUDO_USER:-$USER}"
USER_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
SSH_DIR="$USER_HOME/.ssh"
KEY_PATH="$SSH_DIR/id_ed25519"
CONFIG_PATH="$SSH_DIR/config"

log_info "Initializing secure SSH/SCP setup for user '$ACTUAL_USER'..."

# ==========================================
# PHASE 1: PACKAGE & SERVICE VERIFICATION
# ==========================================
log_info "[Phase 1] Verifying OpenSSH client and server installation..."
if ! command -v sshd >/dev/null 2>&1 || ! command -v ssh-keygen >/dev/null 2>&1; then
    log_info "OpenSSH binaries missing. Installing openssh-client and openssh-server..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq openssh-client openssh-server
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q openssh-clients openssh-server
    else
        log_error "Unsupported package manager. Install OpenSSH manually and re-run."
    fi
    log_success "OpenSSH packages installed."
else
    log_info "OpenSSH client and server are already installed."
fi

log_info "Enabling and starting SSH system service..."
systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || log_error "Failed to start SSH daemon."
log_success "SSH service is active."

# ==========================================
# PHASE 2: INTERACTIVE PARAMETERS
# ==========================================
echo ""
log_info "[Phase 2] Gathering configuration parameters (press Enter for defaults)..."
read -r -p "1. Outbound targets (e.g., target_01@192.168.1.20 github.com) [Default: None]: " input_outbound
read -r -p "2. Inbound allowlist (e.g., target_01@192.168.1.20 admin_user) [Default: None]: " INBOUND_ALLOW_USERS
read -r -p "3. Dedicated SCP/SFTP transfer user [Default: file_agent]: " TRANSFER_USER
TRANSFER_USER=${TRANSFER_USER:-file_agent}
read -r -p "4. Dedicated SCP/SFTP jail path [Default: /var/secure_transfer]: " TRANSFER_DIR
TRANSFER_DIR=${TRANSFER_DIR:-/var/secure_transfer}
read -r -p "5. Disable SSH password authentication (key-only login)? [Y/n]: " DISABLE_PASS_AUTH
DISABLE_PASS_AUTH=${DISABLE_PASS_AUTH:-Y}
read -r -p "6. Auto-configure and enable UFW firewall? [Y/n]: " CONFIG_UFW
CONFIG_UFW=${CONFIG_UFW:-Y}
echo ""

# ==========================================
# PHASE 3: CLIENT HARDENING (OUTBOUND)
# ==========================================
log_info "[Phase 3] Configuring outbound SSH/SCP client in $SSH_DIR..."

log_info "Creating and securing $SSH_DIR (mode 700)..."
sudo -u "$ACTUAL_USER" mkdir -p "$SSH_DIR"
sudo -u "$ACTUAL_USER" chmod 700 "$SSH_DIR"

if [ ! -f "$KEY_PATH" ]; then
    log_info "Generating new Ed25519 key pair at $KEY_PATH..."
    sudo -u "$ACTUAL_USER" ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -q || log_error "Ed25519 key generation failed."
    log_success "Generated Ed25519 key pair."
else
    log_info "Existing Ed25519 key found at $KEY_PATH; preserving existing key."
fi
sudo -u "$ACTUAL_USER" chmod 600 "$KEY_PATH"
sudo -u "$ACTUAL_USER" chmod 644 "${KEY_PATH}.pub"
log_info "Enforced key file permissions (600 private / 644 public)."

if [ -f "$CONFIG_PATH" ]; then
    BACKUP_FILE="${CONFIG_PATH}.backup_$(date +%s)"
    sudo -u "$ACTUAL_USER" cp "$CONFIG_PATH" "$BACKUP_FILE"
    log_info "Backed up existing client config to $BACKUP_FILE."
fi

log_info "Writing hardened global cryptography rules (Ed25519/ECDSA/RSA-SHA2, ChaCha20/AES-GCM, Curve25519) to $CONFIG_PATH..."
sudo -u "$ACTUAL_USER" bash -c "cat << EOF > \"$CONFIG_PATH\"
Host *
    HostKeyAlgorithms ssh-ed25519-cert-v01@openssh.com,ssh-ed25519,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521,rsa-sha2-512,rsa-sha2-256
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

if [ -n "$input_outbound" ]; then
    read -r -a OUTBOUND_ENTRIES <<< "$input_outbound"
    for ENTRY in "${OUTBOUND_ENTRIES[@]}"; do
        if [[ "$ENTRY" == *"@"* ]]; then
            TARGET_USER="${ENTRY%%@*}"
            TARGET_HOST="${ENTRY#*@}"
        else
            TARGET_USER="$ACTUAL_USER"
            TARGET_HOST="$ENTRY"
        fi
        log_info "Adding outbound host profile: Host=$TARGET_HOST, User=$TARGET_USER..."
        sudo -u "$ACTUAL_USER" bash -c "cat << EOF >> \"$CONFIG_PATH\"

Host $TARGET_HOST
    HostName $TARGET_HOST
    User $TARGET_USER
    IdentityFile $KEY_PATH
EOF"
    done
    log_success "Configured ${#OUTBOUND_ENTRIES[@]} outbound target(s)."
else
    log_info "No outbound targets entered; skipping custom Host aliases."
fi

sudo -u "$ACTUAL_USER" chmod 600 "$CONFIG_PATH"
log_info "Validating client SSH configuration syntax (ssh -G)..."
sudo -u "$ACTUAL_USER" ssh -G localhost >/dev/null || log_error "Client SSH config syntax validation failed!"
log_success "Client SSH/SCP configuration validated and secured (mode 600)."

# ==========================================
# PHASE 4: SERVER HARDENING & SFTP JAIL
# ==========================================
log_info "[Phase 4] Configuring SSH daemon hardening, authentication policy, and SCP/SFTP jail..."

mkdir -p /etc/ssh/sshd_config.d
if ! grep -q "^Include /etc/ssh/sshd_config.d/\*.conf" /etc/ssh/sshd_config; then
    sed -i '1s|^|Include /etc/ssh/sshd_config.d/*.conf\n|' /etc/ssh/sshd_config
    log_info "Inserted 'Include /etc/ssh/sshd_config.d/*.conf' into /etc/ssh/sshd_config."
else
    log_info "Verified /etc/ssh/sshd_config already includes drop-in directory."
fi

# Authentication hardening
AUTH_CONF="/etc/ssh/sshd_config.d/97-auth-hardening.conf"
if [[ "$DISABLE_PASS_AUTH" =~ ^[Yy]$ ]]; then
    log_info "Writing key-only authentication policy (disabling password logins and root login)..."
    cat << EOF > "$AUTH_CONF"
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
MaxAuthTries 3
X11Forwarding no
EOF
    log_success "Password-based SSH logins disabled in $AUTH_CONF."
else
    log_info "Writing baseline auth policy while keeping password authentication enabled as fallback..."
    cat << EOF > "$AUTH_CONF"
PubkeyAuthentication yes
PasswordAuthentication yes
PermitRootLogin no
MaxAuthTries 3
X11Forwarding no
EOF
    log_warn "Password-based SSH logins remain enabled. Re-run or set 'PasswordAuthentication no' after key exchange."
fi

# Dedicated transfer user & chroot jail
if ! getent group sftponly >/dev/null; then
    groupadd sftponly
    log_info "Created restricted group 'sftponly'."
fi

if ! id "$TRANSFER_USER" >/dev/null 2>&1; then
    useradd -m -G sftponly -s /bin/false "$TRANSFER_USER"
    log_success "Created shell-less transfer user '$TRANSFER_USER' (/bin/false)."
else
    usermod -aG sftponly -s /bin/false "$TRANSFER_USER"
    log_info "Updated existing user '$TRANSFER_USER' to group 'sftponly' with shell disabled."
fi

TRANSFER_HOME=$(getent passwd "$TRANSFER_USER" | cut -d: -f6)
log_info "Preparing authorized_keys store for '$TRANSFER_USER' at $TRANSFER_HOME/.ssh/authorized_keys..."
mkdir -p "$TRANSFER_HOME/.ssh"
touch "$TRANSFER_HOME/.ssh/authorized_keys"
chown -R "$TRANSFER_USER:sftponly" "$TRANSFER_HOME/.ssh"
chmod 700 "$TRANSFER_HOME/.ssh"
chmod 600 "$TRANSFER_HOME/.ssh/authorized_keys"

log_info "Building chroot jail at $TRANSFER_DIR (root-owned) and upload folder at $TRANSFER_DIR/uploads..."
mkdir -p "$TRANSFER_DIR/uploads"
chown root:root "$TRANSFER_DIR"
chmod 755 "$TRANSFER_DIR"
chown "$TRANSFER_USER:sftponly" "$TRANSFER_DIR/uploads"
chmod 700 "$TRANSFER_DIR/uploads"
log_success "Chroot directory permissions verified."

JAIL_CONF="/etc/ssh/sshd_config.d/98-sftp-jail.conf"
log_info "Writing internal-sftp jail rules to $JAIL_CONF..."
cat << EOF > "$JAIL_CONF"
Match Group sftponly
    ChrootDirectory $TRANSFER_DIR
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
    AllowAgentForwarding no
    PermitTunnel no
EOF

# Inbound user allowlist
ALLOWLIST_CONF="/etc/ssh/sshd_config.d/99-allowlist.conf"
if [ -n "$INBOUND_ALLOW_USERS" ]; then
    echo "AllowUsers $INBOUND_ALLOW_USERS $TRANSFER_USER" > "$ALLOWLIST_CONF"
    log_success "Restricted inbound SSH/SCP access to: $INBOUND_ALLOW_USERS $TRANSFER_USER"
else
    rm -f "$ALLOWLIST_CONF"
    log_info "No inbound allowlist provided; all valid system users permitted."
fi

log_info "Validating SSH daemon configuration syntax (sshd -t)..."
sshd -t || log_error "SSHD syntax validation failed! Inspect /etc/ssh/sshd_config.d/ before reloading."
log_success "SSHD syntax valid."

log_info "Reloading SSH daemon to apply changes..."
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || log_error "Failed to reload SSH daemon."
log_success "SSH daemon reloaded with updated security rules."

# ==========================================
# PHASE 5: UFW FIREWALL CONFIGURATION
# ==========================================
if [[ "$CONFIG_UFW" =~ ^[Yy]$ ]]; then
    log_info "[Phase 5] Configuring Uncomplicated Firewall (UFW)..."
    if ! command -v ufw >/dev/null 2>&1; then
        log_warn "UFW is not installed on this system; skipping firewall setup."
    else
        log_info "Setting UFW defaults: deny incoming, allow outgoing..."
        ufw default deny incoming >/dev/null
        ufw default allow outgoing >/dev/null

        log_info "Applying rate-limiting rule for OpenSSH (port 22)..."
        ufw limit OpenSSH >/dev/null

        for TOKEN in $INBOUND_ALLOW_USERS; do
            if [[ "$TOKEN" == *"@"* ]]; then
                PEER_IP="${TOKEN#*@}"
                if [[ "$PEER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
                    ufw insert 1 allow from "$PEER_IP" to any port 22 proto tcp >/dev/null
                    log_info "Added priority UFW allow rule for peer IP: $PEER_IP on port 22/tcp."
                fi
            fi
        done

        log_info "Enabling UFW firewall..."
        ufw --force enable >/dev/null
        log_success "UFW is active and enforcing SSH rules."
    fi
else
    log_info "[Phase 5] Skipping UFW configuration per user selection."
fi

echo ""
log_success "Unified SSH/SCP security setup completed."
if [[ "$DISABLE_PASS_AUTH" =~ ^[Yy]$ ]]; then
    log_warn "Password authentication is OFF. Copy the public key below to peer machines via VM console or an active session."
fi
echo -e "${YELLOW}Public Key (${KEY_PATH}.pub):${NC}"
cat "${KEY_PATH}.pub"
