#!/usr/bin/env bash
###############################################################################
# deploy-k8s.sh - Kubernetes 集群主部署脚本
# 支持多Master高可用部署
# Kubernetes v1.28.x | containerd | Calico v3.26.x
###############################################################################
set -euo pipefail
umask 077

# --- 颜色与日志函数 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()   { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"; }
warn()  { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARN:${NC} $*"; }
err()   { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*" >&2; }
info()  { echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $*"; }
banner() { echo -e "${BLUE}$(printf '=%.0s' {1..60})${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}$(printf '=%.0s' {1..60})${NC}"; }

# --- 错误处理 ---
trap 'err "脚本在第 $LINENO 行失败"; exit 1' ERR

# --- 配置变量 ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
K8S_VERSION="${K8S_VERSION:-1.28}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-1.7}"
CALICO_VERSION="${CALICO_VERSION:-3.26}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
CLUSTER_NAME="${CLUSTER_NAME:-enterprise-k8s}"
MASTER_IPS="${MASTER_IPS:-}"    # 逗号分隔: 10.0.0.1,10.0.0.2,10.0.0.3
WORKER_IPS="${WORKER_IPS:-}"    # 逗号分隔
SSH_USER="${SSH_USER:-root}"
SSH_KEY="${SSH_KEY:-}"
VIP="${VIP:-}"                    # 虚拟IP（HA模式）

usage() {
    cat <<EOF
Usage: $0 [选项]

阶段2: Kubernetes 集群部署

步骤:
  1   安装 kubeadm/kubelet/kubectl (所有节点)
  2   初始化 Master 节点
  3   Worker 节点加入集群
  4   安装 Calico 网络插件
  5   验证集群状态

选项:
  --master-ips IP1,IP2,...    Master节点IP (逗号分隔)
  --worker-ips IP1,IP2,...    Worker节点IP (逗号分隔)
  --vip IP                     虚拟IP (HA模式)
  --ssh-user USER              SSH用户名 (默认: root)
  --ssh-key PATH               SSH私钥路径
  --step NUM                    只执行指定步骤 (1-5)
  --step-all                    执行所有步骤 (默认)
  --help                        显示帮助

环境变量:
  K8S_VERSION=1.28              Kubernetes大版本
  POD_CIDR=10.244.0.0/16        Pod网络CIDR
  SERVICE_CIDR=10.96.0.0/12     Service网络CIDR
EOF
}

# --- 参数解析 ---
STEP=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --master-ips) MASTER_IPS="$2"; shift 2 ;;
        --worker-ips) WORKER_IPS="$2"; shift 2 ;;
        --vip)        VIP="$2"; shift 2 ;;
        --ssh-user)   SSH_USER="$2"; shift 2 ;;
        --ssh-key)    SSH_KEY="$2"; shift 2 ;;
        --step)       STEP="$2"; shift 2 ;;
        --step-all)   STEP=""; shift ;;
        --help)       usage; exit 0 ;;
        *)            err "未知参数: $1"; usage; exit 1 ;;
    esac
done

# --- SSH 远程执行函数 ---
ssh_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
[[ -n "${SSH_KEY}" ]] && ssh_opts+=" -i ${SSH_KEY}"

remote_exec() {
    local host="$1"; shift
    ssh ${ssh_opts} "${SSH_USER}@${host}" "$@"
}

copy_file() {
    local host="$1" src="$2" dst="$3"
    scp ${ssh_opts} "${src}" "${SSH_USER}@${host}:${dst}"
}

# --- 环境检查 ---
preflight_check() {
    banner "步骤0: 预检"
    local all_ips
    all_ips=$(echo "${MASTER_IPS},${WORKER_IPS}" | tr ',' '\n' | sort -u)
    [[ -z "${all_ips}" || "${all_ips}" == "," ]] && { err "未指定节点IP"; usage; exit 1; }

    for ip in ${all_ips//,/ }; do
        info "检查节点 ${ip} 可达性..."
        if ping -c 1 -W 3 "${ip}" &>/dev/null; then
            log "  ${ip} 可达"
        else
            warn "  ${ip} 不可达, 尝试SSH..."
            if ssh ${ssh_opts} "${SSH_USER}@${ip}" "echo ok" &>/dev/null; then
                log "  ${ip} SSH可达"
            else
                err "  ${ip} 完全不可达"
                exit 1
            fi
        fi
    done
    log "预检通过"
}

# --- 执行步骤 ---
execute_step() {
    local step_num="$1" label="$2" script="$3"
    local all_ips
    all_ips=$(echo "${MASTER_IPS},${WORKER_IPS}" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')

    banner "步骤${step_num}: ${label}"
    for ip in ${all_ips//,/ }; do
        info "在 ${ip} 上执行 ${script}..."
        copy_file "${ip}" "${SCRIPT_DIR}/${script}" "/tmp/${script}"
        remote_exec "${ip}" "chmod +x /tmp/${script} && /tmp/${script}"
        log "  ${ip} 完成"
    done
}

main() {
    banner "Kubernetes 集群部署 - ${CLUSTER_NAME}"
    log "配置: K8S_VERSION=${K8S_VERSION}, POD_CIDR=${POD_CIDR}, SERVICE_CIDR=${SERVICE_CIDR}"
    log "Master节点: ${MASTER_IPS:-本地}"
    log "Worker节点: ${WORKER_IPS:-无}"

    preflight_check

    # 如果没有远程IP, 使用本地部署
    local all_ips
    all_ips=$(echo "${MASTER_IPS},${WORKER_IPS}" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')

    if [[ -z "${all_ips}" || "${all_ips}" == "," ]]; then
        warn "未指定远程节点, 执行本地部署"
        if [[ -z "${STEP}" || "${STEP}" == "1" ]]; then
            banner "步骤1: 安装kubeadm/kubelet/kubectl"
            bash "${SCRIPT_DIR}/01-install-kubeadm.sh"
        fi
        if [[ -z "${STEP}" || "${STEP}" == "2" ]]; then
            banner "步骤2: 初始化Master节点"
            bash "${SCRIPT_DIR}/02-init-master.sh"
        fi
        if [[ -z "${STEP}" || "${STEP}" == "3" ]]; then
            warn "无Worker节点, 跳过"
        fi
        if [[ -z "${STEP}" || "${STEP}" == "4" ]]; then
            banner "步骤4: 安装Calico网络插件"
            bash "${SCRIPT_DIR}/04-install-calico.sh"
        fi
        if [[ -z "${STEP}" || "${STEP}" == "5" ]]; then
            banner "步骤5: 验证集群状态"
            bash "${SCRIPT_DIR}/05-verify-cluster.sh"
        fi
    else
        # 远程部署模式
        if [[ -z "${STEP}" || "${STEP}" == "1" ]]; then
            execute_step "1" "安装kubeadm/kubelet/kubectl" "01-install-kubeadm.sh"
        fi
        if [[ -z "${STEP}" || "${STEP}" == "2" ]]; then
            banner "步骤2: 初始化Master节点"
            local first_master
            first_master=$(echo "${MASTER_IPS}" | cut -d',' -f1)
            copy_file "${first_master}" "${SCRIPT_DIR}/02-init-master.sh" "/tmp/02-init-master.sh"
            remote_exec "${first_master}" "chmod +x /tmp/02-init-master.sh && MASTER_IPS='${MASTER_IPS}' VIP='${VIP}' bash /tmp/02-init-master.sh"
            log "Master初始化完成"
        fi
        if [[ -z "${STEP}" || "${STEP}" == "3" ]]; then
            if [[ -n "${WORKER_IPS}" ]]; then
                banner "步骤3: Worker节点加入集群"
                local first_master
                first_master=$(echo "${MASTER_IPS}" | cut -d',' -f1)
                # 生成join token
                local join_cmd
                join_cmd=$(remote_exec "${first_master}" "kubeadm token create --print-join-command")
                for ip in ${WORKER_IPS//,/ }; do
                    info "将 ${ip} 加入集群..."
                    remote_exec "${ip}" "${join_cmd}"
                    log "  ${ip} 已加入"
                done
            else
                warn "无Worker节点, 跳过"
            fi
        fi
        if [[ -z "${STEP}" || "${STEP}" == "4" ]]; then
            execute_step "4" "安装Calico网络插件" "04-install-calico.sh"
            local first_master
            first_master=$(echo "${MASTER_IPS}" | cut -d',' -f1)
            copy_file "${first_master}" "${SCRIPT_DIR}/04-install-calico.sh" "/tmp/04-install-calico.sh"
            copy_file "${first_master}" "${PROJECT_ROOT}/configs/calico/calico.yaml" "/tmp/calico.yaml"
            remote_exec "${first_master}" "chmod +x /tmp/04-install-calico.sh && bash /tmp/04-install-calico.sh"
        fi
        if [[ -z "${STEP}" || "${STEP}" == "5" ]]; then
            local first_master
            first_master=$(echo "${MASTER_IPS}" | cut -d',' -f1)
            banner "步骤5: 验证集群状态"
            copy_file "${first_master}" "${SCRIPT_DIR}/05-verify-cluster.sh" "/tmp/05-verify-cluster.sh"
            remote_exec "${first_master}" "chmod +x /tmp/05-verify-cluster.sh && bash /tmp/05-verify-cluster.sh"
        fi
    fi

    banner "部署完成"
    log "Kubernetes集群 ${CLUSTER_NAME} 部署成功"
}

main "$@"
