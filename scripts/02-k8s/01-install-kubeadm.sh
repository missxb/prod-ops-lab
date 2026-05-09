#!/usr/bin/env bash
###############################################################################
# 脚本名称: 01-install-kubeadm.sh
# 功能描述: 安装 kubeadm/kubelet/kubectl 和 containerd 容器运行时
# 适用系统: Ubuntu 20.04/22.04, CentOS 7/8, Rocky Linux 8/9, RHEL 8/9
# 依赖条件: root权限, 网络连接, 阶段1基础环境初始化已完成
# 作者: 运维平台团队
# 版本: 1.1.0
# 创建日期: 2026-05-09
# 更新日期: 2026-05-09
#
# 使用方法:
#   K8S_VERSION=1.28 ./01-install-kubeadm.sh        # 安装指定版本
#   K8S_VERSION=1.29 ./01-install-kubeadm.sh        # 安装1.29版本
#   ./01-install-kubeadm.sh                          # 安装默认版本(1.28)
#
# 环境变量:
#   K8S_VERSION     - Kubernetes版本 (默认: 1.28)
#
# 功能说明:
#   1. 系统预配置 (swap/内核模块/内核参数/SELinux/防火墙)
#   2. 安装containerd容器运行时
#   3. 安装kubeadm/kubelet/kubectl
#   4. 预拉取K8s核心镜像
###############################################################################
set -euo pipefail
umask 077

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/02-k8s"
LOG_FILE="${LOG_DIR}/01-install-kubeadm_$(date +%Y%m%d_%H%M%S).log"
LOCK_FILE="/var/lock/01-install-kubeadm.lock"

# 配置变量（可通过环境变量覆盖）
K8S_VERSION="${K8S_VERSION:-1.28}"

# ========================= 颜色定义 =========================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# ========================= 日志函数 =========================
# 统一日志格式，同时输出到终端和日志文件
log_info()    { echo -e "${GREEN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >&2; }
log_step()    { echo -e "${CYAN}[STEP]${NC}  $(date '+%Y-%m-%d %H:%M:%S') === $* ===" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }

# ========================= 错误处理 =========================
# 捕获脚本异常退出，记录错误行号并清理锁文件
cleanup() {
    local exit_code=$?
    rm -f "$LOCK_FILE"
    if [[ $exit_code -ne 0 ]]; then
        log_error "脚本执行失败，退出码: $exit_code (行 $LINENO)"
        log_error "请检查日志: $LOG_FILE"
    fi
    return $exit_code
}
trap cleanup EXIT
trap 'log_error "收到信号(SIGINT/SIGTERM)，正在退出..."; exit 1' SIGINT SIGTERM

# ========================= 工具函数 =========================

# 检查是否以root权限运行
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以root权限运行"
        log_error "请使用: sudo $0"
        exit 1
    fi
}

# 检查锁文件，防止并发执行
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

# 检测操作系统类型和版本
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
    log_info "系统版本: ${OS_ID} ${OS_VERSION}"
}

# 检查网络连接（验证是否能访问外部资源）
check_network() {
    log_step "检查网络连接"
    local test_urls=("pkgs.k8s.io" "download.docker.com")
    local all_ok=true

    for url in "${test_urls[@]}"; do
        if curl -sSf --connect-timeout 5 "https://${url}" >/dev/null 2>&1; then
            log_success "网络可达: ${url}"
        else
            log_warn "无法访问: ${url} (可能影响安装)"
            all_ok=false
        fi
    done

    if [[ "$all_ok" == "false" ]]; then
        log_warn "部分网络不可达，安装可能失败"
    fi
}

# 检查系统资源是否满足最低要求
check_system_resources() {
    log_step "检查系统资源"

    # 检查内存 (最低2GB)
    local mem_gb
    mem_gb=$(free -g | awk '/^Mem:/{print $2}')
    if [[ "$mem_gb" -lt 2 ]]; then
        log_warn "系统内存不足2GB (当前: ${mem_gb}GB)，可能影响集群稳定性"
    else
        log_success "系统内存: ${mem_gb}GB"
    fi

    # 检查磁盘空间 (最低20GB)
    local disk_gb
    disk_gb=$(df -BG / | awk 'NR==2{print $4}' | tr -d 'G')
    if [[ "$disk_gb" -lt 20 ]]; then
        log_warn "根分区剩余空间不足20GB (当前: ${disk_gb}GB)"
    else
        log_success "根分区可用空间: ${disk_gb}GB"
    fi

    # 检查CPU核心数 (最低2核)
    local cpu_cores
    cpu_cores=$(nproc)
    if [[ "$cpu_cores" -lt 2 ]]; then
        log_warn "CPU核心数不足2 (当前: ${cpu_cores})"
    else
        log_success "CPU核心数: ${cpu_cores}"
    fi
}

# ========================= 核心安装函数 =========================

# 步骤1: 系统基础配置
# 包括: 关闭swap、加载内核模块、设置内核参数、禁用SELinux、关闭防火墙
system_prerequisites() {
    log_step "步骤1/4: 系统基础配置"

    # 关闭swap (Kubernetes强制要求)
    log_info "检查并关闭Swap..."
    if swapon --show | grep -q "."; then
        log_info "检测到Swap已启用，正在关闭..."
        swapoff -a
        # 持久化：注释/etc/fstab中的swap行
        if grep -q "\sswap\s" /etc/fstab; then
            sed -i '/\sswap\s/s/^/#/' /etc/fstab
            log_success "已关闭Swap并更新/etc/fstab"
        else
            log_success "已关闭Swap"
        fi
    else
        log_success "Swap未启用"
    fi

    # 加载内核模块 (br_netfilter用于桥接网络流量过滤, overlay用于容器存储)
    log_info "加载内核模块..."
    cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
    modprobe overlay 2>/dev/null || log_warn "无法加载overlay模块"
    modprobe br_netfilter 2>/dev/null || log_warn "无法加载br_netfilter模块"
    log_success "内核模块已配置"

    # 设置内核参数 (Kubernetes网络通信所需)
    log_info "设置内核参数..."
    cat > /etc/sysctl.d/k8s.conf <<EOF
# Kubernetes网络参数配置
net.bridge.bridge-nf-call-iptables  = 1    # 桥接网络流量通过iptables过滤
net.bridge.bridge-nf-call-ip6tables = 1    # IPv6桥接网络过滤
net.ipv4.ip_forward                 = 1    # IP转发 (容器间通信)
net.ipv4.conf.all.forwarding        = 1    # 全局IP转发
fs.inotify.max_user_watches         = 1048576  # inotify监控数量
fs.inotify.max_user_instances       = 8192     # inotify实例数量
EOF
    sysctl --system 2>&1 | tee -a "$LOG_FILE" || true

    # 验证关键内核参数
    local ip_forward
    ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
    if [[ "$ip_forward" == "1" ]]; then
        log_success "net.ipv4.ip_forward = 1 (已生效)"
    else
        log_warn "net.ipv4.ip_forward 未生效，可能影响容器网络"
    fi
    log_success "内核参数已配置"

    # 禁用SELinux (Kubernetes不支持Enforcing模式)
    log_info "检查SELinux状态..."
    if command -v getenforce &>/dev/null; then
        local selinux_status
        selinux_status=$(getenforce 2>/dev/null || echo "Disabled")
        if [[ "$selinux_status" != "Disabled" ]]; then
            log_info "SELinux状态: ${selinux_status}，正在禁用..."
            setenforce 0 2>/dev/null || true
            sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config 2>/dev/null || true
            log_success "SELinux已禁用"
        else
            log_success "SELinux已禁用"
        fi
    else
        log_success "SELinux不存在，跳过"
    fi

    # 关闭防火墙 (集群部署阶段建议关闭，生产环境后续配置)
    log_info "检查防火墙状态..."
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        log_warn "firewalld正在运行，集群部署阶段建议关闭"
        systemctl stop firewalld 2>/dev/null || true
        systemctl disable firewalld 2>/dev/null || true
        log_success "已停止并禁用firewalld"
    else
        log_success "firewalld未运行"
    fi

    # 配置crictl (容器运行时接口工具)
    log_info "配置crictl..."
    cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
debug: false
EOF
    log_success "crictl配置完成"

    log_success "系统基础配置完成"
}

# 步骤2: 安装containerd容器运行时
# containerd是Kubernetes推荐的CRI运行时
install_containerd() {
    log_step "步骤2/4: 安装containerd"

    # 检查containerd是否已安装
    if command -v containerd &>/dev/null; then
        local installed_version
        installed_version=$(containerd --version 2>/dev/null || echo "unknown")
        log_info "containerd已安装: ${installed_version}"
        log_success "跳过containerd安装"
    else
        if [[ "${OS_ID}" == "ubuntu" || "${OS_ID}" == "debian" ]]; then
            log_info "在Debian/Ubuntu系统上安装containerd..."
            apt-get update -qq 2>&1 | tee -a "$LOG_FILE"
            apt-get install -y -qq ca-certificates curl gnupg 2>&1 | tee -a "$LOG_FILE"

            # 添加Docker GPG密钥和源 (containerd由Docker仓库提供)
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
            chmod a+r /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
            apt-get update -qq 2>&1 | tee -a "$LOG_FILE"
            apt-get install -y -qq containerd.io 2>&1 | tee -a "$LOG_FILE"

        elif [[ "${OS_ID}" == "rhel" || "${OS_ID}" == "centos" || "${OS_ID}" == "rocky" || "${OS_ID}" == "almalinux" ]]; then
            log_info "在RHEL/CentOS/Rocky系统上安装containerd..."
            yum install -y yum-utils 2>&1 | tee -a "$LOG_FILE"
            yum-config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo 2>&1 | tee -a "$LOG_FILE"
            yum install -y containerd.io 2>&1 | tee -a "$LOG_FILE"
        else
            log_error "不支持的操作系统: ${OS_ID}"
            return 1
        fi

        # 验证containerd安装
        if command -v containerd &>/dev/null; then
            log_success "containerd安装成功: $(containerd --version)"
        else
            log_error "containerd安装失败"
            return 1
        fi
    fi

    # 配置containerd使用systemd cgroup (Kubernetes要求)
    log_info "配置containerd..."
    mkdir -p /etc/containerd

    # 备份原配置
    local backup="/etc/containerd/config.toml.bak.$(date +%Y%m%d)"
    if [[ -f /etc/containerd/config.toml && ! -f "$backup" ]]; then
        cp /etc/containerd/config.toml "$backup"
        log_info "已备份containerd配置: $backup"
    fi

    containerd config default > /etc/containerd/config.toml

    # 设置SystemdCgroup为true (Kubernetes的cgroup驱动需要)
    if grep -q 'SystemdCgroup = false' /etc/containerd/config.toml; then
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
        log_info "已设置containerd SystemdCgroup = true"
    fi

    # 使用国内镜像仓库 (加速sandbox镜像拉取)
    sed -i 's|sandbox_image = "registry.k8s.io/pause:.*"|sandbox_image = "registry.k8s.io/pause:3.9"|' /etc/containerd/config.toml 2>/dev/null || true

    # 启动containerd服务
    systemctl daemon-reload
    systemctl enable --now containerd 2>&1 | tee -a "$LOG_FILE"
    systemctl restart containerd 2>&1 | tee -a "$LOG_FILE"

    # 等待containerd就绪
    local retries=10
    while [[ $retries -gt 0 ]]; do
        if systemctl is-active containerd >/dev/null 2>&1; then
            break
        fi
        retries=$((retries - 1))
        sleep 2
    done

    # 验证containerd服务状态
    if systemctl is-active containerd >/dev/null 2>&1; then
        log_success "containerd服务启动成功"
    else
        log_error "containerd服务启动失败"
        systemctl status containerd --no-pager 2>&1 | tee -a "$LOG_FILE"
        return 1
    fi

    log_success "containerd配置完成"
}

# 步骤3: 安装kubeadm/kubelet/kubectl
# kubeadm: 集群引导工具
# kubelet: 节点代理，管理Pod生命周期
# kubectl: 集群管理命令行工具
install_kubeadm() {
    log_step "步骤3/4: 安装kubeadm/kubelet/kubectl v${K8S_VERSION}"

    # 检查是否已安装且版本满足要求
    if command -v kubeadm &>/dev/null; then
        local installed_version
        installed_version=$(kubeadm version -o short 2>/dev/null | grep -oP 'v[\d.]+' || echo "unknown")
        log_info "kubeadm已安装: ${installed_version}"
        log_success "跳过kubeadm安装"
    else
        if [[ "${OS_ID}" == "ubuntu" || "${OS_ID}" == "debian" ]]; then
            log_info "在Debian/Ubuntu系统上安装kubeadm..."
            curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
                | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null
            echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
                > /etc/apt/sources.list.d/kubernetes.list
            apt-get update -qq 2>&1 | tee -a "$LOG_FILE"
            apt-get install -y -qq kubelet kubeadm kubectl 2>&1 | tee -a "$LOG_FILE"
            apt-mark hold kubelet kubeadm kubectl 2>&1 | tee -a "$LOG_FILE"
            log_info "已设置kubelet/kubeadm/kubectl版本锁定"

        elif [[ "${OS_ID}" == "rhel" || "${OS_ID}" == "centos" || "${OS_ID}" == "rocky" || "${OS_ID}" == "almalinux" ]]; then
            log_info "在RHEL/CentOS/Rocky系统上安装kubeadm..."
            cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/repodata/repomd.xml.key
EOF
            yum install -y kubelet kubeadm kubectl 2>&1 | tee -a "$LOG_FILE"
            yum versionlock add kubelet kubeadm kubectl 2>&1 | tee -a "$LOG_FILE"
            log_info "已设置kubelet/kubeadm/kubectl版本锁定"
        else
            log_error "不支持的操作系统: ${OS_ID}"
            return 1
        fi

        # 验证安装
        if ! command -v kubeadm &>/dev/null; then
            log_error "kubeadm安装失败"
            return 1
        fi
    fi

    # 启用kubelet服务
    systemctl enable kubelet 2>&1 | tee -a "$LOG_FILE" || true

    # 显示版本确认
    log_info "版本确认:"
    kubeadm version 2>&1 | tee -a "$LOG_FILE"
    kubelet --version 2>&1 | tee -a "$LOG_FILE"
    kubectl version --client 2>/dev/null | tee -a "$LOG_FILE" || true

    log_success "kubeadm/kubelet/kubectl安装完成"
}

# 步骤4: 预拉取K8s核心镜像
# 预拉取可以加速后续kubeadm init过程
pull_images() {
    log_step "步骤4/4: 预拉取K8s镜像"

    log_info "预拉取Kubernetes v${K8S_VERSION}.0 核心镜像..."
    if kubeadm config images pull --kubernetes-version "v${K8S_VERSION}.0" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "镜像预拉取成功"
    else
        log_warn "镜像预拉取部分失败，kubeadm init时将重试"
    fi

    # 显示已拉取的镜像列表
    log_info "已拉取的K8s镜像:"
    kubeadm config images list --kubernetes-version "v${K8S_VERSION}.0" 2>/dev/null | tee -a "$LOG_FILE" || true
}

# ========================= 主逻辑 =========================
main() {
    mkdir -p "$LOG_DIR"
    check_root
    check_lock
    detect_os

    log_step "阶段2-任务1: 安装kubeadm/kubelet/kubectl"
    log_info "目标Kubernetes版本: v${K8S_VERSION}"

    # 预检：网络和系统资源
    check_network
    check_system_resources

    # 系统基础配置
    system_prerequisites

    # 安装containerd
    install_containerd

    # 安装kubeadm/kubelet/kubectl
    install_kubeadm

    # 预拉取镜像
    pull_images

    log_success "阶段2-任务1完成: kubeadm/kubelet/kubectl安装成功"
    log_info "下一步: 运行02-init-master.sh初始化Master节点"
}

main "$@"
