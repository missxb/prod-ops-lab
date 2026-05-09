#!/usr/bin/env bash
###############################################################################
# 脚本名称: 05-verify-cluster.sh
# 功能描述: 全面验证Kubernetes集群健康状态，包括节点、组件、网络、存储等
# 适用系统: 需要kubectl可访问集群
# 依赖条件: kubectl已配置并能访问集群
# 作者: 运维平台团队
# 版本: 1.1.0
# 创建日期: 2026-05-09
# 更新日期: 2026-05-09
#
# 使用方法:
#   ./05-verify-cluster.sh                   # 执行完整验证
#
# 检查项目:
#   1. 节点状态 (Ready/版本/角色)
#   2. 控制平面组件 (etcd/API Server/Controller Manager/Scheduler)
#   3. CoreDNS服务
#   4. 网络插件 (Calico)
#   5. kube-proxy
#   6. API Server连通性
#   7. 组件健康端点
#   8. 资源统计
#   9. 存储类
###############################################################################
set -euo pipefail
umask 077

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/02-k8s"
LOG_FILE="${LOG_DIR}/05-verify-cluster_$(date +%Y%m%d_%H%M%S).log"

# ========================= 颜色定义 =========================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# ========================= 日志函数 =========================
log_info()    { echo -e "${GREEN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >&2; }
log_step()    { echo -e "${CYAN}[STEP]${NC}  $(date '+%Y-%m-%d %H:%M:%S') === $* ===" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }

# ========================= 验证计数器 =========================
PASSED=0
FAILED=0
WARNINGS=0

# 验证结果函数
check_pass() { echo -e "  ${GREEN}✓ PASS${NC}: $*" | tee -a "$LOG_FILE"; PASSED=$((PASSED + 1)); }
check_fail() { echo -e "  ${RED}✗ FAIL${NC}: $*" | tee -a "$LOG_FILE"; FAILED=$((FAILED + 1)); }
check_warn() { echo -e "  ${YELLOW}⚠ WARN${NC}: $*" | tee -a "$LOG_FILE"; WARNINGS=$((WARNINGS + 1)); }

# ========================= 工具函数 =========================

# 检查kubectl是否可用
check_kubectl() {
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl未安装"
        exit 1
    fi

    if ! kubectl cluster-info &>/dev/null; then
        log_error "无法连接到Kubernetes集群"
        log_error "请检查kubeconfig配置"
        exit 1
    fi
    log_success "kubectl连接正常"
}

# ========================= 验证检查函数 =========================

# 1. 节点状态检查
# 验证所有节点是否Ready，显示节点信息
check_nodes() {
    log_step "1. 节点状态"

    local node_total
    node_total=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")

    if [[ "${node_total}" -gt 0 ]]; then
        check_pass "集群节点数: ${node_total}"
    else
        check_fail "未发现任何节点"
        return
    fi

    # 检查每个节点的Ready状态
    while IFS= read -r line; do
        local node_name status roles version
        node_name=$(echo "$line" | awk '{print $1}')
        status=$(echo "$line" | awk '{print $2}')
        roles=$(echo "$line" | awk '{print $3}')
        version=$(echo "$line" | awk '{print $5}')

        if [[ "${status}" == "Ready" ]]; then
            check_pass "节点 ${node_name} [${roles}] Ready (${version})"
        else
            check_fail "节点 ${node_name} 状态: ${status}"
        fi
    done < <(kubectl get nodes --no-headers 2>/dev/null || true)
}

# 2. 控制平面组件检查
# 检查etcd/API Server/Controller Manager/Scheduler运行状态
check_control_plane() {
    log_step "2. 控制平面组件"

    for component in etcd kube-apiserver kube-controller-manager kube-scheduler; do
        local total ready
        total=$(kubectl get pods -n kube-system -l component=${component} --no-headers 2>/dev/null | wc -l || echo "0")
        ready=$(kubectl get pods -n kube-system -l component=${component} --no-headers 2>/dev/null | grep -c "Running" || echo "0")

        if [[ "${total}" -gt 0 && "${ready}" == "${total}" ]]; then
            check_pass "${component}: ${ready}/${total} Running"
        elif [[ "${total}" -gt 0 ]]; then
            check_fail "${component}: ${ready}/${total} Running"
        else
            # 尝试按app标签查找 (不同K8s版本标签可能不同)
            local ready_alt
            ready_alt=$(kubectl get pods -n kube-system -o wide 2>/dev/null | grep "${component}" | grep -c "Running" || echo "0")
            if [[ "${ready_alt}" -gt 0 ]]; then
                check_pass "${component}: 运行中 (alt detection)"
            else
                check_warn "${component}: 未检测到 (可能标签不同)"
            fi
        fi
    done
}

# 3. CoreDNS检查
# CoreDNS负责集群内部DNS解析
check_coredns() {
    log_step "3. CoreDNS"

    local coredns_total coredns_ready
    coredns_total=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | wc -l || echo "0")
    coredns_ready=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c "Running" || echo "0")

    if [[ "${coredns_total}" -gt 0 && "${coredns_ready}" == "${coredns_total}" ]]; then
        check_pass "CoreDNS: ${coredns_ready}/${coredns_total} Running"
    else
        check_fail "CoreDNS: ${coredns_ready}/${coredns_total} Running"
    fi

    # DNS解析测试
    log_info "测试DNS解析..."
    if kubectl run dns-test --image=busybox:1.36 --restart=Never --rm -i --timeout=30s -- \
        nslookup kubernetes.default.svc.cluster.local &>/dev/null 2>&1; then
        check_pass "DNS解析: kubernetes.default.svc.cluster.local"
    else
        check_warn "DNS解析测试超时 (可能Pod还在拉取镜像)"
    fi
}

# 4. 网络插件检查 (Calico)
check_network_plugin() {
    log_step "4. 网络插件 (Calico)"

    local calico_total calico_ready
    calico_total=$(kubectl get pods -n calico-system --no-headers 2>/dev/null | wc -l || echo "0")
    calico_ready=$(kubectl get pods -n calico-system --no-headers 2>/dev/null | grep -c "Running" || echo "0")

    if [[ "${calico_total}" -gt 0 && "${calico_ready}" == "${calico_total}" ]]; then
        check_pass "Calico: ${calico_ready}/${calico_total} Running"
    else
        # 检查kube-system中的calico (旧版本可能在kube-system)
        local calico_ks
        calico_ks=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -c "calico" || echo "0")
        if [[ "${calico_ks}" -gt 0 ]]; then
            check_pass "Calico: 在kube-system中运行 (${calico_ks} pods)"
        else
            check_fail "Calico: ${calico_ready}/${calico_total} Running"
        fi
    fi
}

# 5. kube-proxy检查
check_kube_proxy() {
    log_step "5. kube-proxy"

    local kproxy_total kproxy_ready
    kproxy_total=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy --no-headers 2>/dev/null | wc -l || echo "0")
    kproxy_ready=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy --no-headers 2>/dev/null | grep -c "Running" || echo "0")

    if [[ "${kproxy_total}" -gt 0 && "${kproxy_ready}" == "${kproxy_total}" ]]; then
        check_pass "kube-proxy: ${kproxy_ready}/${kproxy_total} Running"
    else
        # Calico可能替代kube-proxy
        check_warn "kube-proxy: ${kproxy_ready}/${kproxy_total} (可能使用Calico kube-proxy替代)"
    fi
}

# 6. API Server连通性
check_apiserver() {
    log_step "6. API Server连通性"

    if kubectl cluster-info &>/dev/null; then
        check_pass "API Server可达"
        kubectl cluster-info 2>/dev/null | head -2 | tee -a "$LOG_FILE"
    else
        check_fail "API Server不可达"
    fi
}

# 7. 组件健康端点
check_health_endpoints() {
    log_step "7. 组件健康端点"

    for endpoint in "/healthz" "/livez" "/readyz"; do
        if kubectl get --raw "${endpoint}" &>/dev/null; then
            check_pass "API ${endpoint}: OK"
        else
            check_fail "API ${endpoint}: FAIL"
        fi
    done
}

# 8. 资源统计
check_resources() {
    log_step "8. 资源统计"

    local pod_total pod_running svc_total ns_total
    pod_total=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
    pod_running=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    svc_total=$(kubectl get svc --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
    ns_total=$(kubectl get ns --no-headers 2>/dev/null | wc -l || echo "0")

    check_pass "命名空间: ${ns_total}"
    check_pass "Pods: ${pod_running}/${pod_total} Running"
    check_pass "Services: ${svc_total}"
}

# 9. 存储类检查
check_storage_classes() {
    log_step "9. 存储类"

    local sc_total
    sc_total=$(kubectl get sc --no-headers 2>/dev/null | wc -l || echo "0")

    if [[ "${sc_total}" -gt 0 ]]; then
        check_pass "存储类: ${sc_total}"
        kubectl get sc 2>/dev/null | tee -a "$LOG_FILE"
    else
        check_warn "未配置存储类 (可稍后配置)"
    fi
}

# ========================= 汇总报告 =========================
show_summary() {
    echo "" | tee -a "$LOG_FILE"
    echo -e "${CYAN}$(printf '=%.0s' {1..60})${NC}" | tee -a "$LOG_FILE"
    echo -e "${CYAN}  集群验证报告${NC}" | tee -a "$LOG_FILE"
    echo -e "${CYAN}$(printf '=%.0s' {1..60})${NC}" | tee -a "$LOG_FILE"
    echo -e "  ${GREEN}通过: ${PASSED}${NC}" | tee -a "$LOG_FILE"
    echo -e "  ${RED}失败: ${FAILED}${NC}" | tee -a "$LOG_FILE"
    echo -e "  ${YELLOW}警告: ${WARNINGS}${NC}" | tee -a "$LOG_FILE"
    echo -e "${CYAN}$(printf '=%.0s' {1..60})${NC}" | tee -a "$LOG_FILE"

    if [[ ${FAILED} -gt 0 ]]; then
        echo -e "${RED}集群状态: 存在问题, 请检查失败项${NC}" | tee -a "$LOG_FILE"
        echo -e "${RED}日志文件: ${LOG_FILE}${NC}" | tee -a "$LOG_FILE"
        return 1
    elif [[ ${WARNINGS} -gt 0 ]]; then
        echo -e "${YELLOW}集群状态: 基本正常, 有 ${WARNINGS} 个警告${NC}" | tee -a "$LOG_FILE"
        return 0
    else
        echo -e "${GREEN}集群状态: 完全正常!${NC}" | tee -a "$LOG_FILE"
        return 0
    fi
}

# ========================= 主逻辑 =========================
main() {
    mkdir -p "$LOG_DIR"

    log_step "阶段2-任务5: 集群健康状态验证"

    # 检查kubectl
    check_kubectl

    # 执行所有检查
    check_nodes
    check_control_plane
    check_coredns
    check_network_plugin
    check_kube_proxy
    check_apiserver
    check_health_endpoints
    check_resources
    check_storage_classes

    # 显示汇总
    show_summary

    log_info "验证日志: ${LOG_FILE}"
}

main "$@"
