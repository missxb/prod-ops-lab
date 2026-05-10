#!/usr/bin/env bash
###############################################################################
# 脚本名称: 07-verify-longhorn.sh
# 功能描述: 全面验证Longhorn分布式存储功能，包括Manager、CSI、PVC读写、性能、快照等
# 适用系统: 需要kubectl可访问集群, Longhorn已部署
# 依赖条件: kubectl可用, Longhorn已通过Helm部署
# 作者: 运维平台团队
# 版本: 1.2.0
# 创建日期: 2026-05-10
# 更新日期: 2026-05-10
#
# 使用方法:
#   ./07-verify-longhorn.sh                   # 执行完整验证
#   TEST_NS=custom-test ./07-verify-longhorn.sh  # 自定义测试命名空间
#
# 环境变量:
#   TEST_NS            - 测试命名空间 (默认: longhorn-test)
#   LONGHORN_NAMESPACE - Longhorn命名空间 (默认: longhorn-system)
#
# 验证项目:
#   1. Longhorn Manager Pod运行状态
#   2. Longhorn CSI Driver Pod状态
#   3. 集群节点在Longhorn中就绪
#   4. StorageClass存在性
#   5. PVC动态创建 (ReadWriteOnce)
#   6. Pod挂载读写测试
#   7. Longhorn Dashboard可达性
#   8. Volume快照功能 (创建-验证-恢复)
#   9. 写入性能测试
#  10. PASS/FAIL汇总报告
###############################################################################
set -euo pipefail
umask 077

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

LOG_DIR="${PROJECT_ROOT}/logs/03-storage"
LOG_FILE="${LOG_DIR}/07-verify-longhorn_$(date +%Y%m%d_%H%M%S).log"

# 配置变量
TEST_NS="${TEST_NS:-longhorn-test}"
LONGHORN_NAMESPACE="${LONGHORN_NAMESPACE:-longhorn-system}"
RESULTS=()
TOTAL_TESTS=0
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# ========================= 日志函数 =========================
log_info()    { echo -e "${GREEN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >&2; }
log_step()    { echo -e "${CYAN}[STEP]${NC}  $(date '+%Y-%m-%d %H:%M:%S') === $* ===" | tee -a "$LOG_FILE"; }
log_pass()    { echo -e "${GREEN}[PASS]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_fail()    { echo -e "${RED}[FAIL]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_skip()    { echo -e "${YELLOW}[SKIP]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }

banner() {
    echo -e "" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${BLUE}" | tee -a "$LOG_FILE"
    echo "╔══════════════════════════════════════════════════════╗" | tee -a "$LOG_FILE"
    echo "║   Longhorn 存储功能验证                             ║" | tee -a "$LOG_FILE"
    echo "╚══════════════════════════════════════════════════════╝" | tee -a "$LOG_FILE"
    echo -e "${NC}" | tee -a "$LOG_FILE"
}

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
# 参数: $1=步骤号, $2=测试名称, $3=测试函数名
run_test() {
    local step_num="$1"
    local test_name="$2"
    local test_func="$3"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    echo -ne "  ${CYAN}[${step_num}]${NC} ${test_name} ... " | tee -a "$LOG_FILE"
    if eval "${test_func}" &>/dev/null; then
        echo -e "${GREEN}PASS${NC}" | tee -a "$LOG_FILE"
        log_pass "${test_name}"
        RESULTS+=("PASS: ${test_name}")
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "${RED}FAIL${NC}" | tee -a "$LOG_FILE"
        log_fail "${test_name}"
        RESULTS+=("FAIL: ${test_name}")
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# 运行可选测试 (失败不计入FAIL)
# 参数: $1=步骤号, $2=测试名称, $3=测试函数名
run_optional_test() {
    local step_num="$1"
    local test_name="$2"
    local test_func="$3"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    echo -ne "  ${CYAN}[${step_num}]${NC} ${test_name} ... " | tee -a "$LOG_FILE"
    if eval "${test_func}" &>/dev/null; then
        echo -e "${GREEN}PASS${NC}" | tee -a "$LOG_FILE"
        log_pass "${test_name}"
        RESULTS+=("PASS: ${test_name}")
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "${YELLOW}SKIP${NC}" | tee -a "$LOG_FILE"
        log_skip "${test_name} (可选)"
        RESULTS+=("SKIP: ${test_name}")
        SKIP_COUNT=$((SKIP_COUNT + 1))
    fi
}

# ========================= 测试用例函数 =========================

# 测试1: Longhorn Manager Pod运行状态
test_manager_running() {
    local ready
    ready=$(kubectl get daemonset longhorn-manager -n "${LONGHORN_NAMESPACE}" \
        -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
    local desired
    desired=$(kubectl get daemonset longhorn-manager -n "${LONGHORN_NAMESPACE}" \
        -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
    [[ "${ready}" -ge 1 && "${ready}" == "${desired}" ]] 2>/dev/null
}

# 测试2: Longhorn CSI Plugin Pod状态
test_csi_plugin_running() {
    local ready
    ready=$(kubectl get daemonset longhorn-csi-plugin -n "${LONGHORN_NAMESPACE}" \
        -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
    [[ "${ready}" -ge 1 ]] 2>/dev/null
}

# 测试3: Longhorn CSI Provisioner Pod状态
test_csi_provisioner_running() {
    local ready
    ready=$(kubectl get deployment longhorn-csi-provisioner -n "${LONGHORN_NAMESPACE}" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    [[ "${ready}" -ge 1 ]] 2>/dev/null
}

# 测试4: 集群节点在Longhorn中就绪
test_nodes_ready() {
    local node_count
    node_count=$(kubectl get nodes.longhorn.io -n "${LONGHORN_NAMESPACE}" --no-headers 2>/dev/null | wc -l)
    [[ "${node_count}" -ge 1 ]] 2>/dev/null
}

# 测试5: StorageClass存在性
test_storageclass_exists() {
    kubectl get storageclass longhorn &>/dev/null
}

# 测试6: PVC动态创建 (ReadWriteOnce)
test_pvc_rwo() {
    # 确保测试命名空间存在
    kubectl create namespace "${TEST_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

    # 检查longhorn StorageClass是否存在
    if ! kubectl get storageclass longhorn &>/dev/null; then
        return 1
    fi

    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-longhorn-rwo
  namespace: ${TEST_NS}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 2Gi
EOF

    # 等待PVC绑定 (最多90秒)
    local max_wait=90
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local phase
        phase=$(kubectl get pvc test-longhorn-rwo -n "${TEST_NS}" \
            -o jsonpath='{.status.phase}' 2>/dev/null)
        if [[ "${phase}" == "Bound" ]]; then
            return 0
        fi
        sleep 3
        waited=$((waited + 3))
    done
    return 1
}

# 测试7: Pod挂载PVC并读写数据
test_pod_mount() {
    if ! kubectl get pvc test-longhorn-rwo -n "${TEST_NS}" &>/dev/null; then
        return 1
    fi

    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: longhorn-test-pod
  namespace: ${TEST_NS}
spec:
  containers:
    - name: writer
      image: busybox:1.36
      command: ["sh", "-c", "echo 'longhorn-test-data' > /data/test.txt && sleep 10 && cat /data/test.txt"]
      volumeMounts:
        - name: test-vol
          mountPath: /data
  volumes:
    - name: test-vol
      persistentVolumeClaim:
        claimName: test-longhorn-rwo
EOF

    # 等待Pod完成 (最多120秒)
    local max_wait=120
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local phase
        phase=$(kubectl get pod longhorn-test-pod -n "${TEST_NS}" \
            -o jsonpath='{.status.phase}' 2>/dev/null)

        if [[ "${phase}" == "Succeeded" ]]; then
            local output
            output=$(kubectl logs longhorn-test-pod -n "${TEST_NS}" 2>/dev/null)
            if echo "${output}" | grep -q "longhorn-test-data"; then
                return 0
            fi
        elif [[ "${phase}" == "Failed" ]]; then
            return 1
        fi
        sleep 3
        waited=$((waited + 3))
    done
    return 1
}

# 测试8: Longhorn Dashboard可达性
test_dashboard() {
    local dashboard_svc
    dashboard_svc=$(kubectl get svc -n "${LONGHORN_NAMESPACE}" longhorn-frontend \
        -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    if [[ -z "${dashboard_svc}" ]]; then
        return 1
    fi

    local dashboard_port
    dashboard_port=$(kubectl get svc -n "${LONGHORN_NAMESPACE}" longhorn-frontend \
        -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "")

    if [[ -n "${dashboard_port}" ]]; then
        log_info "Longhorn Dashboard: http://${dashboard_svc}:${dashboard_port}"
        return 0
    fi
    return 1
}

# 测试9: Volume快照功能 (创建-验证-恢复)
test_volume_snapshot() {
    # 检查VolumeSnapshotClass是否存在
    if ! kubectl get volumesnapshotclass 2>/dev/null | grep -q "longhorn"; then
        log_info "VolumeSnapshotClass未配置"
        return 1  # 视为跳过
    fi

    # 如果有快照类，尝试创建快照
    if ! kubectl get pvc test-longhorn-rwo -n "${TEST_NS}" &>/dev/null; then
        return 1
    fi

    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: test-longhorn-snapshot
  namespace: ${TEST_NS}
spec:
  volumeSnapshotClassName: longhorn
  source:
    persistentVolumeClaimName: test-longhorn-rwo
EOF
    # 等待快照创建
    local max_wait=60
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local ready
        ready=$(kubectl get volumesnapshot test-longhorn-snapshot -n "${TEST_NS}" \
            -o jsonpath='{.status.readyToUse}' 2>/dev/null || echo "false")
        if [[ "${ready}" == "true" ]]; then
            log_info "Volume快照创建成功"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

# 测试10: 快照恢复测试
test_snapshot_restore() {
    if ! kubectl get volumesnapshot test-longhorn-snapshot -n "${TEST_NS}" &>/dev/null; then
        return 1
    fi

    # 从快照创建新PVC
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-longhorn-restored
  namespace: ${TEST_NS}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 2Gi
  dataSource:
    name: test-longhorn-snapshot
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
EOF

    # 等待恢复的PVC绑定
    local max_wait=60
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local phase
        phase=$(kubectl get pvc test-longhorn-restored -n "${TEST_NS}" \
            -o jsonpath='{.status.phase}' 2>/dev/null)
        if [[ "${phase}" == "Bound" ]]; then
            log_info "快照恢复PVC已绑定"
            return 0
        fi
        sleep 3
        waited=$((waited + 3))
    done
    return 1
}

# 测试11: 写入性能测试
test_performance() {
    if ! kubectl get pvc test-longhorn-rwo -n "${TEST_NS}" &>/dev/null; then
        return 1
    fi

    # 创建性能测试Pod
    cat <<'PERFPOD' | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: longhorn-perf-test
  namespace: TEST_NS_PLACEHOLDER
spec:
  containers:
    - name: perf
      image: busybox:1.36
      command: ["sh", "-c"]
      args:
        - |
          # 写入性能测试: 100MB
          echo "=== 写入性能测试 (100MB) ==="
          dd if=/dev/zero of=/data/perf_testfile bs=1M count=100 2>&1
          sync
          echo ""
          echo "=== 读取性能测试 ==="
          dd if=/data/perf_testfile of=/dev/null bs=1M 2>&1
          echo ""
          echo "=== 性能测试完成 ==="
          rm -f /data/perf_testfile
      volumeMounts:
        - name: test-vol
          mountPath: /data
  volumes:
    - name: test-vol
      persistentVolumeClaim:
        claimName: test-longhorn-rwo
PERFPOD

    # 替换命名空间
    kubectl get pod longhorn-perf-test -n "${TEST_NS}" &>/dev/null 2>&1 || \
        sed "s/TEST_NS_PLACEHOLDER/${TEST_NS}/g" <<'PERFPOD' | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: longhorn-perf-test
  namespace: TEST_NS_PLACEHOLDER
spec:
  containers:
    - name: perf
      image: busybox:1.36
      command: ["sh", "-c"]
      args:
        - |
          echo "=== 写入性能测试 (100MB) ==="
          dd if=/dev/zero of=/data/perf_testfile bs=1M count=100 2>&1
          sync
          echo ""
          echo "=== 读取性能测试 ==="
          dd if=/data/perf_testfile of=/dev/null bs=1M 2>&1
          echo ""
          echo "=== 性能测试完成 ==="
          rm -f /data/perf_testfile
      volumeMounts:
        - name: test-vol
          mountPath: /data
  volumes:
    - name: test-vol
      persistentVolumeClaim:
        claimName: test-longhorn-rwo
PERFPOD

    # 等待性能测试Pod完成 (最多180秒)
    local max_wait=180
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local phase
        phase=$(kubectl get pod longhorn-perf-test -n "${TEST_NS}" \
            -o jsonpath='{.status.phase}' 2>/dev/null)

        if [[ "${phase}" == "Succeeded" ]]; then
            # 获取性能输出
            local perf_output
            perf_output=$(kubectl logs longhorn-perf-test -n "${TEST_NS}" 2>/dev/null)
            if echo "${perf_output}" | grep -q "性能测试完成"; then
                log_info "性能测试输出:"
                echo "${perf_output}" | tee -a "$LOG_FILE"
                return 0
            fi
        elif [[ "${phase}" == "Failed" ]]; then
            return 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

# ========================= 汇总报告 =========================
show_summary() {
    echo "" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════════${NC}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${CYAN}                     验证结果汇总报告                           ${NC}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════════${NC}" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"

    # 列出所有测试结果
    for result in "${RESULTS[@]}"; do
        local status="${result%%:*}"
        local name="${result#*: }"
        case "${status}" in
            PASS) echo -e "  ${GREEN}✓${NC} ${name}" | tee -a "$LOG_FILE" ;;
            FAIL) echo -e "  ${RED}✗${NC} ${name}" | tee -a "$LOG_FILE" ;;
            SKIP) echo -e "  ${YELLOW}○${NC} ${name} (可选)" | tee -a "$LOG_FILE" ;;
        esac
    done

    echo "" | tee -a "$LOG_FILE"
    echo -e "  ─────────────────────────────────────────────" | tee -a "$LOG_FILE"
    echo -e "  ${BOLD}总计:${NC} ${TOTAL_TESTS}    ${GREEN}通过:${NC} ${PASS_COUNT}    ${RED}失败:${NC} ${FAIL_COUNT}    ${YELLOW}跳过:${NC} ${SKIP_COUNT}" | tee -a "$LOG_FILE"
    echo -e "  ─────────────────────────────────────────────" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"

    log_info "测试日志: ${LOG_FILE}"

    if [[ ${FAIL_COUNT} -gt 0 ]]; then
        echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}" | tee -a "$LOG_FILE"
        echo -e "${RED}║   结果: FAIL - 存在 ${FAIL_COUNT} 个失败项                       ║${NC}" | tee -a "$LOG_FILE"
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
    banner

    log_info "测试命名空间: ${TEST_NS}"
    log_info "Longhorn命名空间: ${LONGHORN_NAMESPACE}"
    echo "" | tee -a "$LOG_FILE"

    # 运行所有测试
    log_step "1. Manager 状态检查"
    run_test "1.1" "Longhorn Manager 运行中" test_manager_running

    log_step "2. CSI Driver 状态检查"
    run_test "2.1" "CSI Plugin 运行中" test_csi_plugin_running
    run_test "2.2" "CSI Provisioner 运行中" test_csi_provisioner_running

    log_step "3. 节点就绪检查"
    run_test "3.1" "Longhorn 节点已注册" test_nodes_ready

    log_step "4. StorageClass 检查"
    run_test "4.1" "longhorn StorageClass 存在" test_storageclass_exists

    log_step "5. PVC 动态创建测试"
    run_test "5.1" "Longhorn PVC (RWO) 绑定" test_pvc_rwo

    log_step "6. Pod 挂载读写测试"
    run_test "6.1" "Pod 挂载 Longhorn PVC 读写" test_pod_mount

    log_step "7. Dashboard 可达性"
    run_optional_test "7.1" "Longhorn Dashboard Service 存在" test_dashboard

    log_step "8. Volume 快照功能"
    run_optional_test "8.1" "Volume 快照创建" test_volume_snapshot
    run_optional_test "8.2" "Volume 快照恢复" test_snapshot_restore

    log_step "9. 写入性能测试"
    run_optional_test "9.1" "写入/读取性能 (100MB)" test_performance

    # 显示汇总
    show_summary
}

main "$@"
