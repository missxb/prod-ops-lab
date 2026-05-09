#!/usr/bin/env bash
##############################################################################
# teardown-all.sh - 全阶段回滚脚本
# Enterprise Cloud Native Platform
# 功能: 按逆序执行所有阶段回滚 (阶段10 → 阶段1)
# 安全: 多级确认 + 彩色日志 + 完整回滚报告 + 干运行 + 状态快照
##############################################################################
set -euo pipefail

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/teardown"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/teardown-all_${TIMESTAMP}.log"
REPORT_FILE="${LOG_DIR}/rollback-report-all_${TIMESTAMP}.txt"
START_TIME=$(date +%s)
TOTAL_PHASES=10

# 阶段定义
declare -A PHASE_NAMES=(
    [1]="基础环境初始化"
    [2]="Kubernetes集群"
    [3]="存储层配置"
    [4]="CI/CD平台"
    [5]="应用部署"
    [6]="监控告警系统"
    [7]="日志系统"
    [8]="高可用架构"
    [9]="自动化运维"
    [10]="安全加固"
)

# 阶段回滚脚本
declare -A PHASE_SCRIPTS=(
    [1]="teardown-phase1.sh"
    [2]="teardown-phase2.sh"
    [3]="teardown-phase3.sh"
    [4]="teardown-phase4.sh"
    [5]="teardown-phase5.sh"
    [6]="teardown-phase6.sh"
    [7]="teardown-phase7.sh"
    [8]="teardown-phase8.sh"
    [9]="teardown-phase9.sh"
    [10]="teardown-phase10.sh"
)

# 执行结果
declare -A PHASE_RESULTS=()
SUCCESS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# 加载共享库
source "$SCRIPT_DIR/../lib/common.sh"

# ========================= 颜色定义 =========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# ========================= 日志函数 =========================
log_info()    { echo -e "${GREEN}[INFO]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_step()    { echo -e "${CYAN}[STEP]${NC}    $(date '+%Y-%m-%d %H:%M:%S') === $* ===" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[OK]${NC}      $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_header() {
    echo -e ""
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║${NC}  ${BOLD}${MAGENTA}$*${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo -e ""
}

log_banner() {
    echo -e ""
    echo -e "${BOLD}${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${RED}║                                                            ║${NC}"
    echo -e "${BOLD}${RED}║       企业级云原生运维平台 - 全阶段回滚                     ║${NC}"
    echo -e "${BOLD}${RED}║       Enterprise Cloud Native Platform                     ║${NC}"
    echo -e "${BOLD}${RED}║       Complete Rollback Script                             ║${NC}"
    echo -e "${BOLD}${RED}║                                                            ║${NC}"
    echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo -e ""
}

# ========================= 初始化 =========================
init() {
    mkdir -p "$LOG_DIR"
    log_banner
    log_info "回滚开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "回滚日志: $LOG_FILE"
    log_info "回滚报告: $REPORT_FILE"
    log_info "总阶段数: $TOTAL_PHASES"
    echo ""
}

# ========================= 确认提示 =========================
confirm_rollback() {
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║  ⚠️  警告: 即将执行全阶段回滚!                           ║${NC}"
    echo -e "${RED}${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}${BOLD}║                                                            ║${NC}"
    echo -e "${RED}${BOLD}║  回滚顺序: 阶段10 → 阶段1 (逆序执行)                     ║${NC}"
    echo -e "${RED}${BOLD}║                                                            ║${NC}"
    echo -e "${RED}${BOLD}║  将回滚以下阶段:                                          ║${NC}"
    for i in $(seq $TOTAL_PHASES -1 1); do
        echo -e "${RED}${BOLD}║    [${i}] ${PHASE_NAMES[$i]}$(printf '%*s' $((30-${#PHASE_NAMES[$i]})) '')║${NC}"
    done
    echo -e "${RED}${BOLD}║                                                            ║${NC}"
    echo -e "${RED}${BOLD}║  ⚠️  此操作不可逆! 请确保已备份重要数据!                 ║${NC}"
    echo -e "${RED}${BOLD}║                                                            ║${NC}"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    echo -ne "${YELLOW}请输入回滚确认码 ${RED}ROLLBACK-ALL${YELLOW} 继续: ${NC}"
    read -r confirm
    if [[ "$confirm" != "ROLLBACK-ALL" ]]; then
        echo -e "${RED}已取消全阶段回滚操作${NC}"
        exit 0
    fi
    
    echo ""
    echo -ne "${YELLOW}再次确认: 输入 YES 执行全阶段回滚: ${NC}"
    read -r confirm2
    if [[ "$confirm2" != "YES" ]]; then
        echo -e "${RED}已取消全阶段回滚操作${NC}"
        exit 0
    fi
    echo ""
}

# ========================= 单阶段回滚 =========================
rollback_phase() {
    local phase=$1
    local phase_name="${PHASE_NAMES[$phase]}"
    local script_name="${PHASE_SCRIPTS[$phase]}"
    local script_path="${SCRIPT_DIR}/${script_name}"
    local phase_start=$(date +%s)
    
    echo ""
    log_step "开始回滚阶段${phase}: ${phase_name}"
    
    if [[ ! -f "$script_path" ]]; then
        log_error "回滚脚本不存在: ${script_path}"
        PHASE_RESULTS[$phase]="SKIP"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        return 1
    fi
    
    if [[ ! -x "$script_path" ]]; then
        chmod +x "$script_path"
    fi
    
    # 执行阶段回滚脚本
    log_info "执行: ${script_path}"
    
    if bash "$script_path" 2>&1 | tee -a "$LOG_FILE"; then
        local phase_end=$(date +%s)
        local phase_duration=$((phase_end - phase_start))
        log_success "阶段${phase}回滚完成: ${phase_name} (耗时: ${phase_duration}秒)"
        PHASE_RESULTS[$phase]="SUCCESS"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        return 0
    else
        local phase_end=$(date +%s)
        local phase_duration=$((phase_end - phase_start))
        log_error "阶段${phase}回滚失败: ${phase_name} (耗时: ${phase_duration}秒)"
        PHASE_RESULTS[$phase]="FAIL"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi
}

# ========================= 全阶段回滚 =========================
execute_full_rollback() {
    log_header "开始全阶段回滚"
    log_info "回滚顺序: 阶段10 → 阶段1"
    echo ""
    
    local failed_phases=()
    
    # 按逆序执行回滚
    for phase in $(seq $TOTAL_PHASES -1 1); do
        if ! rollback_phase "$phase"; then
            failed_phases+=("$phase")
        fi
        
        # 阶段间等待
        if [[ $phase -gt 1 ]]; then
            log_info "等待3秒后继续下一阶段..."
            sleep 3
        fi
    done
    
    # 显示失败阶段
    if [[ ${#failed_phases[@]} -gt 0 ]]; then
        log_warn "以下阶段回滚失败:"
        for phase in "${failed_phases[@]}"; do
            log_warn "  - 阶段${phase}: ${PHASE_NAMES[$phase]}"
        done
    fi
}

# ========================= 生成报告 =========================
generate_report() {
    local end_time=$(date +%s)
    local total_duration=$((end_time - START_TIME))
    
    echo "" >> "$REPORT_FILE"
    echo "╔══════════════════════════════════════════════════════════════╗" >> "$REPORT_FILE"
    echo "║            企业级云原生运维平台 - 全阶段回滚报告            ║" >> "$REPORT_FILE"
    echo "╚══════════════════════════════════════════════════════════════╝" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "回滚信息:" >> "$REPORT_FILE"
    echo "  开始时间: $(date -d @$START_TIME '+%Y-%m-%d %H:%M:%S')" >> "$REPORT_FILE"
    echo "  结束时间: $(date '+%Y-%m-%d %H:%M:%S')" >> "$REPORT_FILE"
    echo "  总耗时:   $(common_format_duration $total_duration)" >> "$REPORT_FILE"
    echo "  操作主机: $(hostname)" >> "$REPORT_FILE"
    echo "  日志文件: $LOG_FILE" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "回滚结果汇总:" >> "$REPORT_FILE"
    echo "┌─────────┬──────────────────────┬──────────┐" >> "$REPORT_FILE"
    echo "│ 阶段    │ 名称                 │ 状态     │" >> "$REPORT_FILE"
    echo "├─────────┼──────────────────────┼──────────┤" >> "$REPORT_FILE"
    for i in $(seq $TOTAL_PHASES -1 1); do
        local status="${PHASE_RESULTS[$i]:-N/A}"
        local status_color=""
        case "$status" in
            SUCCESS) status_color="${GREEN}✓ 成功${NC}" ;;
            FAIL)    status_color="${RED}✗ 失败${NC}" ;;
            SKIP)    status_color="${YELLOW}⊘ 跳过${NC}" ;;
            *)       status_color="${YELLOW}? 未执行${NC}" ;;
        esac
        printf "│ [%2d]    │ %-20s │ %-8s │\n" "$i" "${PHASE_NAMES[$i]}" "$status" >> "$REPORT_FILE"
    done
    echo "└─────────┴──────────────────────┴──────────┘" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "统计:" >> "$REPORT_FILE"
    echo "  成功: ${SUCCESS_COUNT}" >> "$REPORT_FILE"
    echo "  失败: ${FAIL_COUNT}" >> "$REPORT_FILE"
    echo "  跳过: ${SKIP_COUNT}" >> "$REPORT_FILE"
    echo "  总计: ${TOTAL_PHASES}" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "注意事项:" >> "$REPORT_FILE"
    echo "  1. 请检查各阶段回滚日志确认回滚完整性" >> "$REPORT_FILE"
    echo "  2. 部分配置可能需要手动验证和清理" >> "$REPORT_FILE"
    echo "  3. 建议在回滚后重启系统以确保所有更改生效" >> "$REPORT_FILE"
    echo "  4. 如有问题请查看详细日志: $LOG_FILE" >> "$REPORT_FILE"
    
    # 终端显示报告
    log_header "全阶段回滚完成"
    echo ""
    echo -e "${BOLD}回滚结果汇总:${NC}"
    echo ""
    for i in $(seq $TOTAL_PHASES -1 1); do
        local status="${PHASE_RESULTS[$i]:-N/A}"
        case "$status" in
            SUCCESS) echo -e "  ${GREEN}✓${NC} 阶段${i}: ${PHASE_NAMES[$i]}" ;;
            FAIL)    echo -e "  ${RED}✗${NC} 阶段${i}: ${PHASE_NAMES[$i]}" ;;
            SKIP)    echo -e "  ${YELLOW}⊘${NC} 阶段${i}: ${PHASE_NAMES[$i]}" ;;
            *)       echo -e "  ${YELLOW}?${NC} 阶段${i}: ${PHASE_NAMES[$i]}" ;;
        esac
    done
    echo ""
    log_info "总耗时: ${total_duration}秒"
    log_info "成功: ${SUCCESS_COUNT} | 失败: ${FAIL_COUNT} | 跳过: ${SKIP_COUNT}"
    log_info "回滚报告: $REPORT_FILE"
    log_info "详细日志: $LOG_FILE"
    
    # 读取并显示纯文本报告
    echo ""
    cat "$REPORT_FILE"
}

# ========================= 帮助信息 =========================
show_help() {
    cat <<EOF
企业级云原生运维平台 - 全阶段回滚脚本

用法: $(basename "$0") [选项]

选项:
    -h, --help          显示此帮助信息
    -p, --phase <N>     仅回滚指定阶段 (1-10)
    -f, --force         跳过确认提示 (危险!)
    --dry-run           干运行，仅显示将要执行的操作
    --report-only       仅生成回滚报告

示例:
    $(basename "$0")                    # 回滚所有阶段
    $(basename "$0") -p 5              # 仅回滚阶段5
    $(basename "$0") --dry-run         # 干运行
    $(basename "$0") -f                # 跳过确认 (不推荐)

回滚阶段:
    10 → 安全加固
     9 → 自动化运维
     8 → 高可用架构
     7 → 日志系统
     6 → 监控告警系统
     5 → 应用部署
     4 → CI/CD平台
     3 → 存储层配置
     2 → Kubernetes集群
     1 → 基础环境初始化

EOF
}

# ========================= 主逻辑 =========================
main() {
    local force_mode=false
    local dry_run=false
    local single_phase=""
    local report_only=false
    
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -p|--phase)
                single_phase="$2"
                shift 2
                ;;
            -f|--force)
                force_mode=true
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --report-only)
                report_only=true
                shift
                ;;
            *)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    init
    
    if [[ "$report_only" == "true" ]]; then
        log_info "仅生成报告模式"
        generate_report
        exit 0
    fi
    
    if [[ "$dry_run" == "true" ]]; then
        log_header "干运行模式 - 仅显示将要执行的操作"
        for phase in $(seq $TOTAL_PHASES -1 1); do
            log_info "[干运行] 阶段${phase}: ${PHASE_NAMES[$phase]} → ${PHASE_SCRIPTS[$phase]}"
        done
        log_info "干运行完成，未执行任何操作"
        exit 0
    fi
    
    if [[ -n "$single_phase" ]]; then
        # 单阶段回滚
        if [[ $single_phase -lt 1 || $single_phase -gt $TOTAL_PHASES ]]; then
            log_error "无效的阶段号: $single_phase (有效范围: 1-${TOTAL_PHASES})"
            exit 1
        fi
        
        log_header "单阶段回滚: 阶段${single_phase} - ${PHASE_NAMES[$single_phase]}"
        
        if [[ "$force_mode" != "true" ]]; then
            echo -ne "${YELLOW}是否确认回滚阶段${single_phase}? 输入 YES 继续: ${NC}"
            read -r confirm
            [[ "$confirm" == "YES" ]] || { echo "已取消"; exit 0; }
        fi
        
        rollback_phase "$single_phase"
        generate_report
    else
        # 全阶段回滚
        if [[ "$force_mode" != "true" ]]; then
            confirm_rollback
        fi
        
        execute_full_rollback
        generate_report
    fi
}

main "$@"
