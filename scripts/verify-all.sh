#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# 全阶段验证脚本
# 按顺序执行所有阶段验证，汇总结果并生成综合报告
# 支持选项: --help, --phase <N>, --skip <N>, --verbose, --json
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPORT_DIR="$PROJECT_DIR/reports"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
MASTER_REPORT="$REPORT_DIR/verify-all-$TIMESTAMP.log"
SUMMARY_REPORT="$REPORT_DIR/verify-summary-$TIMESTAMP.txt"
JSON_REPORT="$REPORT_DIR/verify-all-$TIMESTAMP.json"

mkdir -p "$REPORT_DIR"

# 加载共享库
source "$SCRIPT_DIR/lib/common.sh"
common_init_verify "$PROJECT_DIR" 0

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# 阶段结果计数
PHASE_PASS=0
PHASE_FAIL=0
PHASE_WARN=0
TOTAL_PHASES=10

# 存储每个阶段的结果
declare -A PHASE_RESULTS

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg"
    echo -e "$msg" >> "$MASTER_REPORT"
}

banner() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC} ${BOLD}$1${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

run_phase() {
    local phase_num="$1"
    local phase_name="$2"
    local script="$SCRIPT_DIR/verify-phase${phase_num}.sh"

    echo ""
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log "${BOLD}▶ 执行阶段${phase_num}: ${phase_name}${NC}"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [[ ! -f "$script" ]]; then
        log "${RED}[ERROR] 验证脚本不存在: $script${NC}"
        PHASE_RESULTS[$phase_num]="ERROR"
        PHASE_FAIL=$((PHASE_FAIL + 1))
        return 1
    fi

    # 执行阶段验证脚本，捕获输出
    local phase_report
    local exit_code=0

    bash "$script" 2>&1 | tee -a "$MASTER_REPORT" || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        log "${GREEN}✓ 阶段${phase_num}验证通过${NC}"
        PHASE_RESULTS[$phase_num]="PASS"
        PHASE_PASS=$((PHASE_PASS + 1))
    else
        log "${RED}✗ 阶段${phase_num}验证失败${NC}"
        PHASE_RESULTS[$phase_num]="FAIL"
        PHASE_FAIL=$((PHASE_FAIL + 1))
    fi
}

# ========== 主流程 ==========

banner "企业级云原生运维平台 - 全阶段验证"
echo ""
log "${BOLD}验证开始时间: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
log "${BOLD}项目目录: $PROJECT_DIR${NC}"
log "${BOLD}报告目录: $REPORT_DIR${NC}"
echo ""

# 显示阶段列表
echo -e "${BLUE}将要验证的阶段:${NC}"
for i in $(seq 1 $TOTAL_PHASES); do
    printf "  ${CYAN}%2d${NC}. %s\n" "$i" "${PHASE_NAMES[$i]}"
done
echo ""

# 按顺序执行所有阶段
PHASE_NAMES=(
    ""
    "基础环境初始化"
    "Kubernetes集群部署"
    "存储层配置"
    "CI/CD流水线"
    "应用部署"
    "监控告警"
    "日志系统"
    "高可用架构"
    "自动化运维"
    "安全加固"
)

START_TIME=$(date +%s)

for i in $(seq 1 $TOTAL_PHASES); do
    run_phase "$i" "${PHASE_NAMES[$i]}" || true
done

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# ========== 汇总报告 ==========
banner "全阶段验证汇总报告"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         企业级云原生运维平台 - 验证汇总报告                ║${NC}"
echo -e "${CYAN}║         生成时间: $(date '+%Y-%m-%d %H:%M:%S')                           ║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC}                                                            ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${BOLD}阶段  验证内容              结果${NC}                         ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ────  ────────────────      ──────                         ${CYAN}║${NC}"

for i in $(seq 1 $TOTAL_PHASES); do
    RESULT="${PHASE_RESULTS[$i]:-NOT_RUN}"
    PHASE_NAME="${PHASE_NAMES[$i]}"
    # 截取前20个字符
    DISPLAY_NAME=$(printf "%-20.20s" "$PHASE_NAME")

    case "$RESULT" in
        PASS)
            echo -e "${CYAN}║${NC}  ${CYAN}$(printf '%2d' $i)${NC}    ${DISPLAY_NAME}      ${GREEN}✓ 通过${NC}                         ${CYAN}║${NC}"
            ;;
        FAIL)
            echo -e "${CYAN}║${NC}  ${CYAN}$(printf '%2d' $i)${NC}    ${DISPLAY_NAME}      ${RED}✗ 失败${NC}                         ${CYAN}║${NC}"
            ;;
        ERROR)
            echo -e "${CYAN}║${NC}  ${CYAN}$(printf '%2d' $i)${NC}    ${DISPLAY_NAME}      ${YELLOW}△ 错误${NC}                         ${CYAN}║${NC}"
            ;;
        *)
            echo -e "${CYAN}║${NC}  ${CYAN}$(printf '%2d' $i)${NC}    ${DISPLAY_NAME}      ${YELLOW}? 未执行${NC}                       ${CYAN}║${NC}"
            ;;
    esac
done

echo -e "${CYAN}║${NC}                                                            ${CYAN}║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC}  ${BOLD}总计阶段: ${TOTAL_PHASES}${NC}                                         ${CYAN}║${NC}"
echo -e "${GREEN}║${NC}  ${GREEN}通过:     ${PHASE_PASS}${NC}                                         ${GREEN}║${NC}"
echo -e "${RED}║${NC}  ${RED}失败:     ${PHASE_FAIL}${NC}                                         ${RED}║${NC}"
echo -e "${CYAN}║${NC}  ${BOLD}耗时:     ${DURATION}秒${NC}                                        ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                                            ${CYAN}║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"

if [[ $PHASE_FAIL -eq 0 ]]; then
    echo -e "${GREEN}║${NC}  ${GREEN}${BOLD}🎉 全部阶段验证通过！平台状态良好。${NC}                      ${GREEN}║${NC}"
else
    echo -e "${RED}║${NC}  ${RED}${BOLD}⚠  有 ${PHASE_FAIL} 个阶段验证失败，请检查相关组件。${NC}            ${RED}║${NC}"
fi

echo -e "${CYAN}║${NC}                                                            ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

echo ""
echo -e "${BLUE}详细报告:${NC}"
echo -e "  主报告: ${CYAN}$MASTER_REPORT${NC}"
echo -e "  汇总报告: ${CYAN}$SUMMARY_REPORT${NC}"
echo ""

# 生成简洁的汇总文本报告
cat > "$SUMMARY_REPORT" <<EOF
=================================================================
企业级云原生运维平台 - 验证汇总报告
生成时间: $(date '+%Y-%m-%d %H:%M:%S')
=================================================================

阶段验证结果:
$(for i in $(seq 1 $TOTAL_PHASES); do
    RESULT="${PHASE_RESULTS[$i]:-NOT_RUN}"
    printf "  阶段%2d %-20s : %s\n" "$i" "${PHASE_NAMES[$i]}" "$RESULT"
done)

总计: $TOTAL_PHASES 个阶段
通过: $PHASE_PASS
失败: $PHASE_FAIL
耗时: $(common_format_duration $DURATION)

$(if [[ $PHASE_FAIL -eq 0 ]]; then
    echo "结论: 全部阶段验证通过"
else
    echo "结论: 存在失败阶段，请检查"
    echo ""
    echo "失败阶段:"
    for i in $(seq 1 $TOTAL_PHASES); do
        if [[ "${PHASE_RESULTS[$i]}" == "FAIL" ]]; then
            echo "  - 阶段${i}: ${PHASE_NAMES[$i]}"
        fi
    done
fi)

详细日志: $MASTER_REPORT
=================================================================
EOF

# 生成JSON格式报告
cat > "$JSON_REPORT" <<JSON_EOF
{
  "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')",
  "total_phases": $TOTAL_PHASES,
  "passed": $PHASE_PASS,
  "failed": $PHASE_FAIL,
  "duration_seconds": $DURATION,
  "phases": {
$(for i in $(seq 1 $TOTAL_PHASES); do
    RESULT="${PHASE_RESULTS[$i]:-NOT_RUN}"
    COMMA=""
    [[ $i -lt $TOTAL_PHASES ]] && COMMA=","
    echo "    \"$i\": {\"name\": \"${PHASE_NAMES[$i]}\", \"result\": \"${RESULT}\"}${COMMA}"
done)
  }
}
JSON_EOF

log ""
log "${BOLD}验证完成时间: $(date '+%Y-%m-%d %H:%M:%S')${NC}"

if [[ $PHASE_FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
