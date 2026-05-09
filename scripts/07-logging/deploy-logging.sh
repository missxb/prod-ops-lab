#!/usr/bin/env bash
###############################################################################
# 阶段7: 日志系统部署主脚本
# ELK Stack (Elasticsearch + Fluentd + Kibana)
# 企业级云原生运维平台
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_DIR="/var/log/elk-deploy"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }

mkdir -p "$LOG_DIR"

usage() {
    cat <<EOF
用法: $0 [选项]

选项:
  --namespace, -n    日志命名空间 (默认: logging)
  --skip-elasticsearch  跳过Elasticsearch部署
  --skip-fluentd       跳过Fluentd部署
  --skip-kibana        跳过Kibana部署
  --verify-only        仅执行验证
  --dry-run           干运行模式
  --help, -h          显示帮助
EOF
}

NAMESPACE="logging"
SKIP_ES=false
SKIP_FLUENTD=false
SKIP_KIBANA=false
VERIFY_ONLY=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace|-n) NAMESPACE="$2"; shift 2 ;;
        --skip-elasticsearch) SKIP_ES=true; shift ;;
        --skip-fluentd) SKIP_FLUENTD=true; shift ;;
        --skip-kibana) SKIP_KIBANA=true; shift ;;
        --verify-only) VERIFY_ONLY=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) log_error "未知选项: $1"; usage; exit 1 ;;
    esac
done

apply_manifest() {
    local file="$1"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] kubectl apply -f $file"
        return 0
    fi
    kubectl apply -f "$file" 2>&1 | tee -a "$LOG_DIR/apply-$TIMESTAMP.log"
}

wait_for_deployment() {
    local name="$1"
    local ns="$2"
    local timeout="${3:-300}"
    log_info "等待 $name/$ns 就绪 (超时: ${timeout}s)..."
    if kubectl wait --namespace="$ns" --for=condition=available deployment/"$name" --timeout="${timeout}s" 2>/dev/null; then
        log_ok "$name/$ns 已就绪"
    else
        log_warn "$name/$ns 超时，检查Pod状态..."
        kubectl get pods -n "$ns" -l app="$name" --no-headers 2>/dev/null || true
    fi
}

echo "==========================================="
echo "  日志系统 (ELK Stack) 部署"
echo "  命名空间: $NAMESPACE"
echo "  时间: $(date)"
echo "==========================================="

if [[ "$VERIFY_ONLY" == "true" ]]; then
    log_info "仅验证模式..."
    bash "$SCRIPT_DIR/04-verify-logging.sh" -n "$NAMESPACE"
    exit $?
fi

# 1. 部署命名空间
log_info "创建日志命名空间..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# 2. 部署 Elasticsearch
if [[ "$SKIP_ES" == "false" ]]; then
    log_info "========== 步骤 1/4: 部署 Elasticsearch =========="
    bash "$SCRIPT_DIR/01-deploy-elasticsearch.sh" -n "$NAMESPACE"
    wait_for_deployment "elasticsearch" "$NAMESPACE" 600
fi

# 3. 部署 Fluentd
if [[ "$SKIP_FLUENTD" == "false" ]]; then
    log_info "========== 步骤 2/4: 部署 Fluentd =========="
    bash "$SCRIPT_DIR/02-deploy-fluentd.sh" -n "$NAMESPACE"
    # DaemonSet 不需要 wait_for_deployment，用 rollout status
    log_info "等待 Fluentd DaemonSet rollout..."
    kubectl rollout status daemonset/fluentd -n "$NAMESPACE" --timeout=300s 2>/dev/null || true
fi

# 4. 部署 Kibana
if [[ "$SKIP_KIBANA" == "false" ]]; then
    log_info "========== 步骤 3/4: 部署 Kibana =========="
    bash "$SCRIPT_DIR/03-deploy-kibana.sh" -n "$NAMESPACE"
    wait_for_deployment "kibana" "$NAMESPACE" 300
fi

# 5. 验证
log_info "========== 步骤 4/4: 验证日志系统 =========="
bash "$SCRIPT_DIR/04-verify-logging.sh" -n "$NAMESPACE"

log_ok "==========================================="
log_ok "  日志系统部署完成!"
log_ok "==========================================="
