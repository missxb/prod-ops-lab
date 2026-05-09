#!/usr/bin/env bash
# =============================================================================
# 部署NFS动态供给 (nfs-subdir-external-provisioner)
# 阶段3 - 存储层配置
# =============================================================================
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_DIR="${PROJECT_ROOT}/configs/nfs"

# ---------- 彩色日志 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
log_step()  { echo -e "${CYAN}[STEP]${NC}  $(date '+%Y-%m-%d %H:%M:%S') === $* ==="; }

# ---------- 错误处理 ----------
cleanup() {
    local exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
        log_error "部署失败 (exit code: ${exit_code})"
        log_error "请检查上方日志获取详细错误信息"
    fi
}
trap cleanup EXIT

# ---------- 参数 ----------
NFS_SERVER="${NFS_SERVER:-}"
NFS_PATH="${NFS_PATH:-/exports}"
NFS_NAMESPACE="${NFS_NAMESPACE:-nfs-provisioner}"

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
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--server)   NFS_SERVER="$2"; shift 2 ;;
        -p|--path)     NFS_PATH="$2"; shift 2 ;;
        -n|--namespace) NFS_NAMESPACE="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *)             log_error "未知参数: $1"; usage; exit 1 ;;
    esac
done

if [[ -z "${NFS_SERVER}" ]]; then
    log_error "NFS服务器地址未指定"
    usage
    exit 1
fi

# ---------- 前置检查 ----------
log_step "前置检查"

if ! command -v kubectl &>/dev/null; then
    log_error "kubectl 未安装"
    exit 1
fi
log_info "kubectl: $(kubectl version --client --short 2>/dev/null || echo 'OK')"

if ! kubectl cluster-info &>/dev/null; then
    log_error "无法连接到Kubernetes集群"
    exit 1
fi
log_info "Kubernetes集群连接正常"

# ---------- 部署NFS Provisioner ----------
log_step "部署NFS Client Provisioner"

# 创建临时渲染后的文件
RENDERED_DIR=$(mktemp -d)
trap 'rm -rf "${RENDERED_DIR}"' EXIT

cp "${CONFIG_DIR}/nfs-provisioner.yaml" "${RENDERED_DIR}/nfs-provisioner.yaml"
sed -i "s|NFS_SERVER_PLACEHOLDER|${NFS_SERVER}|g" "${RENDERED_DIR}/nfs-provisioner.yaml"
sed -i "s|NFS_PATH_PLACEHOLDER|${NFS_PATH}|g" "${RENDERED_DIR}/nfs-provisioner.yaml"

# 应用RBAC和服务账户（幂等）
kubectl apply -f "${RENDERED_DIR}/nfs-provisioner.yaml" --namespace "${NFS_NAMESPACE}" 2>/dev/null || \
kubectl apply -f "${RENDERED_DIR}/nfs-provisioner.yaml"

log_info "NFS Provisioner资源已应用"

# ---------- 等待就绪 ----------
log_step "等待NFS Provisioner Pod就绪"

kubectl rollout status deployment/nfs-client-provisioner \
    --namespace="${NFS_NAMESPACE}" \
    --timeout=120s 2>/dev/null || {
    log_warn "Pod未在120秒内就绪，检查Pod状态..."
    kubectl get pods -n "${NFS_NAMESPACE}" -l app.kubernetes.io/name=nfs-client-provisioner -o wide
    kubectl describe deployment nfs-client-provisioner -n "${NFS_NAMESPACE}"
    exit 1
}

POD=$(kubectl get pods -n "${NFS_NAMESPACE}" \
    -l app.kubernetes.io/name=nfs-client-provisioner \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
log_info "NFS Provisioner Pod已就绪: ${POD}"

log_info "NFS动态供给部署完成"
