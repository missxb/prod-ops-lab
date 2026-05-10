#!/usr/bin/env bash
###############################################################################
# 脚本名称: deploy-storage.sh
# 功能描述: 阶段3存储层配置主部署脚本，协调Longhorn/NFS/Ceph动态供给、StorageClass、功能验证
# 适用系统: 需要kubectl可访问集群, 对应存储后端已配置
# 依赖条件: kubectl可用, 阶段2集群已部署
# 作者: 运维平台团队
# 版本: 1.1.0
# 创建日期: 2026-05-09
# 更新日期: 2026-05-10
#
# 使用方法:
#   ./deploy-storage.sh deploy                                  # Longhorn (默认)
#   ./deploy-storage.sh -t longhorn deploy                      # Longhorn
#   ./deploy-storage.sh -t nfs -s 192.168.1.100 -p /exports    # NFS
#   ./deploy-storage.sh -t ceph deploy                          # Rook-Ceph
#   ./deploy-storage.sh -t longhorn verify                      # 验证Longhorn
#   ./deploy-storage.sh -t ceph verify                          # 验证Ceph
#   ./deploy-storage.sh -t longhorn --skip-verify
#
# 环境变量:
#   STORAGE_TYPE    - 存储类型: nfs, ceph, longhorn (默认: longhorn)
#   NFS_SERVER      - NFS服务器IP地址 (NFS模式必填)
#   NFS_PATH        - NFS导出路径 (默认: /exports)
#   SKIP_VERIFY     - 跳过验证步骤 (默认: false)
#
# 部署步骤 (Longhorn - 默认):
#   1. 部署Longhorn (Helm)
#   2. 创建Longhorn StorageClass
#   3. 验证Longhorn存储功能
#
# 部署步骤 (NFS):
#   1. 部署NFS动态供给器 (nfs-subdir-external-provisioner)
#   2. 创建StorageClass配置
#   3. 验证存储功能
#
# 部署步骤 (Ceph):
#   1. 部署Rook-Ceph Operator和CephCluster
#   2. 创建Ceph StorageClass (block + filesystem)
#   3. 验证Ceph存储功能
###############################################################################
set -euo pipefail
umask 077

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/03-storage"
LOG_FILE="${LOG_DIR}/deploy-storage_$(date +%Y%m%d_%H%M%S).log"
LOCK_FILE="/var/lock/deploy-storage.lock"
DEPLOY_START=$(date +%s)

# 配置变量（可通过环境变量覆盖）
NFS_SERVER="${NFS_SERVER:-}"
NFS_PATH="${NFS_PATH:-/exports}"
SKIP_VERIFY="${SKIP_VERIFY:-false}"
STORAGE_TYPE="${STORAGE_TYPE:-longhorn}"

# ========================= 颜色定义 =========================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

# ========================= 日志函数 =========================
log_info()    { echo -e "${GREEN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >&2; }
log_step()    { echo -e "${CYAN}[STEP]${NC}  $(date '+%Y-%m-%d %H:%M:%S') === $* ===" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }

banner() {
    echo -e "" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${BLUE}" | tee -a "$LOG_FILE"
    echo "╔══════════════════════════════════════════════════════╗" | tee -a "$LOG_FILE"
    echo "║   阶段3 - 存储层配置 (Longhorn/NFS/Ceph)            ║" | tee -a "$LOG_FILE"
    echo "╚══════════════════════════════════════════════════════╝" | tee -a "$LOG_FILE"
    echo -e "${NC}" | tee -a "$LOG_FILE"
}

# ========================= 错误处理 =========================
cleanup() {
    local exit_code=$?
    rm -f "$LOCK_FILE"
    local elapsed=$(( $(date +%s) - DEPLOY_START ))
    echo "" | tee -a "$LOG_FILE"
    if [[ ${exit_code} -eq 0 ]]; then
        echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}" | tee -a "$LOG_FILE"
        echo -e "${GREEN}║   ✓ 阶段3存储层部署成功                             ║${NC}" | tee -a "$LOG_FILE"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}" | tee -a "$LOG_FILE"
        log_info "总耗时: ${elapsed}秒"
        log_info "日志文件: ${LOG_FILE}"
    else
        echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}" | tee -a "$LOG_FILE"
        echo -e "${RED}║   ✗ 阶段3存储层部署失败 (exit code: ${exit_code})            ║${NC}" | tee -a "$LOG_FILE"
        echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}" | tee -a "$LOG_FILE"
        log_error "总耗时: ${elapsed}秒"
        log_error "请检查日志: ${LOG_FILE}"
    fi
    return $exit_code
}
trap cleanup EXIT
trap 'log_error "收到信号，正在退出..."; exit 1' SIGINT SIGTERM

# ========================= 工具函数 =========================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以root权限运行"
        exit 1
    fi
}

check_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log_error "另一个部署实例正在运行 (PID: $pid)"
            exit 1
        fi
        log_warn "发现残留锁文件，已清理"
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
}

# 显示帮助信息
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

部署阶段3存储层：Longhorn（默认）/NFS/Ceph动态供给、StorageClass、功能验证。

OPTIONS:
    -s, --server <IP>          NFS服务器地址 (NFS模式必填)
    -p, --path <path>          NFS导出路径 (默认: /exports)
    -t, --storage-type <type>  存储类型: nfs, ceph, longhorn (默认: longhorn)
    --skip-verify              跳过验证步骤
    -h, --help                 显示帮助

ENVIRONMENT VARIABLES:
    STORAGE_TYPE            存储类型: nfs, ceph, longhorn
    NFS_SERVER              NFS服务器地址 (NFS模式)
    NFS_PATH                NFS导出路径
    SKIP_VERIFY=true        跳过验证

EXAMPLES:
    # Longhorn (默认)
    $(basename "$0") deploy
    $(basename "$0") -t longhorn verify

    # NFS
    $(basename "$0") -t nfs -s 192.168.1.100 -p /exports
    NFS_SERVER=10.0.0.5 SKIP_VERIFY=true $(basename "$0") -t nfs
    # Rook-Ceph
    $(basename "$0") -t ceph deploy
    $(basename "$0") -t ceph verify
    $(basename "$0") -t ceph status
    $(basename "$0") -t ceph delete

    # Longhorn (完整操作)
    $(basename "$0") -t longhorn deploy
    $(basename "$0") -t longhorn verify
    $(basename "$0") -t longhorn status
    $(basename "$0") -t longhorn delete
EOF
}

# ========================= 预检函数 =========================
preflight_check() {
    log_step "前置检查"

    # 检查kubectl
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl未安装"
        exit 1
    fi

    if ! kubectl cluster-info &>/dev/null; then
        log_error "无法连接到Kubernetes集群"
        log_error "请确保阶段2集群部署已完成"
        exit 1
    fi
    log_success "Kubernetes集群连接正常"

    # NFS专用检查
    if [[ "${STORAGE_TYPE}" == "nfs" ]]; then
        if ping -c 1 -W 3 "${NFS_SERVER}" &>/dev/null; then
            log_success "NFS服务器 ${NFS_SERVER} 可达"
        else
            log_warn "NFS服务器 ${NFS_SERVER} Ping不可达"
        fi

        if command -v showmount &>/dev/null; then
            if showmount -e "${NFS_SERVER}" &>/dev/null; then
                log_success "NFS服务器 ${NFS_SERVER} 导出可访问"
            else
                log_warn "无法访问NFS服务器导出列表"
            fi
        fi
    fi

    log_success "前置检查通过"
}

# ========================= 主逻辑 =========================
main() {
    mkdir -p "$LOG_DIR"
    check_root
    check_lock

    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -s|--server)       NFS_SERVER="$2"; shift 2 ;;
            -p|--path)         NFS_PATH="$2"; shift 2 ;;
            -t|--storage-type) STORAGE_TYPE="$2"; shift 2 ;;
            --skip-verify)     SKIP_VERIFY=true; shift ;;
            -h|--help)         usage; exit 0 ;;
            *)                 log_error "未知参数: $1"; usage; exit 1 ;;
        esac
    done

    # 验证存储类型
    case "${STORAGE_TYPE}" in
        nfs|ceph|longhorn)
            ;;
        *)
            log_error "不支持的存储类型: ${STORAGE_TYPE}"
            log_error "支持的类型: nfs, ceph, longhorn"
            usage
            exit 1
            ;;
    esac

    # NFS模式需要验证必填参数
    if [[ "${STORAGE_TYPE}" == "nfs" ]]; then
        if [[ -z "${NFS_SERVER}" ]]; then
            log_error "NFS服务器地址未指定 (-s / NFS_SERVER)"
            usage
            exit 1
        fi
    fi

    banner
    log_info "存储类型: ${STORAGE_TYPE}"
    log_info "NFS服务器: ${NFS_SERVER:-N/A}"
    log_info "NFS路径:   ${NFS_PATH:-N/A}"
    log_info "跳过验证:  ${SKIP_VERIFY}"

    # 前置检查
    preflight_check

    case "${STORAGE_TYPE}" in
        nfs)
            # NFS部署流程 (保持原有逻辑)
            # 步骤1: 部署NFS动态供给器
            log_step "步骤1/3: 部署NFS动态供给器"
            bash "${SCRIPT_DIR}/01-nfs-provisioner.sh" \
                --server "${NFS_SERVER}" \
                --path "${NFS_PATH}" 2>&1 | tee -a "$LOG_FILE"
            log_success "步骤1完成 ✓"

            # 步骤2: 创建StorageClass
            log_step "步骤2/3: 创建StorageClass"
            bash "${SCRIPT_DIR}/02-storageclass.sh" 2>&1 | tee -a "$LOG_FILE"
            log_success "步骤2完成 ✓"

            # 步骤3: 验证 (可选)
            if [[ "${SKIP_VERIFY}" != "true" ]]; then
                log_step "步骤3/3: 存储功能验证"
                bash "${SCRIPT_DIR}/03-verify-storage.sh" 2>&1 | tee -a "$LOG_FILE"
                log_success "步骤3完成 ✓"
            else
                log_warn "步骤3已跳过 (--skip-verify)"
            fi
            ;;

        ceph)
            # Rook-Ceph部署流程
            log_step "Rook-Ceph 存储部署"
            bash "${SCRIPT_DIR}/04-deploy-rook-ceph.sh" deploy 2>&1 | tee -a "$LOG_FILE"
            log_success "Rook-Ceph部署完成 ✓"

            if [[ "${SKIP_VERIFY}" != "true" ]]; then
                log_step "Rook-Ceph 存储验证"
                bash "${SCRIPT_DIR}/05-verify-ceph.sh" 2>&1 | tee -a "$LOG_FILE"
                log_success "Rook-Ceph验证完成 ✓"
            else
                log_warn "Ceph验证已跳过 (--skip-verify)"
            fi
            ;;

        longhorn)
            # Longhorn部署流程
            log_step "Longhorn 分布式存储部署"
            bash "${SCRIPT_DIR}/06-deploy-longhorn.sh" deploy 2>&1 | tee -a "$LOG_FILE"
            log_success "Longhorn部署完成 ✓"

            if [[ "${SKIP_VERIFY}" != "true" ]]; then
                log_step "Longhorn 存储验证"
                bash "${SCRIPT_DIR}/07-verify-longhorn.sh" 2>&1 | tee -a "$LOG_FILE"
                log_success "Longhorn验证完成 ✓"
            else
                log_warn "Longhorn验证已跳过 (--skip-verify)"
            fi
            ;;
    esac

    log_success "阶段3存储层部署完成 (${STORAGE_TYPE})"
}

main "$@"
