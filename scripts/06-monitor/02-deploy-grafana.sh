#!/usr/bin/env bash
# 配置 Grafana 数据源和 Dashboard
set -euo pipefail

NAMESPACE="monitoring"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [Grafana] $*"; }

log "配置 Grafana 数据源..."
kubectl apply -f "$(dirname "$0")/../../configs/grafana/datasource.yaml" -n "$NAMESPACE" 2>/dev/null || true

log "配置 Grafana Dashboard ConfigMap..."
kubectl apply -f "$(dirname "$0")/../../configs/grafana/dashboard-configmap.yaml" -n "$NAMESPACE" 2>/dev/null || true

log "Grafana 配置完成"
log "  默认账号: admin / admin123"
