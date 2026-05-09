#!/usr/bin/env bash
# =============================================================================
# 验证存储功能
# 阶段3 - 存储层配置
# =============================================================================
set -euo pipefail
umask 077

# ---------- 彩色日志 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
log_step()  { echo -e "${CYAN}[STEP]${NC}  $(date '+%Y-%m-%d %H:%M:%S') === $* ==="; }
log_pass()  { echo -e "${GREEN}[PASS]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_fail()  { echo -e "${RED}[FAIL]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }

TEST_NS="${TEST_NS:-storage-test}"
RESULTS=()

cleanup() {
    local exit_code=$?
    log_step "清理测试资源"
    kubectl delete namespace "${TEST_NS}" --ignore-not-found --grace-period=0 --force 2>/dev/null || true
    log_info "测试资源已清理"
}
trap cleanup EXIT

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

# ---------- Test 1: StorageClass检查 ----------
test_storageclass_exists() {
    kubectl get storageclass nfs-client >/dev/null 2>&1
}

test_default_storageclass() {
    local is_default
    is_default=$(kubectl get storageclass nfs-client \
        -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null)
    [[ "${is_default}" == "true" ]]
}

# ---------- Test 2: NFS Provisioner运行状态 ----------
test_nfs_provisioner_running() {
    local ready
    ready=$(kubectl get deployment nfs-client-provisioner -n nfs-provisioner \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    [[ "${ready}" -ge 1 ]] 2>/dev/null
}

# ---------- Test 3: PVC动态创建 (ReadWriteMany) ----------
test_pvc_rwx() {
    kubectl create namespace "${TEST_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc-rwx
  namespace: ${TEST_NS}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-client
  resources:
    requests:
      storage: 1Gi
EOF

    # 等待PVC绑定
    for i in $(seq 1 30); do
        local phase
        phase=$(kubectl get pvc test-pvc-rwx -n "${TEST_NS}" \
            -o jsonpath='{.status.phase}' 2>/dev/null)
        if [[ "${phase}" == "Bound" ]]; then
            return 0
        fi
        sleep 2
    done
    return 1
}

# ---------- Test 4: PVC动态创建 (ReadWriteOnce) ----------
test_pvc_rwo() {
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc-rwo
  namespace: ${TEST_NS}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-client
  resources:
    requests:
      storage: 1Gi
EOF

    for i in $(seq 1 30); do
        local phase
        phase=$(kubectl get pvc test-pvc-rwo -n "${TEST_NS}" \
            -o jsonpath='{.status.phase}' 2>/dev/null)
        if [[ "${phase}" == "Bound" ]]; then
            return 0
        fi
        sleep 2
    done
    return 1
}

# ---------- Test 5: Pod挂载测试 ----------
test_pod_mount() {
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: storage-test-pod
  namespace: ${TEST_NS}
spec:
  containers:
    - name: writer
      image: busybox:1.36
      command: ["sh", "-c", "echo 'hello-storage' > /data/test.txt && sleep 30 && cat /data/test.txt"]
      volumeMounts:
        - name: test-vol
          mountPath: /data
  volumes:
    - name: test-vol
      persistentVolumeClaim:
        claimName: test-pvc-rwx
EOF

    for i in $(seq 1 60); do
        local phase
        phase=$(kubectl get pod storage-test-pod -n "${TEST_NS}" \
            -o jsonpath='{.status.phase}' 2>/dev/null)
        if [[ "${phase}" == "Succeeded" ]]; then
            local output
            output=$(kubectl logs storage-test-pod -n "${TEST_NS}" 2>/dev/null)
            if echo "${output}" | grep -q "hello-storage"; then
                return 0
            fi
        elif [[ "${phase}" == "Running" ]]; then
            sleep 2
            continue
        fi
        sleep 2
    done
    return 1
}

# ---------- Test 6: PV创建验证 ----------
test_pv_created() {
    local pv_count
    pv_count=$(kubectl get pv --no-headers 2>/dev/null | wc -l)
    [[ "${pv_count}" -gt 0 ]]
}

# ---------- Test 7: VolumeExpansion测试 ----------
test_volume_expansion() {
    kubectl patch pvc test-pvc-rwo -n "${TEST_NS}" \
        -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}' >/dev/null 2>&1
}

# ========== 运行所有测试 ==========
log_step "开始存储功能验证"

log_step "1. StorageClass检查"
run_test "StorageClass nfs-client 存在" test_storageclass_exists
run_test "nfs-client 为默认StorageClass" test_default_storageclass

log_step "2. NFS Provisioner状态"
run_test "NFS Provisioner运行中" test_nfs_provisioner_running

log_step "3. PVC动态创建测试"
run_test "PVC ReadWriteOnce 绑定" test_pvc_rwo
run_test "PVC ReadWriteMany 绑定" test_pvc_rwx

log_step "4. Pod挂载读写测试"
run_test "Pod挂载PVC并写入数据" test_pod_mount

log_step "5. PV与VolumeExpansion"
run_test "PersistentVolume已创建" test_pv_created
run_test "VolumeExpansion生效" test_volume_expansion

# ========== 汇总 ==========
log_step "测试结果汇总"

PASS_COUNT=0; FAIL_COUNT=0
for result in "${RESULTS[@]}"; do
    if [[ "${result}" == PASS:* ]]; then
        echo -e "  ${GREEN}✓${NC} ${result#PASS: }"
        ((PASS_COUNT++))
    else
        echo -e "  ${RED}✗${NC} ${result#FAIL: }"
        ((FAIL_COUNT++))
    fi
done

echo ""
TOTAL=$((PASS_COUNT + FAIL_COUNT))
log_info "总计: ${TOTAL} | 通过: ${PASS_COUNT} | 失败: ${FAIL_COUNT}"

if [[ ${FAIL_COUNT} -gt 0 ]]; then
    log_error "存在失败的测试用例"
    exit 1
else
    log_info "所有存储功能验证通过"
fi
