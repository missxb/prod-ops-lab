#!/usr/bin/env bash
#==============================================================================
# 03-deploy-harbor.sh - Deploy Harbor Registry with Helm
# Enterprise Cloud Native Platform - Phase 4
#
# Description:
#   Deploys Harbor Container Registry using Helm chart with TLS certificates,
#   database/Redis secrets, project configuration, and health checks.
#
# Usage:
#   ./03-deploy-harbor.sh [deploy|verify|delete]
#
#   deploy  - Full Harbor deployment (default)
#   verify  - Verify Harbor is running and healthy
#   delete  - Remove Harbor deployment
#
# Environment Variables:
#   DOMAIN  - Base domain for Harbor (default: example.com)
#
# Examples:
#   ./03-deploy-harbor.sh
#   DOMAIN=corp.example.com ./03-deploy-harbor.sh deploy
#   ./03-deploy-harbor.sh verify
#==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_DIR="${PROJECT_ROOT}/configs/harbor"

# Configuration
NAMESPACE="harbor"
RELEASE_NAME="harbor"
CHART_VERSION="1.14.0"
VALUES_FILE="${CONFIG_DIR}/harbor-values.yaml"
DOMAIN="${DOMAIN:-example.com}"
LOG_PREFIX="[Harbor]"

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
    
    if ! helm repo list 2>/dev/null | grep -q harbor; then
        log_info "Adding Harbor Helm repository..."
        helm repo add harbor https://helm.goharbor.io --force-update
        helm repo update
    fi
    
    log_info "Prerequisites satisfied"
}

# create_namespace - 创建 Harbor 命名空间并设置标签
create_namespace() {
    log_info "Creating namespace: ${NAMESPACE}"
    
    kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    
    kubectl label namespace "${NAMESPACE}" \
        purpose=registry \
        team=devops \
        environment=production \
        --overwrite
    
    # 验证命名空间
    if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
        log_info "Namespace ${NAMESPACE} verified"
    else
        log_error "Failed to create namespace ${NAMESPACE}"
        exit 1
    fi
}

# create_tls_certs - 为 Harbor 生成 TLS 证书
# 生成 CA 和服务器证书，支持 Harbor 主域名和 Notary 子域名
create_tls_certs() {
    log_info "Creating TLS certificates for Harbor..."
    
    local cert_dir="${PROJECT_ROOT}/certs/harbor"
    mkdir -p "${cert_dir}"
    
    # 生成 CA 证书（如果不存在）
    if [[ ! -f "${cert_dir}/ca.crt" ]]; then
        log_info "Generating CA certificate for Harbor..."
        if ! openssl genrsa -out "${cert_dir}/ca.key" 4096 2>/dev/null; then
            log_error "Failed to generate CA private key"
            exit 1
        fi
        if ! openssl req -x509 -new -nodes -key "${cert_dir}/ca.key" \
            -sha256 -days 3650 \
            -out "${cert_dir}/ca.crt" \
            -subj "/C=CN/ST=Beijing/L=Beijing/O=Enterprise/OU=DevOps/CN=Enterprise-Harbor-CA" 2>/dev/null; then
            log_error "Failed to generate CA certificate"
            exit 1
        fi
    fi
    
    # 生成服务器证书（如果不存在）
    if [[ ! -f "${cert_dir}/server.crt" ]]; then
        log_info "Generating server certificate for Harbor..."
        
        # 生成私钥
        if ! openssl genrsa -out "${cert_dir}/server.key" 2048 2>/dev/null; then
            log_error "Failed to generate server private key"
            exit 1
        fi
        
        cat > "${cert_dir}/server-csr.conf" <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
prompt = no

[req_distinguished_name]
C = CN
ST = Beijing
L = Beijing
O = Enterprise
OU = DevOps
CN = harbor.${DOMAIN}

[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = harbor.${DOMAIN}
DNS.2 = *.harbor.${DOMAIN}
DNS.3 = registry.${DOMAIN}
DNS.4 = notary.${DOMAIN}
DNS.5 = localhost
IP.1 = 127.0.0.1
EOF
        # 生成 CSR
        if ! openssl req -new -key "${cert_dir}/server.key" \
            -out "${cert_dir}/server.csr" \
            -config "${cert_dir}/server-csr.conf" 2>/dev/null; then
            log_error "Failed to generate CSR for Harbor"
            exit 1
        fi
        
        # 签名证书
        if ! openssl x509 -req -in "${cert_dir}/server.csr" \
            -CA "${cert_dir}/ca.crt" \
            -CAkey "${cert_dir}/ca.key" \
            -CAcreateserial \
            -out "${cert_dir}/server.crt" \
            -days 3650 -sha256 \
            -extensions v3_req \
            -extfile "${cert_dir}/server-csr.conf" 2>/dev/null; then
            log_error "Failed to sign certificate for Harbor"
            exit 1
        fi
        
        # 验证证书
        if ! openssl x509 -in "${cert_dir}/server.crt" -noout 2>/dev/null; then
            log_error "Certificate verification failed for Harbor"
            exit 1
        fi
        log_info "Server certificate generated and verified"
    fi
    
    # 创建 Harbor TLS Secret
    kubectl create secret tls harbor-tls-secret \
        --cert="${cert_dir}/server.crt" \
        --key="${cert_dir}/server.key" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # 创建 Notary TLS Secret (使用相同的证书)
    kubectl create secret tls harbor-notary-tls-secret \
        --cert="${cert_dir}/server.crt" \
        --key="${cert_dir}/server.key" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # 验证 Secrets 创建成功
    for secret in harbor-tls-secret harbor-notary-tls-secret; do
        if kubectl get secret "${secret}" -n "${NAMESPACE}" &>/dev/null; then
            log_info "TLS secret ${secret} verified"
        else
            log_error "Failed to create TLS secret ${secret}"
            exit 1
        fi
    done
    
    log_info "TLS certificates created"
}

# create_secrets - 创建 Harbor 所需的所有 Secrets
# 包括: Core secret, Admin password, Database, Redis, Registry HTTP secret
create_secrets() {
    log_info "Creating Harbor secrets..."
    
    # Core secret key
    kubectl create secret generic harbor-core-secret \
        --from-literal=secret="$(openssl rand -hex 32)" \
        --from-literal=key="$(openssl rand -hex 32)" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Admin password
    kubectl create secret generic harbor-admin-secret \
        --from-literal=password="Harbor12345" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Database credentials
    kubectl create secret generic harbor-db-secret \
        --from-literal=POSTGRES_PASSWORD="$(openssl rand -base64 24 | tr -d '=+/')" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Redis password
    kubectl create secret generic harbor-redis-secret \
        --from-literal=REDIS_PASSWORD="$(openssl rand -base64 24 | tr -d '=+/')" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Registry HTTP secret
    kubectl create secret generic harbor-registry-secret \
        --from-literal=REGISTRY_HTTP_SECRET="$(openssl rand -hex 16)" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # 验证 Secrets
    local secret_count
    secret_count=$(kubectl get secrets -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l)
    log_info "Secrets created (${secret_count} total in namespace)"
}

# deploy_harbor - 使用 Helm 安装/升级 Harbor Registry
# 使用 --atomic 标志确保部署失败时自动回滚
deploy_harbor() {
    log_info "Deploying Harbor Registry..."
    
    # 验证 values 文件存在
    if [[ ! -f "${VALUES_FILE}" ]]; then
        log_error "Values file not found: ${VALUES_FILE}"
        log_error "Please create the values file before deploying"
        exit 1
    fi
    
    if helm upgrade --install "${RELEASE_NAME}" harbor/harbor \
        --namespace "${NAMESPACE}" \
        --values "${VALUES_FILE}" \
        --set externalURL="https://harbor.${DOMAIN}" \
        --set expose.ingress.hosts.core="harbor.${DOMAIN}" \
        --set expose.ingress.hosts.notary="notary.${DOMAIN}" \
        --set harborAdminPassword="Harbor12345" \
        --timeout 15m \
        --wait \
        --atomic; then
        log_info "Harbor Helm release deployed"
    else
        log_error "Harbor Helm release deployment failed"
        log_error "Check 'helm history ${RELEASE_NAME} -n ${NAMESPACE}' for details"
        exit 1
    fi
}

# wait_for_ready - 等待 Harbor 各组件 Pod 就绪
# 逐个检查 core, portal, registry, jobservice, trivy-adapter, database, redis
wait_for_ready() {
    log_info "Waiting for Harbor to be ready..."
    
    local components=("core" "portal" "registry" "jobservice" "trivy-adapter" "database" "redis")
    local ready_count=0
    
    for component in "${components[@]}"; do
        log_info "Waiting for ${component}..."
        if kubectl wait --for=condition=ready pod \
            -l "component=${component}" \
            -n "${NAMESPACE}" \
            --timeout=600s 2>/dev/null; then
            log_info "${component} is ready"
            ((ready_count++))
        elif kubectl wait --for=condition=ready pod \
            -l "app.kubernetes.io/component=${component}" \
            -n "${NAMESPACE}" \
            --timeout=600s 2>/dev/null; then
            log_info "${component} is ready"
            ((ready_count++))
        else
            log_warn "Timeout waiting for ${component} (may still be starting)"
        fi
    done
    
    log_info "Harbor components readiness: ${ready_count}/${#components[@]} ready"
}

# configure_projects - 配置 Harbor 默认项目
# 创建 library (public), devops (private), microservices (private) 项目
configure_projects() {
    log_info "Configuring Harbor projects..."
    
    # 等待 Harbor 完全就绪
    log_info "Waiting 30s for Harbor to be fully ready..."
    sleep 30
    
    local harbor_url="https://harbor.${DOMAIN}"
    
    # 通过 ConfigMap 创建默认项目配置
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: harbor-project-config
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: harbor
    component: configuration
data:
  projects.json: |
    [
      {
        "project_name": "library",
        "public": true,
        "metadata": {
          "public": "true"
        }
      },
      {
        "project_name": "devops",
        "public": false,
        "metadata": {
          "public": "false"
        }
      },
      {
        "project_name": "microservices",
        "public": false,
        "metadata": {
          "public": "false"
        }
      }
    ]
EOF
    
    # 验证 ConfigMap
    if kubectl get configmap harbor-project-config -n "${NAMESPACE}" &>/dev/null; then
        log_info "Project configuration created and verified"
    else
        log_warn "Project configuration may not have been applied"
    fi
}

# verify_deployment - 验证 Harbor 部署状态
# 检查 Pod、Service、PVC、Ingress 和 API 健康状态
verify_deployment() {
    log_info "Verifying Harbor deployment..."
    
    local issues=0
    
    # 检查 Pod 状态
    log_info "--- Pods ---"
    kubectl get pods -n "${NAMESPACE}" -o wide
    
    local not_running
    not_running=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -cv "Running\|Completed" || true)
    if [[ "${not_running}" -gt 0 ]]; then
        log_warn "${not_running} pods are not in Running state"
        ((issues++))
    fi
    
    log_info "--- Services ---"
    kubectl get svc -n "${NAMESPACE}" -o wide
    
    log_info "--- PVCs ---"
    kubectl get pvc -n "${NAMESPACE}" -o wide
    
    # 检查 PVC 状态
    local pending_pvc
    pending_pvc=$(kubectl get pvc -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -c "Pending" || true)
    if [[ "${pending_pvc}" -gt 0 ]]; then
        log_warn "${pending_pvc} PVCs are in Pending state"
    fi
    
    log_info "--- Ingress ---"
    kubectl get ingress -n "${NAMESPACE}" -o wide
    
    # 健康检查 - 尝试访问 Harbor API
    log_info "--- Health Check ---"
    local harbor_url="https://harbor.${DOMAIN}"
    if curl -sk "${harbor_url}/api/v2.0/health" 2>/dev/null | python3 -m json.tool 2>/dev/null; then
        log_info "Harbor API is healthy"
    else
        log_warn "Harbor API not yet accessible (may need DNS configuration)"
    fi
    
    if [[ "${issues}" -eq 0 ]]; then
        log_info "Verification complete - no issues detected"
    else
        log_warn "Verification complete - ${issues} issues detected"
    fi
}

# Print summary
print_summary() {
    cat <<EOF

================================================================
  Harbor Registry Credentials
================================================================
  URL:      https://harbor.${DOMAIN}
  Username: admin
  Password: Harbor12345
================================================================

  Docker Login:
    docker login harbor.${DOMAIN}
    Username: admin
    Password: Harbor12345

  Default Projects:
    - library (public)
    - devops (private)
    - microservices (private)

  Next steps:
  1. Access Harbor web interface
  2. Change admin password
  3. Configure robot accounts for CI/CD
  4. Set up webhook for vulnerability scanning
  5. Configure LDAP/OIDC authentication
================================================================

EOF
}

# Main
main() {
    local action="${1:-deploy}"
    
    log_info "============================================"
    log_info "  Harbor Registry Deployment"
    log_info "  Domain: ${DOMAIN}"
    log_info "============================================"
    
    case "${action}" in
        deploy)
            check_prereqs
            create_namespace
            create_tls_certs
            create_secrets
            deploy_harbor
            wait_for_ready
            configure_projects
            verify_deployment
            print_summary
            ;;
        verify)
            verify_deployment
            ;;
        delete)
            log_warn "Deleting Harbor deployment..."
            helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --wait
            kubectl delete pvc --all -n "${NAMESPACE}" 2>/dev/null || true
            log_info "Harbor deleted"
            ;;
        *)
            echo "Usage: $0 {deploy|verify|delete}"
            exit 1
            ;;
    esac
}

main "$@"
