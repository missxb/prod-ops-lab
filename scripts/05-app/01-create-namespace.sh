#!/usr/bin/env bash
###############################################################################
# 步骤1 - 创建命名空间
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

echo "===== 创建命名空间 (环境: ${ENV}) ====="

create_namespace() {
    local ns="$1"
    local manifest="${MANIFEST_DIR}/namespace/${ns}.yaml"

    info "应用命名空间配置: ${ns}"

    if kubectl get namespace "${ns}" &>/dev/null; then
        warn "命名空间 ${ns} 已存在，将更新配置"
    fi

    if [[ -f "$manifest" ]]; then
        kubectl apply -f "$manifest"
        ok "命名空间 ${ns} 已创建/更新"
    else
        kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
        ok "命名空间 ${ns} 已创建 (使用默认配置)"
    fi

    # 标签
    kubectl label namespace "${ns}" \
        app.kubernetes.io/managed-by=enterprise-platform \
        platform=enterprise-cloud-native \
        env="${ns}" \
        --overwrite

    ok "命名空间 ${ns} 标签已设置"
}

case "$ENV" in
    dev|prod)
        create_namespace "$ENV"
        ;;
    all)
        create_namespace dev
        create_namespace prod
        ;;
    *)
        fail "不支持的环境: ${ENV}"
        ;;
esac

echo ""
ok "命名空间创建完成"
