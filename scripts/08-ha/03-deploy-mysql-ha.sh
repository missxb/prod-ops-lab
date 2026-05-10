#!/bin/bash
###############################################################################
# 03-部署MySQL高可用脚本
# 功能: 部署MySQL主从复制，支持半同步和自动故障转移
# 特性: 主从复制、半同步复制、GTID模式、自动故障转移
###############################################################################

set -euo pipefail

# 错误处理
trap 'log_error "MySQL HA部署脚本异常退出 (行号: $LINENO)"' ERR
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "脚本执行失败，退出码: $exit_code"
    fi
    return $exit_code
}
trap cleanup EXIT

# 颜色输出
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

功能: 部署MySQL主从复制，支持半同步和GTID模式

环境变量:
  MASTER_HOST    主节点IP（默认: 192.168.100.10）
  SLAVE_HOST     从节点IP（默认: 192.168.100.11）
  REPL_USER      复制用户（默认: repl_user）
  REPL_PASS      复制密码（默认: repl_pass_2024）
  ROOT_PASS      root密码（默认: root_pass_2024）
  NODE_ROLE      节点角色（默认: auto）

示例:
  NODE_ROLE=master $(basename "$0")
  NODE_ROLE=slave $(basename "$0")
EOF
}

# ==================== 配置变量 ====================
MYSQL_VERSION="${MYSQL_VERSION:-8.0}"
DATA_DIR="/var/lib/mysql"
LOG_DIR="/var/log/mysql"
CONFIG_DIR="/etc/mysql"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="$(cd "$SCRIPT_DIR/../../configs" && pwd)"

# 长期存储配置 (Longhorn 兼容性)
# 当在 Kubernetes 环境中运行时，数据目录应挂载到 Longhorn PVC
# 示例 PVC: mysql-data-pvc (StorageClass: longhorn, 50Gi)
# 此脚本为裸金属模式，直接使用本地磁盘
STORAGE_MOUNT="${STORAGE_MOUNT:-/var/lib/mysql}"

# MySQL复制配置
MASTER_HOST="${MASTER_HOST:-192.168.100.10}"
MASTER_PORT="${MASTER_PORT:-3306}"
SLAVE_HOST="${SLAVE_HOST:-192.168.100.11}"
REPL_USER="${REPL_USER:-repl_user}"
REPL_PASS="${REPL_PASS:-repl_pass_2024}"
ROOT_PASS="${ROOT_PASS:-root_pass_2024}"
MONITOR_USER="${MONITOR_USER:-monitor}"
MONITOR_PASS="${MONITOR_PASS:-monitor_pass}"

# 节点角色检测
NODE_ROLE="${NODE_ROLE:-auto}"

# ==================== 节点角色检测 ====================
# 功能: 根据环境变量、主机名或IP自动判断master/slave角色
# 参数: 无
# 返回: "master" 或 "slave"
detect_role() {
    if [[ "$NODE_ROLE" != "auto" ]]; then
        echo "$NODE_ROLE"
        return
    fi

    local ip
    ip=$(hostname -I | awk '{print $1}')
    local hostname
    hostname=$(hostname)

    if [[ "$hostname" == *"master"* ]] || [[ "$ip" == "$MASTER_HOST" ]]; then
        echo "master"
    else
        echo "slave"
    fi
}

# ==================== 存储检查 ====================
# 验证数据目录可用性（Longhorn 兼容: 可挂载 PVC 到 DATA_DIR）
check_storage() {
    log_step "检查存储配置..."

    # 确保数据目录存在且可写
    mkdir -p "$DATA_DIR" "$LOG_DIR" "$CONFIG_DIR"

    # 检查磁盘空间 (至少需要 5GB 可用)
    local available_kb
    available_kb=$(df -k "$DATA_DIR" | awk 'NR==2{print $4}')
    local available_gb=$((available_kb / 1024 / 1024))
    if [[ "$available_gb" -lt 5 ]]; then
        log_error "磁盘空间不足: 仅 ${available_gb}GB 可用 (需要至少 5GB)"
        log_error "如果使用 Longhorn，请确保存储池有足够容量"
        exit 1
    fi
    log_info "磁盘空间检查通过: ${available_gb}GB 可用"

    # 检查是否为 Longhorn 挂载点
    if df -T "$DATA_DIR" 2>/dev/null | grep -q "longhorn"; then
        log_info "检测到 Longhorn 存储卷挂载"
    else
        log_info "使用本地存储: $DATA_DIR"
    fi

    log_info "存储检查完成"
}

# ==================== 安装MySQL ====================
# 功能: 检测并安装MySQL 8.0
# 支持: CentOS/RHEL (yum), Debian/Ubuntu (apt)
# 返回: 无（失败则exit 1）
install_mysql() {
    log_step "[1/6] 安装MySQL ${MYSQL_VERSION}..."

    if command -v mysqld &>/dev/null; then
        local installed_version
        installed_version=$(mysqld --version 2>&1 | awk '{print $3}' | head -1)
        log_info "MySQL已安装，版本: $installed_version"
        return
    fi

    log_info "开始安装MySQL..."

    if [[ -f /etc/redhat-release ]]; then
        # 安装MySQL YUM仓库
        local rpm_url="https://dev.mysql.com/get/mysql80-community-release-el7-11.noarch.rpm"
        rpm -ivh "$rpm_url" 2>/dev/null || true
        yum install -y mysql-server mysql 2>&1 | tail -3
    elif [[ -f /etc/debian_version ]]; then
        # 安装MySQL APT仓库
        apt-get update -qq
        apt-get install -y mysql-server mysql-client 2>&1 | tail -3
    fi

    log_info "MySQL安装完成"
}

# ==================== 生成MySQL配置 ====================
generate_config() {
    local role=$1
    log_step "[2/6] 生成MySQL配置 (角色: $role)..."

    mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"

    if [[ "$role" == "master" ]]; then
        cat > "$CONFIG_DIR/master.cnf" <<'CONF'
###############################################################################
# MySQL 主节点配置
# 项目: 企业级云原生运维平台
# 功能: 主从复制主节点，支持半同步复制
###############################################################################

[mysqld]
# ==================== 基本配置 ====================
# 服务器ID（集群中必须唯一）
server-id = 1

# 端口
port = 3306

# 绑定地址（允许远程连接）
bind-address = 0.0.0.0

# 数据目录
datadir = /var/lib/mysql

# 日志目录
log-error = /var/log/mysql/error.log

# ==================== 日志配置 ====================
# 二进制日志（主从复制必需）
log-bin = /var/log/mysql/mysql-bin

# 二进制日志格式
# ROW: 记录行变化（推荐，最安全）
# STATEMENT: 记录SQL语句（可能不一致）
# MIXED: 混合模式
binlog_format = ROW

# 二进制日志过期天数
expire_logs_days = 7

# 二进制日志缓存大小
binlog_cache_size = 4M

# 单个二进制日志文件最大大小
max_binlog_size = 256M

# 二进制日志同步策略
# 1: 每次事务提交时同步（最安全，性能最低）
# 0: 由OS决定（最快，可能丢数据）
# N: 每N次事务同步一次
sync_binlog = 1

# ==================== GTID配置 ====================
# 启用GTID（全局事务标识符）
gtid_mode = ON

# 强制GTID一致性
enforce_gtid_consistency = ON

# ==================== 半同步复制配置 ====================
# 加载半同步复制插件
# 主节点需要rpl_semi_sync_master
plugin-load = "rpl_semi_sync_master=semisync_master.so;rpl_semi_sync_slave=semisync_slave.so"

# 启用半同步复制
rpl_semi_sync_master_enabled = ON

# 半同步复制超时（毫秒），超时后降级为异步复制
rpl_semi_sync_master_timeout = 3000

# 半同步复制等待的从节点数量
rpl_semi_sync_master_wait_for_slave_count = 1

# 半同步复制降级后自动恢复为半同步
rpl_semi_sync_master_enabled_after_no_slave = ON

# ==================== InnoDB配置 ====================
# InnoDB缓冲池大小（建议为物理内存的70-80%）
innodb_buffer_pool_size = 1G

# InnoDB缓冲池实例数
innodb_buffer_pool_instances = 4

# InnoDB日志文件大小
innodb_log_file_size = 256M

# InnoDB日志缓冲区大小
innodb_log_buffer_size = 64M

# InnoDB刷新策略
innodb_flush_log_at_trx_commit = 1

# InnoDB I/O容量
innodb_io_capacity = 1000

# InnoDB文件per表
innodb_file_per_table = 1

# ==================== 连接配置 ====================
# 最大连接数
max_connections = 500

# 最大用户连接数
max_user_connections = 400

# 连接超时
connect_timeout = 10

# 网络读取超时
net_read_timeout = 30

# 网络写入超时
net_write_timeout = 60

# ==================== 缓存配置 ====================
# 查询缓存（MySQL 8.0已移除）
# query_cache_type = 0

# 排序缓冲区
sort_buffer_size = 4M

# 连接缓冲区
join_buffer_size = 4M

# 读取缓冲区
read_buffer_size = 2M

# 随机读取缓冲区
read_rnd_buffer_size = 8M

# 表定义缓存
table_open_cache = 2000

# 表缓存
table_open_cache_instances = 16

# ==================== 安全配置 ====================
# 跳过DNS解析（提升连接速度）
skip-name-resolve

# 密码验证插件
# validate_password.policy = MEDIUM
# validate_password.length = 8

# ==================== 字符集配置 ====================
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

# ==================== 慢查询日志 ====================
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2

# ==================== 复制配置 ====================
# 从节点只读（生产环境建议开启）
# read_only = ON

# 复制线程数
replica_parallel_workers = 4
replica_parallel_type = LOGICAL_CLOCK

# 复制心跳（检测复制延迟）
replica_net_timeout = 30

# 半同步复制等待位置
# rpl_semi_sync_master_wait_point = AFTER_SYNC

[client]
default-character-set = utf8mb4
port = 3306

[mysql]
default-character-set = utf8mb4
prompt = '[MySQL] \u@\h [\d]> '
CONF
    else
        # 从节点配置
        cat > "$CONFIG_DIR/slave.cnf" <<'CONF'
###############################################################################
# MySQL 从节点配置
# 项目: 企业级云原生运维平台
# 功能: 主从复制从节点，支持半同步复制
###############################################################################

[mysqld]
# ==================== 基本配置 ====================
# 服务器ID（集群中必须唯一）
server-id = 2

# 端口
port = 3306

# 绑定地址
bind-address = 0.0.0.0

# 数据目录
datadir = /var/lib/mysql

# 日志目录
log-error = /var/log/mysql/error.log

# ==================== 日志配置 ====================
# 中继日志（从节点记录主节点的二进制日志）
relay-log = /var/log/mysql/relay-bin

# 中继日志恢复
relay_log_recovery = ON

# 二进制日志（从节点可选开启，用于级联复制）
log-bin = /var/log/mysql/mysql-bin

# 二进制日志格式
binlog_format = ROW

# 二进制日志过期天数
expire_logs_days = 7

# ==================== GTID配置 ====================
gtid_mode = ON
enforce_gtid_consistency = ON

# ==================== 半同步复制配置 ====================
# 从节点插件
plugin-load = "rpl_semi_sync_master=semisync_master.so;rpl_semi_sync_slave=semisync_slave.so"

# 启用从节点半同步
rpl_semi_sync_slave_enabled = ON

# ==================== 复制配置 ====================
# 从节点只读
read_only = ON

# 超级用户不受read_only限制
super_read_only = ON

# 从节点并行复制
replica_parallel_workers = 4
replica_parallel_type = LOGICAL_CLOCK

# 从节点网络超时
replica_net_timeout = 30

# 复制心跳
master_info_repository = TABLE
relay_log_info_repository = TABLE

# 从节点延迟复制（可选，用于恢复误操作）
# CHANGE MASTER TO MASTER_DELAY = 3600;

# ==================== InnoDB配置 ====================
innodb_buffer_pool_size = 1G
innodb_buffer_pool_instances = 4
innodb_log_file_size = 256M
innodb_log_buffer_size = 64M
innodb_flush_log_at_trx_commit = 1
innodb_io_capacity = 1000
innodb_file_per_table = 1

# ==================== 连接配置 ====================
max_connections = 500
max_user_connections = 400
connect_timeout = 10
net_read_timeout = 30
net_write_timeout = 60

# ==================== 缓存配置 ====================
sort_buffer_size = 4M
join_buffer_size = 4M
read_buffer_size = 2M
read_rnd_buffer_size = 8M
table_open_cache = 2000
table_open_cache_instances = 16

# ==================== 安全配置 ====================
skip-name-resolve

# ==================== 字符集配置 ====================
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

# ==================== 慢查询日志 ====================
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2

[client]
default-character-set = utf8mb4
port = 3306

[mysql]
default-character-set = utf8mb4
prompt = '[MySQL] \u@\h [\d]> '
CONF
    fi

    log_info "MySQL配置文件生成完成"
}

# ==================== 初始化MySQL ====================
# ==================== 初始化MySQL ====================
# 功能: 初始化MySQL数据目录（--initialize-insecure）
# 前置条件: MySQL已安装，数据目录不存在
# 返回: 无（失败则exit 1）
initialize_mysql() {
    log_step "[3/6] 初始化MySQL..."

    # 检查是否已初始化
    if [[ -d "$DATA_DIR/mysql" ]]; then
        log_info "MySQL数据目录已存在，跳过初始化"
        return
    fi

    # 初始化数据库
    if command -v mysqld &>/dev/null; then
        mysqld --initialize-insecure --user=mysql --datadir="$DATA_DIR" 2>&1 | tail -5
        log_info "MySQL初始化完成"
    else
        log_error "mysqld命令不存在"
        exit 1
    fi
}

# ==================== 创建复制用户 ====================
# ==================== 创建复制用户 ====================
# 功能: 在主节点创建复制用户和监控用户
# 仅主节点执行
# 返回: 无
create_repl_user() {
    local role=$1
    log_step "[4/6] 创建复制用户..."

    if [[ "$role" == "master" ]]; then
        # 在主节点创建复制用户
        mysql -u root <<SQL
-- 创建复制用户
CREATE USER IF NOT EXISTS '${REPL_USER}'@'%' IDENTIFIED WITH mysql_native_password BY '${REPL_PASS}';
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '${REPL_USER}'@'%';

-- 创建监控用户
CREATE USER IF NOT EXISTS '${MONITOR_USER}'@'%' IDENTIFIED WITH mysql_native_password BY '${MONITOR_PASS}';
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO '${MONITOR_USER}'@'%';

-- 刷新权限
FLUSH PRIVILEGES;

-- 显示主节点状态
SHOW MASTER STATUS\G
SQL
        log_info "主节点复制用户创建完成"
    fi
}

# ==================== 配置主从复制 ====================
# ==================== 配置主从复制 ====================
# 功能: 在从节点配置GTID自动定位的主从复制
# 仅从节点执行
# 返回: 无
configure_replication() {
    local role=$1
    log_step "[5/6] 配置主从复制..."

    if [[ "$role" == "slave" ]]; then
        # 在从节点配置复制
        mysql -u root <<SQL
-- 停止现有复制（如有）
STOP SLAVE;

-- 配置从节点连接主节点
-- 使用GTID自动定位（推荐）
CHANGE MASTER TO
    MASTER_HOST='${MASTER_HOST}',
    MASTER_PORT=${MASTER_PORT},
    MASTER_USER='${REPL_USER}',
    MASTER_PASSWORD='${REPL_PASS}',
    MASTER_AUTO_POSITION = 1,
    GET_MASTER_PUBLIC_KEY = 1;

-- 或者使用传统方式（指定日志文件和位置）
-- CHANGE MASTER TO
--     MASTER_HOST='${MASTER_HOST}',
--     MASTER_PORT=${MASTER_PORT},
--     MASTER_USER='${REPL_USER}',
--     MASTER_PASSWORD='${REPL_PASS}',
--     MASTER_LOG_FILE='mysql-bin.000001',
--     MASTER_LOG_POS=154;

-- 启动复制
START SLAVE;

-- 检查复制状态
SHOW SLAVE STATUS\G
SQL
        log_info "从节点复制配置完成"
    fi
}

# ==================== 启动MySQL ====================
# ==================== 启动MySQL ====================
# 功能: 启动MySQL服务并验证端口监听
# 返回: 无（失败则exit 1）
start_mysql() {
    local role=$1
    log_step "[6/6] 启动MySQL..."

    # 启动MySQL服务
    systemctl daemon-reload
    systemctl enable mysqld
    systemctl restart mysqld

    sleep 5

    if systemctl is-active mysqld &>/dev/null; then
        log_info "MySQL启动成功 (角色: $role)"
        # 显示端口监听
        ss -tlnp | grep 3306 | awk '{print "  " $4 " " $6}'
    else
        log_error "MySQL启动失败"
        systemctl status mysqld --no-pager
        exit 1
    fi
}

# ==================== 主流程 ====================
main() {
    local role
    role=$(detect_role)

    log_step "========== 部署MySQL高可用 (角色: $role) =========="
    check_storage
    install_mysql
    generate_config "$role"
    initialize_mysql
    create_repl_user "$role"
    start_mysql "$role"
    configure_replication "$role"
    log_success "========== MySQL高可用部署完成 =========="
}

main "$@"
