#!/usr/bin/env bash
###############################################################################
# 阶段5 - 应用部署主脚本
# Enterprise Cloud Native Platform
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="$(cd "${SCRIPT_DIR}/../../manifests" && pwd)"

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

ENV="${1:-dev}"
NAMESPACES=("dev" "prod")

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

# 检查 kubectl
command -v kubectl &>/dev/null || fail "kubectl 未安装"

run_step() {
    local step_num="$1"
    local step_name="$2"
    local step_script="$3"

    if [[ -n "$STEP_ONLY" && "$STEP_ONLY" != "$step_num" ]]; then
        return 0
    fi

    info "执行步骤 ${step_num}: ${step_name}"
    if [[ "$DRY_RUN" == true ]]; then
        warn "[DRY-RUN] 跳过: ${step_script}"
        return 0
    fi

    if [[ -x "$step_script" ]]; then
        "$step_script" -e "$ENV" || warn "步骤 ${step_num} 未完全成功"
    else
        fail "脚本不存在或不可执行: ${step_script}"
    fi
    ok "步骤 ${step_num}: ${step_name} 完成"
    echo ""
}

run_step 1 "创建命名空间"        "${SCRIPT_DIR}/01-create-namespace.sh"
run_step 2 "部署示例应用"        "${SCRIPT_DIR}/02-deploy-demo-app.sh"
run_step 3 "配置HPA自动扩缩容"   "${SCRIPT_DIR}/03-configure-hpa.sh"
run_step 4 "测试滚动更新"        "${SCRIPT_DIR}/04-test-rolling-update.sh"
run_step 5 "测试故障转移"        "${SCRIPT_DIR}/05-test-failover.sh"

echo "=============================================="
ok "阶段5 - 应用部署完成!"
echo "=============================================="
