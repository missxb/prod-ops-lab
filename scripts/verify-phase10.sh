#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# 阶段10: 安全加固验证
# 验证项目: SSL证书、SSH加固、防火墙、容器扫描、K8s RBAC
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPORT_DIR="$PROJECT_DIR/reports"
REPORT_FILE="$REPORT_DIR/verify-phase10-$(date +%Y%m%d-%H%M%S).log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
TOTAL_COUNT=0

mkdir -p "$REPORT_DIR"

log() { local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"; echo -e "$msg"; echo "$msg" >> "$REPORT_FILE"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); TOTAL_COUNT=$((TOTAL_COUNT + 1)); log "${GREEN}[PASS]${NC} $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); TOTAL_COUNT=$((TOTAL_COUNT + 1)); log "${RED}[FAIL]${NC} $1"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); TOTAL_COUNT=$((TOTAL_COUNT + 1)); log "${YELLOW}[WARN]${NC} $1"; }
info() { log "${BLUE}[INFO]${NC} $1"; }
section() { echo ""; log "${CYAN}========== $1 ==========${NC}"; }

# ========== 开始验证 ==========
section "阶段10: 安全加固验证"

# --- 10.1 SSL证书检查 ---
section "10.1 SSL/TLS证书检查"

# 检查K8s中的证书资源
if command -v kubectl &>/dev/null; then
    CERTS=$(kubectl get certificates --all-namespaces --no-headers 2>/dev/null || echo "")
    CERT_COUNT=$(echo "$CERTS" | grep -c . 2>/dev/null || echo "0")
    if [[ $CERT_COUNT -gt 0 ]]; then
        pass "K8s Certificate资源数量: $CERT_COUNT"
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            CERT_NS=$(echo "$line" | awk '{print $1}')
            CERT_NAME=$(echo "$line" | awk '{print $2}')
            CERT_READY=$(echo "$line" | awk '{print $3}')
            if [[ "$CERT_READY" == "True" ]]; then
                pass "证书 $CERT_NS/$CERT_NAME Ready"
            else
                warn "证书 $CERT_NS/$CERT_NAME 状态: $CERT_READY"
            fi
        done <<< "$CERTS"
    else
        info "未发现K8s Certificate资源"
    fi

    # 检查cert-manager
    CERT_MANAGER_PODS=$(kubectl get pods -n cert-manager --no-headers 2>/dev/null || echo "")
    if [[ -n "$CERT_MANAGER_PODS" ]]; then
        if echo "$CERT_MANAGER_PODS" | grep -q "Running"; then
            pass "cert-manager 运行正常"
        else
            warn "cert-manager 异常"
        fi
    else
        info "cert-manager 未部署"
    fi
fi

# 检查本地SSL证书
SSL_DIRS=("/etc/ssl/certs" "/etc/pki/tls/certs" "/etc/nginx/ssl")
for dir in "${SSL_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        CERT_FILES=$(ls "$dir"/*.pem "$dir"/*.crt 2>/dev/null | wc -l || echo "0")
        if [[ $CERT_FILES -gt 0 ]]; then
            pass "SSL证书目录 $dir 存在 ($CERT_FILES 个证书文件)"
        fi
    fi
done

# --- 10.2 SSH安全加固检查 ---
section "10.2 SSH安全加固检查"

SSHD_CONFIG="/etc/ssh/sshd_config"
if [[ -f "$SSHD_CONFIG" ]]; then
    pass "sshd_config 文件存在"

    # 检查关键安全配置
    if grep -qi "^PermitRootLogin no" "$SSHD_CONFIG" 2>/dev/null; then
        pass "SSH: Root登录已禁止"
    elif grep -qi "^PermitRootLogin prohibit-password" "$SSHD_CONFIG" 2>/dev/null; then
        pass "SSH: Root密码登录已禁止(密钥仍允许)"
    else
        warn "SSH: Root登录未禁止"
    fi

    if grep -qi "^PasswordAuthentication no" "$SSHD_CONFIG" 2>/dev/null; then
        pass "SSH: 密码认证已禁止"
    else
        warn "SSH: 密码认证仍启用"
    fi

    if grep -qi "^MaxAuthTries" "$SSHD_CONFIG" 2>/dev/null; then
        MAX_AUTH=$(grep "^MaxAuthTries" "$SSHD_CONFIG" | awk '{print $2}')
        pass "SSH: 最大认证尝试次数已限制 ($MAX_AUTH)"
    else
        info "SSH: 未设置最大认证尝试次数"
    fi

    # 检查非标准SSH端口
    SSH_PORT=$(grep -E "^Port [0-9]+" "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}' || echo "22")
    if [[ "$SSH_PORT" != "22" ]]; then
        pass "SSH: 使用非标准端口 $SSH_PORT"
    else
        info "SSH: 使用默认端口22"
    fi
else
    warn "sshd_config 文件不存在"
fi

# 检查SSH服务
if systemctl is-active sshd &>/dev/null || systemctl is-active ssh &>/dev/null; then
    pass "SSH服务运行中"
else
    fail "SSH服务未运行"
fi

# --- 10.3 防火墙检查 ---
section "10.3 防火墙规则检查"

FIREWALL_ACTIVE=false

if command -v firewall-cmd &>/dev/null; then
    if systemctl is-active firewalld &>/dev/null; then
        pass "firewalld 运行中"
        FIREWALL_ACTIVE=true

        # 列出开放端口
        OPEN_PORTS=$(firewall-cmd --list-ports 2>/dev/null || echo "")
        if [[ -n "$OPEN_PORTS" ]]; then
            info "开放端口: $OPEN_PORTS"
        fi

        OPEN_SERVICES=$(firewall-cmd --list-services 2>/dev/null || echo "")
        if [[ -n "$OPEN_SERVICES" ]]; then
            info "开放服务: $OPEN_SERVICES"
        fi
    else
        warn "firewalld 已安装但未运行"
    fi
fi

if command -v iptables &>/dev/null; then
    IPTABLES_RULES=$(iptables -L -n 2>/dev/null | grep -c "DROP\|REJECT" || echo "0")
    if [[ $IPTABLES_RULES -gt 0 ]]; then
        pass "iptables 防火墙规则存在 ($IPTABLES_RULES 条DROP/REJECT规则)"
        FIREWALL_ACTIVE=true
    fi
fi

if [[ "$FIREWALL_ACTIVE" == false ]]; then
    info "未检测到活跃的防火墙 (可能使用云安全组)"
fi

# --- 10.4 容器安全扫描检查 ---
section "10.4 容器安全扫描检查"

if command -v trivy &>/dev/null; then
    TRIVY_VERSION=$(trivy --version 2>/dev/null | head -1 || echo "unknown")
    pass "Trivy 已安装: $TRIVY_VERSION"
else
    info "Trivy 未安装在本机 (可能在K8s中)"
fi

# 检查K8s中的Trivy
if command -v kubectl &>/dev/null; then
    TRIVY_PODS=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -i trivy || echo "")
    if [[ -n "$TRIVY_PODS" ]]; then
        if echo "$TRIVY_PODS" | grep -q "Running"; then
            pass "K8s Trivy Pod 运行正常"
        fi
    fi
fi

# 检查镜像扫描结果
SCAN_RESULTS=$(find /var/log /tmp /root -name "*trivy*" -o -name "*scan*result*" 2>/dev/null | head -5 || echo "")
if [[ -n "$SCAN_RESULTS" ]]; then
    pass "容器扫描结果文件存在"
else
    info "未发现容器扫描结果文件"
fi

# --- 10.5 Kubernetes RBAC检查 ---
section "10.5 Kubernetes RBAC检查"

if command -v kubectl &>/dev/null; then
    # 检查ClusterRoleBinding
    CRB_COUNT=$(kubectl get clusterrolebindings --no-headers 2>/dev/null | wc -l || echo "0")
    if [[ $CRB_COUNT -gt 0 ]]; then
        pass "ClusterRoleBinding 数量: $CRB_COUNT"
    fi

    # 检查自定义RoleBinding
    RB_ALL=$(kubectl get rolebindings --all-namespaces --no-headers 2>/dev/null || echo "")
    RB_COUNT=$(echo "$RB_ALL" | grep -c . 2>/dev/null || echo "0")
    if [[ $RB_COUNT -gt 0 ]]; then
        pass "RoleBinding 数量: $RB_COUNT"
    fi

    # 检查ServiceAccount
    SA_ALL=$(kubectl get serviceaccounts --all-namespaces --no-headers 2>/dev/null || echo "")
    SA_COUNT=$(echo "$SA_ALL" | grep -c . 2>/dev/null || echo "0")
    info "ServiceAccount 数量: $SA_COUNT"

    # 检查默认ServiceAccount的自动挂载
    DEFAULT_SA_MOUNT=$(kubectl get serviceaccount default -n default -o jsonpath='{.automountServiceAccountToken}' 2>/dev/null || echo "true")
    if [[ "$DEFAULT_SA_MOUNT" == "false" ]]; then
        pass "默认ServiceAccount自动挂载Token已禁用"
    else
        info "默认ServiceAccount自动挂载Token: $DEFAULT_SA_MOUNT"
    fi

    # 检查Pod Security
    PSA_LABELS=$(kubectl get namespace default -o jsonpath='{.metadata.labels}' 2>/dev/null || echo "")
    if echo "$PSA_LABELS" | grep -q "pod-security.kubernetes.io"; then
        pass "Pod Security Admission 已配置"
    else
        info "Pod Security Admission 未配置"
    fi
fi

# 检查K8s安全配置文件
K8S_SECURITY_CONFIGS=(
    "$PROJECT_DIR/configs/kubernetes/pod-security.yaml"
    "$PROJECT_DIR/configs/kubernetes/network-policy.yaml"
    "$PROJECT_DIR/configs/kubernetes/rbac-readonly.yaml"
    "$PROJECT_DIR/configs/kubernetes/rbac-admin.yaml"
)

for config in "${K8S_SECURITY_CONFIGS[@]}"; do
    if [[ -f "$config" ]]; then
        CONFIG_NAME=$(basename "$config")
        pass "安全配置文件存在: $CONFIG_NAME"
    fi
done

# --- 10.6 系统安全检查 ---
section "10.6 系统安全检查"

# 检查SELinux
if command -v getenforce &>/dev/null; then
    SELINUX_STATUS=$(getenforce 2>/dev/null || echo "unknown")
    if [[ "$SELINUX_STATUS" == "Enforcing" ]]; then
        pass "SELinux 状态: Enforcing"
    elif [[ "$SELINUX_STATUS" == "Permissive" ]]; then
        warn "SELinux 状态: Permissive"
    else
        info "SELinux 状态: $SELINUX_STATUS"
    fi
fi

# 检查自动安全更新
if systemctl is-active dnf-automatic.timer &>/dev/null || systemctl is-active yum-cron &>/dev/null || systemctl is-active unattended-upgrades &>/dev/null; then
    pass "自动安全更新已配置"
else
    info "未检测到自动安全更新服务"
fi

# 检查审计服务
if systemctl is-active auditd &>/dev/null; then
    pass "审计服务(auditd)运行中"
else
    info "审计服务(auditd)未运行"
fi

# ========== 验证报告 ==========
section "验证汇总"

echo ""
log "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
log "${CYAN}║          阶段10: 安全加固验证报告               ║${NC}"
log "${CYAN}╠══════════════════════════════════════════════════╣${NC}"
log "${CYAN}║${NC} 总检查项:  ${TOTAL_COUNT}                                    ${CYAN}║${NC}"
log "${GREEN}║${NC} 通过:      ${PASS_COUNT}                                    ${GREEN}║${NC}"
log "${RED}║${NC} 失败:      ${FAIL_COUNT}                                    ${RED}║${NC}"
log "${YELLOW}║${NC} 警告:      ${WARN_COUNT}                                    ${YELLOW}║${NC}"
log "${CYAN}╠══════════════════════════════════════════════════╣${NC}"

if [[ $FAIL_COUNT -eq 0 ]]; then
    if [[ $WARN_COUNT -eq 0 ]]; then
        log "${GREEN}║  结果: ✓ 全部通过                               ║${NC}"
    else
        log "${YELLOW}║  结果: △ 通过(有警告)                           ║${NC}"
    fi
else
    log "${RED}║  结果: ✗ 存在失败项                             ║${NC}"
fi

log "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
log ""
log "报告已保存: $REPORT_FILE"

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
