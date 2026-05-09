#!/usr/bin/env bash
# =============================================================================
# 创建StorageClass配置
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

cleanup() {
    local exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
        log_error "StorageClass创建失败 (exit code: ${exit_code})"
    fi
}
trap cleanup EXIT

# ---------- 前置检查 ----------
log_step "前置检查"

if ! command -v kubectl &>/dev/null; then
    log_error "kubectl 未安装"; exit 1
fi
if ! kubectl cluster-info &>/dev/null; then
    log_error "无法连接到Kubernetes集群"; exit 1
fi

# ---------- 创建StorageClass ----------
log_step "创建StorageClass"

kubectl apply -f "${CONFIG_DIR}/storageclass.yaml"
log_info "StorageClass已创建"

# ---------- 移除默认的standard StorageClass ----------
log_step "清理旧的默认StorageClass"

DEFAULT_SC=$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
for sc in ${DEFAULT_SC}; do
    if [[ "${sc}" == "nfs-client" ]]; then
        log_info "nfs-client已是默认StorageClass"
        continue
    fi
    log_info "取消 ${sc} 的默认StorageClass标记"
    kubectl patch storageclass "${sc}" \
        -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' 2>/dev/null || true
done

# ---------- 验证 ----------
log_step "验证StorageClass"

kubectl get storageclass -o custom-columns=\
'NAME:.metadata.name,PROVISIONER:.provisioner,DEFAULT:.metadata.annotations.storageclass\.kubernetes\.io/is-default-class,RECLAIM:.reclaimPolicy'

log_info "StorageClass配置完成"
