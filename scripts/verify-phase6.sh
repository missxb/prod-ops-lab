#!/usr/bin/env bash
set -euo pipefail

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPORT_DIR="$PROJECT_DIR/reports"
REPORT_FILE="$REPORT_DIR/verify-phase6-$(date +%Y%m%d-%H%M%S).log"
TIMESTAMP_REPORT="$REPORT_DIR/verify-phase6-$(date +%Y%m%d-%H%M%S).txt"

# 加载共享库
source "$SCRIPT_DIR/lib/common.sh"

##############################################################################
# 阶段6: 监控告警验证
# 验证项目: Prometheus、Grafana、Alertmanager、告警规则
##############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
TOTAL_COUNT=0

mkdir -p "$REPORT_DIR"

log() { local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"; echo -e "$msg"; echo "$msg" >> "$REPORT_FILE"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); TOTAL_COUNT=$((TOTAL_COUNT + 1)); log "${GREEN}[PASS]${NC} $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); TOTAL_COUNT=$((TOTAL_COUNT + 1)); log "${RED}[FAIL]${NC} $1"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); TOTAL_COUNT=$((TOTAL_COUNT + 1)); log "${YELLOW}[WARN]${NC} $1"; }
info() { log "${BLUE}[INFO]${NC} $1"; }
section() { echo ""; log "${CYAN}========== $1 ==========${NC}"; }

if ! command -v kubectl &>/dev/null; then
    echo -e "${RED}错误: kubectl 命令不可用${NC}"
    exit 1
fi

MON_NS="monitoring"

# ========== 开始验证 ==========
section "阶段6: 监控告警验证"

# --- 6.1 命名空间检查 ---
section "6.1 监控命名空间检查"

if kubectl get namespace "$MON_NS" &>/dev/null 2>&1; then
    pass "命名空间 $MON_NS 存在"
else
    fail "命名空间 $MON_NS 不存在"
fi

# --- 6.2 Prometheus检查 ---
section "6.2 Prometheus检查"

PROM_PODS=$(kubectl get pods -n "$MON_NS" -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null || echo "")
if [[ -z "$PROM_PODS" ]]; then
    PROM_PODS=$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null | grep -i prom || echo "")
fi
PROM_RUNNING=$(echo "$PROM_PODS" | grep -c "Running" 2>/dev/null || echo "0")
PROM_TOTAL=$(echo "$PROM_PODS" | grep -c . 2>/dev/null || echo "0")

if [[ $PROM_RUNNING -gt 0 ]]; then
    pass "Prometheus Pod 运行正常 ($PROM_RUNNING/$PROM_TOTAL)"
else
    fail "Prometheus Pod 异常或不存在"
fi

PROM_SVC=$(kubectl get svc -n "$MON_NS" --no-headers 2>/dev/null | grep -i prom || echo "")
if [[ -n "$PROM_SVC" ]]; then
    PROM_SVC_NAME=$(echo "$PROM_SVC" | awk '{print $1}')
    PROM_SVC_PORT=$(echo "$PROM_SVC" | awk '{print $5}' | cut -d: -f1)
    pass "Prometheus Service: $PROM_SVC_NAME (port: $PROM_SVC_PORT)"

    # 尝试访问Prometheus
    PROM_SVC_IP=$(kubectl get svc "$PROM_SVC_NAME" -n "$MON_NS" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    if [[ -n "$PROM_SVC_IP" ]]; then
        PROM_HEALTH=$(kubectl run prom-test-$(date +%s) --image=curlimages/curl --rm -i --restart=Never --timeout=15s -- curl -s "http://$PROM_SVC_IP:9090/-/healthy" 2>&1 || echo "FAILED")
        if echo "$PROM_HEALTH" | grep -q "Healthy" 2>/dev/null; then
            pass "Prometheus 健康检查通过"
        else
            warn "Prometheus 健康检查未通过 (可能需要更多时间启动)"
        fi
    fi
else
    fail "Prometheus Service 不存在"
fi

# --- 6.3 Grafana检查 ---
section "6.3 Grafana检查"

GRAFANA_PODS=$(kubectl get pods -n "$MON_NS" -l app.kubernetes.io/name=grafana --no-headers 2>/dev/null || echo "")
if [[ -z "$GRAFANA_PODS" ]]; then
    GRAFANA_PODS=$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null | grep -i grafana || echo "")
fi
GRAFANA_RUNNING=$(echo "$GRAFANA_PODS" | grep -c "Running" 2>/dev/null || echo "0")
GRAFANA_TOTAL=$(echo "$GRAFANA_PODS" | grep -c . 2>/dev/null || echo "0")

if [[ $GRAFANA_RUNNING -gt 0 ]]; then
    pass "Grafana Pod 运行正常 ($GRAFANA_RUNNING/$GRAFANA_TOTAL)"
else
    fail "Grafana Pod 异常或不存在"
fi

GRAFANA_SVC=$(kubectl get svc -n "$MON_NS" --no-headers 2>/dev/null | grep -i grafana || echo "")
if [[ -n "$GRAFANA_SVC" ]]; then
    GRAFANA_SVC_NAME=$(echo "$GRAFANA_SVC" | awk '{print $1}')
    pass "Grafana Service: $GRAFANA_SVC_NAME"
else
    fail "Grafana Service 不存在"
fi

GRAFANA_INGRESS=$(kubectl get ingress -n "$MON_NS" --no-headers 2>/dev/null | grep -i grafana || echo "")
if [[ -n "$GRAFANA_INGRESS" ]]; then
    pass "Grafana Ingress 配置存在"
else
    info "Grafana 未配置Ingress"
fi

# --- 6.4 Alertmanager检查 ---
section "6.4 Alertmanager检查"

ALERT_PODS=$(kubectl get pods -n "$MON_NS" -l app.kubernetes.io/name=alertmanager --no-headers 2>/dev/null || echo "")
if [[ -z "$ALERT_PODS" ]]; then
    ALERT_PODS=$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null | grep -i alertmanager || echo "")
fi
ALERT_RUNNING=$(echo "$ALERT_PODS" | grep -c "Running" 2>/dev/null || echo "0")
ALERT_TOTAL=$(echo "$ALERT_PODS" | grep -c . 2>/dev/null || echo "0")

if [[ $ALERT_RUNNING -gt 0 ]]; then
    pass "Alertmanager Pod 运行正常 ($ALERT_RUNNING/$ALERT_TOTAL)"
else
    fail "Alertmanager Pod 异常或不存在"
fi

ALERT_SVC=$(kubectl get svc -n "$MON_NS" --no-headers 2>/dev/null | grep -i alertmanager || echo "")
if [[ -n "$ALERT_SVC" ]]; then
    pass "Alertmanager Service 存在"
else
    warn "Alertmanager Service 不存在"
fi

# --- 6.5 告警规则检查 ---
section "6.5 告警规则/ConfigMap检查"

RULES_CM=$(kubectl get configmap -n "$MON_NS" --no-headers 2>/dev/null | grep -iE "rule|alert|prom" || echo "")
if [[ -n "$RULES_CM" ]]; then
    RULES_COUNT=$(echo "$RULES_CM" | wc -l)
    pass "告警规则ConfigMap数量: $RULES_COUNT"
else
    info "未发现告警规则ConfigMap"
fi

# --- 6.6 Node Exporter检查 ---
section "6.6 Node Exporter检查"

NODE_EXPORTER_PODS=$(kubectl get pods -n "$MON_NS" -l app.kubernetes.io/name=node-exporter --no-headers 2>/dev/null || echo "")
if [[ -z "$NODE_EXPORTER_PODS" ]]; then
    NODE_EXPORTER_PODS=$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null | grep -i node-exporter || echo "")
fi
NE_RUNNING=$(echo "$NODE_EXPORTER_PODS" | grep -c "Running" 2>/dev/null || echo "0")

if [[ $NE_RUNNING -gt 0 ]]; then
    pass "Node Exporter 运行正常"
else
    info "Node Exporter 未部署或使用DaemonSet"
fi

# 检查DaemonSet
NODE_EXPORTER_DS=$(kubectl get daemonset -n "$MON_NS" --no-headers 2>/dev/null | grep -i node-exporter || echo "")
if [[ -n "$NODE_EXPORTER_DS" ]]; then
    pass "Node Exporter DaemonSet 存在"
fi

# ========== 验证报告 ==========
section "验证汇总"

echo ""
log "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
log "${CYAN}║          阶段6: 监控告警验证报告                ║${NC}"
log "${CYAN}╠══════════════════════════════════════════════════╣${NC}"
log "${CYAN}║${NC} 总检查项:  ${TOTAL_COUNT}                                    ${CYAN}║${NC}"
log "${GREEN}║${NC} 通过:      ${PASS_COUNT}                                    ${GREEN}║${NC}"
log "${RED}║${NC} 失败:      ${FAIL_COUNT}                                    ${RED}║${NC}"
log "${YELLOW}║${NC} 警告:      ${WARN_COUNT}                                    ${YELLOW}║${NC}"
log "${CYAN}╠══════════════════════════════════════════════════╣${NC}"

if [[ $FAIL_COUNT -eq 0 ]]; then
    if [[ $WARN_COUNT -eq 0 ]]; then
        log "${GREEN}║  结果: ✓ 全部通过                               ║${NC}"
    else
        log "${YELLOW}║  结果: △ 通过(有警告)                           ║${NC}"
    fi
else
    log "${RED}║  结果: ✗ 存在失败项                             ║${NC}"
fi

log "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
log ""
log "报告已保存: $REPORT_FILE"

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
