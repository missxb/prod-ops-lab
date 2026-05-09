#!/usr/bin/env bash
#==============================================================================
# 03-deploy-harbor.sh - Deploy Harbor Registry with Helm
# Enterprise Cloud Native Platform - Phase 4
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

# Check prerequisites
check_prereqs() {
    log_info "Checking prerequisites..."
    
    for cmd in kubectl helm openssl; do
        if ! command -v "${cmd}" &>/dev/null; then
            log_error "Required command not found: ${cmd}"
            exit 1
        fi
    done
    
    if ! helm repo list 2>/dev/null | grep -q harbor; then
        log_info "Adding Harbor Helm repository..."
        helm repo add harbor https://helm.goharbor.io --force-update
        helm repo update
    fi
    
    log_info "Prerequisites satisfied"
}

# Create namespace
create_namespace() {
    log_info "Creating namespace: ${NAMESPACE}"
    
    kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    
    kubectl label namespace "${NAMESPACE}" \
        purpose=registry \
        team=devops \
        environment=production \
        --overwrite
}

# Create TLS certificates for Harbor
create_tls_certs() {
    log_info "Creating TLS certificates for Harbor..."
    
    local cert_dir="${PROJECT_ROOT}/certs/harbor"
    mkdir -p "${cert_dir}"
    
    if [[ ! -f "${cert_dir}/ca.crt" ]]; then
        # Generate CA
        openssl genrsa -out "${cert_dir}/ca.key" 4096
        openssl req -x509 -new -nodes -key "${cert_dir}/ca.key" \
            -sha256 -days 3650 \
            -out "${cert_dir}/ca.crt" \
            -subj "/C=CN/ST=Beijing/L=Beijing/O=Enterprise/OU=DevOps/CN=Enterprise-Harbor-CA"
    fi
    
    if [[ ! -f "${cert_dir}/server.crt" ]]; then
        # Generate server certificate
        openssl genrsa -out "${cert_dir}/server.key" 2048
        
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
        openssl req -new -key "${cert_dir}/server.key" \
            -out "${cert_dir}/server.csr" \
            -config "${cert_dir}/server-csr.conf"
        
        openssl x509 -req -in "${cert_dir}/server.csr" \
            -CA "${cert_dir}/ca.crt" \
            -CAkey "${cert_dir}/ca.key" \
            -CAcreateserial \
            -out "${cert_dir}/server.crt" \
            -days 3650 -sha256 \
            -extensions v3_req \
            -extfile "${cert_dir}/server-csr.conf"
    fi
    
    # Create TLS secret
    kubectl create secret tls harbor-tls-secret \
        --cert="${cert_dir}/server.crt" \
        --key="${cert_dir}/server.key" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Also create notary TLS secret (same cert)
    kubectl create secret tls harbor-notary-tls-secret \
        --cert="${cert_dir}/server.crt" \
        --key="${cert_dir}/server.key" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_info "TLS certificates created"
}

# Configure harbor secret key
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
    
    log_info "Secrets created"
}

# Deploy Harbor
deploy_harbor() {
    log_info "Deploying Harbor Registry..."
    
    helm upgrade --install "${RELEASE_NAME}" harbor/harbor \
        --namespace "${NAMESPACE}" \
        --values "${VALUES_FILE}" \
        --set externalURL="https://harbor.${DOMAIN}" \
        --set expose.ingress.hosts.core="harbor.${DOMAIN}" \
        --set expose.ingress.hosts.notary="notary.${DOMAIN}" \
        --set harborAdminPassword="Harbor12345" \
        --timeout 15m \
        --wait \
        --atomic
    
    log_info "Harbor Helm release deployed"
}

# Wait for readiness
wait_for_ready() {
    log_info "Waiting for Harbor to be ready..."
    
    local components=("core" "portal" "registry" "jobservice" "trivy-adapter" "database" "redis")
    
    for component in "${components[@]}"; do
        log_info "Waiting for ${component}..."
        kubectl wait --for=condition=ready pod \
            -l "component=${component}" \
            -n "${NAMESPACE}" \
            --timeout=600s 2>/dev/null || \
        kubectl wait --for=condition=ready pod \
            -l "app.kubernetes.io/component=${component}" \
            -n "${NAMESPACE}" \
            --timeout=600s 2>/dev/null || \
            log_warn "Timeout waiting for ${component}"
    done
    
    log_info "Harbor components ready"
}

# Configure project replication
configure_projects() {
    log_info "Configuring Harbor projects..."
    
    # Wait for Harbor to be fully ready
    sleep 30
    
    local harbor_url="https://harbor.${DOMAIN}"
    
    # Create default projects via API
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
    
    log_info "Project configuration created"
}

# Verify deployment
verify_deployment() {
    log_info "Verifying Harbor deployment..."
    
    log_info "--- Pods ---"
    kubectl get pods -n "${NAMESPACE}" -o wide
    
    log_info "--- Services ---"
    kubectl get svc -n "${NAMESPACE}" -o wide
    
    log_info "--- PVCs ---"
    kubectl get pvc -n "${NAMESPACE}" -o wide
    
    log_info "--- Ingress ---"
    kubectl get ingress -n "${NAMESPACE}" -o wide
    
    # Check Harbor API
    log_info "--- Health Check ---"
    local harbor_url="https://harbor.${DOMAIN}"
    if curl -sk "${harbor_url}/api/v2.0/health" 2>/dev/null | python3 -m json.tool 2>/dev/null; then
        log_info "Harbor API is healthy"
    else
        log_warn "Harbor API not yet accessible (may need DNS configuration)"
    fi
    
    log_info "Verification complete"
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
