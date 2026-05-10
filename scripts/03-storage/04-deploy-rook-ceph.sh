#!/usr/bin/env bash
###############################################################################
# 脚本名称: 04-deploy-rook-ceph.sh
# 功能描述: 部署Rook-Ceph Operator到Kubernetes集群，创建CephCluster和StorageClass
# 适用系统: 需要kubectl可访问集群, ≥3个工作节点
# 依赖条件: kubectl可用, Helm 3.x可用, 阶段2集群已部署
# 作者: 运维平台团队
# 版本: 1.1.0
# 创建日期: 2026-05-10
# 更新日期: 2026-05-10
#
# 使用方法:
#   ./04-deploy-rook-ceph.sh deploy
#   ./04-deploy-rook-ceph.sh verify
#   ./04-deploy-rook-ceph.sh status
#   ./04-deploy-rook-ceph.sh delete
#   ROOK_VERSION=v1.14.10 ./04-deploy-rook-ceph.sh deploy
#
# 环境变量:
#   ROOK_VERSION    - Rook-Ceph版本 (默认: v1.14.10)
#   CEPH_NAMESPACE  - Rook-Ceph命名空间 (默认: rook-ceph)
#   OSD_COUNT       - OSD数量 (默认: 3)
#   MON_COUNT       - Monitor数量 (默认: 3)
#
# 部署步骤:
#   1. 检查前置条件 (kubectl, 集群, ≥3节点)
#   2. 创建rook-ceph命名空间
#   3. 安装Rook-Ceph Operator CRD和资源
#   4. 等待Operator Pod就绪
#   5. 创建CephCluster (3 mons, 3 osds, dashboard)
#   6. 等待CephCluster健康
#   7. 创建StorageClasses (ceph-block, ceph-filesystem)
#   8. 验证并输出状态
###############################################################################
set -euo pipefail
umask 077

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

LOG_DIR="${PROJECT_ROOT}/logs/03-storage"
LOG_FILE="${LOG_DIR}/04-deploy-rook-ceph_$(date +%Y%m%d_%H%M%S).log"
LOCK_FILE="/var/lock/04-deploy-rook-ceph.lock"
CONFIG_DIR="${PROJECT_ROOT}/configs/ceph"
DEPLOY_START=$(date +%s)

# 配置变量（可通过环境变量覆盖）
ROOK_VERSION="${ROOK_VERSION:-v1.14.10}"
CEPH_NAMESPACE="${CEPH_NAMESPACE:-rook-ceph}"
OSD_COUNT="${OSD_COUNT:-3}"
MON_COUNT="${MON_COUNT:-3}"
ACTION="${ACTION:-deploy}"

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
    echo "║   阶段3 - Rook-Ceph 分布式存储部署                 ║" | tee -a "$LOG_FILE"
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
        echo -e "${GREEN}║   ✓ Rook-Ceph 部署成功                              ║${NC}" | tee -a "$LOG_FILE"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}" | tee -a "$LOG_FILE"
        log_info "总耗时: ${elapsed}秒"
        log_info "日志文件: ${LOG_FILE}"
    else
        echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}" | tee -a "$LOG_FILE"
        echo -e "${RED}║   ✗ Rook-Ceph 部署失败 (exit code: ${exit_code})           ║${NC}" | tee -a "$LOG_FILE"
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
Usage: $(basename "$0") [ACTION]

部署Rook-Ceph Operator到Kubernetes集群。

ACTIONS:
    deploy      部署Rook-Ceph (Operator + CephCluster + StorageClass)
    verify      验证Rook-Ceph部署状态
    status      显示当前Rook-Ceph状态
    delete      删除Rook-Ceph集群和所有资源

OPTIONS:
    -h, --help      显示帮助

ENVIRONMENT VARIABLES:
    ROOK_VERSION        Rook-Ceph版本 (默认: v1.14.10)
    CEPH_NAMESPACE      命名空间 (默认: rook-ceph)
    OSD_COUNT           OSD数量 (默认: 3)
    MON_COUNT           Monitor数量 (默认: 3)

EXAMPLES:
    $(basename "$0") deploy
    ROOK_VERSION=v1.14.10 $(basename "$0") deploy
    $(basename "$0") verify
    $(basename "$0") status
    $(basename "$0") delete
EOF
}

# ========================= 前置检查 =========================
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

    # 检查节点数量
    local node_count
    node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    if [[ "${node_count}" -lt 3 ]]; then
        log_error "Rook-Ceph至少需要3个节点 (当前: ${node_count})"
        exit 1
    fi
    log_success "集群节点数量满足要求 (${node_count} ≥ 3)"

    # 检查节点状态
    local not_ready
    not_ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -cv " Ready " || echo "0")
    if [[ "${not_ready}" -gt 0 ]]; then
        log_warn "有 ${not_ready} 个节点未就绪"
    else
        log_success "所有节点已就绪"
    fi

    log_success "前置检查通过"
}

# ========================= 部署函数 =========================

# 安装Rook-Ceph CRD
install_crds() {
    log_step "安装Rook-Ceph CRD"

    local crd_url="https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/crds.yaml"

    log_info "从 ${crd_url} 下载CRD..."
    if kubectl apply -f "${crd_url}" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Rook-Ceph CRD安装成功"
    else
        log_error "Rook-Ceph CRD安装失败"
        return 1
    fi

    # 等待CRD就绪
    log_info "等待CRD注册完成..."
    local max_wait=60
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        if kubectl get crd cephclusters.ceph.rook.io &>/dev/null; then
            log_success "CephCluster CRD已就绪"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    log_error "CRD注册超时"
    return 1
}

# 部署Rook-Ceph Operator
deploy_operator() {
    log_step "部署Rook-Ceph Operator"

    # 创建命名空间
    log_info "创建命名空间 ${CEPH_NAMESPACE}"
    kubectl create namespace "${CEPH_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - 2>&1 | tee -a "$LOG_FILE"

    # 应用Operator配置
    if [[ ! -f "${CONFIG_DIR}/operator.yaml" ]]; then
        log_error "Operator配置文件不存在: ${CONFIG_DIR}/operator.yaml"
        return 1
    fi

    # 替换版本号
    local rendered_dir
    rendered_dir=$(mktemp -d)
    sed "s|rook/ceph:v1.14.10|rook/ceph:${ROOK_VERSION}|g" "${CONFIG_DIR}/operator.yaml" > "${rendered_dir}/operator.yaml"

    log_info "应用Rook-Ceph Operator资源..."
    if kubectl apply -f "${rendered_dir}/operator.yaml" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Operator资源已应用"
    else
        log_error "Operator资源应用失败"
        rm -rf "${rendered_dir}"
        return 1
    fi
    rm -rf "${rendered_dir}"
}

# 等待Operator Pod就绪
wait_for_operator() {
    log_step "等待Rook-Ceph Operator Pod就绪"

    log_info "等待Operator Deployment rollout完成 (最多300秒)..."
    if kubectl rollout status deployment/rook-ceph-operator \
        --namespace="${CEPH_NAMESPACE}" \
        --timeout=300s 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Rook-Ceph Operator已就绪"
    else
        log_error "Operator未在300秒内就绪"
        kubectl get pods -n "${CEPH_NAMESPACE}" -l app=rook-ceph-operator -o wide 2>&1 | tee -a "$LOG_FILE" || true
        return 1
    fi
}

# 创建CephCluster
deploy_ceph_cluster() {
    log_step "创建CephCluster"

    if [[ ! -f "${CONFIG_DIR}/cluster.yaml" ]]; then
        log_error "CephCluster配置文件不存在: ${CONFIG_DIR}/cluster.yaml"
        return 1
    fi

    # 替换配置
    local rendered_dir
    rendered_dir=$(mktemp -d)
    cp "${CONFIG_DIR}/cluster.yaml" "${rendered_dir}/cluster.yaml"

    # 根据环境变量调整配置
    sed -i "s|count: 3|count: ${MON_COUNT}|g" "${rendered_dir}/cluster.yaml"
    sed -i "s|count: 3|count: ${OSD_COUNT}|g" "${rendered_dir}/cluster.yaml" 2>/dev/null || true

    log_info "应用CephCluster资源 (MON: ${MON_COUNT}, OSD: ${OSD_COUNT})..."
    if kubectl apply -f "${rendered_dir}/cluster.yaml" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "CephCluster资源已创建"
    else
        log_error "CephCluster资源创建失败"
        rm -rf "${rendered_dir}"
        return 1
    fi
    rm -rf "${rendered_dir}"
}

# 等待CephCluster健康
wait_for_ceph_health() {
    log_step "等待CephCluster达到健康状态"

    log_info "等待CephCluster进入Ready状态 (最多600秒)..."
    log_info "提示: 首次部署可能需要较长时间下载镜像和初始化OSD"

    local max_wait=600
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local phase
        phase=$(kubectl get cephcluster -n "${CEPH_NAMESPACE}" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "unknown")

        if [[ "${phase}" == "Ready" ]]; then
            log_success "CephCluster已达到Ready状态"
            return 0
        elif [[ "${phase}" == "Failed" ]]; then
            log_error "CephCluster状态为Failed"
            kubectl get cephcluster -n "${CEPH_NAMESPACE}" -o yaml 2>&1 | tail -30 | tee -a "$LOG_FILE"
            return 1
        fi

        # 每60秒输出一次状态
        if [[ $((waited % 60)) -eq 0 && $waited -gt 0 ]]; then
            log_info "等待中... (${waited}/${max_wait}s) 当前阶段: ${phase}"
            kubectl get pods -n "${CEPH_NAMESPACE}" --no-headers 2>/dev/null | tee -a "$LOG_FILE" || true
        fi

        sleep 10
        waited=$((waited + 10))
    done

    log_error "CephCluster未在 ${max_wait}秒内达到Ready状态"
    kubectl get pods -n "${CEPH_NAMESPACE}" 2>&1 | tee -a "$LOG_FILE"
    return 1
}

# 创建StorageClasses
deploy_storageclasses() {
    log_step "创建StorageClass"

    # 应用Ceph RBD StorageClass
    if [[ -f "${CONFIG_DIR}/storageclass-block.yaml" ]]; then
        log_info "创建Ceph RBD StorageClass..."
        if kubectl apply -f "${CONFIG_DIR}/storageclass-block.yaml" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Ceph RBD StorageClass已创建"
        else
            log_warn "Ceph RBD StorageClass创建失败 (可能Operator尚未就绪)"
        fi
    fi

    # 应用CephFS StorageClass
    if [[ -f "${CONFIG_DIR}/storageclass-filesystem.yaml" ]]; then
        log_info "创建CephFS StorageClass..."
        if kubectl apply -f "${CONFIG_DIR}/storageclass-filesystem.yaml" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "CephFS StorageClass已创建"
        else
            log_warn "CephFS StorageClass创建失败 (可能MDS尚未就绪)"
        fi
    fi

    # 列出StorageClass
    log_info "当前StorageClass列表:"
    kubectl get storageclass 2>&1 | tee -a "$LOG_FILE"
}

# 显示部署状态
show_status() {
    log_step "Rook-Ceph 状态"

    # Operator状态
    log_info "=== Operator状态 ==="
    kubectl get deployment rook-ceph-operator -n "${CEPH_NAMESPACE}" 2>&1 | tee -a "$LOG_FILE" || log_warn "Operator未找到"

    # CephCluster状态
    log_info "=== CephCluster状态 ==="
    kubectl get cephcluster -n "${CEPH_NAMESPACE}" 2>&1 | tee -a "$LOG_FILE" || log_warn "CephCluster未找到"

    # Pod状态
    log_info "=== Pods状态 ==="
    kubectl get pods -n "${CEPH_NAMESPACE}" -o wide 2>&1 | tee -a "$LOG_FILE"

    # StorageClass状态
    log_info "=== StorageClass ==="
    kubectl get storageclass 2>&1 | tee -a "$LOG_FILE"

    # Ceph Dashboard信息
    local dashboard_svc
    dashboard_svc=$(kubectl get svc -n "${CEPH_NAMESPACE}" rook-ceph-mgr-dashboard -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null || echo "未就绪")
    log_info "Dashboard地址: https://${dashboard_svc}"

    # Ceph Health (如果toolbox可用)
    local toolbox_pod
    toolbox_pod=$(kubectl get pods -n "${CEPH_NAMESPACE}" -l app=rook-ceph-tools -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "${toolbox_pod}" ]]; then
        log_info "=== Ceph Health ==="
        kubectl exec -n "${CEPH_NAMESPACE}" "${toolbox_pod}" -- ceph health 2>&1 | tee -a "$LOG_FILE" || true
        kubectl exec -n "${CEPH_NAMESPACE}" "${toolbox_pod}" -- ceph osd tree 2>&1 | tee -a "$LOG_FILE" || true
    fi
}

# 删除Rook-Ceph
delete_ceph() {
    log_step "删除Rook-Ceph集群"

    log_warn "即将删除Rook-Ceph集群及其所有数据!"
    log_warn "此操作不可逆，所有Ceph存储卷数据将丢失!"
    echo -ne "${YELLOW}确认删除? 输入 YES 继续: ${NC}"
    read -r confirm
    if [[ "${confirm}" != "YES" ]]; then
        log_info "已取消删除操作"
        return 0
    fi

    # 删除StorageClass
    log_info "删除StorageClass..."
    kubectl delete storageclass ceph-block ceph-filesystem ceph-block-retained --ignore-not-found 2>&1 | tee -a "$LOG_FILE" || true

    # 删除CephCluster
    log_info "删除CephCluster..."
    kubectl delete cephcluster -n "${CEPH_NAMESPACE}" --all 2>&1 | tee -a "$LOG_FILE" || true

    # 等待Ceph资源清理
    log_info "等待Ceph资源清理 (最多300秒)..."
    kubectl delete cephcluster -n "${CEPH_NAMESPACE}" --all --timeout=300s 2>&1 | tee -a "$LOG_FILE" || true

    # 删除CephFilesystem
    log_info "删除CephFilesystem..."
    kubectl delete cephfilesystem -n "${CEPH_NAMESPACE}" --all 2>&1 | tee -a "$LOG_FILE" || true

    # 删除CephBlockPool
    log_info "删除CephBlockPool..."
    kubectl delete cephblockpool -n "${CEPH_NAMESPACE}" --all 2>&1 | tee -a "$LOG_FILE" || true

    # 删除Operator资源
    log_info "删除Operator..."
    kubectl delete -f "${CONFIG_DIR}/operator.yaml" 2>&1 | tee -a "$LOG_FILE" || true

    # 删除CRD
    log_info "删除CRD..."
    kubectl delete -f "https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/crds.yaml" 2>&1 | tee -a "$LOG_FILE" || true

    # 清理本地数据目录
    log_info "清理节点数据目录..."
    kubectl get nodes -o name 2>/dev/null | while read -r node; do
        local node_name="${node#node/}"
        kubectl debug "node/${node_name}" --image=busybox --rm -it -- ls /var/lib/rook 2>/dev/null && \
            log_info "节点 ${node_name}: /var/lib/rook 需手动清理" || true
    done 2>/dev/null || true

    # 删除命名空间
    log_info "删除命名空间 ${CEPH_NAMESPACE}..."
    kubectl delete namespace "${CEPH_NAMESPACE}" --timeout=120s 2>&1 | tee -a "$LOG_FILE" || true

    log_success "Rook-Ceph集群删除完成"
}

# ========================= 主逻辑 =========================
main() {
    mkdir -p "$LOG_DIR"
    check_root
    check_lock

    # 解析命令行参数
    if [[ $# -ge 1 ]]; then
        ACTION="$1"
    fi

    case "${ACTION}" in
        -h|--help)
            usage
            exit 0
            ;;
        deploy|verify|status|delete)
            ;;
        *)
            log_error "未知操作: ${ACTION}"
            usage
            exit 1
            ;;
    esac

    banner

    case "${ACTION}" in
        deploy)
            log_info "操作: deploy"
            log_info "Rook版本: ${ROOK_VERSION}"
            log_info "命名空间: ${CEPH_NAMESPACE}"
            log_info "MON数量: ${MON_COUNT}"
            log_info "OSD数量: ${OSD_COUNT}"

            # 步骤1: 前置检查
            preflight_check

            # 步骤2: 安装CRD
            install_crds

            # 步骤3: 部署Operator
            deploy_operator
            wait_for_operator

            # 步骤4: 创建CephCluster
            deploy_ceph_cluster
            wait_for_ceph_health

            # 步骤5: 创建StorageClass
            deploy_storageclasses

            # 步骤6: 显示状态
            show_status

            log_success "Rook-Ceph部署完成"
            ;;
        verify)
            bash "${SCRIPT_DIR}/05-verify-ceph.sh" 2>&1 | tee -a "$LOG_FILE"
            ;;
        status)
            show_status
            ;;
        delete)
            delete_ceph
            ;;
    esac
}

main "$@"
