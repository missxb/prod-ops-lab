#!/usr/bin/env bash
###############################################################################
# 步骤3 - 配置HPA自动扩缩容
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="$(cd "${SCRIPT_DIR}/../../manifests" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

ENV="dev"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--env) ENV="$2"; shift 2 ;;
        *) shift ;;
    esac
done

echo "===== 配置HPA自动扩缩容 (环境: ${ENV}) ====="

# 检查 metrics-server
info "检查 Metrics Server..."
if kubectl get deployment metrics-server -n kube-system &>/dev/null; then
    ok "Metrics Server 已安装"
else
    warn "Metrics Server 未安装，HPA 可能无法正常工作"
    warn "安装命令: kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
fi

# 应用 HPA 配置
info "应用 HPA 配置..."
kubectl apply -f "${MANIFEST_DIR}/app/demo-hpa.yaml" -n "${ENV}"

# 等待 HPA 就绪
sleep 5

info "HPA 状态:"
kubectl get hpa -n "${ENV}"

echo ""
info "HPA 详情:"
kubectl describe hpa demo-app-hpa -n "${ENV}" 2>/dev/null || warn "HPA 详情获取失败"

echo ""
ok "HPA 自动扩缩容配置完成"
echo ""
echo "HPA 配置摘要:"
echo "  - 目标CPU使用率: 70%"
echo "  - 最小副本数: 2"
echo "  - 最大副本数: 10"
