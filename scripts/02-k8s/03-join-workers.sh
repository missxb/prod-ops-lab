#!/usr/bin/env bash
###############################################################################
# 03-join-workers.sh - Worker节点加入集群
# 支持批量加入
###############################################################################
set -euo pipefail
umask 077

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN:${NC} $*"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*" >&2; }

trap 'err "Worker加入失败 (行 $LINENO)"; exit 1' ERR

MASTER_IPS="${MASTER_IPS:-}"
WORKER_IPS="${WORKER_IPS:-}"
SSH_USER="${SSH_USER:-root}"
SSH_KEY="${SSH_KEY:-}"

ssh_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
[[ -n "${SSH_KEY}" ]] && ssh_opts+=" -i ${SSH_KEY}"

remote_exec() {
    local host="$1"; shift
    ssh ${ssh_opts} "${SSH_USER}@${host}" "$@"
}

# ============================================================
# 本地模式: 等待Master生成join命令后加入
# ============================================================
local_join() {
    local join_script="/tmp/k8s-join-command.sh"
    local max_wait=120
    local waited=0

    log "等待Master生成加入命令..."

    while [[ ! -f "${join_script}" ]]; do
        sleep 2
        waited=$((waited + 2))
        if [[ ${waited} -ge ${max_wait} ]]; then
            err "超时: ${max_wait}s 未检测到 ${join_script}"
            err "请确保Master节点已初始化并生成了加入命令"
            exit 1
        fi
    done

    log "检测到加入命令: $(cat ${join_script})"
    eval "$(cat ${join_script})"

    log "Worker节点加入完成"
}

# ============================================================
# 远程模式: 批量加入Worker
# ============================================================
remote_join() {
    local first_master
    first_master=$(echo "${MASTER_IPS}" | cut -d',' -f1)

    log "从Master(${first_master})获取join命令..."
    local join_cmd
    join_cmd=$(remote_exec "${first_master}" "cat /tmp/k8s-join-command.sh 2>/dev/null || kubeadm token create --print-join-command")

    if [[ -z "${join_cmd}" ]]; then
        err "无法获取join命令"
        exit 1
    fi

    log "Join命令: ${join_cmd}"

    # 计数器
    local total=0 success=0 failed=0

    for ip in ${WORKER_IPS//,/ }; do
        total=$((total + 1))
        log "将 ${ip} 加入集群..."

        if remote_exec "${ip}" "${join_cmd}" 2>&1; then
            log "  ${ip} 加入成功"
            success=$((success + 1))
        else
            warn "  ${ip} 加入失败"
            failed=$((failed + 1))
        fi
    done

    echo ""
    log "汇总: 总计=${total}, 成功=${success}, 失败=${failed}"
    [[ ${failed} -gt 0 ]] && warn "有 ${failed} 个节点加入失败, 请检查"
}

# ============================================================
# 主流程
# ============================================================
main() {
    log "Worker节点加入集群"

    if [[ -n "${WORKER_IPS}" ]]; then
        # 远程模式
        remote_join
    elif [[ -f "/tmp/k8s-join-command.sh" ]]; then
        # 本地模式: 自己就是Worker
        local_join
    else
        warn "未指定Worker节点且未检测到join命令"
        log "如需手动加入, 请在Worker上运行:"
        log "  1. 安装kubeadm (运行01-install-kubeadm.sh)"
        log "  2. 复制join命令并执行"
        log "  3. 或手动: kubeadm join <master-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>"
    fi

    # 验证节点
    log "当前集群节点:"
    kubectl get nodes -o wide 2>/dev/null || warn "kubectl不可用, 请在Master上验证"
}

main "$@"
