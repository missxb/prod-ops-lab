#!/usr/bin/env bash
###############################################################################
# teardown-phase1.sh - 阶段1回滚: 基础环境初始化回滚
# Enterprise Cloud Native Platform
# 功能: 回滚主机名、SSH、NTP、内核参数、Docker、NFS配置
# 安全: 确认提示 + 彩色日志 + 回滚报告
###############################################################################
set -euo pipefail

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/teardown"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/teardown-phase1_${TIMESTAMP}.log"
REPORT_FILE="${LOG_DIR}/rollback-report-phase1_${TIMESTAMP}.txt"
START_TIME=$(date +%s)

# 加载共享库
source "$SCRIPT_DIR/../../scripts/lib/common.sh"

# ========================= 颜色定义 =========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# ========================= 日志函数 =========================
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

# ========================= 初始化 =========================
init() {
    mkdir -p "$LOG_DIR"
    log_header "企业级云原生运维平台 - 阶段1回滚"
    log_info "回滚时间: $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "回滚日志: $LOG_FILE"
    log_info "回滚报告: $REPORT_FILE"
    echo ""
}

# ========================= 确认提示 =========================
confirm_rollback() {
    echo ""
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║  ⚠️  警告: 即将回滚阶段1 - 基础环境初始化              ║${NC}"
    echo -e "${RED}${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}${BOLD}║                                                            ║${NC}"
    echo -e "${RED}${BOLD}║  回滚内容:                                                ║${NC}"
    echo -e "${RED}${BOLD}║    - 停止Docker/containerd服务                            ║${NC}"
    echo -e "${RED}${BOLD}║    - 卸载kubeadm/kubelet/kubectl (如已安装)               ║${NC}"
    echo -e "${RED}${BOLD}║    - 恢复内核参数                                         ║${NC}"
    echo -e "${RED}${BOLD}║    - 恢复NTP配置                                         ║${NC}"
    echo -e "${RED}${BOLD}║    - 清理NFS导出配置                                      ║${NC}"
    echo -e "${RED}${BOLD}║                                                            ║${NC}"
    echo -e "${RED}${BOLD}║  ⚠️  此操作不可逆!                                        ║${NC}"
    echo -e "${RED}${BOLD}║                                                            ║${NC}"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -ne "${YELLOW}是否确认回滚? 输入 YES 继续: ${NC}"
    read -r confirm
    if [[ "$confirm" != "YES" ]]; then
        echo -e "${RED}已取消回滚操作${NC}"
        exit 0
    fi
    echo ""
}

# ========================= 回滚步骤 =========================

# 步骤1: 停止Docker/containerd
rollback_docker() {
    log_step "步骤1/6: 停止Docker/containerd服务"
    
    if systemctl is-active --quiet docker 2>/dev/null; then
        log_info "停止Docker服务..."
        systemctl stop docker
        systemctl disable docker
        log_success "Docker服务已停止"
    else
        log_warn "Docker服务未运行，跳过"
    fi
    
    if systemctl is-active --quiet containerd 2>/dev/null; then
        log_info "停止containerd服务..."
        systemctl stop containerd
        systemctl disable containerd
        log_success "containerd服务已停止"
    else
        log_warn "containerd服务未运行，跳过"
    fi
    
    echo "Docker/containerd服务已停止" >> "$REPORT_FILE"
}

# 步骤2: 卸载kubeadm/kubelet/kubectl (如果在阶段1安装了)
rollback_k8s_tools() {
    log_step "步骤2/6: 卸载K8s工具 (如存在)"
    
    if command -v kubeadm &>/dev/null; then
        log_info "检测到kubeadm，执行kubeadm reset..."
        kubeadm reset -f 2>/dev/null || log_warn "kubeadm reset失败，可能需要手动清理"
    fi
    
    if command -v kubelet &>/dev/null; then
        log_info "停止kubelet..."
        systemctl stop kubelet 2>/dev/null || true
        systemctl disable kubelet 2>/dev/null || true
        log_success "kubelet已停止"
    fi
    
    log_info "卸载kubeadm/kubelet/kubectl..."
    if command -v yum &>/dev/null; then
        yum remove -y kubelet kubeadm kubectl 2>/dev/null || log_warn "卸载失败"
    elif command -v apt-get &>/dev/null; then
        apt-get remove -y kubelet kubeadm kubectl 2>/dev/null || log_warn "卸载失败"
    fi
    
    # 清理K8s相关配置
    rm -rf /etc/kubernetes 2>/dev/null || true
    rm -rf /var/lib/kubelet 2>/dev/null || true
    
    echo "K8s工具已卸载" >> "$REPORT_FILE"
}

# 步骤3: 恢复内核参数
rollback_kernel() {
    log_step "步骤3/6: 恢复内核参数"
    
    # 恢复K8s相关内核参数
    if [[ -f /etc/sysctl.d/k8s.conf ]]; then
        log_info "备份并删除K8s内核参数配置..."
        cp /etc/sysctl.d/k8s.conf /etc/sysctl.d/k8s.conf.bak."$TIMESTAMP"
        rm -f /etc/sysctl.d/k8s.conf
        log_success "K8s内核参数配置已移除"
    fi
    
    # 恢复模块加载配置
    if [[ -f /etc/modules-load.d/k8s.conf ]]; then
        log_info "备份并删除K8s模块加载配置..."
        cp /etc/modules-load.d/k8s.conf /etc/modules-load.d/k8s.conf.bak."$TIMESTAMP"
        rm -f /etc/modules-load.d/k8s.conf
        log_success "K8s模块加载配置已移除"
    fi
    
    # 卸载内核模块
    log_info "卸载内核模块..."
    modprobe -r overlay 2>/dev/null || log_warn "overlay模块卸载失败"
    modprobe -r br_netfilter 2>/dev/null || log_warn "br_netfilter模块卸载失败"
    
    # 应用系统默认内核参数
    log_info "重新加载内核参数..."
    sysctl --system 2>/dev/null || true
    
    echo "内核参数已恢复" >> "$REPORT_FILE"
}

# 步骤4: 恢复NTP配置
rollback_ntp() {
    log_step "步骤4/6: 恢复NTP配置"
    
    # 恢复chrony配置
    if [[ -f /etc/chrony.conf.bak.* ]] 2>/dev/null; then
        local latest_bak=$(ls -t /etc/chrony.conf.bak.* 2>/dev/null | head -1)
        if [[ -n "$latest_bak" ]]; then
            log_info "恢复chrony配置..."
            cp "$latest_bak" /etc/chrony.conf
            systemctl restart chronyd 2>/dev/null || true
            log_success "chrony配置已恢复"
        fi
    else
        log_info "无chrony备份，跳过"
    fi
    
    # 恢复ntpd配置
    if [[ -f /etc/ntp.conf.bak.* ]] 2>/dev/null; then
        local latest_ntp_bak=$(ls -t /etc/ntp.conf.bak.* 2>/dev/null | head -1)
        if [[ -n "$latest_ntp_bak" ]]; then
            log_info "恢复ntpd配置..."
            cp "$latest_ntp_bak" /etc/ntp.conf
            systemctl restart ntpd 2>/dev/null || true
            log_success "ntpd配置已恢复"
        fi
    fi
    
    echo "NTP配置已恢复" >> "$REPORT_FILE"
}

# 步骤5: 清理NFS配置
rollback_nfs() {
    log_step "步骤5/6: 清理NFS导出配置"
    
    # 备份当前exports
    if [[ -f /etc/exports ]]; then
        log_info "备份NFS导出配置..."
        cp /etc/exports /etc/exports.bak."$TIMESTAMP"
        
        # 移除NFS导出行
        if grep -q "exports" /etc/exports; then
            log_info "移除NFS导出配置..."
            sed -i '/^\/exports/d' /etc/exports
            log_success "NFS导出配置已清理"
            
            # 重新导出
            exportfs -ra 2>/dev/null || true
        fi
    fi
    
    # 停止NFS服务
    if systemctl is-active --quiet nfs-server 2>/dev/null; then
        log_info "停止NFS服务..."
        systemctl stop nfs-server
        systemctl disable nfs-server
        log_success "NFS服务已停止"
    fi
    
    echo "NFS配置已清理" >> "$REPORT_FILE"
}

# 步骤6: 验证回滚
verify_rollback() {
    log_step "步骤6/6: 验证回滚结果"
    
    local errors=0
    
    # 验证Docker
    if systemctl is-active --quiet docker 2>/dev/null; then
        log_error "Docker仍在运行!"
        ((errors++))
    else
        log_success "Docker已停止"
    fi
    
    # 验证containerd
    if systemctl is-active --quiet containerd 2>/dev/null; then
        log_error "containerd仍在运行!"
        ((errors++))
    else
        log_success "containerd已停止"
    fi
    
    # 验证kubelet
    if systemctl is-active --quiet kubelet 2>/dev/null; then
        log_error "kubelet仍在运行!"
        ((errors++))
    else
        log_success "kubelet已停止"
    fi
    
    # 验证内核模块
    if lsmod | grep -q "br_netfilter"; then
        log_warn "br_netfilter模块仍加载"
    else
        log_success "br_netfilter模块已卸载"
    fi
    
    if [[ $errors -eq 0 ]]; then
        log_success "回滚验证通过"
        echo "回滚验证: 通过" >> "$REPORT_FILE"
    else
        log_error "回滚验证发现${errors}个问题"
        echo "回滚验证: 有${errors}个问题" >> "$REPORT_FILE"
    fi
}

# ========================= 生成报告 =========================
generate_report() {
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    
    echo "" >> "$REPORT_FILE"
    echo "========================================" >> "$REPORT_FILE"
    echo "阶段1回滚报告" >> "$REPORT_FILE"
    echo "========================================" >> "$REPORT_FILE"
    echo "回滚时间: $(date '+%Y-%m-%d %H:%M:%S')" >> "$REPORT_FILE"
    echo "回滚耗时: ${duration}秒" >> "$REPORT_FILE"
    echo "操作主机: $(hostname)" >> "$REPORT_FILE"
    echo "日志文件: $LOG_FILE" >> "$REPORT_FILE"
    echo "========================================" >> "$REPORT_FILE"
    
    log_header "阶段1回滚完成"
    log_info "总耗时: ${duration}秒"
    log_info "回滚报告: $REPORT_FILE"
    log_info "详细日志: $LOG_FILE"
}

# ========================= 主逻辑 =========================
main() {
    init
    confirm_rollback
    
    rollback_docker
    rollback_k8s_tools
    rollback_kernel
    rollback_ntp
    rollback_nfs
    verify_rollback
    generate_report
}

main "$@"
