#!/usr/bin/env bash
###############################################################################
# 脚本名称: 06-verify-coredns.sh
# 功能描述: 全面验证CoreDNS服务的健康状态和DNS解析功能
# 适用系统: 需要kubectl可访问集群
# 依赖条件: kubectl已配置并能访问集群
# 作者: 运维平台团队
# 版本: 1.1.0
# 创建日期: 2026-05-10
# 更新日期: 2026-05-10
#
# 使用方法:
#   ./06-verify-coredns.sh                   # 执行完整CoreDNS验证
#
# 检查项目:
#   1. CoreDNS Pod运行状态
#   2. CoreDNS ConfigMap存在性
#   3. CoreDNS Service ClusterIP
#   4. 集群内DNS解析测试 (busybox nslookup)
#   5. CoreDNS日志健康检查
#   6. DNS解析外部域名测试
###############################################################################
set -euo pipefail
umask 077

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/02-k8s"
LOG_FILE="${LOG_DIR}/06-verify-coredns_$(date +%Y%m%d_%H%M%S).log"
LOCK_FILE="/var/lock/06-verify-coredns.lock"

# 测试Pod名称
DNS_TEST_POD="dns-test-coredns-$(date +%s)"

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

check_pass() { echo -e "  ${GREEN}✓ PASS${NC}: $*" | tee -a "$LOG_FILE"; PASSED=$((PASSED + 1)); }
check_fail() { echo -e "  ${RED}✗ FAIL${NC}: $*" | tee -a "$LOG_FILE"; FAILED=$((FAILED + 1)); }
check_warn() { echo -e "  ${YELLOW}⚠ WARN${NC}: $*" | tee -a "$LOG_FILE"; WARNINGS=$((WARNINGS + 1)); }

# ========================= 错误处理 =========================

# 清理测试Pod
cleanup_test_pod() {
    if kubectl get pod "$DNS_TEST_POD" -n default &>/dev/null 2>&1; then
        kubectl delete pod "$DNS_TEST_POD" -n default --ignore-not-found &>/dev/null || true
        log_info "已清理测试Pod: ${DNS_TEST_POD}"
    fi
}

cleanup() {
    local exit_code=$?
    cleanup_test_pod
    rm -f "$LOCK_FILE"
    if [[ $exit_code -ne 0 ]]; then
        log_error "脚本执行失败，退出码: $exit_code"
    fi
    return $exit_code
}
trap 'log_error "脚本执行出错，行号: ${LINENO}"' ERR
trap cleanup EXIT
trap 'log_error "收到中断信号，正在清理..."; exit 130' INT TERM

# ========================= 帮助信息 =========================
show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --help     显示此帮助信息"
    echo ""
    echo "功能:"
    echo "  全面验证CoreDNS服务的健康状态和DNS解析功能"
    echo ""
    echo "检查项目:"
    echo "  1. CoreDNS Pod运行状态"
    echo "  2. CoreDNS ConfigMap存在性"
    echo "  3. CoreDNS Service ClusterIP"
    echo "  4. 集群内DNS解析测试 (busybox nslookup)"
    echo "  5. CoreDNS日志健康检查"
    echo "  6. DNS解析外部域名测试"
}

# ========================= 工具函数 =========================

# 锁文件检查
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

# ========================= CoreDNS验证检查函数 =========================

# 1. CoreDNS Pod 运行状态
# 验证所有 CoreDNS Pod 是否处于 Running 状态
check_coredns_pods() {
    log_step "1. CoreDNS Pod 运行状态"

    # 使用标准标签 k8s-app=kube-dns 查询
    local total ready
    total=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | wc -l)
    ready=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c "Running" || echo "0")

    if [[ "$total" -eq 0 ]]; then
        check_fail "未发现CoreDNS Pod (标签 k8s-app=kube-dns)"
        return
    fi

    if [[ "$ready" -eq "$total" ]]; then
        check_pass "CoreDNS Pod: ${ready}/${total} Running"
    else
        check_fail "CoreDNS Pod: ${ready}/${total} Running"
    fi

    # 显示每个Pod的详细信息
    while IFS= read -r line; do
        local pod_name pod_status
        pod_name=$(echo "$line" | awk '{print $1}')
        pod_status=$(echo "$line" | awk '{print $3}')
        local node_name
        node_name=$(echo "$line" | awk '{print $7}')

        if [[ "$pod_status" == "Running" ]]; then
            check_pass "Pod ${pod_name} [${node_name}] - Running"
        else
            check_fail "Pod ${pod_name} [${node_name}] - ${pod_status}"
        fi
    done < <(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null || true)
}

# 2. CoreDNS ConfigMap 检查
# 验证 CoreDNS 配置文件是否存在且包含必要内容
check_coredns_configmap() {
    log_step "2. CoreDNS ConfigMap"

    # 检查 ConfigMap 是否存在
    if ! kubectl get configmap coredns -n kube-system &>/dev/null 2>&1; then
        check_fail "CoreDNS ConfigMap 'coredns' 不存在"
        return
    fi
    check_pass "CoreDNS ConfigMap 'coredns' 存在"

    # 检查 ConfigMap 数据内容
    local corefile
    corefile=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' 2>/dev/null || echo "")

    if [[ -z "$corefile" ]]; then
        check_fail "CoreDNS Corefile 为空"
        return
    fi
    check_pass "CoreDNS Corefile 内容存在"

    # 检查 Corefile 中的关键配置
    if echo "$corefile" | grep -q "kubernetes"; then
        check_pass "Corefile 包含 kubernetes 插件 (集群DNS解析)"
    else
        check_warn "Corefile 未包含 kubernetes 插件"
    fi

    if echo "$corefile" | grep -q "forward"; then
        check_pass "Corefile 包含 forward 插件 (上游DNS转发)"
    else
        check_warn "Corefile 未包含 forward 插件 (可能影响外部域名解析)"
    fi

    if echo "$corefile" | grep -q "errors"; then
        check_pass "Corefile 包含 errors 插件 (错误日志)"
    else
        check_warn "Corefile 未包含 errors 插件"
    fi

    if echo "$corefile" | grep -q "health"; then
        check_pass "Corefile 包含 health 插件 (健康检查端点)"
    else
        check_warn "Corefile 未包含 health 插件"
    fi

    log_info "Corefile 内容摘要:"
    echo "$corefile" | head -20 | tee -a "$LOG_FILE"
}

# 3. CoreDNS Service ClusterIP 检查
# 验证 CoreDNS Service 存在且分配了 ClusterIP
check_coredns_service() {
    log_step "3. CoreDNS Service ClusterIP"

    # 检查 kube-dns Service 是否存在
    if ! kubectl get service kube-dns -n kube-system &>/dev/null 2>&1; then
        check_fail "kube-dns Service 不存在"
        return
    fi
    check_pass "kube-dns Service 存在"

    # 获取 ClusterIP
    local cluster_ip
    cluster_ip=$(kubectl get service kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")

    if [[ -z "$cluster_ip" ]]; then
        check_fail "kube-dns Service 没有分配 ClusterIP"
        return
    fi

    if [[ "$cluster_ip" == "None" ]]; then
        check_warn "kube-dns Service 使用 Headless 模式 (ClusterIP: None)"
    else
        check_pass "kube-dns Service ClusterIP: ${cluster_ip}"
    fi

    # 检查端口配置
    local dns_port
    dns_port=$(kubectl get service kube-dns -n kube-system -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "")
    if [[ "$dns_port" == "53" ]]; then
        check_pass "kube-dns DNS端口: ${dns_port}"
    else
        check_warn "kube-dns DNS端口: ${dns_port:-unknown} (期望: 53)"
    fi

    # 检查 selectors
    local selectors
    selectors=$(kubectl get service kube-dns -n kube-system -o jsonpath='{.spec.selector.k8s-app}' 2>/dev/null || echo "")
    if [[ "$selectors" == "kube-dns" ]]; then
        check_pass "kube-dns selector: k8s-app=kube-dns"
    else
        check_warn "kube-dns selector 不是标准配置"
    fi

    # 显示完整Service信息
    log_info "kube-dns Service 详情:"
    kubectl get service kube-dns -n kube-system -o wide 2>/dev/null | tee -a "$LOG_FILE" || true
}

# 4. 集群内DNS解析测试
# 创建busybox Pod并测试DNS解析
check_dns_resolution() {
    log_step "4. 集群内DNS解析测试"

    log_info "创建测试Pod (busybox)..."

    # 删除可能残留的测试Pod
    cleanup_test_pod

    # 创建busybox测试Pod
    if ! kubectl run "$DNS_TEST_POD" \
        --image=busybox:1.36 \
        --restart=Never \
        --namespace=default \
        --command -- sleep 60 \
        >/dev/null 2>&1; then
        check_fail "无法创建DNS测试Pod"
        return
    fi

    log_info "等待测试Pod就绪..."
    kubectl wait --for=condition=Ready pod/"$DNS_TEST_POD" \
        -n default --timeout=60s 2>/dev/null || {
        check_fail "DNS测试Pod未在60秒内就绪"
        cleanup_test_pod
        return
    }
    check_pass "DNS测试Pod已就绪"

    # 测试1: 解析 kubernetes.default
    log_info "测试DNS解析: kubernetes.default.svc.cluster.local"
    if kubectl exec "$DNS_TEST_POD" -n default -- \
        nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; then
        check_pass "DNS解析: kubernetes.default.svc.cluster.local ✓"
    else
        check_fail "DNS解析: kubernetes.default.svc.cluster.local ✗"
    fi

    # 测试2: 解析 kube-dns Service
    log_info "测试DNS解析: kube-dns.kube-system.svc.cluster.local"
    if kubectl exec "$DNS_TEST_POD" -n default -- \
        nslookup kube-dns.kube-system.svc.cluster.local >/dev/null 2>&1; then
        check_pass "DNS解析: kube-dns.kube-system.svc.cluster.local ✓"
    else
        check_fail "DNS解析: kube-dns.kube-system.svc.cluster.local ✗"
    fi

    # 测试3: 外部域名解析
    log_info "测试外部DNS解析: www.baidu.com"
    if kubectl exec "$DNS_TEST_POD" -n default -- \
        nslookup www.baidu.com >/dev/null 2>&1; then
        check_pass "外部DNS解析: www.baidu.com ✓"
    else
        check_warn "外部DNS解析: www.baidu.com ✗ (可能受网络策略限制)"
    fi

    # 清理测试Pod
    cleanup_test_pod
    log_success "DNS解析测试完成"
}

# 5. CoreDNS 日志健康检查
# 检查CoreDNS日志中是否有错误信息
check_coredns_logs() {
    log_step "5. CoreDNS日志健康检查"

    local coredns_pods
    coredns_pods=$(kubectl get pods -n kube-system -l k8s-app=kube-dns -o name 2>/dev/null || echo "")

    if [[ -z "$coredns_pods" ]]; then
        check_fail "无法获取CoreDNS Pod列表"
        return
    fi

    while IFS= read -r pod; do
        local pod_name
        pod_name=$(basename "$pod")

        # 获取最近50行日志
        local logs
        logs=$(kubectl logs "$pod_name" -n kube-system --tail=50 2>/dev/null || echo "")

        if [[ -z "$logs" ]]; then
            check_warn "无法获取 ${pod_name} 的日志"
            continue
        fi

        # 检查错误日志
        local error_count
        error_count=$(echo "$logs" | grep -ci "error\|panic\|fatal" || echo "0")

        if [[ "$error_count" -gt 5 ]]; then
            check_fail "${pod_name}: 发现 ${error_count} 条错误日志"
            echo "$logs" | grep -i "error\|panic\|fatal" | tail -5 | tee -a "$LOG_FILE"
        elif [[ "$error_count" -gt 0 ]]; then
            check_warn "${pod_name}: 发现 ${error_count} 条错误日志 (可能正常)"
        else
            check_pass "${pod_name}: 日志健康，无错误"
        fi

        # 检查重启次数
        local restarts
        restarts=$(kubectl get pod "$pod_name" -n kube-system -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")

        if [[ "$restarts" -gt 3 ]]; then
            check_fail "${pod_name}: 容器重启次数过多 (${restarts})"
        elif [[ "$restarts" -gt 0 ]]; then
            check_warn "${pod_name}: 容器重启 ${restarts} 次"
        else
            check_pass "${pod_name}: 容器无异常重启"
        fi
    done <<< "$coredns_pods"
}

# ========================= 汇总报告 =========================
show_summary() {
    echo "" | tee -a "$LOG_FILE"
    echo -e "${CYAN}$(printf '=%.0s' {1..60})${NC}" | tee -a "$LOG_FILE"
    echo -e "${CYAN}  CoreDNS 验证报告${NC}" | tee -a "$LOG_FILE"
    echo -e "${CYAN}$(printf '=%.0s' {1..60})${NC}" | tee -a "$LOG_FILE"
    echo -e "  ${GREEN}通过: ${PASSED}${NC}" | tee -a "$LOG_FILE"
    echo -e "  ${RED}失败: ${FAILED}${NC}" | tee -a "$LOG_FILE"
    echo -e "  ${YELLOW}警告: ${WARNINGS}${NC}" | tee -a "$LOG_FILE"
    echo -e "${CYAN}$(printf '=%.0s' {1..60})${NC}" | tee -a "$LOG_FILE"

    if [[ ${FAILED} -gt 0 ]]; then
        echo -e "${RED}CoreDNS状态: 存在问题, 请检查失败项${NC}" | tee -a "$LOG_FILE"
        echo -e "${RED}日志文件: ${LOG_FILE}${NC}" | tee -a "$LOG_FILE"
        return 1
    elif [[ ${WARNINGS} -gt 0 ]]; then
        echo -e "${YELLOW}CoreDNS状态: 基本正常, 有 ${WARNINGS} 个警告${NC}" | tee -a "$LOG_FILE"
        return 0
    else
        echo -e "${GREEN}CoreDNS状态: 完全正常!${NC}" | tee -a "$LOG_FILE"
        return 0
    fi
}

# ========================= 主逻辑 =========================
main() {
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done

    mkdir -p "$LOG_DIR"
    check_lock

    log_step "阶段2-任务6: CoreDNS 验证"

    # 检查kubectl
    check_kubectl

    # 执行所有检查
    check_coredns_pods
    check_coredns_configmap
    check_coredns_service
    check_dns_resolution
    check_coredns_logs

    # 显示汇总
    show_summary

    log_info "验证日志: ${LOG_FILE}"
}

main "$@"
