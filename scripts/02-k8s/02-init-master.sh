#!/usr/bin/env bash
###############################################################################
# 脚本名称: 02-init-master.sh
# 功能描述: 初始化Kubernetes Master节点，支持单Master和多Master HA模式
# 适用系统: Ubuntu 20.04/22.04, CentOS 7/8, Rocky Linux 8/9, RHEL 8/9
# 依赖条件: root权限, kubeadm已安装, 网络连接
# 作者: 运维平台团队
# 版本: 1.1.0
# 创建日期: 2026-05-09
# 更新日期: 2026-05-09
#
# 使用方法:
#   ./02-init-master.sh                                     # 默认单Master模式
#   K8S_VERSION=1.29 POD_CIDR=10.244.0.0/16 ./02-init-master.sh  # 自定义参数
#   MASTER_IPS=10.0.0.1,10.0.0.2 VIP=10.0.0.100 ./02-init-master.sh  # HA模式
#
# 环境变量:
#   K8S_VERSION     - Kubernetes版本 (默认: 1.28)
#   POD_CIDR        - Pod网络CIDR (默认: 10.244.0.0/16)
#   SERVICE_CIDR    - Service网络CIDR (默认: 10.96.0.0/12)
#   CLUSTER_NAME    - 集群名称 (默认: enterprise-k8s)
#   MASTER_IPS      - Master节点IP列表，逗号分隔 (HA模式)
#   VIP             - 虚拟IP地址 (HA模式)
#
# 功能说明:
#   1. 生成kubeadm配置文件
#   2. 配置多Master HA (可选)
#   3. 执行kubeadm init初始化集群
#   4. 配置kubectl访问
#   5. 生成Worker节点加入命令
#   6. 生成额外Master加入命令 (HA模式)
###############################################################################
set -euo pipefail
umask 077

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/02-k8s"
LOG_FILE="${LOG_DIR}/02-init-master_$(date +%Y%m%d_%H%M%S).log"
LOCK_FILE="/var/lock/02-init-master.lock"
CONFIG_DIR="${PROJECT_ROOT}/configs/k8s"

# 配置变量（可通过环境变量覆盖）
K8S_VERSION="${K8S_VERSION:-1.28}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
CLUSTER_NAME="${CLUSTER_NAME:-enterprise-k8s}"
VIP="${VIP:-}"
MASTER_IPS="${MASTER_IPS:-}"

# 获取本机IP (用于集群通信)
HOST_IP=$(hostname -I | awk '{print $1}')

# ========================= 颜色定义 =========================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# ========================= 日志函数 =========================
log_info()    { echo -e "${GREEN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >&2; }
log_step()    { echo -e "${CYAN}[STEP]${NC}  $(date '+%Y-%m-%d %H:%M:%S') === $* ===" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }

# ========================= 错误处理 =========================
cleanup() {
    local exit_code=$?
    rm -f "$LOCK_FILE"
    if [[ $exit_code -ne 0 ]]; then
        log_error "Master初始化失败，退出码: $exit_code (行 $LINENO)"
        log_error "请检查日志: $LOG_FILE"
        log_error "常见问题排查:"
        log_error "  1. 检查containerd是否运行: systemctl status containerd"
        log_error "  2. 检查swap是否已关闭: swapon --show"
        log_error "  3. 检查kubeadm日志: journalctl -u kubelet"
    fi
    return $exit_code
}
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

# 预检: 验证Master初始化的前置条件
preflight_check() {
    log_step "前置条件检查"

    # 检查kubeadm是否已安装
    if ! command -v kubeadm &>/dev/null; then
        log_error "kubeadm未安装，请先运行01-install-kubeadm.sh"
        exit 1
    fi
    log_success "kubeadm已安装: $(kubeadm version -o short 2>/dev/null)"

    # 检查containerd是否运行
    if ! systemctl is-active containerd &>/dev/null; then
        log_error "containerd未运行，请先启动: systemctl start containerd"
        exit 1
    fi
    log_success "containerd服务运行正常"

    # 检查swap是否已关闭
    if swapon --show | grep -q "."; then
        log_error "Swap仍然启用，Kubernetes要求关闭Swap"
        log_error "请执行: swapoff -a && sed -i '/swap/s/^/#/' /etc/fstab"
        exit 1
    fi
    log_success "Swap已关闭"

    # 检查本机IP
    if [[ -z "$HOST_IP" ]]; then
        log_error "无法获取本机IP地址"
        exit 1
    fi
    log_success "本机IP: ${HOST_IP}"

    # 检查端口6443是否可用 (API Server)
    if ss -tlnp | grep -q ":6443 "; then
        log_warn "端口6443已被占用，可能影响API Server启动"
    else
        log_success "端口6443可用"
    fi
}

# ========================= 核心功能函数 =========================

# 生成kubeadm配置文件
# 支持从模板文件生成或直接内联生成
generate_kubeadm_config() {
    log_step "生成kubeadm配置"

    mkdir -p /etc/kubernetes/pki

    # 从模板生成配置 (如果存在)
    if [[ -f "${CONFIG_DIR}/kubeadm-config.yaml" ]]; then
        log_info "使用配置模板: ${CONFIG_DIR}/kubeadm-config.yaml"
        cp "${CONFIG_DIR}/kubeadm-config.yaml" /tmp/kubeadm-config.yaml
        # 替换模板变量
        sed -i "s|__POD_CIDR__|${POD_CIDR}|g" /tmp/kubeadm-config.yaml
        sed -i "s|__SERVICE_CIDR__|${SERVICE_CIDR}|g" /tmp/kubeadm-config.yaml
        sed -i "s|__HOST_IP__|${HOST_IP}|g" /tmp/kubeadm-config.yaml
        sed -i "s|__K8S_VERSION__|v${K8S_VERSION}.0|g" /tmp/kubeadm-config.yaml
        sed -i "s|__CLUSTER_NAME__|${CLUSTER_NAME}|g" /tmp/kubeadm-config.yaml
    else
        # 直接生成配置 (默认模式)
        log_info "使用默认配置模板"
        cat > /tmp/kubeadm-config.yaml <<YAMLEOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${HOST_IP}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
clusterName: ${CLUSTER_NAME}
kubernetesVersion: v${K8S_VERSION}.0
controlPlaneEndpoint: "${HOST_IP}:6443"
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SERVICE_CIDR}
  dnsDomain: cluster.local
apiServer:
  extraArgs:
    enable-admission-plugins: "NamespaceLifecycle,LimitRanger,ServiceAccount,DefaultStorageClass,DefaultTolerationSeconds,MutatingAdmissionWebhook,ValidatingAdmissionWebhook,ResourceQuota"
  timeoutForControlPlane: 5m0s
controllerManager:
  extraArgs:
    horizontal-pod-autoscaler-sync-period: "15s"
    horizontal-pod-autoscaler-downscale-stabilization: "2m0s"
scheduler:
  extraArgs:
    profiling: "false"
dns:
  imageRepository: registry.k8s.io/coredns
etcd:
  local:
    dataDir: /var/lib/etcd
imageRepository: registry.k8s.io
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
containerRuntimeEndpoint: unix:///var/run/containerd/containerd.sock
failSwapOn: true
serializeImagePulls: false
readOnlyPort: 0
clusterDNS:
  - 10.96.0.10
clusterDomain: cluster.local
maxPods: 110
resolvConf: /run/systemd/resolve/resolv.conf
runtimeRequestTimeout: "15m"
YAMLEOF
    fi

    # 验证配置文件生成
    if [[ ! -f /tmp/kubeadm-config.yaml ]]; then
        log_error "kubeadm配置文件生成失败"
        return 1
    fi
    log_success "kubeadm配置已生成: /tmp/kubeadm-config.yaml"
}

# 配置多Master HA模式
# 设置control-plane endpoint为VIP或第一个Master IP
configure_ha_mode() {
    if [[ -n "${MASTER_IPS}" ]]; then
        log_step "配置多Master HA模式"
        local first_master
        first_master=$(echo "${MASTER_IPS}" | cut -d',' -f1)

        if [[ -n "${VIP}" ]]; then
            CONTROL_PLANE_ENDPOINT="${VIP}:6443"
            log_info "使用虚拟IP: ${VIP}"
        else
            CONTROL_PLANE_ENDPOINT="${first_master}:6443"
            log_info "使用第一个Master IP: ${first_master}"
        fi

        # 更新配置中的controlPlaneEndpoint
        sed -i "s|controlPlaneEndpoint:.*|controlPlaneEndpoint: \"${CONTROL_PLANE_ENDPOINT}\"|" /tmp/kubeadm-config.yaml
        log_success "Control Plane Endpoint: ${CONTROL_PLANE_ENDPOINT}"
    fi
}

# 执行kubeadm init初始化集群
# 这是最关键的步骤，初始化etcd、API Server、Controller Manager、Scheduler
init_cluster() {
    log_step "执行kubeadm init"

    log_info "初始化参数:"
    log_info "  Kubernetes版本: v${K8S_VERSION}.0"
    log_info "  Pod CIDR: ${POD_CIDR}"
    log_info "  Service CIDR: ${SERVICE_CIDR}"
    log_info "  集群名称: ${CLUSTER_NAME}"
    log_info "  本机IP: ${HOST_IP}"

    # 执行初始化 (跳过kube-proxy，Calico会替代)
    kubeadm init \
        --config /tmp/kubeadm-config.yaml \
        --upload-certs \
        --skip-phases=addon/kube-proxy \
        --v=5 2>&1 | tee /var/log/kubeadm-init.log | tee -a "$LOG_FILE"

    # 验证初始化结果
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        log_error "kubeadm init失败，请检查日志: /var/log/kubeadm-init.log"
        return 1
    fi

    log_success "kubeadm init执行成功"
}

# 配置kubectl访问集群
configure_kubectl() {
    log_step "配置kubectl"

    mkdir -p $HOME/.kube

    # 备份旧配置
    if [[ -f $HOME/.kube/config ]]; then
        cp -f $HOME/.kube/config "$HOME/.kube/config.bak.$(date +%Y%m%d)" 2>/dev/null || true
    fi

    cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config

    # 验证kubectl配置
    if kubectl cluster-info &>/dev/null; then
        log_success "kubectl配置成功，可以访问集群"
    else
        log_error "kubectl配置失败，无法访问集群"
        return 1
    fi
}

# 等待API Server就绪
wait_for_apiserver() {
    log_step "等待API Server就绪"

    local max_wait=120
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        if kubectl get nodes &>/dev/null; then
            log_success "API Server已就绪 (等待${waited}秒)"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done

    log_error "API Server在${max_wait}秒内未就绪"
    log_error "排查步骤:"
    log_error "  1. 检查kubelet: journalctl -u kubelet -f"
    log_error "  2. 检查容器: crictl ps"
    log_error "  3. 检查日志: cat /var/log/kubeadm-init.log"
    return 1
}

# 生成Worker节点加入命令
generate_join_command() {
    log_step "生成Worker加入命令"

    local join_cmd
    join_cmd=$(kubeadm token create --print-join-command 2>/dev/null || echo "")

    if [[ -n "${join_cmd}" ]]; then
        echo "${join_cmd}" > /tmp/k8s-join-command.sh
        chmod 600 /tmp/k8s-join-command.sh
        log_success "Worker加入命令已保存: /tmp/k8s-join-command.sh"
        log_info "加入命令: ${join_cmd}"
    else
        log_error "无法生成Worker加入命令"
        return 1
    fi
}

# 生成额外Master加入命令 (HA模式)
generate_master_join_command() {
    if [[ -n "${MASTER_IPS}" ]]; then
        log_step "生成控制平面加入命令 (HA模式)"

        local cert_key
        cert_key=$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1 || echo "")

        if [[ -n "${cert_key}" ]]; then
            log_info "证书密钥: ${cert_key}"

            # 生成带证书密钥的加入命令
            local master_join_cmd
            master_join_cmd=$(kubeadm token create --print-join-command --certificate-key "${cert_key}" 2>/dev/null || echo "")

            if [[ -n "${master_join_cmd}" ]]; then
                echo "${master_join_cmd}" > /tmp/k8s-master-join-command.sh
                chmod 600 /tmp/k8s-master-join-command.sh
                log_success "Master加入命令已保存: /tmp/k8s-master-join-command.sh"
            else
                log_error "无法生成Master加入命令"
                return 1
            fi
        else
            log_error "无法获取证书密钥"
            return 1
        fi
    fi
}

# 显示节点状态
show_node_status() {
    log_step "集群节点状态"
    kubectl get nodes -o wide 2>&1 | tee -a "$LOG_FILE" || true
}

# ========================= 主逻辑 =========================
main() {
    mkdir -p "$LOG_DIR"
    check_root
    check_lock

    log_step "阶段2-任务2: Kubernetes Master节点初始化"
    log_info "本机IP: ${HOST_IP}"
    log_info "Kubernetes版本: v${K8S_VERSION}.0"

    # 前置检查
    preflight_check

    # 生成kubeadm配置
    generate_kubeadm_config

    # 配置HA模式 (如果指定了MASTER_IPS)
    configure_ha_mode

    # 执行集群初始化
    init_cluster

    # 配置kubectl
    configure_kubectl

    # 等待API Server就绪
    wait_for_apiserver

    # 生成加入命令
    generate_join_command

    # 生成Master加入命令 (HA模式)
    generate_master_join_command

    # 显示节点状态
    show_node_status

    log_success "阶段2-任务2完成: Master节点初始化成功"
    log_info "下一步:"
    log_info "  1. 安装网络插件: 运行04-install-calico.sh"
    log_info "  2. 加入Worker节点: 运行03-join-workers.sh"
}

main "$@"
