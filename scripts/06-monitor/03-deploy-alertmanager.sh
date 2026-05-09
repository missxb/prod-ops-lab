#!/usr/bin/env bash
# 配置 Alertmanager
set -euo pipefail

NAMESPACE="monitoring"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [Alertmanager] $*"; }

log "应用 Alertmanager 配置..."
kubectl apply -f "$(dirname "$0")/../../configs/prometheus/alertmanager.yaml" -n "$NAMESPACE" 2>/dev/null || true

# 重启 Alertmanager 使配置生效
kubectl rollout restart statefulset/kube-prometheus-stack-alertmanager -n "$NAMESPACE" 2>/dev/null || true

log "Alertmanager 配置完成"
