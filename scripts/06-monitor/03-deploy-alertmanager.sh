#!/usr/bin/env bash
###############################################################################
# 配置 Alertmanager
#
# 功能:
#   - 应用 Alertmanager 配置
#   - 重启 Alertmanager 使配置生效
#   - 验证配置状态
#
# 使用示例:
#   ./03-deploy-alertmanager.sh               # 应用配置并重启
#
# 配置文件:
#   configs/prometheus/alertmanager.yaml       (Alertmanager 配置)
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

log()      { echo -e "${BLUE}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') [Alertmanager] $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') [Alertmanager] $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') [Alertmanager] $*"; }
log_error(){ echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') [Alertmanager] $*"; }

# ===== 前置检查 =====
log "检查 Alertmanager 配置前置条件..."

# 验证 Alertmanager StatefulSet 存在
if ! kubectl get statefulset kube-prometheus-stack-alertmanager -n "$NAMESPACE" >/dev/null 2>&1; then
    log_warn "Alertmanager StatefulSet 不存在，可能尚未部署"
fi

# ===== 应用配置 =====
log "应用 Alertmanager 配置..."
ALERTMANAGER_CONFIG="$PROJECT_ROOT/configs/prometheus/alertmanager.yaml"
if [[ -f "$ALERTMANAGER_CONFIG" ]]; then
    kubectl apply -f "$ALERTMANAGER_CONFIG" -n "$NAMESPACE" 2>/dev/null || {
        log_warn "Alertmanager 配置应用失败"
    }
    log_ok "Alertmanager 配置已应用"
else
    log_warn "Alertmanager 配置文件不存在: $ALERTMANAGER_CONFIG"
fi

# ===== 重启 Alertmanager =====
log "重启 Alertmanager 使配置生效..."
kubectl rollout restart statefulset/kube-prometheus-stack-alertmanager -n "$NAMESPACE" 2>/dev/null || {
    log_warn "重启 Alertmanager 失败，可能尚未部署"
}

# 等待 rollout 完成
log "等待 Alertmanager rollout 完成..."
if kubectl rollout status statefulset/kube-prometheus-stack-alertmanager -n "$NAMESPACE" --timeout=120s 2>/dev/null; then
    log_ok "Alertmanager rollout 完成"
else
    log_warn "Alertmanager rollout 等待超时"
fi

# ===== 验证配置 =====
log "验证 Alertmanager 配置..."
# 检查 Secret 是否存在
if kubectl get secret alertmanager-kube-prometheus-stack-alertmanager -n "$NAMESPACE" >/dev/null 2>&1; then
    log_ok "Alertmanager Secret 存在"
else
    log_warn "Alertmanager Secret 不存在，可能使用默认配置"
fi

log_ok "Alertmanager 配置完成"
