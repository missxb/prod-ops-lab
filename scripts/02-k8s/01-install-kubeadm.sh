#!/usr/bin/env bash
###############################################################################
# 01-install-kubeadm.sh - 安装 kubeadm/kubelet/kubectl
# 支持 Ubuntu 20.04/22.04 和 RHEL 8/9
###############################################################################
set -euo pipefail
umask 077

# --- 颜色与日志 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN:${NC} $*"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*" >&2; }

trap 'err "安装失败 (行 $LINENO)"; exit 1' ERR

K8S_VERSION="${K8S_VERSION:-1.28}"
OS=$(cat /etc/os-release | grep "^ID=" | cut -d= -f2 | tr -d '"')
OS_VERSION=$(cat /etc/os-release | grep "^VERSION_ID=" | cut -d= -f2 | tr -d '"')

# ============================================================
# 1. 系统准备
# ============================================================
log "步骤1: 系统基础配置"

# 关闭 swap
if swapon --show | grep -q "."; then
    log "关闭 swap..."
    swapoff -a
    sed -i '/swap/s/^/#/' /etc/fstab
fi

# 内核模块
log "加载内核模块..."
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# 内核参数
log "设置内核参数..."
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.conf.all.forwarding        = 1
fs.inotify.max_user_watches         = 1048576
fs.inotify.max_user_instances       = 8192
EOF
sysctl --system

# 禁用 SELinux
if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
    log "禁用 SELinux..."
    setenforce 0
    sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config 2>/dev/null || true
fi

# 防火墙
if systemctl is-active --quiet firewalld 2>/dev/null; then
    log "停止 firewalld..."
    systemctl stop firewalld
    systemctl disable firewalld
fi

# 配置 crictl
log "配置 crictl..."
cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
debug: false
EOF

# ============================================================
# 2. 安装 containerd
# ============================================================
log "步骤2: 安装 containerd"

if [[ "${OS}" == "ubuntu" || "${OS}" == "debian" ]]; then
    # 添加 Docker 源 (containerd from Docker repo)
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq containerd.io

elif [[ "${OS}" == "rhel" || "${OS}" == "centos" || "${OS}" == "rocky" || "${OS}" == "almalinux" ]]; then
    yum install -y yum-utils
    yum-config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
    yum install -y containerd.io
fi

# 配置 containerd 使用 systemd cgroup
log "配置 containerd..."
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
# 使用国内镜像仓库 (可选)
sed -i 's|sandbox_image = "registry.k8s.io/pause:.*"|sandbox_image = "registry.k8s.io/pause:3.9"|' /etc/containerd/config.toml

systemctl daemon-reload
systemctl enable --now containerd
systemctl restart containerd

# ============================================================
# 3. 安装 kubeadm / kubelet / kubectl
# ============================================================
log "步骤3: 安装 kubeadm/kubelet/kubectl v${K8S_VERSION}"

if [[ "${OS}" == "ubuntu" || "${OS}" == "debian" ]]; then
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
        | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
        > /etc/apt/sources.list.d/kubernetes.list
    apt-get update -qq
    apt-get install -y -qq kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl

elif [[ "${OS}" == "rhel" || "${OS}" == "centos" || "${OS}" == "rocky" || "${OS}" == "almalinux" ]]; then
    cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/repodata/repomd.xml.key
EOF
    yum install -y kubelet kubeadm kubectl
    yum versionlock add kubelet kubeadm kubectl
fi

systemctl enable kubelet

log "版本确认:"
kubeadm version
kubelet --version
kubectl version --client 2>/dev/null || true

# ============================================================
# 4. 预拉取镜像
# ============================================================
log "步骤4: 预拉取K8s镜像"
kubeadm config images pull --kubernetes-version "v${K8S_VERSION}.0" 2>/dev/null || \
    warn "镜像拉取可能失败, 将在init时重试"

log "kubeadm/kubelet/kubectl 安装完成"
