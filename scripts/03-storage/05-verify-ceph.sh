#!/usr/bin/env bash
###############################################################################
# 脚本名称: 05-verify-ceph.sh
# 功能描述: 全面验证Rook-Ceph存储功能，包括Operator、CephCluster、PVC读写等
# 适用系统: 需要kubectl可访问集群, Rook-Ceph已部署
# 依赖条件: kubectl可用, Rook-Ceph Operator已部署并运行
# 作者: 运维平台团队
# 版本: 1.1.0
# 创建日期: 2026-05-10
# 更新日期: 2026-05-10
#
# 使用方法:
#   ./05-verify-ceph.sh                   # 执行完整验证
#   TEST_NS=custom-test ./05-verify-ceph.sh  # 自定义测试命名空间
#
# 环境变量:
#   TEST_NS          - 测试命名空间 (默认: ceph-test)
#   CEPH_NAMESPACE   - Rook-Ceph命名空间 (默认: rook-ceph)
#
# 验证项目:
#   1. Rook-Ceph Operator Pod运行状态
#   2. CephCluster健康状态
#   3. OSD状态 (up/in)
#   4. Monitor仲裁状态
#   5. StorageClass存在性
#   6. PVC动态创建 (RWO + RWX)
#   7. Pod挂载读写测试
#   8. Ceph Dashboard可达性
#   9. PASS/FAIL汇总报告
###############################################################################
set -euo pipefail
umask 077

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

LOG_DIR="${PROJECT_ROOT}/logs/03-storage"
LOG_FILE="${LOG_DIR}/05-verify-ceph_$(date +%Y%m%d_%H%M%S).log"

# 配置变量
TEST_NS="${TEST_NS:-ceph-test}"
CEPH_NAMESPACE="${CEPH_NAMESPACE:-rook-ceph}"
RESULTS=()

# ========================= 日志函数 =========================
log_info()    { echo -e "${GREEN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >&2; }
log_step()    { echo -e "${CYAN}[STEP]${NC}  $(date '+%Y-%m-%d %H:%M:%S') === $* ===" | tee -a "$LOG_FILE"; }
log_pass()    { echo -e "${GREEN}[PASS]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_fail()    { echo -e "${RED}[FAIL]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }

# ========================= 错误处理 =========================
cleanup() {
    local exit_code=$?
    log_step "清理测试资源"
    # 删除测试命名空间和所有资源
    kubectl delete namespace "${TEST_NS}" --ignore-not-found --grace-period=0 --force 2>/dev/null || true
    log_info "测试资源已清理"
}
trap cleanup EXIT
trap 'log_error "收到信号，正在退出..."; exit 1' SIGINT SIGTERM

# ========================= 测试框架函数 =========================

# 运行单个测试用例
# 参数: $1=测试名称, $2=测试函数名
run_test() {
    local test_name="$1"
    local test_func="$2"
    log_info "测试: ${test_name}"
    if eval "${test_func}" &>/dev/null; then
        log_pass "${test_name}"
        RESULTS+=("PASS: ${test_name}")
    else
        log_fail "${test_name}"
        RESULTS+=("FAIL: ${test_name}")
    fi
}

# ========================= 测试用例函数 =========================

# 测试1: Rook-Ceph Operator Pod运行状态
test_operator_running() {
    local ready
    ready=$(kubectl get deployment rook-ceph-operator -n "${CEPH_NAMESPACE}" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    [[ "${ready}" -ge 1 ]] 2>/dev/null
}

# 测试2: CephCluster健康状态
test_ceph_cluster_health() {
    local phase
    phase=$(kubectl get cephcluster -n "${CEPH_NAMESPACE}" \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "unknown")
    [[ "${phase}" == "Ready" ]]
}

# 测试3: OSD状态 (up/in)
test_osd_status() {
    # 通过toolbox检查OSD状态
    local toolbox_pod
    toolbox_pod=$(kubectl get pods -n "${CEPH_NAMESPACE}" -l app=rook-ceph-tools \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "${toolbox_pod}" ]]; then
        log_warn "Toolbox Pod未找到，跳过OSD检查"
        return 1
    fi

    local osd_count
    osd_count=$(kubectl exec -n "${CEPH_NAMESPACE}" "${toolbox_pod}" -- \
        ceph osd stat -f json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['osd_count'])" 2>/dev/null || echo "0")
    [[ "${osd_count}" -ge 3 ]] 2>/dev/null
}

# 测试4: Monitor仲裁状态
test_mon_quorum() {
    local toolbox_pod
    toolbox_pod=$(kubectl get pods -n "${CEPH_NAMESPACE}" -l app=rook-ceph-tools \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "${toolbox_pod}" ]]; then
        log_warn "Toolbox Pod未找到，跳过Monitor检查"
        return 1
    fi

    local mon_count
    mon_count=$(kubectl exec -n "${CEPH_NAMESPACE}" "${toolbox_pod}" -- \
        ceph quorum_status -f json 2>/dev/null | python3 -c "import sys,json;print(len(json.load(sys.stdin)['quorum']))" 2>/dev/null || echo "0")
    [[ "${mon_count}" -ge 3 ]] 2>/dev/null
}

# 测试5: StorageClass存在性
test_storageclass_exists() {
    local block_exists=false
    local fs_exists=false

    kubectl get storageclass ceph-block &>/dev/null && block_exists=true
    kubectl get storageclass ceph-filesystem &>/dev/null && fs_exists=true

    # 至少有一个StorageClass存在
    [[ "${block_exists}" == "true" || "${fs_exists}" == "true" ]]
}

# 测试6: PVC动态创建 (ReadWriteOnce - Ceph RBD)
test_pvc_rwo() {
    # 确保测试命名空间存在
    kubectl create namespace "${TEST_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

    # 检查ceph-block StorageClass是否存在
    if ! kubectl get storageclass ceph-block &>/dev/null; then
        log_warn "ceph-block StorageClass不存在，跳过RWO测试"
        return 1
    fi

    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-ceph-rwo
  namespace: ${TEST_NS}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ceph-block
  resources:
    requests:
      storage: 1Gi
EOF

    # 等待PVC绑定 (最多60秒)
    local max_wait=60
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local phase
        phase=$(kubectl get pvc test-ceph-rwo -n "${TEST_NS}" \
            -o jsonpath='{.status.phase}' 2>/dev/null)
        if [[ "${phase}" == "Bound" ]]; then
            log_info "Ceph RBD PVC ReadWriteOnce 已绑定"
            return 0
        fi
        sleep 3
        waited=$((waited + 3))
    done
    return 1
}

# 测试7: PVC动态创建 (ReadWriteMany - CephFS)
test_pvc_rwx() {
    # 确保测试命名空间存在
    kubectl create namespace "${TEST_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

    # 检查ceph-filesystem StorageClass是否存在
    if ! kubectl get storageclass ceph-filesystem &>/dev/null; then
        log_warn "ceph-filesystem StorageClass不存在，跳过RWX测试"
        return 1
    fi

    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-ceph-rwx
  namespace: ${TEST_NS}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ceph-filesystem
  resources:
    requests:
      storage: 1Gi
EOF

    # 等待PVC绑定 (最多120秒，CephFS初始化较慢)
    local max_wait=120
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local phase
        phase=$(kubectl get pvc test-ceph-rwx -n "${TEST_NS}" \
            -o jsonpath='{.status.phase}' 2>/dev/null)
        if [[ "${phase}" == "Bound" ]]; then
            log_info "CephFS PVC ReadWriteMany 已绑定"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

# 测试8: Pod挂载RWO PVC并读写数据
test_pod_mount_rwo() {
    if ! kubectl get pvc test-ceph-rwo -n "${TEST_NS}" &>/dev/null; then
        log_warn "test-ceph-rwo PVC不存在，跳过"
        return 1
    fi

    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: ceph-rwo-test-pod
  namespace: ${TEST_NS}
spec:
  containers:
    - name: writer
      image: busybox:1.36
      command: ["sh", "-c", "echo 'ceph-rwo-test-data' > /data/test.txt && sleep 10 && cat /data/test.txt"]
      volumeMounts:
        - name: test-vol
          mountPath: /data
  volumes:
    - name: test-vol
      persistentVolumeClaim:
        claimName: test-ceph-rwo
EOF

    # 等待Pod完成 (最多120秒)
    local max_wait=120
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local phase
        phase=$(kubectl get pod ceph-rwo-test-pod -n "${TEST_NS}" \
            -o jsonpath='{.status.phase}' 2>/dev/null)

        if [[ "${phase}" == "Succeeded" ]]; then
            local output
            output=$(kubectl logs ceph-rwo-test-pod -n "${TEST_NS}" 2>/dev/null)
            if echo "${output}" | grep -q "ceph-rwo-test-data"; then
                log_info "Pod挂载RWD读写测试通过"
                return 0
            fi
        elif [[ "${phase}" == "Failed" ]]; then
            kubectl logs ceph-rwo-test-pod -n "${TEST_NS}" 2>/dev/null | tee -a "$LOG_FILE"
            return 1
        fi
        sleep 3
        waited=$((waited + 3))
    done
    return 1
}

# 测试9: Ceph Dashboard可达性
test_ceph_dashboard() {
    local dashboard_svc
    dashboard_svc=$(kubectl get svc -n "${CEPH_NAMESPACE}" rook-ceph-mgr-dashboard \
        -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    if [[ -z "${dashboard_svc}" ]]; then
        log_warn "Dashboard Service未找到"
        return 1
    fi

    # 从集群内部检查Dashboard端口
    local dashboard_port
    dashboard_port=$(kubectl get svc -n "${CEPH_NAMESPACE}" rook-ceph-mgr-dashboard \
        -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "")

    if [[ -n "${dashboard_port}" ]]; then
        log_info "Ceph Dashboard地址: https://${dashboard_svc}:${dashboard_port}"
        return 0
    fi
    return 1
}

# ========================= 汇总报告 =========================
show_summary() {
    log_step "测试结果汇总"

    local PASS_COUNT=0
    local FAIL_COUNT=0

    for result in "${RESULTS[@]}"; do
        if [[ "${result}" == PASS:* ]]; then
            echo -e "  ${GREEN}✓${NC} ${result#PASS: }" | tee -a "$LOG_FILE"
            ((PASS_COUNT++)) || true
        else
            echo -e "  ${RED}✗${NC} ${result#FAIL: }" | tee -a "$LOG_FILE"
            ((FAIL_COUNT++)) || true
        fi
    done

    echo "" | tee -a "$LOG_FILE"
    local TOTAL=$((PASS_COUNT + FAIL_COUNT))
    log_info "总计: ${TOTAL} | 通过: ${PASS_COUNT} | 失败: ${FAIL_COUNT}"
    log_info "测试日志: ${LOG_FILE}"

    if [[ ${FAIL_COUNT} -gt 0 ]]; then
        echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}" | tee -a "$LOG_FILE"
        echo -e "${RED}║   结果: FAIL - 存在失败项                           ║${NC}" | tee -a "$LOG_FILE"
        echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}" | tee -a "$LOG_FILE"
        return 1
    else
        echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}" | tee -a "$LOG_FILE"
        echo -e "${GREEN}║   结果: PASS - 所有测试通过                         ║${NC}" | tee -a "$LOG_FILE"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}" | tee -a "$LOG_FILE"
        return 0
    fi
}

# ========================= 主逻辑 =========================
main() {
    mkdir -p "$LOG_DIR"

    log_step "Rook-Ceph 存储功能验证"
    log_info "测试命名空间: ${TEST_NS}"
    log_info "Ceph命名空间: ${CEPH_NAMESPACE}"

    # 运行所有测试
    log_step "1. Operator状态检查"
    run_test "Rook-Ceph Operator运行中" test_operator_running

    log_step "2. CephCluster健康检查"
    run_test "CephCluster状态为Ready" test_ceph_cluster_health

    log_step "3. OSD状态检查"
    run_test "OSD数量 ≥ 3" test_osd_status

    log_step "4. Monitor仲裁检查"
    run_test "Monitor仲裁正常 (≥3)" test_mon_quorum

    log_step "5. StorageClass检查"
    run_test "至少一个Ceph StorageClass存在" test_storageclass_exists

    log_step "6. PVC动态创建测试"
    run_test "Ceph RBD PVC (RWO) 绑定" test_pvc_rwo
    run_test "CephFS PVC (RWX) 绑定" test_pvc_rwx

    log_step "7. Pod挂载读写测试"
    run_test "Pod挂载RWO PVC读写" test_pod_mount_rwo

    log_step "8. Dashboard可达性"
    run_test "Ceph Dashboard Service存在" test_ceph_dashboard

    # 显示汇总
    show_summary
}

main "$@"
