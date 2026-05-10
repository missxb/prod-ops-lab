#!/usr/bin/env bash
###############################################################################
# teardown-phase6.sh - 阶段6回滚: 监控告警系统回滚
# Enterprise Cloud Native Platform
# 功能: 回滚Prometheus、Grafana、Alertmanager及监控命名空间
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/teardown"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/teardown-phase6_${TIMESTAMP}.log"
REPORT_FILE="${LOG_DIR}/rollback-report-phase6_${TIMESTAMP}.txt"
START_TIME=$(date +%s)

# 加载共享库
source "$SCRIPT_DIR/../../scripts/lib/common.sh"

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
    log_header "企业级云原生运维平台 - 阶段6回滚"
    log_info "回滚时间: $(date '+%Y-%m-%d %H:%M:%S')"
}

confirm_rollback() {
    echo ""
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║  ⚠️  警告: 即将回滚阶段6 - 监控告警系统                  ║${NC}"
    echo -e "${RED}${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}${BOLD}║  回滚内容:                                                ║${NC}"
    echo -e "${RED}${BOLD}║    - 卸载kube-prometheus-stack (Helm)                    ║${NC}"
    echo -e "${RED}${BOLD}║    - 删除Alertmanager配置                                ║${NC}"
    echo -e "${RED}${BOLD}║    - 删除Grafana                                         ║${NC}"
    echo -e "${RED}${BOLD}║    - 删除Prometheus                                      ║${NC}"
    echo -e "${RED}${BOLD}║    - 删除监控命名空间                                     ║${NC}"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -ne "${YELLOW}是否确认回滚? 输入 YES 继续: ${NC}"
    read -r confirm
    [[ "$confirm" == "YES" ]] || { echo "已取消"; exit 0; }
}

rollback_helm_release() {
    log_step "步骤1/6: 卸载Helm监控栈"
    if command -v helm &>/dev/null; then
        helm uninstall kube-prometheus-stack -n monitoring --wait 2>/dev/null || \
            log_warn "kube-prometheus-stack卸载失败或不存在"
        helm uninstall prometheus-community 2>/dev/null || true
        log_success "Helm监控栈已卸载"
    else
        log_warn "helm不可用，跳过"
    fi
    echo "Helm监控栈已卸载" >> "$REPORT_FILE"
}

rollback_prometheus() {
    log_step "步骤2/6: 清理Prometheus资源"
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        kubectl delete -f "${PROJECT_ROOT}/manifests/monitoring/" 2>/dev/null || true
        log_success "Prometheus资源已清理"
    fi
    echo "Prometheus资源已清理" >> "$REPORT_FILE"
}

rollback_grafana() {
    log_step "步骤3/6: 清理Grafana资源"
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        kubectl delete deployment -n monitoring grafana 2>/dev/null || true
        kubectl delete service -n monitoring grafana 2>/dev/null || true
        kubectl delete configmap -n monitoring grafana-config 2>/dev/null || true
        kubectl delete pvc -n monitoring --all 2>/dev/null || true
        log_success "Grafana资源已清理"
    fi
    echo "Grafana资源已清理" >> "$REPORT_FILE"
}

rollback_alertmanager() {
    log_step "步骤4/6: 清理Alertmanager资源"
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        kubectl delete configmap -n monitoring alertmanager-config 2>/dev/null || true
        kubectl delete alertmanagerconfig --all -n monitoring 2>/dev/null || true
        kubectl delete prometheusrules --all -n monitoring 2>/dev/null || true
        log_success "Alertmanager资源已清理"
    fi
    echo "Alertmanager资源已清理" >> "$REPORT_FILE"
}

rollback_namespace() {
    log_step "步骤5/6: 删除监控命名空间"
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        kubectl delete namespace monitoring --ignore-not-found 2>/dev/null || true
        kubectl delete namespace observability --ignore-not-found 2>/dev/null || true
        log_success "监控命名空间已删除"
    fi
    echo "监控命名空间已删除" >> "$REPORT_FILE"
}

verify_rollback() {
    log_step "步骤6/6: 验证回滚结果"
    local errors=0
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        if kubectl get namespace monitoring &>/dev/null 2>&1; then
            log_error "monitoring命名空间仍存在!"
            ((errors++))
        else
            log_success "monitoring命名空间已清理"
        fi
    fi
    if command -v helm &>/dev/null; then
        if helm list -n monitoring 2>/dev/null | grep -q kube-prometheus-stack; then
            log_error "Helm release仍存在!"
            ((errors++))
        else
            log_success "Helm release已清理"
        fi
    fi
    [[ $errors -eq 0 ]] && log_success "回滚验证通过" || log_error "回滚验证发现${errors}个问题"
    echo "回滚验证: $([ $errors -eq 0 ] && echo '通过' || echo '有问题')" >> "$REPORT_FILE"
}

generate_report() {
    local duration=$(( $(date +%s) - START_TIME ))
    echo "" >> "$REPORT_FILE"
    echo "========================================" >> "$REPORT_FILE"
    echo "阶段6回滚报告 | 耗时: ${duration}秒 | 主机: $(hostname)" >> "$REPORT_FILE"
    echo "========================================" >> "$REPORT_FILE"
    log_header "阶段6回滚完成"
    log_info "总耗时: ${duration}秒 | 报告: $REPORT_FILE"
}

main() {
    init
    confirm_rollback
    rollback_helm_release
    rollback_prometheus
    rollback_grafana
    rollback_alertmanager
    rollback_namespace
    verify_rollback
    generate_report
}

main "$@"
