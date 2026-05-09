#!/usr/bin/env bash
###############################################################################
# 阶段7: 日志系统部署主脚本
# ELK Stack (Elasticsearch + Fluentd + Kibana)
# 企业级云原生运维平台
#
# 功能:
#   - 部署 Elasticsearch (3节点集群，持久化存储)
#   - 部署 Fluentd (日志收集 DaemonSet)
#   - 部署 Kibana (日志可视化平台)
#   - 验证日志系统部署
#
# 使用示例:
#   ./deploy-logging.sh                        # 完整部署
#   ./deploy-logging.sh --skip-elasticsearch   # 跳过 ES 部署
#   ./deploy-logging.sh --verify-only          # 仅验证
#   ./deploy-logging.sh --dry-run              # 干运行模式
#
# 前置条件:
#   - kubectl 已安装并配置
#   - 集群可访问
#   - 足够的存储资源 (ES 需要 150Gi)
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_DIR="/var/log/elk-deploy"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
START_TIME=$(date +%s)

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

# 创建日志目录
mkdir -p "$LOG_DIR" 2>/dev/null || {
    log_warn "无法创建日志目录 $LOG_DIR，使用 /tmp"
    LOG_DIR="/tmp"
}

# ===== 帮助信息 =====
usage() {
    cat <<EOF
用法: $0 [选项]

阶段7: 日志系统 (ELK Stack) 部署

选项:
  --namespace, -n      日志命名空间 (默认: logging)
  --skip-elasticsearch 跳过 Elasticsearch 部署
  --skip-fluentd       跳过 Fluentd 部署
  --skip-kibana        跳过 Kibana 部署
  --verify-only        仅执行验证
  --dry-run            干运行模式 (不实际部署)
  --help, -h           显示帮助

示例:
  $0                              # 完整部署
  $0 -n logging-prod              # 指定命名空间
  $0 --skip-elasticsearch         # 跳过 ES 部署
  $0 --verify-only                # 仅验证
EOF
}

# ===== 参数解析 =====
NAMESPACE="logging"
SKIP_ES=false
SKIP_FLUENTD=false
SKIP_KIBANA=false
VERIFY_ONLY=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace|-n)        NAMESPACE="$2"; shift 2 ;;
        --skip-elasticsearch)  SKIP_ES=true; shift ;;
        --skip-fluentd)        SKIP_FLUENTD=true; shift ;;
        --skip-kibana)         SKIP_KIBANA=true; shift ;;
        --verify-only)         VERIFY_ONLY=true; shift ;;
        --dry-run)             DRY_RUN=true; shift ;;
        --help|-h)             usage; exit 0 ;;
        *) log_error "未知选项: $1"; usage; exit 1 ;;
    esac
done

# ===== 辅助函数 =====
# 应用 Manifest 文件
apply_manifest() {
    local file="$1"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] kubectl apply -f $file"
        return 0
    fi
    kubectl apply -f "$file" 2>&1 | tee -a "$LOG_DIR/apply-$TIMESTAMP.log"
}

# 等待 Deployment 就绪
wait_for_deployment() {
    local name="$1"
    local ns="$2"
    local timeout="${3:-300}"
    log_info "等待 $name/$ns 就绪 (超时: ${timeout}s)..."
    if kubectl wait --namespace="$ns" --for=condition=available deployment/"$name" --timeout="${timeout}s" 2>/dev/null; then
        log_ok "$name/$ns 已就绪"
        return 0
    else
        log_warn "$name/$ns 等待超时，检查Pod状态..."
        kubectl get pods -n "$ns" -l app="$name" --no-headers 2>/dev/null || true
        return 1
    fi
}

# 检查存储资源
check_storage() {
    log_info "检查存储资源..."
    local storage_classes
    storage_classes=$(kubectl get storageclass --no-headers 2>/dev/null | wc -l)
    if [[ "$storage_classes" -gt 0 ]]; then
        log_ok "可用 StorageClass: $storage_classes 个"
    else
        log_warn "未找到 StorageClass，可能影响持久化存储"
    fi
}

# ===== 检查前置条件 =====
log_info "检查日志系统部署前置条件..."

# 验证 kubectl
command -v kubectl >/dev/null 2>&1 || { log_error "kubectl 未安装"; exit 1; }

# 验证集群连接
if ! kubectl cluster-info >/dev/null 2>&1; then
    log_error "无法连接 Kubernetes 集群"
    exit 1
fi
log_ok "前置条件检查通过"

# ===== 显示部署信息 =====
echo "==========================================="
echo "  日志系统 (ELK Stack) 部署"
echo "  命名空间: $NAMESPACE"
echo "  干运行: $DRY_RUN"
echo "  时间: $(date)"
echo "==========================================="

# ===== 仅验证模式 =====
if [[ "$VERIFY_ONLY" == "true" ]]; then
    log_info "仅验证模式..."
    bash "$SCRIPT_DIR/04-verify-logging.sh" -n "$NAMESPACE"
    exit $?
fi

# ===== Step 1: 创建命名空间 =====
log_info "========== 步骤 0/4: 创建日志命名空间 =========="
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || {
    log_error "创建命名空间失败"
    exit 1
}
log_ok "命名空间 $NAMESPACE 已就绪"

# 检查存储
check_storage

# ===== Step 2: 部署 Elasticsearch =====
if [[ "$SKIP_ES" == "false" ]]; then
    log_info "========== 步骤 1/4: 部署 Elasticsearch =========="
    bash "$SCRIPT_DIR/01-deploy-elasticsearch.sh" -n "$NAMESPACE" || {
        log_error "Elasticsearch 部署失败"
        exit 1
    }
    wait_for_deployment "elasticsearch" "$NAMESPACE" 600
else
    log_info "========== 步骤 1/4: 跳过 Elasticsearch 部署 =========="
fi

# ===== Step 3: 部署 Fluentd =====
if [[ "$SKIP_FLUENTD" == "false" ]]; then
    log_info "========== 步骤 2/4: 部署 Fluentd =========="
    bash "$SCRIPT_DIR/02-deploy-fluentd.sh" -n "$NAMESPACE" || {
        log_error "Fluentd 部署失败"
        exit 1
    }
    # DaemonSet 不需要 wait_for_deployment，用 rollout status
    log_info "等待 Fluentd DaemonSet rollout..."
    kubectl rollout status daemonset/fluentd -n "$NAMESPACE" --timeout=300s 2>/dev/null || {
        log_warn "Fluentd rollout 等待超时"
    }
else
    log_info "========== 步骤 2/4: 跳过 Fluentd 部署 =========="
fi

# ===== Step 4: 部署 Kibana =====
if [[ "$SKIP_KIBANA" == "false" ]]; then
    log_info "========== 步骤 3/4: 部署 Kibana =========="
    bash "$SCRIPT_DIR/03-deploy-kibana.sh" -n "$NAMESPACE" || {
        log_error "Kibana 部署失败"
        exit 1
    }
    wait_for_deployment "kibana" "$NAMESPACE" 300
else
    log_info "========== 步骤 3/4: 跳过 Kibana 部署 =========="
fi

# ===== Step 5: 验证 =====
log_info "========== 步骤 4/4: 验证日志系统 =========="
bash "$SCRIPT_DIR/04-verify-logging.sh" -n "$NAMESPACE" || {
    log_warn "日志系统验证发现问题"
}

# ===== 部署结果汇总 =====
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log_ok "==========================================="
log_ok "  日志系统部署完成! (耗时: ${DURATION}s)"
log_ok "==========================================="
log_info "访问地址:"
log_info "  Kibana: http://<node-ip>:30561"
log_info "  Elasticsearch: kubectl port-forward -n $NAMESPACE svc/elasticsearch-client 9200:9200"
