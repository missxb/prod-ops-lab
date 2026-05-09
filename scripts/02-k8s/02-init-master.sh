#!/usr/bin/env bash
###############################################################################
# 02-init-master.sh - 初始化 Kubernetes Master 节点
# 支持单Master和多Master HA模式
###############################################################################
set -euo pipefail
umask 077

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN:${NC} $*"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*" >&2; }

trap 'err "Master初始化失败 (行 $LINENO)"; exit 1' ERR

K8S_VERSION="${K8S_VERSION:-1.28}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
CLUSTER_NAME="${CLUSTER_NAME:-enterprise-k8s}"
VIP="${VIP:-}"
MASTER_IPS="${MASTER_IPS:-}"
CONFIG_DIR="/root/enterprise-cloud-native-platform/configs/k8s"

# 获取本机IP
HOST_IP=$(hostname -I | awk '{print $1}')
log "本机IP: ${HOST_IP}"

# ============================================================
# 生成 kubeadm 配置
# ============================================================
log "生成 kubeadm 配置..."

mkdir -p /etc/kubernetes/pki

# 从模板生成配置
if [[ -f "${CONFIG_DIR}/kubeadm-config.yaml" ]]; then
    cp "${CONFIG_DIR}/kubeadm-config.yaml" /tmp/kubeadm-config.yaml
    # 替换变量
    sed -i "s|__POD_CIDR__|${POD_CIDR}|g" /tmp/kubeadm-config.yaml
    sed -i "s|__SERVICE_CIDR__|${SERVICE_CIDR}|g" /tmp/kubeadm-config.yaml
    sed -i "s|__HOST_IP__|${HOST_IP}|g" /tmp/kubeadm-config.yaml
    sed -i "s|__K8S_VERSION__|v${K8S_VERSION}.0|g" /tmp/kubeadm-config.yaml
    sed -i "s|__CLUSTER_NAME__|${CLUSTER_NAME}|g" /tmp/kubeadm-config.yaml
else
    # 直接生成配置
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

log "kubeadm配置已生成"

# ============================================================
# 多Master HA: 配置control-plane endpoint
# ============================================================
if [[ -n "${MASTER_IPS}" ]]; then
    log "多Master HA模式"
    FIRST_MASTER=$(echo "${MASTER_IPS}" | cut -d',' -f1)
    if [[ -n "${VIP}" ]]; then
        CONTROL_PLANE_ENDPOINT="${VIP}:6443"
    else
        CONTROL_PLANE_ENDPOINT="${FIRST_MASTER}:6443"
    fi
    # 更新配置中的 controlPlaneEndpoint
    sed -i "s|controlPlaneEndpoint:.*|controlPlaneEndpoint: \"${CONTROL_PLANE_ENDPOINT}\"|" /tmp/kubeadm-config.yaml
    log "Control Plane Endpoint: ${CONTROL_PLANE_ENDPOINT}"
fi

# ============================================================
# kubeadm init
# ============================================================
log "执行 kubeadm init..."

kubeadm init \
    --config /tmp/kubeadm-config.yaml \
    --upload-certs \
    --skip-phases=addon/kube-proxy \
    --v=5 2>&1 | tee /var/log/kubeadm-init.log

# ============================================================
# 配置 kubectl
# ============================================================
log "配置 kubectl..."
mkdir -p $HOME/.kube
cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# 等待API Server就绪
log "等待API Server就绪..."
for i in $(seq 1 60); do
    if kubectl get nodes &>/dev/null; then
        log "API Server就绪"
        break
    fi
    if [[ $i -eq 60 ]]; then
        err "API Server 60秒内未就绪"
        exit 1
    fi
    sleep 1
done

# ============================================================
# 生成 Worker 加入命令
# ============================================================
log "生成Worker加入命令..."
JOIN_CMD=$(kubeadm token create --print-join-command 2>/dev/null || echo "")
if [[ -n "${JOIN_CMD}" ]]; then
    echo "${JOIN_CMD}" > /tmp/k8s-join-command.sh
    chmod 600 /tmp/k8s-join-command.sh
    log "加入命令已保存到 /tmp/k8s-join-command.sh"
fi

# ============================================================
# 生成额外Master加入证书
# ============================================================
if [[ -n "${MASTER_IPS}" ]]; then
    log "生成控制平面证书密钥..."
    CERT_KEY=$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1 || echo "")
    if [[ -n "${CERT_KEY}" ]]; then
        log "证书密钥: ${CERT_KEY}"
        # 保存加入命令 (带证书密钥)
        MASTER_JOIN_CMD=$(kubeadm token create --print-join-command --certificate-key "${CERT_KEY}" 2>/dev/null || echo "")
        echo "${MASTER_JOIN_CMD}" > /tmp/k8s-master-join-command.sh
        chmod 600 /tmp/k8s-master-join-command.sh
    fi
fi

# 显示节点状态
log "节点状态:"
kubectl get nodes -o wide

log "Master节点初始化完成"
log "下一步: 安装网络插件 (Calico)"
