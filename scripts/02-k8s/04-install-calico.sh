#!/usr/bin/env bash
###############################################################################
# 04-install-calico.sh - 安装 Calico 网络插件
# Calico v3.26.x | 支持 Pod CIDR 配置
###############################################################################
set -euo pipefail
umask 077

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN:${NC} $*"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*" >&2; }

trap 'err "Calico安装失败 (行 $LINENO)"; exit 1' ERR

CALICO_VERSION="${CALICO_VERSION:-3.26}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
CALICO_MANIFEST="${CALICO_MANIFEST:-/tmp/calico.yaml}"

log "安装 Calico v${CALICO_VERSION}"
log "Pod CIDR: ${POD_CIDR}"

# ============================================================
# 1. 等待Master就绪
# ============================================================
log "步骤1: 等待Master节点就绪..."
for i in $(seq 1 120); do
    if kubectl get nodes &>/dev/null; then
        local status
        status=$(kubectl get node -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [[ "${status}" == "True" ]]; then
            log "Master节点就绪"
            break
        fi
    fi
    if [[ $i -eq 120 ]]; then
        err "Master节点120秒内未就绪"
        exit 1
    fi
    sleep 1
done

# ============================================================
# 2. 安装 Calico operator
# ============================================================
log "步骤2: 安装 Calico Operator..."

CALICO_OPERATOR_URL="https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}.0/manifests/tigera-operator.yaml"

kubectl create -f "${CALICO_OPERATOR_URL}" --dry-run=client -o yaml | kubectl apply -f -

log "等待 Calico Operator 就绪..."
for i in $(seq 1 120); do
    if kubectl get deployment -n tigera-operator tigera-operator -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -qE "^[1-9]"; then
        log "Calico Operator 就绪"
        break
    fi
    if [[ $i -eq 120 ]]; then
        warn "Calico Operator 120秒内未就绪, 继续安装..."
    fi
    sleep 1
done

# ============================================================
# 3. 配置 Calico Installation CR
# ============================================================
log "步骤3: 配置 Calico Installation..."

# 从本地配置文件安装 或 创建Installation CR
if [[ -f "${CALICO_MANIFEST}" ]]; then
    log "使用本地Calico配置: ${CALICO_MANIFEST}"
    # 替换POD_CIDR变量
    if grep -q "__POD_CIDR__" "${CALICO_MANIFEST}"; then
        cp "${CALICO_MANIFEST}" /tmp/calico-resolved.yaml
        sed -i "s|__POD_CIDR__|${POD_CIDR}|g" /tmp/calico-resolved.yaml
        kubectl apply -f /tmp/calico-resolved.yaml
    else
        kubectl apply -f "${CALICO_MANIFEST}"
    fi
else
    # 创建 Installation CR (使用operator模式, 推荐)
    log "创建 Calico Installation CR..."
    cat <<EOF | kubectl apply -f -
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

# ============================================================
# 4. 等待Calico Pod就绪
# ============================================================
log "步骤4: 等待Calico组件就绪..."

# 等待calico-system命名空间创建
for i in $(seq 1 60); do
    if kubectl get namespace calico-system &>/dev/null; then
        break
    fi
    sleep 2
done

# 等待所有calico pod就绪
log "等待Calico Pods就绪 (最多5分钟)..."
for i in $(seq 1 150); do
    local ready total
    ready=$(kubectl get pods -n calico-system -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c "True" || echo "0")
    total=$(kubectl get pods -n calico-system --no-headers 2>/dev/null | wc -l || echo "0")

    if [[ ${total} -gt 0 && "${ready}" == "${total}" ]]; then
        log "所有 ${total} 个Calico Pod已就绪"
        break
    fi

    if [[ $((i % 15)) -eq 0 ]]; then
        log "  等待中... (${ready}/${total} ready)"
    fi

    if [[ $i -eq 150 ]]; then
        warn "部分Calico Pod可能未就绪, 建议稍后检查"
        kubectl get pods -n calico-system -o wide
    fi
    sleep 2
done

# ============================================================
# 5. 验证网络
# ============================================================
log "步骤5: 验证Calico安装..."

# 检查节点是否Ready (Calico就绪后节点会变为Ready)
for i in $(seq 1 60); do
    local not_ready
    not_ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -cv "Ready" || echo "0")
    if [[ "${not_ready}" == "0" ]]; then
        log "所有节点Ready"
        break
    fi
    sleep 2
done

log "节点状态:"
kubectl get nodes -o wide

log "Calico安装完成"
