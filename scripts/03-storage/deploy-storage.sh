#!/usr/bin/env bash
# =============================================================================
# 阶段3 - 存储层配置 主部署脚本
# NFS动态供给 + StorageClass配置 + 功能验证
# =============================================================================
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ---------- 彩色日志 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
log_step()  { echo -e "${CYAN}[STEP]${NC}  $(date '+%Y-%m-%d %H:%M:%S') === $* ==="; }
banner() {
    echo -e "${BOLD}${BLUE}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║   阶段3 - 存储层配置 (NFS Dynamic Provisioning)    ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ---------- 全局错误处理 ----------
DEPLOY_START=$(date +%s)
cleanup() {
    local exit_code=$?
    local elapsed=$(( $(date +%s) - DEPLOY_START ))
    echo ""
    if [[ ${exit_code} -eq 0 ]]; then
        echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║   ✓ 阶段3存储层部署成功                             ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    else
        echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║   ✗ 阶段3存储层部署失败 (exit code: ${exit_code})            ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"
    fi
    log_info "总耗时: ${elapsed}秒"
}
trap cleanup EXIT

# ---------- 参数 ----------
NFS_SERVER="${NFS_SERVER:-}"
NFS_PATH="${NFS_PATH:-/exports}"
SKIP_VERIFY="${SKIP_VERIFY:-false}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

部署阶段3存储层：NFS动态供给、StorageClass、功能验证。

OPTIONS:
    -s, --server <IP>     NFS服务器地址 (必填)
    -p, --path <path>     NFS导出路径 (默认: /exports)
    --skip-verify         跳过验证步骤
    -h, --help            显示帮助

ENVIRONMENT VARIABLES:
    NFS_SERVER            NFS服务器地址
    NFS_PATH              NFS导出路径
    SKIP_VERIFY=true      跳过验证

EXAMPLES:
    $(basename "$0") -s 192.168.1.100 -p /exports
    NFS_SERVER=10.0.0.5 SKIP_VERIFY=true $(basename "$0")
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--server)      NFS_SERVER="$2"; shift 2 ;;
        -p|--path)        NFS_PATH="$2"; shift 2 ;;
        --skip-verify)    SKIP_VERIFY=true; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                log_error "未知参数: $1"; usage; exit 1 ;;
    esac
done

if [[ -z "${NFS_SERVER}" ]]; then
    log_error "NFS服务器地址未指定 (-s / NFS_SERVER)"
    usage
    exit 1
fi

banner
log_info "NFS服务器: ${NFS_SERVER}"
log_info "NFS路径:   ${NFS_PATH}"
log_info "跳过验证:  ${SKIP_VERIFY}"

# ========== 步骤1: 部署NFS Provisioner ==========
log_step "步骤1/3: 部署NFS动态供给器"
bash "${SCRIPT_DIR}/01-nfs-provisioner.sh" \
    --server "${NFS_SERVER}" \
    --path "${NFS_PATH}"
log_info "步骤1完成 ✓"

# ========== 步骤2: 创建StorageClass ==========
log_step "步骤2/3: 创建StorageClass"
bash "${SCRIPT_DIR}/02-storageclass.sh"
log_info "步骤2完成 ✓"

# ========== 步骤3: 验证 ==========
if [[ "${SKIP_VERIFY}" != "true" ]]; then
    log_step "步骤3/3: 存储功能验证"
    bash "${SCRIPT_DIR}/03-verify-storage.sh"
    log_info "步骤3完成 ✓"
else
    log_warn "步骤3已跳过 (--skip-verify)"
fi

log_info "阶段3存储层部署完成"
