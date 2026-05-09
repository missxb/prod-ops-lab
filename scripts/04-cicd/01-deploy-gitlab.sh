#!/usr/bin/env bash
#==============================================================================
# 01-deploy-gitlab.sh - Deploy GitLab CE with Helm
# Enterprise Cloud Native Platform - Phase 4
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

# Check prerequisites
check_prereqs() {
    log_info "Checking prerequisites..."
    
    for cmd in kubectl helm openssl; do
        if ! command -v "${cmd}" &>/dev/null; then
            log_error "Required command not found: ${cmd}"
            exit 1
        fi
    done
    
    if ! helm repo list 2>/dev/null | grep -q gitlab; then
        log_info "Adding GitLab Helm repository..."
        helm repo add gitlab "${CHART_REPO}" --force-update
        helm repo update
    fi
    
    log_info "Prerequisites satisfied"
}

# Create namespace with labels
create_namespace() {
    log_info "Creating namespace: ${NAMESPACE}"
    
    kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    
    kubectl label namespace "${NAMESPACE}" \
        purpose=source-control \
        team=devops \
        environment=production \
        app.kubernetes.io/managed-by=helm \
        --overwrite
}

# Create secrets
create_secrets() {
    log_info "Creating secrets..."
    
    # Initial root password
    kubectl create secret generic gitlab-initial-root-password \
        --from-literal=password="$(openssl rand -base64 24 | tr -d '=+/')" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Rails secrets
    kubectl create secret generic gitlab-rails-secret \
        --from-literal=base="$(openssl rand -hex 64)" \
        --from-literal=otp_key_base="$(openssl rand -hex 64)" \
        --from-literal=secret_key_base="$(openssl rand -hex 64)" \
        --from-literal=otp_key="$(openssl rand -hex 32)" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # SSH host key
    local key_dir="/tmp/gitlab-ssh-keys"
    mkdir -p "${key_dir}"
    ssh-keygen -t rsa -b 4096 -f "${key_dir}/ssh-host-key" -N "" -q 2>/dev/null || true
    
    kubectl create secret generic gitlab-gitlab-shell-host-keys \
        --from-file=ssh-host-key="${key_dir}/ssh-host-key" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    rm -rf "${key_dir}"
    
    log_info "Secrets created"
}

# Create storage classes if needed
setup_storage() {
    log_info "Setting up storage..."
    
    # Check if default storage class exists
    if ! kubectl get storageclass standard &>/dev/null; then
        log_warn "No 'standard' storage class found. Creating one..."
        cat <<'EOF' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: standard
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
EOF
    fi
    
    log_info "Storage configured"
}

# Deploy GitLab
deploy_gitlab() {
    log_info "Deploying GitLab CE..."
    
    helm upgrade --install "${RELEASE_NAME}" gitlab/gitlab \
        --namespace "${NAMESPACE}" \
        --values "${VALUES_FILE}" \
        --set global.hosts.domain="${DOMAIN}" \
        --set global.hosts.externalIP="" \
        --set certmanager.installCRDs=false \
        --timeout 15m \
        --wait \
        --atomic
    
    log_info "GitLab Helm release deployed successfully"
}

# Wait for readiness
wait_for_ready() {
    log_info "Waiting for GitLab components to be ready..."
    
    local components=("webservice" "sidekiq" "toolbox" "gitaly" "gitlab-shell" "registry")
    local timeout=900
    
    for component in "${components[@]}"; do
        log_info "Waiting for ${component}..."
        kubectl wait --for=condition=ready pod \
            -l "app=${component}" \
            -n "${NAMESPACE}" \
            --timeout="${timeout}s" 2>/dev/null || \
        kubectl wait --for=condition=ready pod \
            -l "app.kubernetes.io/name=${component}" \
            -n "${NAMESPACE}" \
            --timeout="${timeout}s" 2>/dev/null || \
            log_warn "Timeout waiting for ${component}"
    done
    
    log_info "Component readiness check complete"
}

# Configure Ingress
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
    
    log_info "Ingress configured for ${gitlab_host}"
}

# Verify deployment
verify_deployment() {
    log_info "Verifying GitLab deployment..."
    
    # Check pods
    log_info "--- Pods ---"
    kubectl get pods -n "${NAMESPACE}" -o wide
    
    # Check services
    log_info "--- Services ---"
    kubectl get svc -n "${NAMESPACE}" -o wide
    
    # Check PVCs
    log_info "--- Persistent Volume Claims ---"
    kubectl get pvc -n "${NAMESPACE}" -o wide
    
    # Check ingress
    log_info "--- Ingress ---"
    kubectl get ingress -n "${NAMESPACE}" -o wide
    
    # Check events for errors
    log_info "--- Recent Events ---"
    kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' | tail -20
    
    log_info "Verification complete"
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
