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

# ==================== 初始化 ====================
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
deploy_keepalived() {
    log_step "[2/7] 部署Keepalived (VIP漂移)..."
    bash "$SCRIPT_DIR/01-deploy-keepalived.sh" 2>&1 | tee -a "$LOG_DIR/keepalived_${TIMESTAMP}.log"
    log_success "Keepalived部署完成"
}

# ==================== 部署Nginx负载均衡 ====================
deploy_nginx_lb() {
    log_step "[3/7] 部署Nginx负载均衡..."
    bash "$SCRIPT_DIR/02-deploy-nginx-lb.sh" 2>&1 | tee -a "$LOG_DIR/nginx-lb_${TIMESTAMP}.log"
    log_success "Nginx负载均衡部署完成"
}

# ==================== 部署MySQL HA ====================
deploy_mysql_ha() {
    log_step "[4/7] 部署MySQL高可用 (主从复制)..."
    bash "$SCRIPT_DIR/03-deploy-mysql-ha.sh" 2>&1 | tee -a "$LOG_DIR/mysql-ha_${TIMESTAMP}.log"
    log_success "MySQL高可用部署完成"
}

# ==================== 部署Redis Sentinel ====================
deploy_redis_sentinel() {
    log_step "[5/7] 部署Redis Sentinel..."
    bash "$SCRIPT_DIR/04-deploy-redis-sentinel.sh" 2>&1 | tee -a "$LOG_DIR/redis-sentinel_${TIMESTAMP}.log"
    log_success "Redis Sentinel部署完成"
}

# ==================== 运行故障转移测试 ====================
run_failover_test() {
    log_step "[6/7] 运行故障转移测试..."
    bash "$SCRIPT_DIR/05-test-failover.sh" 2>&1 | tee -a "$LOG_DIR/failover-test_${TIMESTAMP}.log"
    log_success "故障转移测试完成"
}

# ==================== 生成部署报告 ====================
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

show_status() {
    log_step "检查各组件状态..."
    echo ""
    echo "  Keepalived状态:"
    systemctl is-active keepalived 2>/dev/null || echo "  未运行"
    echo ""
    echo "  Nginx状态:"
    systemctl is-active nginx 2>/dev/null || echo "  未运行"
    echo ""
    echo "  MySQL状态:"
    systemctl is-active mysqld 2>/dev/null || echo "  未运行"
    echo ""
    echo "  Redis状态:"
    systemctl is-active redis 2>/dev/null || echo "  未运行"
}

main "$@"
