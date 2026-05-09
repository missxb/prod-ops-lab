#!/usr/bin/env bash
set -euo pipefail

# 加载共享库
source "$SCRIPT_DIR/lib/common.sh"

##############################################################################
# 阶段3: 存储层配置验证
# 验证项目: StorageClass、NFS Provisioner、PVC动态绑定
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPORT_DIR="$PROJECT_DIR/reports"
REPORT_FILE="$REPORT_DIR/verify-phase3-$(date +%Y%m%d-%H%M%S).log"
TIMESTAMP_REPORT="$REPORT_DIR/verify-phase3-$(date +%Y%m%d-%H%M%S).txt"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
TOTAL_COUNT=0

mkdir -p "$REPORT_DIR"

log() { local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"; echo -e "$msg"; echo "$msg" >> "$REPORT_FILE"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); TOTAL_COUNT=$((TOTAL_COUNT + 1)); log "${GREEN}[PASS]${NC} $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); TOTAL_COUNT=$((TOTAL_COUNT + 1)); log "${RED}[FAIL]${NC} $1"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); TOTAL_COUNT=$((TOTAL_COUNT + 1)); log "${YELLOW}[WARN]${NC} $1"; }
info() { log "${BLUE}[INFO]${NC} $1"; }
section() { echo ""; log "${CYAN}========== $1 ==========${NC}"; }

if ! command -v kubectl &>/dev/null; then
    echo -e "${RED}错误: kubectl 命令不可用${NC}"
    exit 1
fi

# ========== 开始验证 ==========
section "阶段3: 存储层配置验证"

# --- 3.1 StorageClass检查 ---
section "3.1 StorageClass检查"

SC_OUTPUT=$(kubectl get sc --no-headers 2>/dev/null || echo "")
SC_COUNT=$(echo "$SC_OUTPUT" | grep -c . 2>/dev/null || echo "0")

if [[ $SC_COUNT -gt 0 ]]; then
    pass "StorageClass 数量: $SC_COUNT"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        SC_NAME=$(echo "$line" | awk '{print $1}')
        PROVISIONER=$(echo "$line" | awk '{print $2}')
        info "  StorageClass: $SC_NAME (provisioner: $PROVISIONER)"
    done <<< "$SC_OUTPUT"
else
    fail "未发现任何 StorageClass"
fi

# 检查默认StorageClass
DEFAULT_SC=$(kubectl get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$DEFAULT_SC" ]]; then
    pass "默认StorageClass: $DEFAULT_SC"
else
    warn "未设置默认StorageClass"
fi

# --- 3.2 NFS Provisioner检查 ---
section "3.2 NFS Provisioner检查"

NFS_NS=""
for ns in nfs-provisioner default kube-system; do
    if kubectl get namespace "$ns" &>/dev/null 2>&1; then
        NFS_PODS=$(kubectl get pods -n "$ns" -l app=nfs-subdir-external-provisioner --no-headers 2>/dev/null || echo "")
        if [[ -z "$NFS_PODS" ]]; then
            NFS_PODS=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -i nfs || echo "")
        fi
        if [[ -n "$NFS_PODS" ]]; then
            NFS_NS="$ns"
            break
        fi
    fi
done

if [[ -n "$NFS_NS" ]]; then
    NFS_RUNNING=$(echo "$NFS_PODS" | grep -c "Running" 2>/dev/null || echo "0")
    NFS_TOTAL=$(echo "$NFS_PODS" | grep -c . 2>/dev/null || echo "0")
    if [[ $NFS_RUNNING -gt 0 ]]; then
        pass "NFS Provisioner 运行正常 ($NFS_RUNNING/$NFS_TOTAL) [namespace: $NFS_NS]"
    else
        fail "NFS Provisioner Pod 异常"
    fi
else
    warn "未发现 NFS Provisioner Pod"
fi

# --- 3.3 PersistentVolume检查 ---
section "3.3 PersistentVolume检查"

PV_OUTPUT=$(kubectl get pv --no-headers 2>/dev/null || echo "")
PV_COUNT=$(echo "$PV_OUTPUT" | grep -c . 2>/dev/null || echo "0")

if [[ $PV_COUNT -gt 0 ]]; then
    pass "PersistentVolume 数量: $PV_COUNT"
else
    info "PersistentVolume 数量: 0 (动态Provisioning模式下正常)"
fi

# --- 3.4 PersistentVolumeClaim检查 ---
section "3.4 PersistentVolumeClaim检查"

PVC_OUTPUT=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null || echo "")
PVC_COUNT=$(echo "$PVC_OUTPUT" | grep -c . 2>/dev/null || echo "0")

if [[ $PVC_COUNT -gt 0 ]]; then
    pass "PersistentVolumeClaim 数量: $PVC_COUNT"

    BOUND_COUNT=$(echo "$PVC_OUTPUT" | grep -c "Bound" 2>/dev/null || echo "0")
    PENDING_COUNT=$(echo "$PVC_OUTPUT" | grep -c "Pending" 2>/dev/null || echo "0")

    if [[ $BOUND_COUNT -gt 0 ]]; then
        pass "已绑定PVC: $BOUND_COUNT"
    fi
    if [[ $PENDING_COUNT -gt 0 ]]; then
        fail "Pending状态PVC: $PENDING_COUNT"
    fi
    if [[ $PENDING_COUNT -eq 0 && $BOUND_COUNT -eq $PVC_COUNT ]]; then
        pass "所有PVC均已绑定"
    fi
else
    info "当前无PVC (可通过创建测试PVC验证存储功能)"
fi

# --- 3.5 挂载测试 ---
section "3.5 NFS挂载点检查"

if [[ -d /mnt ]]; then
    MOUNT_POINTS=$(mount | grep -c "nfs" 2>/dev/null || echo "0")
    if [[ $MOUNT_POINTS -gt 0 ]]; then
        pass "NFS挂载点: $MOUNT_POINTS"
    else
        info "当前无活跃NFS挂载点"
    fi
else
    info "/mnt 目录不存在"
fi

# ========== 验证报告 ==========
section "验证汇总"

echo ""
log "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
log "${CYAN}║          阶段3: 存储层验证报告                  ║${NC}"
log "${CYAN}╠══════════════════════════════════════════════════╣${NC}"
log "${CYAN}║${NC} 总检查项:  ${TOTAL_COUNT}                                    ${CYAN}║${NC}"
log "${GREEN}║${NC} 通过:      ${PASS_COUNT}                                    ${GREEN}║${NC}"
log "${RED}║${NC} 失败:      ${FAIL_COUNT}                                    ${RED}║${NC}"
log "${YELLOW}║${NC} 警告:      ${WARN_COUNT}                                    ${YELLOW}║${NC}"
log "${CYAN}╠══════════════════════════════════════════════════╣${NC}"

if [[ $FAIL_COUNT -eq 0 ]]; then
    if [[ $WARN_COUNT -eq 0 ]]; then
        log "${GREEN}║  结果: ✓ 全部通过                               ║${NC}"
    else
        log "${YELLOW}║  结果: △ 通过(有警告)                           ║${NC}"
    fi
else
    log "${RED}║  结果: ✗ 存在失败项                             ║${NC}"
fi

log "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
log ""
log "报告已保存: $REPORT_FILE"

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
