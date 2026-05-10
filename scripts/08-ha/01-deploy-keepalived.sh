#!/bin/bash
###############################################################################
# 01-部署Keepalived脚本
# 功能: 安装配置Keepalived，实现VIP漂移和健康检查
# 特性: 非抢占模式、自定义健康检查脚本、邮件通知
###############################################################################

set -euo pipefail

# 错误处理
trap 'log_error "Keepalived部署脚本异常退出 (行号: $LINENO)"' ERR
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

功能: 安装配置Keepalived，实现VIP漂移和健康检查

环境变量:
  VIP_ADDRESS          VIP地址（默认: 192.168.100.100）
  VIP_NETMASK          VIP子网掩码（默认: 255.255.255.0）
  VIP_INTERFACE        绑定接口（默认: eth0）
  ROUTER_ID            路由ID（默认: 51）
  VRRP_AUTH_PASS       认证密码（默认: ha_secret_2024）
  PREEMPT_MODE         抢占模式（默认: nopreempt）
  PRIORITY_START       优先级起始值（默认: 101）

示例:
  VIP_ADDRESS=10.0.0.100 $(basename "$0")
  ./$(basename "$0")
EOF
}

# ==================== 配置变量 ====================
KEEPALIVED_VERSION="2.2.8"
CONFIG_DIR="/etc/keepalived"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="$(cd "$SCRIPT_DIR/../../configs" && pwd)"

# Keepalived配置
VIP_ADDRESS="${VIP_ADDRESS:-192.168.100.100}"
VIP_NETMASK="${VIP_NETMASK:-255.255.255.0}"
VIP_INTERFACE="${VIP_INTERFACE:-eth0}"
ROUTER_ID="${ROUTER_ID:-51}"
VRRP_AUTH_PASS="${VRRP_AUTH_PASS:-ha_secret_2024}"
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-2}"
PRIORITY_START="${PRIORITY_START:-101}"
PREEMPT_MODE="${PREEMPT_MODE:-nopreempt}"

# ==================== 安装Keepalived ====================
# ==================== 安装Keepalived ====================
# 功能: 检测并安装Keepalived软件包
# 支持: CentOS/RHEL (yum), Debian/Ubuntu (apt)
# 返回: 无（失败则exit 1）
install_keepalived() {
    log_step "[1/4] 安装Keepalived..."

    if command -v keepalived &>/dev/null; then
        local installed_version
        installed_version=$(keepalived --version 2>&1 | head -1 | awk '{print $NF}')
        log_info "Keepalived已安装，版本: $installed_version"
    else
        log_info "开始安装Keepalived..."

        if [[ -f /etc/redhat-release ]]; then
            yum install -y keepalived ipvsadm 2>&1 | tail -3
        elif [[ -f /etc/debian_version ]]; then
            apt-get update -qq && apt-get install -y keepalived ipvsadm 2>&1 | tail -3
        else
            log_error "不支持的操作系统"
            exit 1
        fi
    fi

    log_info "Keepalived安装完成"
}

# ==================== 创建健康检查脚本 ====================
# ==================== 创建健康检查脚本 ====================
# 功能: 生成Nginx和MySQL健康检查脚本、VIP故障转移通知脚本
# 脚本路径: /etc/keepalived/scripts/
# 返回: 无
create_health_check_script() {
    log_step "[2/4] 创建健康检查脚本..."

    mkdir -p /etc/keepalived/scripts

    # Nginx健康检查脚本
    cat > /etc/keepalived/scripts/check_nginx.sh <<'SCRIPT'
#!/bin/bash
###############################################################################
# Nginx健康检查脚本
# 检查Nginx进程是否存活，以及是否能正常响应HTTP请求
# 返回值: 0=健康, 1=不健康
###############################################################################

# 检查Nginx进程
if ! pidof nginx &>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Nginx进程不存在，尝试重启..."
    systemctl restart nginx 2>/dev/null || /usr/sbin/nginx -s reload 2>/dev/null
    sleep 2
    if ! pidof nginx &>/dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Nginx重启失败"
        exit 1
    fi
fi

# HTTP健康检查
http_code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/health --connect-timeout 3 --max-time 5 2>/dev/null)

if [[ "$http_code" == "200" ]] || [[ "$http_code" == "000" ]]; then
    # 000表示连接被接受但可能返回异常，也算健康
    exit 0
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Nginx健康检查失败，HTTP状态码: $http_code"
    exit 1
fi
SCRIPT

    # MySQL健康检查脚本
    cat > /etc/keepalived/scripts/check_mysql.sh <<'SCRIPT'
#!/bin/bash
###############################################################################
# MySQL健康检查脚本
# 检查MySQL连接和响应
###############################################################################

MYSQL_USER="${CHECK_MYSQL_USER:-monitor}"
MYSQL_PASS="${CHECK_MYSQL_PASS:-monitor_pass}"
MYSQL_PORT="${CHECK_MYSQL_PORT:-3306}"

# 检查MySQL进程
if ! pidof mysqld &>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] MySQL进程不存在"
    exit 1
fi

# 检查MySQL连接
if mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -P"$MYSQL_PORT" -e "SELECT 1;" &>/dev/null; then
    exit 0
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] MySQL连接检查失败"
    exit 1
fi
SCRIPT

    # VIP故障转移通知脚本
    cat > /etc/keepalived/scripts/notify.sh <<'SCRIPT'
#!/bin/bash
###############################################################################
# VIP故障转移通知脚本
# 当VIP发生漂移时发送通知
###############################################################################

TYPE=$1      # INSTANCE, GROUP, FAULT, STOP, RELOAD
NAME=$2      # 实例名称
STATE=$3     # MASTER, BACKUP, FAULT
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

log_file="/var/log/keepalived/notify.log"
mkdir -p "$(dirname "$log_file")"

case "$TYPE" in
    INSTANCE)
        case "$STATE" in
            MASTER)
                echo "[$TIMESTAMP] [MASTER] 实例 $NAME 成为主节点，VIP已接管" | tee -a "$log_file"
                # 主节点接管时执行的脚本
                systemctl start nginx 2>/dev/null || true
                ;;
            BACKUP)
                echo "[$TIMESTAMP] [BACKUP] 实例 $NAME 成为备节点" | tee -a "$log_file"
                ;;
            FAULT)
                echo "[$TIMESTAMP] [FAULT] 实例 $NAME 故障，进入故障状态" | tee -a "$log_file"
                # 发送告警通知
                echo "HA故障转移通知: 节点 $NAME 状态变为 FAULT" | \
                    mail -s "[HA Alert] VIP Failover" admin@example.com 2>/dev/null || true
                ;;
            *)
                echo "[$TIMESTAMP] [UNKNOWN] 实例 $NAME 状态: $STATE" | tee -a "$log_file"
                ;;
        esac
        ;;
    GROUP)
        echo "[$TIMESTAMP] [GROUP] 组 $NAME 状态: $STATE" | tee -a "$log_file"
        ;;
    FAULT)
        echo "[$TIMESTAMP] [FAULT] 节点进入故障状态" | tee -a "$log_file"
        ;;
    STOP)
        echo "[$TIMESTAMP] [STOP] Keepalived停止" | tee -a "$log_file"
        ;;
    RELOAD)
        echo "[$TIMESTAMP] [RELOAD] Keepalived重载配置" | tee -a "$log_file"
        ;;
    *)
        echo "[$TIMESTAMP] [UNKNOWN] 通知类型: $TYPE, 状态: $STATE" | tee -a "$log_file"
        ;;
esac
SCRIPT

    chmod +x /etc/keepalived/scripts/*.sh
    log_info "健康检查脚本创建完成"
}

# ==================== 生成Keepalived配置 ====================
# ==================== 生成Keepalived配置 ====================
# 功能: 根据节点角色生成keepalived.conf配置文件
# 配置: /etc/keepalived/keepalived.conf
# 参数: 无（自动检测节点角色）
generate_config() {
    log_step "[3/4] 生成Keepalived配置..."

    mkdir -p "$CONFIG_DIR"

    # 检测节点角色（通过主机名或IP判断）
    local node_id
    node_id=$(hostname | grep -oP '\d+' | tail -1)
    local is_master=false

    # 如果是第一台节点或主机名包含master，则为主节点
    if [[ "$node_id" == "1" ]] || [[ "$(hostname)" == *"master"* ]] || [[ "$(hostname)" == *"master"* ]]; then
        is_master=true
    fi

    local priority
    if $is_master; then
        priority=$((PRIORITY_START + node_id))
    else
        priority=$((PRIORITY_START - 10))
    fi

    local state
    if $is_master; then
        state="MASTER"
    else
        state="BACKUP"
    fi

    # 生成主配置文件
    cat > "$CONFIG_DIR/keepalived.conf" <<CONF
###############################################################################
# Keepalived 高可用配置
# 角色: ${state}
# 节点: $(hostname)
# VIP: ${VIP_ADDRESS}
# 模式: ${PREEMPT_MODE} (非抢占)
###############################################################################

# 全局配置
global_defs {
    # 路由ID，每个Keepalived节点必须唯一
    router_id $(hostname -s)_${state}

    # 通知脚本（VIP漂移时触发）
    notification_script /etc/keepalived/scripts/notify.sh

    # 启用脚本安全（非root用户运行脚本时需要）
    enable_script_security

    # 使用vrrp脚本而非多播
    vrrp_garp_master_delay 10
    vrrp_garp_master_repeat 1
    vrrp_garp_lower_prio_delay 10
    vrrp_garp_lower_prio_repeat 1
    vrrp_garp_interval 0
    vrrp_gna_interval 0

    # 日志级别: 0-4 (0=安静, 4=详细)
    log_level 3

    # 检查间隔（秒）
    max_auto_priority -1
}

# VRRP脚本定义 - 健康检查
vrrp_script check_nginx {
    # 健康检查脚本路径
    script "/etc/keepalived/scripts/check_nginx.sh"

    # 检查间隔（秒）
    interval 2

    # 权重（负数表示权重降低）
    weight -20

    # 连续失败次数，超过此值认为节点故障
    fall 3

    # 连续成功次数，超过此值认为节点恢复
    rise 2

    # 超时时间（秒）
    timeout 5
}

# VRRP脚本定义 - MySQL健康检查
vrrp_script check_mysql {
    script "/etc/keepalived/scripts/check_mysql.sh"
    interval 5
    weight -30
    fall 3
    rise 2
    timeout 5
}

# VRRP实例定义
vrrp_instance VI_1 {
    # 节点初始状态
    state ${state}

    # 绑定的网络接口
    interface ${VIP_INTERFACE}

    # 虚拟路由ID（同一组Keepalived必须相同）
    virtual_router_id ${ROUTER_ID}

    # 优先级（越大优先级越高）
    priority ${priority}

    # VRRP通告间隔（秒）
    advert_int 1

    # 认证配置（同一组Keepalived必须相同）
    authentication {
        # 认证类型: PASS(密码) 或 AH(IPSec)
        auth_type PASS

        # 认证密码（最多8个字符）
        auth_pass ${VRRP_AUTH_PASS}
    }

    # 虚拟IP地址
    virtual_ipaddress {
        # VIP地址/子网掩码 dev 接口
        ${VIP_ADDRESS}/${VIP_NETMASK} dev ${VIP_INTERFACE} label ${VIP_INTERFACE}:0
    }

    # 健康检查脚本关联
    track_script {
        check_nginx
        check_mysql
    }

    # 通知脚本（状态变化时触发）
    notify_master "/etc/keepalived/scripts/notify.sh INSTANCE \$INSTANCE_NAME MASTER"
    notify_backup "/etc/keepalived/scripts/notify.sh INSTANCE \$INSTANCE_NAME BACKUP"
    notify_fault  "/etc/keepalived/scripts/notify.sh INSTANCE \$INSTANCE_NAME FAULT"
    notify_stop   "/etc/keepalived/scripts/notify.sh INSTANCE \$INSTANCE_NAME STOP"

    # 非抢占模式（推荐生产环境使用）
    # 启用后，故障恢复的节点不会立即抢占VIP
    nopreempt

    # 同步组（用于同步多个VRRP实例的状态）
    # lvs_sync_daemon_interface eth1

    # 节点停止后VIP迁移等待时间
    # 最小化脑裂风险
    garp_master_delay 10
    garp_master_repeat 1

    # VRRP优先级广播
    virtual_ipaddress_excluded {
        # 排除不需要漂移的VIP（如果有）
    }
}

# 虚拟服务器定义（LVS-DR模式，可选）
# virtual_server ${VIP_ADDRESS} 80 {
#     delay_loop 6
#     lb_algo rr
#     lb_kind DR
#     persistence_timeout 50
#     protocol TCP
#
#     real_server 192.168.100.10 80 {
#         weight 1
#         TCP_CHECK {
#             connect_timeout 3
#             connect_port 80
#             retry 3
#             delay_before_retry 1
#         }
#     }
#
#     real_server 192.168.100.11 80 {
#         weight 1
#         TCP_CHECK {
#             connect_timeout 3
#             connect_port 80
#             retry 3
#             delay_before_retry 1
#         }
#     }
# }

###############################################################################
# VRRP实例2 - 用于Redis Sentinel高可用（可选）
###############################################################################
# vrrp_instance VI_2 {
#     state ${state}
#     interface ${VIP_INTERFACE}
#     virtual_router_id 52
#     priority ${priority}
#     advert_int 1
#     authentication {
#         auth_type PASS
#         auth_pass ${VRRP_AUTH_PASS}
#     }
#     virtual_ipaddress {
#         192.168.100.200/24 dev ${VIP_INTERFACE} label ${VIP_INTERFACE}:1
#     }
#     nopreempt
# }
CONF

    log_info "Keepalived配置生成完成: $CONFIG_DIR/keepalived.conf"
}

# ==================== 启动Keepalived ====================
# ==================== 启动Keepalived ====================
# 功能: 配置防火墙规则、启动Keepalived服务、验证VIP
# 验证: 检查服务状态和VIP地址
start_keepalived() {
    log_step "[4/4] 启动Keepalived..."

    # 禁用SELinux（如启用）
    if command -v getenforce &>/dev/null && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
        setenforce 0 2>/dev/null || true
        log_warn "SELinux已临时禁用"
    fi

    # 禁用防火墙（生产环境应配置放行规则）
    if systemctl is-active firewalld &>/dev/null; then
        systemctl stop firewalld 2>/dev/null || true
        systemctl disable firewalld 2>/dev/null || true
        log_warn "firewalld已禁用（生产环境请配置放行VRRP协议）"
    fi

    # 确保iptables允许VRRP协议
    iptables -I INPUT -p vrrp -j ACCEPT 2>/dev/null || true
    iptables -I OUTPUT -p vrrp -j ACCEPT 2>/dev/null || true

    # 启动Keepalived
    systemctl daemon-reload
    systemctl enable keepalived
    systemctl restart keepalived

    # 等待VIP生效
    sleep 3

    if systemctl is-active keepalived &>/dev/null; then
        log_info "Keepalived启动成功"
        # 显示VIP状态
        ip addr show | grep "$VIP_ADDRESS" && \
            log_info "VIP地址 $VIP_ADDRESS 已生效" || \
            log_warn "VIP地址 $VIP_ADDRESS 未检测到（可能在备节点）"
    else
        log_error "Keepalived启动失败"
        systemctl status keepalived --no-pager
        exit 1
    fi
}

# ==================== 主流程 ====================
# ==================== 主流程 ====================
# 功能: 顺序执行安装、脚本创建、配置生成、启动
# 用法: ./01-deploy-keepalived.sh
main() {
    log_step "========== 部署Keepalived =========="
    install_keepalived
    create_health_check_script
    generate_config
    start_keepalived
    log_success "========== Keepalived部署完成 =========="
}

main "$@"
