#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# 阶段2: Kubernetes集群部署验证
# 验证项目: 节点状态、系统Pod、CoreDNS、Calico网络、kubectl操作
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPORT_DIR="$PROJECT_DIR/reports"
REPORT_FILE="$REPORT_DIR/verify-phase2-$(date +%Y%m%d-%H%M%S).log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
TOTAL_COUNT=0

mkdir -p "$REPORT_DIR"

log() { local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"; echo -e "$msg"; echo "$msg" >> "$REPORT_FILE"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); TOTAL_COUNT=$((TOTAL_COUNT + 1)); log "${GREEN}[PASS]${NC} $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); TOTAL_COUNT=$((TOTAL_COUNT + 1)); log "${RED}[FAIL]${NC} $1"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); TOTAL_COUNT=$((TOTAL_COUNT + 1)); log "${YELLOW}[WARN]${NC} $1"; }
info() { log "${BLUE}[INFO]${NC} $1"; }
section() { echo ""; log "${CYAN}========== $1 ==========${NC}"; }

# ========== 前置检查 ==========
if ! command -v kubectl &>/dev/null; then
    echo -e "${RED}错误: kubectl 命令不可用，请先安装 Kubernetes${NC}"
    exit 1
fi

# ========== 开始验证 ==========
section "阶段2: Kubernetes集群验证"

# --- 2.1 kubectl配置检查 ---
section "2.1 kubectl配置检查"

if kubectl cluster-info &>/dev/null; then
    pass "kubectl 可以连接到集群"
    K8S_VERSION=$(kubectl version --short 2>/dev/null | head -1 || echo "unknown")
    info "集群版本: $K8S_VERSION"
else
    fail "kubectl 无法连接到集群"
    echo -e "${RED}无法连接到集群，终止后续检查${NC}"
    exit 1
fi

# --- 2.2 节点状态检查 ---
section "2.2 节点状态检查"

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
