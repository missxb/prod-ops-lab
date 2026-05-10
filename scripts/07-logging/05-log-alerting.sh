#!/bin/bash
###############################################################################
# 05-log-alerting.sh - 日志告警规则管理
# 功能: 创建、启用、禁用、删除日志告警规则
# 项目: 企业级云原生运维平台
# 阶段: 07 - 日志系统
# 作者: 运维平台团队
# 版本: 1.1.0
###############################################################################

set -euo pipefail
umask 077

# 加载公共函数库
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# 错误处理
trap 'log_error "脚本执行出错，行号: ${LINENO}"' ERR

# 清理函数
LOCK_FILE="/var/lock/$(basename "$0").lock"
cleanup() {
    rm -f "${LOCK_FILE}"
    log_info "脚本执行完毕"
}
trap cleanup EXIT
trap 'log_error "收到中断信号，正在清理..."; exit 130' INT TERM

# 锁文件检查
if [ -f "${LOCK_FILE}" ]; then
    log_error "另一个实例正在运行 (PID: $(cat ${LOCK_FILE}))"
    exit 1
fi
echo $$ > "${LOCK_FILE}"

# ==================== 全局变量 ====================
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RULES_FILE="${PROJECT_ROOT}/configs/prometheus/log-alerting-rules.yaml"
PROMETHEUS_NAMESPACE="${PROMETHEUS_NAMESPACE:-monitoring}"
RULE_NAME="log-alerting-rules"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="${PROJECT_ROOT}/logs/07-logging"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/log-alerting_${TIMESTAMP}.log"

# ==================== 用法说明 ====================
usage() {
    cat << EOF
用法: $(basename "$0") <action>

操作选项:
  create       创建日志告警规则PrometheusRule资源（默认）
  enable       启用日志告警规则
  disable      禁用日志告警规则
  delete       删除日志告警规则
  verify       验证告警规则是否已加载
  list         列出所有告警规则
  help         显示此帮助信息

环境变量:
  PROMETHEUS_NAMESPACE    Prometheus所在命名空间（默认: monitoring）
  KUBECONFIG              kubectl配置文件路径

示例:
  $(basename "$0") create       # 创建告警规则
  $(basename "$0") enable       # 启用告警规则
  $(basename "$0") disable      # 禁用告警规则
  $(basename "$0") delete       # 删除告警规则
  $(basename "$0") verify       # 验证规则加载
  $(basename "$0") list         # 列出规则
EOF
}

# ==================== 前置检查 ====================
check_prerequisites() {
    # 检查kubectl
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl命令不可用"
        exit 1
    fi

    # 检查集群连接
    if ! kubectl cluster-info &>/dev/null 2>&1; then
        log_error "无法连接到Kubernetes集群"
        exit 1
    fi

    # 检查规则文件
    if [[ ! -f "$RULES_FILE" ]]; then
        log_error "告警规则文件不存在: $RULES_FILE"
        exit 1
    fi

    log_success "前置检查通过"
}

# ==================== 创建告警规则 ====================
create_rules() {
    log_step "[1/3] 创建日志告警规则PrometheusRule..."

    # 确保命名空间存在
    kubectl create namespace "$PROMETHEUS_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

    # 读取规则文件内容
    local rules_content
    rules_content=$(cat "$RULES_FILE")

    # 创建PrometheusRule资源
    cat << EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: ${RULE_NAME}
  namespace: ${PROMETHEUS_NAMESPACE}
  labels:
    app.kubernetes.io/name: log-alerting
    app.kubernetes.io/part-of: enterprise-platform
    prometheus: kube-prometheus
    role: alert-rules
  annotations:
    description: "日志系统告警规则 - 监控EFK栈健康状态"
spec:
  groups:
    - name: log-alerting
      rules:
        # ==================== Fluentd告警 ====================

        # 日志量异常增高
        - alert: HighLogVolume
          expr: rate(fluentd_output_status_num_records_total[5m]) > 10000
          for: 5m
          labels:
            severity: warning
            team: operations
          annotations:
            summary: "日志量异常增高"
            description: "过去5分钟日志速率超过10000条/秒，可能存在日志风暴或异常事件"

        # Fluentd输出错误
        - alert: FluentdErrors
          expr: rate(fluentd_output_status_num_errors_total[5m]) > 0
          for: 2m
          labels:
            severity: critical
            team: operations
          annotations:
            summary: "Fluentd输出错误"
            description: "Fluentd在过去2分钟内有输出错误，日志可能丢失"

        # Fluentd缓冲区使用率过高
        - alert: FluentdBufferHighUsage
          expr: fluentd_output_status_buffer_stage_length / fluentd_output_status_buffer_total_limit_length > 0.8
          for: 10m
          labels:
            severity: warning
            team: operations
          annotations:
            summary: "Fluentd缓冲区使用率过高"
            description: "Fluentd缓冲区使用率超过80%，可能导致日志丢失"

        # Fluentd重试次数过多
        - alert: FluentdRetryExcessive
          expr: rate(fluentd_output_status_retry_count[5m]) > 5
          for: 5m
          labels:
            severity: warning
            team: operations
          annotations:
            summary: "Fluentd重试次数过多"
            description: "Fluentd在过去5分钟内重试次数超过5次/秒"

        # ==================== Elasticsearch告警 ====================

        # ES集群状态为RED
        - alert: ElasticsearchClusterRed
          expr: elasticsearch_cluster_health_status{color="red"} == 1
          for: 1m
          labels:
            severity: critical
            team: operations
          annotations:
            summary: "ES集群状态为RED"
            description: "Elasticsearch集群状态变为RED，存在未分配分片"

        # ES集群状态为YELLOW
        - alert: ElasticsearchClusterYellow
          expr: elasticsearch_cluster_health_status{color="yellow"} == 1
          for: 5m
          labels:
            severity: warning
            team: operations
          annotations:
            summary: "ES集群状态为YELLOW"
            description: "Elasticsearch集群状态持续YELLOW超过5分钟"

        # ES磁盘使用率超过85%
        - alert: ElasticsearchHighDiskUsage
          expr: elasticsearch_filesystem_data_used_percent > 85
          for: 10m
          labels:
            severity: warning
            team: operations
          annotations:
            summary: "ES磁盘使用率超过85%"
            description: "ES节点磁盘使用率超过85%"

        # ES JVM堆内存使用超过80%
        - alert: ElasticsearchHighHeapUsage
          expr: elasticsearch_jvm_mem_heap_used_percent > 80
          for: 5m
          labels:
            severity: warning
            team: operations
          annotations:
            summary: "ES JVM堆内存使用超过80%"
            description: "ES节点JVM堆使用率超过80%"

        # ES主分片未分配
        - alert: ElasticsearchUnassignedShards
          expr: elasticsearch_cluster_health_unassigned_shards > 0
          for: 10m
          labels:
            severity: warning
            team: operations
          annotations:
            summary: "ES存在未分配分片"
            description: "ES集群存在未分配分片"

        # ==================== Kibana告警 ====================

        # Kibana服务不可用
        - alert: KibanaDown
          expr: up{job="kibana"} == 0
          for: 1m
          labels:
            severity: critical
            team: operations
          annotations:
            summary: "Kibana服务不可用"
            description: "Kibana服务已宕机"

        # ==================== 日志内容告警 ====================

        # 容器错误日志速率过高
        - alert: HighErrorLogRate
          expr: rate(container_logs_errors_total[5m]) > 100
          for: 5m
          labels:
            severity: warning
            team: development
          annotations:
            summary: "容器错误日志速率过高"
            description: "过去5分钟错误日志速率超过100条/秒"

        # OOM Kill日志检测
        - alert: OOMKillDetected
          expr: increase(container_logs_errors_total{container="OOMKilled"}[5m]) > 0
          for: 0m
          labels:
            severity: critical
            team: development
          annotations:
            summary: "检测到OOM Kill事件"
            description: "过去5分钟内检测到OOM Kill事件"

        # 容器重启日志检测
        - alert: ContainerRestartDetected
          expr: increase(kube_pod_container_status_restarts_total[1h]) > 3
          for: 0m
          labels:
            severity: warning
            team: development
          annotations:
            summary: "容器频繁重启"
            description: "容器在过去1小时内重启超过3次"
EOF

    log_success "日志告警规则创建完成"

    # 验证资源创建
    log_step "[2/3] 验证资源创建..."
    if kubectl get prometheusrule "$RULE_NAME" -n "$PROMETHEUS_NAMESPACE" &>/dev/null; then
        log_success "PrometheusRule资源创建成功"
    else
        log_error "PrometheusRule资源创建失败"
        exit 1
    fi
}

# ==================== 启用告警规则 ====================
enable_rules() {
    log_step "启用日志告警规则..."

    if ! kubectl get prometheusrule "$RULE_NAME" -n "$PROMETHEUS_NAMESPACE" &>/dev/null; then
        log_error "PrometheusRule资源不存在，请先创建"
        exit 1
    fi

    # 移除禁用标签
    kubectl label prometheusrule "$RULE_NAME" -n "$PROMETHEUS_NAMESPACE" alerting-disabled- 2>/dev/null || true

    log_success "日志告警规则已启用"
    log_info "等待Prometheus重新加载配置..."
}

# ==================== 禁用告警规则 ====================
disable_rules() {
    log_step "禁用日志告警规则..."

    if ! kubectl get prometheusrule "$RULE_NAME" -n "$PROMETHEUS_NAMESPACE" &>/dev/null; then
        log_error "PrometheusRule资源不存在"
        exit 1
    fi

    # 添加禁用标签
    kubectl label prometheusrule "$RULE_NAME" -n "$PROMETHEUS_NAMESPACE" alerting-disabled=true --overwrite

    log_success "日志告警规则已禁用"
    log_info "等待Prometheus重新加载配置..."
}

# ==================== 删除告警规则 ====================
delete_rules() {
    log_step "删除日志告警规则..."

    if ! kubectl get prometheusrule "$RULE_NAME" -n "$PROMETHEUS_NAMESPACE" &>/dev/null; then
        log_warn "PrometheusRule资源不存在，无需删除"
        return 0
    fi

    # 删除资源
    kubectl delete prometheusrule "$RULE_NAME" -n "$PROMETHEUS_NAMESPACE"

    log_success "日志告警规则已删除"
}

# ==================== 验证规则加载 ====================
verify_rules() {
    log_step "验证告警规则加载状态..."

    # 检查PrometheusRule资源
    if kubectl get prometheusrule "$RULE_NAME" -n "$PROMETHEUS_NAMESPACE" &>/dev/null; then
        log_success "PrometheusRule资源存在"
    else
        log_error "PrometheusRule资源不存在"
        return 1
    fi

    # 获取规则详情
    echo ""
    echo "  规则资源详情:"
    kubectl get prometheusrule "$RULE_NAME" -n "$PROMETHEUS_NAMESPACE" -o wide 2>/dev/null || true
    echo ""

    # 尝试通过Prometheus API验证
    log_info "尝试通过Prometheus API验证规则..."

    # 查找Prometheus服务
    local prometheus_svc
    prometheus_svc=$(kubectl get svc -n "$PROMETHEUS_NAMESPACE" -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -n "$prometheus_svc" ]]; then
        # 端口转发并查询规则
        local prometheus_port
        prometheus_port=$(kubectl get svc "$prometheus_svc" -n "$PROMETHEUS_NAMESPACE" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "9090")

        log_info "Prometheus服务: ${prometheus_svc}:${prometheus_port}"

        # 使用kubectl exec或端口转发查询规则
        kubectl exec -n "$PROMETHEUS_NAMESPACE" \
            $(kubectl get pods -n "$PROMETHEUS_NAMESPACE" -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) \
            -- wget -qO- "http://localhost:9090/api/v1/rules" 2>/dev/null | \
            python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    rules = data.get('data', {}).get('groups', [])
    log_rules = [g for g in rules if 'log' in g.get('name', '').lower()]
    if log_rules:
        print('  ✓ 找到日志告警规则组:')
        for g in log_rules:
            print(f\"    组: {g['name']}\")
            for r in g.get('rules', []):
                print(f\"      - {r.get('name', 'unknown')}\")
    else:
        print('  ✗ 未找到日志告警规则组')
        print('  请等待Prometheus重新加载配置，或检查Prometheus日志')
except Exception as e:
    print(f'  解析失败: {e}')
" 2>/dev/null || log_warn "无法通过API验证，请稍后手动检查"
    else
        log_warn "未找到Prometheus服务，跳过API验证"
    fi

    echo ""
    log_success "验证完成"
}

# ==================== 列出告警规则 ====================
list_rules() {
    log_step "列出日志告警规则..."

    echo ""
    echo "  PrometheusRule资源:"
    kubectl get prometheusrule -n "$PROMETHEUS_NAMESPACE" -o wide 2>/dev/null || echo "  无PrometheusRule资源"
    echo ""

    # 显示规则文件中的告警
    if [[ -f "$RULES_FILE" ]]; then
        echo "  规则文件中的告警 ($RULES_FILE):"
        grep -E "^\s*- alert:" "$RULES_FILE" | sed 's/.*- alert: /    - /' || echo "  无法解析规则文件"
    fi
    echo ""
}

# ==================== 主流程 ====================
main() {
    local action="${1:-create}"

    case "$action" in
        help|-h|--help)
            usage
            exit 0
            ;;
        create)
            log_info "========== 创建日志告警规则 =========="
            check_prerequisites
            create_rules
            verify_rules
            log_info "========== 告警规则创建完成 =========="
            ;;
        enable)
            check_prerequisites
            enable_rules
            ;;
        disable)
            check_prerequisites
            disable_rules
            ;;
        delete)
            check_prerequisites
            delete_rules
            ;;
        verify)
            check_prerequisites
            verify_rules
            ;;
        list)
            check_prerequisites
            list_rules
            ;;
        *)
            echo "用法: $0 {create|enable|disable|delete|verify|list|help}"
            exit 1
            ;;
    esac
}

main "$@"
