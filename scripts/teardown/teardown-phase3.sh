#!/usr/bin/env bash
###############################################################################
# teardown-phase3.sh - 阶段3回滚: 存储层回滚
# Enterprise Cloud Native Platform
# 功能: 回滚NFS动态供给、StorageClass配置
###############################################################################
set -euo pipefail

# 加载共享库
source "$SCRIPT_DIR/../../scripts/lib/common.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/teardown"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/teardown-phase3_${TIMESTAMP}.log"
REPORT_FILE="${LOG_DIR}/rollback-report-phase3_${TIMESTAMP}.txt"
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
    log_header "企业级云原生运维平台 - 阶段3回滚"
    log_info "回滚时间: $(date '+%Y-%m-%d %H:%M:%S')"
}

confirm_rollback() {
    echo ""
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║  ⚠️  警告: 即将回滚阶段3 - 存储层配置                    ║${NC}"
    echo -e "${RED}${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}${BOLD}║  回滚内容:                                                ║${NC}"
    echo -e "${RED}${BOLD}║    - 删除StorageClass                                    ║${NC}"
    echo -e "${RED}${BOLD}║    - 删除NFS Provisioner                                 ║${NC}"
    echo -e "${RED}${BOLD}║    - 删除测试PVC                                         ║${NC}"
    echo -e "${RED}${BOLD}║    - 清理存储相关配置                                     ║${NC}"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -ne "${YELLOW}是否确认回滚? 输入 YES 继续: ${NC}"
    read -r confirm
    [[ "$confirm" == "YES" ]] || { echo "已取消"; exit 0; }
}

rollback_storageclass() {
    log_step "步骤1/4: 删除StorageClass"
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        kubectl delete storageclass nfs-client 2>/dev/null || log_warn "nfs-client StorageClass不存在"
        kubectl delete storageclass managed-nfs 2>/dev/null || log_warn "managed-nfs StorageClass不存在"
        kubectl delete pvc --all -n default 2>/dev/null || true
        log_success "StorageClass已删除"
    else
        log_warn "K8s集群不可达，跳过"
    fi
    echo "StorageClass已删除" >> "$REPORT_FILE"
}

rollback_nfs_provisioner() {
    log_step "步骤2/4: 删除NFS Provisioner"
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        kubectl delete deployment -n kube-system nfs-client-provisioner 2>/dev/null || true
        kubectl delete clusterrolebinding nfs-client-provisioner 2>/dev/null || true
        kubectl delete clusterrole nfs-client-provisioner 2>/dev/null || true
        kubectl delete serviceaccount nfs-client-provisioner -n kube-system 2>/dev/null || true
        kubectl delete -f /root/enterprise-cloud-native-platform/manifests/storage/ 2>/dev/null || true
        log_success "NFS Provisioner已删除"
    else
        log_warn "K8s集群不可达，跳过"
    fi
    echo "NFS Provisioner已删除" >> "$REPORT_FILE"
}

rollback_test_pvcs() {
    log_step "步骤3/4: 清理测试PVC"
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        kubectl delete pvc test-pvc -n default 2>/dev/null || true
        kubectl delete pvc nfs-test-pvc -n default 2>/dev/null || true
        log_success "测试PVC已清理"
    fi
    echo "测试PVC已清理" >> "$REPORT_FILE"
}

verify_rollback() {
    log_step "步骤4/4: 验证回滚结果"
    local errors=0
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        if kubectl get storageclass nfs-client &>/dev/null 2>&1; then
            log_error "nfs-client StorageClass仍存在!"
            ((errors++))
        else
            log_success "StorageClass已清理"
        fi
    fi
    [[ $errors -eq 0 ]] && log_success "回滚验证通过" || log_error "回滚验证发现${errors}个问题"
    echo "回滚验证: $([ $errors -eq 0 ] && echo '通过' || echo '有问题')" >> "$REPORT_FILE"
}

generate_report() {
    local duration=$(( $(date +%s) - START_TIME ))
    echo "" >> "$REPORT_FILE"
    echo "========================================" >> "$REPORT_FILE"
    echo "阶段3回滚报告 | 耗时: ${duration}秒 | 主机: $(hostname)" >> "$REPORT_FILE"
    echo "========================================" >> "$REPORT_FILE"
    log_header "阶段3回滚完成"
    log_info "总耗时: ${duration}秒 | 报告: $REPORT_FILE"
}

main() {
    init
    confirm_rollback
    rollback_storageclass
    rollback_nfs_provisioner
    rollback_test_pvcs
    verify_rollback
    generate_report
}

main "$@"
