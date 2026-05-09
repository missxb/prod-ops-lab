#!/bin/bash
###############################################################################
# 脚本名称: init-all.sh
# 功能描述: 企业级云原生运维平台 - 阶段1基础环境初始化主入口脚本
# 适用系统: CentOS 7/8, Rocky Linux 8/9
# 依赖条件: root权限
# 作者: 运维平台团队
# 版本: 1.1.0
# 创建日期: 2026-05-09
# 更新日期: 2026-05-09
#
# 使用方法:
#   ./init-all.sh                          # 执行所有初始化任务
#   ./init-all.sh --task 1                 # 只执行任务1（主机名设置）
#   ./init-all.sh --task 1,2,3             # 执行任务1-3
#   ./init-all.sh --skip 4,5               # 跳过任务4和5
#   ./init-all.sh --dry-run                # 干运行，只显示将要执行的任务
#   ./init-all.sh --list                   # 列出所有可用任务
#   ./init-all.sh --help                   # 显示帮助信息
#
# 功能说明:
#   1. 设置主机名 (01-hostname.sh)
#   2. SSH免密配置 (02-ssh.sh)
#   3. NTP时间同步 (03-ntp.sh)
#   4. 内核参数优化 (04-kernel.sh)
#   5. Docker/containerd安装 (05-docker.sh)
#   6. NFS服务端配置 (06-nfs.sh)
#
# 特性:
#   - 支持选择性执行 (指定/跳过任务)
#   - 支持干运行模式 (预览不执行)
#   - 支持详细输出模式
#   - 任务失败自动停止
#   - 完整的日志记录
#
# 日志文件: logs/01-init/init-all_YYYYMMDD_HHMMSS.log
@@
# 任务列表:
#   1 - 设置主机名
#   2 - SSH免密配置
#   3 - NTP时间同步
#   4 - 内核参数优化
#   5 - Docker/containerd安装
#   6 - NFS服务端配置
###############################################################################
set -euo pipefail
umask 077

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/01-init"
LOG_FILE="${LOG_DIR}/init-all_$(date +%Y%m%d_%H%M%S).log"
LOCK_FILE="/var/lock/init-all.lock"
START_TIME=$(date +%s)

# 任务定义
declare -A TASKS=(
    [1]="01-hostname.sh"
    [2]="02-ssh.sh"
    [3]="03-ntp.sh"
    [4]="04-kernel.sh"
    [5]="05-docker.sh"
    [6]="06-nfs.sh"
)

declare -A TASK_DESC=(
    [1]="设置主机名"
    [2]="SSH免密配置"
    [3]="NTP时间同步"
    [4]="内核参数优化"
    [5]="Docker/containerd安装"
    [6]="NFS服务端配置"
)

# 默认执行所有任务
EXECUTE_TASKS="1,2,3,4,5,6"
SKIP_TASKS=""
DRY_RUN=false
VERBOSE=false

# ========================= 颜色定义 =========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

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

# ========================= 错误处理 =========================
cleanup() {
    local exit_code=$?
    rm -f "$LOCK_FILE"
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))

    if [[ $exit_code -eq 0 ]]; then
        echo -e ""
        log_header "初始化完成"
        log_success "所有任务执行成功"
        log_info "总耗时: ${duration}秒"
        log_info "日志文件: ${LOG_FILE}"
    else
        log_error "脚本执行失败，退出码: $exit_code"
        log_error "请检查日志: ${LOG_FILE}"
    fi
    return $exit_code
}
trap cleanup EXIT
trap 'log_error "收到信号，正在退出..."; exit 1' SIGINT SIGTERM

# ========================= 工具函数 =========================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以root权限运行"
        log_info "请使用: sudo $0 $*"
        exit 1
    fi
}

check_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log_error "另一个初始化实例正在运行 (PID: $pid)"
            log_error "如果确认没有其他进程，请删除: $LOCK_FILE"
            exit 1
        fi
        log_warn "发现残留锁文件，已清理"
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID}"
        OS_NAME="${PRETTY_NAME}"
    else
        log_error "无法检测操作系统类型"
        exit 1
    fi
    log_info "检测到系统: ${OS_NAME}"
    log_info "系统版本: ${OS_ID} ${OS_VERSION}"
}

show_help() {
    echo -e "${BOLD}企业级云原生运维平台 - 阶段1基础环境初始化${NC}"
    echo ""
    echo "使用方法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --task <tasks>     执行指定任务（逗号分隔，如: 1,2,3）"
    echo "  --skip <tasks>     跳过指定任务（逗号分隔，如: 4,5）"
    echo "  --dry-run          干运行，只显示将要执行的任务"
    echo "  --list             列出所有可用任务"
    echo "  --verbose          显示详细输出"
    echo "  --help             显示此帮助信息"
    echo ""
    echo "任务列表:"
    for task_num in $(echo "${!TASKS[@]}" | tr ' ' '\n' | sort -n); do
        echo -e "  ${CYAN}${task_num}${NC} - ${TASK_DESC[$task_num]} (${TASKS[$task_num]})"
    done
    echo ""
    echo "示例:"
    echo "  $0                          # 执行所有任务"
    echo "  $0 --task 1,2,3             # 只执行任务1-3"
    echo "  $0 --skip 4,5               # 跳过任务4和5"
    echo "  $0 --dry-run                # 干运行"
    echo "  $0 --list                   # 列出所有任务"
}

list_tasks() {
    echo -e "${BOLD}可用任务列表:${NC}"
    echo ""
    for task_num in $(echo "${!TASKS[@]}" | tr ' ' '\n' | sort -n); do
        echo -e "  ${CYAN}${task_num}${NC} - ${TASK_DESC[$task_num]}"
        echo -e "      脚本: ${SCRIPT_DIR}/${TASKS[$task_num]}"
    done
    echo ""
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --task)
                EXECUTE_TASKS="$2"
                shift 2
                ;;
            --skip)
                SKIP_TASKS="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --list)
                list_tasks
                exit 0
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# ========================= 任务执行函数 =========================

# 判断是否应该执行指定任务
# 检查任务是否在执行列表中，且不在跳过列表中
should_execute_task() {
    local task_num=$1

    # 检查是否在跳过列表中
    if [[ -n "$SKIP_TASKS" ]]; then
        IFS=',' read -ra skip_list <<< "$SKIP_TASKS"
        for skip in "${skip_list[@]}"; do
            if [[ "$skip" == "$task_num" ]]; then
                return 1
            fi
        done
    fi

    # 检查是否在执行列表中
    IFS=',' read -ra exec_list <<< "$EXECUTE_TASKS"
    for exec_task in "${exec_list[@]}"; do
        if [[ "$exec_task" == "$task_num" ]]; then
            return 0
        fi
    done

    return 1
}

# 执行单个任务
# 参数: $1=任务编号
# 支持干运行模式和详细输出模式
# 任务执行超时时间: 无限制 (由子脚本控制)
execute_task() {
    local task_num=$1
    local script_name="${TASKS[$task_num]}"
    local script_path="${SCRIPT_DIR}/${script_name}"
    local task_desc="${TASK_DESC[$task_num]}"
    local task_start=$(date +%s)

    if [[ ! -f "$script_path" ]]; then
        log_error "任务脚本不存在: ${script_path}"
        return 1
    fi

    if [[ ! -x "$script_path" ]]; then
        chmod +x "$script_path"
    fi

    log_step "开始执行任务${task_num}: ${task_desc}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[干运行] 将执行: ${script_path}"
        return 0
    fi

    if [[ "$VERBOSE" == "true" ]]; then
        bash "$script_path" 2>&1 | tee -a "$LOG_FILE"
    else
        bash "$script_path" >> "$LOG_FILE" 2>&1
    fi

    local exit_code=$?
    local task_end=$(date +%s)
    local task_duration=$((task_end - task_start))

    if [[ $exit_code -eq 0 ]]; then
        log_success "任务${task_num}完成: ${task_desc} (耗时: ${task_duration}秒)"
    else
        log_error "任务${task_num}失败: ${task_desc} (退出码: $exit_code)"
        return $exit_code
    fi
}

# ========================= 主逻辑 =========================
main() {
    # 解析命令行参数
    parse_args "$@"

    # 创建日志目录
    mkdir -p "$LOG_DIR"

    # 检查权限和锁
    check_root
    check_lock

    # 检测操作系统
    detect_os

    # 显示初始化头
    log_header "企业级云原生运维平台 - 阶段1基础环境初始化"

    # 显示执行计划
    log_info "执行计划:"
    for task_num in $(echo "${!TASKS[@]}" | tr ' ' '\n' | sort -n); do
        if should_execute_task "$task_num"; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "  [将执行] 任务${task_num}: ${TASK_DESC[$task_num]}"
            else
                log_info "  [执行中] 任务${task_num}: ${TASK_DESC[$task_num]}"
            fi
        else
            log_info "  [跳过]   任务${task_num}: ${TASK_DESC[$task_num]}"
        fi
    done
    echo ""

    # 记录系统信息
    log_step "记录系统信息"
    log_info "主机名: $(hostname)"
    log_info "内核版本: $(uname -r)"
    log_info "系统架构: $(uname -m)"
    log_info "当前用户: $(whoami)"
    log_info "IP地址: $(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || echo 'N/A')"
    echo ""

    # 执行任务
    local failed_tasks=()
    local success_count=0

    for task_num in $(echo "${!TASKS[@]}" | tr ' ' '\n' | sort -n); do
        if should_execute_task "$task_num"; then
            if execute_task "$task_num"; then
                success_count=$((success_count + 1))
            else
                failed_tasks+=("$task_num")
            fi
        fi
    done

    # 显示执行结果摘要
    echo ""
    log_header "执行结果摘要"

    local total_tasks=$(echo "${!TASKS[@]}" | wc -w)
    log_info "总任务数: ${total_tasks}"
    log_info "成功执行: ${success_count}"
    log_info "跳过任务: $((total_tasks - success_count - ${#failed_tasks[@]}))"

    if [[ ${#failed_tasks[@]} -gt 0 ]]; then
        log_error "失败任务: ${#failed_tasks[@]}"
        for failed_task in "${failed_tasks[@]}"; do
            log_error "  - 任务${failed_task}: ${TASK_DESC[$failed_task]}"
        done
        log_error "请检查日志并修复失败任务"
        exit 1
    fi

    # 显示后续步骤
    if [[ "$DRY_RUN" == "false" ]]; then
        echo ""
        log_header "后续步骤"
        log_info "阶段1基础环境初始化已完成"
        log_info "建议的下一步操作:"
        log_info "  1. 验证NFS配置: showmount -e $(hostname)"
        log_info "  2. 测试Docker: docker run hello-world"
        log_info "  3. 测试时间同步: chronyc sources"
        log_info "  4. 检查内核参数: sysctl net.bridge.bridge-nf-call-iptables"
        log_info "  5. 进入阶段2: Kubernetes集群部署"
    fi
}

# 执行主函数
main "$@"
