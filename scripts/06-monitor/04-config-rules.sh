#!/usr/bin/env bash
###############################################################################
# 配置 Prometheus 告警规则
#
# 功能:
#   - 应用自定义告警规则 (PrometheusRule CRD)
#   - 配置节点监控规则 (NodeDown 等)
#   - 验证规则配置
#
# 使用示例:
#   ./04-config-rules.sh                      # 配置告警规则
#
# 配置文件:
#   configs/prometheus/alert-rules.yaml        (自定义告警规则)
###############################################################################
set -euo pipefail

NAMESPACE="monitoring"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ===== 颜色与日志 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()      { echo -e "${BLUE}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') [Rules] $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') [Rules] $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') [Rules] $*"; }
log_error(){ echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') [Rules] $*"; }

# ===== 前置检查 =====
log "检查告警规则配置前置条件..."

# 验证 Prometheus CRD 是否安装
if ! kubectl get crd prometheusrules.monitoring.coreos.com >/dev/null 2>&1; then
    log_error "PrometheusRule CRD 未安装，请先部署 kube-prometheus-stack"
    exit 1
fi
log_ok "PrometheusRule CRD 已安装"

# ===== 应用自定义告警规则 =====
log "应用自定义告警规则..."
ALERT_RULES_FILE="$PROJECT_ROOT/configs/prometheus/alert-rules.yaml"
if [[ -f "$ALERT_RULES_FILE" ]]; then
    kubectl apply -f "$ALERT_RULES_FILE" -n "$NAMESPACE" || {
        log_error "应用自定义告警规则失败"
        exit 1
    }
    log_ok "自定义告警规则已应用"
else
    log_warn "自定义告警规则文件不存在: $ALERT_RULES_FILE"
fi

# ===== 配置 ServiceMonitor 自动发现 =====
log "配置 PrometheusRule: 节点监控规则..."
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

# ===== 验证规则配置 =====
log "验证告警规则配置..."

# 检查 PrometheusRule 资源
RULES_COUNT=$(kubectl get prometheusrules -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
if [[ "$RULES_COUNT" -gt 0 ]]; then
    log_ok "PrometheusRule 资源: $RULES_COUNT 个"
    kubectl get prometheusrules -n "$NAMESPACE" --no-headers 2>/dev/null | while read line; do
        RULE_NAME=$(echo "$line" | awk '{print $1}')
        log "  - $RULE_NAME"
    done
else
    log_warn "未找到 PrometheusRule 资源"
fi

# 检查告警规则详情
RULE_DETAILS=$(kubectl get prometheusrules custom-alert-rules -n "$NAMESPACE" -o jsonpath='{.spec.groups[*].rules[*].alert}' 2>/dev/null || echo "")
if [[ -n "$RULE_DETAILS" ]]; then
    log_ok "已配置告警规则: $RULE_DETAILS"
else
    log_warn "无法获取告警规则详情"
fi

log_ok "告警规则配置完成"
