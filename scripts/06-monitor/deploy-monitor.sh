#!/usr/bin/env bash
###############################################################################
# 阶段6: 监控告警系统部署主脚本
# 使用 kube-prometheus-stack Helm Chart 部署 Prometheus + Grafana + Alertmanager
#
# 功能:
#   - 创建监控命名空间
#   - 部署 Prometheus (指标采集与存储)
#   - 部署 Grafana (可视化仪表盘)
#   - 部署 Alertmanager (告警管理)
#   - 配置自定义告警规则
#
# 使用示例:
#   ./deploy-monitor.sh              # 完整部署
#   ./deploy-monitor.sh --help       # 查看帮助
#
# 前置条件:
#   - kubectl 已安装并配置
#   - helm 已安装 (v3+)
#   - 集群可访问
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_FILE="/tmp/deploy-monitor-$(date +%Y%m%d-%H%M%S).log"
START_TIME=$(date +%s)

# ===== 颜色与日志函数 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()      { echo -e "${BLUE}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_error(){ echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }

# ===== 帮助信息 =====
usage() {
    cat <<EOF
用法: $0 [选项]

阶段6: 监控告警系统部署

选项:
  --help, -h          显示帮助信息
  --skip-prometheus   跳过 Prometheus 部署
  --skip-grafana      跳过 Grafana 部署
  --skip-alertmanager 跳过 Alertmanager 部署
  --verify-only       仅验证部署状态
EOF
}

# ===== 参数解析 =====
SKIP_PROMETHEUS=false
SKIP_GRAFANA=false
SKIP_ALERTMANAGER=false
VERIFY_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-prometheus)  SKIP_PROMETHEUS=true;  shift ;;
        --skip-grafana)     SKIP_GRAFANA=true;     shift ;;
        --skip-alertmanager) SKIP_ALERTMANAGER=true; shift ;;
        --verify-only)      VERIFY_ONLY=true;      shift ;;
        --help|-h)          usage; exit 0 ;;
        *) log_error "未知选项: $1"; usage; exit 1 ;;
    esac
done

# ===== 等待 Deployment 就绪 =====
# 参数: $1=名称 $2=命名空间 $3=超时秒数(默认300)
wait_for_deployment() {
    local name="$1"
    local ns="${2:-monitoring}"
    local timeout="${3:-300}"
    log "等待 $name/$ns 就绪 (超时: ${timeout}s)..."
    if kubectl wait --namespace="$ns" --for=condition=available deployment/"$name" --timeout="${timeout}s" 2>/dev/null; then
        log_ok "$name/$ns 已就绪"
        return 0
    else
        log_warn "$name/$ns 等待超时，检查Pod状态..."
        kubectl get pods -n "$ns" --no-headers 2>/dev/null || true
        return 1
    fi
}

# ===== 检查前置条件 =====
log "========== 阶段6: 监控告警系统部署 =========="

log "检查前置条件..."
command -v kubectl >/dev/null 2>&1 || { log_error "kubectl 未安装，请先安装 kubectl"; exit 1; }
command -v helm >/dev/null 2>&1    || { log_error "helm 未安装，请先安装 helm v3+"; exit 1; }

# 验证集群连接
if ! kubectl cluster-info >/dev/null 2>&1; then
    log_error "无法连接 Kubernetes 集群，请检查 kubeconfig"
    exit 1
fi
log_ok "前置条件检查通过"

# ===== 仅验证模式 =====
if [[ "$VERIFY_ONLY" == "true" ]]; then
    log "仅验证模式，跳过部署"
    log "监控命名空间状态:"
    kubectl get all -n monitoring 2>/dev/null || log_warn "监控命名空间不存在"
    exit 0
fi

# ===== Step 1: 创建监控命名空间 =====
log "[Step 1/5] 创建监控命名空间..."
if kubectl get namespace monitoring >/dev/null 2>&1; then
    log_ok "监控命名空间已存在"
else
    kubectl apply -f "$PROJECT_ROOT/manifests/monitoring/namespace.yaml" || {
        log_error "创建监控命名空间失败"
        exit 1
    }
    log_ok "监控命名空间创建成功"
fi

# ===== Step 2: 添加 Helm 仓库 =====
log "[Step 2/5] 添加 Prometheus Community Helm 仓库..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update >/dev/null 2>&1 || { log_error "更新 Helm 仓库失败"; exit 1; }
log_ok "Helm 仓库更新完成"

# ===== Step 3: 部署 Prometheus =====
if [[ "$SKIP_PROMETHEUS" == "false" ]]; then
    log "[Step 3/5] 部署 Prometheus..."
    bash "$SCRIPT_DIR/01-deploy-prometheus.sh" 2>&1 | tee -a "$LOG_FILE" || {
        log_error "Prometheus 部署失败"
        exit 1
    }
    log_ok "Prometheus 部署完成"
else
    log "[Step 3/5] 跳过 Prometheus 部署"
fi

# ===== Step 4: 部署 Grafana =====
if [[ "$SKIP_GRAFANA" == "false" ]]; then
    log "[Step 4/5] 部署 Grafana..."
    bash "$SCRIPT_DIR/02-deploy-grafana.sh" 2>&1 | tee -a "$LOG_FILE" || {
        log_error "Grafana 部署失败"
        exit 1
    }
    log_ok "Grafana 部署完成"
else
    log "[Step 4/5] 跳过 Grafana 部署"
fi

# ===== Step 5: 部署 Alertmanager =====
if [[ "$SKIP_ALERTMANAGER" == "false" ]]; then
    log "[Step 5/5] 部署 Alertmanager..."
    bash "$SCRIPT_DIR/03-deploy-alertmanager.sh" 2>&1 | tee -a "$LOG_FILE" || {
        log_error "Alertmanager 部署失败"
        exit 1
    }
    log_ok "Alertmanager 部署完成"
else
    log "[Step 5/5] 跳过 Alertmanager 部署"
fi

# ===== Post-deploy: 配置告警规则 =====
log "[Post-deploy] 配置告警规则..."
bash "$SCRIPT_DIR/04-config-rules.sh" 2>&1 | tee -a "$LOG_FILE" || {
    log_warn "告警规则配置失败，可稍后手动配置"
}

# ===== 部署结果汇总 =====
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log "========== 监控告警系统部署完成 (耗时: ${DURATION}s) =========="
log "访问地址:"
log "  Grafana:       kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80"
log "  Prometheus:    kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
log "  Alertmanager:  kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093"
log "日志文件: $LOG_FILE"
