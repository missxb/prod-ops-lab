#!/bin/bash
###############################################################################
# install-agent.sh - 在远程主机安装Zabbix Agent
# 功能: 自动检测操作系统并安装Zabbix Agent
# 项目: 企业级云原生运维平台
# 阶段: 06 - 监控系统
# 作者: 运维平台团队
# 版本: 1.1.0
###############################################################################

set -euo pipefail
umask 077

# ==================== 配置变量 ====================
# Zabbix Server地址（部署后更新此值）
ZABBIX_SERVER="${ZABBIX_SERVER_IP:-192.168.100.10}"
ZABBIX_AGENT_VERSION="7.0"
ZABBIX_AGENT_CONFIG="/etc/zabbix/zabbix_agentd.conf"
ZABBIX_AGENT_LOG="/var/log/zabbix/zabbix_agentd.log"

# ==================== 颜色输出 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $(date '+%H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $(date '+%H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $(date '+%H:%M:%S') $*"; }

# ==================== 用法说明 ====================
usage() {
    cat << EOF
用法: $(basename "$0") [options]

功能: 在远程主机安装和配置Zabbix Agent

环境变量:
  ZABBIX_SERVER_IP      Zabbix Server地址（默认: 192.168.100.10）

选项:
  -s, --server <ip>     指定Zabbix Server地址
  -v, --version <ver>   指定Zabbix版本（默认: 7.0）
  -h, --help            显示此帮助信息

示例:
  ZABBIX_SERVER_IP=10.0.0.1 $(basename "$0")
  $(basename "$0") -s 10.0.0.1 -v 7.0
EOF
}

# ==================== 参数解析 ====================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -s|--server)
                ZABBIX_SERVER="$2"
                shift 2
                ;;
            -v|--version)
                ZABBIX_AGENT_VERSION="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# ==================== 检查root权限 ====================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        exit 1
    fi
}

# ==================== 检测操作系统 ====================
detect_os() {
    if [[ -f /etc/redhat-release ]]; then
        echo "rhel"
    elif [[ -f /etc/debian_version ]]; then
        echo "debian"
    else
        echo "unknown"
    fi
}

# ==================== 安装Zabbix Agent (RHEL/CentOS) ====================
install_agent_rhel() {
    log_step "[1/5] 安装Zabbix Agent (RHEL/CentOS)..."

    # 安装Zabbix仓库
    local rpm_version
    rpm_version=$(rpm -E %rhel 2>/dev/null || echo "7")
    rpm -Uvh "https://repo.zabbix.com/zabbix/${ZABBIX_AGENT_VERSION}/rhel/${rpm_version}/x86_64/zabbix-release-latest.el${rpm_version}.noarch.rpm" 2>/dev/null || true
    yum clean all 2>/dev/null || true

    # 安装Zabbix Agent
    yum install -y zabbix-agent 2>&1 | tail -5

    # 创建日志目录
    mkdir -p /var/log/zabbix
    chown zabbix:zabbix /var/log/zabbix 2>/dev/null || true

    log_success "Zabbix Agent安装完成"
}

# ==================== 安装Zabbix Agent (Debian/Ubuntu) ====================
install_agent_debian() {
    log_step "[1/5] 安装Zabbix Agent (Debian/Ubuntu)..."

    # 安装依赖
    apt-get update -qq 2>/dev/null || true
    apt-get install -y wget gnupg 2>/dev/null || true

    # 安装Zabbix仓库
    local os_version
    os_version=$(lsb_release -rs 2>/dev/null | tr -d '.' || echo "2204")
    wget -q "https://repo.zabbix.com/zabbix/${ZABBIX_AGENT_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu${os_version}_all.deb" -O /tmp/zabbix-release.deb 2>/dev/null || true
    dpkg -i /tmp/zabbix-release.deb 2>/dev/null || true
    apt-get update -qq 2>/dev/null || true

    # 安装Zabbix Agent
    apt-get install -y zabbix-agent 2>&1 | tail -5

    # 创建日志目录
    mkdir -p /var/log/zabbix
    chown zabbix:zabbix /var/log/zabbix 2>/dev/null || true

    log_success "Zabbix Agent安装完成"
}

# ==================== 备份原始配置 ====================
backup_config() {
    log_step "[2/5] 备份原始配置..."

    if [[ -f "${ZABBIX_AGENT_CONFIG}" ]]; then
        cp "${ZABBIX_AGENT_CONFIG}" "${ZABBIX_AGENT_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
        log_info "原始配置已备份"
    fi
}

# ==================== 配置Zabbix Agent ====================
configure_agent() {
    log_step "[3/5] 配置Zabbix Agent..."

    local hostname
    hostname=$(hostname)

    # 使用sed更新配置（如果配置文件存在）
    if [[ -f "${ZABBIX_AGENT_CONFIG}" ]]; then
        # 更新Server地址
        sed -i "s|^Server=.*|Server=${ZABBIX_SERVER}|" "${ZABBIX_AGENT_CONFIG}"
        sed -i "s|^# Server=.*|Server=${ZABBIX_SERVER}|" "${ZABBIX_AGENT_CONFIG}"

        # 更新ServerActive地址
        sed -i "s|^ServerActive=.*|ServerActive=${ZABBIX_SERVER}|" "${ZABBIX_AGENT_CONFIG}"
        sed -i "s|^# ServerActive=.*|ServerActive=${ZABBIX_SERVER}|" "${ZABBIX_AGENT_CONFIG}"

        # 更新主机名
        sed -i "s|^Hostname=.*|Hostname=${hostname}|" "${ZABBIX_AGENT_CONFIG}"
        sed -i "s|^# Hostname=.*|Hostname=${hostname}|" "${ZABBIX_AGENT_CONFIG}"

        # 启用远程命令
        sed -i "s|^# EnableRemoteCommands=.*|EnableRemoteCommands=1|" "${ZABBIX_AGENT_CONFIG}"
        sed -i "s|^EnableRemoteCommands=.*|EnableRemoteCommands=1|" "${ZABBIX_AGENT_CONFIG}"

        # 设置日志文件
        sed -i "s|^LogFile=.*|LogFile=${ZABBIX_AGENT_LOG}|" "${ZABBIX_AGENT_CONFIG}"
        sed -i "s|^# LogFile=.*|LogFile=${ZABBIX_AGENT_LOG}|" "${ZABBIX_AGENT_CONFIG}"

        # 设置超时
        sed -i "s|^Timeout=.*|Timeout=30|" "${ZABBIX_AGENT_CONFIG}"
        sed -i "s|^# Timeout=.*|Timeout=30|" "${ZABBIX_AGENT_CONFIG}"
    else
        # 创建新配置文件
        mkdir -p "$(dirname "${ZABBIX_AGENT_CONFIG}")"
        cat > "${ZABBIX_AGENT_CONFIG}" << CONF
# Zabbix Agent配置文件
# 自动生成于 $(date '+%Y-%m-%d %H:%M:%S')

PidFile=/tmp/zabbix_agentd.pid
LogFile=${ZABBIX_AGENT_LOG}
LogFileSize=100
DebugLevel=3

Server=${ZABBIX_SERVER}
ServerActive=${ZABBIX_SERVER}
Hostname=${hostname}

AllowRemoteCommands=1
Timeout=30

CacheSize=32M
HistoryCacheSize=16M
CONF
    fi

    log_info "Zabbix Agent配置完成"
}

# ==================== 启动Zabbix Agent ====================
start_agent() {
    log_step "[4/5] 启动Zabbix Agent服务..."

    # 启用并启动服务
    systemctl enable zabbix-agent 2>/dev/null || true
    systemctl restart zabbix-agent

    # 等待服务启动
    sleep 3

    if systemctl is-active zabbix-agent &>/dev/null; then
        log_success "Zabbix Agent启动成功"
    else
        log_error "Zabbix Agent启动失败"
        systemctl status zabbix-agent --no-pager 2>/dev/null || true
        exit 1
    fi
}

# ==================== 验证连接 ====================
verify_connection() {
    log_step "[5/5] 验证与Zabbix Server的连接..."

    # 等待几秒让Agent完成初始化
    sleep 5

    # 测试Agent连通性
    if command -v zabbix_agentd &>/dev/null; then
        if timeout 10 zabbix_agentd -t agent.ping 2>/dev/null | grep -q "1"; then
            log_success "Zabbix Agent连接验证成功"
        else
            log_warn "无法验证连接，请检查:"
            log_warn "  1. Zabbix Server地址: ${ZABBIX_SERVER}"
            log_warn "  2. 防火墙是否放行端口 10050"
            log_warn "  3. Zabbix Server配置"
        fi
    else
        log_warn "zabbix_agentd命令不可用，跳过连接验证"
    fi
}

# ==================== 显示部署信息 ====================
show_info() {
    local local_ip
    local_ip=$(hostname -I | awk '{print $1}')

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║            Zabbix Agent安装完成                             ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC} 主机名: $(hostname)"
    echo -e "${CYAN}║${NC} IP地址: ${local_ip}"
    echo -e "${CYAN}║${NC} Zabbix Server: ${ZABBIX_SERVER}"
    echo -e "${CYAN}║${NC} 配置文件: ${ZABBIX_AGENT_CONFIG}"
    echo -e "${CYAN}║${NC} 日志文件: ${ZABBIX_AGENT_LOG}"
    echo -e "${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} 管理命令:"
    echo -e "${CYAN}║${NC}   systemctl status zabbix-agent    # 查看状态"
    echo -e "${CYAN}║${NC}   systemctl restart zabbix-agent   # 重启服务"
    echo -e "${CYAN}║${NC}   journalctl -u zabbix-agent -f    # 查看日志"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ==================== 主函数 ====================
main() {
    parse_args "$@"
    check_root

    log_info "========== 开始安装Zabbix Agent =========="

    local os_type
    os_type=$(detect_os)

    case "$os_type" in
        rhel)
            install_agent_rhel
            ;;
        debian)
            install_agent_debian
            ;;
        *)
            log_error "不支持的操作系统: $os_type"
            exit 1
            ;;
    esac

    backup_config
    configure_agent
    start_agent
    verify_connection
    show_info

    log_info "========== Zabbix Agent安装完成 =========="
}

main "$@"
