#!/bin/bash
###############################################################################
# 04-部署Redis Sentinel脚本
# 功能: 部署Redis主从复制和Sentinel高可用架构
# 架构: 3 Sentinel + 1 Master + 2 Slave
###############################################################################

set -euo pipefail

# 错误处理
trap 'log_error "Redis Sentinel部署脚本异常退出 (行号: $LINENO)"' ERR

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

功能: 部署Redis主从复制和Sentinel高可用架构
架构: 3 Sentinel + 1 Master + 2 Slave

环境变量:
  MASTER_HOST          主节点IP（默认: 192.168.100.10）
  SLAVE_HOSTS          从节点IP列表（逗号分隔）
  SENTINEL_HOSTS       Sentinel节点IP列表（逗号分隔）
  REDIS_PASS           Redis密码（默认: redis_pass_2024）
  SENTINEL_PORT        Sentinel端口（默认: 26379）

示例:
  MASTER_HOST=10.0.0.1 $(basename "$0")
EOF
}

# ==================== 配置变量 ====================
REDIS_VERSION="${REDIS_VERSION:-7.0}"
REDIS_DIR="/var/lib/redis"
REDIS_LOG_DIR="/var/log/redis"
REDIS_CONFIG_DIR="/etc/redis"

# Sentinel配置
SENTINEL_PORT="${SENTINEL_PORT:-26379}"
SENTINEL_DOWN_AFTER="${SENTINEL_DOWN_AFTER:-5000}"
SENTINEL_FAILOVER_TIMEOUT="${SENTINEL_FAILOVER_TIMEOUT:-60000}"
SENTINEL_PARALLEL_SYNC="${SENTINEL_PARALLEL_SYNC:-1}"

# Redis集群配置
MASTER_HOST="${MASTER_HOST:-192.168.100.10}"
MASTER_PORT="${MASTER_PORT:-6379}"
SLAVE_HOSTS="${SLAVE_HOSTS:-192.168.100.11,192.168.100.12}"
SENTINEL_HOSTS="${SENTINEL_HOSTS:-192.168.100.10,192.168.100.11,192.168.100.12}"
REDIS_PASS="${REDIS_PASS:-redis_pass_2024}"
REDIS_SENTINEL_PASS="${REDIS_SENTINEL_PASS:-sentinel_pass_2024}"

# ==================== 安装Redis ====================
# ==================== 安装Redis ====================
# 功能: 检测并安装Redis服务器
# 支持: CentOS/RHEL (yum), Debian/Ubuntu (apt)
install_redis() {
    log_step "[1/6] 安装Redis..."

    if command -v redis-server &>/dev/null; then
        local installed_version
        installed_version=$(redis-server --version 2>&1 | awk '{print $3}' | cut -d'=' -f2)
        log_info "Redis已安装，版本: $installed_version"
        return
    fi

    log_info "开始安装Redis..."

    if [[ -f /etc/redhat-release ]]; then
        # 安装EPEL仓库
        yum install -y epel-release 2>/dev/null || true
        yum install -y redis 2>&1 | tail -3
    elif [[ -f /etc/debian_version ]]; then
        apt-get update -qq
        apt-get install -y redis-server redis-tools 2>&1 | tail -3
    fi

    log_info "Redis安装完成"
}

# ==================== 创建目录 ====================
# ==================== 创建目录 ====================
# 功能: 创建Redis数据、日志、配置目录结构
# 目录: /var/lib/redis, /var/log/redis, /etc/redis, /etc/redis/sentinel
create_directories() {
    log_step "[2/6] 创建目录结构..."

    local dirs=(
        "$REDIS_DIR"
        "$REDIS_LOG_DIR"
        "$REDIS_CONFIG_DIR"
        "$REDIS_CONFIG_DIR/sentinel"
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
    done

    chown -R redis:redis "$REDIS_DIR" "$REDIS_LOG_DIR" 2>/dev/null || true

    log_info "目录结构创建完成"
}

# ==================== 生成Redis主节点配置 ====================
# ==================== 生成Redis主节点配置 ====================
# 功能: 生成redis-master.conf，包含网络、认证、持久化、复制等配置
# 配置路径: /etc/redis/redis-master.conf
generate_master_config() {
    log_step "[3/6] 生成Redis主节点配置..."

    cat > "$REDIS_CONFIG_DIR/redis-master.conf" <<'CONF'
###############################################################################
# Redis 主节点配置
# 项目: 企业级云原生运维平台
# 功能: Redis主节点，支持主从复制和持久化
###############################################################################

# ==================== 网络配置 ====================
# 绑定地址（允许远程连接）
bind 0.0.0.0

# 端口
port 6379

# 保护模式（禁用以便远程连接）
protected-mode no

# TCP backlog（连接队列大小）
tcp-backlog 511

# 客户端空闲超时（秒，0=不超时）
timeout 0

# TCP keepalive间隔（秒）
tcp-keepalive 300

# ==================== 认证配置 ====================
# 访问密码（生产环境必须设置）
requirepass redis_pass_2024

# 主节点复制密码
masterauth redis_pass_2024

# ==================== 通用配置 ====================
# 后台运行
daemonize yes

# PID文件
pidfile /var/run/redis/redis-server.pid

# 日志级别: debug, verbose, notice, warning
loglevel notice

# 日志文件
logfile /var/log/redis/redis-server.log

# 数据库数量
databases 16

# 数据目录
dir /var/lib/redis

# ==================== 内存管理 ====================
# 最大内存（建议为物理内存的70-80%）
maxmemory 2gb

# 内存淘汰策略
# noeviction: 不淘汰，写入报错（默认）
# allkeys-lru: 所有key中淘汰最近最少使用的
# volatile-lru: 有过期时间的key中淘汰最近最少使用的
# allkeys-lfu: 所有key中淘汰使用频率最低的
# volatile-lfu: 有过期时间的key中淘汰使用频率最低的
# allkeys-random: 所有key中随机淘汰
# volatile-random: 有过期时间的key中随机淘汰
# volatile-ttl: 淘汰最早过期的key
maxmemory-policy allkeys-lru

# ==================== 持久化 - RDB ====================
# RDB快照配置
# 格式: save <秒数> <修改数>
# 在以下时间点进行RDB持久化
save 900 1      # 900秒内至少1次修改
save 300 10     # 300秒内至少10次修改
save 60 10000   # 60秒内至少10000次修改

# RDB文件名
dbfilename dump.rdb

# RDB压缩
rdbcompression yes

# RDB校验
rdbchecksum yes

# ==================== 持久化 - AOF ====================
# AOF（Append Only File）配置
appendonly yes

# AOF文件名
appendfilename "appendonly.aof"

# AOF同步策略
# always: 每次写操作都同步（最安全，性能最低）
# everysec: 每秒同步一次（推荐，最多丢1秒数据）
# no: 由OS决定（最快，可能丢数据）
appendfsync everysec

# AOF重写时不进行fsync
no-appendfsync-on-rewrite no

# AOF重写条件
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb

# 加载损坏的AOF文件
aof-load-truncated yes

# AOF RDB预加载
aof-use-rdb-preamble yes

# ==================== 慢查询日志 ====================
# 慢查询阈值（微秒）
slowlog-log-slower-than 10000

# 慢查询日志最大长度
slowlog-max-len 128

# ==================== 复制配置 ====================
# 从节点优先级（越小优先级越高，0表示永远不升主）
replica-priority 10

# 从节点只读
replica-read-only yes

# 无盘复制（主节点直接传输RDB给从节点，不写本地磁盘）
repl-diskless-sync yes
repl-diskless-sync-delay 5

# 复制积压缓冲区大小
repl-backlog-size 256mb

# 复制积压缓冲区释放时间
repl-backlog-ttl 3600

# 最小从节点连接数（低于此数不进行无盘同步）
min-replicas-to-write 1
min-replicas-max-lag 10

# ==================== 安全配置 ====================
# 禁用危险命令
rename-command FLUSHALL ""
rename-command FLUSHDB ""
# rename-command CONFIG ""  # 如需远程配置则不禁用

# ==================== 客户端配置 ====================
# 最大客户端连接数
maxclients 10000

# ==================== 集群配置（可选）====================
# cluster-enabled yes
# cluster-config-file nodes-6379.conf
# cluster-node-timeout 15000

# ==================== 延迟监控 ====================
# 延迟监控阈值（微秒）
latency-tracking-info-percentiles 50 99 99.9
CONF

    # 替换密码占位符
    sed -i "s/redis_pass_2024/${REDIS_PASS}/g" "$REDIS_CONFIG_DIR/redis-master.conf"

    log_info "Redis主节点配置生成完成"
}

# ==================== 生成Redis从节点配置 ====================
# ==================== 生成Redis从节点配置 ====================
# 功能: 生成指定从节点的配置文件
# 参数: $1=slave_id, $2=slave_host
# 配置路径: /etc/redis/redis-slave-{id}.conf
generate_slave_config() {
    local slave_id=$1
    local slave_host=$2
    log_step "[3/6] 生成Redis从节点配置 (节点: $slave_host)..."

    cat > "$REDIS_CONFIG_DIR/redis-slave-${slave_id}.conf" <<CONF
###############################################################################
# Redis 从节点配置
# 节点: ${slave_host}
# 功能: 从节点，自动同步主节点数据
###############################################################################

# ==================== 网络配置 ====================
bind 0.0.0.0
port 6379
protected-mode no
tcp-backlog 511
timeout 0
tcp-keepalive 300

# ==================== 认证配置 ====================
requirepass ${REDIS_PASS}
masterauth ${REDIS_PASS}

# ==================== 通用配置 ====================
daemonize yes
pidfile /var/run/redis/redis-slave-${slave_id}.pid
loglevel notice
logfile /var/log/redis/redis-slave-${slave_id}.log
databases 16
dir /var/lib/redis/slave-${slave_id}

# ==================== 内存管理 ====================
maxmemory 2gb
maxmemory-policy allkeys-lru

# ==================== 持久化 - RDB ====================
save 900 1
save 300 10
save 60 10000
dbfilename dump-slave-${slave_id}.rdb
rdbcompression yes
rdbchecksum yes

# ==================== 持久化 - AOF ====================
appendonly yes
appendfilename "appendonly-slave-${slave_id}.aof"
appendfsync everysec

# ==================== 复制配置 ====================
# 从节点只读
replica-read-only yes

# 主节点配置（使用sentinel管理时不需要手动指定）
# replicaof ${MASTER_HOST} ${MASTER_PORT}

# 无盘复制
repl-diskless-sync yes

# 复制积压缓冲区
repl-backlog-size 256mb

# ==================== 延迟监控 ====================
latency-tracking-info-percentiles 50 99 99.9
CONF

    # 创建从节点数据目录
    mkdir -p "$REDIS_DIR/slave-${slave_id}"
    chown -R redis:redis "$REDIS_DIR/slave-${slave_id}" 2>/dev/null || true

    log_info "Redis从节点配置生成完成: $slave_host"
}

# ==================== 生成Sentinel配置 ====================
# ==================== 生成Sentinel配置 ====================
# 功能: 生成指定Sentinel节点的配置文件
# 参数: $1=sentinel_id, $2=sentinel_host
# 配置路径: /etc/redis/sentinel/sentinel-{id}.conf
generate_sentinel_config() {
    local sentinel_id=$1
    local sentinel_host=$2
    log_step "[4/6] 生成Sentinel配置 (节点: $sentinel_host)..."

    cat > "$REDIS_CONFIG_DIR/sentinel/sentinel-${sentinel_id}.conf" <<CONF
###############################################################################
# Redis Sentinel 配置
# 节点: ${sentinel_host}
# 功能: 监控Redis主从节点，自动故障转移
# 架构: 3 Sentinel + 1 Master + 2 Slave
###############################################################################

# ==================== 基本配置 ====================
# Sentinel端口
port ${SENTINEL_PORT}

# Sentinel运行模式
daemonize yes

# PID文件
pidfile /var/run/redis/sentinel-${sentinel_id}.pid

# 日志文件
logfile /var/log/redis/sentinel-${sentinel_id}.log

# 日志级别
loglevel notice

# 工作目录
dir /var/lib/redis/sentinel-${sentinel_id}

# ==================== 监控配置 ====================
# 监控的主节点
# sentinel monitor <master-name> <ip> <port> <quorum>
# quorum: 需要多少个Sentinel同意才能判断主节点故障
# 3个Sentinel建议quorum=2
sentinel monitor mymaster ${MASTER_HOST} ${MASTER_PORT} 2

# 主节点密码
sentinel auth-pass mymaster ${REDIS_PASS}

# Sentinel认证密码
requirepass ${REDIS_SENTINEL_PASS}

# ==================== 故障检测配置 ====================
# 多长时间无响应认为主观下线（毫秒）
sentinel down-after-milliseconds mymaster ${SENTINEL_DOWN_AFTER}

# 故障转移超时时间（毫秒）
sentinel failover-timeout mymaster ${SENTINEL_FAILOVER_TIMEOUT}

# 并行同步从节点数量
sentinel parallel-syncs mymaster ${SENTINEL_PARALLEL_SYNC}

# ==================== 通知脚本（可选）====================
# 故障转移完成后执行的脚本
# sentinel notification-script mymaster /var/lib/redis/notify.sh

# 客户端重配置脚本
# sentinel client-reconfig-script mymaster /var/lib/redis/reconfig.sh

# ==================== 通知配置 ====================
# 通知邮件（可选）
# sentinel notification-script mymaster /etc/redis/sentinel-notify.sh

# ==================== 运行时配置（由Sentinel自动管理）====================
# 以下配置由Sentinel在运行时自动修改
# sentinel myid <sentinel-id>
# sentinel config-epoch mymaster 0
# sentinel leader-epoch mymaster 0
# sentinel current-epoch mymaster 0
CONF

    # 创建Sentinel数据目录
    mkdir -p "$REDIS_DIR/sentinel-${sentinel_id}"
    chown -R redis:redis "$REDIS_DIR/sentinel-${sentinel_id}" 2>/dev/null || true

    log_info "Sentinel配置生成完成: $sentinel_host"
}

# ==================== 生成Sentinel通知脚本 ====================
# ==================== 生成Sentinel脚本 ====================
# 功能: 生成故障转移通知脚本和Sentinel健康检查脚本
# 脚本路径: /var/lib/redis/notify.sh, /var/lib/redis/check_sentinel.sh
generate_sentinel_scripts() {
    log_step "[5/6] 生成Sentinel脚本..."

    # 故障转移通知脚本
    cat > /var/lib/redis/notify.sh <<'SCRIPT'
#!/bin/bash
###############################################################################
# Redis Sentinel 故障转移通知脚本
# 当Sentinel检测到故障并完成转移时触发
###############################################################################

MASTER_NAME=$1
ACTION=$2          # switch-master, sdown, rdown
MASTER_IP=$3
MASTER_PORT=$4
NEW_MASTER_IP=$5
NEW_MASTER_PORT=$6
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

LOG_FILE="/var/log/redis/sentinel-notify.log"

case "$ACTION" in
    switch-master)
        echo "[$TIMESTAMP] [FAILOVER] 主节点切换: ${MASTER_IP}:${MASTER_PORT} -> ${NEW_MASTER_IP}:${NEW_MASTER_PORT}" | tee -a "$LOG_FILE"
        # 发送告警通知
        echo "Redis HA故障转移: ${MASTER_NAME} 主节点已从 ${MASTER_IP}:${MASTER_PORT} 切换到 ${NEW_MASTER_IP}:${NEW_MASTER_PORT}" | \
            mail -s "[Redis HA] Failover Complete" admin@example.com 2>/dev/null || true
        ;;
    sdown)
        echo "[$TIMESTAMP] [SDOWN] 主观下线: ${MASTER_IP}:${MASTER_PORT}" | tee -a "$LOG_FILE"
        ;;
    rdown)
        echo "[$TIMESTAMP] [RDOWN] 客观下线: ${MASTER_IP}:${MASTER_PORT}" | tee -a "$LOG_FILE"
        ;;
    *)
        echo "[$TIMESTAMP] [UNKNOWN] 未知事件: ${ACTION} ${MASTER_IP}:${MASTER_PORT}" | tee -a "$LOG_FILE"
        ;;
esac
SCRIPT

    # Sentinel健康检查脚本
    cat > /var/lib/redis/check_sentinel.sh <<'SCRIPT'
#!/bin/bash
###############################################################################
# Redis Sentinel 健康检查脚本
###############################################################################

SENTINEL_HOST="${1:-127.0.0.1}"
SENTINEL_PORT="${2:-26379}"

# 检查Sentinel进程
if ! pidof redis-sentinel &>/dev/null; then
    echo "Sentinel进程未运行"
    exit 1
fi

# 检查Sentinel响应
response=$(redis-cli -p "$SENTINEL_PORT" -a "$REDIS_SENTINEL_PASS" ping 2>/dev/null)

if [[ "$response" == "PONG" ]]; then
    echo "Sentinel健康检查通过"
    # 显示主节点信息
    redis-cli -p "$SENTINEL_PORT" -a "$REDIS_SENTINEL_PASS" sentinel masters 2>/dev/null | head -20
    exit 0
else
    echo "Sentinel健康检查失败"
    exit 1
fi
SCRIPT

    chmod +x /var/lib/redis/*.sh
    log_info "Sentinel脚本生成完成"
}

# ==================== 启动Redis服务 ====================
# ==================== 启动Redis服务 ====================
# 功能: 启动Redis主节点和Sentinel服务
# 验证: 检查服务状态和端口监听
start_redis_services() {
    log_step "[6/6] 启动Redis服务..."

    # 启动Redis主节点
    log_info "启动Redis主节点..."
    systemctl enable redis
    systemctl restart redis
    sleep 2

    if systemctl is-active redis &>/dev/null; then
        log_info "Redis主节点启动成功"
    else
        log_error "Redis主节点启动失败"
        systemctl status redis --no-pager
    fi

    # 启动Sentinel
    log_info "启动Redis Sentinel..."
    systemctl enable redis-sentinel 2>/dev/null || true
    systemctl restart redis-sentinel 2>/dev/null || true
    sleep 2

    if systemctl is-active redis-sentinel &>/dev/null; then
        log_info "Redis Sentinel启动成功"
    else
        # 手动启动Sentinel（某些系统没有redis-sentinel服务）
        log_warn "尝试手动启动Sentinel..."
        redis-sentinel "$REDIS_CONFIG_DIR/sentinel/sentinel-1.conf" &
        sleep 2
    fi

    # 显示服务状态
    log_info "Redis服务状态:"
    ss -tlnp | grep -E "(6379|26379)" | awk '{print "  " $4 " " $6}'
}

# ==================== 主流程 ====================
main() {
    log_step "========== 部署Redis Sentinel高可用 =========="

    install_redis
    create_directories
    generate_master_config

    # 生成从节点配置
    IFS=',' read -ra SLAVE_HOST_ARRAY <<< "$SLAVE_HOSTS"
    local slave_id=1
    for slave_host in "${SLAVE_HOST_ARRAY[@]}"; do
        generate_slave_config "$slave_id" "$slave_host"
        ((slave_id++))
    done

    # 生成Sentinel配置
    IFS=',' read -ra SENTINEL_HOST_ARRAY <<< "$SENTINEL_HOSTS"
    local sentinel_id=1
    for sentinel_host in "${SENTINEL_HOST_ARRAY[@]}"; do
        generate_sentinel_config "$sentinel_id" "$sentinel_host"
        ((sentinel_id++))
    done

    generate_sentinel_scripts
    start_redis_services

    log_success "========== Redis Sentinel部署完成 =========="
    echo ""
    echo "  Redis集群架构:"
    echo "  ┌─────────────────────────────────────────┐"
    echo "  │           Sentinel监控层                │"
    echo "  │  ┌─────────┐ ┌─────────┐ ┌─────────┐  │"
    echo "  │  │Sentinel1│ │Sentinel2│ │Sentinel3│  │"
    echo "  │  │:26379   │ │:26379   │ │:26379   │  │"
    echo "  │  └────┬────┘ └────┬────┘ └────┬────┘  │"
    echo "  │       └───────────┼───────────┘        │"
    echo "  │                   ▼                    │"
    echo "  │           ┌───────────┐                │"
    echo "  │           │  Master   │                │"
    echo "  │           │  :6379    │                │"
    echo "  │           └─────┬─────┘                │"
    echo "  │          ┌──────┴──────┐               │"
    echo "  │     ┌────▼────┐   ┌────▼────┐          │"
    echo "  │     │ Slave 1 │   │ Slave 2 │          │"
    echo "  │     │ :6379   │   │ :6379   │          │"
    echo "  │     └─────────┘   └─────────┘          │"
    echo "  └─────────────────────────────────────────┘"
    echo ""
}

main "$@"
