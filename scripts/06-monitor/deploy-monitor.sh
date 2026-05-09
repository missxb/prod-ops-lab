#!/usr/bin/env bash
# 阶段6: 监控告警系统部署主脚本
# 使用 kube-prometheus-stack Helm Chart 部署 Prometheus + Grafana + Alertmanager
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="/tmp/deploy-monitor-$(date +%Y%m%d-%H%M%S).log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

log "========== 阶段6: 监控告警系统部署 =========="

# 检查前置条件
command -v kubectl >/dev/null || { log "ERROR: kubectl not found"; exit 1; }
command -v helm >/dev/null || { log "ERROR: helm not found"; exit 1; }

# 1. 创建监控命名空间
log "[Step 1/5] 创建监控命名空间..."
kubectl apply -f "$SCRIPT_DIR/../../manifests/monitoring/namespace.yaml"

# 2. 添加 Helm 仓库
log "[Step 2/5] 添加 Prometheus Community Helm 仓库..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update

# 3. 部署 Prometheus
log "[Step 3/5] 部署 Prometheus..."
bash "$SCRIPT_DIR/01-deploy-prometheus.sh" 2>&1 | tee -a "$LOG_FILE"

# 4. 部署 Grafana
log "[Step 4/5] 部署 Grafana..."
bash "$SCRIPT_DIR/02-deploy-grafana.sh" 2>&1 | tee -a "$LOG_FILE"

# 5. 部署 Alertmanager
log "[Step 5/5] 部署 Alertmanager..."
bash "$SCRIPT_DIR/03-deploy-alertmanager.sh" 2>&1 | tee -a "$LOG_FILE"

# 6. 配置告警规则
log "[Post-deploy] 配置告警规则..."
bash "$SCRIPT_DIR/04-config-rules.sh" 2>&1 | tee -a "$LOG_FILE"

log "========== 监控告警系统部署完成 =========="
log "访问地址:"
log "  Grafana:       kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80"
log "  Prometheus:    kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
log "  Alertmanager:  kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093"
log "日志: $LOG_FILE"
