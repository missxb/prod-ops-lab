#!/usr/bin/env bash
###############################################################################
# 脚本名称: 01-nfs-provisioner.sh
# 功能描述: 部署NFS动态供给器 (nfs-subdir-external-provisioner) 到Kubernetes集群
# 适用系统: 需要kubectl可访问集群, NFS服务器已配置
# 依赖条件: kubectl可用, NFS服务器已配置并导出
# 作者: 运维平台团队
# 版本: 1.1.0
# 创建日期: 2026-05-09
# 更新日期: 2026-05-09
#
# 使用方法:
#   ./01-nfs-provisioner.sh -s 192.168.1.100 -p /exports
#   NFS_SERVER=10.0.0.5 NFS_PATH=/exports ./01-nfs-provisioner.sh
#   ./01-nfs-provisioner.sh -s 10.0.0.5 -p /exports -n custom-namespace
#
# 环境变量:
#   NFS_SERVER      - NFS服务器IP地址 (必填)
#   NFS_PATH        - NFS导出路径 (默认: /exports)
#   NFS_NAMESPACE   - 部署命名空间 (默认: nfs-provisioner)
#
# 功能说明:
#   1. 验证NFS服务器连通性
#   2. 渲染NFS Provisioner配置模板
#   3. 创建RBAC和ServiceAccount
#   4. 部署NFS Client Provisioner Deployment
#   5. 等待Pod就绪并验证
###############################################################################
set -euo pipefail
umask 077

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/03-storage"
LOG_FILE="${LOG_DIR}/01-nfs-provisioner_$(date +%Y%m%d_%H%M%S).log"
LOCK_FILE="/var/lock/01-nfs-provisioner.lock"
CONFIG_DIR="${PROJECT_ROOT}/configs/nfs"

# 配置变量（可通过环境变量覆盖）
NFS_SERVER="${NFS_SERVER:-}"
NFS_PATH="${NFS_PATH:-/exports}"
NFS_NAMESPACE="${NFS_NAMESPACE:-nfs-provisioner}"

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
RENDERED_DIR=""
cleanup() {
    local exit_code=$?
    rm -f "$LOCK_FILE"
    # 清理临时渲染目录
    if [[ -n "$RENDERED_DIR" && -d "$RENDERED_DIR" ]]; then
        rm -rf "$RENDERED_DIR"
    fi
    if [[ $exit_code -ne 0 ]]; then
        log_error "NFS Provisioner部署失败，退出码: $exit_code"
        log_error "请检查日志: $LOG_FILE"
        log_error "排查步骤:"
        log_error "  1. 检查NFS服务器连通性: showmount -e ${NFS_SERVER}"
        log_error "  2. 检查kubectl连接: kubectl cluster-info"
        log_error "  3. 检查Pod状态: kubectl get pods -n ${NFS_NAMESPACE}"
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

# 检查NFS服务器连通性
check_nfs_server() {
    log_step "检查NFS服务器连通性"

    # Ping测试
    if ping -c 1 -W 3 "${NFS_SERVER}" &>/dev/null; then
        log_success "NFS服务器 ${NFS_SERVER} Ping可达"
    else
        log_warn "NFS服务器 ${NFS_SERVER} Ping不可达 (可能禁用了ICMP)"
    fi

    # showmount测试
    if command -v showmount &>/dev/null; then
        if showmount -e "${NFS_SERVER}" &>/dev/null; then
            log_success "NFS服务器 ${NFS_SERVER} showmount可访问"
            log_info "NFS导出列表:"
            showmount -e "${NFS_SERVER}" 2>/dev/null | tee -a "$LOG_FILE"
        else
            log_warn "无法通过showmount访问NFS服务器"
        fi
    fi
}

# 显示帮助信息
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

部署NFS动态供给器到Kubernetes集群。

OPTIONS:
    -s, --server <IP>     NFS服务器地址 (必填)
    -p, --path <path>     NFS导出路径 (默认: /exports)
    -n, --namespace <ns>  部署命名空间 (默认: nfs-provisioner)
    -h, --help            显示帮助信息

ENVIRONMENT VARIABLES:
    NFS_SERVER            NFS服务器地址
    NFS_PATH              NFS导出路径
    NFS_NAMESPACE         部署命名空间

EXAMPLES:
    $(basename "$0") -s 192.168.1.100 -p /exports
    NFS_SERVER=10.0.0.5 $(basename "$0")
    $(basename "$0") -s 10.0.0.5 -p /exports/shared -n custom-ns
EOF
}

# ========================= 核心功能函数 =========================

# 部署NFS Client Provisioner
deploy_nfs_provisioner() {
    log_step "部署NFS Client Provisioner"

    # 检查配置文件是否存在
    if [[ ! -f "${CONFIG_DIR}/nfs-provisioner.yaml" ]]; then
        log_error "NFS Provisioner配置文件不存在: ${CONFIG_DIR}/nfs-provisioner.yaml"
        return 1
    fi

    # 创建临时渲染目录
    RENDERED_DIR=$(mktemp -d)
    log_info "临时渲染目录: ${RENDERED_DIR}"

    # 渲染配置文件 (替换占位符)
    cp "${CONFIG_DIR}/nfs-provisioner.yaml" "${RENDERED_DIR}/nfs-provisioner.yaml"
    sed -i "s|NFS_SERVER_PLACEHOLDER|${NFS_SERVER}|g" "${RENDERED_DIR}/nfs-provisioner.yaml"
    sed -i "s|NFS_PATH_PLACEHOLDER|${NFS_PATH}|g" "${RENDERED_DIR}/nfs-provisioner.yaml"

    log_info "NFS服务器: ${NFS_SERVER}"
    log_info "NFS路径: ${NFS_PATH}"
    log_info "命名空间: ${NFS_NAMESPACE}"

    # 应用配置 (幂等操作)
    if kubectl apply -f "${RENDERED_DIR}/nfs-provisioner.yaml" --namespace "${NFS_NAMESPACE}" 2>/dev/null; then
        log_success "NFS Provisioner资源已应用到命名空间 ${NFS_NAMESPACE}"
    elif kubectl apply -f "${RENDERED_DIR}/nfs-provisioner.yaml"; then
        log_success "NFS Provisioner资源已应用 (使用默认命名空间)"
    else
        log_error "NFS Provisioner资源应用失败"
        return 1
    fi
}

# 等待NFS Provisioner Pod就绪
wait_for_provisioner() {
    log_step "等待NFS Provisioner Pod就绪"

    # 使用kubectl rollout status等待Deployment就绪
    log_info "等待Deployment rollout完成 (最多120秒)..."
    if kubectl rollout status deployment/nfs-client-provisioner \
        --namespace="${NFS_NAMESPACE}" \
        --timeout=120s 2>/dev/null; then
        log_success "NFS Client Provisioner Deployment已就绪"
    else
        log_warn "Pod未在120秒内就绪，检查Pod状态..."
        kubectl get pods -n "${NFS_NAMESPACE}" -l app.kubernetes.io/name=nfs-client-provisioner -o wide 2>&1 | tee -a "$LOG_FILE" || true
        kubectl describe deployment nfs-client-provisioner -n "${NFS_NAMESPACE}" 2>&1 | tee -a "$LOG_FILE" || true
        return 1
    fi

    # 获取并显示就绪的Pod信息
    local pod_name
    pod_name=$(kubectl get pods -n "${NFS_NAMESPACE}" \
        -l app.kubernetes.io/name=nfs-client-provisioner \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "unknown")
    log_info "NFS Provisioner Pod已就绪: ${pod_name}"

    # 验证Pod状态
    local pod_status
    pod_status=$(kubectl get pod "${pod_name}" -n "${NFS_NAMESPACE}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
    if [[ "$pod_status" == "Running" ]]; then
        log_success "Pod状态: Running"
    else
        log_warn "Pod状态: ${pod_status}"
    fi
}

# ========================= 主逻辑 =========================
main() {
    mkdir -p "$LOG_DIR"

    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -s|--server)   NFS_SERVER="$2"; shift 2 ;;
            -p|--path)     NFS_PATH="$2"; shift 2 ;;
            -n|--namespace) NFS_NAMESPACE="$2"; shift 2 ;;
            -h|--help)     usage; exit 0 ;;
            *)             log_error "未知参数: $1"; usage; exit 1 ;;
        esac
    done

    # 验证必填参数
    if [[ -z "${NFS_SERVER}" ]]; then
        log_error "NFS服务器地址未指定"
        usage
        exit 1
    fi

    log_step "阶段3-任务1: 部署NFS动态供给器"

    # 前置检查
    check_kubectl
    check_nfs_server

    # 部署NFS Provisioner
    deploy_nfs_provisioner

    # 等待就绪
    wait_for_provisioner

    log_success "阶段3-任务1完成: NFS动态供给器部署成功"
    log_info "NFS服务器: ${NFS_SERVER}"
    log_info "NFS路径: ${NFS_PATH}"
    log_info "命名空间: ${NFS_NAMESPACE}"
}

main "$@"
