#!/usr/bin/env bash
###############################################################################
# 脚本名称: deploy-k8s.sh
# 功能描述: Kubernetes集群主部署脚本，协调所有阶段2子任务的执行
# 适用系统: Ubuntu 20.04/22.04, CentOS 7/8, Rocky Linux 8/9, RHEL 8/9
# 依赖条件: root权限, SSH可达所有节点, 网络连接
# 作者: 运维平台团队
# 版本: 1.1.0
# 创建日期: 2026-05-09
# 更新日期: 2026-05-09
#
# 使用方法:
#   ./deploy-k8s.sh                                          # 本地单节点部署
#   ./deploy-k8s.sh --master-ips 10.0.0.1 --worker-ips 10.0.0.11,10.0.0.12
#   ./deploy-k8s.sh --master-ips 10.0.0.1,10.0.0.2,10.0.0.3 --vip 10.0.0.100
#   ./deploy-k8s.sh --step 1                                # 只执行步骤1
#   ./deploy-k8s.sh --step 2                                # 只执行步骤2
#
# 环境变量:
#   K8S_VERSION     - Kubernetes版本 (默认: 1.28)
#   POD_CIDR        - Pod网络CIDR (默认: 10.244.0.0/16)
#   SERVICE_CIDR    - Service网络CIDR (默认: 10.96.0.0/12)
#   CLUSTER_NAME    - 集群名称 (默认: enterprise-k8s)
#   MASTER_IPS      - Master节点IP (逗号分隔)
#   WORKER_IPS      - Worker节点IP (逗号分隔)
#   SSH_USER        - SSH用户名 (默认: root)
#   SSH_KEY         - SSH私钥路径
#   VIP             - 虚拟IP (HA模式)
#
# 部署步骤:
#   1. 安装kubeadm/kubelet/kubectl (所有节点)
#   2. 初始化Master节点
#   3. Worker节点加入集群
#   4. 安装Calico网络插件
#   5. 验证集群状态
###############################################################################
set -euo pipefail
umask 077

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/02-k8s"
LOG_FILE="${LOG_DIR}/deploy-k8s_$(date +%Y%m%d_%H%M%S).log"
LOCK_FILE="/var/lock/deploy-k8s.lock"
DEPLOY_START=$(date +%s)

# 配置变量（可通过环境变量覆盖）
K8S_VERSION="${K8S_VERSION:-1.28}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-1.7}"
CALICO_VERSION="${CALICO_VERSION:-3.26}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
CLUSTER_NAME="${CLUSTER_NAME:-enterprise-k8s}"
MASTER_IPS="${MASTER_IPS:-}"
WORKER_IPS="${WORKER_IPS:-}"
SSH_USER="${SSH_USER:-root}"
SSH_KEY="${SSH_KEY:-}"
VIP="${VIP:-}"
STEP="${STEP:-}"

# SSH连接选项
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
[[ -n "${SSH_KEY}" ]] && SSH_OPTS+=" -i ${SSH_KEY}"

# ========================= 颜色定义 =========================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

# ========================= 日志函数 =========================
log_info()    { echo -e "${GREEN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >&2; }
log_step()    { echo -e "${CYAN}[STEP]${NC}  $(date '+%Y-%m-%d %H:%M:%S') === $* ===" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }

banner() {
    echo -e "" | tee -a "$LOG_FILE"
    echo -e "${BLUE}$(printf '=%.0s' {1..60})${NC}" | tee -a "$LOG_FILE"
    echo -e "${BLUE}  $*${NC}" | tee -a "$LOG_FILE"
    echo -e "${BLUE}$(printf '=%.0s' {1..60})${NC}" | tee -a "$LOG_FILE"
    echo -e "" | tee -a "$LOG_FILE"
}

# ========================= 错误处理 =========================
cleanup() {
    local exit_code=$?
    rm -f "$LOCK_FILE"
    local end_time=$(date +%s)
    local duration=$((end_time - DEPLOY_START))

    echo "" | tee -a "$LOG_FILE"
    if [[ $exit_code -eq 0 ]]; then
        banner "Kubernetes集群部署成功"
        log_success "集群 ${CLUSTER_NAME} 部署完成"
        log_info "总耗时: ${duration}秒"
        log_info "日志文件: ${LOG_FILE}"
    else
        banner "Kubernetes集群部署失败"
        log_error "部署失败，退出码: $exit_code"
        log_error "请检查日志: ${LOG_FILE}"
        log_error "总耗时: ${duration}秒"
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
            log_error "另一个部署实例正在运行 (PID: $pid)"
            exit 1
        fi
        log_warn "发现残留锁文件，已清理"
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
}

# SSH远程执行命令
remote_exec() {
    local host="$1"; shift
    ssh ${SSH_OPTS} "${SSH_USER}@${host}" "$@"
}

# SCP复制文件到远程节点
copy_file() {
    local host="$1" src="$2" dst="$3"
    scp ${SSH_OPTS} "${src}" "${SSH_USER}@${host}:${dst}"
}

# ========================= 帮助信息 =========================
usage() {
    cat <<EOF
Usage: $0 [选项]

阶段2: Kubernetes集群部署

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

示例:
  $0                                                  # 本地部署
  $0 --master-ips 10.0.0.1 --worker-ips 10.0.0.11    # 远程部署
  $0 --master-ips 10.0.0.1,10.0.0.2 --vip 10.0.0.100 # HA部署
  $0 --step 1                                         # 只执行步骤1
EOF
}

# ========================= 参数解析 =========================
parse_args() {
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
            *)            log_error "未知参数: $1"; usage; exit 1 ;;
        esac
    done
}

# ========================= 预检函数 =========================
preflight_check() {
    banner "步骤0: 预检"

    local all_ips
    all_ips=$(echo "${MASTER_IPS},${WORKER_IPS}" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')

    # 检查是否指定了节点IP
    if [[ -z "${all_ips}" || "${all_ips}" == "," ]]; then
        log_warn "未指定远程节点IP，将执行本地部署"
        return 0
    fi

    log_info "检查所有节点可达性..."

    for ip in ${all_ips//,/ }; do
        log_info "检查节点 ${ip}..."
        if ping -c 1 -W 3 "${ip}" &>/dev/null; then
            log_success "  ${ip} Ping可达"
        elif ssh ${SSH_OPTS} "${SSH_USER}@${ip}" "echo ok" &>/dev/null; then
            log_success "  ${ip} SSH可达"
        else
            log_error "  ${ip} 完全不可达"
            log_error "请检查网络连接和SSH配置"
            exit 1
        fi
    done

    log_success "预检通过"
}

# ========================= 步骤执行函数 =========================

# 在所有节点上执行脚本
execute_step_all_nodes() {
    local step_num="$1" label="$2" script="$3"
    local all_ips
    all_ips=$(echo "${MASTER_IPS},${WORKER_IPS}" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')

    banner "步骤${step_num}: ${label}"

    for ip in ${all_ips//,/ }; do
        log_info "在 ${ip} 上执行 ${script}..."
        copy_file "${ip}" "${SCRIPT_DIR}/${script}" "/tmp/${script}"
        remote_exec "${ip}" "chmod +x /tmp/${script} && /tmp/${script}" 2>&1 | tee -a "$LOG_FILE"
        log_success "  ${ip} 完成"
    done
}

# 本地部署模式
deploy_local() {
    log_info "执行本地部署模式"

    if [[ -z "${STEP}" || "${STEP}" == "1" ]]; then
        banner "步骤1: 安装kubeadm/kubelet/kubectl"
        K8S_VERSION="${K8S_VERSION}" bash "${SCRIPT_DIR}/01-install-kubeadm.sh" 2>&1 | tee -a "$LOG_FILE"
    fi

    if [[ -z "${STEP}" || "${STEP}" == "2" ]]; then
        banner "步骤2: 初始化Master节点"
        K8S_VERSION="${K8S_VERSION}" POD_CIDR="${POD_CIDR}" SERVICE_CIDR="${SERVICE_CIDR}" \
            CLUSTER_NAME="${CLUSTER_NAME}" MASTER_IPS="${MASTER_IPS}" VIP="${VIP}" \
            bash "${SCRIPT_DIR}/02-init-master.sh" 2>&1 | tee -a "$LOG_FILE"
    fi

    if [[ -z "${STEP}" || "${STEP}" == "3" ]]; then
        if [[ -n "${WORKER_IPS}" ]]; then
            banner "步骤3: Worker节点加入集群"
            WORKER_IPS="${WORKER_IPS}" MASTER_IPS="${MASTER_IPS}" \
                bash "${SCRIPT_DIR}/03-join-workers.sh" 2>&1 | tee -a "$LOG_FILE"
        else
            log_warn "无Worker节点, 跳过"
        fi
    fi

    if [[ -z "${STEP}" || "${STEP}" == "4" ]]; then
        banner "步骤4: 安装Calico网络插件"
        CALICO_VERSION="${CALICO_VERSION}" POD_CIDR="${POD_CIDR}" \
            bash "${SCRIPT_DIR}/04-install-calico.sh" 2>&1 | tee -a "$LOG_FILE"
    fi

    if [[ -z "${STEP}" || "${STEP}" == "5" ]]; then
        banner "步骤5: 验证集群状态"
        bash "${SCRIPT_DIR}/05-verify-cluster.sh" 2>&1 | tee -a "$LOG_FILE"
    fi
}

# 远程部署模式
deploy_remote() {
    log_info "执行远程部署模式"
    log_info "Master节点: ${MASTER_IPS}"
    log_info "Worker节点: ${WORKER_IPS:-无}"

    # 步骤1: 在所有节点上安装kubeadm
    if [[ -z "${STEP}" || "${STEP}" == "1" ]]; then
        execute_step_all_nodes "1" "安装kubeadm/kubelet/kubectl" "01-install-kubeadm.sh"
    fi

    # 步骤2: 在第一个Master上初始化集群
    if [[ -z "${STEP}" || "${STEP}" == "2" ]]; then
        banner "步骤2: 初始化Master节点"
        local first_master
        first_master=$(echo "${MASTER_IPS}" | cut -d',' -f1)

        copy_file "${first_master}" "${SCRIPT_DIR}/02-init-master.sh" "/tmp/02-init-master.sh"
        remote_exec "${first_master}" "chmod +x /tmp/02-init-master.sh && MASTER_IPS='${MASTER_IPS}' VIP='${VIP}' bash /tmp/02-init-master.sh" 2>&1 | tee -a "$LOG_FILE"
        log_success "Master初始化完成"
    fi

    # 步骤3: Worker节点加入集群
    if [[ -z "${STEP}" || "${STEP}" == "3" ]]; then
        if [[ -n "${WORKER_IPS}" ]]; then
            banner "步骤3: Worker节点加入集群"
            local first_master
            first_master=$(echo "${MASTER_IPS}" | cut -d',' -f1)

            # 从Master获取join命令
            local join_cmd
            join_cmd=$(remote_exec "${first_master}" "kubeadm token create --print-join-command")

            if [[ -z "${join_cmd}" ]]; then
                log_error "无法获取join命令"
                exit 1
            fi

            local total=0 success=0 failed=0
            for ip in ${WORKER_IPS//,/ }; do
                total=$((total + 1))
                log_info "将 ${ip} 加入集群..."
                if remote_exec "${ip}" "${join_cmd}" 2>&1 | tee -a "$LOG_FILE"; then
                    log_success "  ${ip} 已加入"
                    success=$((success + 1))
                else
                    log_warn "  ${ip} 加入失败"
                    failed=$((failed + 1))
                fi
            done

            log_info "加入汇总: 总计=${total}, 成功=${success}, 失败=${failed}"
        else
            log_warn "无Worker节点, 跳过"
        fi
    fi

    # 步骤4: 安装Calico
    if [[ -z "${STEP}" || "${STEP}" == "4" ]]; then
        banner "步骤4: 安装Calico网络插件"
        local first_master
        first_master=$(echo "${MASTER_IPS}" | cut -d',' -f1)

        copy_file "${first_master}" "${SCRIPT_DIR}/04-install-calico.sh" "/tmp/04-install-calico.sh"
        # 如果有本地calico配置，也复制过去
        if [[ -f "${PROJECT_ROOT}/configs/calico/calico.yaml" ]]; then
            copy_file "${first_master}" "${PROJECT_ROOT}/configs/calico/calico.yaml" "/tmp/calico.yaml"
        fi
        remote_exec "${first_master}" "chmod +x /tmp/04-install-calico.sh && CALICO_VERSION='${CALICO_VERSION}' POD_CIDR='${POD_CIDR}' bash /tmp/04-install-calico.sh" 2>&1 | tee -a "$LOG_FILE"
    fi

    # 步骤5: 验证集群
    if [[ -z "${STEP}" || "${STEP}" == "5" ]]; then
        banner "步骤5: 验证集群状态"
        local first_master
        first_master=$(echo "${MASTER_IPS}" | cut -d',' -f1)

        copy_file "${first_master}" "${SCRIPT_DIR}/05-verify-cluster.sh" "/tmp/05-verify-cluster.sh"
        remote_exec "${first_master}" "chmod +x /tmp/05-verify-cluster.sh && bash /tmp/05-verify-cluster.sh" 2>&1 | tee -a "$LOG_FILE"
    fi
}

# ========================= 主逻辑 =========================
main() {
    mkdir -p "$LOG_DIR"
    check_root
    check_lock

    # 解析命令行参数
    parse_args "$@"

    banner "Kubernetes集群部署 - ${CLUSTER_NAME}"
    log_info "配置信息:"
    log_info "  Kubernetes版本: v${K8S_VERSION}"
    log_info "  Pod CIDR: ${POD_CIDR}"
    log_info "  Service CIDR: ${SERVICE_CIDR}"
    log_info "  集群名称: ${CLUSTER_NAME}"
    log_info "  Master节点: ${MASTER_IPS:-本地}"
    log_info "  Worker节点: ${WORKER_IPS:-无}"

    # 预检
    preflight_check

    # 确定部署模式
    local all_ips
    all_ips=$(echo "${MASTER_IPS},${WORKER_IPS}" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')

    if [[ -z "${all_ips}" || "${all_ips}" == "," ]]; then
        deploy_local
    else
        deploy_remote
    fi

    log_success "阶段2部署完成"
}

main "$@"
