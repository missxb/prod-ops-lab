#!/usr/bin/env bash
###############################################################################
# teardown-phase2.sh - 阶段2回滚: Kubernetes集群回滚
# Enterprise Cloud Native Platform
# 功能: 回滚K8s集群、kubeadm/kubelet/kubectl安装、Calico网络插件
###############################################################################
set -euo pipefail

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/teardown"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/teardown-phase2_${TIMESTAMP}.log"
REPORT_FILE="${LOG_DIR}/rollback-report-phase2_${TIMESTAMP}.txt"
START_TIME=$(date +%s)

# 加载共享库
source "$SCRIPT_DIR/../../scripts/lib/common.sh"

# ========================= 颜色定义 =========================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

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
    log_header "企业级云原生运维平台 - 阶段2回滚"
    log_info "回滚时间: $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "回滚日志: $LOG_FILE"
    log_info "回滚报告: $REPORT_FILE"
}

# ========================= 确认提示 =========================
confirm_rollback() {
    echo ""
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║  ⚠️  警告: 即将回滚阶段2 - Kubernetes集群                ║${NC}"
    echo -e "${RED}${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}${BOLD}║  回滚内容:                                                ║${NC}"
    echo -e "${RED}${BOLD}║    - 重置Kubernetes集群                                  ║${NC}"
    echo -e "${Red}${BOLD}║    - 卸载Calico网络插件                                  ║${NC}"
    echo -e "${RED}${BOLD}║    - 卸载kubeadm/kubelet/kubectl                         ║${NC}"
    echo -e "${RED}${BOLD}║    - 恢复Docker/containerd配置                           ║${NC}"
    echo -e "${RED}${BOLD}║    - 清理K8s相关数据和配置                               ║${NC}"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -ne "${YELLOW}是否确认回滚? 输入 YES 继续: ${NC}"
    read -r confirm
    if [[ "$confirm" != "YES" ]]; then
        echo -e "${RED}已取消回滚操作${NC}"
        exit 0
    fi
}

# ========================= 回滚步骤 =========================

# 步骤1: 卸载Calico网络插件
rollback_calico() {
    log_step "步骤1/6: 卸载Calico网络插件"
    
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        log_info "删除Calico资源..."
        kubectl delete -f /etc/kubernetes/calico.yaml 2>/dev/null || \
            kubectl delete daemonset -n kube-system calico-node 2>/dev/null || \
            log_warn "Calico DaemonSet删除失败"
        
        kubectl delete -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml 2>/dev/null || \
            log_warn "Calico manifest删除失败"
        
        kubectl delete clusterrole calico-node 2>/dev/null || true
        kubectl delete clusterrolebinding calico-node 2>/dev/null || true
        kubectl delete serviceaccount calico-node -n kube-system 2>/dev/null || true
        
        log_success "Calico网络插件已卸载"
    else
        log_warn "K8s集群不可达，跳过Calico卸载"
    fi
    
    echo "Calico网络插件已卸载" >> "$REPORT_FILE"
}

# 步骤2: 重置K8s集群
reset_k8s_cluster() {
    log_step "步骤2/6: 重置Kubernetes集群"
    
    if command -v kubeadm &>/dev/null; then
        log_info "执行kubeadm reset..."
        kubeadm reset -f --cri-socket unix:///var/run/containerd/containerd.sock 2>/dev/null || \
            kubeadm reset -f 2>/dev/null || \
            log_warn "kubeadm reset失败"
        
        log_success "K8s集群已重置"
    else
        log_warn "kubeadm不存在，跳过"
    fi
    
    echo "K8s集群已重置" >> "$REPORT_FILE"
}

# 步骤3: 清理K8s目录和配置
cleanup_k8s_dirs() {
    log_step "步骤3/6: 清理K8s目录和配置"
    
    local dirs=(
        "/etc/kubernetes"
        "/var/lib/etcd"
        "/var/lib/kubelet"
        "/etc/cni/net.d"
        "/var/lib/calico"
        "/etc/sysctl.d/k8s.conf"
        "/etc/modules-load.d/k8s.conf"
        "/etc/crictl.yaml"
        "/var/lib/kube-proxy"
        "/var/run/kubernetes"
        "/etc/systemd/system/kubelet.service.d"
    )
    
    for dir in "${dirs[@]}"; do
        if [[ -e "$dir" ]]; then
            log_info "移除: $dir"
            rm -rf "$dir"
        fi
    done
    
    # 清理iptables规则
    log_info "清理K8s iptables规则..."
    iptables -F && iptables -X 2>/dev/null || true
    iptables -t nat -F && iptables -t nat -X 2>/dev/null || true
    iptables -t mangle -F && iptables -t mangle -X 2>/dev/null || true
    iptables -t raw -F && iptables -t raw -X 2>/dev/null || true
    iptables -t security -F && iptables -t security -X 2>/dev/null || true
    
    # 清理ipvs规则
    if command -v ipvsadm &>/dev/null; then
        log_info "清理ipvs规则..."
        ipvsadm --clear 2>/dev/null || true
    fi
    
    log_success "K8s目录和配置已清理"
    echo "K8s目录和配置已清理" >> "$REPORT_FILE"
}

# 步骤4: 卸载kubeadm/kubelet/kubectl
rollback_k8s_packages() {
    log_step "步骤4/6: 卸载kubeadm/kubelet/kubectl"
    
    # 停止kubelet
    if systemctl is-active --quiet kubelet 2>/dev/null; then
        systemctl stop kubelet
        systemctl disable kubelet 2>/dev/null || true
    fi
    
    # 清理K8s yum/apt仓库配置
    log_info "清理K8s软件仓库配置..."
    rm -f /etc/yum.repos.d/kubernetes.repo 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/kubernetes.list 2>/dev/null || true
    
    # 卸载软件包
    if command -v yum &>/dev/null; then
        log_info "使用yum卸载..."
        yum remove -y kubelet kubeadm kubectl 2>/dev/null || log_warn "yum卸载失败"
        yum clean all 2>/dev/null || true
    elif command -v apt-get &>/dev/null; then
        log_info "使用apt卸载..."
        apt-get remove -y kubelet kubeadm kubectl 2>/dev/null || log_warn "apt卸载失败"
        apt-get autoremove -y 2>/dev/null || true
    fi
    
    log_success "K8s软件包已卸载"
    echo "K8s软件包已卸载" >> "$REPORT_FILE"
}

# 步骤5: 恢复Docker/containerd配置
restore_runtime() {
    log_step "步骤5/6: 恢复容器运行时配置"
    
    # 恢复containerd配置
    if [[ -f /etc/containerd/config.toml.bak ]] || [[ -f /etc/containerd/config.toml.default ]]; then
        log_info "恢复containerd配置..."
        if [[ -f /etc/containerd/config.toml.bak ]]; then
            cp /etc/containerd/config.toml.bak /etc/containerd/config.toml
        fi
        systemctl restart containerd 2>/dev/null || true
        log_success "containerd配置已恢复"
    fi
    
    # 恢复Docker配置
    if [[ -f /etc/docker/daemon.json.bak ]]; then
        log_info "恢复Docker配置..."
        cp /etc/docker/daemon.json.bak /etc/docker/daemon.json
        systemctl restart docker 2>/dev/null || true
        log_success "Docker配置已恢复"
    fi
    
    # 恢复K8s相关内核参数
    sysctl --system 2>/dev/null || true
    
    log_success "容器运行时配置已恢复"
    echo "容器运行时配置已恢复" >> "$REPORT_FILE"
}

# 步骤6: 验证回滚
verify_rollback() {
    log_step "步骤6/6: 验证回滚结果"
    
    local errors=0
    
    # 验证K8s集群是否已重置
    if command -v kubectl &>/dev/null; then
        if kubectl cluster-info &>/dev/null 2>&1; then
            log_error "K8s集群仍在运行!"
            ((errors++))
        else
            log_success "K8s集群已重置"
        fi
    else
        log_success "kubectl已卸载"
    fi
    
    # 验证kubelet
    if systemctl is-active --quiet kubelet 2>/dev/null; then
        log_error "kubelet仍在运行!"
        ((errors++))
    else
        log_success "kubelet已停止"
    fi
    
    # 验证配置目录已清理
    if [[ -d /etc/kubernetes ]]; then
        log_error "/etc/kubernetes目录仍存在!"
        ((errors++))
    else
        log_success "/etc/kubernetes已清理"
    fi
    
    # 验证containerd
    if systemctl is-active --quiet containerd 2>/dev/null; then
        log_success "containerd正常运行"
    else
        log_warn "containerd未运行"
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
    echo "阶段2回滚报告" >> "$REPORT_FILE"
    echo "========================================" >> "$REPORT_FILE"
    echo "回滚时间: $(date '+%Y-%m-%d %H:%M:%S')" >> "$REPORT_FILE"
    echo "回滚耗时: ${duration}秒" >> "$REPORT_FILE"
    echo "操作主机: $(hostname)" >> "$REPORT_FILE"
    echo "日志文件: $LOG_FILE" >> "$REPORT_FILE"
    echo "========================================" >> "$REPORT_FILE"
    
    log_header "阶段2回滚完成"
    log_info "总耗时: ${duration}秒"
    log_info "回滚报告: $REPORT_FILE"
    log_info "详细日志: $LOG_FILE"
}

# ========================= 主逻辑 =========================
main() {
    init
    confirm_rollback
    
    rollback_calico
    reset_k8s_cluster
    cleanup_k8s_dirs
    rollback_k8s_packages
    restore_runtime
    verify_rollback
    generate_report
}

main "$@"
