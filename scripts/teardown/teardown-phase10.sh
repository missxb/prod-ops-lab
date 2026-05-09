#!/usr/bin/env bash
###############################################################################
# teardown-phase10.sh - 阶段10回滚: 安全加固回滚
# Enterprise Cloud Native Platform
# 功能: 回滚SSL/TLS、SSH加固、防火墙规则、容器扫描、RBAC配置
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/teardown"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/teardown-phase10_${TIMESTAMP}.log"
REPORT_FILE="${LOG_DIR}/rollback-report-phase10_${TIMESTAMP}.txt"
START_TIME=$(date +%s)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_step()    { echo -e "${CYAN}[STEP]${NC}    $(date '+%Y-%m-%d %H:%M:%S') === $* ===" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[OK]${NC}      $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_header() {
    echo -e ""
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║${NC}  ${BOLD}${MAGENTA}$*${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo -e ""
}

init() {
    mkdir -p "$LOG_DIR"
    log_header "企业级云原生运维平台 - 阶段10回滚"
    log_info "回滚时间: $(date '+%Y-%m-%d %H:%M:%S')"
}

confirm_rollback() {
    echo ""
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║  ⚠️  警告: 即将回滚阶段10 - 安全加固                     ║${NC}"
    echo -e "${RED}${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}${BOLD}║  回滚内容:                                                ║${NC}"
    echo -e "${RED}${BOLD}║    - 回滚SSL/TLS证书管理                                  ║${NC}"
    echo -e "${RED}${BOLD}║    - 回滚SSH安全加固                                      ║${NC}"
    echo -e "${RED}${BOLD}║    - 回滚防火墙规则                                       ║${NC}"
    echo -e "${RED}${BOLD}║    - 清理K8s RBAC配置                                     ║${NC}"
    echo -e "${RED}${BOLD}║    - 清理NetworkPolicy和PSP                              ║${NC}"
    echo -e "${RED}${BOLD}║    - 恢复系统默认安全配置                                 ║${NC}"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -ne "${YELLOW}是否确认回滚? 输入 YES 继续: ${NC}"
    read -r confirm
    [[ "$confirm" == "YES" ]] || { echo "已取消"; exit 0; }
}

rollback_ssl() {
    log_step "步骤1/7: 回滚SSL/TLS证书管理"
    
    # 恢复nginx SSL配置
    if [[ -f /etc/nginx/conf.d/ssl.conf.bak ]]; then
        log_info "恢复nginx SSL配置..."
        cp /etc/nginx/conf.d/ssl.conf.bak /etc/nginx/conf.d/ssl.conf 2>/dev/null || true
        systemctl restart nginx 2>/dev/null || true
    fi
    
    # 清理自定义证书
    if [[ -d /etc/ssl/custom ]]; then
        log_info "备份并清理自定义证书..."
        tar -czf "/tmp/ssl-backup-${TIMESTAMP}.tar.gz" -C /etc ssl/custom 2>/dev/null || true
        rm -rf /etc/ssl/custom
    fi
    
    log_success "SSL/TLS配置已回滚"
    echo "SSL/TLS配置已回滚" >> "$REPORT_FILE"
}

rollback_ssh() {
    log_step "步骤2/7: 回滚SSH安全加固"
    
    if [[ -f /etc/ssh/sshd_config.bak ]]; then
        log_info "恢复SSH配置..."
        cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
        log_success "SSH配置已恢复"
    else
        log_warn "SSH备份配置不存在，跳过"
    fi
    
    echo "SSH配置已回滚" >> "$REPORT_FILE"
}

rollback_firewall() {
    log_step "步骤3/7: 回滚防火墙规则"
    
    if command -v firewall-cmd &>/dev/null; then
        log_info "恢复防火墙规则..."
        # 恢复默认区域
        firewall-cmd --set-default-zone=public 2>/dev/null || true
        
        # 移除自定义规则
        firewall-cmd --permanent --remove-port=6443/tcp 2>/dev/null || true
        firewall-cmd --permanent --remove-port=2379-2380/tcp 2>/dev/null || true
        firewall-cmd --permanent --remove-port=10250/tcp 2>/dev/null || true
        firewall-cmd --permanent --remove-port=10251/tcp 2>/dev/null || true
        firewall-cmd --permanent --remove-port=10252/tcp 2>/dev/null || true
        firewall-cmd --permanent --remove-port=10255/tcp 2>/dev/null || true
        firewall-cmd --permanent --remove-port=8472/udp 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        
        log_success "防火墙规则已恢复"
    else
        log_warn "firewalld不可用，跳过"
    fi
    
    echo "防火墙规则已回滚" >> "$REPORT_FILE"
}

rollback_container_scan() {
    log_step "步骤4/7: 清理容器扫描配置"
    
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        # 删除Trivy扫描配置
        kubectl delete configmap trivy-scan-config -n trivy 2>/dev/null || true
        kubectl delete cronjob trivy-scan -n trivy 2>/dev/null || true
        log_success "容器扫描配置已清理"
    fi
    
    echo "容器扫描配置已清理" >> "$REPORT_FILE"
}

rollback_rbac() {
    log_step "步骤5/7: 清理K8s RBAC配置"
    
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        # 删除自定义ClusterRole
        kubectl delete clusterrole app-developer 2>/dev/null || true
        kubectl delete clusterrole app-viewer 2>/dev/null || true
        kubectl delete clusterrole security-auditor 2>/dev/null || true
        
        # 删除自定义ClusterRoleBinding
        kubectl delete clusterrolebinding dev-binding 2>/dev/null || true
        kubectl delete clusterrolebinding viewer-binding 2>/dev/null || true
        
        # 删除自定义ServiceAccount
        for ns in dev prod; do
            kubectl delete serviceaccount --all -n "$ns" 2>/dev/null || true
        done
        
        log_success "RBAC配置已清理"
    fi
    
    echo "RBAC配置已清理" >> "$REPORT_FILE"
}

rollback_network_policy() {
    log_step "步骤6/7: 清理NetworkPolicy和PSP"
    
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        # 删除NetworkPolicy
        kubectl delete networkpolicy --all -n default 2>/dev/null || true
        kubectl delete networkpolicy --all -n kube-system 2>/dev/null || true
        kubectl delete networkpolicy --all -n monitoring 2>/dev/null || true
        
        # 删除PodSecurityPolicy (K8s 1.25+ 已移除)
        kubectl delete podsecuritypolicy --all 2>/dev/null || true
        
        # 删除PodSecurityAdmission配置
        kubectl delete namespace --all -l pod-security.kubernetes.io/enforce 2>/dev/null || true
        
        log_success "NetworkPolicy和PSP已清理"
    fi
    
    echo "NetworkPolicy和PSP已清理" >> "$REPORT_FILE"
}

verify_rollback() {
    log_step "步骤7/7: 验证回滚结果"
    local errors=0
    
    # 验证SSH配置
    if [[ -f /etc/ssh/sshd_config.bak ]]; then
        if grep -q "PermitRootLogin no" /etc/ssh/sshd_config; then
            log_warn "SSH仍禁止root登录"
        else
            log_success "SSH配置已恢复"
        fi
    fi
    
    # 验证防火墙
    if command -v firewall-cmd &>/dev/null; then
        local zone=$(firewall-cmd --get-default-zone 2>/dev/null)
        if [[ "$zone" == "public" ]]; then
            log_success "防火墙默认区域已恢复"
        else
            log_warn "防火墙默认区域: $zone"
        fi
    fi
    
    # 验证K8s RBAC
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        if kubectl get clusterrole app-developer &>/dev/null 2>&1; then
            log_error "app-developer ClusterRole仍存在!"
            ((errors++))
        else
            log_success "RBAC配置已清理"
        fi
    fi
    
    [[ $errors -eq 0 ]] && log_success "回滚验证通过" || log_error "回滚验证发现${errors}个问题"
    echo "回滚验证: $([ $errors -eq 0 ] && echo '通过' || echo '有问题')" >> "$REPORT_FILE"
}

generate_report() {
    local duration=$(( $(date +%s) - START_TIME ))
    echo "" >> "$REPORT_FILE"
    echo "========================================" >> "$REPORT_FILE"
    echo "阶段10回滚报告 | 耗时: ${duration}秒 | 主机: $(hostname)" >> "$REPORT_FILE"
    echo "========================================" >> "$REPORT_FILE"
    log_header "阶段10回滚完成"
    log_info "总耗时: ${duration}秒 | 报告: $REPORT_FILE"
}

main() {
    init
    confirm_rollback
    rollback_ssl
    rollback_ssh
    rollback_firewall
    rollback_container_scan
    rollback_rbac
    rollback_network_policy
    verify_rollback
    generate_report
}

main "$@"
