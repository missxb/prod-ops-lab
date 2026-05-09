#!/usr/bin/env bash
###############################################################################
# 步骤2 - 部署示例应用
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

echo "===== 部署示例应用 (环境: ${ENV}) ====="

# 确保命名空间存在
kubectl create namespace "${ENV}" --dry-run=client -o yaml | kubectl apply -f -

info "应用 ConfigMap..."
kubectl apply -f "${MANIFEST_DIR}/app/demo-configmap.yaml" -n "${ENV}"

info "应用 Secret..."
kubectl apply -f "${MANIFEST_DIR}/app/demo-secret.yaml" -n "${ENV}"

info "应用 Deployment..."
kubectl apply -f "${MANIFEST_DIR}/app/demo-app.yaml" -n "${ENV}"

info "应用 Service..."
kubectl apply -f "${MANIFEST_DIR}/app/demo-service.yaml" -n "${ENV}"

info "应用 Ingress..."
kubectl apply -f "${MANIFEST_DIR}/app/demo-ingress.yaml" -n "${ENV}"

# 等待就绪
info "等待 Deployment 就绪..."
kubectl rollout status deployment/demo-app -n "${ENV}" --timeout=120s || warn "Deployment 未在超时内就绪"

echo ""
info "部署状态:"
kubectl get all -n "${ENV}" -l app=demo-app

echo ""
ok "示例应用部署完成"
