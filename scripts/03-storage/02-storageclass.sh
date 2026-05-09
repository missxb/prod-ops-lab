#!/usr/bin/env bash
###############################################################################
# 脚本名称: 02-storageclass.sh
# 功能描述: 创建Kubernetes StorageClass配置，设置NFS动态供给为默认存储类
# 适用系统: 需要kubectl可访问集群, NFS Provisioner已部署
# 依赖条件: kubectl可用, NFS Provisioner已部署并运行
# 作者: 运维平台团队
# 版本: 1.1.0
# 创建日期: 2026-05-09
# 更新日期: 2026-05-09
#
# 使用方法:
#   ./02-storageclass.sh                    # 使用默认配置
#
# 功能说明:
#   1. 验证NFS Provisioner已运行
#   2. 创建StorageClass (nfs-client)
#   3. 设置为默认StorageClass
#   4. 清理其他默认StorageClass
#   5. 验证StorageClass配置
###############################################################################
set -euo pipefail
umask 077

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/03-storage"
LOG_FILE="${LOG_DIR}/02-storageclass_$(date +%Y%m%d_%H%M%S).log"
LOCK_FILE="/var/lock/02-storageclass.lock"
CONFIG_DIR="${PROJECT_ROOT}/configs/nfs"

# ========================= 颜色定义 =========================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# ========================= 日志函数 =========================
log_info()    { echo -e "${GREEN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >&2; }
log_step()    { echo -e "${CYAN}[STEP]${NC}  $(date '+%Y-%m-%d %H:%M:%S') === $* ===" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }

# ========================= 错误处理 =========================
cleanup() {
    local exit_code=$?
    rm -f "$LOCK_FILE"
    if [[ $exit_code -ne 0 ]]; then
        log_error "StorageClass创建失败，退出码: $exit_code"
        log_error "请检查日志: $LOG_FILE"
    fi
    return $exit_code
}
trap cleanup EXIT
trap 'log_error "收到信号，正在退出..."; exit 1' SIGINT SIGTERM

# ========================= 工具函数 =========================

# 检查kubectl是否可用
check_kubectl() {
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl未安装"
        exit 1
    fi

    if ! kubectl cluster-info &>/dev/null; then
        log_error "无法连接到Kubernetes集群"
        exit 1
    fi
    log_success "kubectl连接正常"
}

# 检查NFS Provisioner是否运行
check_nfs_provisioner() {
    log_step "检查NFS Provisioner状态"

    local ready
    ready=$(kubectl get deployment nfs-client-provisioner -n nfs-provisioner \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

    if [[ "${ready}" -ge 1 ]] 2>/dev/null; then
        log_success "NFS Provisioner运行正常 (${ready} replicas ready)"
    else
        log_error "NFS Provisioner未运行或未就绪"
        log_error "请先运行: 01-nfs-provisioner.sh"
        exit 1
    fi
}

# ========================= 核心功能函数 =========================

# 创建StorageClass
create_storageclass() {
    log_step "创建StorageClass"

    # 检查配置文件是否存在
    if [[ ! -f "${CONFIG_DIR}/storageclass.yaml" ]]; then
        log_error "StorageClass配置文件不存在: ${CONFIG_DIR}/storageclass.yaml"
        return 1
    fi

    # 应用StorageClass配置 (幂等操作)
    if kubectl apply -f "${CONFIG_DIR}/storageclass.yaml" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "StorageClass已创建/更新"
    else
        log_error "StorageClass创建失败"
        return 1
    fi

    # 验证StorageClass是否创建成功
    if kubectl get storageclass nfs-client &>/dev/null; then
        log_success "StorageClass nfs-client 存在"
    else
        log_error "StorageClass nfs-client 不存在"
        return 1
    fi
}

# 清理旧的默认StorageClass
# 确保nfs-client是唯一的默认StorageClass
cleanup_default_storageclass() {
    log_step "清理旧的默认StorageClass"

    # 获取所有标记为默认的StorageClass
    local default_scs
    default_scs=$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

    if [[ -z "${default_scs}" ]]; then
        log_info "没有其他默认StorageClass"
        return 0
    fi

    for sc in ${default_scs}; do
        if [[ "${sc}" == "nfs-client" ]]; then
            log_info "nfs-client已是默认StorageClass，跳过"
            continue
        fi

        log_info "取消 ${sc} 的默认StorageClass标记"
        if kubectl patch storageclass "${sc}" \
            -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' 2>/dev/null; then
            log_success "已取消 ${sc} 的默认标记"
        else
            log_warn "无法取消 ${sc} 的默认标记"
        fi
    done
}

# 设置nfs-client为默认StorageClass
set_default_storageclass() {
    log_step "设置nfs-client为默认StorageClass"

    # 检查nfs-client是否已经是默认的
    local is_default
    is_default=$(kubectl get storageclass nfs-client \
        -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null || echo "")

    if [[ "${is_default}" == "true" ]]; then
        log_success "nfs-client已是默认StorageClass"
        return 0
    fi

    # 设置为默认
    if kubectl patch storageclass nfs-client \
        -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>/dev/null; then
        log_success "已将nfs-client设置为默认StorageClass"
    else
        log_error "无法设置nfs-client为默认StorageClass"
        return 1
    fi
}

# 验证StorageClass配置
verify_storageclass() {
    log_step "验证StorageClass配置"

    # 显示所有StorageClass
    log_info "当前StorageClass列表:"
    kubectl get storageclass -o custom-columns=\
'NAME:.metadata.name,PROVISIONER:.provisioner,DEFAULT:.metadata.annotations.storageclass\.kubernetes\.io/is-default-class,RECLAIM:.reclaimPolicy,PROVISIONINGMODE:.volumeBindingMode' 2>&1 | tee -a "$LOG_FILE"

    # 验证nfs-client配置
    log_info "nfs-client详细信息:"
    kubectl get storageclass nfs-client -o yaml 2>&1 | tee -a "$LOG_FILE" || true

    # 检查是否有多个默认StorageClass
    local default_count
    default_count=$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -c "." || echo "0")

    if [[ "${default_count}" -gt 1 ]]; then
        log_warn "存在多个默认StorageClass (${default_count})，可能导致调度问题"
    elif [[ "${default_count}" -eq 1 ]]; then
        log_success "只有一个默认StorageClass"
    else
        log_warn "没有默认StorageClass"
    fi
}

# ========================= 主逻辑 =========================
main() {
    mkdir -p "$LOG_DIR"

    log_step "阶段3-任务2: 创建StorageClass"

    # 前置检查
    check_kubectl
    check_nfs_provisioner

    # 创建StorageClass
    create_storageclass

    # 清理旧的默认StorageClass
    cleanup_default_storageclass

    # 设置nfs-client为默认
    set_default_storageclass

    # 验证配置
    verify_storageclass

    log_success "阶段3-任务2完成: StorageClass配置成功"
}

main "$@"
