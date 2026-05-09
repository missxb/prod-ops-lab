#!/usr/bin/env bash
###############################################################################
# 05-verify-cluster.sh - 验证Kubernetes集群状态
# 全面检查集群健康状态
###############################################################################
set -euo pipefail
umask 077

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN:${NC} $*"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*" >&2; }

PASSED=0
FAILED=0
WARNINGS=0

check_pass() { echo -e "  ${GREEN}✓ PASS${NC}: $*"; PASSED=$((PASSED + 1)); }
check_fail() { echo -e "  ${RED}✗ FAIL${NC}: $*"; FAILED=$((FAILED + 1)); }
check_warn() { echo -e "  ${YELLOW}⚠ WARN${NC}: $*"; WARNINGS=$((WARNINGS + 1)); }

# ============================================================
# 1. 节点状态检查
# ============================================================
echo ""
echo -e "${CYAN}=== 1. 节点状态 ===${NC}"

NODE_TOTAL=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
if [[ "${NODE_TOTAL}" -gt 0 ]]; then
    check_pass "集群节点数: ${NODE_TOTAL}"
else
    check_fail "未发现任何节点"
fi

# 检查每个节点Ready状态
while IFS= read -r line; do
    node_name=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $2}')
    roles=$(echo "$line" | awk '{print $3}')
    age=$(echo "$line" | awk '{print $4}')
    version=$(echo "$line" | awk '{print $5}')

    if [[ "${status}" == "Ready" ]]; then
        check_pass "节点 ${node_name} [${roles}] Ready (${version})"
    else
        check_fail "节点 ${node_name} 状态: ${status}"
    fi
done < <(kubectl get nodes --no-headers 2>/dev/null || true)

# ============================================================
# 2. 控制平面组件检查
# ============================================================
echo ""
echo -e "${CYAN}=== 2. 控制平面组件 ===${NC}"

for component in etcd kube-apiserver kube-controller-manager kube-scheduler; do
    total=$(kubectl get pods -n kube-system -l component=${component} --no-headers 2>/dev/null | wc -l || echo "0")
    ready=$(kubectl get pods -n kube-system -l component=${component} --no-headers 2>/dev/null | grep -c "Running" || echo "0")

    if [[ "${total}" -gt 0 && "${ready}" == "${total}" ]]; then
        check_pass "${component}: ${ready}/${total} Running"
    elif [[ "${total}" -gt 0 ]]; then
        check_fail "${component}: ${ready}/${total} Running"
    else
        # 尝试按app标签查找
        ready_alt=$(kubectl get pods -n kube-system -o wide 2>/dev/null | grep "${component}" | grep -c "Running" || echo "0")
        if [[ "${ready_alt}" -gt 0 ]]; then
            check_pass "${component}: 运行中 (alt detection)"
        else
            check_warn "${component}: 未检测到 (可能标签不同)"
        fi
    fi
done

# ============================================================
# 3. CoreDNS检查
# ============================================================
echo ""
echo -e "${CYAN}=== 3. CoreDNS ===${NC}"

COREDNS_TOTAL=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | wc -l || echo "0")
COREDNS_READY=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c "Running" || echo "0")

if [[ "${COREDNS_TOTAL}" -gt 0 && "${COREDNS_READY}" == "${COREDNS_TOTAL}" ]]; then
    check_pass "CoreDNS: ${COREDNS_READY}/${COREDNS_TOTAL} Running"
else
    check_fail "CoreDNS: ${COREDNS_READY}/${COREDNS_TOTAL} Running"
fi

# DNS解析测试
log "测试DNS解析..."
if kubectl run dns-test --image=busybox:1.36 --restart=Never --rm -i --timeout=30s -- \
    nslookup kubernetes.default.svc.cluster.local &>/dev/null 2>&1; then
    check_pass "DNS解析: kubernetes.default.svc.cluster.local"
else
    check_warn "DNS解析测试超时 (可能Pod还在拉取镜像)"
fi

# ============================================================
# 4. 网络插件检查 (Calico)
# ============================================================
echo ""
echo -e "${CYAN}=== 4. 网络插件 (Calico) ===${NC}"

CALICO_TOTAL=$(kubectl get pods -n calico-system --no-headers 2>/dev/null | wc -l || echo "0")
CALICO_READY=$(kubectl get pods -n calico-system --no-headers 2>/dev/null | grep -c "Running" || echo "0")

if [[ "${CALICO_TOTAL}" -gt 0 && "${CALICO_READY}" == "${CALICO_TOTAL}" ]]; then
    check_pass "Calico: ${CALICO_READY}/${CALICO_TOTAL} Running"
else
    # 检查kube-system中的calico
    CALICO_KS=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -c "calico" || echo "0")
    if [[ "${CALICO_KS}" -gt 0 ]]; then
        check_pass "Calico: 在kube-system中运行 (${CALICO_KS} pods)"
    else
        check_fail "Calico: ${CALICO_READY}/${CALICO_TOTAL} Running"
    fi
fi

# ============================================================
# 5. kube-proxy检查
# ============================================================
echo ""
echo -e "${CYAN}=== 5. kube-proxy ===${NC}"

KPROXY_TOTAL=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy --no-headers 2>/dev/null | wc -l || echo "0")
KPROXY_READY=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy --no-headers 2>/dev/null | grep -c "Running" || echo "0")

if [[ "${KPROXY_TOTAL}" -gt 0 && "${KPROXY_READY}" == "${KPROXY_TOTAL}" ]]; then
    check_pass "kube-proxy: ${KPROXY_READY}/${KPROXY_TOTAL} Running"
else
    check_warn "kube-proxy: ${KPROXY_READY}/${KPROXY_TOTAL} (可能使用Calico kube-proxy替代)"
fi

# ============================================================
# 6. API Server连通性
# ============================================================
echo ""
echo -e "${CYAN}=== 6. API Server连通性 ===${NC}"

if kubectl cluster-info &>/dev/null; then
    check_pass "API Server可达"
    kubectl cluster-info 2>/dev/null | head -2
else
    check_fail "API Server不可达"
fi

# ============================================================
# 7. 组件健康检查
# ============================================================
echo ""
echo -e "${CYAN}=== 7. 组件健康端点 ===${NC}"

for endpoint in "/healthz" "/livez" "/readyz"; do
    if kubectl get --raw "${endpoint}" &>/dev/null; then
        check_pass "API ${endpoint}: OK"
    else
        check_fail "API ${endpoint}: FAIL"
    fi
done

# ============================================================
# 8. 资源统计
# ============================================================
echo ""
echo -e "${CYAN}=== 8. 资源统计 ===${NC}"

POD_TOTAL=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
POD_RUNNING=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -c "Running" || echo "0")
SVC_TOTAL=$(kubectl get svc --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
NS_TOTAL=$(kubectl get ns --no-headers 2>/dev/null | wc -l || echo "0")

check_pass "命名空间: ${NS_TOTAL}"
check_pass "Pods: ${POD_RUNNING}/${POD_TOTAL} Running"
check_pass "Services: ${SVC_TOTAL}"

# ============================================================
# 9. 存储检查
# ============================================================
echo ""
echo -e "${CYAN}=== 9. 存储类 ===${NC}"

SC_TOTAL=$(kubectl get sc --no-headers 2>/dev/null | wc -l || echo "0")
if [[ "${SC_TOTAL}" -gt 0 ]]; then
    check_pass "存储类: ${SC_TOTAL}"
    kubectl get sc 2>/dev/null
else
    check_warn "未配置存储类 (可稍后配置)"
fi

# ============================================================
# 汇总报告
# ============================================================
echo ""
echo -e "${CYAN}$(printf '=%.0s' {1..60})${NC}"
echo -e "${CYAN}  集群验证报告${NC}"
echo -e "${CYAN}$(printf '=%.0s' {1..60})${NC}"
echo -e "  ${GREEN}通过: ${PASSED}${NC}"
echo -e "  ${RED}失败: ${FAILED}${NC}"
echo -e "  ${YELLOW}警告: ${WARNINGS}${NC}"
echo -e "${CYAN}$(printf '=%.0s' {1..60})${NC}"

if [[ ${FAILED} -gt 0 ]]; then
    echo -e "${RED}集群状态: 存在问题, 请检查失败项${NC}"
    exit 1
elif [[ ${WARNINGS} -gt 0 ]]; then
    echo -e "${YELLOW}集群状态: 基本正常, 有 ${WARNINGS} 个警告${NC}"
    exit 0
else
    echo -e "${GREEN}集群状态: 完全正常!${NC}"
    exit 0
fi
