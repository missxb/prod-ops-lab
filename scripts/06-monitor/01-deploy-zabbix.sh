#!/bin/bash
###############################################################################
# 01-deploy-zabbix.sh - 部署Zabbix监控系统
# 功能: 通过Docker Compose部署Zabbix Server、Web UI、MySQL数据库
#       支持远程主机Agent安装
# 项目: 企业级云原生运维平台
# 阶段: 06 - 监控系统
# 作者: 运维平台团队
# 版本: 1.1.0
###############################################################################

set -euo pipefail
umask 077

# 加载公共函数库
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# 错误处理
trap 'log_error "脚本执行出错，行号: ${LINENO}"' ERR

# 清理函数
LOCK_FILE="/var/lock/$(basename "$0").lock"
cleanup() {
    rm -f "${LOCK_FILE}"
    log_info "脚本执行完毕"
}
trap cleanup EXIT
trap 'log_error "收到中断信号，正在清理..."; exit 130' INT TERM

# 锁文件检查
if [ -f "${LOCK_FILE}" ]; then
    log_error "另一个实例正在运行 (PID: $(cat ${LOCK_FILE}))"
    exit 1
fi
echo $$ > "${LOCK_FILE}"

# root权限检查
if [[ $EUID -ne 0 ]]; then
    log_error "此脚本需要root权限运行"
    exit 1
fi

# ==================== 全局变量 ====================
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ZABBIX_CONFIG_DIR="${PROJECT_ROOT}/configs/zabbix"
ZABBIX_DATA_DIR="/opt/zabbix/data"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="${PROJECT_ROOT}/logs/06-monitor"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/zabbix-deploy_${TIMESTAMP}.log"

# Zabbix组件版本
ZABBIX_SERVER_VERSION="${ZABBIX_SERVER_VERSION:-7.0-latest}"
ZABBIX_WEB_VERSION="${ZABBIX_WEB_VERSION:-7.0-latest}"
MYSQL_VERSION="${MYSQL_VERSION:-8.0}"

# 网络配置
ZABBIX_WEB_PORT="${ZABBIX_WEB_PORT:-8080}"
ZABBIX_SERVER_PORT="${ZABBIX_SERVER_PORT:-10051}"

# 数据库配置
MYSQL_DATABASE="${MYSQL_DATABASE:-zabbix}"
MYSQL_USER="${MYSQL_USER:-zabbix}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-zabbix_password_2026}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-root_password_2026}"

# ==================== 日志函数 ====================
# (使用common.sh中的日志函数)

# ==================== 用法说明 ====================
usage() {
    cat << EOF
用法: $(basename "$0") [options]

功能: 部署Zabbix监控系统（Server + Web UI + MySQL）

操作选项:
  deploy       部署完整Zabbix监控栈（默认）
  agent        仅安装Zabbix Agent到远程主机
  status       查看各组件运行状态
  stop         停止所有Zabbix容器
  help         显示此帮助信息

环境变量:
  ZABBIX_WEB_PORT       Web UI端口（默认: 8080）
  ZABBIX_SERVER_PORT    Server端口（默认: 10051）
  MYSQL_PASSWORD        MySQL密码（默认: zabbix_password_2026）
  MYSQL_ROOT_PASSWORD   MySQL root密码（默认: root_password_2026）

示例:
  $(basename "$0") deploy        # 部署完整Zabbix
  $(basename "$0") agent         # 安装Agent到远程主机
  $(basename "$0") status        # 查看状态
EOF
}

# ==================== 环境检查 ====================
# 功能: 检查Docker和Docker Compose是否可用
check_prerequisites() {
    log_step "[1/6] 检查前置条件..."

    # 检查Docker
    if ! command -v docker &>/dev/null; then
        log_error "Docker未安装，请先安装Docker"
        exit 1
    fi
    log_success "Docker已安装: $(docker --version)"

    # 检查Docker Compose
    if ! docker compose version &>/dev/null 2>&1 && ! docker-compose version &>/dev/null 2>&1; then
        log_error "Docker Compose未安装，请先安装Docker Compose"
        exit 1
    fi
    log_success "Docker Compose已安装"

    # 检查Docker服务状态
    if ! systemctl is-active docker &>/dev/null; then
        log_warn "Docker服务未运行，正在启动..."
        systemctl start docker
        systemctl enable docker
    fi
    log_success "Docker服务运行正常"

    # 检查端口占用
    local ports=($ZABBIX_WEB_PORT $ZABBIX_SERVER_PORT)
    for port in "${ports[@]}"; do
        if ss -tlnp | grep -q ":${port} " 2>/dev/null; then
            log_warn "端口 $port 已被占用，请确认是否继续"
        fi
    done
}

# ==================== 创建配置目录 ====================
# 功能: 创建Zabbix配置文件目录和数据目录
create_directories() {
    log_step "[2/6] 创建配置目录..."

    mkdir -p "$ZABBIX_CONFIG_DIR"
    mkdir -p "$ZABBIX_DATA_DIR"
    mkdir -p "${LOG_DIR}"

    log_success "配置目录创建完成: $ZABBIX_CONFIG_DIR"
}

# ==================== 生成Docker Compose配置 ====================
# 功能: 生成Zabbix Docker Compose配置文件
generate_docker_compose() {
    log_step "[3/6] 生成Docker Compose配置..."

    cat > "${ZABBIX_CONFIG_DIR}/docker-compose.yml" << 'COMPOSE_EOF'
version: '3.8'
services:
  mysql-server:
    image: mysql:8.0
    container_name: zabbix-mysql
    restart: always
    environment:
      MYSQL_DATABASE: zabbix
      MYSQL_USER: zabbix
      MYSQL_PASSWORD: zabbix_password_2026
      MYSQL_ROOT_PASSWORD: root_password_2026
    volumes:
      - zabbix-mysql-data:/var/lib/mysql
    networks:
      - zabbix-net
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5

  zabbix-server:
    image: zabbix/zabbix-server-mysql:7.0-latest
    container_name: zabbix-server
    restart: always
    environment:
      DB_SERVER_HOST: mysql-server
      MYSQL_DATABASE: zabbix
      MYSQL_USER: zabbix
      MYSQL_PASSWORD: zabbix_password_2026
      ZBX_CACHESIZE: 512M
      ZBX_HISTORYCACHESIZE: 256M
    ports:
      - "10051:10051"
    depends_on:
      mysql-server:
        condition: service_healthy
    networks:
      - zabbix-net

  zabbix-web:
    image: zabbix/zabbix-web-nginx-mysql:7.0-latest
    container_name: zabbix-web
    restart: always
    environment:
      DB_SERVER_HOST: mysql-server
      MYSQL_DATABASE: zabbix
      MYSQL_USER: zabbix
      MYSQL_PASSWORD: zabbix_password_2026
      ZBX_SERVER_HOST: zabbix-server
      PHP_TZ: Asia/Shanghai
    ports:
      - "8080:8080"
    depends_on:
      zabbix-server:
        condition: service_started
    networks:
      - zabbix-net

networks:
  zabbix-net:
    driver: bridge

volumes:
  zabbix-mysql-data:
COMPOSE_EOF

    log_success "Docker Compose配置生成完成"
}

# ==================== 生成Zabbix Agent配置 ====================
# 功能: 生成Zabbix Agent配置文件用于远程主机安装
generate_agent_config() {
    log_step "[4/6] 生成Zabbix Agent配置..."

    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    cat > "${ZABBIX_CONFIG_DIR}/zabbix_agentd.conf" << CONF
# Zabbix Agent配置文件
# 项目: 企业级云原生运维平台
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 版本: 1.1.0

# Agent配置
PidFile=/tmp/zabbix_agentd.pid
LogFile=/var/log/zabbix/zabbix_agentd.log
LogFileSize=100

# Server配置 - 指向Zabbix Server地址
Server=${server_ip}
ServerActive=${server_ip}
Hostname=$(hostname)

# 监控参数
AllowKey=system.run[*]
AllowKey=vfs.file.contents[/etc/os-release]

# 安全配置
EnableRemoteCommands=1
LogRemoteCommands=1

# 性能配置
StartAgents=5
MaxProcesses=100
Timeout=30

# TLS加密通信（可选）
# TLSConnect=psk
# TLSAccept=psk
# TLSPSKIdentity=$(hostname)
# TLSPSKFile=/etc/zabbix/zabbix_agentd.psk
CONF

    # 生成Agent安装脚本
    generate_install_agent_script

    log_success "Zabbix Agent配置生成完成"
}

# ==================== 生成Agent安装脚本 ====================
# 功能: 生成用于远程主机安装Zabbix Agent的脚本
generate_install_agent_script() {
    cat > "${ZABBIX_CONFIG_DIR}/install-agent.sh" << 'INSTALL_EOF'
#!/bin/bash
###############################################################################
# install-agent.sh - 在远程主机安装Zabbix Agent
# 功能: 自动检测操作系统并安装Zabbix Agent
# 版本: 1.1.0
# 作者: 运维平台团队
###############################################################################

set -euo pipefail

# Zabbix Server地址（部署后更新此值）
ZABBIX_SERVER="${ZABBIX_SERVER_IP:-192.168.100.10}"
ZABBIX_AGENT_VERSION="7.0"
ZABBIX_AGENT_CONFIG="/etc/zabbix/zabbix_agentd.conf"
ZABBIX_AGENT_LOG="/var/log/zabbix/zabbix_agentd.log"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $(date '+%H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $(date '+%H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*"; }

# 检查root权限
if [[ $EUID -ne 0 ]]; then
    log_error "此脚本需要root权限运行"
    exit 1
fi

# 检测操作系统
detect_os() {
    if [[ -f /etc/redhat-release ]]; then
        echo "rhel"
    elif [[ -f /etc/debian_version ]]; then
        echo "debian"
    else
        echo "unknown"
    fi
}

# 安装Zabbix Agent (RHEL/CentOS)
install_agent_rhel() {
    log_info "检测到RHEL/CentOS系统，开始安装Zabbix Agent..."

    # 安装Zabbix仓库
    rpm -Uvh "https://repo.zabbix.com/zabbix/${ZABBIX_AGENT_VERSION}/rhel/$(rpm -E %rhel)/x86_64/zabbix-release-latest.el$(rpm -E %rhel).noarch.rpm" 2>/dev/null || true
    yum clean all

    # 安装Zabbix Agent
    yum install -y zabbix-agent 2>&1 | tail -5

    # 创建日志目录
    mkdir -p /var/log/zabbix
    chown zabbix:zabbix /var/log/zabbix

    # 备份原始配置
    cp "${ZABBIX_AGENT_CONFIG}" "${ZABBIX_AGENT_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

    log_info "Zabbix Agent安装完成"
}

# 安装Zabbix Agent (Debian/Ubuntu)
install_agent_debian() {
    log_info "检测到Debian/Ubuntu系统，开始安装Zabbix Agent..."

    # 安装Zabbix仓库
    wget -q "https://repo.zabbix.com/zabbix/${ZABBIX_AGENT_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu$(lsb_release -rs | tr -d '.')_all.deb" -O /tmp/zabbix-release.deb 2>/dev/null
    dpkg -i /tmp/zabbix-release.deb 2>/dev/null || true
    apt-get update -qq

    # 安装Zabbix Agent
    apt-get install -y zabbix-agent 2>&1 | tail -5

    # 创建日志目录
    mkdir -p /var/log/zabbix
    chown zabbix:zabbix /var/log/zabbix

    # 备份原始配置
    cp "${ZABBIX_AGENT_CONFIG}" "${ZABBIX_AGENT_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

    log_info "Zabbix Agent安装完成"
}

# 配置Zabbix Agent
configure_agent() {
    log_info "配置Zabbix Agent..."

    # 更新Server地址
    sed -i "s|^Server=.*|Server=${ZABBIX_SERVER}|" "${ZABBIX_AGENT_CONFIG}"
    sed -i "s|^ServerActive=.*|ServerActive=${ZABBIX_SERVER}|" "${ZABBIX_AGENT_CONFIG}"
    sed -i "s|^# Hostname=.*|Hostname=$(hostname)|" "${ZABBIX_AGENT_CONFIG}"
    sed -i "s|^Hostname=.*|Hostname=$(hostname)|" "${ZABBIX_AGENT_CONFIG}"

    # 启用远程命令
    sed -i "s|^# EnableRemoteCommands=.*|EnableRemoteCommands=1|" "${ZABBIX_AGENT_CONFIG}"
    sed -i "s|^EnableRemoteCommands=.*|EnableRemoteCommands=1|" "${ZABBIX_AGENT_CONFIG}"

    # 设置日志文件
    sed -i "s|^LogFile=.*|LogFile=${ZABBIX_AGENT_LOG}|" "${ZABBIX_AGENT_CONFIG}"

    log_info "Zabbix Agent配置完成"
}

# 启动Zabbix Agent
start_agent() {
    log_info "启动Zabbix Agent服务..."

    systemctl enable zabbix-agent
    systemctl restart zabbix-agent

    if systemctl is-active zabbix-agent &>/dev/null; then
        log_info "Zabbix Agent启动成功"
    else
        log_error "Zabbix Agent启动失败"
        systemctl status zabbix-agent --no-pager
        exit 1
    fi
}

# 验证连接
verify_connection() {
    log_info "验证与Zabbix Server的连接..."

    if zabbix_agentd -t agent.ping -c "${ZABBIX_AGENT_CONFIG}" 2>/dev/null | grep -q "1"; then
        log_info "Zabbix Agent连接验证成功"
    else
        log_warn "无法验证连接，请检查Zabbix Server地址和防火墙设置"
    fi
}

# 主函数
main() {
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

    configure_agent
    start_agent
    verify_connection

    log_info "========== Zabbix Agent安装完成 =========="
}

main "$@"
INSTALL_EOF

    chmod +x "${ZABBIX_CONFIG_DIR}/install-agent.sh"
    log_success "Agent安装脚本生成完成"
}

# ==================== 启动Zabbix监控栈 ====================
# 功能: 使用Docker Compose启动Zabbix所有组件
start_zabbix() {
    log_step "[5/6] 启动Zabbix监控栈..."

    cd "$ZABBIX_CONFIG_DIR"

    # 停止旧容器（如果存在）
    docker compose down 2>/dev/null || true

    # 拉取最新镜像
    log_info "拉取Zabbix镜像..."
    docker compose pull 2>&1 | tail -5

    # 启动服务
    log_info "启动Zabbix服务..."
    docker compose up -d

    # 等待MySQL就绪
    log_info "等待MySQL数据库就绪..."
    local retries=30
    while [[ $retries -gt 0 ]]; do
        if docker exec zabbix-mysql mysqladmin ping -h localhost 2>/dev/null | grep -q "alive"; then
            log_success "MySQL数据库已就绪"
            break
        fi
        retries=$((retries - 1))
        sleep 2
    done

    if [[ $retries -eq 0 ]]; then
        log_error "MySQL数据库启动超时"
        exit 1
    fi

    # 等待Zabbix Server就绪
    log_info "等待Zabbix Server就绪..."
    retries=60
    while [[ $retries -gt 0 ]]; do
        if docker logs zabbix-server 2>&1 | grep -q "completed"; then
            log_success "Zabbix Server已就绪"
            break
        fi
        retries=$((retries - 1))
        sleep 3
    done

    if [[ $retries -eq 0 ]]; then
        log_warn "Zabbix Server启动可能未完成，请检查日志"
    fi

    # 等待Web UI就绪
    log_info "等待Zabbix Web UI就绪..."
    retries=30
    while [[ $retries -gt 0 ]]; do
        if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${ZABBIX_WEB_PORT}" 2>/dev/null | grep -qE "^(200|302)$"; then
            log_success "Zabbix Web UI已就绪"
            break
        fi
        retries=$((retries - 1))
        sleep 3
    done

    if [[ $retries -eq 0 ]]; then
        log_warn "Zabbix Web UI可能未完全就绪，请稍后重试"
    fi
}

# ==================== 验证部署 ====================
# 功能: 验证所有Zabbix组件正常运行
verify_deployment() {
    log_step "[6/6] 验证Zabbix部署..."

    local all_ok=true

    # 检查容器状态
    log_info "检查容器状态..."
    local containers=("zabbix-mysql:MySQL数据库" "zabbix-server:Zabbix Server" "zabbix-web:Zabbix Web UI")

    for container_info in "${containers[@]}"; do
        IFS=':' read -r container name <<< "$container_info"
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            log_success "$name ($container) 运行正常"
        else
            log_error "$name ($container) 未运行"
            all_ok=false
        fi
    done

    # 检查端口监听
    log_info "检查端口监听..."
    if ss -tlnp | grep -q ":${ZABBIX_WEB_PORT} "; then
        log_success "Web UI端口 ${ZABBIX_WEB_PORT} 监听正常"
    else
        log_error "Web UI端口 ${ZABBIX_WEB_PORT} 未监听"
        all_ok=false
    fi

    if ss -tlnp | grep -q ":${ZABBIX_SERVER_PORT} "; then
        log_success "Server端口 ${ZABBIX_SERVER_PORT} 监听正常"
    else
        log_warn "Server端口 ${ZABBIX_SERVER_PORT} 未监听（可能通过Docker网络通信）"
    fi

    # 检查Zabbix Server日志
    log_info "检查Zabbix Server日志..."
    if docker logs zabbix-server 2>&1 | tail -5 | grep -i "ready"; then
        log_success "Zabbix Server日志正常"
    fi

    return 0
}

# ==================== 显示部署信息 ====================
# 功能: 显示访问URL、默认凭据等部署信息
show_deployment_info() {
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║            Zabbix监控系统部署完成                           ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC} 访问地址: http://${server_ip}:${ZABBIX_WEB_PORT}"
    echo -e "${CYAN}║${NC} 默认用户名: ${BOLD}Admin${NC}"
    echo -e "${CYAN}║${NC} 默认密码: ${BOLD}zabbix${NC}"
    echo -e "${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} Zabbix Server端口: ${ZABBIX_SERVER_PORT}"
    echo -e "${CYAN}║${NC} MySQL端口: 3306（内部）"
    echo -e "${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} 配置文件目录: ${ZABBIX_CONFIG_DIR}"
    echo -e "${CYAN}║${NC} Agent安装脚本: ${ZABBIX_CONFIG_DIR}/install-agent.sh"
    echo -e "${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} ${YELLOW}⚠ 请立即修改默认密码!${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ==================== 显示状态 ====================
# 功能: 检查并显示所有Zabbix组件的运行状态
show_status() {
    log_step "检查Zabbix组件状态..."
    echo ""

    # 容器状态
    echo "  容器状态:"
    docker ps --filter "name=zabbix" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "  无Zabbix容器运行"
    echo ""

    # 端口状态
    echo "  端口监听状态:"
    for port in $ZABBIX_WEB_PORT $ZABBIX_SERVER_PORT 3306; do
        if ss -tlnp | grep -q ":${port} " 2>/dev/null; then
            echo "    端口 $port: ✓ 监听中"
        else
            echo "    端口 $port: ✗ 未监听"
        fi
    done
    echo ""
}

# ==================== 停止Zabbix ====================
# 功能: 停止所有Zabbix容器
stop_zabbix() {
    log_step "停止Zabbix监控栈..."
    cd "$ZABBIX_CONFIG_DIR"
    docker compose down 2>/dev/null || true
    log_success "Zabbix监控栈已停止"
}

# ==================== 主流程 ====================
main() {
    local action="${1:-deploy}"

    case "$action" in
        help|-h|--help)
            usage
            exit 0
            ;;
        deploy)
            log_info "========== Zabbix监控系统部署开始 =========="
            check_prerequisites
            create_directories
            generate_docker_compose
            generate_agent_config
            start_zabbix
            verify_deployment
            show_deployment_info
            log_info "========== Zabbix监控系统部署完成 =========="
            ;;
        agent)
            log_step "安装Zabbix Agent..."
            bash "${ZABBIX_CONFIG_DIR}/install-agent.sh"
            ;;
        status)
            show_status
            ;;
        stop)
            stop_zabbix
            ;;
        *)
            echo "用法: $0 {deploy|agent|status|stop|help}"
            exit 1
            ;;
    esac
}

main "$@"
