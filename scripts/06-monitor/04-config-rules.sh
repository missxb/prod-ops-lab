#!/usr/bin/env bash
# 配置 Prometheus 告警规则
set -euo pipefail

NAMESPACE="monitoring"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [Rules] $*"; }

log "应用自定义告警规则..."
kubectl apply -f "$(dirname "$0")/../../configs/prometheus/alert-rules.yaml" -n "$NAMESPACE"

log "配置 ServiceMonitor 自动发现..."
cat <<'EOF' | kubectl apply -n "$NAMESPACE" -f -
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: custom-alert-rules
  labels:
    prometheus: kube-prometheus
    role: alert-rules
spec:
  groups:
    - name: node.rules
      rules:
        - alert: NodeDown
          expr: up{job="node-exporter"} == 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "节点 {{ $labels.instance }} 宕机"
            description: "节点 {{ $labels.instance }} 已超过2分钟不可达"
EOF

log "告警规则配置完成"
