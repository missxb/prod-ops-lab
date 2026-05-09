#!/usr/bin/env bash
#==============================================================================
# deploy-cicd.sh - CI/CD Pipeline Main Deployment Script
# Enterprise Cloud Native Platform - Phase 4
#==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_DIR="${PROJECT_ROOT}/configs"
LOG_FILE="/var/log/cicd-deploy-$(date +%Y%m%d-%H%M%S).log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
DOMAIN="${DOMAIN:-example.com}"
GITLAB_URL="gitlab.${DOMAIN}"
JENKINS_URL="jenkins.${DOMAIN}"
HARBOR_URL="harbor.${DOMAIN}"
NAMESPACE_CICD="cicd"
NAMESPACE_GITLAB="gitlab"
NAMESPACE_JENKINS="jenkins"
NAMESPACE_JENKINS_AGENTS="jenkins-agents"
NAMESPACE_HARBOR="harbor"
NAMESPACE_TRIVY="trivy"

# Logging
log() {
    local level=$1; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo -e "${msg}" | tee -a "${LOG_FILE}"
}

log_info()  { log "INFO"  "${GREEN}$*${NC}"; }
log_warn()  { log "WARN"  "${YELLOW}$*${NC}"; }
log_error() { log "ERROR" "${RED}$*${NC}"; }
log_step()  { log "STEP"  "${BLUE}>>> $*${NC}"; }

# Prerequisites check
check_prerequisites() {
    log_step "Checking prerequisites..."
    
    local required_tools=("kubectl" "helm" "openssl" "curl")
    for tool in "${required_tools[@]}"; do
        if ! command -v "${tool}" &>/dev/null; then
            log_error "Required tool not found: ${tool}"
            exit 1
        fi
    done
    
    # Check Kubernetes connectivity
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    
    log_info "All prerequisites satisfied"
}

# Setup namespaces
setup_namespaces() {
    log_step "Creating namespaces..."
    
    local namespaces=("${NAMESPACE_CICD}" "${NAMESPACE_GITLAB}" "${NAMESPACE_JENKINS}" "${NAMESPACE_JENKINS_AGENTS}" "${NAMESPACE_HARBOR}" "${NAMESPACE_TRIVY}")
    for ns in "${namespaces[@]}"; do
        kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
        log_info "Namespace ${ns} ready"
    done
    
    # Add labels
    for ns in "${namespaces[@]}"; do
        kubectl label namespace "${ns}" \
            purpose=cicd \
            team=devops \
            environment=production \
            --overwrite
    done
}

# Create TLS certificates
create_tls_certificates() {
    log_step "Creating TLS certificates..."
    
    local cert_dir="${PROJECT_ROOT}/certs/cicd"
    mkdir -p "${cert_dir}"
    
    if [[ ! -f "${cert_dir}/ca.crt" ]]; then
        log_info "Generating CA certificate..."
        openssl genrsa -out "${cert_dir}/ca.key" 4096
        openssl req -x509 -new -nodes -key "${cert_dir}/ca.key" \
            -sha256 -days 3650 \
            -out "${cert_dir}/ca.crt" \
            -subj "/C=CN/ST=Beijing/L=Beijing/O=Enterprise/OU=DevOps/CN=Enterprise-CA"
    fi
    
    local services=("gitlab" "jenkins" "harbor")
    for svc in "${services[@]}"; do
        if [[ ! -f "${cert_dir}/${svc}.crt" ]]; then
            log_info "Generating certificate for ${svc}..."
            
            openssl genrsa -out "${cert_dir}/${svc}.key" 2048
            
            cat > "${cert_dir}/${svc}-csr.conf" <<EOF
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
CN = ${svc}.${DOMAIN}

[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${svc}.${DOMAIN}
DNS.2 = *.${svc}.${DOMAIN}
DNS.3 = localhost
IP.1 = 127.0.0.1
EOF
            openssl req -new -key "${cert_dir}/${svc}.key" \
                -out "${cert_dir}/${svc}.csr" \
                -config "${cert_dir}/${svc}-csr.conf"
            
            openssl x509 -req -in "${cert_dir}/${svc}.csr" \
                -CA "${cert_dir}/ca.crt" \
                -CAkey "${cert_dir}/ca.key" \
                -CAcreateserial \
                -out "${cert_dir}/${svc}.crt" \
                -days 3650 -sha256 \
                -extensions v3_req \
                -extfile "${cert_dir}/${svc}-csr.conf"
        fi
    done
    
    # Create TLS secrets
    local ns_list=("gitlab" "jenkins" "harbor")
    for i in "${!services[@]}"; do
        local svc="${services[$i]}"
        local ns="${ns_list[$i]}"
        local secret_name="${svc}-tls-secret"
        
        kubectl create secret tls "${secret_name}" \
            --cert="${cert_dir}/${svc}.crt" \
            --key="${cert_dir}/${svc}.key" \
            -n "${ns}" \
            --dry-run=client -o yaml | kubectl apply -f -
        
        log_info "TLS secret ${secret_name} created in namespace ${ns}"
    done
}

# Update Helm values with domain
update_helm_values() {
    log_step "Updating Helm values with domain: ${DOMAIN}..."
    
    local domain_templates=(
        "gitlab:gitlab.example.com:${GITLAB_URL}"
        "jenkins:jenkins.example.com:${JENKINS_URL}"
        "harbor:harbor.example.com:${HARBOR_URL}"
    )
    
    for template in "${domain_templates[@]}"; do
        IFS=':' read -r name old_domain new_domain <<< "${template}"
        local values_file="${CONFIG_DIR}/${name}/${name}-values.yaml"
        
        if [[ -f "${values_file}" ]]; then
            sed -i "s|${old_domain}|${new_domain}|g" "${values_file}"
            log_info "Updated ${values_file}"
        fi
    done
}

# Add Helm repositories
add_helm_repos() {
    log_step "Adding Helm repositories..."
    
    helm repo add gitlab https://charts.gitlab.io/ --force-update
    helm repo add jenkins https://charts.jenkins.io --force-update
    helm repo add harbor https://helm.goharbor.io --force-update
    helm repo update
    
    log_info "Helm repositories added and updated"
}

# Deploy all services
deploy_all_services() {
    log_step "Deploying CI/CD services..."
    
    # Deploy in order: GitLab first, then others
    log_info "=== Deploying GitLab ==="
    bash "${SCRIPT_DIR}/01-deploy-gitlab.sh" 2>&1 | tee -a "${LOG_FILE}"
    
    log_info "=== Deploying Jenkins ==="
    bash "${SCRIPT_DIR}/02-deploy-jenkins.sh" 2>&1 | tee -a "${LOG_FILE}"
    
    log_info "=== Deploying Harbor ==="
    bash "${SCRIPT_DIR}/03-deploy-harbor.sh" 2>&1 | tee -a "${LOG_FILE}"
    
    log_info "=== Deploying Trivy Scanner ==="
    bash "${SCRIPT_DIR}/04-deploy-trivy.sh" 2>&1 | tee -a "${LOG_FILE}"
    
    log_info "=== Setting up Jenkins Pipeline ==="
    bash "${SCRIPT_DIR}/05-setup-pipeline.sh" 2>&1 | tee -a "${LOG_FILE}"
}

# Verify deployment
verify_deployment() {
    log_step "Verifying deployment..."
    
    local status=0
    
    # Check GitLab
    if kubectl get pods -n "${NAMESPACE_GITLAB}" -l app=webservice -o name 2>/dev/null | head -1 | grep -q pod; then
        log_info "GitLab pods found"
    else
        log_warn "GitLab pods not yet ready"
        status=1
    fi
    
    # Check Jenkins
    if kubectl get pods -n "${NAMESPACE_JENKINS}" -l app.kubernetes.io/name=jenkins -o name 2>/dev/null | head -1 | grep -q pod; then
        log_info "Jenkins pods found"
    else
        log_warn "Jenkins pods not yet ready"
        status=1
    fi
    
    # Check Harbor
    if kubectl get pods -n "${NAMESPACE_HARBOR}" -l component=core -o name 2>/dev/null | head -1 | grep -q pod; then
        log_info "Harbor pods found"
    else
        log_warn "Harbor pods not yet ready"
        status=1
    fi
    
    # Check Trivy
    if kubectl get pods -n "${NAMESPACE_TRIVY}" -l app.kubernetes.io/name=trivy -o name 2>/dev/null | head -1 | grep -q pod; then
        log_info "Trivy pods found"
    else
        log_warn "Trivy pods not yet ready"
        status=1
    fi
    
    # Check services
    log_info "--- Service Endpoints ---"
    kubectl get svc -n "${NAMESPACE_GITLAB}" -o wide 2>/dev/null || true
    kubectl get svc -n "${NAMESPACE_JENKINS}" -o wide 2>/dev/null || true
    kubectl get svc -n "${NAMESPACE_HARBOR}" -o wide 2>/dev/null || true
    
    return ${status}
}

# Print summary
print_summary() {
    log_step "Deployment Summary"
    
    cat <<EOF

================================================================
  CI/CD Pipeline Deployment Complete
================================================================
  GitLab:   https://${GITLAB_URL}
  Jenkins:  https://${JENKINS_URL}
  Harbor:   https://${HARBOR_URL}
  Trivy:    Running in namespace: ${NAMESPACE_TRIVY}
================================================================

  Namespaces:
    GitLab:         ${NAMESPACE_GITLAB}
    Jenkins:        ${NAMESPACE_JENKINS}
    Jenkins Agents: ${NAMESPACE_JENKINS_AGENTS}
    Harbor:         ${NAMESPACE_HARBOR}
    Trivy:          ${NAMESPACE_TRIVY}
    CI/CD:          ${NAMESPACE_CICD}

  Log file: ${LOG_FILE}
================================================================

EOF
}

# Main
main() {
    local action="${1:-deploy}"
    
    log_info "============================================"
    log_info "  CI/CD Pipeline Deployment - Phase 4"
    log_info "  Domain: ${DOMAIN}"
    log_info "============================================"
    
    case "${action}" in
        deploy)
            check_prerequisites
            setup_namespaces
            add_helm_repos
            update_helm_values
            create_tls_certificates
            deploy_all_services
            verify_deployment
            print_summary
            ;;
        verify)
            verify_deployment
            ;;
        teardown)
            log_warn "Tearing down CI/CD stack..."
            helm uninstall jenkins -n "${NAMESPACE_JENKINS}" --wait 2>/dev/null || true
            helm uninstall harbor -n "${NAMESPACE_HARBOR}" --wait 2>/dev/null || true
            helm uninstall gitlab -n "${NAMESPACE_GITLAB}" --wait 2>/dev/null || true
            helm uninstall trivy -n "${NAMESPACE_TRIVY}" --wait 2>/dev/null || true
            log_info "Teardown complete"
            ;;
        *)
            echo "Usage: $0 {deploy|verify|teardown}"
            exit 1
            ;;
    esac
}

main "$@"
