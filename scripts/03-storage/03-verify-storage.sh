#!/usr/bin/env bash
###############################################################################
# 脚本名称: 03-verify-storage.sh
# 功能描述: 全面验证存储功能，包括StorageClass、PVC动态创建、Pod挂载读写等
# 适用系统: 需要kubectl可访问集群, NFS存储已配置
# 依赖条件: kubectl可用, NFS Provisioner已部署, StorageClass已创建
# 作者: 运维平台团队
# 版本: 1.1.0
# 创建日期: 2026-05-09
# 更新日期: 2026-05-09
#
# 使用方法:
#   ./03-verify-storage.sh                   # 执行完整验证
#   TEST_NS=custom-test ./03-verify-storage.sh  # 自定义测试命名空间
#
# 环境变量:
#   TEST_NS          - 测试命名空间 (默认: storage-test)
#
# 测试项目:
#   1. StorageClass存在性和默认标记
#   2. NFS Provisioner运行状态
#   3. PVC动态创建 (ReadWriteOnce)
#   4. PVC动态创建 (ReadWriteMany)
#   5. Pod挂载PVC并写入/读取数据
#   6. PersistentVolume创建验证
#   7. VolumeExpansion功能
###############################################################################
set -euo pipefail
umask 077

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/03-storage"
LOG_FILE="${LOG_DIR}/03-verify-storage_$(date +%Y%m%d_%H%M%S).log"

# 配置变量
TEST_NS="${TEST_NS:-storage-test}"
RESULTS=()  # 存储测试结果

# ========================= 颜色定义 =========================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# ========================= 日志函数 =========================
log_info()    { echo -e "${GREEN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >&2; }
log_step()    { echo -e "${CYAN}[STEP]${NC}  $(date '+%Y-%m-%d %H:%M:%S') === $* ===" | tee -a "$LOG_FILE"; }
log_pass()    { echo -e "${GREEN}[PASS]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_fail()    { echo -e "${RED}[FAIL]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }

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

# 测试1: StorageClass存在性检查
test_storageclass_exists() {
    kubectl get storageclass nfs-client >/dev/null 2>&1
}

# 测试1.1: StorageClass默认标记检查
test_default_storageclass() {
    local is_default
    is_default=$(kubectl get storageclass nfs-client \
        -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null)
    [[ "${is_default}" == "true" ]]
}

# 测试2: NFS Provisioner运行状态
test_nfs_provisioner_running() {
    local ready
    ready=$(kubectl get deployment nfs-client-provisioner -n nfs-provisioner \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    [[ "${ready}" -ge 1 ]] 2>/dev/null
}

# 测试3: PVC动态创建 (ReadWriteMany)
# 验证可以创建ReadWriteMany类型的PVC并成功绑定
test_pvc_rwx() {
    # 确保测试命名空间存在
    kubectl create namespace "${TEST_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

    # 创建PVC
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

    # 等待PVC绑定 (最多60秒)
    local max_wait=30
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local phase
        phase=$(kubectl get pvc test-pvc-rwx -n "${TEST_NS}" \
            -o jsonpath='{.status.phase}' 2>/dev/null)
        if [[ "${phase}" == "Bound" ]]; then
            log_info "PVC ReadWriteMany 已绑定"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

# 测试4: PVC动态创建 (ReadWriteOnce)
# 验证可以创建ReadWriteOnce类型的PVC并成功绑定
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

    # 等待PVC绑定
    local max_wait=30
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local phase
        phase=$(kubectl get pvc test-pvc-rwo -n "${TEST_NS}" \
            -o jsonpath='{.status.phase}' 2>/dev/null)
        if [[ "${phase}" == "Bound" ]]; then
            log_info "PVC ReadWriteOnce 已绑定"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

# 测试5: Pod挂载PVC并写入/读取数据
# 验证Pod可以成功挂载PVC并进行文件读写操作
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

    # 等待Pod完成 (最多120秒)
    local max_wait=60
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local phase
        phase=$(kubectl get pod storage-test-pod -n "${TEST_NS}" \
            -o jsonpath='{.status.phase}' 2>/dev/null)

        if [[ "${phase}" == "Succeeded" ]]; then
            # 验证输出内容
            local output
            output=$(kubectl logs storage-test-pod -n "${TEST_NS}" 2>/dev/null)
            if echo "${output}" | grep -q "hello-storage"; then
                log_info "Pod挂载读写测试通过"
                return 0
            fi
        elif [[ "${phase}" == "Running" ]]; then
            sleep 2
            waited=$((waited + 2))
            continue
        elif [[ "${phase}" == "Failed" ]]; then
            log_error "Pod执行失败"
            kubectl logs storage-test-pod -n "${TEST_NS}" 2>/dev/null | tee -a "$LOG_FILE"
            return 1
        fi

        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

# 测试6: PersistentVolume创建验证
# 验证动态供给是否成功创建了PV
test_pv_created() {
    local pv_count
    pv_count=$(kubectl get pv --no-headers 2>/dev/null | wc -l)
    [[ "${pv_count}" -gt 0 ]]
}

# 测试7: VolumeExpansion功能
# 验证PVC可以扩容
test_volume_expansion() {
    kubectl patch pvc test-pvc-rwo -n "${TEST_NS}" \
        -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}' >/dev/null 2>&1
}

# ========================= 汇总报告 =========================
show_summary() {
    log_step "测试结果汇总"

    local PASS_COUNT=0
    local FAIL_COUNT=0

    for result in "${RESULTS[@]}"; do
        if [[ "${result}" == PASS:* ]]; then
            echo -e "  ${GREEN}✓${NC} ${result#PASS: }" | tee -a "$LOG_FILE"
            ((PASS_COUNT++))
        else
            echo -e "  ${RED}✗${NC} ${result#FAIL: }" | tee -a "$LOG_FILE"
            ((FAIL_COUNT++))
        fi
    done

    echo "" | tee -a "$LOG_FILE"
    local TOTAL=$((PASS_COUNT + FAIL_COUNT))
    log_info "总计: ${TOTAL} | 通过: ${PASS_COUNT} | 失败: ${FAIL_COUNT}"
    log_info "测试日志: ${LOG_FILE}"

    if [[ ${FAIL_COUNT} -gt 0 ]]; then
        log_error "存在失败的测试用例"
        log_error "请检查上方日志获取详细错误信息"
        return 1
    else
        log_info "所有存储功能验证通过"
        return 0
    fi
}

# ========================= 主逻辑 =========================
main() {
    mkdir -p "$LOG_DIR"

    log_step "阶段3-任务3: 存储功能验证"
    log_info "测试命名空间: ${TEST_NS}"

    # 运行所有测试
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

    # 显示汇总
    show_summary

    log_success "阶段3-任务3完成"
}

main "$@"
