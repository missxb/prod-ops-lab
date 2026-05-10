#!/bin/bash
###############################################################################
# 脚本名称: 07-timezone.sh
# 功能描述: 设置系统时区，确保集群时间一致性
# 适用系统: CentOS 7/8, Rocky Linux 8/9
# 依赖条件: root权限
# 作者: 运维平台团队
# 版本: 1.1.0
# 创建日期: 2026-05-10
# 更新日期: 2026-05-10
#
# 使用方法:
#   ./07-timezone.sh                         # 设置为默认时区 Asia/Shanghai
#   ./07-timezone.sh --timezone Asia/Beijing  # 设置为指定时区
#   TIMEZONE=Europe/London ./07-timezone.sh   # 通过环境变量指定
#
# 功能说明:
#   1. 检测操作系统类型
#   2. 设置系统时区 (timedatectl)
#   3. 确保chrony已安装 (时间同步)
#   4. 验证时区设置正确
#   5. 记录设置结果
#
# 时区对于集群的重要性:
#   - 日志时间戳统一，便于故障排查
#   - 证书有效期计算需要时区准确
#   - 跨时区部署的运维操作需要时间一致
###############################################################################
set -euo pipefail
umask 077

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/01-init"
LOG_FILE="${LOG_DIR}/07-timezone_$(date +%Y%m%d_%H%M%S).log"
LOCK_FILE="/var/lock/07-timezone.lock"

# 默认时区
DEFAULT_TIMEZONE="Asia/Shanghai"
TIMEZONE="${TIMEZONE:-$DEFAULT_TIMEZONE}"

# ========================= 颜色定义 =========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ========================= 日志函数 =========================
log_info()    { echo -e "${GREEN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_step()    { echo -e "${CYAN}[STEP]${NC}  $(date '+%Y-%m-%d %H:%M:%S') === $* ===" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }

# ========================= 错误处理 =========================
cleanup() {
    local exit_code=$?
    rm -f "$LOCK_FILE"
    if [[ $exit_code -ne 0 ]]; then
        log_error "脚本执行失败，退出码: $exit_code"
    fi
    return $exit_code
}
trap 'log_error "脚本执行出错，行号: ${LINENO}"' ERR
trap cleanup EXIT
trap 'log_error "收到信号，正在退出..."; exit 1' SIGINT SIGTERM

# ========================= 工具函数 =========================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以root权限运行"
        exit 1
    fi
}

check_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log_error "另一个实例正在运行 (PID: $pid)"
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
}

# ========================= 帮助信息 =========================
show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --timezone <时区>   设置系统时区 (默认: Asia/Shanghai)"
    echo "  --list             列出常用时区"
    echo "  --help             显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0                         # 设置为 Asia/Shanghai"
    echo "  $0 --timezone Asia/Tokyo   # 设置为亚洲/东京"
}

list_timezones() {
    echo "常用时区列表:"
    echo "  Asia/Shanghai      - 中国标准时间 (CST)"
    echo "  Asia/Tokyo         - 日本标准时间 (JST)"
    echo "  Asia/Kolkata       - 印度标准时间 (IST)"
    echo "  Europe/London      - 格林威治标准时间 (GMT)"
    echo "  Europe/Paris       - 中欧时间 (CET)"
    echo "  America/New_York   - 美国东部时间 (EST)"
    echo "  America/Los_Angeles - 美国太平洋时间 (PST)"
    echo "  UTC                - 协调世界时"
    echo ""
    echo "完整时区列表请运行: timedatectl list-timezones"
}

# ========================= 时区配置函数 =========================

# 验证时区是否有效
# timedatectl set-timezone 会自动验证，此函数用于预检查
validate_timezone() {
    local tz="$1"

    # 检查时区文件是否存在
    if [[ -f "/usr/share/zoneinfo/${tz}" ]]; then
        return 0
    fi

    # 尝试使用 timedatectl 验证
    if timedatectl list-timezones 2>/dev/null | grep -q "^${tz}$"; then
        return 0
    fi

    return 1
}

# 设置系统时区
# 使用 timedatectl 命令设置，这是 systemd 系统的标准方式
set_timezone() {
    local tz="$1"
    local current_tz

    log_step "设置系统时区为: ${tz}"

    # 获取当前时区
    current_tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo "unknown")
    log_info "当前时区: ${current_tz}"

    # 幂等性检查：如果时区已经正确，跳过设置
    if [[ "$current_tz" == "$tz" ]]; then
        log_success "时区已经是目标值: ${tz}，跳过设置"
        return 0
    fi

    # 设置新时区
    if timedatectl set-timezone "$tz" 2>/dev/null; then
        log_success "时区设置命令执行成功"
    else
        log_error "时区设置失败: ${tz}"
        log_info "请确认时区名称是否正确，运行 'timedatectl list-timezones' 查看可用时区"
        return 1
    fi
}

# 确保 chrony 已安装
# 虽然 03-ntp.sh 已处理，但作为独立时区脚本需要确保时间同步可用
ensure_chrony() {
    log_step "检查 chrony 时间同步服务"

    if command -v chronyd >/dev/null 2>&1; then
        log_success "chrony 已安装"
        return 0
    fi

    log_warn "chrony 未安装，尝试安装..."

    # 检测系统类型并安装
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "${ID}" in
            centos|rhel|rocky|almalinux)
                yum install -y chrony >> "$LOG_FILE" 2>&1 || {
                    log_error "chrony 安装失败"
                    return 1
                }
                ;;
            *)
                log_warn "未知系统类型 ${ID}，尝试 yum 安装"
                yum install -y chrony >> "$LOG_FILE" 2>&1 || {
                    log_error "chrony 安装失败"
                    return 1
                }
                ;;
        esac
    fi

    # 启动 chrony
    systemctl enable chronyd 2>/dev/null || true
    systemctl start chronyd 2>/dev/null || true

    if systemctl is-active chronyd >/dev/null 2>&1; then
        log_success "chrony 安装并启动成功"
    else
        log_warn "chrony 已安装但启动失败，请手动检查"
    fi
}

# 验证时区设置结果
verify_timezone() {
    local expected_tz="$1"

    log_step "验证时区设置"

    # 获取当前时区
    local actual_tz
    actual_tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo "unknown")

    if [[ "$actual_tz" == "$expected_tz" ]]; then
        log_success "时区验证通过: ${actual_tz}"
    else
        log_error "时区验证失败: 期望 ${expected_tz}，实际 ${actual_tz}"
        return 1
    fi

    # 显示详细时间信息
    log_info "当前系统时间信息:"
    timedatectl status 2>/dev/null | tee -a "$LOG_FILE" || true

    log_info "当前时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    log_info "UTC 时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
}

# ========================= 主逻辑 =========================
main() {
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            --timezone)
                TIMEZONE="$2"
                shift 2
                ;;
            --list)
                list_timezones
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

    mkdir -p "$LOG_DIR"
    check_root
    check_lock
    detect_os

    log_step "阶段1-任务7: 设置系统时区"

    # 验证时区是否有效
    if ! validate_timezone "$TIMEZONE"; then
        log_error "无效的时区: ${TIMEZONE}"
        log_info "请运行 '$0 --list' 查看常用时区"
        log_info "或运行 'timedatectl list-timezones' 查看所有可用时区"
        exit 1
    fi

    # 设置时区
    set_timezone "$TIMEZONE"

    # 确保 chrony 已安装
    ensure_chrony

    # 验证时区设置
    verify_timezone "$TIMEZONE"

    log_success "阶段1-任务7完成: 系统时区设置成功 (${TIMEZONE})"
}

main "$@"
