#!/usr/bin/env bash
###############################################################################
# 脚本名称: 07-test-cluster-ha.sh
# 功能描述: 全面测试Kubernetes集群高可用性，验证容错和故障恢复能力
# 适用系统: 需要kubectl可访问集群，etcdctl已安装 (可选)
# 依赖条件: kubectl已配置并能访问集群
# 作者: 运维平台团队
# 版本: 1.1.0
# 创建日期: 2026-05-10
# 更新日期: 2026-05-10
#
# 使用方法:
#   ./07-test-cluster-ha.sh              # 执行完整HA测试
#   ./07-test-cluster-ha.sh --skip-simulate  # 跳过节点故障模拟
#
# 测试项目:
#   1. 所有节点 Ready 状态检查
#   2. etcd 集群健康状态
#   3. API Server 冗余验证
#   4. Pod 跨节点调度测试
#   5. 节点故障模拟测试 (cordon/uncordon)
#   6. 控制平面组件冗余检查
#
# 注意:
#   - 故障模拟测试 (项目5) 会临时 cordon 节点，请在生产环境谨慎使用
#   - 建议先在测试环境执行验证
###############################################################################
set -euo pipefail
umask 077

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/02-k8s"
LOG_FILE="${LOG_DIR}/07-test-cluster-ha_$(date +%Y%m%d_%H%M%S).log"
LOCK_FILE="/var/lock/07-test-cluster-ha.lock"

# 测试配置
SKIP_SIMULATE=false
NODE_CORDONED=""
TEST_DEPLOYMENT="ha-test-deployment-$(date +%s)"
TEST_NAMESPACE="default"

# ========================= 颜色定义 =========================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# ========================= 日志函数 =========================
log_info()    { echo -e "${GREEN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >&2; }
log_step()    { echo -e "${CYAN}[STEP]${NC}  $(date '+%Y-%m-%d %H:%M:%S') === $* ===" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }

# ========================= 验证计数器 =========================
PASSED=0
FAILED=0
WARNINGS=0

check_pass() { echo -e "  ${GREEN}✓ PASS${NC}: $*" | tee -a "$LOG_FILE"; PASSED=$((PASSED + 1)); }
check_fail() { echo -e "  ${RED}✗ FAIL${NC}: $*" | tee -a "$LOG_FILE"; FAILED=$((FAILED + 1)); }
check_warn() { echo -e "  ${YELLOW}⚠ WARN${NC}: $*" | tee -a "$LOG_FILE"; WARNINGS=$((WARNINGS + 1)); }

# ========================= 错误处理 =========================

# 清理测试资源
cleanup_test_resources() {
    log_info "清理测试资源..."

    # 删除测试Deployment
    kubectl delete deployment "$TEST_DEPLOYMENT" -n "$TEST_NAMESPACE" --ignore-not-found &>/dev/null || true

    # 如果有节点被cordon，恢复uncordon
    if [[ -n "$NODE_CORDONED" ]]; then
        kubectl uncordon "$NODE_CORDONED" &>/dev/null || true
        log_info "已恢复节点 ${NODE_CORDONED} 为 schedulable"
    fi
}

cleanup() {
    local exit_code=$?
    cleanup_test_resources
    rm -f "$LOCK_FILE"
    if [[ $exit_code -ne 0 ]]; then
        log_error "脚本执行失败，退出码: $exit_code"
    fi
    return $exit_code
}
trap 'log_error "脚本执行出错，行号: ${LINENO}"' ERR
trap cleanup EXIT
trap 'log_error "收到中断信号，正在清理..."; exit 130' INT TERM

# ========================= 工具函数 =========================

# 锁文件检查
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

# 检查kubectl是否可用
check_kubectl() {
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl未安装"
        exit 1
    fi

    if ! kubectl cluster-info &>/dev/null; then
        log_error "无法连接到Kubernetes集群"
        log_error "请检查kubeconfig配置"
        exit 1
    fi
    log_success "kubectl连接正常"
}

# ========================= HA测试检查函数 =========================

# 1. 所有节点 Ready 状态检查
# 验证集群中所有节点是否处于 Ready 状态
check_nodes_ready() {
    log_step "1. 节点 Ready 状态检查"

    local node_total
    node_total=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)

    if [[ "$node_total" -eq 0 ]]; then
        check_fail "集群中没有任何节点"
        return
    fi
    check_pass "集群节点总数: ${node_total}"

    local all_ready=true
    local ready_count=0

    while IFS= read -r line; do
        local node_name status
        node_name=$(echo "$line" | awk '{print $1}')
        status=$(echo "$line" | awk '{print $2}')

        if [[ "$status" == "Ready" ]]; then
            ready_count=$((ready_count + 1))
            check_pass "节点 ${node_name}: Ready"
        else
            check_fail "节点 ${node_name}: ${status}"
            all_ready=false
        fi
    done < <(kubectl get nodes --no-headers 2>/dev/null)

    if [[ "$all_ready" == "true" ]]; then
        check_pass "所有节点均为 Ready (${ready_count}/${node_total})"
    else
        check_fail "部分节点未 Ready (${ready_count}/${node_total})"
    fi

    # 检查节点是否参与调度
    local unschedulable
    unschedulable=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "SchedulingDisabled" || echo "0")
    if [[ "$unschedulable" -gt 0 ]]; then
        check_warn "${unschedulable} 个节点处于 SchedulingDisabled 状态"
    fi
}

# 2. etcd 集群健康状态
# 验证 etcd 集群是否健康
check_etcd_health() {
    log_step "2. etcd 集群健康状态"

    # 方法1: 通过 kubectl 获取 etcd Pod
    local etcd_pods
    etcd_pods=$(kubectl get pods -n kube-system -l component=etcd --no-headers 2>/dev/null || echo "")

    if [[ -z "$etcd_pods" ]]; then
        # 尝试备用标签
        etcd_pods=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -i "etcd" || echo "")
    fi

    if [[ -z "$etcd_pods" ]]; then
        check_warn "未找到 etcd Pod (可能使用外部etcd集群)"
    else
        local etcd_total etcd_ready
        etcd_total=$(echo "$etcd_pods" | grep -c . || echo "0")
        etcd_ready=$(echo "$etcd_pods" | grep -c "Running" || echo "0")

        if [[ "$etcd_ready" -eq "$etcd_total" ]]; then
            check_pass "etcd Pod: ${etcd_ready}/${etcd_total} Running"
        else
            check_fail "etcd Pod: ${etcd_ready}/${etcd_total} Running"
        fi
    fi

    # 方法2: 通过 etcdctl 检查集群状态 (如果可用)
    if command -v etcdctl &>/dev/null; then
        log_info "使用 etcdctl 检查 etcd 集群健康..."

        # 尝试常见的 etcd 端点
        local etcd_endpoints="https://127.0.0.1:2379"
        local etcd_cacert="/etc/kubernetes/pki/etcd/ca.crt"
        local etcd_cert="/etc/kubernetes/pki/etcd/server.crt"
        local etcd_key="/etc/kubernetes/pki/etcd/server.key"

        local etcd_args=""
        if [[ -f "$etcd_cacert" ]]; then
            etcd_args="--cacert=${etcd_cacert} --cert=${etcd_cert} --key=${etcd_key}"
        fi

        if etcdctl endpoint health --endpoints="$etcd_endpoints" $etcd_args >/dev/null 2>&1; then
            check_pass "etcd 集群健康 (etcdctl 验证)"
            etcdctl endpoint health --endpoints="$etcd_endpoints" $etcd_args 2>&1 | tee -a "$LOG_FILE" || true
        else
            check_warn "etcdctl 不可用或 etcd 不可达 (可能需要证书配置)"
        fi

        # 检查 etcd 成员列表
        if etcdctl member list --endpoints="$etcd_endpoints" $etcd_args >/dev/null 2>&1; then
            local member_count
            member_count=$(etcdctl member list --endpoints="$etcd_endpoints" $etcd_args --write-out=table 2>/dev/null | grep -c "started\|follower\|leader" || echo "0")
            check_pass "etcd 集群成员数: ${member_count}"
            etcdctl member list --endpoints="$etcd_endpoints" $etcd_args --write-out=table 2>&1 | tee -a "$LOG_FILE" || true
        fi
    else
        log_info "etcdctl 未安装，跳过 etcd 集群详细检查"
        log_info "如需安装: yum install -y etcd 或从 https://github.com/etcd-io/etcd/releases 下载"
    fi
}

# 3. API Server 冗余验证
# 检查是否有多个 API Server 实例
check_apiserver_redundancy() {
    log_step "3. API Server 冗余验证"

    local apiserver_pods
    apiserver_pods=$(kubectl get pods -n kube-system -l component=kube-apiserver --no-headers 2>/dev/null || echo "")

    if [[ -z "$apiserver_pods" ]]; then
        apiserver_pods=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -i "kube-apiserver" || echo "")
    fi

    if [[ -z "$apiserver_pods" ]]; then
        check_warn "未找到 kube-apiserver Pod (可能使用外部负载均衡器)"
        return
    fi

    local apiserver_total apiserver_ready
    apiserver_total=$(echo "$apiserver_pods" | grep -c . || echo "0")
    apiserver_ready=$(echo "$apiserver_pods" | grep -c "Running" || echo "0")

    if [[ "$apiserver_total" -gt 1 ]]; then
        check_pass "API Server 冗余: ${apiserver_ready}/${apiserver_total} 实例 (高可用模式)"
    elif [[ "$apiserver_total" -eq 1 ]]; then
        check_warn "API Server 仅1个实例 (建议多master高可用)"
    fi

    if [[ "$apiserver_ready" -eq "$apiserver_total" ]]; then
        check_pass "API Server 全部 Running"
    else
        check_fail "API Server: ${apiserver_ready}/${apiserver_total} Running"
    fi

    # 显示每个API Server的节点分布
    while IFS= read -r line; do
        local pod_name node_name
        pod_name=$(echo "$line" | awk '{print $1}')
        node_name=$(echo "$line" | awk '{print $7}')
        check_pass "API Server ${pod_name} 运行在节点 ${node_name}"
    done <<< "$apiserver_pods"
}

# 4. Pod 跨节点调度测试
# 创建Deployment验证Pod是否分布在多个节点上
check_pod_scheduling() {
    log_step "4. Pod 跨节点调度测试"

    # 获取节点数量
    local node_count
    node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)

    if [[ "$node_count" -lt 2 ]]; then
        check_warn "集群仅有 ${node_count} 个节点，跳过跨节点调度测试"
        return
    fi

    # 清理可能残留的测试Deployment
    kubectl delete deployment "$TEST_DEPLOYMENT" -n "$TEST_NAMESPACE" --ignore-not-found &>/dev/null || true
    sleep 2

    # 创建测试Deployment (3个副本)
    log_info "创建测试Deployment (${TEST_DEPLOYMENT}, 3副本)..."
    cat <<EOF | kubectl apply -n "$TEST_NAMESPACE" -f - >/dev/null 2>&1
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${TEST_DEPLOYMENT}
  labels:
    app: ha-test
spec:
  replicas: 3
  selector:
    matchLabels:
      app: ha-test
  template:
    metadata:
      labels:
        app: ha-test
    spec:
      containers:
      - name: pause
        image: registry.k8s.io/pause:3.9
        resources:
          requests:
            cpu: 1m
            memory: 1Mi
EOF

    # 等待Pod就绪
    log_info "等待测试Pod就绪..."
    kubectl rollout status deployment/"$TEST_DEPLOYMENT" -n "$TEST_NAMESPACE" --timeout=60s >/dev/null 2>&1 || {
        check_fail "测试Deployment未能在60秒内就绪"
        return
    }
    check_pass "测试Deployment已就绪 (3副本)"

    # 检查Pod分布
    local pods_on_nodes
    pods_on_nodes=$(kubectl get pods -n "$TEST_NAMESPACE" -l app=ha-test -o wide --no-headers 2>/dev/null || echo "")

    if [[ -z "$pods_on_nodes" ]]; then
        check_fail "无法获取测试Pod列表"
        return
    fi

    local unique_nodes
    unique_nodes=$(echo "$pods_on_nodes" | awk '{print $7}' | sort -u | wc -l)
    local total_pods
    total_pods=$(echo "$pods_on_nodes" | grep -c . || echo "0")

    check_pass "测试Pod总数: ${total_pods}"
    check_pass "分布节点数: ${unique_nodes}"

    if [[ "$unique_nodes" -gt 1 ]]; then
        check_pass "Pod成功分布在 ${unique_nodes} 个不同节点上"
    else
        check_warn "所有Pod在同一节点 (可能调度约束)"
    fi

    # 显示Pod分布详情
    log_info "Pod节点分布:"
    echo "$pods_on_nodes" | tee -a "$LOG_FILE"

    # 清理
    kubectl delete deployment "$TEST_DEPLOYMENT" -n "$TEST_NAMESPACE" --ignore-not-found &>/dev/null || true
    log_success "测试Deployment已清理"
}

# 5. 节点故障模拟测试
# Cordon一个节点并验证Pod重新调度
check_node_failure_simulation() {
    log_step "5. 节点故障模拟测试"

    if [[ "$SKIP_SIMULATE" == "true" ]]; then
        log_info "已跳过节点故障模拟测试 (--skip-simulate)"
        return
    fi

    # 获取节点列表
    local nodes
    nodes=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1}' || echo "")

    if [[ -z "$nodes" ]]; then
        check_fail "未找到可用节点"
        return
    fi

    local node_count
    node_count=$(echo "$nodes" | wc -l)

    if [[ "$node_count" -lt 2 ]]; then
        check_warn "集群仅有 ${node_count} 个节点，跳过故障模拟 (单节点故障将影响整个集群)"
        return
    fi

    log_warn "注意: 故障模拟将临时 cordon 一个节点，影响Pod调度"
    log_info "测试将在5秒后开始..."
    sleep 5

    # 选择一个worker节点进行故障模拟 (优先选择非master节点)
    local target_node=""
    while IFS= read -r node; do
        local roles
        roles=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/role}' 2>/dev/null || echo "worker")
        if [[ "$roles" != "master" && "$roles" != "control-plane" ]]; then
            target_node="$node"
            break
        fi
    done <<< "$nodes"

    # 如果没有worker节点，使用第一个节点
    if [[ -z "$target_node" ]]; then
        target_node=$(echo "$nodes" | head -1)
    fi

    log_info "选择故障模拟节点: ${target_node}"

    # 创建测试Deployment (4副本)
    kubectl delete deployment "$TEST_DEPLOYMENT" -n "$TEST_NAMESPACE" --ignore-not-found &>/dev/null || true
    sleep 2

    cat <<EOF | kubectl apply -n "$TEST_NAMESPACE" -f - >/dev/null 2>&1
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${TEST_DEPLOYMENT}
  labels:
    app: ha-failover-test
spec:
  replicas: 4
  selector:
    matchLabels:
      app: ha-failover-test
  template:
    metadata:
      labels:
        app: ha-failover-test
    spec:
      containers:
      - name: pause
        image: registry.k8s.io/pause:3.9
        resources:
          requests:
            cpu: 1m
            memory: 1Mi
EOF

    kubectl rollout status deployment/"$TEST_DEPLOYMENT" -n "$TEST_NAMESPACE" --timeout=60s >/dev/null 2>&1 || {
        check_fail "测试Deployment未能就绪"
        return
    }

    # 记录cordon前的Pod分布
    local before_cordon
    before_cordon=$(kubectl get pods -n "$TEST_NAMESPACE" -l app=ha-failover-test -o wide --no-headers 2>/dev/null || echo "")
    local before_ready
    before_ready=$(echo "$before_cordon" | grep -c "Running" || echo "0")
    check_pass "故障前: ${before_ready} 个Pod Running"

    # Cordon 节点
    log_info "Cordon 节点: ${target_node}"
    if kubectl cordon "$target_node" >/dev/null 2>&1; then
        NODE_CORDONED="$target_node"
        check_pass "节点 ${target_node} 已 Cordon (SchedulingDisabled)"

        # 等待重新调度
        log_info "等待Pod重新调度 (30秒)..."
        sleep 30

        # 检查Pod状态
        local after_cordon
        after_cordon=$(kubectl get pods -n "$TEST_NAMESPACE" -l app=ha-failover-test -o wide --no-headers 2>/dev/null || echo "")
        local after_ready
        after_ready=$(echo "$after_cordon" | grep -c "Running" || echo "0")

        if [[ "$after_ready" -ge "$before_ready" ]]; then
            check_pass "故障后: ${after_ready} 个Pod Running (调度正常)"
        else
            check_fail "故障后: ${after_ready}/${before_ready} 个Pod Running (调度受影响)"
        fi

        # 检查cordon节点上是否还有Pod
        local pods_on_cordoned
        pods_on_cordoned=$(echo "$after_cordon" | grep "$target_node" | wc -l)
        if [[ "$pods_on_cordoned" -eq 0 ]]; then
            check_pass "Cordon节点上无测试Pod (调度器正常工作)"
        else
            check_warn "Cordon节点上仍有 ${pods_on_cordoned} 个Pod (可能是现有Pod未重新调度)"
        fi

        # Uncordon 节点
        log_info "Uncordon 节点: ${target_node}"
        kubectl uncordon "$target_node" >/dev/null 2>&1
        NODE_CORDONED=""
        check_pass "节点 ${target_node} 已恢复 Uncordon"
    else
        check_fail "无法 Cordon 节点 ${target_node}"
    fi

    # 清理
    kubectl delete deployment "$TEST_DEPLOYMENT" -n "$TEST_NAMESPACE" --ignore-not-found &>/dev/null || true
    log_success "故障模拟测试完成"
}

# 6. 控制平面组件冗余检查
# 检查 kube-controller-manager 和 kube-scheduler 的冗余
check_control_plane_redundancy() {
    log_step "6. 控制平面组件冗余检查"

    for component in kube-controller-manager kube-scheduler; do
        local pods
        pods=$(kubectl get pods -n kube-system -l component="$component" --no-headers 2>/dev/null || echo "")

        if [[ -z "$pods" ]]; then
            # 尝试备用标签
            pods=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -i "$component" || echo "")
        fi

        if [[ -z "$pods" ]]; then
            check_warn "未找到 ${component} Pod"
            continue
        fi

        local total ready
        total=$(echo "$pods" | grep -c . || echo "0")
        ready=$(echo "$pods" | grep -c "Running" || echo "0")

        if [[ "$total" -gt 1 ]]; then
            check_pass "${component}: ${ready}/${total} 实例 (高可用模式)"
        elif [[ "$total" -eq 1 ]]; then
            check_warn "${component}: 仅1个实例 (建议多master高可用)"
        fi

        if [[ "$ready" -eq "$total" ]]; then
            check_pass "${component}: 全部 Running"
        else
            check_fail "${component}: ${ready}/${total} Running"
        fi

        # 显示组件分布
        while IFS= read -r line; do
            local pod_name node_name
            pod_name=$(echo "$line" | awk '{print $1}')
            node_name=$(echo "$line" | awk '{print $7}')
            check_pass "${component} ${pod_name} 运行在节点 ${node_name}"
        done <<< "$pods"
    done

    # 检查 etcd 是否有冗余
    local etcd_pods
    etcd_pods=$(kubectl get pods -n kube-system -l component=etcd --no-headers 2>/dev/null || echo "")

    if [[ -n "$etcd_pods" ]]; then
        local etcd_total
        etcd_total=$(echo "$etcd_pods" | grep -c . || echo "0")

        if [[ "$etcd_total" -gt 1 ]]; then
            check_pass "etcd: ${etcd_total} 实例 (高可用模式)"
        elif [[ "$etcd_total" -eq 1 ]]; then
            check_warn "etcd: 仅1个实例 (建议3节点高可用)"
        fi
    fi
}

# ========================= 汇总报告 =========================
show_summary() {
    echo "" | tee -a "$LOG_FILE"
    echo -e "${CYAN}$(printf '=%.0s' {1..60})${NC}" | tee -a "$LOG_FILE"
    echo -e "${CYAN}  Kubernetes 集群 HA 测试报告${NC}" | tee -a "$LOG_FILE"
    echo -e "${CYAN}$(printf '=%.0s' {1..60})${NC}" | tee -a "$LOG_FILE"
    echo -e "  ${GREEN}通过: ${PASSED}${NC}" | tee -a "$LOG_FILE"
    echo -e "  ${RED}失败: ${FAILED}${NC}" | tee -a "$LOG_FILE"
    echo -e "  ${YELLOW}警告: ${WARNINGS}${NC}" | tee -a "$LOG_FILE"
    echo -e "${CYAN}$(printf '=%.0s' {1..60})${NC}" | tee -a "$LOG_FILE"

    # HA评分
    local total=$((PASSED + FAILED + WARNINGS))
    local score=0
    if [[ $total -gt 0 ]]; then
        score=$(( (PASSED * 100) / total ))
    fi

    echo -e "  HA评分: ${score}%" | tee -a "$LOG_FILE"

    if [[ ${FAILED} -gt 0 ]]; then
        echo -e "${RED}HA状态: 存在故障, 请检查失败项${NC}" | tee -a "$LOG_FILE"
        echo -e "${RED}日志文件: ${LOG_FILE}${NC}" | tee -a "$LOG_FILE"
        return 1
    elif [[ ${WARNINGS} -gt 0 ]]; then
        echo -e "${YELLOW}HA状态: 基本可用, 有 ${WARNINGS} 个改进建议${NC}" | tee -a "$LOG_FILE"
        return 0
    else
        echo -e "${GREEN}HA状态: 高可用配置完善!${NC}" | tee -a "$LOG_FILE"
        return 0
    fi
}

# ========================= 帮助信息 =========================
show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --skip-simulate   跳过节点故障模拟测试"
    echo "  --help            显示此帮助信息"
    echo ""
    echo "测试项目:"
    echo "  1. 节点 Ready 状态检查"
    echo "  2. etcd 集群健康状态"
    echo "  3. API Server 冗余验证"
    echo "  4. Pod 跨节点调度测试"
    echo "  5. 节点故障模拟测试"
    echo "  6. 控制平面组件冗余检查"
}

# ========================= 主逻辑 =========================
main() {
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-simulate)
                SKIP_SIMULATE=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done

    mkdir -p "$LOG_DIR"
    check_lock

    log_step "阶段2-任务7: Kubernetes 集群高可用性测试"

    # 检查kubectl
    check_kubectl

    # 显示集群概况
    log_info "集群概况:"
    kubectl get nodes -o wide 2>/dev/null | head -10 | tee -a "$LOG_FILE" || true
    echo "" | tee -a "$LOG_FILE"

    # 执行所有测试
    check_nodes_ready
    check_etcd_health
    check_apiserver_redundancy
    check_pod_scheduling
    check_node_failure_simulation
    check_control_plane_redundancy

    # 显示汇总
    show_summary

    log_info "测试日志: ${LOG_FILE}"
}

main "$@"
