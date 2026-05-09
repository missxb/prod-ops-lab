#!/usr/bin/env bash
###############################################################################
# teardown-phase7.sh - 阶段7回滚: 日志系统回滚
# Enterprise Cloud Native Platform
# 功能: 回滚ELK Stack (Elasticsearch + Fluentd + Kibana)
###############################################################################
set -euo pipefail

# 加载共享库
source "$SCRIPT_DIR/../../scripts/lib/common.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/teardown"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/teardown-phase7_${TIMESTAMP}.log"
REPORT_FILE="${LOG_DIR}/rollback-report-phase7_${TIMESTAMP}.txt"
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
    log_header "企业级云原生运维平台 - 阶段7回滚"
    log_info "回滚时间: $(date '+%Y-%m-%d %H:%M:%S')"
}

confirm_rollback() {
    echo ""
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║  ⚠️  警告: 即将回滚阶段7 - 日志系统                      ║${NC}"
    echo -e "${RED}${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}${BOLD}║  回滚内容:                                                ║${NC}"
    echo -e "${RED}${BOLD}║    - 删除Kibana                                          ║${NC}"
    echo -e "${RED}${BOLD}║    - 删除Fluentd DaemonSet                               ║${NC}"
    echo -e "${RED}${BOLD}║    - 删除Elasticsearch                                   ║${NC}"
    echo -e "${RED}${BOLD}║    - 删除日志命名空间                                     ║${NC}"
    echo -e "${RED}${BOLD}║    - 清理PVC和配置                                        ║${NC}"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -ne "${YELLOW}是否确认回滚? 输入 YES 继续: ${NC}"
    read -r confirm
    [[ "$confirm" == "YES" ]] || { echo "已取消"; exit 0; }
}

rollback_kibana() {
    log_step "步骤1/6: 删除Kibana"
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        kubectl delete deployment kibana -n logging 2>/dev/null || true
        kubectl delete service kibana -n logging 2>/dev/null || true
        kubectl delete configmap kibana-config -n logging 2>/dev/null || true
        kubectl delete ingress kibana -n logging 2>/dev/null || true
        log_success "Kibana已删除"
    else
        log_warn "K8s集群不可达，跳过"
    fi
    echo "Kibana已删除" >> "$REPORT_FILE"
}

rollback_fluentd() {
    log_step "步骤2/6: 删除Fluentd DaemonSet"
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        kubectl delete daemonset fluentd -n logging 2>/dev/null || true
        kubectl delete configmap fluentd-config -n logging 2>/dev/null || true
        kubectl delete serviceaccount fluentd -n logging 2>/dev/null || true
        kubectl delete clusterrole fluentd 2>/dev/null || true
        kubectl delete clusterrolebinding fluentd 2>/dev/null || true
        log_success "Fluentd已删除"
    fi
    echo "Fluentd已删除" >> "$REPORT_FILE"
}

rollback_elasticsearch() {
    log_step "步骤3/6: 删除Elasticsearch"
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        kubectl delete statefulset elasticsearch -n logging 2>/dev/null || true
        kubectl delete service elasticsearch -n logging 2>/dev/null || true
        kubectl delete configmap elasticsearch-config -n logging 2>/dev/null || true
        kubectl delete pvc --all -n logging 2>/dev/null || true
        log_success "Elasticsearch已删除"
    fi
    echo "Elasticsearch已删除" >> "$REPORT_FILE"
}

rollback_resources() {
    log_step "步骤4/6: 清理ELK资源文件"
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        kubectl delete -f "${PROJECT_ROOT}/manifests/logging/" 2>/dev/null || true
        log_success "ELK资源文件已清理"
    fi
    echo "ELK资源文件已清理" >> "$REPORT_FILE"
}

rollback_namespace() {
    log_step "步骤5/6: 删除日志命名空间"
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        kubectl delete namespace logging --ignore-not-found 2>/dev/null || true
        kubectl delete namespace elk --ignore-not-found 2>/dev/null || true
        log_success "日志命名空间已删除"
    fi
    echo "日志命名空间已删除" >> "$REPORT_FILE"
}

verify_rollback() {
    log_step "步骤6/6: 验证回滚结果"
    local errors=0
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        for ns in logging elk; do
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
    echo "阶段7回滚报告 | 耗时: ${duration}秒 | 主机: $(hostname)" >> "$REPORT_FILE"
    echo "========================================" >> "$REPORT_FILE"
    log_header "阶段7回滚完成"
    log_info "总耗时: ${duration}秒 | 报告: $REPORT_FILE"
}

main() {
    init
    confirm_rollback
    rollback_kibana
    rollback_fluentd
    rollback_elasticsearch
    rollback_resources
    rollback_namespace
    verify_rollback
    generate_report
}

main "$@"
