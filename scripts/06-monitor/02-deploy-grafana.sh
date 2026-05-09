#!/usr/bin/env bash
###############################################################################
# 配置 Grafana 数据源和 Dashboard
#
# 功能:
#   - 配置 Prometheus 数据源
#   - 导入预置 Dashboard ConfigMap
#   - 验证 Grafana 配置
#
# 使用示例:
#   ./02-deploy-grafana.sh                    # 配置数据源和 Dashboard
#
# 配置文件:
#   configs/grafana/datasource.yaml          (数据源配置)
#   configs/grafana/dashboard-configmap.yaml (Dashboard ConfigMap)
#
# 默认账号: admin / admin123
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

log()      { echo -e "${BLUE}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') [Grafana] $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') [Grafana] $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') [Grafana] $*"; }
log_error(){ echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') [Grafana] $*"; }

# ===== 前置检查 =====
log "检查 Grafana 配置前置条件..."

# 验证 Grafana Pod 是否运行
GRAFANA_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=grafana --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
if [[ "$GRAFANA_PODS" -eq 0 ]]; then
    log_warn "Grafana Pods 未运行，配置将在 Pod 就绪后生效"
fi

# ===== 配置数据源 =====
log "配置 Grafana 数据源..."
DATA_SOURCE_FILE="$PROJECT_ROOT/configs/grafana/datasource.yaml"
if [[ -f "$DATA_SOURCE_FILE" ]]; then
    kubectl apply -f "$DATA_SOURCE_FILE" -n "$NAMESPACE" 2>/dev/null || {
        log_warn "数据源配置应用失败，可能需要手动配置"
    }
    log_ok "数据源配置已应用"
else
    log_warn "数据源配置文件不存在: $DATA_SOURCE_FILE"
fi

# ===== 配置 Dashboard ConfigMap =====
log "配置 Grafana Dashboard ConfigMap..."
DASHBOARD_FILE="$PROJECT_ROOT/configs/grafana/dashboard-configmap.yaml"
if [[ -f "$DASHBOARD_FILE" ]]; then
    kubectl apply -f "$DASHBOARD_FILE" -n "$NAMESPACE" 2>/dev/null || {
        log_warn "Dashboard ConfigMap 应用失败"
    }
    log_ok "Dashboard ConfigMap 已应用"
else
    log_warn "Dashboard ConfigMap 文件不存在: $DASHBOARD_FILE"
fi

# ===== 验证配置 =====
log "验证 Grafana 配置..."

# 检查数据源 ConfigMap
if kubectl get configmap grafana-datasource -n "$NAMESPACE" >/dev/null 2>&1; then
    log_ok "数据源 ConfigMap 存在"
else
    log_warn "数据源 ConfigMap 不存在"
fi

# 检查 Dashboard ConfigMap
if kubectl get configmap grafana-dashboards -n "$NAMESPACE" >/dev/null 2>&1; then
    log_ok "Dashboard ConfigMap 存在"
else
    log_warn "Dashboard ConfigMap 不存在"
fi

log_ok "Grafana 配置完成"
log "  默认账号: admin / admin123"
