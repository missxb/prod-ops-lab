#!/bin/bash
###############################################################################
# 高可用架构部署主脚本
# 项目: 企业级云原生运维平台
# 阶段: 08 - 高可用架构
# 功能: 一键部署完整高可用架构，包括Keepalived、Nginx LB、MySQL HA、Redis Sentinel
# 作者: DevOps Team
# 版本: 1.0.0
###############################################################################

set -euo pipefail

# 错误处理：脚本退出时清理临时文件
trap 'log_error "脚本异常退出 (行号: $LINENO)"' ERR

# ==================== 全局变量 ====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$SCRIPT_DIR/../../configs" && pwd)"
LOG_DIR="/var/log/enterprise-ha"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==================== 日志函数 ====================
log_info()    { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_step()    { echo -e "${CYAN}[STEP]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }

# ==================== 辅助函数 ====================
# 检查命令是否存在，不存在则报错退出
check_command() {
    local cmd="$1"
    local package="${2:-$1}"
    if ! command -v "$cmd" &>/dev/null; then
        log_error "命令 '$cmd' 未安装，请先安装 $package"
        exit 1
    fi
}

# 验证目录是否存在，不存在则创建
ensure_dir() {
    local dir="$1"
    mkdir -p "$dir" || { log_error "无法创建目录: $dir"; exit 1; }
}

# 验证服务是否正常运行
check_service() {
    local service="$1"
    if systemctl is-active "$service" &>/dev/null; then
        log_success "$service 服务运行正常"
        return 0
    else
        log_error "$service 服务未运行"
        return 1
    fi
}

# ==================== 用法说明 ====================
usage() {
    cat << EOF
用法: $(basename "$0") <action>

操作选项:
  deploy       部署完整高可用架构（默认）
  keepalived   仅部署Keepalived
  nginx        仅部署Nginx负载均衡
  mysql        仅部署MySQL高可用
  redis        仅部署Redis Sentinel
  test         仅运行故障转移测试
  status       查看各组件运行状态
  help         显示此帮助信息

示例:
  $(basename "$0") deploy        # 一键部署全部HA组件
  $(basename "$0") keepalived    # 仅部署Keepalived VIP漂移
  $(basename "$0") status       # 查看各组件运行状态

环境变量:
  VIP_ADDRESS      VIP地址（默认: 192.168.100.100）
  SKIP_FAILOVER_TEST=true  跳过故障转移测试
EOF
}

# ==================== 初始化 ====================
# ==================== 初始化 ====================
# 功能: 创建日志目录、检查权限和操作系统兼容性
# 参数: 无
# 返回: 无（失败则exit 1）
init() {
    log_step "========== 高可用架构部署开始 =========="
    mkdir -p "$LOG_DIR"
    log_info "日志目录: $LOG_DIR"
    log_info "配置目录: $CONFIG_DIR"

    # 检查root权限
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        exit 1
    fi

    # 检查操作系统
    if [[ ! -f /etc/redhat-release ]] && [[ ! -f /etc/debian_version ]]; then
        log_warn "未识别的操作系统，可能不兼容"
    fi
}

# ==================== 环境检测 ====================
# ==================== 环境检测 ====================
# 功能: 检查网络、磁盘、内存、端口等运行环境
# 参数: 无
# 返回: 无（不可用条件则exit 1）
check_environment() {
    log_step "[1/7] 检查运行环境..."

    # 检查网络连通性
    if ! ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        log_warn "外网连通性检查失败，部分功能可能受限"
    fi

    # 检查磁盘空间
    local free_space
    free_space=$(df -BG / | awk 'NR==2{print $4}' | tr -d 'G')
    if [[ $free_space -lt 5 ]]; then
        log_error "磁盘剩余空间不足5G，请清理后重试"
        exit 1
    fi
    log_success "磁盘空间检查通过 (可用: ${free_space}G)"

    # 检查内存
    local total_mem
    total_mem=$(free -m | awk '/Mem:/{print $2}')
    if [[ $total_mem -lt 1024 ]]; then
        log_warn "系统内存不足1G，性能可能受影响"
    fi
    log_success "内存检查通过 (总内存: ${total_mem}MB)"

    # 检查端口占用
    local ports=(80 443 3306 6379 26379)
    for port in "${ports[@]}"; do
        if ss -tlnp | grep -q ":${port} "; then
            log_warn "端口 ${port} 已被占用，请确认是否继续"
        fi
    done

    log_success "环境检查完成"
}

# ==================== 部署Keepalived ====================
# ==================== 部署Keepalived ====================
# 功能: 调用Keepalived部署脚本，实现VIP漂移
# 日志: 输出到 $LOG_DIR/keepalived_$TIMESTAMP.log
deploy_keepalived() {
    log_step "[2/7] 部署Keepalived (VIP漂移)..."
    bash "$SCRIPT_DIR/01-deploy-keepalived.sh" 2>&1 | tee -a "$LOG_DIR/keepalived_${TIMESTAMP}.log"
    log_success "Keepalived部署完成"
}

# ==================== 部署Nginx负载均衡 ====================
# ==================== 部署Nginx负载均衡 ====================
# 功能: 调用Nginx LB部署脚本，实现7层负载均衡
# 日志: 输出到 $LOG_DIR/nginx-lb_$TIMESTAMP.log
deploy_nginx_lb() {
    log_step "[3/7] 部署Nginx负载均衡..."
    bash "$SCRIPT_DIR/02-deploy-nginx-lb.sh" 2>&1 | tee -a "$LOG_DIR/nginx-lb_${TIMESTAMP}.log"
    log_success "Nginx负载均衡部署完成"
}

# ==================== 部署MySQL HA ====================
# ==================== 部署MySQL HA ====================
# 功能: 调用MySQL高可用部署脚本，实现主从复制
# 日志: 输出到 $LOG_DIR/mysql-ha_$TIMESTAMP.log
deploy_mysql_ha() {
    log_step "[4/7] 部署MySQL高可用 (主从复制)..."
    bash "$SCRIPT_DIR/03-deploy-mysql-ha.sh" 2>&1 | tee -a "$LOG_DIR/mysql-ha_${TIMESTAMP}.log"
    log_success "MySQL高可用部署完成"
}

# ==================== 部署Redis Sentinel ====================
# ==================== 部署Redis Sentinel ====================
# 功能: 调用Redis Sentinel部署脚本，实现自动故障转移
# 日志: 输出到 $LOG_DIR/redis-sentinel_$TIMESTAMP.log
deploy_redis_sentinel() {
    log_step "[5/7] 部署Redis Sentinel..."
    bash "$SCRIPT_DIR/04-deploy-redis-sentinel.sh" 2>&1 | tee -a "$LOG_DIR/redis-sentinel_${TIMESTAMP}.log"
    log_success "Redis Sentinel部署完成"
}

# ==================== 运行故障转移测试 ====================
# ==================== 运行故障转移测试 ====================
# 功能: 验证各组件故障转移能力
# 注意: 生产环境建议设置 SKIP_FAILOVER_TEST=true
run_failover_test() {
    log_step "[6/7] 运行故障转移测试..."
    bash "$SCRIPT_DIR/05-test-failover.sh" 2>&1 | tee -a "$LOG_DIR/failover-test_${TIMESTAMP}.log"
    log_success "故障转移测试完成"
}

# ==================== 生成部署报告 ====================
# ==================== 生成部署报告 ====================
# 功能: 生成Markdown格式的部署报告，包含组件状态和端口信息
# 报告路径: $LOG_DIR/ha-deploy-report_$TIMESTAMP.md
generate_report() {
    log_step "[7/7] 生成部署报告..."
    local report_file="$LOG_DIR/ha-deploy-report_${TIMESTAMP}.md"

    cat > "$report_file" <<EOF
# 高可用架构部署报告
- 部署时间: $(date '+%Y-%m-%d %H:%M:%S')
- 主机名: $(hostname)
- IP地址: $(hostname -I | awk '{print $1}')
- 操作系统: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2)

## 组件状态
| 组件 | 状态 | 说明 |
|------|------|------|
| Keepalived | 待检查 | VIP漂移，非抢占模式 |
| Nginx LB | 待检查 | 7层负载均衡，K8s API Server |
| MySQL HA | 待检查 | 主从复制，半同步 |
| Redis Sentinel | 待检查 | 3 Sentinel + 1 Master + 2 Slave |

## VIP地址
- Keepalived VIP: 192.168.100.100

## 端口清单
- Nginx LB: 80, 443
- MySQL: 3306
- Redis: 6379
- Redis Sentinel: 26379
EOF

    log_success "部署报告已生成: $report_file"
    echo ""
    log_step "========== 高可用架构部署完成 =========="
    echo ""
    echo "  组件部署状态:"
    echo "  ┌──────────────────┬────────────┐"
    echo "  │ Keepalived       │ ✓ 已部署   │"
    echo "  │ Nginx LB         │ ✓ 已部署   │"
    echo "  │ MySQL HA         │ ✓ 已部署   │"
    echo "  │ Redis Sentinel   │ ✓ 已部署   │"
    echo "  └──────────────────┴────────────┘"
    echo ""
    echo "  日志目录: $LOG_DIR"
    echo "  部署报告: $report_file"
    echo ""
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
            init
            check_environment
            deploy_keepalived
            deploy_nginx_lb
            deploy_mysql_ha
            deploy_redis_sentinel
            run_failover_test
            generate_report
            ;;
        keepalived)
            init
            deploy_keepalived
            ;;
        nginx)
            init
            deploy_nginx_lb
            ;;
        mysql)
            init
            deploy_mysql_ha
            ;;
        redis)
            init
            deploy_redis_sentinel
            ;;
        test)
            init
            run_failover_test
            ;;
        status)
            show_status
            ;;
        *)
            echo "用法: $0 {deploy|keepalived|nginx|mysql|redis|test|status}"
            exit 1
            ;;
    esac
}

# ==================== 显示状态 ====================
# 功能: 检查并显示所有HA组件的运行状态
# 输出: Keepalived、Nginx、MySQL、Redis状态
show_status() {
    log_step "检查各组件状态..."
    echo ""
    local status_output=""
    for svc in keepalived:Keepalived nginx:Nginx mysqld:MySQL redis:Redis redis-sentinel:"Redis Sentinel"; do
        IFS=':' read -r service name <<< "$svc"
        if systemctl is-active "$service" &>/dev/null; then
            echo "  ${name}: ✓ 运行中"
        else
            echo "  ${name}: ✗ 未运行"
        fi
    done
    echo ""
    # 显示端口监听状态
    echo "  端口监听状态:"
    for port in 80 443 3306 6379 26379; do
        if ss -tlnp | grep -q ":${port} "; then
            echo "    端口 $port: ✓ 监听中"
        else
            echo "    端口 $port: ✗ 未监听"
        fi
    done
}

main "$@"
