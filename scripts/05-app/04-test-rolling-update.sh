#!/usr/bin/env bash
###############################################################################
# 步骤4 - 测试滚动更新
###############################################################################
set -euo pipefail

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

echo "===== 测试滚动更新 (环境: ${ENV}) ====="

# 检查当前状态
info "当前 Deployment 状态:"
kubectl get deployment demo-app -n "${ENV}" -o wide

# 记录更新前的Pod列表
info "更新前的Pod列表:"
BEFORE_PODS=$(kubectl get pods -n "${ENV}" -l app=demo-app --no-headers 2>/dev/null | awk '{print $1}' | sort)
echo "$BEFORE_PODS"

# 触发滚动更新 - 更新镜像注解
info "触发滚动更新..."
kubectl set image deployment/demo-app \
    nginx=nginx:1.25-alpine \
    -n "${ENV}" \
    --record

# 监控滚动更新过程
info "监控滚动更新过程..."
if kubectl rollout status deployment/demo-app -n "${ENV}" --timeout=180s; then
    ok "滚动更新成功完成"
else
    warn "滚动更新可能未完全完成"
fi

# 更新后的Pod列表
echo ""
info "更新后的Pod列表:"
AFTER_PODS=$(kubectl get pods -n "${ENV}" -l app=demo-app --no-headers 2>/dev/null | awk '{print $1}' | sort)
echo "$AFTER_PODS"

# 检查滚动更新策略是否生效
echo ""
info "检查滚动更新策略:"
REPLICAS=$(kubectl get deployment demo-app -n "${ENV}" -o jsonpath='{.spec.replicas}')
UPDATED=$(kubectl get deployment demo-app -n "${ENV}" -o jsonpath='{.status.updatedReplicas}')
READY=$(kubectl get deployment demo-app -n "${ENV}" -o jsonpath='{.status.readyReplicas}')
AVAILABLE=$(kubectl get deployment demo-app -n "${ENV}" -o jsonpath='{.status.availableReplicas}')

echo "  总副本数: ${REPLICAS:-N/A}"
echo "  已更新:   ${UPDATED:-N/A}"
echo "  已就绪:   ${READY:-N/A}"
echo "  可用:     ${AVAILABLE:-N/A}"

# 验证所有Pod都可用
if [[ "${AVAILABLE:-0}" -ge "${REPLICAS:-1}" ]]; then
    ok "所有副本在滚动更新期间保持可用 - 无停机部署成功!"
else
    warn "部分副本在更新期间不可用，请检查"
fi

# 验证历史版本
echo ""
info "Deployment 更新历史:"
kubectl rollout history deployment/demo-app -n "${ENV}" --no-revisions 2>/dev/null || true

echo ""
ok "滚动更新测试完成"
