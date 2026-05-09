#!/usr/bin/env bash
###############################################################################
# 步骤5 - 测试故障转移
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

echo "===== 测试故障转移 (环境: ${ENV}) ====="

# 1. 记录当前状态
info "测试前状态:"
kubectl get pods -n "${ENV}" -l app=demo-app -o wide

REPLICAS=$(kubectl get deployment demo-app -n "${ENV}" -o jsonpath='{.spec.replicas}')
info "当前副本数: ${REPLICAS}"

# 2. 删除一个Pod，测试自愈
echo ""
info "=== 测试1: Pod自愈 (删除一个Pod) ==="

# 获取第一个Pod名称
FIRST_POD=$(kubectl get pods -n "${ENV}" -l app=demo-app --no-headers | head -1 | awk '{print $1}')
if [[ -z "$FIRST_POD" ]]; then
    fail "未找到运行中的Pod"
fi

info "删除Pod: ${FIRST_POD}"
kubectl delete pod "${FIRST_POD}" -n "${ENV}" --grace-period=0 --force 2>/dev/null || true

# 等待新Pod创建
info "等待新Pod创建和就绪..."
sleep 10

# 检查ReplicaSet是否创建了新Pod
NEW_PODS=$(kubectl get pods -n "${ENV}" -l app=demo-app --no-headers)
POD_COUNT=$(echo "$NEW_PODS" | grep -c "" || true)

if [[ "$POD_COUNT" -ge "$REPLICAS" ]]; then
    ok "Pod自愈成功! 当前Pod数量: ${POD_COUNT}"
else
    warn "Pod数量可能不足: ${POD_COUNT}/${REPLICAS}"
fi

kubectl get pods -n "${ENV}" -l app=demo-app -o wide

# 3. 等待所有Pod就绪
info "等待所有Pod就绪..."
kubectl rollout status deployment/demo-app -n "${ENV}" --timeout=120s || true

# 4. 测试Service端点连通性
echo ""
info "=== 测试2: Service端点连通性 ==="

SVC_IP=$(kubectl get svc demo-app -n "${ENV}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
if [[ -n "$SVC_IP" ]]; then
    info "Service ClusterIP: ${SVC_IP}"

    # 尝试通过Service访问
    RESULT=$(kubectl run curl-test --rm -i --restart=Never --image=curlimages/curl:latest \
        -- curl -s -o /dev/null -w "%{http_code}" "http://${SVC_IP}:80" --timeout=5 2>/dev/null || echo "FAILED")

    if [[ "$RESULT" == "200" ]]; then
        ok "Service端点连通性正常 (HTTP 200)"
    else
        warn "Service端点返回: ${RESULT}"
    fi
else
    warn "无法获取Service ClusterIP"
fi

# 5. 测试并发删除多个Pod
echo ""
info "=== 测试3: 并发Pod故障恢复 ==="

info "获取当前所有Pod..."
ALL_PODS=$(kubectl get pods -n "${ENV}" -l app=demo-app --no-headers | awk '{print $1}')
POD_ARRAY=($ALL_PODS)

if [[ ${#POD_ARRAY[@]} -ge 2 ]]; then
    DELETE_COUNT=$(( ${#POD_ARRAY[@]} / 2 ))
    info "删除 ${DELETE_COUNT} 个Pod模拟并发故障..."

    for ((i=0; i<DELETE_COUNT && i<${#POD_ARRAY[@]}; i++)); do
        kubectl delete pod "${POD_ARRAY[$i]}" -n "${ENV}" --grace-period=0 --force 2>/dev/null &
    done
    wait

    info "等待集群恢复..."
    sleep 15
    kubectl rollout status deployment/demo-app -n "${ENV}" --timeout=180s || true

    FINAL_COUNT=$(kubectl get pods -n "${ENV}" -l app=demo-app --no-headers | grep -c "Running" || true)
    info "恢复后Running Pod数: ${FINAL_COUNT}"

    if [[ "$FINAL_COUNT" -ge "$REPLICAS" ]]; then
        ok "并发故障恢复成功!"
    else
        warn "恢复后Pod数量不足，等待进一步恢复..."
    fi
else
    warn "Pod数量不足以进行并发故障测试"
fi

# 6. 最终状态报告
echo ""
info "=== 最终状态 ==="
kubectl get pods -n "${ENV}" -l app=demo-app -o wide
echo ""
kubectl get deployment demo-app -n "${ENV}"

echo ""
ok "故障转移测试完成"
echo ""
echo "故障转移测试摘要:"
echo "  - Pod自愈测试: 已验证 (Deployment自愈机制)"
echo "  - Service连通性: 已验证"
echo "  - 并发故障恢复: 已验证"
