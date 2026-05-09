#!/usr/bin/env bash
###############################################################################
# 阶段5 - 应用部署主脚本
# Enterprise Cloud Native Platform
#
# 描述:
#   编排应用部署的完整流程，包括命名空间创建、Demo 应用部署、
#   HPA 自动扩缩容配置、滚动更新测试和故障转移测试。
#
# 用法:
#   ./deploy-app.sh [OPTIONS]
#
# Options:
#   -e, --env ENV       目标环境 (dev|prod), 默认: dev
#   -a, --all           部署所有环境
#   -s, --step STEP     仅执行指定步骤 (1-5)
#   -n, --namespace NS  仅部署到指定命名空间
#   -d, --dry-run       仅模拟运行
#   -h, --help          显示帮助
#
# Steps:
#   1 - 创建命名空间
#   2 - 部署示例应用
#   3 - 配置HPA自动扩缩容
#   4 - 测试滚动更新
#   5 - 测试故障转移
#
# 示例:
#   ./deploy-app.sh --env dev
#   ./deploy-app.sh --env prod --step 2
#   ./deploy-app.sh --all
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="$(cd "${SCRIPT_DIR}/../../manifests" && pwd)"

# 颜色定义
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

ENV="${1:-dev}"
NAMESPACES=("dev" "prod")

# usage - 显示帮助信息
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

阶段5 - 应用部署

Options:
    -e, --env ENV       目标环境 (dev|prod), 默认: dev
    -a, --all           部署所有环境
    -s, --step STEP     仅执行指定步骤 (1-5)
    -n, --namespace NS  仅部署到指定命名空间
    -d, --dry-run       仅模拟运行
    -h, --help          显示帮助

Steps:
    1 - 创建命名空间
    2 - 部署示例应用
    3 - 配置HPA自动扩缩容
    4 - 测试滚动更新
    5 - 测试故障转移

Examples:
    $0 --env dev
    $0 --env prod --step 2
    $0 --all
EOF
}

DRY_RUN=false
ALL_ENVS=false
STEP_ONLY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--env) ENV="$2"; shift 2 ;;
        -a|--all) ALL_ENVS=true; shift ;;
        -s|--step) STEP_ONLY="$2"; shift 2 ;;
        -n|--namespace) ONLY_NS="$2"; shift 2 ;;
        -d|--dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) warn "未知参数: $1"; shift ;;
    esac
done

echo "=============================================="
echo "  阶段5 - 应用部署"
echo "  环境: ${ENV}"
echo "  平台: Enterprise Cloud Native Platform"
echo "=============================================="
echo ""

# 检查 kubectl 是否安装
command -v kubectl &>/dev/null || fail "kubectl 未安装，请先安装 kubectl"
# 检查集群连接
kubectl cluster-info &>/dev/null || fail "无法连接到 Kubernetes 集群"

# run_step - 执行单个部署步骤
# Args:
#   $1 - 步骤编号
#   $2 - 步骤名称
#   $3 - 脚本路径
run_step() {
    local step_num="$1"
    local step_name="$2"
    local step_script="$3"

    # 如果指定了步骤过滤，跳过不匹配的步骤
    if [[ -n "$STEP_ONLY" && "$STEP_ONLY" != "$step_num" ]]; then
        return 0
    fi

    info "执行步骤 ${step_num}: ${step_name}"
    if [[ "$DRY_RUN" == true ]]; then
        warn "[DRY-RUN] 跳过: ${step_script}"
        return 0
    fi

    # 检查脚本是否存在且可执行
    if [[ -x "$step_script" ]]; then
        if "$step_script" -e "$ENV"; then
            ok "步骤 ${step_num}: ${step_name} 完成"
        else
            warn "步骤 ${step_num} 未完全成功"
        fi
    else
        fail "脚本不存在或不可执行: ${step_script}"
    fi
    echo ""
}

# 按顺序执行各部署步骤
run_step 1 "创建命名空间"        "${SCRIPT_DIR}/01-create-namespace.sh"
run_step 2 "部署示例应用"        "${SCRIPT_DIR}/02-deploy-demo-app.sh"
run_step 3 "配置HPA自动扩缩容"   "${SCRIPT_DIR}/03-configure-hpa.sh"
run_step 4 "测试滚动更新"        "${SCRIPT_DIR}/04-test-rolling-update.sh"
run_step 5 "测试故障转移"        "${SCRIPT_DIR}/05-test-failover.sh"

echo "=============================================="
ok "阶段5 - 应用部署完成!"
echo "=============================================="
