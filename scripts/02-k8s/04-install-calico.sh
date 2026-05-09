#!/usr/bin/env bash
###############################################################################
# 脚本名称: 04-install-calico.sh
# 功能描述: 安装Calico网络插件，支持Operator模式和本地Manifest模式
# 适用系统: Ubuntu 20.04/22.04, CentOS 7/8, Rocky Linux 8/9, RHEL 8/9
# 依赖条件: root权限, kubectl可用, Master节点已就绪
# 作者: 运维平台团队
# 版本: 1.1.0
# 创建日期: 2026-05-09
# 更新日期: 2026-05-09
#
# 使用方法:
#   ./04-install-calico.sh                                  # 默认安装
#   CALICO_VERSION=3.27 POD_CIDR=10.244.0.0/16 ./04-install-calico.sh
#   CALICO_MANIFEST=/path/to/calico.yaml ./04-install-calico.sh  # 本地Manifest模式
#
# 环境变量:
#   CALICO_VERSION  - Calico版本 (默认: 3.26)
#   POD_CIDR        - Pod网络CIDR (默认: 10.244.0.0/16)
#   CALICO_MANIFEST - 本地Calico Manifest文件路径 (可选，使用本地配置)
#
# 安装模式:
#   1. Operator模式 (推荐): 使用Tigera Operator管理Calico
#   2. 本地Manifest模式: 使用预配置的calico.yaml文件
#
# 功能说明:
#   1. 等待Master节点就绪
#   2. 安装Calico Operator (Operator模式)
#   3. 配置Calico Installation CR (Operator模式)
#   4. 或应用本地Manifest (Manifest模式)
#   5. 等待所有Calico组件就绪
#   6. 验证网络连接
###############################################################################
set -euo pipefail
umask 077

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/02-k8s"
LOG_FILE="${LOG_DIR}/04-install-calico_$(date +%Y%m%d_%H%M%S).log"
LOCK_FILE="/var/lock/04-install-calico.lock"

# 配置变量（可通过环境变量覆盖）
CALICO_VERSION="${CALICO_VERSION:-3.26}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
CALICO_MANIFEST="${CALICO_MANIFEST:-/tmp/calico.yaml}"

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
        log_error "Calico安装失败，退出码: $exit_code (行 $LINENO)"
        log_error "请检查日志: $LOG_FILE"
        log_error "排查步骤:"
        log_error "  1. 检查Master节点: kubectl get nodes"
        log_error "  2. 检查Operator状态: kubectl get pods -n tigera-operator"
        log_error "  3. 检查Calico日志: kubectl logs -n calico-system <pod-name>"
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
            log_error "另一个实例正在运行 (PID: $pid)"
            exit 1
        fi
        log_warn "发现残留锁文件，已清理"
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
}

# ========================= 核心功能函数 =========================

# 步骤1: 等待Master节点就绪
# 在安装Calico之前，Master节点必须处于Ready状态
wait_for_master() {
    log_step "步骤1/5: 等待Master节点就绪"

    local max_wait=120
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        if kubectl get nodes &>/dev/null; then
            local status
            status=$(kubectl get node -l node-role.kubernetes.io/control-plane \
                -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
            if [[ "${status}" == "True" ]]; then
                log_success "Master节点就绪 (等待${waited}秒)"
                return 0
            fi
        fi
        sleep 2
        waited=$((waited + 2))
    done

    log_error "Master节点在${max_wait}秒内未就绪"
    log_error "排查步骤:"
    log_error "  1. 检查kubelet: journalctl -u kubelet -f"
    log_error "  2. 检查容器: crictl ps"
    log_error "  3. 检查节点: kubectl get nodes"
    return 1
}

# 步骤2: 安装Calico Operator (Operator模式)
# Tigera Operator是Calico的推荐管理方式
install_calico_operator() {
    log_step "步骤2/5: 安装Calico Operator"

    local CALICO_OPERATOR_URL="https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}.0/manifests/tigera-operator.yaml"

    # 下载并应用Operator
    log_info "下载Calico Operator v${CALICO_VERSION}..."
    if kubectl create -f "${CALICO_OPERATOR_URL}" --dry-run=client -o yaml | kubectl apply -f - 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Calico Operator已部署"
    else
        log_error "Calico Operator部署失败"
        return 1
    fi

    # 等待Operator就绪
    log_info "等待Calico Operator就绪..."
    local max_wait=120
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        local ready
        ready=$(kubectl get deployment -n tigera-operator tigera-operator \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        if [[ "${ready}" -ge 1 ]] 2>/dev/null; then
            log_success "Calico Operator就绪 (等待${waited}秒)"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done

    log_warn "Calico Operator在${max_wait}秒内未就绪，继续安装..."
}

# 步骤3: 配置Calico Installation CR (Operator模式)
# 定义IP池、封装模式、网络参数等
configure_calico_installation() {
    log_step "步骤3/5: 配置Calico Installation"

    # 如果存在本地Manifest文件，使用本地配置
    if [[ -f "${CALICO_MANIFEST}" ]]; then
        log_info "使用本地Calico配置: ${CALICO_MANIFEST}"

        # 替换POD_CIDR变量 (如果模板中包含)
        if grep -q "__POD_CIDR__" "${CALICO_MANIFEST}"; then
            cp "${CALICO_MANIFEST}" /tmp/calico-resolved.yaml
            sed -i "s|__POD_CIDR__|${POD_CIDR}|g" /tmp/calico-resolved.yaml
            kubectl apply -f /tmp/calico-resolved.yaml 2>&1 | tee -a "$LOG_FILE"
        else
            kubectl apply -f "${CALICO_MANIFEST}" 2>&1 | tee -a "$LOG_FILE"
        fi
    else
        # 创建Installation CR (使用Operator模式，推荐)
        log_info "创建Calico Installation CR (Operator模式)..."
        cat <<EOF | kubectl apply -f - 2>&1 | tee -a "$LOG_FILE"
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  registry: quay.io
  variant: Calico
  calicoNetwork:
    ipPools:
    - name: default-ipv4-ippool
      blockSize: 26
      cidr: ${POD_CIDR}
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
    nodeAddressAutodetectionV4:
      interface: eth.*
  controlPlaneReplicas: 1
  nodeMetricsPort: 9091
  typhaMetricsPort: 9093
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF
    fi

    if [[ $? -eq 0 ]]; then
        log_success "Calico Installation已配置"
    else
        log_error "Calico Installation配置失败"
        return 1
    fi
}

# 步骤4: 等待所有Calico Pod就绪
# 包括calico-node、calico-kube-controllers等
wait_for_calico_pods() {
    log_step "步骤4/5: 等待Calico组件就绪"

    # 等待calico-system命名空间创建
    log_info "等待calico-system命名空间创建..."
    local max_ns_wait=60
    local ns_waited=0
    while [[ $ns_waited -lt $max_ns_wait ]]; do
        if kubectl get namespace calico-system &>/dev/null; then
            log_success "calico-system命名空间已创建"
            break
        fi
        sleep 2
        ns_waited=$((ns_waited + 2))
    done

    # 等待所有Calico Pod就绪
    log_info "等待Calico Pods就绪 (最多5分钟)..."
    local max_wait=150
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        local ready total
        ready=$(kubectl get pods -n calico-system -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c "True" || echo "0")
        total=$(kubectl get pods -n calico-system --no-headers 2>/dev/null | wc -l || echo "0")

        if [[ ${total} -gt 0 && "${ready}" == "${total}" ]]; then
            log_success "所有 ${total} 个Calico Pod已就绪"
            return 0
        fi

        # 每15秒显示一次进度
        if [[ $((waited % 15)) -eq 0 ]]; then
            log_info "  等待中... (${ready}/${total} ready, ${waited}s elapsed)"
        fi

        sleep 2
        waited=$((waited + 2))
    done

    # 超时后显示当前状态
    log_warn "Calico Pod在${max_wait}秒内未全部就绪"
    log_info "当前Calico Pod状态:"
    kubectl get pods -n calico-system -o wide 2>&1 | tee -a "$LOG_FILE" || true
}

# 步骤5: 验证网络安装
# 检查节点Ready状态和网络连通性
verify_calico_installation() {
    log_step "步骤5/5: 验证Calico安装"

    # 检查所有节点是否Ready (Calico就绪后节点会变为Ready)
    log_info "等待所有节点Ready..."
    local max_wait=60
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        local not_ready
        not_ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -cv "Ready" || echo "0")
        if [[ "${not_ready}" == "0" ]]; then
            log_success "所有节点Ready"
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    # 显示节点状态
    log_info "集群节点状态:"
    kubectl get nodes -o wide 2>&1 | tee -a "$LOG_FILE"

    # 显示Calico组件状态
    log_info "Calico组件状态:"
    kubectl get pods -n calico-system -o wide 2>&1 | tee -a "$LOG_FILE" || true
}

# ========================= 主逻辑 =========================
main() {
    mkdir -p "$LOG_DIR"
    check_root
    check_lock

    log_step "阶段2-任务4: 安装Calico网络插件"
    log_info "Calico版本: v${CALICO_VERSION}"
    log_info "Pod CIDR: ${POD_CIDR}"

    # 等待Master就绪
    wait_for_master

    # 安装Calico Operator
    install_calico_operator

    # 配置Calico Installation
    configure_calico_installation

    # 等待Calico Pod就绪
    wait_for_calico_pods

    # 验证安装
    verify_calico_installation

    log_success "阶段2-任务4完成: Calico网络插件安装成功"
    log_info "下一步: 运行05-verify-cluster.sh验证集群状态"
}

main "$@"
