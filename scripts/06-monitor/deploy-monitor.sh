#!/bin/bash
###############################################################################
# deploy-monitor.sh - 监控系统部署主脚本
# 功能: 一键部署监控系统，支持Prometheus、Grafana、Zabbix
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

# ==================== 全局变量 ====================
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="${PROJECT_ROOT}/logs/06-monitor"
mkdir -p "${LOG_DIR}"

# ==================== 用法说明 ====================
usage() {
    cat << EOF
用法: $(basename "$0") <action>

操作选项:
  deploy       部署完整监控系统（Prometheus + Grafana + Zabbix）（默认）
  prometheus   仅部署Prometheus监控
  grafana      仅部署Grafana可视化
  zabbix       仅部署Zabbix监控
  status       查看各组件运行状态
  help         显示此帮助信息

环境变量:
  SKIP_PROMETHEUS=true    跳过Prometheus部署
  SKIP_GRAFANA=true       跳过Grafana部署
  SKIP_ZABBIX=true        跳过Zabbix部署

示例:
  $(basename "$0") deploy        # 一键部署全部监控组件
  $(basename "$0") prometheus    # 仅部署Prometheus
  $(basename "$0") zabbix        # 仅部署Zabbix
  $(basename "$0") status        # 查看各组件运行状态
EOF
}

# ==================== 初始化 ====================
init() {
    log_info "========== 监控系统部署开始 =========="
    mkdir -p "$LOG_DIR"
    log_info "日志目录: $LOG_DIR"

    # 检查root权限
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        exit 1
    fi
}

# ==================== 环境检测 ====================
check_environment() {
    log_step "[1/4] 检查运行环境..."

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

    # 检查Docker
    if ! command -v docker &>/dev/null; then
        log_error "Docker未安装，请先安装Docker"
        exit 1
    fi
    log_success "Docker已安装"

    if ! systemctl is-active docker &>/dev/null; then
        log_warn "Docker服务未运行，正在启动..."
        systemctl start docker
        systemctl enable docker
    fi
    log_success "Docker服务运行正常"

    log_success "环境检查完成"
}

# ==================== 部署Prometheus ====================
deploy_prometheus() {
    if [[ "${SKIP_PROMETHEUS:-false}" == "true" ]]; then
        log_info "跳过Prometheus部署"
        return 0
    fi

    log_step "[2/4] 部署Prometheus监控..."
    if [[ -f "$SCRIPT_DIR/01-deploy-prometheus.sh" ]]; then
        bash "$SCRIPT_DIR/01-deploy-prometheus.sh" 2>&1 | tee -a "$LOG_DIR/prometheus_${TIMESTAMP}.log"
    else
        log_warn "Prometheus部署脚本不存在: 01-deploy-prometheus.sh"
        log_info "Prometheus将通过Kubernetes部署，请参考manifests/monitoring/"
    fi
    log_success "Prometheus部署完成"
}

# ==================== 部署Grafana ====================
deploy_grafana() {
    if [[ "${SKIP_GRAFANA:-false}" == "true" ]]; then
        log_info "跳过Grafana部署"
        return 0
    fi

    log_step "[3/4] 部署Grafana可视化..."
    if [[ -f "$SCRIPT_DIR/02-deploy-grafana.sh" ]]; then
        bash "$SCRIPT_DIR/02-deploy-grafana.sh" 2>&1 | tee -a "$LOG_DIR/grafana_${TIMESTAMP}.log"
    else
        log_warn "Grafana部署脚本不存在: 02-deploy-grafana.sh"
        log_info "Grafana将通过Kubernetes部署，请参考manifests/app/grafana-dashboard.yaml"
    fi
    log_success "Grafana部署完成"
}

# ==================== 部署Zabbix ====================
deploy_zabbix() {
    if [[ "${SKIP_ZABBIX:-false}" == "true" ]]; then
        log_info "跳过Zabbix部署"
        return 0
    fi

    log_step "[4/4] 部署Zabbix监控..."
    if [[ -f "$SCRIPT_DIR/01-deploy-zabbix.sh" ]]; then
        bash "$SCRIPT_DIR/01-deploy-zabbix.sh" deploy 2>&1 | tee -a "$LOG_DIR/zabbix_${TIMESTAMP}.log"
    else
        log_error "Zabbix部署脚本不存在: 01-deploy-zabbix.sh"
        exit 1
    fi
    log_success "Zabbix部署完成"
}

# ==================== 显示状态 ====================
show_status() {
    log_step "检查各组件状态..."
    echo ""

    echo "  Docker容器状态:"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | grep -E "prometheus|grafana|zabbix|nginx" || echo "  无监控容器运行"
    echo ""

    echo "  端口监听状态:"
    for port in 9090 3000 8080 10051; do
        if ss -tlnp | grep -q ":${port} " 2>/dev/null; then
            echo "    端口 $port: ✓ 监听中"
        else
            echo "    端口 $port: ✗ 未监听"
        fi
    done
    echo ""

    echo "  组件说明:"
    echo "    Prometheus: http://<ip>:9090 (Kubernetes内部部署)"
    echo "    Grafana:    http://<ip>:3000 (Kubernetes内部部署)"
    echo "    Zabbix:     http://<ip>:8080 (Docker部署)"
    echo ""
}

# ==================== 生成部署报告 ====================
generate_report() {
    log_step "生成部署报告..."
    local report_file="$LOG_DIR/monitor-deploy-report_${TIMESTAMP}.md"

    cat > "$report_file" << EOF
# 监控系统部署报告
- 部署时间: $(date '+%Y-%m-%d %H:%M:%S')
- 主机名: $(hostname)
- IP地址: $(hostname -I | awk '{print $1}')
- 操作系统: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2)

## 组件状态
| 组件 | 状态 | 端口 | 说明 |
|------|------|------|------|
| Prometheus | 待检查 | 9090 | 指标采集与存储 |
| Grafana | 待检查 | 3000 | 可视化仪表板 |
| Zabbix | 待检查 | 8080 | 物理机/VM监控 |
| Zabbix Server | 待检查 | 10051 | Zabbix服务端 |

## 默认凭据
- Zabbix Web: Admin / zabbix
- Grafana: admin / admin
EOF

    log_success "部署报告已生成: $report_file"
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
            deploy_prometheus
            deploy_grafana
            deploy_zabbix
            generate_report
            log_info "========== 监控系统部署完成 =========="
            ;;
        prometheus)
            init
            deploy_prometheus
            ;;
        grafana)
            init
            deploy_grafana
            ;;
        zabbix)
            init
            deploy_zabbix
            ;;
        status)
            show_status
            ;;
        *)
            echo "用法: $0 {deploy|prometheus|grafana|zabbix|status|help}"
            exit 1
            ;;
    esac
}

main "$@"
