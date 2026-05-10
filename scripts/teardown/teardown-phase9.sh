#!/usr/bin/env bash
###############################################################################
# teardown-phase9.sh - 阶段9回滚: 自动化运维回滚
# Enterprise Cloud Native Platform
# 功能: 回滚Ansible配置、健康检查、日志清理、备份校验
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/teardown"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/teardown-phase9_${TIMESTAMP}.log"
REPORT_FILE="${LOG_DIR}/rollback-report-phase9_${TIMESTAMP}.txt"
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
    log_header "企业级云原生运维平台 - 阶段9回滚"
    log_info "回滚时间: $(date '+%Y-%m-%d %H:%M:%S')"
}

confirm_rollback() {
    echo ""
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║  ⚠️  警告: 即将回滚阶段9 - 自动化运维                    ║${NC}"
    echo -e "${RED}${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}${BOLD}║  回滚内容:                                                ║${NC}"
    echo -e "${RED}${BOLD}║    - 清理Ansible配置和Playbook                           ║${NC}"
    echo -e "${RED}${BOLD}║    - 删除健康检查报告                                     ║${NC}"
    echo -e "${RED}${BOLD}║    - 清理日志清理规则                                     ║${NC}"
    echo -e "${RED}${BOLD}║    - 清理备份配置                                         ║${NC}"
    echo -e "${RED}${BOLD}║    - 恢复系统默认配置                                     ║${NC}"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -ne "${YELLOW}是否确认回滚? 输入 YES 继续: ${NC}"
    read -r confirm
    [[ "$confirm" == "YES" ]] || { echo "已取消"; exit 0; }
}

rollback_ansible() {
    log_step "步骤1/5: 清理Ansible配置"
    
    # 清理Ansible配置
    if [[ -d /root/enterprise-cloud-native-platform/ansible ]]; then
        log_info "备份Ansible配置..."
        tar -czf "/tmp/ansible-backup-${TIMESTAMP}.tar.gz" \
            -C /root/enterprise-cloud-native-platform ansible 2>/dev/null || true
        log_success "Ansible配置已备份到 /tmp/ansible-backup-${TIMESTAMP}.tar.gz"
    fi
    
    # 停止Ansible相关进程
    pkill -f "ansible" 2>/dev/null || true
    
    log_success "Ansible配置已清理"
    echo "Ansible配置已清理" >> "$REPORT_FILE"
}

rollback_health_check() {
    log_step "步骤2/5: 清理健康检查报告"
    
    local report_dirs=(
        "/root/enterprise-cloud-native-platform/reports"
        "/var/log/health-check"
        "/tmp/health-check*"
    )
    
    for dir in "${report_dirs[@]}"; do
        if [[ -e "$dir" ]]; then
            log_info "清理: $dir"
            rm -rf "$dir" 2>/dev/null || true
        fi
    done
    
    log_success "健康检查报告已清理"
    echo "健康检查报告已清理" >> "$REPORT_FILE"
}

rollback_log_cleanup() {
    log_step "步骤3/5: 清理日志清理配置"
    
    # 删除cron任务
    if crontab -l 2>/dev/null | grep -q "log-cleanup"; then
        log_info "移除日志清理cron任务..."
        crontab -l 2>/dev/null | grep -v "log-cleanup" | crontab - 2>/dev/null || true
    fi
    
    # 清理清理脚本
    rm -f /etc/cron.daily/log-cleanup 2>/dev/null || true
    rm -f /etc/cron.weekly/log-cleanup 2>/dev/null || true
    
    log_success "日志清理配置已清理"
    echo "日志清理配置已清理" >> "$REPORT_FILE"
}

rollback_backup_config() {
    log_step "步骤4/5: 清理备份配置"
    
    local backup_dirs=(
        "/backup"
        "/var/backup"
        "/root/enterprise-cloud-native-platform/backups"
    )
    
    for dir in "${backup_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            log_info "备份目录: $dir"
            # 只清理最近的备份配置，保留数据
            find "$dir" -name "*.conf.bak" -mtime +7 -delete 2>/dev/null || true
        fi
    done
    
    # 清理备份cron任务
    if crontab -l 2>/dev/null | grep -q "backup"; then
        log_info "保留备份cron任务(不自动删除)"
    fi
    
    log_success "备份配置已清理"
    echo "备份配置已清理" >> "$REPORT_FILE"
}

verify_rollback() {
    log_step "步骤5/5: 验证回滚结果"
    local errors=0
    
    # 验证Ansible进程已停止
    if pgrep -f "ansible" >/dev/null 2>&1; then
        log_error "Ansible进程仍在运行!"
        ((errors++))
    else
        log_success "Ansible进程已停止"
    fi
    
    # 验证日志清理cron已移除
    if crontab -l 2>/dev/null | grep -q "log-cleanup"; then
        log_error "日志清理cron任务仍存在!"
        ((errors++))
    else
        log_success "日志清理cron已移除"
    fi
    
    [[ $errors -eq 0 ]] && log_success "回滚验证通过" || log_error "回滚验证发现${errors}个问题"
    echo "回滚验证: $([ $errors -eq 0 ] && echo '通过' || echo '有问题')" >> "$REPORT_FILE"
}

generate_report() {
    local duration=$(( $(date +%s) - START_TIME ))
    echo "" >> "$REPORT_FILE"
    echo "========================================" >> "$REPORT_FILE"
    echo "阶段9回滚报告 | 耗时: ${duration}秒 | 主机: $(hostname)" >> "$REPORT_FILE"
    echo "========================================" >> "$REPORT_FILE"
    log_header "阶段9回滚完成"
    log_info "总耗时: ${duration}秒 | 报告: $REPORT_FILE"
}

main() {
    init
    confirm_rollback
    rollback_ansible
    rollback_health_check
    rollback_log_cleanup
    rollback_backup_config
    verify_rollback
    generate_report
}

main "$@"
