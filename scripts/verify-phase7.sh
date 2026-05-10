#!/usr/bin/env bash
set -euo pipefail

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPORT_DIR="$PROJECT_DIR/reports"
REPORT_FILE="$REPORT_DIR/verify-phase7-$(date +%Y%m%d-%H%M%S).log"
TIMESTAMP_REPORT="$REPORT_DIR/verify-phase7-$(date +%Y%m%d-%H%M%S).txt"

# 加载共享库
source "$SCRIPT_DIR/lib/common.sh"

##############################################################################
# 阶段7: 日志系统验证
# 验证项目: Elasticsearch、Fluentd、Kibana
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

LOG_NS="logging"

# ========== 开始验证 ==========
section "阶段7: 日志系统验证"

# --- 7.1 命名空间检查 ---
section "7.1 日志命名空间检查"

if kubectl get namespace "$LOG_NS" &>/dev/null 2>&1; then
    pass "命名空间 $LOG_NS 存在"
else
    fail "命名空间 $LOG_NS 不存在"
fi

# --- 7.2 Elasticsearch检查 ---
section "7.2 Elasticsearch检查"

ES_PODS=$(kubectl get pods -n "$LOG_NS" -l app=elasticsearch --no-headers 2>/dev/null || echo "")
if [[ -z "$ES_PODS" ]]; then
    ES_PODS=$(kubectl get pods -n "$LOG_NS" --no-headers 2>/dev/null | grep -i elasticsearch || echo "")
fi
ES_RUNNING=$(echo "$ES_PODS" | grep -c "Running" 2>/dev/null || echo "0")
ES_TOTAL=$(echo "$ES_PODS" | grep -c . 2>/dev/null || echo "0")

if [[ $ES_RUNNING -gt 0 ]]; then
    pass "Elasticsearch Pod 运行正常 ($ES_RUNNING/$ES_TOTAL)"
else
    fail "Elasticsearch Pod 异常或不存在"
fi

ES_SVC=$(kubectl get svc -n "$LOG_NS" --no-headers 2>/dev/null | grep -i elasticsearch || echo "")
if [[ -n "$ES_SVC" ]]; then
    ES_SVC_NAME=$(echo "$ES_SVC" | awk '{print $1}')
    pass "Elasticsearch Service: $ES_SVC_NAME"

    # 尝试健康检查
    ES_SVC_IP=$(kubectl get svc "$ES_SVC_NAME" -n "$LOG_NS" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    if [[ -n "$ES_SVC_IP" ]]; then
        ES_HEALTH=$(kubectl run es-test-$(date +%s) --image=curlimages/curl --rm -i --restart=Never --timeout=15s -- curl -s "http://$ES_SVC_IP:9200/_cluster/health" 2>&1 || echo "FAILED")
        if echo "$ES_HEALTH" | grep -q "status" 2>/dev/null; then
            ES_CLUSTER_STATUS=$(echo "$ES_HEALTH" | grep -o '"status":"[^"]*"' || echo "unknown")
            pass "Elasticsearch 集群健康: $ES_CLUSTER_STATUS"
        else
            warn "Elasticsearch 健康检查未通过"
        fi
    fi
else
    fail "Elasticsearch Service 不存在"
fi

ES_PVC=$(kubectl get pvc -n "$LOG_NS" --no-headers 2>/dev/null | grep -i elasticsearch || echo "")
if [[ -n "$ES_PVC" ]]; then
    ES_PVC_BOUND=$(echo "$ES_PVC" | grep -c "Bound" 2>/dev/null || echo "0")
    if [[ $ES_PVC_BOUND -gt 0 ]]; then
        pass "Elasticsearch PVC 已绑定"
    else
        fail "Elasticsearch PVC 未绑定"
    fi
fi

# --- 7.3 Fluentd检查 ---
section "7.3 Fluentd检查"

FLUENTD_PODS=$(kubectl get pods -n "$LOG_NS" -l app=fluentd --no-headers 2>/dev/null || echo "")
if [[ -z "$FLUENTD_PODS" ]]; then
    FLUENTD_PODS=$(kubectl get pods -n "$LOG_NS" --no-headers 2>/dev/null | grep -i fluentd || echo "")
fi
FLUENTD_RUNNING=$(echo "$FLUENTD_PODS" | grep -c "Running" 2>/dev/null || echo "0")
FLUENTD_TOTAL=$(echo "$FLUENTD_PODS" | grep -c . 2>/dev/null || echo "0")

if [[ $FLUENTD_RUNNING -gt 0 ]]; then
    pass "Fluentd Pod 运行正常 ($FLUENTD_RUNNING/$FLUENTD_TOTAL)"
else
    fail "Fluentd Pod 异常或不存在"
fi

# 检查Fluentd DaemonSet
FLUENTD_DS=$(kubectl get daemonset -n "$LOG_NS" --no-headers 2>/dev/null | grep -i fluentd || echo "")
if [[ -n "$FLUENTD_DS" ]]; then
    pass "Fluentd DaemonSet 存在"
    DESIRED=$(echo "$FLUENTD_DS" | awk '{print $2}')
    CURRENT=$(echo "$FLUENTD_DS" | awk '{print $3}')
    if [[ "$DESIRED" == "$CURRENT" ]]; then
        pass "Fluentd DaemonSet 状态一致 (Desired=$DESIRED, Current=$CURRENT)"
    else
        warn "Fluentd DaemonSet 状态不一致 (Desired=$DESIRED, Current=$CURRENT)"
    fi
else
    info "Fluentd 未使用DaemonSet部署"
fi

# --- 7.4 Kibana检查 ---
section "7.4 Kibana检查"

KIBANA_PODS=$(kubectl get pods -n "$LOG_NS" -l app=kibana --no-headers 2>/dev/null || echo "")
if [[ -z "$KIBANA_PODS" ]]; then
    KIBANA_PODS=$(kubectl get pods -n "$LOG_NS" --no-headers 2>/dev/null | grep -i kibana || echo "")
fi
KIBANA_RUNNING=$(echo "$KIBANA_PODS" | grep -c "Running" 2>/dev/null || echo "0")
KIBANA_TOTAL=$(echo "$KIBANA_PODS" | grep -c . 2>/dev/null || echo "0")

if [[ $KIBANA_RUNNING -gt 0 ]]; then
    pass "Kibana Pod 运行正常 ($KIBANA_RUNNING/$KIBANA_TOTAL)"
else
    fail "Kibana Pod 异常或不存在"
fi

KIBANA_SVC=$(kubectl get svc -n "$LOG_NS" --no-headers 2>/dev/null | grep -i kibana || echo "")
if [[ -n "$KIBANA_SVC" ]]; then
    pass "Kibana Service 存在"
else
    fail "Kibana Service 不存在"
fi

KIBANA_INGRESS=$(kubectl get ingress -n "$LOG_NS" --no-headers 2>/dev/null | grep -i kibana || echo "")
if [[ -n "$KIBANA_INGRESS" ]]; then
    pass "Kibana Ingress 配置存在"
else
    info "Kibana 未配置Ingress"
fi

# --- 7.5 日志收集验证 ---
section "7.5 日志收集配置检查"

FLUENTD_CM=$(kubectl get configmap -n "$LOG_NS" --no-headers 2>/dev/null | grep -i fluentd || echo "")
if [[ -n "$FLUENTD_CM" ]]; then
    pass "Fluentd 配置ConfigMap存在"
else
    warn "Fluentd ConfigMap未发现"
fi

# 检查Elasticsearch索引
if [[ -n "${ES_SVC_IP:-}" ]]; then
    ES_INDICES=$(kubectl run es-idx-test --image=curlimages/curl --rm -i --restart=Never --timeout=15s -- curl -s "http://$ES_SVC_IP:9200/_cat/indices?v" 2>&1 || echo "FAILED")
    if echo "$ES_INDICES" | grep -q "index" 2>/dev/null; then
        INDEX_COUNT=$(echo "$ES_INDICES" | grep -c "fluentd\|log\|filebeat" 2>/dev/null || echo "0")
        if [[ $INDEX_COUNT -gt 0 ]]; then
            pass "日志索引已存在 ($INDEX_COUNT 个日志相关索引)"
        else
            info "暂无日志索引 (首次日志到达后会自动创建)"
        fi
    fi
fi

# ========== 验证报告 ==========
section "验证汇总"

echo ""
log "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
log "${CYAN}║          阶段7: 日志系统验证报告                ║${NC}"
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
