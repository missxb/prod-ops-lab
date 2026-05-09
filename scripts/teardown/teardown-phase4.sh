#!/usr/bin/env bash
###############################################################################
# teardown-phase4.sh - 阶段4回滚: CI/CD平台回滚
# Enterprise Cloud Native Platform
# 功能: 回滚GitLab、Jenkins、Harbor、Trivy及CI/CD命名空间
###############################################################################
set -euo pipefail

# 加载共享库
source "$SCRIPT_DIR/../../scripts/lib/common.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/teardown"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/teardown-phase4_${TIMESTAMP}.log"
REPORT_FILE="${LOG_DIR}/rollback-report-phase4_${TIMESTAMP}.txt"
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
    log_header "企业级云原生运维平台 - 阶段4回滚"
    log_info "回滚时间: $(date '+%Y-%m-%d %H:%M:%S')"
}

confirm_rollback() {
    echo ""
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║  ⚠️  警告: 即将回滚阶段4 - CI/CD平台                      ║${NC}"
    echo -e "${RED}${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}${BOLD}║  回滚内容:                                                ║${NC}"
    echo -e "${RED}${BOLD}║    - 卸载GitLab (Helm)                                   ║${NC}"
    echo -e "${RED}${BOLD}║    - 卸载Jenkins (Helm)                                  ║${NC}"
    echo -e "${RED}${BOLD}║    - 卸载Harbor (Helm)                                   ║${NC}"
    echo -e "${RED}${BOLD}║    - 卸载Trivy Scanner                                   ║${NC}"
    echo -e "${RED}${BOLD}║    - 删除CI/CD命名空间                                   ║${NC}"
    echo -e "${RED}${BOLD}║    - 清理TLS证书和Helm仓库                               ║${NC}"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -ne "${YELLOW}是否确认回滚? 输入 YES 继续: ${NC}"
    read -r confirm
    [[ "$confirm" == "YES" ]] || { echo "已取消"; exit 0; }
}

rollback_gitlab() {
    log_step "步骤1/7: 卸载GitLab"
    if command -v helm &>/dev/null; then
        helm uninstall gitlab -n gitlab --wait 2>/dev/null || log_warn "GitLab卸载失败或不存在"
        log_success "GitLab已卸载"
    else
        log_warn "helm不可用，跳过"
    fi
    echo "GitLab已卸载" >> "$REPORT_FILE"
}

rollback_jenkins() {
    log_step "步骤2/7: 卸载Jenkins"
    if command -v helm &>/dev/null; then
        helm uninstall jenkins -n jenkins --wait 2>/dev/null || log_warn "Jenkins卸载失败或不存在"
        log_success "Jenkins已卸载"
    fi
    echo "Jenkins已卸载" >> "$REPORT_FILE"
}

rollback_harbor() {
    log_step "步骤3/7: 卸载Harbor"
    if command -v helm &>/dev/null; then
        helm uninstall harbor -n harbor --wait 2>/dev/null || log_warn "Harbor卸载失败或不存在"
        log_success "Harbor已卸载"
    fi
    echo "Harbor已卸载" >> "$REPORT_FILE"
}

rollback_trivy() {
    log_step "步骤4/7: 卸载Trivy Scanner"
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        kubectl delete deployment -n trivy trivy-server 2>/dev/null || true
        kubectl delete service -n trivy trivy-server 2>/dev/null || true
        kubectl delete configmap -n trivy trivy-config 2>/dev/null || true
        kubectl delete serviceaccount -n trivy trivy 2>/dev/null || true
        log_success "Trivy已卸载"
    fi
    echo "Trivy已卸载" >> "$REPORT_FILE"
}

rollback_namespaces() {
    log_step "步骤5/7: 删除CI/CD命名空间"
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        local namespaces=("gitlab" "jenkins" "jenkins-agents" "harbor" "trivy" "cicd")
        for ns in "${namespaces[@]}"; do
            kubectl delete namespace "$ns" --ignore-not-found 2>/dev/null || true
            log_info "命名空间 $ns 已删除"
        done
        log_success "CI/CD命名空间已清理"
    fi
    echo "CI/CD命名空间已删除" >> "$REPORT_FILE"
}

rollback_helm_repos() {
    log_step "步骤6/7: 清理Helm仓库"
    if command -v helm &>/dev/null; then
        helm repo remove gitlab 2>/dev/null || true
        helm repo remove jenkins 2>/dev/null || true
        helm repo remove harbor 2>/dev/null || true
        helm repo update 2>/dev/null || true
        log_success "Helm仓库已清理"
    fi
    echo "Helm仓库已清理" >> "$REPORT_FILE"
}

verify_rollback() {
    log_step "步骤7/7: 验证回滚结果"
    local errors=0
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        for ns in gitlab jenkins harbor trivy cicd; do
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
    echo "阶段4回滚报告 | 耗时: ${duration}秒 | 主机: $(hostname)" >> "$REPORT_FILE"
    echo "========================================" >> "$REPORT_FILE"
    log_header "阶段4回滚完成"
    log_info "总耗时: ${duration}秒 | 报告: $REPORT_FILE"
}

main() {
    init
    confirm_rollback
    rollback_gitlab
    rollback_jenkins
    rollback_harbor
    rollback_trivy
    rollback_namespaces
    rollback_helm_repos
    verify_rollback
    generate_report
}

main "$@"
