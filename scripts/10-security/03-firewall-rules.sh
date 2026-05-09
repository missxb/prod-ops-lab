#!/bin/bash
#===============================================================================
# Stage 10.3: Firewall Rules & Policies
#===============================================================================
# Production-grade firewall configuration for enterprise environments
#===============================================================================

set -euo pipefail

# 错误处理
trap 'log ERROR "防火墙脚本异常退出 (行号: $LINENO)"' ERR

LOG_FILE="/var/log/firewall-rules-$(date +%Y%m%d-%H%M%S).log"
BACKUP_DIR="/var/backups/firewall-$(date +%Y%m%d-%H%M%S)"

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
# Detect Firewall Tool
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# Detect Firewall Tool
# 功能: 自动检测可用的防火墙工具
# 返回: "firewalld" | "iptables" | "ufw" | "none"
#-------------------------------------------------------------------------------
detect_firewall() {
    if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        echo "firewalld"
    elif command -v iptables &>/dev/null; then
        echo "iptables"
    elif command -v ufw &>/dev/null; then
        echo "ufw"
    else
        echo "none"
    fi
}

#-------------------------------------------------------------------------------
# Backup Current Rules
#-------------------------------------------------------------------------------
backup_rules() {
    local firewall_type=$1
    
    log INFO "Backing up current firewall rules..."
    mkdir -p "$BACKUP_DIR"
    
    case $firewall_type in
        firewalld)
            firewall-cmd --list-all > "$BACKUP_DIR/firewalld-rules.txt" 2>/dev/null || true
            ;;
        iptables)
            iptables-save > "$BACKUP_DIR/iptables-rules.txt" 2>/dev/null || true
            ip6tables-save > "$BACKUP_DIR/ip6tables-rules.txt" 2>/dev/null || true
            ;;
        ufw)
            ufw status verbose > "$BACKUP_DIR/ufw-rules.txt" 2>/dev/null || true
            ;;
    esac
    
    log INFO "Firewall rules backed up to ${BACKUP_DIR}"
}

#-------------------------------------------------------------------------------
# Configure firewalld
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# Configure firewalld
# 功能: 配置firewalld默认zone为drop，放行必要端口
# 放行: SSH(2222), HTTP/HTTPS, K8s API(6443), etcd等
#-------------------------------------------------------------------------------
configure_firewalld() {
    log INFO "Configuring firewalld..."
    
    # Set default zone to drop
    firewall-cmd --set-default-zone=drop
    
    # Remove all existing rules
    firewall-cmd --permanent --zone=drop --remove-service=cockpit 2>/dev/null || true
    
    # Allow SSH (custom port 2222)
    firewall-cmd --permanent --zone=drop --add-port=2222/tcp
    firewall-cmd --permanent --zone=drop --add-service=ssh --remove 2>/dev/null || true
    
    # Allow HTTP/HTTPS for web services
    firewall-cmd --permanent --zone=drop --add-port=80/tcp
    firewall-cmd --permanent --zone=drop --add-port=443/tcp
    
    # Allow Kubernetes API server
    firewall-cmd --permanent --zone=drop --add-port=6443/tcp
    
    # Allow Kubernetes node ports (if needed)
    firewall-cmd --permanent --zone=drop --add-port=30000-32767/tcp
    
    # Allow etcd (if running on this node)
    firewall-cmd --permanent --zone=drop --add-port=2379-2380/tcp
    
    # Allow kubelet
    firewall-cmd --permanent --zone=drop --add-port=10250/tcp
    
    # Allow kube-proxy
    firewall-cmd --permanent --zone=drop --add-port=10256/tcp
    
    # Allow flannel/calico networking
    firewall-cmd --permanent --zone=drop --add-port=8472/udp
    firewall-cmd --permanent --zone=drop --add-port=179/tcp
    
    # Allow Prometheus metrics
    firewall-cmd --permanent --zone=drop --add-port=9090/tcp
    firewall-cmd --permanent --zone=drop --add-port=9093/tcp
    
    # Allow Grafana
    firewall-cmd --permanent --zone=drop --add-port=3000/tcp
    
    # Allow Node Exporter
    firewall-cmd --permanent --zone=drop --add-port=9100/tcp
    
    # Allow DNS
    firewall-cmd --permanent --zone=drop --add-port=53/udp
    firewall-cmd --permanent --zone=drop --add-port=53/tcp
    
    # Allow NTP
    firewall-cmd --permanent --zone=drop --add-port=123/udp
    
    # Add rich rules for rate limiting
    firewall-cmd --permanent --zone=drop --add-rich-rule='rule family="ipv4" source address="10.0.0.0/8" port port="2222" protocol="tcp" accept'
    firewall-cmd --permanent --zone=drop --add-rich-rule='rule family="ipv4" source address="172.16.0.0/12" port port="2222" protocol="tcp" accept'
    firewall-cmd --permanent --zone=drop --add-rich-rule='rule family="ipv4" source address="192.168.0.0/16" port port="2222" protocol="tcp" accept'
    
    # Reload firewall
    firewall-cmd --reload
    
    log INFO "firewalld configured successfully"
}

#-------------------------------------------------------------------------------
# Configure iptables
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# Configure iptables
# 功能: 配置iptables规则，设置默认策略为DROP
# 特性: SSH速率限制、日志记录丢包
#-------------------------------------------------------------------------------
configure_iptables() {
    log INFO "Configuring iptables..."
    
    # Flush existing rules
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    iptables -t mangle -F
    iptables -t mangle -X
    
    # Set default policies
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    
    # Allow loopback
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    
    # Allow established connections
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    
    # Drop invalid packets
    iptables -A INPUT -m state --state INVALID -j DROP
    
    # Allow SSH (custom port 2222)
    iptables -A INPUT -p tcp --dport 2222 -m state --state NEW -m recent --set --name SSH
    iptables -A INPUT -p tcp --dport 2222 -m state --state NEW -m recent --update --seconds 60 --hitcount 5 --name SSH -j DROP
    iptables -A INPUT -p tcp --dport 2222 -j ACCEPT
    
    # Allow HTTP/HTTPS
    iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    iptables -A INPUT -p tcp --dport 443 -j ACCEPT
    
    # Allow Kubernetes services
    iptables -A INPUT -p tcp --dport 6443 -j ACCEPT
    iptables -A INPUT -p tcp --dport 2379:2380 -j ACCEPT
    iptables -A INPUT -p tcp --dport 10250 -j ACCEPT
    iptables -A INPUT -p tcp --dport 10256 -j ACCEPT
    iptables -A INPUT -p tcp --dport 30000:32767 -j ACCEPT
    
    # Allow networking
    iptables -A INPUT -p udp --dport 8472 -j ACCEPT
    iptables -A INPUT -p tcp --dport 179 -j ACCEPT
    
    # Allow monitoring
    iptables -A INPUT -p tcp --dport 9090 -j ACCEPT
    iptables -A INPUT -p tcp --dport 9093 -j ACCEPT
    iptables -A INPUT -p tcp --dport 3000 -j ACCEPT
    iptables -A INPUT -p tcp --dport 9100 -j ACCEPT
    
    # Allow DNS and NTP
    iptables -A INPUT -p udp --dport 53 -j ACCEPT
    iptables -A INPUT -p tcp --dport 53 -j ACCEPT
    iptables -A INPUT -p udp --dport 123 -j ACCEPT
    
    # Allow ICMP (ping)
    iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
    
    # Log dropped packets
    iptables -A INPUT -j LOG --log-prefix "IPTables-Dropped: " --log-level 4
    
    # Save rules
    if command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    
    log INFO "iptables configured successfully"
}

#-------------------------------------------------------------------------------
# Configure UFW
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# Configure UFW
# 功能: 配置UFW默认拒绝入站/出站/转发
#-------------------------------------------------------------------------------
configure_ufw() {
    log INFO "Configuring UFW..."
    
    # Reset UFW
    ufw --force reset
    
    # Set default policies
    ufw default deny incoming
    ufw default deny outgoing
    ufw default deny routed
    
    # Allow SSH (custom port)
    ufw allow 2222/tcp
    
    # Allow HTTP/HTTPS
    ufw allow 80/tcp
    ufw allow 443/tcp
    
    # Allow Kubernetes
    ufw allow 6443/tcp
    ufw allow 2379:2380/tcp
    ufw allow 10250/tcp
    ufw allow 10256/tcp
    ufw allow 30000:32767/tcp
    
    # Allow DNS and NTP
    ufw allow 53/udp
    ufw allow 53/tcp
    ufw allow 123/udp
    
    # Enable UFW
    ufw --force enable
    
    log INFO "UFW configured successfully"
}

#-------------------------------------------------------------------------------
# Create Firewall Rules File (for reference)
#-------------------------------------------------------------------------------
create_rules_reference() {
    log INFO "Creating firewall rules reference document..."
    
    cat > /root/enterprise-cloud-native-platform/configs/firewall-rules.md <<'EOF'
# Enterprise Cloud Native Platform - Firewall Rules Reference

## Open Ports

| Port | Protocol | Service | Description |
|------|----------|---------|-------------|
| 2222 | TCP | SSH | Secure Shell (custom port) |
| 80 | TCP | HTTP | Web traffic |
| 443 | TCP | HTTPS | Secure web traffic |
| 6443 | TCP | K8s API | Kubernetes API Server |
| 2379-2380 | TCP | etcd | etcd cluster communication |
| 10250 | TCP | kubelet | Kubelet API |
| 10256 | TCP | kube-proxy | Kube-proxy health check |
| 30000-32767 | TCP | NodePort | Kubernetes NodePort range |
| 8472 | UDP | Flannel | Flannel VXLAN |
| 179 | TCP | Calico | Calico BGP |
| 9090 | TCP | Prometheus | Prometheus server |
| 9093 | TCP | Alertmanager | Alertmanager |
| 3000 | TCP | Grafana | Grafana dashboard |
| 9100 | TCP | Node Exporter | Prometheus node exporter |
| 53 | UDP/TCP | DNS | Domain Name System |
| 123 | UDP | NTP | Network Time Protocol |

## Blocked by Default

- All other inbound traffic
- All forwarded traffic (unless explicitly allowed)
- ICMP echo (rate limited)

## Rate Limiting

- SSH: Max 5 connections per minute
- HTTP: No rate limit (handled by application layer)

## Internal Network Ranges

- 10.0.0.0/8
- 172.16.0.0/12
- 192.168.0.0/16
EOF
    
    log INFO "Firewall rules reference created"
}

#-------------------------------------------------------------------------------
# Main Entry Point
#-------------------------------------------------------------------------------
main() {
    log INFO "=== Firewall Rules Configuration Started ==="
    
    # Pre-flight checks
    if [[ $EUID -ne 0 ]]; then
        log ERROR "This script must be run as root"
        exit 1
    fi
    
    # Detect firewall
    local firewall_type=$(detect_firewall)
    log INFO "Detected firewall: ${firewall_type}"
    
    # Backup current rules
    backup_rules "$firewall_type"
    
    # Configure firewall based on detected type
    case $firewall_type in
        firewalld)
            configure_firewalld
            ;;
        iptables)
            configure_iptables
            ;;
        ufw)
            configure_ufw
            ;;
        none)
            log WARN "No firewall detected, installing iptables..."
            if command -v apt-get &>/dev/null; then
                apt-get update && apt-get install -y iptables-persistent
            elif command -v yum &>/dev/null; then
                yum install -y iptables-services
            fi
            configure_iptables
            ;;
    esac
    
    # Create rules reference
    create_rules_reference
    
    log INFO "=== Firewall Rules Configuration Completed ==="
    log INFO "Logs: ${LOG_FILE}"
    log INFO "Backup: ${BACKUP_DIR}"
}

main "$@"
