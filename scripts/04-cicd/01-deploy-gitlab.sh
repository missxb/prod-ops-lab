#!/usr/bin/env bash
#==============================================================================
# 01-deploy-gitlab.sh - Deploy GitLab CE with Helm
# Enterprise Cloud Native Platform - Phase 4
#
# Description:
#   Deploys GitLab Community Edition using Helm chart with TLS,
#   persistent storage, ingress configuration, and secrets.
#
# Usage:
#   ./01-deploy-gitlab.sh [deploy|verify|credentials|delete]
#
#   deploy      - Full GitLab deployment (default)
#   verify      - Verify GitLab is running
#   credentials - Show GitLab login credentials
#   delete      - Remove GitLab deployment
#
# Environment Variables:
#   DOMAIN  - Base domain for GitLab (default: example.com)
#
# Examples:
#   ./01-deploy-gitlab.sh
#   DOMAIN=corp.example.com ./01-deploy-gitlab.sh deploy
#   ./01-deploy-gitlab.sh credentials
#==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_DIR="${PROJECT_ROOT}/configs/gitlab"

# Configuration
NAMESPACE="gitlab"
RELEASE_NAME="gitlab"
CHART_REPO="https://charts.gitlab.io/"
CHART_VERSION="7.14.0"
VALUES_FILE="${CONFIG_DIR}/gitlab-values.yaml"
DOMAIN="${DOMAIN:-example.com}"
LOG_PREFIX="[GitLab]"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}${LOG_PREFIX} [INFO] $(date '+%H:%M:%S') $*${NC}"; }
log_warn()  { echo -e "${YELLOW}${LOG_PREFIX} [WARN] $(date '+%H:%M:%S') $*${NC}"; }
log_error() { echo -e "${RED}${LOG_PREFIX} [ERROR] $(date '+%H:%M:%S') $*${NC}"; }

# check_prereqs - 检查必需工具和 Helm 仓库
check_prereqs() {
    log_info "Checking prerequisites..."
    
    for cmd in kubectl helm openssl; do
        if ! command -v "${cmd}" &>/dev/null; then
            log_error "Required command not found: ${cmd}"
            log_error "Please install ${cmd} before running this script"
            exit 1
        fi
    done
    
    # 验证 Kubernetes 集群连接
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    
    # 检查并添加 GitLab Helm 仓库
    if ! helm repo list 2>/dev/null | grep -q gitlab; then
        log_info "Adding GitLab Helm repository..."
        helm repo add gitlab "${CHART_REPO}" --force-update
        helm repo update
    fi
    
    log_info "Prerequisites satisfied"
}

# create_namespace - 创建 GitLab 命名空间并设置标签
# 应用 purpose=source-control, team=devops, environment=production 标签
create_namespace() {
    log_info "Creating namespace: ${NAMESPACE}"
    
    kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    
    kubectl label namespace "${NAMESPACE}" \
        purpose=source-control \
        team=devops \
        environment=production \
        app.kubernetes.io/managed-by=helm \
        --overwrite
    
    # 验证命名空间创建成功
    if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
        log_info "Namespace ${NAMESPACE} verified"
    else
        log_error "Failed to create namespace ${NAMESPACE}"
        exit 1
    fi
}

# create_secrets - 创建 GitLab 所需的所有 Kubernetes Secrets
# 包括: root 密码, Rails secrets, SSH host key
create_secrets() {
    log_info "Creating secrets..."
    
    # 创建初始 root 密码 Secret
    local root_password
    root_password=$(openssl rand -base64 24 | tr -d '=+/' || true)
    if [[ -z "${root_password}" ]]; then
        log_error "Failed to generate root password"
        exit 1
    fi
    
    kubectl create secret generic gitlab-initial-root-password \
        --from-literal=password="${root_password}" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # 创建 Rails secrets
    kubectl create secret generic gitlab-rails-secret \
        --from-literal=base="$(openssl rand -hex 64)" \
        --from-literal=otp_key_base="$(openssl rand -hex 64)" \
        --from-literal=secret_key_base="$(openssl rand -hex 64)" \
        --from-literal=otp_key="$(openssl rand -hex 32)" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # 创建 SSH host key
    local key_dir="/tmp/gitlab-ssh-keys"
    mkdir -p "${key_dir}"
    if ! ssh-keygen -t rsa -b 4096 -f "${key_dir}/ssh-host-key" -N "" -q 2>/dev/null; then
        log_warn "Failed to generate SSH key, using existing or default"
    fi
    
    if [[ -f "${key_dir}/ssh-host-key" ]]; then
        kubectl create secret generic gitlab-gitlab-shell-host-keys \
            --from-file=ssh-host-key="${key_dir}/ssh-host-key" \
            -n "${NAMESPACE}" \
            --dry-run=client -o yaml | kubectl apply -f -
        rm -rf "${key_dir}"
    fi
    
    # 验证 Secrets 创建成功
    local secret_count
    secret_count=$(kubectl get secrets -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l)
    log_info "Secrets created (${secret_count} total in namespace)"
}

# setup_storage - 检查 Longhorn StorageClass 可用性
# GitLab 需要持久化存储，Longhorn 是必需的
setup_storage() {
    log_info "检查 Longhorn StorageClass..."

    # 检查 Longhorn StorageClass 是否存在
    if kubectl get storageclass longhorn &>/dev/null; then
        log_info "检测到 Longhorn StorageClass，GitLab 将使用 Longhorn 持久化存储"
    else
        log_error "Longhorn StorageClass 不存在！"
        log_error "GitLab 需要可靠的持久化存储来保存数据。"
        log_error ""
        log_error "请先部署 Longhorn:"
        log_error "  1. kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.5.3/deploy/longhorn.yaml"
        log_error "  2. 或运行: bash scripts/03-storage/deploy-storage.sh"
        log_error "  3. 等待所有 Longhorn 节点就绪后再重新运行此脚本"
        log_error ""
        log_error "验证 Longhorn 状态:"
        log_error "  kubectl get storageclass longhorn"
        log_error "  kubectl get pods -n longhorn-system"
        exit 1
    fi

    # 检查 Longhorn 组件是否就绪
    local longhorn_pods_not_ready
    longhorn_pods_not_ready=$(kubectl get pods -n longhorn-system --no-headers 2>/dev/null | grep -cv "Running\|Completed" || true)
    if [[ "${longhorn_pods_not_ready}" -gt 0 ]]; then
        log_warn "Longhorn 有 ${longhorn_pods_not_ready} 个 Pod 未就绪，可能影响存储性能"
        log_warn "建议等待 Longhorn 完全就绪后再部署 GitLab"
    fi

    # 检查是否至少有一个节点可用
    local longhorn_ready_nodes
    longhorn_ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready" || true)
    if [[ "${longhorn_ready_nodes}" -lt 1 ]]; then
        log_error "集群中没有 Ready 状态的节点，Longhorn 无法正常工作"
        exit 1
    fi

    log_info "Longhorn StorageClass 验证通过"
}

# deploy_gitlab - 使用 Helm 安装/升级 GitLab CE
# 使用 --atomic 标志确保部署失败时自动回滚
deploy_gitlab() {
    log_info "Deploying GitLab CE..."
    
    # 验证 values 文件存在
    if [[ ! -f "${VALUES_FILE}" ]]; then
        log_error "Values file not found: ${VALUES_FILE}"
        log_error "Please create the values file before deploying"
        exit 1
    fi
    
    if helm upgrade --install "${RELEASE_NAME}" gitlab/gitlab \
        --namespace "${NAMESPACE}" \
        --values "${VALUES_FILE}" \
        --set global.hosts.domain="${DOMAIN}" \
        --set global.hosts.externalIP="" \
        --set certmanager.installCRDs=false \
        --timeout 15m \
        --wait \
        --atomic; then
        log_info "GitLab Helm release deployed successfully"
    else
        log_error "GitLab Helm release deployment failed"
        log_error "Check 'helm history ${RELEASE_NAME} -n ${NAMESPACE}' for details"
        exit 1
    fi
}

# wait_for_ready - 等待所有 GitLab 组件 Pod 就绪
# 逐个检查 webservice, sidekiq, toolbox, gitaly, gitlab-shell, registry 组件
wait_for_ready() {
    log_info "Waiting for GitLab components to be ready..."
    
    local components=("webservice" "sidekiq" "toolbox" "gitaly" "gitlab-shell" "registry")
    local timeout=900
    local ready_count=0
    
    for component in "${components[@]}"; do
        log_info "Waiting for ${component} (timeout: ${timeout}s)..."
        if kubectl wait --for=condition=ready pod \
            -l "app=${component}" \
            -n "${NAMESPACE}" \
            --timeout="${timeout}s" 2>/dev/null; then
            log_info "${component} is ready"
            ((ready_count++))
        elif kubectl wait --for=condition=ready pod \
            -l "app.kubernetes.io/name=${component}" \
            -n "${NAMESPACE}" \
            --timeout="${timeout}s" 2>/dev/null; then
            log_info "${component} is ready"
            ((ready_count++))
        else
            log_warn "Timeout waiting for ${component} (may still be starting)"
        fi
    done
    
    log_info "Component readiness: ${ready_count}/${#components[@]} ready"
}

# configure_ingress - 配置 GitLab Ingress 规则
# 设置 HTTPS 重定向、代理超时、TLS 终止
configure_ingress() {
    log_info "Configuring ingress..."
    
    local gitlab_host="gitlab.${DOMAIN}"
    
    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gitlab-ingress
  namespace: ${NAMESPACE}
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "250m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "300"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - ${gitlab_host}
        - registry.${gitlab_host}
        - minio.${gitlab_host}
      secretName: gitlab-tls-secret
  rules:
    - host: ${gitlab_host}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: gitlab-webservice-default
                port:
                  number: 8080
    - host: registry.${gitlab_host}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: gitlab-registry
                port:
                  number: 5000
    - host: minio.${gitlab_host}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: gitlab-minio
                port:
                  number: 9000
EOF
    
    # 验证 Ingress 创建成功
    if kubectl get ingress gitlab-ingress -n "${NAMESPACE}" &>/dev/null; then
        log_info "Ingress configured for ${gitlab_host}"
    else
        log_warn "Ingress configuration may not have been applied"
    fi
}

# verify_deployment - 验证 GitLab 部署状态
# 检查 Pod、Service、PVC、Ingress 和最近事件
verify_deployment() {
    log_info "Verifying GitLab deployment..."
    
    local issues=0
    
    # 检查 Pods 状态
    log_info "--- Pods ---"
    kubectl get pods -n "${NAMESPACE}" -o wide
    
    # 检查是否有异常 Pod
    local not_running
    not_running=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -cv "Running\|Completed" || true)
    if [[ "${not_running}" -gt 0 ]]; then
        log_warn "${not_running} pods are not in Running state"
        ((issues++))
    fi
    
    # 检查 Services
    log_info "--- Services ---"
    kubectl get svc -n "${NAMESPACE}" -o wide
    
    # 检查 PVC 状态
    log_info "--- Persistent Volume Claims ---"
    kubectl get pvc -n "${NAMESPACE}" -o wide
    local pending_pvc
    pending_pvc=$(kubectl get pvc -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -c "Pending" || true)
    if [[ "${pending_pvc}" -gt 0 ]]; then
        log_warn "${pending_pvc} PVCs are in Pending state"
    fi
    
    # 检查 Ingress
    log_info "--- Ingress ---"
    kubectl get ingress -n "${NAMESPACE}" -o wide
    
    # 检查最近事件中的错误
    log_info "--- Recent Events (last 20) ---"
    kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' 2>/dev/null | tail -20
    
    if [[ "${issues}" -eq 0 ]]; then
        log_info "Verification complete - no issues detected"
    else
        log_warn "Verification complete - ${issues} issues detected"
    fi
}

# Get initial credentials
get_credentials() {
    log_info "Retrieving credentials..."
    
    local password
    password=$(kubectl get secret gitlab-initial-root-password \
        -n "${NAMESPACE}" \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
    
    cat <<EOF

================================================================
  GitLab Credentials
================================================================
  URL:      https://gitlab.${DOMAIN}
  Username: root
  Password: ${password}
================================================================

  IMPORTANT: Change the initial root password immediately!
  
  Next steps:
  1. Access GitLab web interface
  2. Create your first project
  3. Configure SSH keys for Git access
  4. Set up CI/CD runners
================================================================

EOF
}

# Main
main() {
    local action="${1:-deploy}"
    
    log_info "============================================"
    log_info "  GitLab CE Deployment"
    log_info "  Domain: ${DOMAIN}"
    log_info "============================================"
    
    case "${action}" in
        deploy)
            check_prereqs
            create_namespace
            create_secrets
            setup_storage
            deploy_gitlab
            wait_for_ready
            configure_ingress
            verify_deployment
            get_credentials
            ;;
        verify)
            verify_deployment
            ;;
        credentials)
            get_credentials
            ;;
        delete)
            log_warn "Deleting GitLab deployment..."
            helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --wait
            kubectl delete pvc --all -n "${NAMESPACE}" 2>/dev/null || true
            kubectl delete namespace "${NAMESPACE}" 2>/dev/null || true
            log_info "GitLab deleted"
            ;;
        *)
            echo "Usage: $0 {deploy|verify|credentials|delete}"
            exit 1
            ;;
    esac
}

main "$@"
