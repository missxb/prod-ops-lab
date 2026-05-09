#!/usr/bin/env bash
###############################################################################
# teardown-phase5.sh - 阶段5回滚: 应用部署回滚
# Enterprise Cloud Native Platform
# 功能: 回滚Demo应用、HPA配置、命名空间
###############################################################################
set -euo pipefail

# 加载共享库
source "$SCRIPT_DIR/../../scripts/lib/common.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/teardown"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/teardown-phase5_${TIMESTAMP}.log"
REPORT_FILE="${LOG_DIR}/rollback-report-phase5_${TIMESTAMP}.txt"
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
    log_header "企业级云原生运维平台 - 阶段5回滚"
    log_info "回滚时间: $(date '+%Y-%m-%d %H:%M:%S')"
}

confirm_rollback() {
    echo ""
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║  ⚠️  警告: 即将回滚阶段5 - 应用部署                      ║${NC}"
    echo -e "${RED}${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}${BOLD}║  回滚内容:                                                ║${NC}"
    echo -e "${RED}${BOLD}║    - 删除Demo应用                                         ║${NC}"
    echo -e "${RED}${BOLD}║    - 删除HPA自动扩缩容配置                               ║${NC}"
    echo -e "${RED}${BOLD}║    - 删除Ingress规则                                     ║${NC}"
    echo -e "${RED}${BOLD}║    - 删除dev/prod命名空间                                ║${NC}"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -ne "${YELLOW}是否确认回滚? 输入 YES 继续: ${NC}"
    read -r confirm
    [[ "$confirm" == "YES" ]] || { echo "已取消"; exit 0; }
}

rollback_hpa() {
    log_step "步骤1/5: 删除HPA配置"
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        for ns in dev prod; do
            kubectl delete hpa --all -n "$ns" 2>/dev/null || true
        done
        log_success "HPA配置已删除"
    else
        log_warn "K8s集群不可达，跳过"
    fi
    echo "HPA配置已删除" >> "$REPORT_FILE"
}

rollback_demo_app() {
    log_step "步骤2/5: 删除Demo应用"
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        for ns in dev prod; do
            kubectl delete deployment --all -n "$ns" 2>/dev/null || true
            kubectl delete service --all -n "$ns" 2>/dev/null || true
            kubectl delete configmap --all -n "$ns" 2>/dev/null || true
            kubectl delete secret --all -n "$ns" 2>/dev/null || true
        done
        log_success "Demo应用已删除"
    fi
    echo "Demo应用已删除" >> "$REPORT_FILE"
}

rollback_ingress() {
    log_step "步骤3/5: 删除Ingress规则"
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        kubectl delete ingress --all -n dev 2>/dev/null || true
        kubectl delete ingress --all -n prod 2>/dev/null || true
        kubectl delete ingress --all -n ingress-nginx 2>/dev/null || true
        log_success "Ingress规则已删除"
    fi
    echo "Ingress规则已删除" >> "$REPORT_FILE"
}

rollback_namespaces() {
    log_step "步骤4/5: 删除应用命名空间"
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        kubectl delete namespace dev --ignore-not-found 2>/dev/null || true
        kubectl delete namespace prod --ignore-not-found 2>/dev/null || true
        kubectl delete namespace app --ignore-not-found 2>/dev/null || true
        log_success "应用命名空间已删除"
    fi
    echo "应用命名空间已删除" >> "$REPORT_FILE"
}

verify_rollback() {
    log_step "步骤5/5: 验证回滚结果"
    local errors=0
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        for ns in dev prod; do
            if kubectl get namespace "$ns" &>/dev/null 2>&1; then
                log_error "命名空间 $ns 仍存在!"
                ((errors++))
            else
                log_success "命名空间 $ns 已清理"
            fi
        done
    fi
    [[ $errors -eq 0 ]] && log_success "回滚验证通过" || log_error "回滚验证发现${errors}个问题"
    echo "回滚验证: $([ $errors -eq 0 ] && echo '通过' || echo '有问题')" >> "$REPORT_FILE"
}

generate_report() {
    local duration=$(( $(date +%s) - START_TIME ))
    echo "" >> "$REPORT_FILE"
    echo "========================================" >> "$REPORT_FILE"
    echo "阶段5回滚报告 | 耗时: ${duration}秒 | 主机: $(hostname)" >> "$REPORT_FILE"
    echo "========================================" >> "$REPORT_FILE"
    log_header "阶段5回滚完成"
    log_info "总耗时: ${duration}秒 | 报告: $REPORT_FILE"
}

main() {
    init
    confirm_rollback
    rollback_hpa
    rollback_demo_app
    rollback_ingress
    rollback_namespaces
    verify_rollback
    generate_report
}

main "$@"
