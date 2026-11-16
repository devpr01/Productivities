# Secure SSH & SCP/SFTP Configuration Guide

This script automates the setup of a highly secure SSH environment. It handles both outbound connections (acting as a client) and inbound connections (acting as a server). The script is interactive and will prompt you for necessary allowed IPs and usernames during execution.

## 🛠️ Command Breakdown (What the script does)

*   **`ssh-keygen -t ed25519`**: Generates a modern, highly secure cryptographic key pair. It avoids older algorithms like RSA, matching industry best practices.
*   **`sudo -u $ACTUAL_USER`**: Ensures that client-side files (`~/.ssh/config`, private keys) are owned by the developer running the script, not the `root` user, even though the script is executed with `sudo`.
*   **`cat << EOF > file`**: A "heredoc" operation. It writes multiple lines of configuration directly into SSH configuration files without requiring a text editor.
*   **`useradd -s /bin/false`**: Creates a user but denies them terminal/shell access. They cannot run bash scripts or commands, closing a major security vulnerability for file-transfer accounts.
*   **`ChrootDirectory`**: A subsystem rule in SSH that "jails" the user. When they log in via SCP/SFTP, they treat `/var/secure_transfer` as the root of the server (`/`). They physically cannot navigate to `/etc` or `/home`.

## ⚠️ Security & Risk Considerations

While this script implements aggressive hardening, you should be aware of the operational risks this architecture introduces:

| Vulnerability / Risk | Description | Mitigation |
| :--- | :--- | :--- |
| **Data-at-Rest Vulnerability** | The script generates the Ed25519 key without a passphrase for automated execution. If the local machine is compromised, the key can be used immediately. | Rely on Full Disk Encryption (e.g., LUKS) on the host machine. For maximum security, modify the script to remove `-N ""` from the `ssh-keygen` command to force a passphrase prompt. |
| **"Self-Lockout" Denial of Service** | The `AllowUsers` directive acts as a strict default-deny firewall. If you run this remotely and fail to input your own IP/username, you will be locked out upon daemon reload. | Keep your current SSH session open in one terminal while running the script in another. Verify login in a new window before closing the active session. |
| **Silent Jail Evasion** | Some Linux distributions do not process `.d` drop-in directories by default. If ignored, the `file_agent` won't be jailed and could tunnel into the internal network. | Verify configuration by running `sudo sshd -T -C user=file_agent`. Ensure the output includes `forcecommand internal-sftp` and `allowtcpforwarding no`. |
| **Human-in-the-Loop MITM** | The script uses `StrictHostKeyChecking ask`. If a network is under a Man-in-the-Middle attack and a developer blindly types "yes" to accept a new fingerprint, the tunnel is compromised. | For absolute zero-trust, change this to `yes` in the script and pre-provision remote host keys into `~/.ssh/known_hosts` using `ssh-keyscan`. |

**Post-Setup Security Audit:**
Run this command to print exactly what cryptography and allowlists the server is actually enforcing in memory:
\`\`\`bash
sudo sshd -T | grep -E '^(allowusers|ciphers|kexalgorithms|macs)'
\`\`\`

## 🚧 Common Errors & Troubleshooting

### 1. Error: "fatal: bad ownership or modes for chroot directory"
**Why it happens:** OpenSSH enforces strict security on `ChrootDirectory`. If the folder (`/var/secure_transfer`) is owned by anyone other than `root`, or if other users have write access to it, OpenSSH will abort the connection to prevent breakout attacks.
**Troubleshooting Procedure:**
1. Run: `sudo chown root:root /var/secure_transfer`
2. Run: `sudo chmod 755 /var/secure_transfer`
3. Ensure the inner folder is writable by the user: `sudo chown file_agent:sftponly /var/secure_transfer/uploads`

### 2. Error: "Permission denied (publickey)" during SCP/SSH
**Why it happens:** The server rejected the connection. This usually means the public key is missing from the server's `authorized_keys` file, or the user/IP is blocked by the allowlist.
**Troubleshooting Procedure:**
1. Check if your user and IP were successfully added to `/etc/ssh/sshd_config.d/99-allowlist.conf`.
2. Ensure you appended the client's `.pub` file into the target user's `~/.ssh/authorized_keys`.
3. Check key permissions on the server:
   * `chmod 700 ~/.ssh`
   * `chmod 600 ~/.ssh/authorized_keys`

### 3. Error: "Bad owner or permissions on /home/user/.ssh/config"
**Why it happens:** SSH will refuse to use configuration files or private keys if they are readable by other users on the system (a critical security risk).
**Troubleshooting Procedure:**
1. Run: `chmod 600 ~/.ssh/config`
2. Run: `chmod 600 ~/.ssh/id_ed25519`

### 4. Error: Connections are completely ignoring the AllowUsers or SFTP jail rules
**Why it happens:** Some Linux distributions do not include the `.d/` drop-in directories by default in their main SSH configuration.
**Troubleshooting Procedure:**
1. Open `/etc/ssh/sshd_config`.
2. Ensure this line exists at the very top of the file: `Include /etc/ssh/sshd_config.d/*.conf`
3. Reload the daemon: `sudo systemctl reload sshd`
