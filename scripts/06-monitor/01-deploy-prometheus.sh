#!/usr/bin/env bash
# 部署 Prometheus via kube-prometheus-stack
set -euo pipefail

RELEASE_NAME="kube-prometheus-stack"
NAMESPACE="monitoring"
CHART="prometheus-community/kube-prometheus-stack"
VALUES_FILE="$(dirname "$0")/../../configs/prometheus/prometheus.yaml"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [Prometheus] $*"; }

log "安装 kube-prometheus-stack..."

helm upgrade --install "$RELEASE_NAME" "$CHART" \
  --namespace "$NAMESPACE" \
  --values "$VALUES_FILE" \
  --set prometheus.prometheusSpec.retention=30d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=local-path \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=50Gi \
  --set grafana.adminPassword=admin123 \
  --timeout 10m \
  --wait

log "Prometheus 部署完成"
