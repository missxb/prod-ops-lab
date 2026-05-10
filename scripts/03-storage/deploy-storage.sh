#!/usr/bin/env bash
###############################################################################
# 脚本名称: deploy-storage.sh
# 功能描述: 阶段3存储层配置主部署脚本，协调Longhorn/NFS/Ceph动态供给、StorageClass、功能验证
# 适用系统: 需要kubectl可访问集群, 对应存储后端已配置
# 依赖条件: kubectl可用, 阶段2集群已部署
# 作者: 运维平台团队
# 版本: 1.2.0
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
#   ./deploy-storage.sh --list                                  # 列出所有存储类型
#   ./deploy-storage.sh --info                                  # 显示当前配置
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
ACTION="${ACTION:-}"
LIST_ONLY=false
INFO_ONLY=false
SKIP_CLEANUP_SUMMARY=false

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
    local storage_type="${1:-$STORAGE_TYPE}"
    local type_desc=""
    case "${storage_type}" in
        longhorn) type_desc="Longhorn 分布式块存储 (推荐)" ;;
        nfs)      type_desc="NFS 网络文件系统" ;;
        ceph)     type_desc="Rook-Ceph 分布式存储" ;;
        *)        type_desc="未知类型" ;;
    esac
    echo "" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${BLUE}" | tee -a "$LOG_FILE"
    echo "╔══════════════════════════════════════════════════════╗" | tee -a "$LOG_FILE"
    echo "║   阶段3 - 存储层配置                                ║" | tee -a "$LOG_FILE"
    echo "║   存储类型: ${type_desc}" | tee -a "$LOG_FILE"
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
        if [[ "${SKIP_CLEANUP_SUMMARY}" != true ]]; then
            echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}" | tee -a "$LOG_FILE"
            echo -e "${GREEN}║   ✓ 阶段3存储层部署成功                             ║${NC}" | tee -a "$LOG_FILE"
            echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}" | tee -a "$LOG_FILE"
            show_deploy_summary
            log_info "总耗时: ${elapsed}秒"
            log_info "日志文件: ${LOG_FILE}"
        fi
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
        log_error "此脚本必须以root权限运行 (请使用 sudo 或以 root 身份执行)"
        exit 1
    fi
}

check_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log_error "另一个部署实例正在运行 (PID: $pid)"
            log_error "如确认无其他进程运行，可手动删除锁文件: rm -f $LOCK_FILE"
            exit 1
        fi
        log_warn "发现残留锁文件，已清理"
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
}

# 显示所有可用的存储类型
list_storage_types() {
    echo ""
    echo -e "${BOLD}${CYAN}可用存储类型${NC}"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    echo -e "  ${GREEN}longhorn${NC}  (默认)"
    echo "    轻量级分布式块存储，适合中小规模生产环境"
    echo "    特点: 副本复制、快照备份、在线扩容、Dashboard管理"
    echo "    要求: ≥2节点, 所有节点需安装 open-iscsi"
    echo "    脚本: 06-deploy-longhorn.sh / 07-verify-longhorn.sh"
    echo ""
    echo -e "  ${YELLOW}nfs${NC}"
    echo "    NFS网络文件系统，最简单的共享存储方案"
    echo "    特点: 配置简单、多节点共享访问 (RWX)"
    echo "    要求: 外部NFS服务器, 所有节点需安装 nfs-common"
    echo "    脚本: 01-nfs-provisioner.sh / 02-storageclass.sh / 03-verify-storage.sh"
    echo ""
    echo -e "  ${YELLOW}ceph${NC}"
    echo "    Rook-Ceph 分布式存储，企业级高性能方案"
    echo "    特点: 块/对象/文件存储、高可用、高扩展性"
    echo "    要求: ≥3节点, 每节点≥2GB空闲内存"
    echo "    脚本: 04-deploy-rook-ceph.sh / 05-verify-ceph.sh"
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo -e "用法: $(basename "$0") -t <类型> deploy"
    echo ""
}

# 显示当前存储配置信息
show_info() {
    echo ""
    echo -e "${BOLD}${CYAN}当前存储配置${NC}"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    echo "  存储类型:      ${STORAGE_TYPE}"
    echo "  NFS服务器:     ${NFS_SERVER:-N/A}"
    echo "  NFS导出路径:   ${NFS_PATH}"
    echo "  跳过验证:      ${SKIP_VERIFY}"
    echo "  项目根目录:    ${PROJECT_ROOT}"
    echo "  日志目录:      ${LOG_DIR}"
    echo ""

    # 检查kubectl是否可用
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        echo -e "  ${GREEN}Kubernetes集群${NC}: 已连接"
        echo "  节点数量:      $(kubectl get nodes --no-headers 2>/dev/null | wc -l)"
        echo ""
        echo "  已部署的StorageClass:"
        kubectl get storageclass 2>/dev/null | sed 's/^/    /' || echo "    (无法获取)"

        # 检查Longhorn
        if kubectl get ns longhorn-system &>/dev/null 2>&1; then
            echo ""
            echo -e "  ${GREEN}Longhorn${NC}: 已安装"
            local sc_list
            sc_list=$(kubectl get storageclass 2>/dev/null | grep longhorn | awk '{print $1}' | tr '\n' ', ' || echo "无")
            echo "    StorageClass: ${sc_list%, }"
        else
            echo ""
            echo -e "  ${YELLOW}Longhorn${NC}: 未安装"
        fi

        # 检查Ceph
        if kubectl get ns rook-ceph &>/dev/null 2>&1; then
            echo -e "  ${GREEN}Ceph${NC}: 已安装"
        else
            echo -e "  ${YELLOW}Ceph${NC}: 未安装"
        fi
    else
        echo -e "  ${RED}Kubernetes集群${NC}: 未连接 (请先运行阶段2部署)"
    fi
    echo ""
    echo "════════════════════════════════════════════════════════════════"
}

# 部署完成后显示摘要
show_deploy_summary() {
    echo ""
    log_step "部署摘要"
    echo -e "  存储类型:    ${BOLD}${STORAGE_TYPE}${NC}"
    case "${STORAGE_TYPE}" in
        longhorn)
            echo -e "  部署组件:    Longhorn CSI Driver, Manager, Dashboard"
            echo -e "  StorageClass: longhorn (默认), longhorn-fast, longhorn-backup"
            echo -e "  Dashboard:   http://<LONGHORN_MANAGER_IP>:8080"
            echo -e "  备份命令:    kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80"
            ;;
        nfs)
            echo -e "  部署组件:    NFS Subdir External Provisioner"
            echo -e "  NFS服务器:   ${NFS_SERVER}"
            echo -e "  NFS路径:     ${NFS_PATH}"
            echo -e "  StorageClass: nfs-client (默认)"
            ;;
        ceph)
            echo -e "  部署组件:    Rook-Ceph Operator, CephCluster"
            echo -e "  StorageClass: ceph-block, ceph-filesystem"
            echo -e "  Dashboard:   kubectl -n rook-ceph port-forward svc/rook-ceph-mgr-dashboard 8443:8443"
            ;;
    esac
    echo ""
}

# ========================= 显示帮助信息 =========================
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [ACTION]

部署阶段3存储层：Longhorn（默认）/NFS/Ceph动态供给、StorageClass、功能验证。

OPTIONS:
    -s, --server <IP>          NFS服务器地址 (NFS模式必填)
    -p, --path <path>          NFS导出路径 (默认: /exports)
    -t, --storage-type <type>  存储类型: nfs, ceph, longhorn (默认: longhorn)
    --skip-verify              跳过验证步骤
    --list                     列出所有可用存储类型及说明
    --info                     显示当前存储配置和集群状态
    -h, --help                 显示帮助

ACTIONS:
    deploy                     部署存储 (默认)
    verify                     验证存储功能

ENVIRONMENT VARIABLES:
    STORAGE_TYPE            存储类型: nfs, ceph, longhorn
    NFS_SERVER              NFS服务器地址 (NFS模式)
    NFS_PATH                NFS导出路径
    SKIP_VERIFY=true        跳过验证

EXAMPLES:
    # 快速部署Longhorn (推荐)
    $(basename "$0") deploy

    # 查看所有存储类型
    $(basename "$0") --list

    # 查看当前配置
    $(basename "$0") --info

    # 部署NFS存储
    $(basename "$0") -t nfs -s 192.168.1.100 -p /exports

    # 部署Ceph存储
    $(basename "$0") -t ceph deploy

    # 仅验证不部署
    $(basename "$0") -t longhorn verify
EOF
}

# ========================= 预检函数 =========================
preflight_check() {
    log_step "前置检查"

    # 检查kubectl
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl未安装 - 请先安装 kubectl 工具"
        log_error "安装方法: curl -LO https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        log_error "详见: https://kubernetes.io/docs/tasks/tools/install-kubectl/"
        exit 1
    fi

    if ! kubectl cluster-info &>/dev/null; then
        log_error "无法连接到Kubernetes集群"
        log_error "请确保:"
        log_error "  1. 阶段2 (集群部署) 已完成"
        log_error "  2. kubeconfig 文件已正确配置"
        log_error "  3. 集群 Master 节点正常运行"
        log_error "诊断命令: kubectl cluster-info, kubectl get nodes"
        exit 1
    fi
    log_success "Kubernetes集群连接正常"

    # NFS专用检查
    if [[ "${STORAGE_TYPE}" == "nfs" ]]; then
        if ! command -v showmount &>/dev/null; then
            log_warn "nfs-common 未安装，无法验证NFS服务器导出列表"
            log_warn "安装方法: apt-get install -y nfs-common"
        fi

        if ping -c 1 -W 3 "${NFS_SERVER}" &>/dev/null; then
            log_success "NFS服务器 ${NFS_SERVER} 可达"
        else
            log_error "NFS服务器 ${NFS_SERVER} 不可达"
            log_error "请检查:"
            log_error "  1. IP地址是否正确: ${NFS_SERVER}"
            log_error "  2. NFS服务器是否运行"
            log_error "  3. 网络防火墙是否放行NFS端口 (2049)"
            exit 1
        fi

        if command -v showmount &>/dev/null; then
            if showmount -e "${NFS_SERVER}" &>/dev/null; then
                log_success "NFS服务器 ${NFS_SERVER} 导出可访问"
            else
                log_error "无法访问NFS服务器导出列表 (路径: ${NFS_PATH})"
                log_error "请确认NFS服务器已导出 ${NFS_PATH}"
                exit 1
            fi
        fi
    fi

    # Longhorn专用检查
    if [[ "${STORAGE_TYPE}" == "longhorn" ]]; then
        local node_count
        node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
        if [[ "${node_count}" -lt 2 ]]; then
            log_error "Longhorn至少需要2个节点 (当前: ${node_count})"
            log_error "请先添加足够的Worker节点"
            exit 1
        fi
        log_success "节点数量满足要求 (${node_count} ≥ 2)"
    fi

    # Ceph专用检查
    if [[ "${STORAGE_TYPE}" == "ceph" ]]; then
        local node_count
        node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
        if [[ "${node_count}" -lt 3 ]]; then
            log_error "Rook-Ceph至少需要3个节点 (当前: ${node_count})"
            log_error "请先添加足够的Worker节点"
            exit 1
        fi
        log_success "节点数量满足要求 (${node_count} ≥ 3)"
    fi

    log_success "前置检查通过"
}

# ========================= 主逻辑 =========================
main() {
    mkdir -p "$LOG_DIR"

    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -s|--server)       NFS_SERVER="$2"; shift 2 ;;
            -p|--path)         NFS_PATH="$2"; shift 2 ;;
            -t|--storage-type) STORAGE_TYPE="$2"; shift 2 ;;
            --skip-verify)     SKIP_VERIFY=true; shift ;;
            --list)            LIST_ONLY=true; shift ;;
            --info)            INFO_ONLY=true; shift ;;
            -h|--help)         usage; exit 0 ;;
            deploy|verify)     ACTION="$1"; shift ;;
            *)                 log_error "未知参数: $1"; usage; exit 1 ;;
        esac
    done

    # --list 模式：直接输出后退出
    if [[ "${LIST_ONLY}" == true ]]; then
        SKIP_CLEANUP_SUMMARY=true
        list_storage_types
        exit 0
    fi

    # --info 模式：显示配置后退出
    if [[ "${INFO_ONLY}" == true ]]; then
        SKIP_CLEANUP_SUMMARY=true
        show_info
        exit 0
    fi

    # 默认action
    ACTION="${ACTION:-deploy}"

    check_root
    check_lock

    # 验证存储类型
    case "${STORAGE_TYPE}" in
        nfs|ceph|longhorn)
            ;;
        *)
            log_error "不支持的存储类型: ${STORAGE_TYPE}"
            log_error "支持的类型: nfs, ceph, longhorn"
            log_error "提示: 使用 --list 查看所有存储类型说明"
            usage
            exit 1
            ;;
    esac

    # NFS模式需要验证必填参数
    if [[ "${STORAGE_TYPE}" == "nfs" ]]; then
        if [[ -z "${NFS_SERVER}" ]]; then
            log_error "NFS服务器地址未指定!"
            log_error "请使用以下方式之一指定:"
            log_error "  命令行: $0 -t nfs -s <NFS服务器IP>"
            log_error "  环境变量: NFS_SERVER=10.0.0.5 $0 -t nfs"
            usage
            exit 1
        fi
    fi

    banner "${STORAGE_TYPE}"
    log_info "操作: ${ACTION}"
    log_info "存储类型: ${STORAGE_TYPE}"
    if [[ "${STORAGE_TYPE}" == "nfs" ]]; then
        log_info "NFS服务器: ${NFS_SERVER}"
        log_info "NFS路径:   ${NFS_PATH}"
    fi
    log_info "跳过验证: ${SKIP_VERIFY}"

    # 前置检查
    preflight_check

    case "${STORAGE_TYPE}" in
        nfs)
            # NFS部署流程
            if [[ "${ACTION}" == "deploy" ]]; then
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
            elif [[ "${ACTION}" == "verify" ]]; then
                log_step "NFS 存储功能验证"
                bash "${SCRIPT_DIR}/03-verify-storage.sh" 2>&1 | tee -a "$LOG_FILE"
                log_success "NFS验证完成 ✓"
            fi
            ;;

        ceph)
            # Rook-Ceph部署流程
            if [[ "${ACTION}" == "deploy" ]]; then
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
            elif [[ "${ACTION}" == "verify" ]]; then
                log_step "Rook-Ceph 存储验证"
                bash "${SCRIPT_DIR}/05-verify-ceph.sh" 2>&1 | tee -a "$LOG_FILE"
                log_success "Rook-Ceph验证完成 ✓"
            fi
            ;;

        longhorn)
            # Longhorn部署流程
            if [[ "${ACTION}" == "deploy" ]]; then
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
            elif [[ "${ACTION}" == "verify" ]]; then
                log_step "Longhorn 存储验证"
                bash "${SCRIPT_DIR}/07-verify-longhorn.sh" 2>&1 | tee -a "$LOG_FILE"
                log_success "Longhorn验证完成 ✓"
            fi
            ;;
    esac

    log_success "阶段3存储层部署完成 (${STORAGE_TYPE})"
}

main "$@"
