#!/usr/bin/env bash
set -euo pipefail

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPORT_DIR="$PROJECT_DIR/reports"
REPORT_FILE="$REPORT_DIR/verify-phase9-$(date +%Y%m%d-%H%M%S).log"
TIMESTAMP_REPORT="$REPORT_DIR/verify-phase9-$(date +%Y%m%d-%H%M%S).txt"

# 加载共享库
source "$SCRIPT_DIR/lib/common.sh"

##############################################################################
# 阶段9: 自动化运维验证
# 验证项目: Ansible、健康检查、日志清理、备份验证
##############################################################################

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
section "阶段9: 自动化运维验证"

# --- 9.1 Ansible检查 ---
section "9.1 Ansible检查"

if command -v ansible &>/dev/null; then
    ANSIBLE_VERSION=$(ansible --version 2>/dev/null | head -1 || echo "unknown")
    pass "Ansible 已安装: $ANSIBLE_VERSION"
else
    fail "Ansible 未安装"
fi

if command -v ansible-playbook &>/dev/null; then
    pass "ansible-playbook 命令可用"
else
    fail "ansible-playbook 命令不可用"
fi

if command -v ansible-vault &>/dev/null; then
    pass "ansible-vault 命令可用"
else
    info "ansible-vault 命令不可用 (可选)"
fi

# 检查Ansible配置
ANSIBLE_CFG="$PROJECT_DIR/ansible/ansible.cfg"
if [[ -f "$ANSIBLE_CFG" ]]; then
    pass "Ansible 配置文件存在"
else
    info "Ansible 配置文件不存在 (使用默认配置)"
fi

# 检查Inventory
INVENTORY="$PROJECT_DIR/ansible/inventory/hosts.yml"
if [[ -f "$INVENTORY" ]]; then
    pass "Ansible Inventory 文件存在"
else
    warn "Ansible Inventory 文件不存在"
fi

# --- 9.2 Playbook检查 ---
section "9.2 Playbook检查"

PLAYBOOKS_DIR="$PROJECT_DIR/ansible/playbooks"
if [[ -d "$PLAYBOOKS_DIR" ]]; then
    PLAYBOOK_COUNT=$(ls "$PLAYBOOKS_DIR"/*.yml "$PLAYBOOKS_DIR"/*.yaml 2>/dev/null | wc -l || echo "0")
    if [[ $PLAYBOOK_COUNT -gt 0 ]]; then
        pass "Playbook 数量: $PLAYBOOK_COUNT"
        for pb in "$PLAYBOOKS_DIR"/*.yml "$PLAYBOOKS_DIR"/*.yaml; do
            [[ -f "$pb" ]] || continue
            PB_NAME=$(basename "$pb")
            info "  Playbook: $PB_NAME"
        done
    else
        warn "Playbook 目录为空"
    fi
else
    warn "Playbook 目录不存在"
fi

# 检查health-check playbook
if [[ -f "$PLAYBOOKS_DIR/health-check.yml" ]]; then
    pass "健康检查 Playbook 存在"
else
    warn "健康检查 Playbook 不存在"
fi

# 检查backup playbook
if [[ -f "$PLAYBOOKS_DIR/backup.yml" ]]; then
    pass "备份 Playbook 存在"
else
    warn "备份 Playbook 不存在"
fi

# --- 9.3 Roles检查 ---
section "9.3 Ansible Roles检查"

ROLES_DIR="$PROJECT_DIR/ansible/roles"
if [[ -d "$ROLES_DIR" ]]; then
    ROLE_COUNT=$(ls -d "$ROLES_DIR"/*/ 2>/dev/null | wc -l || echo "0")
    if [[ $ROLE_COUNT -gt 0 ]]; then
        pass "Ansible Roles 数量: $ROLE_COUNT"
        for role_dir in "$ROLES_DIR"/*/; do
            [[ -d "$role_dir" ]] || continue
            ROLE_NAME=$(basename "$role_dir")
            info "  Role: $ROLE_NAME"
        done
    else
        info "无自定义Roles"
    fi
else
    info "Roles 目录不存在"
fi

# --- 9.4 健康检查脚本检查 ---
section "9.4 健康检查脚本检查"

HEALTH_SCRIPT="$PROJECT_DIR/scripts/09-automation/02-health-check.sh"
if [[ -f "$HEALTH_SCRIPT" ]]; then
    pass "健康检查脚本存在"
else
    warn "健康检查脚本不存在"
fi

# 检查最近的健康检查报告
HEALTH_REPORTS=$(ls /var/log/health-check-*.txt 2>/dev/null || echo "")
if [[ -n "$HEALTH_REPORTS" ]]; then
    LATEST_REPORT=$(ls -t /var/log/health-check-*.txt 2>/dev/null | head -1)
    REPORT_TIME=$(stat -c %y "$LATEST_REPORT" 2>/dev/null | cut -d. -f1 || echo "unknown")
    pass "健康检查报告存在，最新: $LATEST_REPORT ($REPORT_TIME)"
else
    info "未发现健康检查报告"
fi

# --- 9.5 备份检查 ---
section "9.5 备份检查"

BACKUP_SCRIPT="$PROJECT_DIR/scripts/09-automation/04-backup-verify.sh"
if [[ -f "$BACKUP_SCRIPT" ]]; then
    pass "备份验证脚本存在"
else
    warn "备份验证脚本不存在"
fi

BACKUP_DIRS=("/backup" "/var/backup" "/data/backup" "/mnt/backup")
for dir in "${BACKUP_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        BACKUP_FILES=$(ls "$dir" 2>/dev/null | wc -l || echo "0")
        if [[ $BACKUP_FILES -gt 0 ]]; then
            pass "备份目录 $dir 存在，包含 $BACKUP_FILES 个文件"
        else
            info "备份目录 $dir 存在，但为空"
        fi
    fi
done

# --- 9.6 日志清理检查 ---
section "9.6 日志清理检查"

CLEANUP_SCRIPT="$PROJECT_DIR/scripts/09-automation/03-log-cleanup.sh"
if [[ -f "$CLEANUP_SCRIPT" ]]; then
    pass "日志清理脚本存在"
else
    warn "日志清理脚本不存在"
fi

# 检查crontab中的清理任务
if crontab -l 2>/dev/null | grep -qi "cleanup\|log.*clean\|vacuum"; then
    pass "日志清理定时任务已配置"
else
    info "未发现日志清理crontab任务"
fi

# ========== 验证报告 ==========
section "验证汇总"

echo ""
log "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
log "${CYAN}║          阶段9: 自动化运维验证报告              ║${NC}"
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
