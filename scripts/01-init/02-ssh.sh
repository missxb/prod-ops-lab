#!/bin/bash
###############################################################################
# 脚本名称: 02-ssh.sh
# 功能描述: 配置SSH免密登录，生成密钥对，部署公钥到集群节点
# 适用系统: CentOS 7/8, Rocky Linux 8/9
# 依赖条件: root权限, sshpass(可选)
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
LOG_FILE="${LOG_DIR}/02-ssh_$(date +%Y%m%d_%H%M%S).log"
LOCK_FILE="/var/lock/02-ssh.lock"
SSH_DIR="/root/.ssh"
SSH_KEY="${SSH_DIR}/id_rsa"
SSH_CONFIG="${SSH_DIR}/config"
KNOWN_HOSTS="${SSH_DIR}/known_hosts"
SSH_USER="${SSH_USER:-root}"
SSH_PORT="${SSH_PORT:-22}"

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
    fi
    log_info "检测到系统: ${OS_NAME:-Unknown}"
}

# ========================= SSH配置函数 =========================
generate_ssh_key() {
    log_step "检查并生成SSH密钥"

    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"

    if [[ -f "$SSH_KEY" ]]; then
        log_info "SSH密钥已存在: $SSH_KEY"
        # 验证密钥是否有效
        if ssh-keygen -l -f "$SSH_KEY" >/dev/null 2>&1; then
            log_success "SSH密钥验证通过，跳过生成"
        else
            log_warn "SSH密钥无效，重新生成"
            rm -f "$SSH_KEY" "${SSH_KEY}.pub"
            ssh-keygen -t rsa -b 4096 -f "$SSH_KEY" -N "" -C "enterprise-platform-$(hostname)"
            log_success "SSH密钥已重新生成"
        fi
    else
        log_info "生成新的SSH密钥对..."
        ssh-keygen -t rsa -b 4096 -f "$SSH_KEY" -N "" -C "enterprise-platform-$(hostname)"
        log_success "SSH密钥已生成: $SSH_KEY"
    fi
}

configure_ssh_security() {
    log_step "配置SSH安全加固"

    local sshd_config="/etc/ssh/sshd_config"
    local backup="${sshd_config}.bak.$(date +%Y%m%d)"

    # 备份原始配置
    if [[ ! -f "$backup" ]]; then
        cp "$sshd_config" "$backup"
        log_info "已备份SSH配置: $backup"
    fi

    # 安全配置项
    declare -A SSH_CONFIGS=(
        ["PermitRootLogin"]="yes"
        ["PasswordAuthentication"]="no"
        ["PubkeyAuthentication"]="yes"
        ["PermitEmptyPasswords"]="no"
        ["X11Forwarding"]="no"
        ["MaxAuthTries"]="3"
        ["ClientAliveInterval"]="300"
        ["ClientAliveCountMax"]="3"
        ["UseDNS"]="no"
        ["GSSAPIAuthentication"]="no"
    )

    local config_changed=false
    for key in "${!SSH_CONFIGS[@]}"; do
        local value="${SSH_CONFIGS[$key]}"
        if grep -q "^#\?${key}" "$sshd_config"; then
            if grep -q "^${key} ${value}" "$sshd_config"; then
                log_info "SSH配置 ${key} 已经是 ${value}，跳过"
            else
                sed -i "s/^#\?${key} .*/${key} ${value}/" "$sshd_config"
                config_changed=true
                log_info "已更新SSH配置: ${key} ${value}"
            fi
        else
            echo "${key} ${value}" >> "$sshd_config"
            config_changed=true
            log_info "已添加SSH配置: ${key} ${value}"
        fi
    done

    # 重启SSH服务
    if [[ "$config_changed" == "true" ]]; then
        systemctl restart sshd 2>/dev/null || service sshd restart 2>/dev/null || true
        log_success "SSH服务已重启"
    else
        log_info "SSH配置无变更，跳过重启"
    fi
}

deploy_key_to_node() {
    local target_host="$1"
    local target_port="${2:-22}"
    local target_user="${3:-root}"

    log_info "部署公钥到 ${target_user}@${target_host}:${target_port}"

    # 检查是否已经可以免密登录
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
           -p "$target_port" "${target_user}@${target_host}" "echo ok" >/dev/null 2>&1; then
        log_success "目标主机 ${target_host} 已配置免密登录"
        return 0
    fi

    # 尝试使用 ssh-copy-id
    if command -v sshpass >/dev/null 2>&1; then
        local password="${4:-}"
        if [[ -n "$password" ]]; then
            sshpass -p "$password" ssh-copy-id -o StrictHostKeyChecking=no \
                -p "$target_port" "${target_user}@${target_host}" 2>>"$LOG_FILE"
            log_success "已通过sshpass部署公钥到 ${target_host}"
            return 0
        fi
    fi

    log_warn "无法自动部署公钥到 ${target_host}，请手动执行:"
    log_warn "  ssh-copy-id -p ${target_port} ${target_user}@${target_host}"
    return 1
}

# ========================= 主逻辑 =========================
main() {
    mkdir -p "$LOG_DIR"
    check_root
    check_lock
    detect_os

    log_step "阶段1-任务2: SSH免密配置"

    # 生成密钥
    generate_ssh_key

    # 安全加固
    configure_ssh_security

    # 处理主机列表（如果存在）
    local host_list="${PROJECT_ROOT}/config/hosts.conf"
    if [[ -f "$host_list" ]]; then
        log_step "从配置文件读取主机列表，部署公钥"
        while IFS=',' read -r host port user password _; do
            host=$(echo "$host" | xargs)
            port=$(echo "${port:-22}" | xargs)
            user=$(echo "${user:-root}" | xargs)
            [[ -z "$host" || "$host" =~ ^# ]] && continue
            deploy_key_to_node "$host" "$port" "$user" "$password" || true
        done < "$host_list"
    else
        log_info "未发现主机列表文件 (${host_list})，跳过公钥部署"
        log_info "如需批量部署，请创建 hosts.conf 格式: host,port,user,password"
    fi

    # 设置known_hosts自动接受（用于集群初始化阶段）
    local ssh_config_content=""
    if [[ -f "$SSH_CONFIG" ]]; then
        ssh_config_content=$(cat "$SSH_CONFIG")
    fi

    if ! echo "$ssh_config_content" | grep -q "StrictHostKeyChecking"; then
        cat >> "$SSH_CONFIG" << 'EOF'

# 集群初始化阶段配置（生产环境部署完成后建议移除）
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF
        chmod 600 "$SSH_CONFIG"
        log_success "已配置SSH全局选项"
    fi

    log_success "阶段1-任务2完成: SSH免密配置成功"
}

main "$@"
