#!/usr/bin/env bash
#==============================================================================
# deploy-cicd.sh - CI/CD Pipeline Main Deployment Script
# Enterprise Cloud Native Platform - Phase 4
#
# Description:
#   Orchestrates the full CI/CD stack deployment including GitLab CE,
#   Jenkins, Harbor Registry, and Trivy Security Scanner.
#
# Usage:
#   ./deploy-cicd.sh [deploy|verify|teardown]
#
#   deploy    - Full CI/CD stack deployment (default)
#   verify    - Verify all CI/CD components are running
#   teardown  - Remove all CI/CD components
#
# Environment Variables:
#   DOMAIN  - Base domain for all services (default: example.com)
#
# Examples:
#   ./deploy-cicd.sh
#   DOMAIN=corp.example.com ./deploy-cicd.sh deploy
+#   ./deploy-cicd.sh verify
+#   ./deploy-cicd.sh teardown
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

# log - 写入带时间戳的日志并同时输出到终端和日志文件
# Args:
#   $1 - 日志级别 (INFO, WARN, ERROR, STEP)
#   $* - 日志消息内容
log() {
    local level=$1; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo -e "${msg}" | tee -a "${LOG_FILE}"
}

# log_info - 输出信息级别日志（绿色）
log_info()  { log "INFO"  "${GREEN}$*${NC}"; }
# log_warn - 输出警告级别日志（黄色）
log_warn()  { log "WARN"  "${YELLOW}$*${NC}"; }
# log_error - 输出错误级别日志（红色）
log_error() { log "ERROR" "${RED}$*${NC}"; }
# log_step - 输出步骤标记日志（蓝色，带 >>> 前缀）
log_step()  { log "STEP"  "${BLUE}>>> $*${NC}"; }

# check_prerequisites - 检查所有必需的命令行工具和集群连接
# 验证 kubectl, helm, openssl, curl 是否可用，以及 Kubernetes 集群是否可达
check_prerequisites() {
    log_step "Checking prerequisites..."
    
    local required_tools=("kubectl" "helm" "openssl" "curl")
    for tool in "${required_tools[@]}"; do
        if ! command -v "${tool}" &>/dev/null; then
            log_error "Required tool not found: ${tool}"
            log_error "Please install ${tool} before proceeding"
            exit 1
        fi
    done
    
    # 检查 Kubernetes 集群连接
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        log_error "Please ensure kubeconfig is properly configured"
        exit 1
    fi
    
    # 验证集群版本
    local k8s_version
    k8s_version=$(kubectl version --short 2>/dev/null | head -1 || echo "unknown")
    log_info "Kubernetes cluster: ${k8s_version}"
    
    # 检查 Helm 版本
    local helm_version
    helm_version=$(helm version --short 2>/dev/null || echo "unknown")
    log_info "Helm version: ${helm_version}"
    
    log_info "All prerequisites satisfied"
}

# setup_namespaces - 创建 CI/CD 所需的所有命名空间
# 包括: cicd, gitlab, jenkins, jenkins-agents, harbor, trivy
# 并为每个命名空间添加 purpose/team/environment 标签
setup_namespaces() {
    log_step "Creating namespaces..."
    
    local namespaces=("${NAMESPACE_CICD}" "${NAMESPACE_GITLAB}" "${NAMESPACE_JENKINS}" "${NAMESPACE_JENKINS_AGENTS}" "${NAMESPACE_HARBOR}" "${NAMESPACE_TRIVY}")
    for ns in "${namespaces[@]}"; do
        kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
        log_info "Namespace ${ns} ready"
    done
    
    # 为命名空间添加标准标签
    for ns in "${namespaces[@]}"; do
        kubectl label namespace "${ns}" \
            purpose=cicd \
            team=devops \
            environment=production \
            --overwrite
    done
    
    # 验证命名空间创建成功
    local ns_count
    ns_count=$(kubectl get namespaces --no-headers 2>/dev/null | grep -cE "^($(IFS='|'; echo "${namespaces[*]}"))[[:space:]]" || true)
    log_info "Verified ${ns_count}/${#namespaces[@]} namespaces created"
}

# create_tls_certificates - 生成 CA 和各服务的 TLS 证书
# 为 gitlab, jenkins, harbor 三个服务生成独立的 TLS 证书
# 并创建对应的 Kubernetes TLS Secret
create_tls_certificates() {
    log_step "Creating TLS certificates..."
    
    local cert_dir="${PROJECT_ROOT}/certs/cicd"
    mkdir -p "${cert_dir}"
    
    # 生成 CA 证书（如果不存在）
    if [[ ! -f "${cert_dir}/ca.crt" ]]; then
        log_info "Generating CA certificate..."
        if ! openssl genrsa -out "${cert_dir}/ca.key" 4096 2>/dev/null; then
            log_error "Failed to generate CA private key"
            exit 1
        fi
        if ! openssl req -x509 -new -nodes -key "${cert_dir}/ca.key" \
            -sha256 -days 3650 \
            -out "${cert_dir}/ca.crt" \
            -subj "/C=CN/ST=Beijing/L=Beijing/O=Enterprise/OU=DevOps/CN=Enterprise-CA" 2>/dev/null; then
            log_error "Failed to generate CA certificate"
            exit 1
        fi
        log_info "CA certificate generated: ${cert_dir}/ca.crt"
    else
        log_info "CA certificate already exists, skipping generation"
    fi
    
    local services=("gitlab" "jenkins" "harbor")
    for svc in "${services[@]}"; do
        if [[ ! -f "${cert_dir}/${svc}.crt" ]]; then
            log_info "Generating certificate for ${svc}..."
            
            # 生成服务私钥
            if ! openssl genrsa -out "${cert_dir}/${svc}.key" 2048 2>/dev/null; then
                log_error "Failed to generate private key for ${svc}"
                exit 1
            fi
            
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
            # 生成 CSR 和签名证书
            if ! openssl req -new -key "${cert_dir}/${svc}.key" \
                -out "${cert_dir}/${svc}.csr" \
                -config "${cert_dir}/${svc}-csr.conf" 2>/dev/null; then
                log_error "Failed to generate CSR for ${svc}"
                exit 1
            fi
            
            if ! openssl x509 -req -in "${cert_dir}/${svc}.csr" \
                -CA "${cert_dir}/ca.crt" \
                -CAkey "${cert_dir}/ca.key" \
                -CAcreateserial \
                -out "${cert_dir}/${svc}.crt" \
                -days 3650 -sha256 \
                -extensions v3_req \
                -extfile "${cert_dir}/${svc}-csr.conf" 2>/dev/null; then
                log_error "Failed to sign certificate for ${svc}"
                exit 1
            fi
            
            # 验证证书生成成功
            if [[ -f "${cert_dir}/${svc}.crt" ]] && openssl x509 -in "${cert_dir}/${svc}.crt" -noout 2>/dev/null; then
                log_info "Certificate for ${svc} generated and verified"
            else
                log_error "Certificate verification failed for ${svc}"
                exit 1
            fi
        else
            log_info "Certificate for ${svc} already exists, skipping"
        fi
    done
    
    # 为各命名空间创建 TLS Secret
    # 注意: 使用数组索引对齐 services 和 namespaces
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
        
        # 验证 Secret 创建成功
        if kubectl get secret "${secret_name}" -n "${ns}" &>/dev/null; then
            log_info "TLS secret ${secret_name} verified in namespace ${ns}"
        else
            log_error "Failed to create TLS secret ${secret_name} in namespace ${ns}"
            exit 1
        fi
    done
}

# update_helm_values - 根据域名配置更新 Helm values 文件
# 替换各配置文件中的占位域名
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
            log_info "Updated ${values_file} with domain ${new_domain}"
        else
            log_warn "Values file not found: ${values_file} - skipping"
        fi
    done
}

# add_helm_repos - 添加 GitLab, Jenkins, Harbor 的 Helm Chart 仓库
# 所有仓库使用 --force-update 确保获取最新版本
add_helm_repos() {
    log_step "Adding Helm repositories..."
    
    # 添加各 Helm 仓库，每个仓库添加后验证
    local repos=(
        "gitlab|https://charts.gitlab.io/"
        "jenkins|https://charts.jenkins.io"
        "harbor|https://helm.goharbor.io"
    )
    
    for repo_def in "${repos[@]}"; do
        IFS='|' read -r name url <<< "${repo_def}"
        log_info "Adding Helm repo: ${name} (${url})"
        if helm repo add "${name}" "${url}" --force-update 2>/dev/null; then
            log_info "Helm repo '${name}' added successfully"
        else
            log_error "Failed to add Helm repo: ${name}"
            exit 1
        fi
    done
    
    log_info "Updating Helm repository index..."
    helm repo update
    log_info "Helm repositories added and updated"
}

# deploy_all_services - 按依赖顺序部署所有 CI/CD 服务
# 部署顺序: GitLab → Jenkins → Harbor → Trivy → Pipeline
# 每个步骤失败时记录警告但继续执行后续步骤
deploy_all_services() {
    log_step "Deploying CI/CD services..."
    
    local failed_services=()
    
    # 部署 GitLab (首先部署，其他服务可能依赖它)
    log_info "=== Deploying GitLab ==="
    if bash "${SCRIPT_DIR}/01-deploy-gitlab.sh" 2>&1 | tee -a "${LOG_FILE}"; then
        log_info "GitLab deployment completed"
    else
        log_error "GitLab deployment failed"
        failed_services+=("gitlab")
    fi
    
    # 部署 Jenkins
    log_info "=== Deploying Jenkins ==="
    if bash "${SCRIPT_DIR}/02-deploy-jenkins.sh" 2>&1 | tee -a "${LOG_FILE}"; then
        log_info "Jenkins deployment completed"
    else
        log_error "Jenkins deployment failed"
        failed_services+=("jenkins")
    fi
    
    # 部署 Harbor Registry
    log_info "=== Deploying Harbor ==="
    if bash "${SCRIPT_DIR}/03-deploy-harbor.sh" 2>&1 | tee -a "${LOG_FILE}"; then
        log_info "Harbor deployment completed"
    else
        log_error "Harbor deployment failed"
        failed_services+=("harbor")
    fi
    
    # 部署 Trivy 安全扫描器
    log_info "=== Deploying Trivy Scanner ==="
    if bash "${SCRIPT_DIR}/04-deploy-trivy.sh" 2>&1 | tee -a "${LOG_FILE}"; then
        log_info "Trivy deployment completed"
    else
        log_error "Trivy deployment failed"
        failed_services+=("trivy")
    fi
    
    # 配置 Jenkins Pipeline
    log_info "=== Setting up Jenkins Pipeline ==="
    if bash "${SCRIPT_DIR}/05-setup-pipeline.sh" 2>&1 | tee -a "${LOG_FILE}"; then
        log_info "Pipeline setup completed"
    else
        log_error "Pipeline setup failed"
        failed_services+=("pipeline")
    fi
    
    # 报告失败的部署
    if [[ ${#failed_services[@]} -gt 0 ]]; then
        log_error "Failed services: ${failed_services[*]}"
        log_warn "Check log file: ${LOG_FILE}"
        return 1
    fi
    
    log_info "All CI/CD services deployed successfully"
}

# verify_deployment - 验证所有 CI/CD 组件是否正常运行
# 检查 GitLab, Jenkins, Harbor, Trivy 的 Pod 状态和服务端点
# 返回: 0 - 全部成功, 1 - 部分失败
verify_deployment() {
    log_step "Verifying deployment..."
    
    local status=0
    local total_checks=0
    local passed_checks=0
    
    # 检查 GitLab Pod
    ((total_checks++))
    if kubectl get pods -n "${NAMESPACE_GITLAB}" -l app=webservice -o name 2>/dev/null | head -1 | grep -q pod; then
        log_info "GitLab pods found"
        ((passed_checks++))
    else
        log_warn "GitLab pods not yet ready"
        status=1
    fi
    
    # 检查 Jenkins Pod
    ((total_checks++))
    if kubectl get pods -n "${NAMESPACE_JENKINS}" -l app.kubernetes.io/name=jenkins -o name 2>/dev/null | head -1 | grep -q pod; then
        log_info "Jenkins pods found"
        ((passed_checks++))
    else
        log_warn "Jenkins pods not yet ready"
        status=1
    fi
    
    # 检查 Harbor Pod
    ((total_checks++))
    if kubectl get pods -n "${NAMESPACE_HARBOR}" -l component=core -o name 2>/dev/null | head -1 | grep -q pod; then
        log_info "Harbor pods found"
        ((passed_checks++))
    else
        log_warn "Harbor pods not yet ready"
        status=1
    fi
    
    # 检查 Trivy Pod
    ((total_checks++))
    if kubectl get pods -n "${NAMESPACE_TRIVY}" -l app.kubernetes.io/name=trivy -o name 2>/dev/null | head -1 | grep -q pod; then
        log_info "Trivy pods found"
        ((passed_checks++))
    else
        log_warn "Trivy pods not yet ready"
        status=1
    fi
    
    # 检查各命名空间的服务端点
    log_info "=== Service Endpoints ==="
    for ns in "${NAMESPACE_GITLAB}" "${NAMESPACE_JENKINS}" "${NAMESPACE_HARBOR}" "${NAMESPACE_TRIVY}"; do
        log_info "--- Namespace: ${ns} ---"
        kubectl get svc -n "${ns}" -o wide 2>/dev/null || log_warn "No services found in ${ns}"
    done
    
    # 输出验证摘要
    log_info "Verification summary: ${passed_checks}/${total_checks} checks passed"
    
    return ${status}
}

# print_summary - 打印部署摘要和访问信息
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

  Post-deployment steps:
    1. Access GitLab and change the initial root password
    2. Configure Jenkins credentials for Harbor/GitLab
    3. Create your first Jenkins pipeline
    4. Set up Harbor robot accounts for CI/CD
    5. Configure Trivy integration for automated scanning
================================================================

EOF
}

# main - 脚本入口，根据参数执行对应操作
# Args:
#   $1 - 操作类型: deploy (默认), verify, teardown
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
