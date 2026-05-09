#!/bin/bash
###############################################################################
# 脚本名称: 01-hostname.sh
# 功能描述: 设置主机名，支持从配置文件读取或命令行参数指定
# 适用系统: CentOS 7/8, Rocky Linux 8/9
# 依赖条件: root权限
# 作者: 运维平台团队
# 版本: 1.0.0
# 创建日期: 2026-05-09
###############################################################################
set -euo pipefail
umask 077

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/01-init"
LOG_FILE="${LOG_DIR}/01-hostname_$(date +%Y%m%d_%H%M%S).log"
LOCK_FILE="/var/lock/01-hostname.lock"

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

# ========================= 主逻辑 =========================
main() {
    local target_hostname="${1:-}"

    mkdir -p "$LOG_DIR"
    check_root
    check_lock
    detect_os

    log_step "阶段1-任务1: 设置主机名"

    # 如果未指定主机名，检查是否有配置文件
    if [[ -z "$target_hostname" ]]; then
        local config_file="${PROJECT_ROOT}/config/hostname.conf"
        if [[ -f "$config_file" ]]; then
            target_hostname=$(grep -v '^#' "$config_file" | grep -v '^$' | head -1)
            log_info "从配置文件读取主机名: $target_hostname"
        fi
    fi

    if [[ -z "$target_hostname" ]]; then
        log_warn "未指定主机名，使用当前主机名: $(hostname)"
        target_hostname=$(hostname)
    fi

    # 幂等性检查：如果主机名已正确设置则跳过
    local current_hostname
    current_hostname=$(hostname)
    if [[ "$current_hostname" == "$target_hostname" ]]; then
        log_success "主机名已经是目标值: $target_hostname，跳过设置"
    else
        # 设置主机名（支持CentOS 7和8/9）
        hostnamectl set-hostname "$target_hostname" 2>/dev/null || hostname "$target_hostname"
        log_success "主机名已设置为: $target_hostname"
    fi

    # 确保 /etc/hosts 中包含主机名映射
    local ip_addr
    ip_addr=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    if [[ -n "$ip_addr" ]]; then
        # 移除旧的主机名映射（如果有）
        if grep -q "$current_hostname" /etc/hosts 2>/dev/null && [[ "$current_hostname" != "$target_hostname" ]]; then
            sed -i "/${current_hostname}/d" /etc/hosts
            log_info "已移除旧主机名映射: $current_hostname"
        fi

        if ! grep -q "$target_hostname" /etc/hosts 2>/dev/null; then
            echo "${ip_addr}  ${target_hostname}" >> /etc/hosts
            log_success "已添加hosts映射: ${ip_addr} ${target_hostname}"
        else
            log_info "hosts中已存在主机名映射，跳过"
        fi
    else
        log_warn "未检测到有效的IPv4地址，跳过hosts配置"
    fi

    log_success "阶段1-任务1完成: 主机名设置成功"
}

main "$@"
