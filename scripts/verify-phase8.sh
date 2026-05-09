#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# 阶段8: 高可用架构验证
# 验证项目: Keepalived、Nginx LB、MySQL HA、Redis Sentinel
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPORT_DIR="$PROJECT_DIR/reports"
REPORT_FILE="$REPORT_DIR/verify-phase8-$(date +%Y%m%d-%H%M%S).log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
TOTAL_COUNT=0

mkdir -p "$REPORT_DIR"

log() { local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"; echo -e "$msg"; echo "$msg" >> "$REPORT_FILE"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); TOTAL_COUNT=$((TOTAL_COUNT + 1)); log "${GREEN}[PASS]${NC} $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); TOTAL_COUNT=$((TOTAL_COUNT + 1)); log "${RED}[FAIL]${NC} $1"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); TOTAL_COUNT=$((TOTAL_COUNT + 1)); log "${YELLOW}[WARN]${NC} $1"; }
info() { log "${BLUE}[INFO]${NC} $1"; }
section() { echo ""; log "${CYAN}========== $1 ==========${NC}"; }

# ========== 开始验证 ==========
section "阶段8: 高可用架构验证"

# --- 8.1 Keepalived检查 ---
section "8.1 Keepalived检查"

if systemctl is-active keepalived &>/dev/null; then
    pass "Keepalived 服务运行中"
else
    warn "Keepalived 服务未运行 (可能使用容器化部署)"
fi

# 检查VIP
VIP="192.168.1.100"
if ip addr show | grep -q "$VIP" 2>/dev/null; then
    pass "VIP $VIP 已绑定到本机"
else
    info "VIP $VIP 未绑定到本机 (可能在其他节点)"
fi

# 检查Keepalived配置
KEEPALIVED_CONF="/etc/keepalived/keepalived.conf"
if [[ -f "$KEEPALIVED_CONF" ]]; then
    pass "Keepalived 配置文件存在"
    if grep -q "vrrp_script" "$KEEPALIVED_CONF" 2>/dev/null; then
        pass "Keepalived VRRP脚本已配置"
    fi
else
    info "Keepalived 配置文件不存在 (可能使用容器化部署)"
fi

# 检查K8s中的Keepalived
KEEPALIVED_K8S=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -i keepalived || echo "")
if [[ -n "$KEEPALIVED_K8S" ]]; then
    if echo "$KEEPALIVED_K8S" | grep -q "Running"; then
        pass "K8s Keepalived Pod 运行正常"
    else
        warn "K8s Keepalived Pod 异常"
    fi
fi

# --- 8.2 Nginx负载均衡检查 ---
section "8.2 Nginx负载均衡检查"

if systemctl is-active nginx &>/dev/null; then
    pass "Nginx 服务运行中"
else
    warn "Nginx 服务未运行 (可能使用容器化部署)"
fi

NGINX_CONF="/etc/nginx/nginx.conf"
if [[ -f "$NGINX_CONF" ]]; then
    pass "Nginx 配置文件存在"
    if grep -q "upstream" "$NGINX_CONF" 2>/dev/null; then
        pass "Nginx upstream 配置存在 (负载均衡已配置)"
    else
        info "Nginx 未配置upstream"
    fi
else
    info "Nginx 配置文件不存在 (可能使用容器化部署)"
fi

# 检查K8s中的Nginx LB
NGINX_K8S=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -iE "nginx.*(lb|load)" || echo "")
if [[ -z "$NGINX_K8S" ]]; then
    NGINX_K8S=$(kubectl get pods -n ingress-nginx --no-headers 2>/dev/null | grep -i nginx || echo "")
fi
if [[ -n "$NGINX_K8S" ]]; then
    if echo "$NGINX_K8S" | grep -q "Running"; then
        pass "Nginx Ingress Controller/LB 运行正常"
    fi
fi

# --- 8.3 MySQL高可用检查 ---
section "8.3 MySQL高可用检查"

# 检查MySQL容器/Pod
MYSQL_PODS=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -i mysql || echo "")
MYSQL_RUNNING=$(echo "$MYSQL_PODS" | grep -c "Running" 2>/dev/null || echo "0")
MYSQL_TOTAL=$(echo "$MYSQL_PODS" | grep -c . 2>/dev/null || echo "0")

if [[ $MYSQL_RUNNING -gt 0 ]]; then
    pass "MySQL Pod 运行正常 ($MYSQL_RUNNING/$MYSQL_TOTAL)"
elif systemctl is-active mysqld &>/dev/null || systemctl is-active mysql &>/dev/null; then
    pass "MySQL 服务运行中 (systemd)"
else
    warn "MySQL 未检测到运行实例"
fi

# 检查MySQL主从
MYSQL_MASTER_IP=$(kubectl get configmap --all-namespaces --no-headers 2>/dev/null | grep -i mysql | head -1 || echo "")
if [[ -n "$MYSQL_MASTER_IP" ]]; then
    info "MySQL 配置发现"
fi

# --- 8.4 Redis Sentinel检查 ---
section "8.4 Redis Sentinel检查"

REDIS_PODS=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -i redis || echo "")
REDIS_RUNNING=$(echo "$REDIS_PODS" | grep -c "Running" 2>/dev/null || echo "0")
REDIS_TOTAL=$(echo "$REDIS_PODS" | grep -c . 2>/dev/null || echo "0")

if [[ $REDIS_RUNNING -gt 0 ]]; then
    pass "Redis Pod 运行正常 ($REDIS_RUNNING/$REDIS_TOTAL)"
elif systemctl is-active redis &>/dev/null || systemctl is-active redis-server &>/dev/null; then
    pass "Redis 服务运行中 (systemd)"
else
    warn "Redis 未检测到运行实例"
fi

# 检查Redis Sentinel
SENTINEL_PODS=$(echo "$REDIS_PODS" | grep -i sentinel || echo "")
if [[ -n "$SENTINEL_PODS" ]]; then
    SENTINEL_RUNNING=$(echo "$SENTINEL_PODS" | grep -c "Running" 2>/dev/null || echo "0")
    if [[ $SENTINEL_RUNNING -gt 0 ]]; then
        pass "Redis Sentinel 运行正常"
    fi
fi

# 检查Sentinel配置
SENTINEL_CONF=$(find /etc/redis/ -name "redis-sentinel.conf" 2>/dev/null || echo "")
if [[ -n "$SENTINEL_CONF" ]]; then
    pass "Redis Sentinel 配置文件存在"
fi

# --- 8.5 服务可用性测试 ---
section "8.5 服务可用性测试"

# 测试VIP可达性
if ping -c 1 -W 2 "$VIP" &>/dev/null; then
    pass "VIP $VIP 可达"
else
    info "VIP $VIP 不可达 (可能本机不承载VIP)"
fi

# 检查端口监听
for port in 80 443 3306 6379 26379; do
    if ss -tlnp | grep -q ":${port} " 2>/dev/null; then
        pass "端口 $port 正在监听"
    fi
done

# ========== 验证报告 ==========
section "验证汇总"

echo ""
log "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
log "${CYAN}║          阶段8: 高可用架构验证报告              ║${NC}"
log "${CYAN}╠══════════════════════════════════════════════════╣${NC}"
log "${CYAN}║${NC} 总检查项:  ${TOTAL_COUNT}                                    ${CYAN}║${NC}"
log "${GREEN}║${NC} 通过:      ${PASS_COUNT}                                    ${GREEN}║${NC}"
log "${RED}║${NC} 失败:      ${FAIL_COUNT}                                    ${RED}║${NC}"
log "${YELLOW}║${NC} 警告:      ${WARN_COUNT}                                    ${YELLOW}║${NC}"
log "${CYAN}╠══════════════════════════════════════════════════╣${NC}"

if [[ $FAIL_COUNT -eq 0 ]]; then
    if [[ $WARN_COUNT -eq 0 ]]; then
        log "${GREEN}║  结果: ✓ 全部通过                               ║${NC}"
    else
        log "${YELLOW}║  结果: △ 通过(有警告)                           ║${NC}"
    fi
else
    log "${RED}║  结果: ✗ 存在失败项                             ║${NC}"
fi

log "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
log ""
log "报告已保存: $REPORT_FILE"

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
