#!/usr/bin/env bash
###############################################################################
# 脚本名称: 06-deploy-longhorn.sh
# 功能描述: 部署Longhorn分布式存储到Kubernetes集群
# 适用系统: 需要kubectl可访问集群, Helm 3.x, ≥2个工作节点
# 依赖条件: kubectl可用, Helm 3.x可用, open-iscsi已安装
# 作者: 运维平台团队
# 版本: 1.2.0
# 创建日期: 2026-05-10
# 更新日期: 2026-05-10
#
# 使用方法:
#   ./06-deploy-longhorn.sh deploy
#   ./06-deploy-longhorn.sh verify
#   ./06-deploy-longhorn.sh status
#   ./06-deploy-longhorn.sh delete
#   LONGHORN_VERSION=v1.6.4 ./06-deploy-longhorn.sh deploy
#
# 环境变量:
#   LONGHORN_VERSION    - Longhorn版本 (默认: v1.6.4)
#   LONGHORN_NAMESPACE  - Longhorn命名空间 (默认: longhorn-system)
#   REPLICA_COUNT       - 默认副本数 (默认: 3)
#   HELM_RETRY_MAX      - Helm安装最大重试次数 (默认: 3)
#
# 部署步骤:
#   1. 检查前置条件 (kubectl, 集群, ≥2节点, open-iscsi)
#   2. 安装open-iscsi (所有节点)
#   3. 添加Longhorn Helm仓库
#   4. helm install longhorn (含重试逻辑)
#   5. 等待所有Longhorn Pod就绪
#   6. 创建StorageClasses (longhorn, longhorn-fast, longhorn-backup)
#   7. 验证StorageClass
#   8. 启用Longhorn Dashboard
#   9. 输出部署摘要 (Dashboard URL + StorageClass列表)
###############################################################################
set -euo pipefail
umask 077

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

LOG_DIR="${PROJECT_ROOT}/logs/03-storage"
LOG_FILE="${LOG_DIR}/06-deploy-longhorn_$(date +%Y%m%d_%H%M%S).log"
LOCK_FILE="/var/lock/06-deploy-longhorn.lock"
CONFIG_DIR="${PROJECT_ROOT}/configs/longhorn"
DEPLOY_START=$(date +%s)

# 配置变量（可通过环境变量覆盖）
LONGHORN_VERSION="${LONGHORN_VERSION:-v1.6.4}"
LONGHORN_NAMESPACE="${LONGHORN_NAMESPACE:-longhorn-system}"
REPLICA_COUNT="${REPLICA_COUNT:-3}"
HELM_RETRY_MAX="${HELM_RETRY_MAX:-3}"
ACTION="${ACTION:-deploy}"

# 进度跟踪
TOTAL_STEPS=7
CURRENT_STEP=0

# ========================= 日志函数 =========================
log_info()    { echo -e "${GREEN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >&2; }
log_step()    { echo -e "${CYAN}[STEP]${NC}  $(date '+%Y-%m-%d %H:%M:%S') === $* ===" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }

# 进度指示器
show_progress() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local pct=$((CURRENT_STEP * 100 / TOTAL_STEPS))
    local bar=""
    local filled=$((pct / 5))
    local empty=$((20 - filled))
    for ((i=0; i<filled; i++)); do bar="${bar}█"; done
    for ((i=0; i<empty; i++)); do bar="${bar}░"; done
    echo -e "${CYAN}[${bar}] ${pct}% (${CURRENT_STEP}/${TOTAL_STEPS})${NC}" | tee -a "$LOG_FILE"
}

banner() {
    echo -e "" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${BLUE}" | tee -a "$LOG_FILE"
    echo "╔══════════════════════════════════════════════════════╗" | tee -a "$LOG_FILE"
    echo "║   阶段3 - Longhorn 分布式存储部署                   ║" | tee -a "$LOG_FILE"
    echo "║   版本: ${LONGHORN_VERSION}  命名空间: ${LONGHORN_NAMESPACE}       ║" | tee -a "$LOG_FILE"
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
        echo -e "${GREEN}║   ✓ Longhorn 部署成功                               ║${NC}" | tee -a "$LOG_FILE"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}" | tee -a "$LOG_FILE"
        show_deploy_summary
        log_info "总耗时: ${elapsed}秒"
        log_info "日志文件: ${LOG_FILE}"
    else
        echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}" | tee -a "$LOG_FILE"
        echo -e "${RED}║   ✗ Longhorn 部署失败 (exit code: ${exit_code})            ║${NC}" | tee -a "$LOG_FILE"
        echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}" | tee -a "$LOG_FILE"
        log_error "总耗时: ${elapsed}秒"
        log_error "请检查日志: ${LOG_FILE}"
        log_error "常见解决方法:"
        log_error "  1. 检查所有节点 open-iscsi 是否运行: systemctl status iscsid"
        log_error "  2. 检查 Helm 仓库是否可达: helm repo update"
        log_error "  3. 检查集群资源是否充足: kubectl top nodes"
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

# 显示帮助信息
usage() {
    cat <<EOF
Usage: $(basename "$0") [ACTION]

部署Longhorn分布式存储到Kubernetes集群。

ACTIONS:
    deploy      部署Longhorn (Helm安装 + StorageClass + Dashboard)
    verify      验证Longhorn部署状态
    status      显示当前Longhorn状态
    delete      删除Longhorn集群和所有资源

OPTIONS:
    -h, --help      显示帮助

ENVIRONMENT VARIABLES:
    LONGHORN_VERSION    Longhorn版本 (默认: v1.6.4)
    LONGHORN_NAMESPACE  命名空间 (默认: longhorn-system)
    REPLICA_COUNT       默认副本数 (默认: 3)
    HELM_RETRY_MAX      Helm安装最大重试次数 (默认: 3)

EXAMPLES:
    $(basename "$0") deploy
    LONGHORN_VERSION=v1.6.4 $(basename "$0") deploy
    $(basename "$0") verify
    $(basename "$0") status
    $(basename "$0") delete
EOF
}

# ========================= 前置检查 =========================
preflight_check() {
    log_step "1/${TOTAL_STEPS} 前置检查"
    show_progress

    # 检查kubectl
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl未安装"
        log_error "安装方法: curl -LO https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        exit 1
    fi

    if ! kubectl cluster-info &>/dev/null; then
        log_error "无法连接到Kubernetes集群"
        log_error "请确保阶段2集群部署已完成"
        exit 1
    fi
    log_success "Kubernetes集群连接正常"

    # 检查Helm
    if ! command -v helm &>/dev/null; then
        log_error "Helm未安装"
        log_error "安装方法: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
        exit 1
    fi

    local helm_version
    helm_version=$(helm version --short 2>/dev/null || echo "unknown")
    log_success "Helm版本: ${helm_version}"

    # 检查节点数量
    local node_count
    node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    if [[ "${node_count}" -lt 2 ]]; then
        log_error "Longhorn至少需要2个节点 (当前: ${node_count})"
        log_error "请先添加足够的Worker节点"
        exit 1
    fi
    log_success "集群节点数量满足要求 (${node_count} ≥ 2)"

    # 检查节点状态
    local not_ready
    not_ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -cv " Ready " || echo "0")
    if [[ "${not_ready}" -gt 0 ]]; then
        log_warn "有 ${not_ready} 个节点未就绪"
        kubectl get nodes --no-headers 2>/dev/null | grep -v " Ready " | tee -a "$LOG_FILE"
    else
        log_success "所有节点已就绪"
    fi

    log_success "前置检查通过"
}

# ========================= 部署函数 =========================

# 检查所有节点的 open-iscsi 状态
check_iscsi_on_nodes() {
    log_step "2/${TOTAL_STEPS} 检查并安装 open-iscsi"
    show_progress

    log_info "检查所有节点的 open-iscsi 状态..."
    local all_ok=true
    local nodes
    nodes=$(kubectl get nodes --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null)

    while IFS= read -r node; do
        [[ -z "${node}" ]] && continue
        # 通过DaemonSet检查iscsid是否运行
        local iscsi_running
        iscsi_running=$(kubectl debug node/"${node}" --image=busybox --quiet -- chroot /host systemctl is-active iscsid 2>/dev/null || echo "unknown")
        if [[ "${iscsi_running}" == "active" ]]; then
            log_success "节点 ${node}: open-iscsi 已运行"
        else
            log_warn "节点 ${node}: open-iscsi 状态=${iscsi_running}"
            all_ok=false
        fi
    done <<< "${nodes}"

    if [[ "${all_ok}" == false ]]; then
        log_warn "部分节点 open-iscsi 未就绪，尝试自动安装..."
        install_iscsi
    else
        log_success "所有节点 open-iscsi 正常"
    fi
}

# 安装open-iscsi依赖
install_iscsi() {
    log_info "通过DaemonSet在所有节点安装open-iscsi..."

    # 检查是否有install-iscsi.sh脚本
    if [[ -f "${CONFIG_DIR}/install-iscsi.sh" ]]; then
        log_info "使用install-iscsi.sh安装open-iscsi..."
        bash "${CONFIG_DIR}/install-iscsi.sh" 2>&1 | tee -a "$LOG_FILE" || true
    else
        # 使用DaemonSet在所有节点安装open-iscsi
        cat <<'ISCSI_DS' | kubectl apply -f - 2>&1 | tee -a "$LOG_FILE" || true
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: install-iscsi
  namespace: kube-system
  labels:
    app: install-iscsi
spec:
  selector:
    matchLabels:
      app: install-iscsi
  template:
    metadata:
      labels:
        app: install-iscsi
    spec:
      initContainers:
        - name: install
          image: debian:bullseye-slim
          command:
            - bash
            - -c
            - |
              apt-get update -qq && apt-get install -y -qq open-iscsi > /dev/null 2>&1
              systemctl enable iscsid && systemctl start iscsid
              echo "open-iscsi installed successfully"
          securityContext:
            privileged: true
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
      tolerations:
        - operator: Exists
ISCSI_DS
    fi

    # 等待DaemonSet完成
    log_info "等待open-iscsi安装完成 (最多120秒)..."
    sleep 10
    kubectl rollout status daemonset/install-iscsi -n kube-system --timeout=120s 2>&1 | tee -a "$LOG_FILE" || true

    # 清理DaemonSet
    kubectl delete daemonset install-iscsi -n kube-system --ignore-not-found 2>/dev/null || true

    log_success "open-iscsi依赖安装完成"
}

# 添加Longhorn Helm仓库
add_helm_repo() {
    log_step "3/${TOTAL_STEPS} 添加Longhorn Helm仓库"
    show_progress

    if helm repo list 2>/dev/null | grep -q "longhorn"; then
        log_info "Longhorn Helm仓库已存在"
    else
        log_info "添加Longhorn Helm仓库..."
        if helm repo add longhorn https://charts.longhorn.io 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Longhorn Helm仓库已添加"
        else
            log_error "Longhorn Helm仓库添加失败"
            log_error "请检查网络连接: curl -I https://charts.longhorn.io"
            return 1
        fi
    fi

    log_info "更新Helm仓库索引..."
    helm repo update 2>&1 | tee -a "$LOG_FILE"
    log_success "Helm仓库已更新"
}

# 带重试逻辑的Helm安装
install_longhorn_with_retry() {
    local max_retries="${HELM_RETRY_MAX}"
    local attempt=1

    while [[ ${attempt} -le ${max_retries} ]]; do
        log_info "尝试安装/升级 Longhorn (第 ${attempt}/${max_retries} 次)..."
        if install_longhorn; then
            return 0
        fi

        if [[ ${attempt} -lt ${max_retries} ]]; then
            local wait_time=$((attempt * 15))
            log_warn "安装失败，${wait_time}秒后重试..."
            sleep "${wait_time}"
        fi
        attempt=$((attempt + 1))
    done

    log_error "Longhorn 安装失败，已尝试 ${max_retries} 次"
    log_error "请检查:"
    log_error "  1. Helm 仓库是否可达: helm repo update"
    log_error "  2. 集群资源是否充足: kubectl top nodes"
    log_error "  3. 网络代理设置是否正确"
    return 1
}

# 使用Helm安装Longhorn
install_longhorn() {
    log_step "4/${TOTAL_STEPS} Helm安装Longhorn"
    show_progress

    # 创建命名空间 (支持升级场景)
    log_info "创建/确认命名空间 ${LONGHORN_NAMESPACE}"
    kubectl create namespace "${LONGHORN_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - 2>&1 | tee -a "$LOG_FILE"

    # 准备Helm values
    local values_file="${CONFIG_DIR}/values.yaml"
    if [[ ! -f "${values_file}" ]]; then
        log_warn "Helm values文件不存在: ${values_file}，使用默认配置"
        values_file=""
    fi

    # 检查是否已安装 (处理升级场景)
    local release_exists=false
    if helm status longhorn -n "${LONGHORN_NAMESPACE}" &>/dev/null 2>&1; then
        release_exists=true
        log_info "检测到已存在的 Longhorn release，将执行升级..."
    fi

    local helm_args=(
        install longhorn longhorn/longhorn
        --namespace "${LONGHORN_NAMESPACE}"
        --version "${LONGHORN_VERSION}"
        --set "defaultSettings.defaultReplicaCount=${REPLICA_COUNT}"
        --set "defaultSettings.defaultDataPath=/var/lib/longhorn"
        --set "persistence.enabled=true"
        --set "ingress.enabled=true"
        --wait
        --timeout 600s
    )

    if [[ -n "${values_file}" ]]; then
        helm_args+=(-f "${values_file}")
    fi

    if helm "${helm_args[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Longhorn Helm安装成功"
    else
        # 如果install失败且release已存在，尝试升级
        if [[ "${release_exists}" == true ]]; then
            log_warn "安装失败，尝试升级已有release..."
            if helm upgrade longhorn longhorn/longhorn \
                --namespace "${LONGHORN_NAMESPACE}" \
                --version "${LONGHORN_VERSION}" \
                --set "defaultSettings.defaultReplicaCount=${REPLICA_COUNT}" \
                --set "defaultSettings.defaultDataPath=/var/lib/longhorn" \
                --set "persistence.enabled=true" \
                --set "ingress.enabled=true" \
                --wait \
                --timeout 600s \
                ${values_file:+-f "${values_file}"} 2>&1 | tee -a "$LOG_FILE"; then
                log_success "Longhorn Helm升级成功"
            else
                log_error "Longhorn Helm升级也失败"
                return 1
            fi
        else
            log_error "Longhorn Helm安装失败 (且非升级场景)"
            return 1
        fi
    fi
}

# 等待Longhorn Pod就绪
wait_for_longhorn() {
    log_step "5/${TOTAL_STEPS} 等待Longhorn Pod就绪"
    show_progress

    log_info "等待所有Longhorn Pod就绪 (最多300秒)..."
    local max_wait=300
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local total
        local ready
        total=$(kubectl get pods -n "${LONGHORN_NAMESPACE}" --no-headers 2>/dev/null | wc -l)
        ready=$(kubectl get pods -n "${LONGHORN_NAMESPACE}" --no-headers 2>/dev/null | grep -c "Running" || echo "0")

        if [[ "${ready}" -ge 1 && "${total}" -eq "${ready}" ]]; then
            log_success "所有Longhorn Pod已就绪 (${ready}/${total})"
            return 0
        fi

        if [[ $((waited % 30)) -eq 0 && $waited -gt 0 ]]; then
            log_info "等待中... (${waited}/${max_wait}s) 就绪: ${ready}/${total}"
        fi

        sleep 10
        waited=$((waited + 10))
    done

    log_error "Longhorn Pod未在 ${max_wait}秒内全部就绪"
    log_error "当前Pod状态:"
    kubectl get pods -n "${LONGHORN_NAMESPACE}" 2>&1 | tee -a "$LOG_FILE"
    return 1
}

# 创建StorageClasses
deploy_storageclasses() {
    log_step "6/${TOTAL_STEPS} 创建StorageClass"
    show_progress

    # 应用默认StorageClass
    if [[ -f "${CONFIG_DIR}/storageclass-default.yaml" ]]; then
        log_info "创建Longhorn默认StorageClass..."
        if kubectl apply -f "${CONFIG_DIR}/storageclass-default.yaml" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Longhorn默认StorageClass已创建"
        else
            log_warn "Longhorn默认StorageClass创建失败"
        fi
    fi

    # 应用高性能StorageClass
    if [[ -f "${CONFIG_DIR}/storageclass-fast.yaml" ]]; then
        log_info "创建Longhorn高性能StorageClass..."
        if kubectl apply -f "${CONFIG_DIR}/storageclass-fast.yaml" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Longhorn高性能StorageClass已创建"
        else
            log_warn "Longhorn高性能StorageClass创建失败"
        fi
    fi

    # 应用备份StorageClass
    if [[ -f "${CONFIG_DIR}/storageclass-backup.yaml" ]]; then
        log_info "创建Longhorn备份StorageClass..."
        if kubectl apply -f "${CONFIG_DIR}/storageclass-backup.yaml" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Longhorn备份StorageClass已创建"
        else
            log_warn "Longhorn备份StorageClass创建失败"
        fi
    fi

    # 列出StorageClass
    log_info "当前StorageClass列表:"
    kubectl get storageclass 2>&1 | tee -a "$LOG_FILE"
}

# 显示部署摘要
show_deploy_summary() {
    echo ""
    log_step "7/${TOTAL_STEPS} 部署摘要"
    show_progress

    # Dashboard信息
    local dashboard_svc
    dashboard_svc=$(kubectl get svc -n "${LONGHORN_NAMESPACE}" longhorn-frontend \
        -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "未就绪")
    local dashboard_port
    dashboard_port=$(kubectl get svc -n "${LONGHORN_NAMESPACE}" longhorn-frontend \
        -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "80")

    echo ""
    echo -e "${BOLD}${GREEN}Longhorn 部署摘要${NC}"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    echo -e "  ${BOLD}版本${NC}:          ${LONGHORN_VERSION}"
    echo -e "  ${BOLD}命名空间${NC}:      ${LONGHORN_NAMESPACE}"
    echo -e "  ${BOLD}副本数${NC}:        ${REPLICA_COUNT}"
    echo ""
    echo -e "  ${BOLD}Dashboard${NC}:     http://${dashboard_svc}:${dashboard_port}"
    echo ""
    echo -e "  ${BOLD}StorageClass:${NC}"
    kubectl get storageclass 2>/dev/null | grep longhorn | sed 's/^/    /' | tee -a "$LOG_FILE" || echo "    (获取中...)"
    echo ""
    echo -e "  ${BOLD}Pod 状态:${NC}"
    kubectl get pods -n "${LONGHORN_NAMESPACE}" --no-headers 2>/dev/null | \
        awk '{printf "    %-50s %s\n", $1, $3}' | tee -a "$LOG_FILE" || echo "    (获取中...)"
    echo ""
    echo -e "  ${BOLD}节点状态:${NC}"
    kubectl get nodes -l longhorn-node=true --no-headers 2>/dev/null | \
        awk '{printf "    %-30s %s\n", $1, $2}' | tee -a "$LOG_FILE" || echo "    (获取中...)"
    echo ""
    echo "════════════════════════════════════════════════════════════════"
}

# 显示部署状态
show_status() {
    log_step "Longhorn 状态"

    # Manager状态
    log_info "=== Longhorn Manager ==="
    kubectl get pods -n "${LONGHORN_NAMESPACE}" -l app=longhorn-manager -o wide 2>&1 | tee -a "$LOG_FILE" || log_warn "Manager Pod未找到"

    # Driver状态
    log_info "=== Longhorn Driver ==="
    kubectl get pods -n "${LONGHORN_NAMESPACE}" -l app=longhorn-csi-plugin -o wide 2>&1 | tee -a "$LOG_FILE" || log_warn "CSI Plugin未找到"
    kubectl get pods -n "${LONGHORN_NAMESPACE}" -l app=longhorn-csi-provisioner -o wide 2>&1 | tee -a "$LOG_FILE" || log_warn "CSI Provisioner未找到"

    # 所有Pod状态
    log_info "=== 所有Pod状态 ==="
    kubectl get pods -n "${LONGHORN_NAMESPACE}" -o wide 2>&1 | tee -a "$LOG_FILE"

    # 节点状态
    log_info "=== Longhorn节点 ==="
    kubectl get nodes -l longhorn-node=true -o wide 2>&1 | tee -a "$LOG_FILE" || log_info "无Longhorn节点标签"

    # StorageClass
    log_info "=== StorageClass ==="
    kubectl get storageclass 2>&1 | tee -a "$LOG_FILE"

    # Dashboard信息
    local dashboard_svc
    dashboard_svc=$(kubectl get svc -n "${LONGHORN_NAMESPACE}" longhorn-frontend -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null || echo "未就绪")
    log_info "Longhorn Dashboard: http://${dashboard_svc}"

    # 卷信息
    log_info "=== 卷列表 ==="
    kubectl get volumes.longhorn.io -n "${LONGHORN_NAMESPACE}" 2>&1 | tee -a "$LOG_FILE" || log_info "无卷或CRD未就绪"
}

# 删除Longhorn
delete_longhorn() {
    log_step "删除Longhorn集群"

    log_warn "即将删除Longhorn集群及其所有数据!"
    log_warn "此操作不可逆，所有Longhorn存储卷数据将丢失!"
    echo -ne "${YELLOW}确认删除? 输入 YES 继续: ${NC}"
    read -r confirm
    if [[ "${confirm}" != "YES" ]]; then
        log_info "已取消删除操作"
        return 0
    fi

    # 删除StorageClass
    log_info "删除StorageClass..."
    kubectl delete storageclass longhorn longhorn-fast longhorn-backup --ignore-not-found 2>&1 | tee -a "$LOG_FILE" || true

    # 卸载Helm release
    log_info "卸载Longhorn Helm release..."
    helm uninstall longhorn -n "${LONGHORN_NAMESPACE}" 2>&1 | tee -a "$LOG_FILE" || true

    # 等待资源清理
    log_info "等待Longhorn资源清理 (最多300秒)..."
    kubectl delete namespace "${LONGHORN_NAMESPACE}" --timeout=300s 2>&1 | tee -a "$LOG_FILE" || true

    # 删除CRD
    log_info "删除Longhorn CRD..."
    kubectl get crd 2>/dev/null | grep longhorn | awk '{print $1}' | xargs -r kubectl delete crd 2>&1 | tee -a "$LOG_FILE" || true

    log_success "Longhorn集群删除完成"
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
            log_error "可用操作: deploy, verify, status, delete"
            usage
            exit 1
            ;;
    esac

    banner

    case "${ACTION}" in
        deploy)
            log_info "操作: deploy"
            log_info "Longhorn版本: ${LONGHORN_VERSION}"
            log_info "命名空间: ${LONGHORN_NAMESPACE}"
            log_info "副本数: ${REPLICA_COUNT}"

            # 步骤1: 前置检查
            preflight_check

            # 步骤2: 检查并安装open-iscsi
            check_iscsi_on_nodes

            # 步骤3: 添加Helm仓库
            add_helm_repo

            # 步骤4: Helm安装Longhorn (含重试)
            install_longhorn_with_retry

            # 步骤5: 等待Pod就绪
            wait_for_longhorn

            # 步骤6: 创建StorageClass
            deploy_storageclasses

            # 步骤7: 显示部署摘要
            show_deploy_summary

            log_success "Longhorn部署完成"
            ;;
        verify)
            bash "${SCRIPT_DIR}/07-verify-longhorn.sh" 2>&1 | tee -a "$LOG_FILE"
            ;;
        status)
            show_status
            ;;
        delete)
            delete_longhorn
            ;;
    esac
}

main "$@"
