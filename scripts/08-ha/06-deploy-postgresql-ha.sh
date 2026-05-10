#!/bin/bash
###############################################################################
# 06-部署PostgreSQL高可用脚本
# 功能: 部署PostgreSQL流复制，支持主从高可用配置
# 特性: 流复制、热备、同步提交、复制用户管理
# 版本: 1.1.0
# 作者: 运维平台团队
###############################################################################

set -euo pipefail
umask 077

# ==================== 颜色定义 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 日志函数
log_info()    { echo -e "${GREEN}[INFO]${NC}    $(date '+%H:%M:%S') $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $(date '+%H:%M:%S') $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $(date '+%H:%M:%S') $*"; }
log_step()    { echo -e "${CYAN}[STEP]${NC}    $(date '+%H:%M:%S') $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%H:%M:%S') ✓ $*"; }

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

# ==================== 配置变量 ====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../" && pwd)"
CONFIGS_DIR="${PROJECT_ROOT}/configs/postgresql"
LOG_DIR="${PROJECT_ROOT}/logs/08-ha"

# PostgreSQL路径配置
PG_DATA_DIR="${PG_DATA_DIR:-/var/lib/postgresql/data}"
PG_CONFIG_DIR="${PG_CONFIG_DIR:-/etc/postgresql}"
PG_LOG_DIR="${PG_LOG_DIR:-/var/log/postgresql}"
PG_VERSION="${PG_VERSION:-15}"

# 复制配置
MASTER_HOST="${MASTER_HOST:-192.168.100.10}"
MASTER_PORT="${MASTER_PORT:-5432}"
SLAVE_HOST="${SLAVE_HOST:-192.168.100.11}"
REPL_USER="${REPL_USER:-repl_user}"
REPL_PASS="${REPL_PASS:-repl_pass_2024}"
PG_USER="${PG_USER:-postgres}"

# 节点角色
NODE_ROLE="${NODE_ROLE:-auto}"

# ==================== 用法说明 ====================
usage() {
    cat << EOF
用法: $(basename "$0") [options]

功能: 部署PostgreSQL流复制，支持主从高可用

选项:
  --role <master|slave>   指定节点角色
  --master-host <IP>      主节点IP
  --slave-host <IP>       从节点IP
  --repl-user <user>      复制用户名
  --repl-pass <pass>      复制用户密码
  --help                  显示此帮助信息

环境变量:
  MASTER_HOST    主节点IP（默认: 192.168.100.10）
  SLAVE_HOST     从节点IP（默认: 192.168.100.11）
  REPL_USER      复制用户（默认: repl_user）
  REPL_PASS      复制密码（默认: repl_pass_2024）
  NODE_ROLE      节点角色（默认: auto，根据IP自动检测）
  PG_VERSION     PostgreSQL版本（默认: 15）

示例:
  $(basename "$0") --role master
  $(basename "$0") --role slave --master-host 10.0.0.10
EOF
    exit 0
}

# ==================== 参数解析 ====================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --role)       NODE_ROLE="$2"; shift 2 ;;
            --master-host) MASTER_HOST="$2"; shift 2 ;;
            --slave-host) SLAVE_HOST="$2"; shift 2 ;;
            --repl-user)  REPL_USER="$2"; shift 2 ;;
            --repl-pass)  REPL_PASS="$2"; shift 2 ;;
            --help|-h)    usage ;;
            *) log_error "未知参数: $1"; usage ;;
        esac
    done
}

# ==================== 前置检查 ====================
check_prerequisites() {
    log_step "[1/6] 前置检查..."

    # 检查root权限
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        exit 1
    fi

    # 检查PostgreSQL是否已安装
    if ! command -v pg_isready &>/dev/null; then
        log_warn "PostgreSQL未安装，开始安装..."
        install_postgresql
    fi

    # 获取已安装版本
    local pg_version_installed
    pg_version_installed=$(psql --version 2>/dev/null | awk '{print $3}' | cut -d. -f1 || echo "0")
    log_info "PostgreSQL版本: $(psql --version 2>/dev/null || echo 'unknown')"

    # 检查必要命令
    for cmd in pg_isready psql pg_basebackup; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "缺少必要命令: $cmd"
            exit 1
        fi
    done

    log_info "前置检查通过"
}

# ==================== 安装PostgreSQL ====================
install_postgresql() {
    log_step "安装PostgreSQL ${PG_VERSION}..."

    if [[ -f /etc/redhat-release ]]; then
        # CentOS/RHEL
        if [[ -f /etc/yum.repos.d/pgdg-redhat-all.repo ]] 2>/dev/null || \
           rpm -q "pgdg-redhat-repo" &>/dev/null; then
            log_info "PostgreSQL官方仓库已配置"
        else
            # 安装PostgreSQL官方仓库
            local pkg_url="https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
            rpm -ivh "$pkg_url" 2>/dev/null || true
            # 禁用系统自带的PostgreSQL模块
            dnf -qy module disable postgresql 2>/dev/null || true
        fi
        dnf install -y postgresql${PG_VERSION}-server postgresql${PG_VERSION} 2>&1 | tail -3
    elif [[ -f /etc/debian_version ]]; then
        # Debian/Ubuntu
        echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
            > /etc/apt/sources.list.d/pgdg.list
        curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -
        apt-get update -qq
        apt-get install -y postgresql-${PG_VERSION} postgresql-client-${PG_VERSION} 2>&1 | tail -3
    else
        log_error "不支持的操作系统"
        exit 1
    fi

    log_info "PostgreSQL安装完成"
}

# ==================== 检测节点角色 ====================
detect_role() {
    if [[ "$NODE_ROLE" != "auto" ]]; then
        echo "$NODE_ROLE"
        return
    fi

    local local_ip
    local_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")
    local local_hostname
    local_hostname=$(hostname)

    if [[ "$local_hostname" == *"master"* ]] || [[ "$local_ip" == "$MASTER_HOST" ]]; then
        echo "master"
    else
        echo "slave"
    fi
}

# ==================== 创建目录结构 ====================
setup_directories() {
    log_step "创建目录结构..."

    mkdir -p "$PG_DATA_DIR" "$PG_LOG_DIR" "$PG_CONFIG_DIR" "$LOG_DIR"

    # 设置正确的所有者
    if id postgres &>/dev/null; then
        chown -R postgres:postgres "$PG_DATA_DIR" "$PG_LOG_DIR"
    fi

    log_info "目录结构创建完成"
}

# ==================== 初始化PostgreSQL数据目录 ====================
initialize_database() {
    log_step "[2/6] 初始化PostgreSQL数据目录..."

    if [[ -f "$PG_DATA_DIR/PG_VERSION" ]]; then
        log_info "数据目录已存在，跳过初始化"
        return 0
    fi

    if id postgres &>/dev/null; then
        su - postgres -c "initdb -D '$PG_DATA_DIR' --encoding=UTF8 --locale=en_US.UTF-8" 2>&1 | tail -5
    else
        initdb -D "$PG_DATA_DIR" --encoding=UTF8 --locale=en_US.UTF-8 2>&1 | tail -5
    fi

    log_info "数据目录初始化完成"
}

# ==================== 配置主节点 ====================
configure_master() {
    local role=$1
    log_step "[3/6] 配置主节点 (角色: $role)..."

    if [[ "$role" != "master" ]]; then
        log_info "非主节点，跳过主节点配置"
        return 0
    fi

    # 复制主节点配置
    if [[ -f "${CONFIGS_DIR}/master.conf" ]]; then
        cp "${CONFIGS_DIR}/master.conf" "${PG_CONFIG_DIR}/postgresql.conf"
        log_info "已复制主节点配置文件"
    else
        # 直接写入配置
        cat > "${PG_CONFIG_DIR}/postgresql.conf" <<'PGCONF'
# ==================== WAL配置 ====================
wal_level = replica
max_wal_senders = 3
wal_keep_size = 1024
synchronous_commit = on
hot_standby = on

# ==================== 连接配置 ====================
listen_addresses = '*'
port = 5432
max_connections = 200
superuser_reserved_connections = 5

# ==================== 写入性能 ====================
wal_buffers = 64MB
full_page_writes = on

# ==================== Checkpoint ====================
checkpoint_timeout = 15min
checkpoint_completion_target = 0.9

# ==================== 日志配置 ====================
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d '
log_statement = 'ddl'
log_min_duration_statement = 1000
log_connections = on
log_disconnections = on

# ==================== 自动清理 ====================
autovacuum_max_workers = 3
autovacuum_naptime = 1min
PGCONF
    fi

    # 复制pg_hba.conf
    if [[ -f "${CONFIGS_DIR}/pg_hba-master.conf" ]]; then
        cp "${CONFIGS_DIR}/pg_hba-master.conf" "${PG_CONFIG_DIR}/pg_hba.conf"
    fi

    log_info "主节点配置完成"
}

# ==================== 配置从节点 ====================
configure_slave() {
    local role=$1
    log_step "[4/6] 配置从节点 (角色: $role)..."

    if [[ "$role" != "slave" ]]; then
        log_info "非从节点，跳过从节点配置"
        return 0
    fi

    # 复制从节点配置
    if [[ -f "${CONFIGS_DIR}/slave.conf" ]]; then
        cp "${CONFIGS_DIR}/slave.conf" "${PG_CONFIG_DIR}/postgresql.conf"
        log_info "已复制从节点配置文件"
    else
        # 直接写入配置
        cat > "${PG_CONFIG_DIR}/postgresql.conf" <<'PGCONF'
# ==================== 热备配置 ====================
wal_level = replica
max_wal_senders = 3
synchronous_commit = on
hot_standby = on
hot_standby_feedback = on

# ==================== 连接配置 ====================
listen_addresses = '*'
port = 5432
max_connections = 200
superuser_reserved_connections = 5

# ==================== 写入性能 ====================
wal_buffers = 64MB
full_page_writes = on

# ==================== Checkpoint ====================
checkpoint_timeout = 15min
checkpoint_completion_target = 0.9

# ==================== 日志配置 ====================
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d '
log_statement = 'ddl'
log_min_duration_statement = 1000
log_connections = on
log_disconnections = on

# ==================== 自动清理 ====================
autovacuum_max_workers = 3
autovacuum_naptime = 1min
PGCONF
    fi

    # 复制从节点pg_hba.conf
    if [[ -f "${CONFIGS_DIR}/pg_hba-slave.conf" ]]; then
        cp "${CONFIGS_DIR}/pg_hba-slave.conf" "${PG_CONFIG_DIR}/pg_hba.conf"
    fi

    log_info "从节点配置完成"
}

# ==================== 创建复制用户 ====================
create_replication_user() {
    local role=$1
    log_step "[5/6] 创建复制用户..."

    if [[ "$role" != "master" ]]; then
        log_info "非主节点，跳过复制用户创建"
        return 0
    fi

    # 检查复制用户是否已存在
    local user_exists
    user_exists=$(su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${REPL_USER}'\"" 2>/dev/null || echo "")

    if [[ "$user_exists" == "1" ]]; then
        log_info "复制用户 '${REPL_USER}' 已存在"
        return 0
    fi

    # 创建复制用户
    su - postgres -c "psql -c \"
CREATE USER ${REPL_USER} WITH REPLICATION LOGIN PASSWORD '${REPL_PASS}';
GRANT ALL PRIVILEGES ON DATABASE postgres TO ${REPL_USER};
\"" 2>&1

    log_info "复制用户创建完成: ${REPL_USER}"
}

# ==================== 配置流复制 ====================
configure_streaming_replication() {
    local role=$1
    log_step "[6/6] 配置流复制..."

    if [[ "$role" == "master" ]]; then
        # 主节点: 设置archive_command（可选）
        log_info "主节点流复制配置完成"

        # 启动PostgreSQL
        restart_postgresql

        # 验证复制状态
        sleep 2
        local repl_status
        repl_status=$(su - postgres -c "psql -tAc \"SELECT count(*) FROM pg_stat_replication;\"" 2>/dev/null || echo "0")
        log_info "当前连接的从库数量: $repl_status"

    elif [[ "$role" == "slave" ]]; then
        # 从节点: 从主节点获取基础备份
        log_info "开始从主节点获取基础备份..."

        # 停止从节点PostgreSQL
        stop_postgresql

        # 清空数据目录
        rm -rf "${PG_DATA_DIR:?}"/*

        # 使用pg_basebackup从主节点获取基础备份
        if pg_basebackup \
            -h "$MASTER_HOST" \
            -p "$MASTER_PORT" \
            -U "$REPL_USER" \
            -D "$PG_DATA_DIR" \
            -Fp -Xs -P -R \
            2>&1; then
            log_info "基础备份获取成功"
        else
            log_error "基础备份获取失败，请检查主节点连接和复制用户配置"
            exit 1
        fi

        # 创建standby.signal文件
        touch "${PG_DATA_DIR}/standby.signal"
        log_info "已创建standby.signal文件"

        # 配置primary_conninfo
        cat >> "${PG_DATA_DIR}/postgresql.auto.conf" <<AUTOCONF

# ==================== 复制连接信息 ====================
# 主节点连接配置
primary_conninfo = 'host=${MASTER_HOST} port=${MASTER_PORT} user=${REPL_USER} password=${REPL_PASS} application_name=slave1'
AUTOCONF

        log_info "primary_conninfo配置完成"

        # 启动从节点
        restart_postgresql
    fi

    log_info "流复制配置完成"
}

# ==================== 启动/停止PostgreSQL ====================
start_postgresql() {
    if systemctl is-active --quiet postgresql 2>/dev/null; then
        log_info "PostgreSQL已在运行"
        return 0
    fi

    if [[ -d /run/systemd/system ]]; then
        systemctl start postgresql
    else
        su - postgres -c "pg_ctl -D '$PG_DATA_DIR' -l '$PG_LOG_DIR/postgresql.log' start"
    fi

    log_info "PostgreSQL启动成功"
}

stop_postgresql() {
    if ! pg_isready -q 2>/dev/null; then
        log_info "PostgreSQL未运行"
        return 0
    fi

    if [[ -d /run/systemd/system ]]; then
        systemctl stop postgresql
    else
        su - postgres -c "pg_ctl -D '$PG_DATA_DIR' stop -m fast"
    fi

    log_info "PostgreSQL已停止"
}

restart_postgresql() {
    log_info "重启PostgreSQL..."
    stop_postgresql
    sleep 2
    start_postgresql
}

# ==================== 验证部署结果 ====================
verify_deployment() {
    local role=$1
    log_step "验证部署结果..."

    # 检查PostgreSQL是否运行
    if pg_isready -q 2>/dev/null; then
        log_info "PostgreSQL运行正常"
    else
        log_error "PostgreSQL未运行"
        return 1
    fi

    if [[ "$role" == "master" ]]; then
        # 验证复制状态
        local repl_count
        repl_count=$(su - postgres -c "psql -tAc \"SELECT count(*) FROM pg_stat_replication;\"" 2>/dev/null || echo "0")
        log_info "主节点复制状态: 连接从库数=$repl_count"

        # 验证WAL配置
        local wal_level
        wal_level=$(su - postgres -c "psql -tAc \"SHOW wal_level;\"" 2>/dev/null || echo "unknown")
        log_info "WAL级别: $wal_level"

        # 验证max_wal_senders
        local max_wal
        max_wal=$(su - postgres -c "psql -tAc \"SHOW max_wal_senders;\"" 2>/dev/null || echo "unknown")
        log_info "最大WAL发送进程: $max_wal"

    elif [[ "$role" == "slave" ]]; then
        # 验证热备状态
        local hot_standby
        hot_standby=$(su - postgres -c "psql -tAc \"SHOW hot_standby;\"" 2>/dev/null || echo "unknown")
        log_info "热备模式: $hot_standby"

        # 验证只读模式
        local read_only
        read_only=$(su - postgres -c "psql -tAc \"SHOW default_transaction_read_only;\"" 2>/dev/null || echo "unknown")
        log_info "只读模式: $read_only"

        # 检查standby.signal
        if [[ -f "${PG_DATA_DIR}/standby.signal" ]]; then
            log_info "standby.signal文件存在"
        else
            log_warn "standby.signal文件不存在"
        fi
    fi

    log_info "部署验证完成"
}

# ==================== 生成部署报告 ====================
generate_report() {
    local role=$1
    local report_file="${LOG_DIR}/postgresql-ha-$(date +%Y%m%d-%H%M%S).log"

    mkdir -p "$LOG_DIR"

    cat > "$report_file" <<REPORT
=================================================================
PostgreSQL HA 部署报告
生成时间: $(date '+%Y-%m-%d %H:%M:%S')
=================================================================

节点角色: ${role}
主机名:   $(hostname)
IP地址:   $(hostname -I 2>/dev/null | awk '{print $1}' || echo 'unknown')

PostgreSQL版本: $(psql --version 2>/dev/null || echo 'unknown')
数据目录: ${PG_DATA_DIR}
配置目录: ${PG_CONFIG_DIR}

复制配置:
  主节点:   ${MASTER_HOST}
  复制用户: ${REPL_USER}

WAL配置:
  wal_level:         replica
  max_wal_senders:   3
  synchronous_commit: on
  hot_standby:       on

=================================================================
REPORT

    log_info "部署报告已保存: $report_file"
}

# ==================== 主函数 ====================
main() {
    parse_args "$@"

    echo ""
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${CYAN}  PostgreSQL 高可用部署${NC}"
    echo -e "${CYAN}  版本: 1.1.0${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo ""

    # 检测节点角色
    local role
    role=$(detect_role)
    log_info "节点角色: $role"

    # 执行部署步骤
    check_prerequisites
    setup_directories
    initialize_database
    configure_master "$role"
    configure_slave "$role"
    create_replication_user "$role"
    configure_streaming_replication "$role"

    # 验证部署
    verify_deployment "$role"

    # 生成报告
    generate_report "$role"

    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}  PostgreSQL HA 部署完成!${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo ""
}

# 执行主函数
main "$@"
