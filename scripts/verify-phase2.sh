#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# 阶段2: Kubernetes集群部署验证
# 验证项目: 节点状态、系统Pod、CoreDNS、Calico网络、kubectl操作、资源配额、网络策略
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPORT_DIR="$PROJECT_DIR/reports"
REPORT_FILE="$REPORT_DIR/verify-phase2-$(date +%Y%m%d-%H%M%S).log"
TIMESTAMP_REPORT="$REPORT_DIR/verify-phase2-$(date +%Y%m%d-%H%M%S).txt"

# 加载共享库
source "$SCRIPT_DIR/lib/common.sh"

# 初始化
common_init_verify "$PROJECT_DIR" 2

# 解析选项
show_help() {
    common_show_verify_help \
        "阶段2: Kubernetes集群部署验证" \
        "验证K8s集群状态、节点、Pod、网络、组件等" \
        "  2.1  kubectl配置检查
  2.2  节点状态检查
  2.3  系统Pod检查
  2.4  CoreDNS检查
  2.5  Calico网络插件检查
  2.6  kubelet运行状态
  2.7  集群组件检查
  2.8  资源配额检查
  2.9  网络策略检查
  2.10 Pod安全策略检查
  2.11 集群版本兼容性检查"
}
COMMON_HELP_FUNCTION=show_help
common_parse_verify_options "$@"

# ========== 开始验证 ==========
common_header "阶段2: Kubernetes集群验证"
common_info "验证时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

if ! command -v kubectl &>/dev/null; then
    common_error "kubectl 命令不可用，请先安装 Kubernetes"
    exit 1
fi

# --- 2.1 kubectl配置检查 ---
common_step "2.1 kubectl配置检查"

if kubectl cluster-info &>/dev/null; then
    common_pass "kubectl 可以连接到集群"
    K8S_VERSION=$(kubectl version --short 2>/dev/null | head -1 || echo "unknown")
    common_info_check "集群版本: $K8S_VERSION"
else
    common_fail "kubectl 无法连接到集群"
    common_error "无法连接到集群，终止后续检查"
    exit 1
fi

# --- 2.2 节点状态检查 ---
common_step "2.2 节点状态检查"

NODE_OUTPUT=$(kubectl get nodes --no-headers 2>/dev/null || echo "")
NODE_COUNT=$(echo "$NODE_OUTPUT" | grep -c . 2>/dev/null || echo "0")

if [[ $NODE_COUNT -gt 0 ]]; then
    pass "集群节点数: $NODE_COUNT"
else
    fail "未发现任何节点"
fi

# 检查每个节点是否 Ready
NOT_READY=0
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    NODE_NAME=$(echo "$line" | awk '{print $1}')
    NODE_STATUS=$(echo "$line" | awk '{print $2}')
    if [[ "$NODE_STATUS" == "Ready" ]]; then
        pass "节点 $NODE_NAME 状态: Ready"
    else
        fail "节点 $NODE_NAME 状态: $NODE_STATUS"
        NOT_READY=$((NOT_READY + 1))
    fi
done <<< "$NODE_OUTPUT"

if [[ $NOT_READY -eq 0 && $NODE_COUNT -gt 0 ]]; then
    pass "所有节点状态正常"
fi

# --- 2.3 系统Pod检查 ---
section "2.3 系统Pod检查 (kube-system)"

SYSTEM_PODS=$(kubectl get pods -n kube-system --no-headers 2>/dev/null || echo "")
SYSTEM_POD_COUNT=$(echo "$SYSTEM_PODS" | grep -c . 2>/dev/null || echo "0")

if [[ $SYSTEM_POD_COUNT -gt 0 ]]; then
    pass "系统Pod数量: $SYSTEM_POD_COUNT"
else
    fail "未发现系统Pod"
fi

CRASH_PODS=$(echo "$SYSTEM_PODS" | grep -E "CrashLoopBackOff|Error|OOMKilled" 2>/dev/null || echo "")
if [[ -z "$CRASH_PODS" ]]; then
    pass "所有系统Pod运行正常 (无CrashLoopBackOff/Error)"
else
    CRASH_COUNT=$(echo "$CRASH_PODS" | grep -c . 2>/dev/null || echo "0")
    fail "发现 $CRASH_COUNT 个异常系统Pod"
    echo "$CRASH_PODS" | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        log "${RED}    → $line${NC}"
    done
fi

# --- 2.4 CoreDNS检查 ---
section "2.4 CoreDNS检查"

COREDNS_PODS=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null || echo "")
if [[ -n "$COREDNS_PODS" ]]; then
    COREDNS_RUNNING=$(echo "$COREDNS_PODS" | grep -c "Running" 2>/dev/null || echo "0")
    COREDNS_TOTAL=$(echo "$COREDNS_PODS" | grep -c . 2>/dev/null || echo "0")
    if [[ $COREDNS_RUNNING -eq $COREDNS_TOTAL && $COREDNS_RUNNING -gt 0 ]]; then
        pass "CoreDNS Pod 运行正常 ($COREDNS_RUNNING/$COREDNS_TOTAL)"
    else
        fail "CoreDNS Pod 异常 ($COREDNS_RUNNING/$COREDNS_TOTAL 运行中)"
    fi
else
    fail "未发现 CoreDNS Pod"
fi

COREDNS_SVC=$(kubectl get svc -n kube-system kube-dns --no-headers 2>/dev/null || echo "")
if [[ -n "$COREDNS_SVC" ]]; then
    pass "CoreDNS Service 存在"
else
    fail "CoreDNS Service 不存在"
fi

# 测试DNS解析
info "测试DNS解析..."
DNS_TEST=$(kubectl run dns-test-$(date +%s) --image=busybox --rm -i --restart=Never --timeout=30s -- nslookup kubernetes.default.svc.cluster.local 2>&1 || echo "DNS_TEST_FAILED")
if echo "$DNS_TEST" | grep -q "Address" 2>/dev/null; then
    pass "DNS解析测试通过 (kubernetes.default.svc.cluster.local)"
else
    warn "DNS解析测试未通过 (可能需要等待或网络不通)"
fi

# --- 2.5 Calico网络插件检查 ---
section "2.5 Calico网络插件检查"

CALICO_PODS=$(kubectl get pods -n kube-system -l k8s-app=calico-node --no-headers 2>/dev/null || echo "")
if [[ -n "$CALICO_PODS" ]]; then
    CALICO_RUNNING=$(echo "$CALICO_PODS" | grep -c "Running" 2>/dev/null || echo "0")
    CALICO_TOTAL=$(echo "$CALICO_PODS" | grep -c . 2>/dev/null || echo "0")
    if [[ $CALICO_RUNNING -eq $CALICO_TOTAL && $CALICO_RUNNING -gt 0 ]]; then
        pass "Calico Node Pod 运行正常 ($CALICO_RUNNING/$CALICO_TOTAL)"
    else
        fail "Calico Node Pod 异常"
    fi
else
    warn "未发现 Calico Node Pod (可能使用其他CNI插件)"
fi

CALICO_KUBE_CONTROLLERS=$(kubectl get pods -n kube-system -l k8s-app=calico-kube-controllers --no-headers 2>/dev/null || echo "")
if [[ -n "$CALICO_KUBE_CONTROLLERS" ]]; then
    if echo "$CALICO_KUBE_CONTROLLERS" | grep -q "Running"; then
        pass "Calico Kube Controllers 运行正常"
    else
        warn "Calico Kube Controllers 未运行"
    fi
fi

# 检查CNI配置
CNI_PLUGINS=$(ls /etc/cni/net.d/ 2>/dev/null || echo "")
if [[ -n "$CNI_PLUGINS" ]]; then
    pass "CNI插件配置文件存在: $CNI_PLUGINS"
else
    warn "/etc/cni/net.d/ 目录为空或不存在"
fi

# --- 2.6 kubelet检查 ---
section "2.6 kubelet运行状态"

if systemctl is-active kubelet &>/dev/null; then
    pass "kubelet 服务运行中"
else
    fail "kubelet 服务未运行"
fi

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
    pass "kubelet配置文件存在"
else
    fail "kubelet配置文件不存在: /etc/kubernetes/kubelet.conf"
fi

# --- 2.7 集群组件检查 ---
section "2.7 集群组件检查"

for component in etcd apiserver controller-manager scheduler; do
    POD_STATUS=$(kubectl get pods -n kube-system -l component=$component --no-headers 2>/dev/null || echo "")
    if [[ -n "$POD_STATUS" ]]; then
        if echo "$POD_STATUS" | grep -q "Running"; then
            pass "kube-$component 运行正常"
        else
            fail "kube-$component 未正常运行"
        fi
    else
        # 非托管模式(etcd静态部署等)
        if systemctl is-active "kube-$component" &>/dev/null; then
            pass "kube-$component 以systemd服务运行"
        else
            warn "kube-$component 状态未知"
        fi
    fi
done

# --- 2.8 资源配额检查 ---
common_step "2.8 资源配额检查"

QUOTA_ALL=$(kubectl get resourcequotas --all-namespaces --no-headers 2>/dev/null || echo "")
QUOTA_COUNT=$(echo "$QUOTA_ALL" | grep -c . 2>/dev/null || echo "0")

if [[ $QUOTA_COUNT -gt 0 ]]; then
    common_pass "ResourceQuota 数量: $QUOTA_COUNT"
else
    common_info_check "未配置ResourceQuota (可选)"
fi

LIMIT_RANGE_ALL=$(kubectl get limitranges --all-namespaces --no-headers 2>/dev/null || echo "")
LIMIT_RANGE_COUNT=$(echo "$LIMIT_RANGE_ALL" | grep -c . 2>/dev/null || echo "0")
if [[ $LIMIT_RANGE_COUNT -gt 0 ]]; then
    common_pass "LimitRange 数量: $LIMIT_RANGE_COUNT"
else
    common_info_check "未配置LimitRange (可选)"
fi

# --- 2.9 网络策略检查 ---
common_step "2.9 网络策略检查"

NP_ALL=$(kubectl get networkpolicies --all-namespaces --no-headers 2>/dev/null || echo "")
NP_COUNT=$(echo "$NP_ALL" | grep -c . 2>/dev/null || echo "0")

if [[ $NP_COUNT -gt 0 ]]; then
    common_pass "NetworkPolicy 数量: $NP_COUNT"
else
    common_info_check "未配置NetworkPolicy (建议生产环境配置)"
fi

# 检查default命名空间是否有拒绝策略
DEFAULT_NP=$(kubectl get networkpolicy -n default --no-headers 2>/dev/null || echo "")
if echo "$DEFAULT_NP" | grep -q "deny-all\|default-deny"; then
    common_pass "default命名空间已配置默认拒绝策略"
else
    common_info_check "default命名空间未配置默认拒绝策略"
fi

# --- 2.10 Pod安全策略检查 ---
common_step "2.10 Pod安全策略检查"

# 检查Pod Security Admission (PSA)
PSA_NS=$(kubectl get namespace kube-system -o jsonpath='{.metadata.labels}' 2>/dev/null || echo "")
if echo "$PSA_NS" | grep -q "pod-security.kubernetes.io"; then
    common_pass "Pod Security Admission 已配置"
else
    common_info_check "Pod Security Admission 未配置"
fi

# ========== 验证报告 ==========
section "验证汇总"

echo ""
log "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
log "${CYAN}║          阶段2: K8s集群验证报告                ║${NC}"
log "${CYAN}╠══════════════════════════════════════════════════╣${NC}"
log "${CYAN}║${NC} 总检查项:  ${TOTAL_COUNT}                                    ${CYAN}║${NC}"
log "${GREEN}║${NC} 通过:      ${PASS_COUNT}                                    ${GREEN}║${NC}"
log "${RED}║${NC} 失败:      ${FAIL_COUNT}                                    ${RED}║${NC}"
log "${YELLOW}║${NC} 警告:      ${WARN_COUNT}                                    ${YELLOW}║${NC}"
log "${CYAN}╠══════════════════════════════════════════════════╣${NC}"

if [[ $FAIL_COUNT -eq 0 ]]; then
    if [[ $WARN_COUNT -eq 0 ]]; then
        log "${GREEN}║  结果: ✓ 全部通过                               ║${NC}"
    else
        log "${YELLOW}║  结果: △ 通过(有警告)                           ║${NC}"
    fi
else
    log "${RED}║  结果: ✗ 存在失败项                             ║${NC}"
fi

log "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
log ""
log "报告已保存: $REPORT_FILE"

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
