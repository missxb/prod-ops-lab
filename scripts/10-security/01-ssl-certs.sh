#!/bin/bash
#===============================================================================
# Stage 10.1: SSL/TLS Certificate Management
#===============================================================================
# Automated SSL/TLS certificate management with cert-manager or OpenSSL
#===============================================================================

set -euo pipefail

# 错误处理
trap 'log ERROR "SSL证书脚本异常退出 (行号: $LINENO)"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="/etc/ssl/enterprise"
K8S_CERT_DIR="/root/enterprise-cloud-native-platform/certs"
LOG_FILE="/var/log/ssl-certs-$(date +%Y%m%d-%H%M%S).log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        INFO)    echo -e "${GREEN}[INFO]${NC} ${timestamp} - ${message}" ;;
        WARN)    echo -e "${YELLOW}[WARN]${NC} ${timestamp} - ${message}" ;;
        ERROR)   echo -e "${RED}[ERROR]${NC} ${timestamp} - ${message}" ;;
    esac
    
    echo "[${level}] ${timestamp} - ${message}" >> "$LOG_FILE"
}

#-------------------------------------------------------------------------------
# Install cert-manager
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# Install cert-manager
# 功能: 通过Helm或kubectl安装cert-manager到K8s集群
# 前置条件: kubectl可用、集群可达
# 等待: deployment/cert-manager和webhook就绪
#-------------------------------------------------------------------------------
install_cert_manager() {
    log INFO "Installing cert-manager..."
    
    # Check if cert-manager is already installed
    if kubectl get namespace cert-manager &>/dev/null; then
        log INFO "cert-manager already installed"
        return 0
    fi
    
    # Install cert-manager via Helm or kubectl
    if command -v helm &>/dev/null; then
        helm repo add jetstack https://charts.jetstack.io
        helm repo update
        helm install cert-manager jetstack/cert-manager \
            --namespace cert-manager \
            --create-namespace \
            --set installCRDs=true \
            --set prometheus.enabled=true
    else
        kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
    fi
    
    # Wait for cert-manager to be ready
    kubectl wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=300s
    kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=300s
    
    log INFO "cert-manager installed successfully"
}

#-------------------------------------------------------------------------------
# Create Let's Encrypt Cluster Issuer
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# Create Let's Encrypt Cluster Issuer
# 功能: 创建Let's Encrypt生产环境和测试环境的ClusterIssuer
# 名称: letsencrypt-prod, letsencrypt-staging
#-------------------------------------------------------------------------------
create_cluster_issuer() {
    log INFO "Creating Let's Encrypt Cluster Issuer..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@enterprise.com
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        ingress:
          class: nginx
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: admin@enterprise.com
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
    
    log INFO "Cluster Issuers created successfully"
}

#-------------------------------------------------------------------------------
# Generate Self-Signed Certificates (for internal use)
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# Generate Self-Signed Certificates
# 功能: 生成自签名CA和服务器证书（4096位RSA，SHA512）
# 参数: $1=domain（默认: enterprise.local）
# 生成: ca.key, ca.crt, server.key, server.crt, server.p12
#-------------------------------------------------------------------------------
generate_self_signed() {
    local domain=${1:-"enterprise.local"}
    local cert_dir="${CERT_DIR}/${domain}"
    
    log INFO "Generating self-signed certificates for ${domain}..."
    
    mkdir -p "$cert_dir"
    
    # Generate CA key and certificate
    openssl genrsa -out "${cert_dir}/ca.key" 4096
    openssl req -x509 -new -nodes -sha512 -days 3650 \
        -subj "/C=US/ST=State/L=City/O=Enterprise/CN=Enterprise CA" \
        -key "${cert_dir}/ca.key" \
        -out "${cert_dir}/ca.crt"
    
    # Generate server key and CSR
    openssl genrsa -out "${cert_dir}/server.key" 4096
    openssl req -sha512 -new \
        -subj "/C=US/ST=State/L=City/O=Enterprise/CN=${domain}" \
        -key "${cert_dir}/server.key" \
        -out "${cert_dir}/server.csr"
    
    # Generate certificate extensions
    cat > "${cert_dir}/v3.ext" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${domain}
DNS.2 = *.${domain}
DNS.3 = localhost
IP.1 = 127.0.0.1
EOF
    
    # Generate server certificate
    openssl x509 -req -sha512 -days 3650 \
        -extfile "${cert_dir}/v3.ext" \
        -CA "${cert_dir}/ca.crt" \
        -CAkey "${cert_dir}/ca.key" \
        -CAcreateserial \
        -in "${cert_dir}/server.csr" \
        -out "${cert_dir}/server.crt"
    
    # Generate PKCS12 for Java
    openssl pkcs12 -export -out "${cert_dir}/server.p12" \
        -inkey "${cert_dir}/server.key" \
        -in "${cert_dir}/server.crt" \
        -certfile "${cert_dir}/ca.crt" \
        -passout pass:changeit
    
    # Generate PEM bundle for Kubernetes
    cat "${cert_dir}/server.crt" "${cert_dir}/ca.crt" > "${cert_dir}/server-bundle.crt"
    
    # Set proper permissions
    chmod 600 "${cert_dir}"/*.key
    chmod 644 "${cert_dir}"/*.crt
    
    log INFO "Self-signed certificates generated in ${cert_dir}"
}

#-------------------------------------------------------------------------------
# Create Kubernetes TLS Secrets
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# Create Kubernetes TLS Secrets
# 功能: 创建K8s TLS Secret和CA ConfigMap
# 参数: $1=domain, $2=namespace
#-------------------------------------------------------------------------------
create_k8s_secrets() {
    local domain=${1:-"enterprise.local"}
    local cert_dir="${CERT_DIR}/${domain}"
    local namespace=${2:-"default"}
    
    log INFO "Creating Kubernetes TLS secrets..."
    
    # Create TLS secret
    kubectl create secret tls "${domain}-tls" \
        --cert="${cert_dir}/server.crt" \
        --key="${cert_dir}/server.key" \
        --namespace="$namespace" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Create CA ConfigMap
    kubectl create configmap "${domain}-ca" \
        --from-file=ca.crt="${cert_dir}/ca.crt" \
        --namespace="$namespace" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log INFO "Kubernetes secrets created for ${domain}"
}

#-------------------------------------------------------------------------------
# Create Ingress with TLS
#-------------------------------------------------------------------------------
create_tls_ingress() {
    local domain=${1:-"enterprise.local"}
    local service=${2:-"nginx-ingress-controller"}
    local namespace=${3:-"ingress-nginx"}
    
    log INFO "Creating TLS Ingress for ${domain}..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${domain}-ingress
  namespace: ${namespace}
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/ssl-protocols: "TLSv1.2 TLSv1.3"
    nginx.ingress.kubernetes.io/ssl-ciphers: "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384"
    nginx.ingress.kubernetes.io/hsts: "true"
    nginx.ingress.kubernetes.io/hsts-max-age: "31536000"
    nginx.ingress.kubernetes.io/hsts-include-subdomains: "true"
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - ${domain}
    - www.${domain}
    secretName: ${domain}-tls
  rules:
  - host: ${domain}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${service}
            port:
              number: 80
  - host: www.${domain}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${service}
            port:
              number: 80
EOF
    
    log INFO "TLS Ingress created for ${domain}"
}

#-------------------------------------------------------------------------------
# Main Entry Point
#-------------------------------------------------------------------------------
main() {
    log INFO "=== SSL/TLS Certificate Management Started ==="
    
    mkdir -p "$CERT_DIR" "$K8S_CERT_DIR"
    
    # Install cert-manager
    install_cert_manager
    
    # Create Cluster Issuers
    create_cluster_issuer
    
    # Generate certificates for common domains
    local domains=("enterprise.local" "api.enterprise.local" "grafana.enterprise.local" "kibana.enterprise.local")
    
    for domain in "${domains[@]}"; do
        generate_self_signed "$domain"
    done
    
    # Create Kubernetes secrets
    for domain in "${domains[@]}"; do
        create_k8s_secrets "$domain" "default"
    done
    
    # Create sample TLS Ingress
    create_tls_ingress "enterprise.local" "nginx-ingress-controller" "ingress-nginx"
    
    log INFO "=== SSL/TLS Certificate Management Completed ==="
    log INFO "Certificates stored in: ${CERT_DIR}"
    log INFO "Logs: ${LOG_FILE}"
}

main "$@"
