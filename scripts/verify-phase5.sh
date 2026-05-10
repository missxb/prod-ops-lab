#!/usr/bin/env bash
set -euo pipefail

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPORT_DIR="$PROJECT_DIR/reports"
REPORT_FILE="$REPORT_DIR/verify-phase5-$(date +%Y%m%d-%H%M%S).log"
TIMESTAMP_REPORT="$REPORT_DIR/verify-phase5-$(date +%Y%m%d-%H%M%S).txt"

# 加载共享库
source "$SCRIPT_DIR/lib/common.sh"

##############################################################################
# 阶段5: 应用部署验证
# 验证项目: 命名空间、Demo App、HPA、Service、Ingress、滚动更新
##############################################################################

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
section "阶段5: 应用部署验证"

# --- 5.1 命名空间检查 ---
section "5.1 命名空间检查"

for ns in dev prod; do
    if kubectl get namespace "$ns" &>/dev/null 2>&1; then
        pass "命名空间 $ns 存在"
    else
        warn "命名空间 $ns 不存在"
    fi
done

# --- 5.2 Demo App Pod检查 ---
section "5.2 Demo App Pod检查"

for ns in dev prod; do
    if kubectl get namespace "$ns" &>/dev/null 2>&1; then
        APP_PODS=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null || echo "")
        APP_COUNT=$(echo "$APP_PODS" | grep -c . 2>/dev/null || echo "0")
        RUNNING_COUNT=$(echo "$APP_PODS" | grep -c "Running" 2>/dev/null || echo "0")

        if [[ $APP_COUNT -gt 0 ]]; then
            if [[ $RUNNING_COUNT -eq $APP_COUNT ]]; then
                pass "$ns 命名空间应用Pod运行正常 ($RUNNING_COUNT/$APP_COUNT)"
            else
                fail "$ns 命名空间应用Pod异常 ($RUNNING_COUNT/$APP_COUNT 运行中)"
            fi
        else
            info "$ns 命名空间无Pod"
        fi
    fi
done

# --- 5.3 Service检查 ---
section "5.3 Service检查"

for ns in dev prod; do
    if kubectl get namespace "$ns" &>/dev/null 2>&1; then
        SVC_OUTPUT=$(kubectl get svc -n "$ns" --no-headers 2>/dev/null || echo "")
        SVC_COUNT=$(echo "$SVC_OUTPUT" | grep -c . 2>/dev/null || echo "0")
        if [[ $SVC_COUNT -gt 0 ]]; then
            pass "$ns 命名空间Service数量: $SVC_COUNT"
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                SVC_NAME=$(echo "$line" | awk '{print $1}')
                SVC_TYPE=$(echo "$line" | awk '{print $2}')
                SVC_IP=$(echo "$line" | awk '{print $3}')
                info "  Service: $SVC_NAME (Type: $SVC_TYPE, ClusterIP: $SVC_IP)"
            done <<< "$SVC_OUTPUT"
        fi
    fi
done

# --- 5.4 Ingress检查 ---
section "5.4 Ingress检查"

INGRESS_ALL=$(kubectl get ingress --all-namespaces --no-headers 2>/dev/null || echo "")
INGRESS_COUNT=$(echo "$INGRESS_ALL" | grep -c . 2>/dev/null || echo "0")

if [[ $INGRESS_COUNT -gt 0 ]]; then
    pass "Ingress资源数量: $INGRESS_COUNT"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        INGRESS_NS=$(echo "$line" | awk '{print $1}')
        INGRESS_NAME=$(echo "$line" | awk '{print $2}')
        info "  Ingress: $INGRESS_NAME (namespace: $INGRESS_NS)"
    done <<< "$INGRESS_ALL"
else
    info "未发现Ingress资源"
fi

# 检查Ingress Controller
INGRESS_NGINX_PODS=$(kubectl get pods -n ingress-nginx --no-headers 2>/dev/null || echo "")
if [[ -n "$INGRESS_NGINX_PODS" ]]; then
    INGRESS_NGINX_RUNNING=$(echo "$INGRESS_NGINX_PODS" | grep -c "Running" 2>/dev/null || echo "0")
    if [[ $INGRESS_NGINX_RUNNING -gt 0 ]]; then
        pass "Nginx Ingress Controller 运行正常"
    else
        warn "Nginx Ingress Controller 未运行"
    fi
else
    info "Nginx Ingress Controller 未部署"
fi

# --- 5.5 HPA检查 ---
section "5.5 HPA检查"

HPA_ALL=$(kubectl get hpa --all-namespaces --no-headers 2>/dev/null || echo "")
HPA_COUNT=$(echo "$HPA_ALL" | grep -c . 2>/dev/null || echo "0")

if [[ $HPA_COUNT -gt 0 ]]; then
    pass "HPA资源数量: $HPA_COUNT"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        HPA_NS=$(echo "$line" | awk '{print $1}')
        HPA_NAME=$(echo "$line" | awk '{print $2}')
        HPA_REPLICAS=$(echo "$line" | awk '{print $2}')
        info "  HPA: $HPA_NAME (namespace: $HPA_NS)"
    done <<< "$HPA_ALL"
else
    info "未发现HPA资源"
fi

# --- 5.6 ConfigMap/Secret检查 ---
section "5.6 ConfigMap/Secret检查"

for ns in dev prod; do
    if kubectl get namespace "$ns" &>/dev/null 2>&1; then
        CM_COUNT=$(kubectl get configmap -n "$ns" --no-headers 2>/dev/null | grep -c . 2>/dev/null || echo "0")
        SECRET_COUNT=$(kubectl get secret -n "$ns" --no-headers 2>/dev/null | grep -c . 2>/dev/null || echo "0")
        if [[ $CM_COUNT -gt 0 ]]; then
            pass "$ns ConfigMap数量: $CM_COUNT"
        fi
        if [[ $SECRET_COUNT -gt 0 ]]; then
            pass "$ns Secret数量: $SECRET_COUNT"
        fi
    fi
done

# --- 5.7 就绪/存活探针检查 ---
section "5.7 健康探针检查"

for ns in dev prod; do
    if kubectl get namespace "$ns" &>/dev/null 2>&1; then
        DEPLOYMENTS=$(kubectl get deployments -n "$ns" --no-headers 2>/dev/null || echo "")
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            DEPLOY_NAME=$(echo "$line" | awk '{print $1}')
            LIVENESS=$(kubectl get deployment "$DEPLOY_NAME" -n "$ns" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe}' 2>/dev/null || echo "")
            READINESS=$(kubectl get deployment "$DEPLOY_NAME" -n "$ns" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' 2>/dev/null || echo "")
            if [[ -n "$LIVENESS" && "$LIVENESS" != "null" ]]; then
                pass "$ns/$DEPLOY_NAME 有存活探针"
            else
                warn "$ns/$DEPLOY_NAME 缺少存活探针"
            fi
            if [[ -n "$READINESS" && "$READINESS" != "null" ]]; then
                pass "$ns/$DEPLOY_NAME 有就绪探针"
            else
                warn "$ns/$DEPLOY_NAME 缺少就绪探针"
            fi
        done <<< "$DEPLOYMENTS"
    fi
done

# --- 5.8 资源限制检查 ---
section "5.8 资源限制检查"

for ns in dev prod; do
    if kubectl get namespace "$ns" &>/dev/null 2>&1; then
        DEPLOYMENTS=$(kubectl get deployments -n "$ns" --no-headers 2>/dev/null || echo "")
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            DEPLOY_NAME=$(echo "$line" | awk '{print $1}')
            RESOURCES=$(kubectl get deployment "$DEPLOY_NAME" -n "$ns" -o jsonpath='{.spec.template.spec.containers[0].resources}' 2>/dev/null || echo "")
            if [[ -n "$RESOURCES" && "$RESOURCES" != "{}" ]]; then
                REQUESTS=$(echo "$RESOURCES" | grep -o '"requests"' || echo "")
                LIMITS=$(echo "$RESOURCES" | grep -o '"limits"' || echo "")
                if [[ -n "$REQUESTS" && -n "$LIMITS" ]]; then
                    pass "$ns/$DEPLOY_NAME 已配置资源限制和请求"
                elif [[ -n "$LIMITS" ]]; then
                    warn "$ns/$DEPLOY_NAME 仅配置了资源限制 (建议同时配置requests)"
                fi
            else
                warn "$ns/$DEPLOY_NAME 未配置资源限制"
            fi
        done <<< "$DEPLOYMENTS"
    fi
done

# --- 5.9 滚动更新状态检查 ---
section "5.9 滚动更新状态检查"

for ns in dev prod; do
    if kubectl get namespace "$ns" &>/dev/null 2>&1; then
        DEPLOYMENTS=$(kubectl get deployments -n "$ns" --no-headers 2>/dev/null || echo "")
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            DEPLOY_NAME=$(echo "$line" | awk '{print $1}')
            REPLICAS=$(echo "$line" | awk '{print $2}')
            AVAILABLE=$(echo "$line" | awk '{print $4}')
            UPDATED=$(echo "$line" | awk '{print $6}')
            if [[ "$REPLICAS" == "$AVAILABLE" && "$REPLICAS" == "$UPDATED" ]]; then
                pass "$ns/$DEPLOY_NAME 滚动更新完成 ($UPDATED/$REPLICAS)"
            elif [[ "$UPDATED" != "0" ]]; then
                warn "$ns/$DEPLOY_NAME 滚动更新进行中 ($UPDATED/$REPLICAS)"
            fi
        done <<< "$DEPLOYMENTS"
    fi
done

# ========== 验证报告 ==========
section "验证汇总"

echo ""
log "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
log "${CYAN}║          阶段5: 应用部署验证报告                ║${NC}"
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
