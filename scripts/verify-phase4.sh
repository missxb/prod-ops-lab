#!/usr/bin/env bash
set -euo pipefail

# 加载共享库
source "$SCRIPT_DIR/lib/common.sh"

##############################################################################
# 阶段4: CI/CD流水线验证
# 验证项目: GitLab、Jenkins、Harbor、Trivy、Pipeline
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPORT_DIR="$PROJECT_DIR/reports"
REPORT_FILE="$REPORT_DIR/verify-phase4-$(date +%Y%m%d-%H%M%S).log"
TIMESTAMP_REPORT="$REPORT_DIR/verify-phase4-$(date +%Y%m%d-%H%M%S).txt"

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

check_service_pod() {
    local namespace="$1"
    local label="$2"
    local name="$3"

    if kubectl get namespace "$namespace" &>/dev/null 2>&1; then
        PODS=$(kubectl get pods -n "$namespace" -l "$label" --no-headers 2>/dev/null || echo "")
        if [[ -z "$PODS" ]]; then
            PODS=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null || echo "")
        fi
        RUNNING=$(echo "$PODS" | grep -c "Running" 2>/dev/null || echo "0")
        TOTAL=$(echo "$PODS" | grep -c . 2>/dev/null || echo "0")
        if [[ $RUNNING -gt 0 ]]; then
            pass "$name Pod 运行正常 ($RUNNING/$TOTAL) [namespace: $namespace]"
        elif [[ $TOTAL -gt 0 ]]; then
            fail "$name Pod 异常 ($RUNNING/$TOTAL 运行中)"
        else
            warn "$name: namespace $namespace 中无Pod"
        fi
    else
        warn "$name: namespace $namespace 不存在"
    fi
}

# ========== 开始验证 ==========
section "阶段4: CI/CD流水线验证"

# --- 4.1 GitLab检查 ---
section "4.1 GitLab检查"

check_service_pod "gitlab" "app=gitlab" "GitLab"

# 检查GitLab Service/Ingress
GITLAB_SVC=$(kubectl get svc -n gitlab --no-headers 2>/dev/null || echo "")
if [[ -n "$GITLAB_SVC" ]]; then
    pass "GitLab Service 存在"
else
    warn "GitLab Service 不存在"
fi

GITLAB_INGRESS=$(kubectl get ingress -n gitlab --no-headers 2>/dev/null || echo "")
if [[ -n "$GITLAB_INGRESS" ]]; then
    pass "GitLab Ingress 配置存在"
else
    info "GitLab 未配置Ingress (可能使用NodePort)"
fi

# --- 4.2 Jenkins检查 ---
section "4.2 Jenkins检查"

check_service_pod "jenkins" "app=jenkins" "Jenkins"

JENKINS_SVC=$(kubectl get svc -n jenkins --no-headers 2>/dev/null || echo "")
if [[ -n "$JENKINS_SVC" ]]; then
    pass "Jenkins Service 存在"
else
    warn "Jenkins Service 不存在"
fi

JENKINS_INGRESS=$(kubectl get ingress -n jenkins --no-headers 2>/dev/null || echo "")
if [[ -n "$JENKINS_INGRESS" ]]; then
    pass "Jenkins Ingress 配置存在"
fi

# --- 4.3 Harbor检查 ---
section "4.3 Harbor检查"

check_service_pod "harbor" "app=harbor" "Harbor"

HARBOR_SVC=$(kubectl get svc -n harbor --no-headers 2>/dev/null || echo "")
if [[ -n "$HARBOR_SVC" ]]; then
    pass "Harbor Service 存在"
else
    warn "Harbor Service 不存在"
fi

# 检查Harbor组件
for component in core registry notary jobservice; do
    COMP_PODS=$(kubectl get pods -n harbor -l "component=$component" --no-headers 2>/dev/null || echo "")
    if [[ -n "$COMP_PODS" ]] && echo "$COMP_PODS" | grep -q "Running"; then
        pass "Harbor $component 运行正常"
    fi
done

# --- 4.4 Trivy检查 ---
section "4.4 Trivy检查"

check_service_pod "trivy" "app=trivy" "Trivy"

# --- 4.5 Pipeline/Workflow检查 ---
section "4.5 Pipeline配置检查"

# 检查Jenkins Pipeline配置
JENKINS_CONFIG=$(kubectl get configmap -n jenkins --no-headers 2>/dev/null || echo "")
if [[ -n "$JENKINS_CONFIG" ]]; then
    pass "Jenkins 配置文件存在"
else
    info "Jenkins ConfigMap 未发现"
fi

# 检查Harbor项目
HARBOR_SVC_IP=$(kubectl get svc -n harbor harbor-core -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
if [[ -n "$HARBOR_SVC_IP" ]]; then
    pass "Harbor Core Service IP: $HARBOR_SVC_IP"
else
    info "无法获取Harbor Core Service IP"
fi

# --- 4.6 PVC检查 ---
section "4.6 CI/CD存储PVC检查"

for ns in gitlab jenkins harbor; do
    PVC_OUTPUT=$(kubectl get pvc -n "$ns" --no-headers 2>/dev/null || echo "")
    PVC_COUNT=$(echo "$PVC_OUTPUT" | grep -c . 2>/dev/null || echo "0")
    BOUND_COUNT=$(echo "$PVC_OUTPUT" | grep -c "Bound" 2>/dev/null || echo "0")
    if [[ $PVC_COUNT -gt 0 ]]; then
        if [[ $BOUND_COUNT -eq $PVC_COUNT ]]; then
            pass "$ns PVC 已全部绑定 ($BOUND_COUNT/$PVC_COUNT)"
        else
            fail "$ns PVC 部分未绑定 ($BOUND_COUNT/$PVC_COUNT)"
        fi
    fi
done

# ========== 验证报告 ==========
section "验证汇总"

echo ""
log "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
log "${CYAN}║          阶段4: CI/CD流水线验证报告             ║${NC}"
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
