#!/usr/bin/env bash
###############################################################################
# 验证日志系统 (ELK Stack) 部署
#
# 功能:
#   - 验证 Elasticsearch 集群状态 (StatefulSet, Pod, 集群健康)
#   - 验证 Fluentd DaemonSet 状态 (DaemonSet, Pod, 日志错误)
#   - 验证 Kibana 状态 (Deployment, Service, 外部访问)
#   - 验证日志流 (容器日志文件)
#   - 检查资源使用情况
#   - 检查 ILM 保留策略
#
# 使用示例:
#   ./04-verify-logging.sh                     # 验证默认命名空间
#   ./04-verify-logging.sh -n logging          # 指定命名空间
#
# 退出码:
#   0 = 全部验证通过
#   1 = 发现问题
###############################################################################
set -euo pipefail

# ===== 颜色与日志函数 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }

# ===== 参数解析 =====
NAMESPACE="logging"
ERRORS=0
WARNINGS=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace|-n) NAMESPACE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# ===== 显示验证信息 =====
echo "==========================================="
echo "  日志系统验证"
echo "  命名空间: $NAMESPACE"
echo "  时间: $(date)"
echo "==========================================="

# ===== 1. 验证 Elasticsearch =====
echo ""
echo "----- Elasticsearch 验证 -----"

# 1.1 检查 StatefulSet 状态
log_info "检查 Elasticsearch StatefulSet..."
if kubectl get statefulset elasticsearch -n "$NAMESPACE" >/dev/null 2>&1; then
    READY=$(kubectl get statefulset elasticsearch -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    DESIRED=$(kubectl get statefulset elasticsearch -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    if [[ "$READY" == "$DESIRED" && "$READY" -gt 0 ]]; then
        log_ok "Elasticsearch StatefulSet: $READY/$DESIRED 副本就绪"
    else
        log_warn "Elasticsearch StatefulSet: $READY/$DESIRED 副本就绪"
        ERRORS=$((ERRORS + 1))
    fi
else
    log_error "Elasticsearch StatefulSet 不存在"
    ERRORS=$((ERRORS + 1))
fi

# 1.2 检查 Pod 状态
log_info "检查 Elasticsearch Pod 状态..."
ES_PODS=$(kubectl get pods -n "$NAMESPACE" -l app=elasticsearch --no-headers 2>/dev/null | wc -l)
ES_READY=$(kubectl get pods -n "$NAMESPACE" -l app=elasticsearch --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
if [[ "$ES_PODS" -gt 0 && "$ES_PODS" == "$ES_READY" ]]; then
    log_ok "Elasticsearch Pods: $ES_READY/$ES_PODS 运行中"
else
    log_warn "Elasticsearch Pods: $ES_READY/$ES_PODS 运行中"
    ERRORS=$((ERRORS + 1))
fi

# 1.3 检查集群健康状态
log_info "检查 Elasticsearch 集群健康..."
ES_POD=$(kubectl get pod -n "$NAMESPACE" -l app=elasticsearch -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "$ES_POD" ]]; then
    HEALTH=$(kubectl exec -n "$NAMESPACE" "$ES_POD" -- curl -s http://localhost:9200/_cluster/health 2>/dev/null || echo '{"status":"unavailable"}')
    CLUSTER_STATUS=$(echo "$HEALTH" | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
    if [[ "$CLUSTER_STATUS" == "green" ]]; then
        log_ok "Elasticsearch 集群状态: GREEN"
    elif [[ "$CLUSTER_STATUS" == "yellow" ]]; then
        log_warn "Elasticsearch 集群状态: YELLOW (可能副本不足)"
        WARNINGS=$((WARNINGS + 1))
    else
        log_error "Elasticsearch 集群状态: $CLUSTER_STATUS"
        ERRORS=$((ERRORS + 1))
    fi
    
    # 检查节点数
    NODES=$(echo "$HEALTH" | grep -o '"number_of_nodes":[0-9]*' | cut -d':' -f2 || echo "0")
    log_info "Elasticsearch 节点数: $NODES"
    
    # 检查索引数
    INDICES=$(kubectl exec -n "$NAMESPACE" "$ES_POD" -- curl -s http://localhost:9200/_cat/indices 2>/dev/null | wc -l || echo "0")
    log_info "Elasticsearch 索引数: $INDICES"
else
    log_error "无法找到 Elasticsearch Pod"
    ERRORS=$((ERRORS + 1))
fi

# ===== 2. 验证 Fluentd =====
echo ""
echo "----- Fluentd 验证 -----"

# 2.1 检查 DaemonSet 状态
log_info "检查 Fluentd DaemonSet..."
if kubectl get daemonset fluentd -n "$NAMESPACE" >/dev/null 2>&1; then
    DESIRED=$(kubectl get daemonset fluentd -n "$NAMESPACE" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
    READY=$(kubectl get daemonset fluentd -n "$NAMESPACE" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
    if [[ "$READY" == "$DESIRED" && "$READY" -gt 0 ]]; then
        log_ok "Fluentd DaemonSet: $READY/$DESIRED Pod 就绪"
    else
        log_warn "Fluentd DaemonSet: $READY/$DESIRED Pod 就绪"
        ERRORS=$((ERRORS + 1))
    fi
else
    log_error "Fluentd DaemonSet 不存在"
    ERRORS=$((ERRORS + 1))
fi

# 2.2 检查 Fluentd Pod 日志
log_info "检查 Fluentd 日志状态..."
FLUENTD_POD=$(kubectl get pod -n "$NAMESPACE" -l app=fluentd -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "$FLUENTD_POD" ]]; then
    FLUENTD_STATUS=$(kubectl get pod -n "$NAMESPACE" "$FLUENTD_POD" -o jsonpath='{.status.phase}' 2>/dev/null)
    if [[ "$FLUENTD_STATUS" == "Running" ]]; then
        log_ok "Fluentd Pod 状态: Running"
        # 检查最近的日志
        RECENT_ERRORS=$(kubectl logs -n "$NAMESPACE" "$FLUENTD_POD" --tail=100 2>/dev/null | grep -i "error" | wc -l || echo "0")
        if [[ "$RECENT_ERRORS" -lt 5 ]]; then
            log_ok "Fluentd 最近日志: 无严重错误"
        else
            log_warn "Fluentd 最近日志: 发现 $RECENT_ERRORS 条错误"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        log_error "Fluentd Pod 状态: $FLUENTD_STATUS"
        ERRORS=$((ERRORS + 1))
    fi
else
    log_error "无法找到 Fluentd Pod"
    ERRORS=$((ERRORS + 1))
fi

# 2.3 检查 RBAC
log_info "检查 Fluentd RBAC..."
if kubectl get serviceaccount fluentd -n "$NAMESPACE" >/dev/null 2>&1; then
    log_ok "Fluentd ServiceAccount 存在"
else
    log_warn "Fluentd ServiceAccount 不存在"
fi

# ===== 3. 验证 Kibana =====
echo ""
echo "----- Kibana 验证 -----"

# 3.1 检查 Deployment 状态
log_info "检查 Kibana Deployment..."
if kubectl get deployment kibana -n "$NAMESPACE" >/dev/null 2>&1; then
    READY=$(kubectl get deployment kibana -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    DESIRED=$(kubectl get deployment kibana -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    if [[ "$READY" == "$DESIRED" && "$READY" -gt 0 ]]; then
        log_ok "Kibana Deployment: $READY/$DESIRED 副本就绪"
    else
        log_warn "Kibana Deployment: $READY/$DESIRED 副本就绪"
        ERRORS=$((ERRORS + 1))
    fi
else
    log_error "Kibana Deployment 不存在"
    ERRORS=$((ERRORS + 1))
fi

# 3.2 检查 Kibana Service
log_info "检查 Kibana Service..."
if kubectl get service kibana -n "$NAMESPACE" >/dev/null 2>&1; then
    log_ok "Kibana Service 存在"
else
    log_error "Kibana Service 不存在"
    ERRORS=$((ERRORS + 1))
fi

# 3.3 检查 Kibana 外部访问
log_info "检查 Kibana 外部访问..."
KIBANA_SVC=$(kubectl get service kibana-external -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)
if [[ -n "$KIBANA_SVC" ]]; then
    log_ok "Kibana 外部访问端口: $KIBANA_SVC"
else
    log_warn "Kibana 外部访问 Service 不存在"
    WARNINGS=$((WARNINGS + 1))
fi

# 3.4 检查 Kibana 初始化 Job
log_info "检查 Kibana 初始化 Job..."
if kubectl get job kibana-init -n "$NAMESPACE" >/dev/null 2>&1; then
    JOB_STATUS=$(kubectl get job kibana-init -n "$NAMESPACE" -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "unknown")
    if [[ "$JOB_STATUS" == "Complete" ]]; then
        log_ok "Kibana 初始化 Job: 已完成"
    elif [[ "$JOB_STATUS" == "Failed" ]]; then
        log_warn "Kibana 初始化 Job: 失败"
        WARNINGS=$((WARNINGS + 1))
    else
        log_info "Kibana 初始化 Job: 运行中"
    fi
else
    log_warn "Kibana 初始化 Job 不存在"
fi

# ===== 4. 验证日志流 =====
echo ""
echo "----- 日志流验证 -----"

# 4.1 检查日志文件
log_info "检查容器日志文件..."
LOG_COUNT=$(ls /var/log/containers/*.log 2>/dev/null | wc -l || echo "0")
if [[ "$LOG_COUNT" -gt 0 ]]; then
    log_ok "找到 $LOG_COUNT 个容器日志文件"
else
    log_warn "未找到容器日志文件"
    WARNINGS=$((WARNINGS + 1))
fi

# ===== 5. 资源使用 =====
echo ""
echo "----- 资源使用 -----"

log_info "检查日志系统资源使用..."
if kubectl top pods -n "$NAMESPACE" --no-headers 2>/dev/null; then
    log_ok "资源使用信息获取成功"
else
    log_warn "无法获取资源使用信息 (metrics-server 可能未安装)"
    WARNINGS=$((WARNINGS + 1))
fi

# ===== 6. 日志保留策略 =====
echo ""
echo "----- 日志保留策略 -----"

log_info "检查 ILM 策略..."
if [[ -n "$ES_POD" ]]; then
    POLICIES=$(kubectl exec -n "$NAMESPACE" "$ES_POD" -- curl -s http://localhost:9200/_ilm/policy 2>/dev/null | grep -o '"[^"]*"' | head -5 || echo "无")
    if [[ "$POLICIES" != "无" ]]; then
        log_ok "ILM 策略已配置"
    else
        log_warn "未发现 ILM 策略"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    log_warn "无法检查 ILM 策略 (ES Pod 不可用)"
fi

# ===== 汇总 =====
echo ""
echo "==========================================="
echo "  验证汇总"
echo "  命名空间: $NAMESPACE"
echo "  时间: $(date)"
echo "==========================================="

if [[ $ERRORS -eq 0 && $WARNINGS -eq 0 ]]; then
    log_ok "日志系统验证完成 - 全部通过"
    echo "==========================================="
    exit 0
elif [[ $ERRORS -eq 0 ]]; then
    log_warn "日志系统验证完成 - 发现 $WARNINGS 个警告"
    echo "==========================================="
    exit 0
else
    log_error "日志系统验证完成 - 发现 $ERRORS 个错误, $WARNINGS 个警告"
    echo "==========================================="
    exit 1
fi
