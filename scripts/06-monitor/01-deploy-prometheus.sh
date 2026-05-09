#!/usr/bin/env bash
###############################################################################
# 部署 Prometheus via kube-prometheus-stack
#
# 功能:
#   - 通过 Helm 部署 kube-prometheus-stack
#   - 配置 Prometheus 指标采集 (30天保留)
#   - 配置持久化存储 (50Gi)
#   - 集成 Grafana 仪表盘
#
# 使用示例:
#   ./01-deploy-prometheus.sh                     # 使用默认配置
#   helm upgrade --install kube-prometheus-stack   # 手动调整参数
#
# 配置文件:
#   configs/prometheus/prometheus.yaml (Helm values)
###############################################################################
set -euo pipefail

RELEASE_NAME="kube-prometheus-stack"
NAMESPACE="monitoring"
CHART="prometheus-community/kube-prometheus-stack"
VALUES_FILE="$(dirname "$0")/../../configs/prometheus/prometheus.yaml"

# ===== 颜色与日志 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()      { echo -e "${BLUE}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') [Prometheus] $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') [Prometheus] $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') [Prometheus] $*"; }
log_error(){ echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') [Prometheus] $*"; }

# ===== 前置检查 =====
log "检查 Prometheus 部署前置条件..."

# 验证命名空间存在
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    log_error "命名空间 $NAMESPACE 不存在，请先创建"
    exit 1
fi
log_ok "命名空间 $NAMESPACE 存在"

# 验证 Helm 仓库
if ! helm repo list 2>/dev/null | grep -q "prometheus-community"; then
    log "添加 Prometheus Community Helm 仓库..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || {
        log_error "添加 Helm 仓库失败"
        exit 1
    }
fi
log_ok "Helm 仓库已配置"

# 验证 values 文件存在
if [[ ! -f "$VALUES_FILE" ]]; then
    log_warn "Values 文件不存在: $VALUES_FILE，使用默认配置"
fi

# ===== 部署 Prometheus =====
log "安装 kube-prometheus-stack..."
log "  Chart: $CHART"
log "  Namespace: $NAMESPACE"
log "  保留策略: 30天"
log "  存储: 50Gi (local-path)"

helm upgrade --install "$RELEASE_NAME" "$CHART" \
  --namespace "$NAMESPACE" \
  --values "$VALUES_FILE" \
  --set prometheus.prometheusSpec.retention=30d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=local-path \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=50Gi \
  --set grafana.adminPassword=admin123 \
  --timeout 10m \
  --wait 2>&1

# ===== 部署验证 =====
log "验证 Prometheus 部署状态..."

# 检查 Helm release 状态
RELEASE_STATUS=$(helm status "$RELEASE_NAME" -n "$NAMESPACE" -o json 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
if [[ "$RELEASE_STATUS" == "deployed" ]]; then
    log_ok "Helm Release 状态: deployed"
else
    log_warn "Helm Release 状态: $RELEASE_STATUS"
fi

# 检查 Prometheus Pod
PROM_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | wc -l)
if [[ "$PROM_PODS" -gt 0 ]]; then
    log_ok "Prometheus Pods: $PROM_PODS 个运行中"
else
    log_warn "未找到 Prometheus Pods"
fi

# 检查 Grafana Pod
GRAFANA_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=grafana --no-headers 2>/dev/null | wc -l)
if [[ "$GRAFANA_PODS" -gt 0 ]]; then
    log_ok "Grafana Pods: $GRAFANA_PODS 个运行中"
else
    log_warn "未找到 Grafana Pods"
fi

log_ok "Prometheus 部署完成"
