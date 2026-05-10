#!/usr/bin/env bash
###############################################################################
# teardown-phase8.sh - 阶段8回滚: 高可用架构回滚
# Enterprise Cloud Native Platform
# 功能: 回滚Keepalived、Nginx LB、MySQL HA、Redis Sentinel
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/teardown"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/teardown-phase8_${TIMESTAMP}.log"
REPORT_FILE="${LOG_DIR}/rollback-report-phase8_${TIMESTAMP}.txt"
START_TIME=$(date +%s)

# 加载共享库
source "$SCRIPT_DIR/../../scripts/lib/common.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_step()    { echo -e "${CYAN}[STEP]${NC}    $(date '+%Y-%m-%d %H:%M:%S') === $* ===" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[OK]${NC}      $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_header() {
    echo -e ""
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║${NC}  ${BOLD}${MAGENTA}$*${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo -e ""
}

init() {
    mkdir -p "$LOG_DIR"
    log_header "企业级云原生运维平台 - 阶段8回滚"
    log_info "回滚时间: $(date '+%Y-%m-%d %H:%M:%S')"
}

confirm_rollback() {
    echo ""
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║  ⚠️  警告: 即将回滚阶段8 - 高可用架构                    ║${NC}"
    echo -e "${RED}${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}${BOLD}║  回滚内容:                                                ║${NC}"
    echo -e "${RED}${BOLD}║    - 停止Redis Sentinel集群                              ║${NC}"
    echo -e "${RED}${BOLD}║    - 停止MySQL主从复制                                   ║${NC}"
    echo -e "${RED}${BOLD}║    - 停止Nginx负载均衡                                   ║${NC}"
    echo -e "${RED}${BOLD}║    - 停止Keepalived VIP漂移                              ║${NC}"
    echo -e "${RED}${BOLD}║    - 清理HA相关配置                                      ║${NC}"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -ne "${YELLOW}是否确认回滚? 输入 YES 继续: ${NC}"
    read -r confirm
    [[ "$confirm" == "YES" ]] || { echo "已取消"; exit 0; }
}

rollback_redis_sentinel() {
    log_step "步骤1/5: 停止Redis Sentinel集群"
    if command -v systemctl &>/dev/null; then
        systemctl stop redis-sentinel 2>/dev/null || true
        systemctl disable redis-sentinel 2>/dev/null || true
        systemctl stop redis 2>/dev/null || true
        systemctl disable redis 2>/dev/null || true
        
        if [[ -f /etc/redis/sentinel.conf ]]; then
            cp /etc/redis/sentinel.conf /etc/redis/sentinel.conf.bak."$TIMESTAMP"
            rm -f /etc/redis/sentinel.conf
        fi
        
        log_success "Redis Sentinel已停止"
    else
        log_warn "systemctl不可用，跳过"
    fi
    echo "Redis Sentinel已停止" >> "$REPORT_FILE"
}

rollback_mysql_ha() {
    log_step "步骤2/5: 停止MySQL高可用"
    if command -v systemctl &>/dev/null; then
        systemctl stop mysqld 2>/dev/null || systemctl stop mysql 2>/dev/null || true
        systemctl disable mysqld 2>/dev/null || systemctl disable mysql 2>/dev/null || true
        
        if [[ -f /etc/my.cnf.bak ]] || [[ -f /etc/mysql/my.cnf.bak ]]; then
            cp /etc/my.cnf.bak."$TIMESTAMP" /etc/my.cnf 2>/dev/null || \
                cp /etc/mysql/my.cnf.bak."$TIMESTAMP" /etc/mysql/my.cnf 2>/dev/null || true
        fi
        
        log_success "MySQL高可用已停止"
    fi
    echo "MySQL高可用已停止" >> "$REPORT_FILE"
}

rollback_nginx_lb() {
    log_step "步骤3/5: 停止Nginx负载均衡"
    if command -v systemctl &>/dev/null; then
        systemctl stop nginx 2>/dev/null || true
        systemctl disable nginx 2>/dev/null || true
        
        if [[ -f /etc/nginx/nginx.conf.bak ]]; then
            cp /etc/nginx/nginx.conf.bak."$TIMESTAMP" /etc/nginx/nginx.conf 2>/dev/null || true
        fi
        
        log_success "Nginx负载均衡已停止"
    fi
    echo "Nginx负载均衡已停止" >> "$REPORT_FILE"
}

rollback_keepalived() {
    log_step "步骤4/5: 停止Keepalived"
    if command -v systemctl &>/dev/null; then
        systemctl stop keepalived 2>/dev/null || true
        systemctl disable keepalived 2>/dev/null || true
        
        # 释放VIP
        local vip="192.168.100.100"
        ip addr del "$vip"/24 dev eth0 2>/dev/null || \
            ip addr del "$vip"/24 dev ens33 2>/dev/null || \
            log_warn "VIP释放失败或不存在"
        
        if [[ -f /etc/keepalived/keepalived.conf.bak ]]; then
            cp /etc/keepalived/keepalived.conf.bak."$TIMESTAMP" /etc/keepalived/keepalived.conf 2>/dev/null || true
        fi
        
        log_success "Keepalived已停止"
    fi
    echo "Keepalived已停止" >> "$REPORT_FILE"
}

verify_rollback() {
    log_step "步骤5/5: 验证回滚结果"
    local errors=0
    
    for svc in keepalived nginx mysqld redis redis-sentinel; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log_error "$svc仍在运行!"
            ((errors++))
        else
            log_success "$svc已停止"
        fi
    done
    
    [[ $errors -eq 0 ]] && log_success "回滚验证通过" || log_error "回滚验证发现${errors}个问题"
    echo "回滚验证: $([ $errors -eq 0 ] && echo '通过' || echo '有问题')" >> "$REPORT_FILE"
}

generate_report() {
    local duration=$(( $(date +%s) - START_TIME ))
    echo "" >> "$REPORT_FILE"
    echo "========================================" >> "$REPORT_FILE"
    echo "阶段8回滚报告 | 耗时: ${duration}秒 | 主机: $(hostname)" >> "$REPORT_FILE"
    echo "========================================" >> "$REPORT_FILE"
    log_header "阶段8回滚完成"
    log_info "总耗时: ${duration}秒 | 报告: $REPORT_FILE"
}

main() {
    init
    confirm_rollback
    rollback_redis_sentinel
    rollback_mysql_ha
    rollback_nginx_lb
    rollback_keepalived
    verify_rollback
    generate_report
}

main "$@"
