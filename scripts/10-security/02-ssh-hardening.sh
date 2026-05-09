#!/bin/bash
#===============================================================================
# Stage 10.2: SSH Security Hardening
#===============================================================================
# Production-grade SSH security configuration
#===============================================================================

set -euo pipefail

# 错误处理
trap 'log ERROR "SSH加固脚本异常退出 (行号: $LINENO)"' ERR

LOG_FILE="/var/log/ssh-hardening-$(date +%Y%m%d-%H%M%S).log"
BACKUP_DIR="/var/backups/ssh-config-$(date +%Y%m%d-%H%M%S)"
SSHD_CONFIG="/etc/ssh/sshd_config"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        INFO)    echo -e "${GREEN}[INFO]${NC} ${timestamp} - ${message}" ;;
        WARN)    echo -e "${YELLOW}[WARN]${NC} ${timestamp} - ${message}" ;;
        ERROR)   echo -e "${RED}[ERROR]${NC} ${timestamp} - ${message}" ;;
    esac
    
    echo "[${level}] ${timestamp} - ${message}" >> "$LOG_FILE"
}

#-------------------------------------------------------------------------------
# Backup Current Configuration
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# Backup Current Configuration
# 功能: 备份当前SSH配置到 $BACKUP_DIR
# 备份: sshd_config, sshd_config.d/
#-------------------------------------------------------------------------------
backup_config() {
    log INFO "Backing up current SSH configuration..."
    
    mkdir -p "$BACKUP_DIR"
    
    # Backup sshd_config
    cp "$SSHD_CONFIG" "$BACKUP_DIR/sshd_config.bak"
    
    # Backup other SSH-related files
    [[ -f /etc/ssh/sshd_config.d/* ]] && cp -r /etc/ssh/sshd_config.d "$BACKUP_DIR/" 2>/dev/null || true
    
    log INFO "Configuration backed up to ${BACKUP_DIR}"
}

#-------------------------------------------------------------------------------
# Generate SSH Key Pairs
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# Generate SSH Key Pairs
# 功能: 生成RSA(4096)、ED25519、ECDSA(521)主机密钥
# 密钥路径: /etc/ssh/ssh_host_*_key
#-------------------------------------------------------------------------------
generate_ssh_keys() {
    log INFO "Generating SSH key pairs..."
    
    local ssh_dir="/etc/ssh"
    
    # Generate RSA key (4096 bits)
    if [[ ! -f "${ssh_dir}/ssh_host_rsa_key" ]]; then
        ssh-keygen -t rsa -b 4096 -f "${ssh_dir}/ssh_host_rsa_key" -N "" -q
        log INFO "RSA key generated"
    fi
    
    # Generate ED25519 key (preferred)
    if [[ ! -f "${ssh_dir}/ssh_host_ed25519_key" ]]; then
        ssh-keygen -t ed25519 -f "${ssh_dir}/ssh_host_ed25519_key" -N "" -q
        log INFO "ED25519 key generated"
    fi
    
    # Generate ECDSA key
    if [[ ! -f "${ssh_dir}/ssh_host_ecdsa_key" ]]; then
        ssh-keygen -t ecdsa -b 521 -f "${ssh_dir}/ssh_host_ecdsa_key" -N "" -q
        log INFO "ECDSA key generated"
    fi
    
    # Set proper permissions
    chmod 600 "${ssh_dir}"/ssh_host_*_key
    chmod 644 "${ssh_dir}"/ssh_host_*_key.pub
    
    log INFO "SSH key pairs generated"
}

#-------------------------------------------------------------------------------
# Harden SSH Configuration
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# Harden SSH Configuration
# 功能: 写入加固的sshd_config配置
# 主要变更: 端口2222、禁用密码、限制root、强加密算法
#-------------------------------------------------------------------------------
harden_sshd() {
    log INFO "Applying SSH hardening configuration..."
    
    cat > "$SSHD_CONFIG" <<'EOF'
#===============================================================================
# SSH Server Configuration - Enterprise Hardened
#===============================================================================

# Network Settings
Port 2222
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

# Protocol and Host Keys
Protocol 2
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key

# Authentication - Disable Password Login
PermitRootLogin prohibit-password
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes

# Disable Password Authentication
PasswordAuthentication no
KerberosAuthentication no
GSSAPIAuthentication no

# Two-Factor Authentication (Optional - enable if configured)
# AuthenticationMethods publickey,keyboard-interactive
# ChallengeResponseAuthentication yes

# Security Settings
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitUserEnvironment no
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
MaxAuthTries 3
MaxSessions 5
MaxStartups 10:30:60

# Logging
SyslogFacility AUTH
LogLevel VERBOSE

# Access Control
AllowUsers admin deployer
AllowGroups ssh-users administrators
DenyUsers root

# Ciphers and MACs (Strong only)
Ciphers aes256-gcm@openssh.com,chacha20-poly1305@openssh.com,aes256-ctr,aes192-ctr,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-256

# Banner
Banner /etc/issue.net

# Environment Variables
AcceptEnv LANG LC_*

# Subsystem
Subsystem sftp /usr/lib/openssh/sftp-server
EOF
    
    log INFO "SSH configuration hardened"
}

#-------------------------------------------------------------------------------
# Create SSH Banner
#-------------------------------------------------------------------------------
create_banner() {
    log INFO "Creating SSH login banner..."
    
    cat > /etc/issue.net <<'EOF'
*******************************************************************
*           ENTERPRISE CLOUD NATIVE PLATFORM                     *
*           AUTHORIZED ACCESS ONLY                                *
*                                                                 *
*  All activities on this system are monitored and recorded.      *
*  Unauthorized access attempts will be prosecuted to the         *
*  full extent of the law.                                        *
*                                                                 *
*  Disconnect IMMEDIATELY if you are not an authorized user!      *
*******************************************************************
EOF
    
    log INFO "SSH banner created"
}

#-------------------------------------------------------------------------------
# Setup SSH Key-Based Authentication for Users
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# Setup SSH Key-Based Authentication for Users
# 功能: 创建用户并配置SSH密钥认证
# 参数: $1=username, $2=ssh_key(可选)
#-------------------------------------------------------------------------------
setup_user_auth() {
    local username=${1:-"admin"}
    local ssh_key=${2:-""}
    
    log INFO "Setting up SSH key authentication for ${username}..."
    
    # Create user if not exists
    if ! id "$username" &>/dev/null; then
        useradd -m -s /bin/bash "$username"
        log INFO "User ${username} created"
    fi
    
    # Create .ssh directory
    local user_home=$(eval echo "~${username}")
    mkdir -p "${user_home}/.ssh"
    chmod 700 "${user_home}/.ssh"
    
    # Generate or copy SSH key
    if [[ -n "$ssh_key" && -f "$ssh_key" ]]; then
        cp "$ssh_key" "${user_home}/.ssh/authorized_keys"
    else
        # Generate new key pair
        ssh-keygen -t ed25519 -f "${user_home}/.ssh/id_ed25519" -N "" -C "${username}@enterprise"
        cp "${user_home}/.ssh/id_ed25519.pub" "${user_home}/.ssh/authorized_keys"
        log INFO "New SSH key pair generated for ${username}"
    fi
    
    chmod 600 "${user_home}/.ssh/authorized_keys"
    chown -R "${username}:${username}" "${user_home}/.ssh"
    
    log INFO "SSH key authentication configured for ${username}"
}

#-------------------------------------------------------------------------------
# Setup SSH Group for Access Control
#-------------------------------------------------------------------------------
setup_ssh_groups() {
    log INFO "Setting up SSH access groups..."
    
    # Create groups if not exist
    groupadd -f ssh-users
    groupadd -f administrators
    
    # Add admin user to groups
    if id "admin" &>/dev/null; then
        usermod -aG ssh-users,administrators admin
        log INFO "User 'admin' added to ssh-users and administrators groups"
    fi
    
    # Create deployer user
    if ! id "deployer" &>/dev/null; then
        useradd -m -s /bin/bash deployer
        usermod -aG ssh-users deployer
        log INFO "User 'deployer' created and added to ssh-users group"
    fi
    
    log INFO "SSH groups configured"
}

#-------------------------------------------------------------------------------
# Setup SSH Rate Limiting
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# Setup SSH Rate Limiting
# 功能: 配置fail2ban限制SSH暴力破解
# 规则: 3次失败封禁24小时
#-------------------------------------------------------------------------------
setup_rate_limiting() {
    log INFO "Setting up SSH rate limiting..."
    
    # Create fail2ban configuration
    if command -v fail2ban-client &>/dev/null; then
        cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
backend = systemd

[sshd]
enabled = true
port = 2222
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 86400
EOF
        systemctl restart fail2ban
        log INFO "fail2ban configured for SSH"
    else
        log WARN "fail2ban not installed, skipping rate limiting setup"
    fi
}

#-------------------------------------------------------------------------------
# Setup SSH Audit Logging
#-------------------------------------------------------------------------------
setup_audit() {
    log INFO "Setting up SSH audit logging..."
    
    # Create audit rules for SSH
    if command -v auditctl &>/dev/null; then
        cat > /etc/audit/rules.d/ssh.rules <<'EOF'
# Monitor SSH configuration changes
-w /etc/ssh/sshd_config -p wa -k ssh_config
-w /etc/ssh/sshd_config.d/ -p wa -k ssh_config

# Monitor SSH key files
-w /etc/ssh/ -p wa -k ssh_keys

# Monitor authorized_keys changes
-w /root/.ssh/authorized_keys -p wa -k ssh_keys
-w /home/ -p wa -k ssh_keys
EOF
        auditctl -R /etc/audit/rules.d/ssh.rules 2>/dev/null || true
        log INFO "SSH audit rules configured"
    else
        log WARN "auditctl not found, skipping audit setup"
    fi
}

#-------------------------------------------------------------------------------
# Validate Configuration
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# Validate Configuration
# 功能: 使用sshd -t验证配置语法
# 返回: 0=有效, 1=无效（恢复备份）
#-------------------------------------------------------------------------------
validate_config() {
    log INFO "Validating SSH configuration..."
    
    # Test configuration
    if sshd -t -f "$SSHD_CONFIG"; then
        log INFO "SSH configuration is valid"
        return 0
    else
        log ERROR "SSH configuration is invalid!"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Main Entry Point
#-------------------------------------------------------------------------------
main() {
    log INFO "=== SSH Security Hardening Started ==="
    
    # Pre-flight checks
    if [[ $EUID -ne 0 ]]; then
        log ERROR "This script must be run as root"
        exit 1
    fi
    
    # Backup current config
    backup_config
    
    # Generate SSH keys
    generate_ssh_keys
    
    # Harden SSH configuration
    harden_sshd
    
    # Create banner
    create_banner
    
    # Setup groups and users
    setup_ssh_groups
    setup_user_auth "admin"
    setup_user_auth "deployer"
    
    # Setup rate limiting
    setup_rate_limiting
    
    # Setup audit logging
    setup_audit
    
    # Validate configuration
    if validate_config; then
        # Restart SSH service
        systemctl restart sshd
        log INFO "SSH service restarted with new configuration"
    else
        log ERROR "Restoring backup configuration..."
        cp "$BACKUP_DIR/sshd_config.bak" "$SSHD_CONFIG"
        systemctl restart sshd
        log WARN "Configuration restored from backup"
        exit 1
    fi
    
    log INFO "=== SSH Security Hardening Completed ==="
    log INFO "SSH is now listening on port 2222"
    log INFO "Password authentication is disabled"
    log INFO "Root login is restricted to key-based authentication"
    log INFO "Logs: ${LOG_FILE}"
    log INFO "Backup: ${BACKUP_DIR}"
}

main "$@"
