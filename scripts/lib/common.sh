#!/usr/bin/env bash
###############################################################################
# common.sh - 共享函数库
# Enterprise Cloud Native Platform
# 提供验证和回滚脚本共用的日志、计数、报告、工具函数
###############################################################################

# 防止重复加载
[[ -n "${_COMMON_SH_LOADED:-}" ]] && return 0
_COMMON_SH_LOADED=1

# ========================= 颜色定义 =========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ========================= 计数器 =========================
COMMON_PASS_COUNT=0
COMMON_FAIL_COUNT=0
COMMON_WARN_COUNT=0
COMMON_SKIP_COUNT=0
COMMON_TOTAL_COUNT=0

# ========================= 时间追踪 =========================
COMMON_SCRIPT_START=0
COMMON_SECTION_START=0

# ========================= 日志函数 =========================

# 通用日志 (同时输出到终端和日志文件)
# 用法: common_log "message" [log_file]
common_log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg"
    [[ -n "${2:-}" ]] && echo "$msg" >> "$2"
}

# 调试日志 (仅在 DEBUG 模式输出)
common_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo -e "${DIM}[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') $*${NC}" >&2
    fi
}

# 信息日志
common_info() {
    local msg="[INFO]    $(date '+%Y-%m-%d %H:%M:%S') $*"
    echo -e "${GREEN}[INFO]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*"
}

# 警告日志
common_warn() {
    local msg="[WARN]    $(date '+%Y-%m-%d %H:%M:%S') $*"
    echo -e "${YELLOW}[WARN]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*"
}

# 错误日志
common_error() {
    local msg="[ERROR]   $(date '+%Y-%m-%d %H:%M:%S') $*"
    echo -e "${RED}[ERROR]${NC}   $(date '+%Y-%m-%d %H:%M:%S') $*"
}

# 成功日志
common_success() {
    local msg="[OK]      $(date '+%Y-%m-%d %H:%M:%S') $*"
    echo -e "${GREEN}[OK]${NC}      $(date '+%Y-%m-%d %H:%M:%S') $*"
}

# 步骤日志
common_step() {
    echo -e ""
    echo -e "${CYAN}[STEP]${NC}    $(date '+%Y-%m-%d %H:%M:%S') === $* ==="
}

# 标题日志
common_header() {
    echo ""
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║${NC}  ${BOLD}${MAGENTA}$*${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ========================= 验证计数器函数 =========================

# 通过
common_pass() {
    COMMON_PASS_COUNT=$((COMMON_PASS_COUNT + 1))
    COMMON_TOTAL_COUNT=$((COMMON_TOTAL_COUNT + 1))
    echo -e "${GREEN}[PASS]${NC} $*"
}

# 失败
common_fail() {
    COMMON_FAIL_COUNT=$((COMMON_FAIL_COUNT + 1))
    COMMON_TOTAL_COUNT=$((COMMON_TOTAL_COUNT + 1))
    echo -e "${RED}[FAIL]${NC} $*"
}

# 警告
common_warn_check() {
    COMMON_WARN_COUNT=$((COMMON_WARN_COUNT + 1))
    COMMON_TOTAL_COUNT=$((COMMON_TOTAL_COUNT + 1))
    echo -e "${YELLOW}[WARN]${NC} $*"
}

# 跳过
common_skip() {
    COMMON_SKIP_COUNT=$((COMMON_SKIP_COUNT + 1))
    COMMON_TOTAL_COUNT=$((COMMON_TOTAL_COUNT + 1))
    echo -e "${DIM}[SKIP]${NC} $*"
}

# 信息
common_info_check() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

# ========================= 计时函数 =========================

# 开始计时
common_timer_start() {
    COMMON_SCRIPT_START=$(date +%s)
}

# 获取耗时
common_timer_elapsed() {
    local now=$(date +%s)
    echo $((now - COMMON_SCRIPT_START))
}

# 开始段计时
common_section_start() {
    COMMON_SECTION_START=$(date +%s)
}

# 段耗时
common_section_elapsed() {
    local now=$(date +%s)
    echo $((now - COMMON_SECTION_START))
}

# 格式化耗时
common_format_duration() {
    local seconds=$1
    if [[ $seconds -lt 60 ]]; then
        echo "${seconds}秒"
    elif [[ $seconds -lt 3600 ]]; then
        echo "$((seconds / 60))分$((seconds % 60))秒"
    else
        echo "$((seconds / 3600))时$((seconds % 3600 / 60))分"
    fi
}

# ========================= 系统信息函数 =========================

# 获取系统信息
common_get_system_info() {
    local info=""
    info+="操作系统: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || echo 'unknown')"
    info+="\n内核版本: $(uname -r)"
    info+="\n主机名:   $(hostname)"
    info+="\nCPU核心:  $(nproc)"
    info+="\n内存总量: $(free -h 2>/dev/null | awk '/Mem:/{print $2}' || echo 'unknown')"
    info+="\n磁盘使用: $(df -h / 2>/dev/null | awk 'NR==2{print $5}' || echo 'unknown')"
    echo -e "$info"
}

# 检查磁盘空间
common_check_disk_space() {
    local threshold=${1:-80}
    local usage=$(df / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
    if [[ -n "$usage" && "$usage" -gt "$threshold" ]]; then
        common_fail "磁盘使用率过高: ${usage}% (阈值: ${threshold}%)"
        return 1
    fi
    common_pass "磁盘使用率正常: ${usage:-unknown}%"
    return 0
}

# 检查内存使用
common_check_memory() {
    local threshold=${1:-90}
    local usage=$(free 2>/dev/null | awk '/Mem:/{printf "%.0f", ($3/$2)*100}')
    if [[ -n "$usage" && "$usage" -gt "$threshold" ]]; then
        common_warn_check "内存使用率较高: ${usage}% (阈值: ${threshold}%)"
        return 1
    fi
    common_pass "内存使用率正常: ${usage:-unknown}%"
    return 0
}

# 检查Swap
common_check_swap() {
    local swap_total=$(free 2>/dev/null | awk '/Swap:/{print $2}')
    local swap_used=$(free 2>/dev/null | awk '/Swap:/{print $3}')
    if [[ -n "$swap_used" && "$swap_used" -gt 0 ]]; then
        common_warn_check "Swap正在使用: ${swap_used}KB / ${swap_total}KB"
        return 1
    fi
    common_pass "Swap未使用或正常"
    return 0
}

# 检查CPU负载
common_check_load() {
    local threshold=${1:-2}
    local cores=$(nproc 2>/dev/null || echo 1)
    local load=$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | awk -F, '{print $1}' | tr -d ' ')
    if [[ -n "$load" ]]; then
        local load_int=$(echo "$load" | awk '{printf "%.0f", $1}')
        if [[ "$load_int" -gt $((cores * threshold)) ]]; then
            common_warn_check "CPU负载较高: $load (核心数: $cores)"
            return 1
        fi
    fi
    common_pass "CPU负载正常: ${load:-unknown}"
    return 0
}

# 检查防火墙状态
common_check_firewall() {
    local active=false
    if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        common_pass "firewalld 运行中"
        active=true
    fi
    if command -v iptables &>/dev/null; then
        local rules=$(iptables -L -n 2>/dev/null | grep -c "DROP\|REJECT" || echo "0")
        if [[ "$rules" -gt 0 ]]; then
            common_pass "iptables 防火墙规则存在 ($rules 条)"
            active=true
        fi
    fi
    if [[ "$active" == false ]]; then
        common_info_check "未检测到活跃的防火墙 (可能使用云安全组)"
    fi
}

# ========================= K8s 工具函数 =========================

# 检查kubectl是否可用
common_check_kubectl() {
    if ! command -v kubectl &>/dev/null; then
        common_error "kubectl 命令不可用"
        return 1
    fi
    if ! kubectl cluster-info &>/dev/null 2>&1; then
        common_error "kubectl 无法连接到集群"
        return 1
    fi
    return 0
}

# 检查K8s命名空间
common_check_namespace() {
    local ns=$1
    if kubectl get namespace "$ns" &>/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# 检查Pod运行状态
common_check_pod_status() {
    local namespace=$1
    local label=$2
    local name=${3:-$label}

    if ! common_check_namespace "$namespace"; then
        common_warn_check "$name: namespace $namespace 不存在"
        return 1
    fi

    local pods=$(kubectl get pods -n "$namespace" -l "$label" --no-headers 2>/dev/null || echo "")
    if [[ -z "$pods" ]]; then
        pods=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | grep -i "$label" || echo "")
    fi

    local running=$(echo "$pods" | grep -c "Running" 2>/dev/null || echo "0")
    local total=$(echo "$pods" | grep -c . 2>/dev/null || echo "0")

    if [[ $running -gt 0 && $running -eq $total ]]; then
        common_pass "$name Pod 运行正常 ($running/$total) [namespace: $namespace]"
        return 0
    elif [[ $total -gt 0 ]]; then
        common_fail "$name Pod 异常 ($running/$total 运行中) [namespace: $namespace]"
        return 1
    else
        common_warn_check "$name: namespace $namespace 中无Pod"
        return 1
    fi
}

# 获取Pod状态摘要
common_get_pod_summary() {
    local namespace=$1
    local running=0
    local failed=0
    local pending=0
    local total=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        total=$((total + 1))
        local status=$(echo "$line" | awk '{print $3}')
        case "$status" in
            Running) running=$((running + 1)) ;;
            Failed|Error|CrashLoopBackOff|OOMKilled) failed=$((failed + 1)) ;;
            Pending) pending=$((pending + 1)) ;;
        esac
    done < <(kubectl get pods -n "$namespace" --no-headers 2>/dev/null)

    echo "running=$running failed=$failed pending=$pending total=$total"
}

# ========================= 服务检查函数 =========================

# 检查systemd服务
common_check_service() {
    local service=$1
    local name=${2:-$service}
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        common_pass "$name 服务运行中"
        return 0
    else
        common_fail "$name 服务未运行"
        return 1
    fi
}

# 检查端口监听
common_check_port() {
    local port=$1
    local name=${2:-port}
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        common_pass "端口 $port ($name) 正在监听"
        return 0
    fi
    return 1
}

# 检查命令是否可用
common_check_command() {
    local cmd=$1
    local name=${2:-$cmd}
    if command -v "$cmd" &>/dev/null; then
        return 0
    fi
    return 1
}

# ========================= 报告函数 =========================

# 生成验证汇总报告
common_generate_verify_report() {
    local phase_name=$1
    local report_file=${2:-}

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          $phase_name 验证报告${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC} 总检查项:  ${COMMON_TOTAL_COUNT}                                    ${CYAN}║${NC}"
    echo -e "${GREEN}║${NC} 通过:      ${COMMON_PASS_COUNT}                                    ${GREEN}║${NC}"
    echo -e "${RED}║${NC} 失败:      ${COMMON_FAIL_COUNT}                                    ${RED}║${NC}"
    echo -e "${YELLOW}║${NC} 警告:      ${COMMON_WARN_COUNT}                                    ${YELLOW}║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════╣${NC}"

    if [[ $COMMON_FAIL_COUNT -eq 0 ]]; then
        if [[ $COMMON_WARN_COUNT -eq 0 ]]; then
            echo -e "${GREEN}║  结果: ✓ 全部通过                               ║${NC}"
        else
            echo -e "${YELLOW}║  结果: △ 通过(有警告)                           ║${NC}"
        fi
    else
        echo -e "${RED}║  结果: ✗ 存在失败项                             ║${NC}"
    fi

    echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"

    # 写入纯文本报告
    if [[ -n "$report_file" ]]; then
        cat > "$report_file" <<REPORT_EOF
=================================================================
${phase_name} 验证报告
生成时间: $(date '+%Y-%m-%d %H:%M:%S')
=================================================================

总检查项: ${COMMON_TOTAL_COUNT}
通过:     ${COMMON_PASS_COUNT}
失败:     ${COMMON_FAIL_COUNT}
警告:     ${COMMON_WARN_COUNT}
跳过:     ${COMMON_SKIP_COUNT}

结论: $(if [[ $COMMON_FAIL_COUNT -eq 0 ]]; then echo "通过"; else echo "存在失败项"; fi)
=================================================================
REPORT_EOF
    fi
}

# 生成回滚汇总报告
common_generate_rollback_report() {
    local phase_name=$1
    local report_file=$2
    local start_time=$3

    local duration=$(($(date +%s) - start_time))

    cat >> "$report_file" <<REPORT_EOF

=================================================================
${phase_name} 回滚报告
=================================================================
回滚时间: $(date '+%Y-%m-%d %H:%M:%S')
回滚耗时: $(common_format_duration $duration)
操作主机: $(hostname)
=================================================================
REPORT_EOF
}

# ========================= 陷阱处理 =========================

# 设置错误陷阱
common_setup_trap() {
    local script_name=${1:-"unknown"}
    trap 'common_error "脚本异常退出: $script_name (行号: $LINENO, 退出码: $?)"' ERR
    trap 'common_error "收到中断信号，正在清理..."' INT TERM
}

# ========================= 帮助信息模板 =========================

# 生成验证脚本帮助信息
common_show_verify_help() {
    local script_name=$1
    local description=$2
    local checks=$3

    cat <<HELP_EOF
${BOLD}${script_name}${NC}
${description}

${BOLD}用法:${NC}
    $(basename "$0") [选项]

${BOLD}选项:${NC}
    -h, --help          显示此帮助信息
    -v, --verbose       详细输出模式
    --json              输出JSON格式结果
    --no-color          禁用彩色输出
    --timeout <秒>      命令超时时间 (默认: 30)

${BOLD}验证项目:${NC}
${checks}

${BOLD}示例:${NC}
    $(basename "$0")              # 执行验证
    $(basename "$0") -v           # 详细输出
    $(basename "$0") --json       # JSON输出

HELP_EOF
}

# 生成回滚脚本帮助信息
common_show_rollback_help() {
    local script_name=$1
    local description=$2
    local steps=$3

    cat <<HELP_EOF
${BOLD}${script_name}${NC}
${description}

${BOLD}用法:${NC}
    $(basename "$0") [选项]

${BOLD}选项:${NC}
    -h, --help          显示此帮助信息
    -f, --force         跳过确认提示 (危险!)
    --dry-run           干运行，仅显示将要执行的操作
    --verbose           详细输出模式

${BOLD}回滚步骤:${NC}
${steps}

${BOLD}示例:${NC}
    $(basename "$0")              # 执行回滚 (需要确认)
    $(basename "$0") --dry-run    # 干运行
    $(basename "$0") -f           # 跳过确认 (不推荐)

HELP_EOF
}

# ========================= 初始化函数 =========================

# 初始化验证脚本环境
common_init_verify() {
    local project_root=$1
    local phase_num=$2
    local report_dir="${project_root}/reports"

    mkdir -p "$report_dir"
    common_setup_trap "verify-phase${phase_num}"
    common_timer_start
}

# 初始化回滚脚本环境
common_init_rollback() {
    local project_root=$1
    local phase_num=$2
    local log_dir="${project_root}/logs/teardown"

    mkdir -p "$log_dir"
    common_setup_trap "teardown-phase${phase_num}"
    common_timer_start
}

# ========================= 选项解析 =========================

# 解析通用验证选项
common_parse_verify_options() {
    local OPTIND=1
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                if [[ -n "${COMMON_HELP_FUNCTION:-}" ]]; then
                    $COMMON_HELP_FUNCTION
                fi
                exit 0
                ;;
            -v|--verbose)
                export DEBUG=1
                shift
                ;;
            --json)
                export JSON_OUTPUT=1
                shift
                ;;
            --no-color)
                RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''
                BOLD=''; DIM=''; NC=''
                shift
                ;;
            --timeout)
                export COMMAND_TIMEOUT=$2
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
}

# 解析通用回滚选项
common_parse_rollback_options() {
    local OPTIND=1
    FORCE_MODE=false
    DRY_RUN=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                if [[ -n "${COMMON_HELP_FUNCTION:-}" ]]; then
                    $COMMON_HELP_FUNCTION
                fi
                exit 0
                ;;
            -f|--force)
                FORCE_MODE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                export DEBUG=1
                shift
                ;;
            *)
                shift
                ;;
        esac
    done
}

# 确认回滚操作
common_confirm_rollback() {
    local phase_num=$1
    local phase_name=$2
    local rollback_items=$3

    if [[ "${FORCE_MODE:-false}" == "true" ]]; then
        return 0
    fi

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        common_info "干运行模式 - 不执行实际操作"
        return 1
    fi

    echo ""
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║  ⚠️  警告: 即将回滚阶段${phase_num} - ${phase_name}$(printf '%*s' $((28-${#phase_name})) '')║${NC}"
    echo -e "${RED}${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}${BOLD}║  回滚内容:                                                ║${NC}"
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        printf "${RED}${BOLD}║    - %-53s║${NC}\n" "$item"
    done <<< "$rollback_items"
    echo -e "${RED}${BOLD}║                                                            ║${NC}"
    echo -e "${RED}${BOLD}║  ⚠️  此操作不可逆!                                        ║${NC}"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -ne "${YELLOW}是否确认回滚? 输入 YES 继续: ${NC}"
    read -r confirm
    if [[ "$confirm" != "YES" ]]; then
        echo -e "${RED}已取消回滚操作${NC}"
        exit 0
    fi
    echo ""
}

# ========================= 干运行辅助 =========================

# 干运行日志
common_dry_run() {
    local action=$1
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        common_info "[干运行] 将执行: $action"
        return 1  # 返回1表示不实际执行
    fi
    return 0  # 返回0表示应该执行
}
