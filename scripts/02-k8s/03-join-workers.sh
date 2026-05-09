#!/usr/bin/env bash
###############################################################################
# 脚本名称: 03-join-workers.sh
# 功能描述: Worker节点加入Kubernetes集群，支持本地和远程批量加入
# 适用系统: Ubuntu 20.04/22.04, CentOS 7/8, Rocky Linux 8/9, RHEL 8/9
# 依赖条件: root权限, kubeadm已安装, Master节点已初始化
# 作者: 运维平台团队
# 版本: 1.1.0
# 创建日期: 2026-05-09
# 更新日期: 2026-05-09
#
# 使用方法:
#   ./03-join-workers.sh                                    # 本地模式
#   WORKER_IPS=10.0.0.11,10.0.0.12 ./03-join-workers.sh    # 远程批量模式
#   WORKER_IPS=10.0.0.11 SSH_USER=admin SSH_KEY=/path/to/key ./03-join-workers.sh
#
# 环境变量:
#   WORKER_IPS      - Worker节点IP列表，逗号分隔 (远程模式)
#   MASTER_IPS      - Master节点IP列表，逗号分隔 (远程模式)
#   SSH_USER        - SSH用户名 (默认: root)
#   SSH_KEY         - SSH私钥路径 (可选)
#
# 模式说明:
#   - 本地模式: 当前节点即为Worker，从/tmp/k8s-join-command.sh读取加入命令
#   - 远程模式: 从Master获取加入命令，批量在Worker上执行
###############################################################################
set -euo pipefail
umask 077

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/02-k8s"
LOG_FILE="${LOG_DIR}/03-join-workers_$(date +%Y%m%d_%H%M%S).log"
LOCK_FILE="/var/lock/03-join-workers.lock"

MASTER_IPS="${MASTER_IPS:-}"
WORKER_IPS="${WORKER_IPS:-}"
SSH_USER="${SSH_USER:-root}"
SSH_KEY="${SSH_KEY:-}"

# SSH连接选项 (禁用主机密钥检查，设置超时)
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
[[ -n "${SSH_KEY}" ]] && SSH_OPTS+=" -i ${SSH_KEY}"

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
        log_error "Worker加入失败，退出码: $exit_code (行 $LINENO)"
        log_error "请检查日志: $LOG_FILE"
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

# SSH远程执行命令
remote_exec() {
    local host="$1"; shift
    ssh ${SSH_OPTS} "${SSH_USER}@${host}" "$@"
}

# ========================= 核心功能函数 =========================

# 本地模式: 当前节点作为Worker加入集群
# 等待Master生成join命令后执行
local_join() {
    local join_script="/tmp/k8s-join-command.sh"
    local max_wait=120
    local waited=0

    log_step "本地模式: 等待Master生成加入命令"

    while [[ ! -f "${join_script}" ]]; do
        sleep 2
        waited=$((waited + 2))
        if [[ ${waited} -ge ${max_wait} ]]; then
            log_error "超时: ${max_wait}秒内未检测到 ${join_script}"
            log_error "请确保Master节点已初始化并生成了加入命令"
            log_error "排查步骤:"
            log_error "  1. 检查Master节点是否运行: ssh master 'ls -la /tmp/k8s-join-command.sh'"
            log_error "  2. 手动生成join命令: kubeadm token create --print-join-command"
            exit 1
        fi
    done

    log_info "检测到加入命令: $(cat ${join_script})"

    # 执行加入命令
    if eval "$(cat ${join_script})"; then
        log_success "Worker节点加入完成"
    else
        log_error "Worker节点加入失败"
        log_error "排查步骤:"
        log_error "  1. 检查kubeadm日志: journalctl -u kubelet -f"
        log_error "  2. 检查容器运行时: systemctl status containerd"
        return 1
    fi
}

# 远程模式: 批量将Worker节点加入集群
remote_join() {
    local first_master
    first_master=$(echo "${MASTER_IPS}" | cut -d',' -f1)

    log_step "远程模式: 从Master(${first_master})获取join命令"

    # 验证Master可达性
    if ! remote_exec "${first_master}" "echo ok" &>/dev/null; then
        log_error "无法连接到Master节点: ${first_master}"
        log_error "请检查SSH配置和网络连接"
        exit 1
    fi
    log_success "Master节点 ${first_master} SSH可达"

    # 获取join命令
    local join_cmd
    join_cmd=$(remote_exec "${first_master}" "cat /tmp/k8s-join-command.sh 2>/dev/null || kubeadm token create --print-join-command")

    if [[ -z "${join_cmd}" ]]; then
        log_error "无法获取join命令"
        log_error "请确保Master节点已初始化: 运行02-init-master.sh"
        exit 1
    fi

    log_info "Join命令: ${join_cmd}"

    # 计数器
    local total=0 success=0 failed=0
    local failed_nodes=()

    for ip in ${WORKER_IPS//,/ }; do
        total=$((total + 1))
        log_info "将 ${ip} 加入集群..."

        # 验证Worker可达性
        if ! ping -c 1 -W 3 "${ip}" &>/dev/null && \
           ! remote_exec "${ip}" "echo ok" &>/dev/null; then
            log_error "  ${ip} 不可达，跳过"
            failed=$((failed + 1))
            failed_nodes+=("${ip}")
            continue
        fi

        # 在Worker上执行join命令
        if remote_exec "${ip}" "${join_cmd}" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "  ${ip} 加入成功"
            success=$((success + 1))
        else
            log_warn "  ${ip} 加入失败"
            failed=$((failed + 1))
            failed_nodes+=("${ip}")
        fi
    done

    # 显示汇总
    echo ""
    log_step "加入结果汇总"
    log_info "总计: ${total} | 成功: ${success} | 失败: ${failed}"

    if [[ ${failed} -gt 0 ]]; then
        log_warn "失败节点: ${failed_nodes[*]}"
        log_warn "请检查失败节点的日志和网络连接"
    fi

    # 验证所有Worker节点状态
    log_step "验证集群节点状态"
    if command -v kubectl &>/dev/null; then
        kubectl get nodes -o wide 2>&1 | tee -a "$LOG_FILE" || true
    else
        log_info "kubectl不可用，请在Master节点上验证: kubectl get nodes -o wide"
    fi
}

# ========================= 主逻辑 =========================
main() {
    mkdir -p "$LOG_DIR"
    check_root
    check_lock

    log_step "阶段2-任务3: Worker节点加入集群"

    if [[ -n "${WORKER_IPS}" ]]; then
        # 远程模式: 批量加入Worker
        log_info "模式: 远程批量加入"
        log_info "Worker节点: ${WORKER_IPS}"
        remote_join
    elif [[ -f "/tmp/k8s-join-command.sh" ]]; then
        # 本地模式: 当前节点作为Worker
        log_info "模式: 本地加入"
        local_join
    else
        # 无配置模式: 提供手动加入指引
        log_warn "未指定Worker节点且未检测到join命令"
        log_info "如需手动加入，请在Worker节点上执行以下步骤:"
        log_info "  1. 安装kubeadm: 运行01-install-kubeadm.sh"
        log_info "  2. 从Master获取join命令: kubeadm token create --print-join-command"
        log_info "  3. 在Worker上执行join命令"
        log_info "  4. 或手动指定: kubeadm join <master-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>"
    fi

    log_success "阶段2-任务3完成"
}

main "$@"
