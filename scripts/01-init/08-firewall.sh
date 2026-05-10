#!/bin/bash
###############################################################################
# 脚本名称: 08-firewall.sh
# 功能描述: 配置基础防火墙规则，开放集群必要端口
# 适用系统: CentOS 7/8, Rocky Linux 8/9
# 依赖条件: root权限
# 作者: 运维平台团队
# 版本: 1.1.0
# 创建日期: 2026-05-10
# 更新日期: 2026-05-10
#
# 使用方法:
#   ./08-firewall.sh                    # 使用默认规则配置
#   ./08-firewall.sh --skip-enable      # 只添加规则，不启用防火墙
#   ./08-firewall.sh --dry-run          # 干运行，显示将要执行的操作
#
# 功能说明:
#   1. 检测防火墙类型 (firewalld / iptables)
#   2. 开放SSH端口 (22)
#   3. 开放HTTP端口 (80)
#   4. 开放HTTPS端口 (443)
#   5. 开放K8s API端口 (6443)
#   6. 开放NodePort范围 (30000-32767)
#   7. 启用防火墙服务
#   8. 验证规则生效
#
# 端口规划:
#   - 22:    SSH远程管理
#   - 80:    HTTP服务 / Ingress入口
#   - 443:   HTTPS服务 / Ingress入口
#   - 6443:  Kubernetes API Server
#   - 2379-2380: etcd (仅master节点，本脚本不开放)
#   - 30000-32767: Kubernetes NodePort Service范围
###############################################################################
set -euo pipefail
umask 077

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/01-init"
LOG_FILE="${LOG_DIR}/08-firewall_$(date +%Y%m%d_%H%M%S).log"
LOCK_FILE="/var/lock/08-firewall.lock"

# 需要开放的端口列表
declare -A PORTS=(
    ["22"]="SSH远程管理"
    ["80"]="HTTP服务/Ingress"
    ["443"]="HTTPS服务/Ingress"
    ["6443"]="Kubernetes API Server"
)

# NodePort范围
NODEPORT_RANGE="30000-32767"

# 选项
SKIP_ENABLE=false
DRY_RUN=false

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
trap 'log_error "脚本执行出错，行号: ${LINENO}"' ERR
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
    else
        log_error "无法检测操作系统类型"
        exit 1
    fi
    log_info "检测到系统: ${OS_NAME}"
}

# ========================= 防火墙配置函数 =========================

# 检测防火墙类型
# 支持 firewalld (CentOS/RHEL) 和 iptables (通用回退方案)
detect_firewall() {
    if command -v firewall-cmd >/dev/null 2>&1; then
        FIREWALL_TYPE="firewalld"
        log_info "检测到防火墙类型: firewalld"
    elif command -v iptables >/dev/null 2>&1; then
        FIREWALL_TYPE="iptables"
        log_info "检测到防火墙类型: iptables (回退模式)"
    else
        FIREWALL_TYPE="none"
        log_warn "未检测到防火墙工具"
    fi
}

# firewalld 配置函数
# 在 public zone 中添加端口规则
configure_firewalld() {
    log_step "使用 firewalld 配置防火墙规则"

    # 确保 firewalld 运行中
    if ! systemctl is-active firewalld >/dev/null 2>&1; then
        log_info "启动 firewalld 服务..."
        systemctl start firewalld 2>/dev/null || true
        systemctl enable firewalld 2>/dev/null || true
    fi

    # 使用 public zone
    local zone="public"

    # 检查 zone 是否存在
    if ! firewall-cmd --get-zones 2>/dev/null | grep -q "^${zone}$"; then
        log_error "防火墙 zone '${zone}' 不存在"
        return 1
    fi

    # 添加单个端口规则
    for port in "${!PORTS[@]}"; do
        local desc="${PORTS[$port]}"
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[干运行] 将添加端口: ${port} (${desc})"
        else
            if firewall-cmd --zone="$zone" --query-port="${port}/tcp" >/dev/null 2>&1; then
                log_info "端口 ${port} 已开放 (${desc})，跳过"
            else
                firewall-cmd --zone="$zone" --add-port="${port}/tcp" --permanent >> "$LOG_FILE" 2>&1
                log_success "已添加端口规则: ${port}/tcp (${desc})"
            fi
        fi
    done

    # 添加 NodePort 范围
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[干运行] 将添加 NodePort 范围: ${NODEPORT_RANGE}/tcp"
    else
        if firewall-cmd --zone="$zone" --query-port="${NODEPORT_RANGE}/tcp" >/dev/null 2>&1; then
            log_info "NodePort 范围 ${NODEPORT_RANGE} 已开放，跳过"
        else
            firewall-cmd --zone="$zone" --add-port="${NODEPORT_RANGE}/tcp" --permanent >> "$LOG_FILE" 2>&1
            log_success "已添加 NodePort 范围: ${NODEPORT_RANGE}/tcp"
        fi
    fi

    # 重新加载防火墙配置
    if [[ "$DRY_RUN" != "true" ]]; then
        firewall-cmd --reload >> "$LOG_FILE" 2>&1
        log_success "firewalld 配置已重载"
    fi

    # 启用 firewalld 服务
    if [[ "$SKIP_ENABLE" != "true" ]]; then
        systemctl enable firewalld 2>>"$LOG_FILE"
        log_success "firewalld 服务已启用开机自启"
    fi
}

# iptables 配置函数 (回退方案)
# 当 firewalld 不可用时使用 iptables
configure_iptables() {
    log_step "使用 iptables 配置防火墙规则"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[干运行] 将添加 iptables 规则"
        log_info "[干运行] 添加 INPUT ACCEPT 规则用于: ${!PORTS[*]}, NodePort ${NODEPORT_RANGE}"
        return 0
    fi

    # 确保 iptables-services 已安装 (CentOS/RHEL)
    if ! command -v iptables >/dev/null 2>&1; then
        log_error "iptables 未安装"
        log_info "请运行: yum install -y iptables-services"
        return 1
    fi

    # 创建 iptables 启动脚本目录
    mkdir -p /etc/iptables

    # 生成 iptables 规则脚本
    cat > /etc/iptables/iptables-rules.sh << 'IPTABLES_EOF'
#!/bin/bash
# Enterprise Cloud Native Platform - iptables 规则
# 由 08-firewall.sh 自动生成

# 清除现有规则
iptables -F
iptables -X
iptables -Z

# 设置默认策略: 允许输入
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# 允许回环接口
iptables -A INPUT -i lo -j ACCEPT

# 允许已建立的连接
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# 允许 SSH
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# 允许 HTTP/HTTPS
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT

# 允许 Kubernetes API Server
iptables -A INPUT -p tcp --dport 6443 -j ACCEPT

# 允许 Kubernetes NodePort 范围
iptables -A INPUT -p tcp --dport 30000:32767 -j ACCEPT

# 允许 ICMP (ping)
iptables -A INPUT -p icmp -j ACCEPT

# 保存规则
iptables-save > /etc/sysconfig/iptables 2>/dev/null || \
iptables-save > /etc/iptables.rules 2>/dev/null || true
IPTABLES_EOF

    chmod +x /etc/iptables/iptables-rules.sh

    # 执行规则脚本
    bash /etc/iptables/iptables-rules.sh >> "$LOG_FILE" 2>&1
    log_success "iptables 规则已应用"

    # 启用 iptables 服务
    if [[ "$SKIP_ENABLE" != "true" ]]; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable iptables 2>>"$LOG_FILE" || true
            log_success "iptables 服务已启用开机自启"
        fi
    fi
}

# 无防火墙时的处理
configure_no_firewall() {
    log_warn "未检测到防火墙工具"
    log_warn "如果使用云安全组管理防火墙，请在云控制台配置以下规则:"
    log_info "  - 开放端口 22 (SSH)"
    log_info "  - 开放端口 80 (HTTP)"
    log_info "  - 开放端口 443 (HTTPS)"
    log_info "  - 开放端口 6443 (K8s API)"
    log_info "  - 开放端口范围 30000-32767 (NodePort)"
}

# 验证防火墙规则
verify_firewall_rules() {
    log_step "验证防火墙规则"

    local all_ok=true

    case "$FIREWALL_TYPE" in
        firewalld)
            # 验证每个端口
            for port in "${!PORTS[@]}"; do
                if firewall-cmd --query-port="${port}/tcp" >/dev/null 2>&1; then
                    log_success "端口 ${port} (${PORTS[$port]}) 验证通过"
                else
                    log_error "端口 ${port} (${PORTS[$port]}) 验证失败"
                    all_ok=false
                fi
            done

            # 验证 NodePort 范围
            if firewall-cmd --query-port="${NODEPORT_RANGE}/tcp" >/dev/null 2>&1; then
                log_success "NodePort 范围 (${NODEPORT_RANGE}) 验证通过"
            else
                log_error "NodePort 范围 (${NODEPORT_RANGE}) 验证失败"
                all_ok=false
            fi

            # 显示完整规则列表
            log_info "当前 public zone 规则:"
            firewall-cmd --list-all 2>/dev/null | tee -a "$LOG_FILE" || true
            ;;

        iptables)
            # 验证 iptables 规则
            if iptables -L INPUT -n 2>/dev/null | grep -q "dpt:22"; then
                log_success "端口 22 (SSH) 验证通过"
            else
                log_error "端口 22 (SSH) 验证失败"
                all_ok=false
            fi

            if iptables -L INPUT -n 2>/dev/null | grep -q "dpt:6443"; then
                log_success "端口 6443 (K8s API) 验证通过"
            else
                log_error "端口 6443 (K8s API) 验证失败"
                all_ok=false
            fi

            log_info "当前 iptables INPUT 规则:"
            iptables -L INPUT -n 2>/dev/null | head -20 | tee -a "$LOG_FILE" || true
            ;;

        none)
            log_info "无本地防火墙，跳过规则验证"
            ;;
    esac

    if [[ "$all_ok" == "true" ]]; then
        log_success "所有防火墙规则验证通过"
    else
        log_warn "部分规则验证失败，请检查防火墙配置"
    fi
}

# ========================= 帮助信息 =========================
show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --skip-enable    只添加规则，不启用防火墙服务"
    echo "  --dry-run        干运行，显示将要执行的操作"
    echo "  --help           显示此帮助信息"
    echo ""
    echo "端口说明:"
    for port in $(echo "${!PORTS[@]}" | tr ' ' '\n' | sort -n); do
        echo "  ${port}/tcp    ${PORTS[$port]}"
    done
    echo "  ${NODEPORT_RANGE}/tcp  Kubernetes NodePort 范围"
}

# ========================= 主逻辑 =========================
main() {
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-enable)
                SKIP_ENABLE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done

    mkdir -p "$LOG_DIR"
    check_root
    check_lock
    detect_os

    log_step "阶段1-任务8: 配置基础防火墙"

    # 检测防火墙类型
    detect_firewall

    # 根据防火墙类型配置规则
    case "$FIREWALL_TYPE" in
        firewalld)
            configure_firewalld
            ;;
        iptables)
            configure_iptables
            ;;
        none)
            configure_no_firewall
            ;;
    esac

    # 验证规则
    if [[ "$DRY_RUN" != "true" ]]; then
        verify_firewall_rules
    fi

    log_success "阶段1-任务8完成: 防火墙配置成功"
}

main "$@"
