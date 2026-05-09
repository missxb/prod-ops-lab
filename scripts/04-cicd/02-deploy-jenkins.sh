#!/usr/bin/env bash
#==============================================================================
# 02-deploy-jenkins.sh - Deploy Jenkins with Helm
# Enterprise Cloud Native Platform - Phase 4
#
# Description:
#   Deploys Jenkins CI server using Helm chart with Kubernetes plugin support,
#   RBAC configuration, GitLab/Harbor credentials, and shared pipeline library.
#
# Usage:
#   ./02-deploy-jenkins.sh [deploy|verify|credentials|delete]
#
#   deploy      - Full Jenkins deployment (default)
#   verify      - Verify Jenkins is running
#   credentials - Show Jenkins login credentials
#   delete      - Remove Jenkins deployment
#
# Environment Variables:
#   DOMAIN  - Base domain for Jenkins (default: example.com)
#
# Examples:
#   ./02-deploy-jenkins.sh
#   DOMAIN=corp.example.com ./02-deploy-jenkins.sh deploy
#   ./02-deploy-jenkins.sh credentials
#==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_DIR="${PROJECT_ROOT}/configs/jenkins"

# Configuration
NAMESPACE="jenkins"
NAMESPACE_AGENTS="jenkins-agents"
RELEASE_NAME="jenkins"
CHART_VERSION="5.1.18"
VALUES_FILE="${CONFIG_DIR}/jenkins-values.yaml"
DOMAIN="${DOMAIN:-example.com}"
LOG_PREFIX="[Jenkins]"

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
    
    for cmd in kubectl helm; do
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
    
    if ! helm repo list 2>/dev/null | grep -q jenkins; then
        log_info "Adding Jenkins Helm repository..."
        helm repo add jenkins https://charts.jenkins.io --force-update
        helm repo update
    fi
    
    log_info "Prerequisites satisfied"
}

# create_namespaces - 创建 Jenkins 和 Jenkins Agents 命名空间
create_namespaces() {
    log_info "Creating namespaces..."
    
    kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace "${NAMESPACE_AGENTS}" --dry-run=client -o yaml | kubectl apply -f -
    
    kubectl label namespace "${NAMESPACE}" \
        purpose=ci \
        team=devops \
        environment=production \
        --overwrite
    
    kubectl label namespace "${NAMESPACE_AGENTS}" \
        purpose=ci-agents \
        team=devops \
        environment=production \
        --overwrite
    
    # 验证命名空间
    for ns in "${NAMESPACE}" "${NAMESPACE_AGENTS}"; do
        if kubectl get namespace "${ns}" &>/dev/null; then
            log_info "Namespace ${ns} verified"
        else
            log_error "Failed to create namespace ${ns}"
            exit 1
        fi
    done
}

# create_rbac - 创建 Jenkins Kubernetes 插件所需的 RBAC 权限
# 包括 ServiceAccount, Role, RoleBinding, ClusterRole, ClusterRoleBinding
create_rbac() {
    log_info "Creating RBAC for Jenkins Kubernetes plugin..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins-agent
  namespace: ${NAMESPACE_AGENTS}
  labels:
    app.kubernetes.io/name: jenkins-agent
    app.kubernetes.io/managed-by: jenkins

---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: jenkins-agent-role
  namespace: ${NAMESPACE_AGENTS}
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "pods/status", "events"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["secrets", "configmaps"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jenkins-agent-rolebinding
  namespace: ${NAMESPACE_AGENTS}
subjects:
  - kind: ServiceAccount
    name: jenkins-agent
    namespace: ${NAMESPACE_AGENTS}
roleRef:
  kind: Role
  name: jenkins-agent-role
  apiGroup: rbac.authorization.k8s.io

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: jenkins-agent-cluster-role
rules:
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["networkpolicies"]
    verbs: ["get", "list", "watch"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: jenkins-agent-cluster-rolebinding
subjects:
  - kind: ServiceAccount
    name: jenkins-agent
    namespace: ${NAMESPACE_AGENTS}
roleRef:
  kind: ClusterRole
  name: jenkins-agent-cluster-role
  apiGroup: rbac.authorization.k8s.io
EOF
    
    log_info "RBAC created"
}

# create_credentials - 创建 Jenkins 所需的凭据 Secrets
# 包括 GitLab 凭据、Harbor Docker Registry 凭据、Docker Config
create_credentials() {
    log_info "Creating credential secrets..."
    
    # GitLab 凭据
    local gitlab_password
    gitlab_password=$(openssl rand -base64 24 | tr -d '=+/' || true)
    if [[ -z "${gitlab_password}" ]]; then
        log_error "Failed to generate GitLab deployer password"
        exit 1
    fi
    
    kubectl create secret generic jenkins-gitlab-credentials \
        --from-literal=username="gitlab-deployer" \
        --from-literal=password="${gitlab_password}" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
    log_info "GitLab credentials secret created"
    
    # Harbor Docker Registry 凭据
    kubectl create secret docker-registry jenkins-harbor-credentials \
        --docker-server="harbor.${DOMAIN}" \
        --docker-username="admin" \
        --docker-password="Harbor12345" \
        --docker-email="admin@${DOMAIN}" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
    log_info "Harbor registry credentials secret created"
    
    # Docker config (用于镜像拉取)
    kubectl create secret generic jenkins-docker-config \
        --from-file=config.json=/dev/null \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || \
        log_warn "Docker config secret may already exist"
    
    # 验证 Secrets 创建成功
    local secret_count
    secret_count=$(kubectl get secrets -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l)
    log_info "Credentials created (${secret_count} secrets in namespace)"
}

# deploy_jenkins - 使用 Helm 安装/升级 Jenkins
# 使用 --atomic 标志确保部署失败时自动回滚
deploy_jenkins() {
    log_info "Deploying Jenkins..."
    
    # 验证 values 文件存在
    if [[ ! -f "${VALUES_FILE}" ]]; then
        log_error "Values file not found: ${VALUES_FILE}"
        log_error "Please create the values file before deploying"
        exit 1
    fi
    
    local admin_password
    admin_password=$(openssl rand -base64 16 | tr -d '=+/' || true)
    
    if helm upgrade --install "${RELEASE_NAME}" jenkins/jenkins \
        --namespace "${NAMESPACE}" \
        --values "${VALUES_FILE}" \
        --set controller.ingress.hostName="jenkins.${DOMAIN}" \
        --set controller.ingress.tls[0].hosts[0]="jenkins.${DOMAIN}" \
        --set controller.admin.password="${admin_password}" \
        --timeout 10m \
        --wait \
        --atomic; then
        log_info "Jenkins Helm release deployed"
    else
        log_error "Jenkins Helm release deployment failed"
        log_error "Check 'helm history ${RELEASE_NAME} -n ${NAMESPACE}' for details"
        exit 1
    fi
}

# wait_for_ready - 等待 Jenkins Pod 就绪
wait_for_ready() {
    log_info "Waiting for Jenkins to be ready..."
    
    if kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=jenkins \
        -n "${NAMESPACE}" \
        --timeout=600s 2>/dev/null; then
        log_info "Jenkins is ready"
    else
        log_warn "Timeout waiting for Jenkins to become ready"
        log_warn "Check 'kubectl get pods -n ${NAMESPACE}' for pod status"
    fi
}

# setup_pipeline_library - 配置 Jenkins 共享 Pipeline 库
# 提供 buildAndPushImage, trivyScan, deployToK8s, notifySlack 等通用步骤
setup_pipeline_library() {
    log_info "Setting up shared pipeline library..."
    
    cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: jenkins-shared-library
  namespace: jenkins
  labels:
    app.kubernetes.io/name: jenkins
    component: pipeline-library
data:
  EnterprisePipelineLib.groovy: |
    package com.enterprise.pipeline
    
    /**
     * Enterprise Shared Pipeline Library
     * Provides common pipeline stages for the platform
     */
    class EnterprisePipelineLib implements Serializable {
        
        def steps
        
        EnterprisePipelineLib(steps) {
            this.steps = steps
        }
        
        /**
         * Build and push container image
         */
        def buildAndPushImage(Map config = [:]) {
            def registry = config.registry ?: "harbor.example.com"
            def project = config.project ?: "devops"
            def image = config.image ?: "app"
            def tag = config.tag ?: steps.env.BUILD_NUMBER
            def dockerfile = config.dockerfile ?: "Dockerfile"
            
            def fullImage = "${registry}/${project}/${image}:${tag}"
            
            steps.stage('Build Image') {
                steps.sh """
                    docker build -t ${fullImage} \
                        -f ${dockerfile} \
                        --label build.number=${tag} \
                        --label build.date=\$(date -u +%Y-%m-%dT%H:%M:%SZ) \
                        .
                """
            }
            
            steps.stage('Push Image') {
                steps.withCredentials([
                    steps.usernamePassword(
                        credentialsId: 'harbor-credentials',
                        usernameVariable: 'DOCKER_USER',
                        passwordVariable: 'DOCKER_PASS'
                    )
                ]) {
                    steps.sh """
                        echo \$DOCKER_PASS | docker login ${registry} -u \$DOCKER_USER --password-stdin
                        docker push ${fullImage}
                        docker tag ${fullImage} ${registry}/${project}/${image}:latest
                        docker push ${registry}/${project}/${image}:latest
                    """
                }
            }
            
            return fullImage
        }
        
        /**
         * Run Trivy security scan
         */
        def trivyScan(Map config = [:]) {
            def image = config.image
            def severity = config.severity ?: "HIGH,CRITICAL"
            def failOnVuln = config.failOnVuln ?: true
            
            steps.stage('Security Scan') {
                steps.sh """
                    trivy image \
                        --severity ${severity} \
                        --exit-code ${failOnVuln ? '1' : '0'} \
                        --no-progress \
                        --format table \
                        ${image}
                """
            }
        }
        
        /**
         * Deploy to Kubernetes
         */
        def deployToK8s(Map config = [:]) {
            def namespace = config.namespace ?: "default"
            def manifest = config.manifest ?: "k8s/"
            
            steps.stage('Deploy') {
                steps.sh """
                    kubectl apply -f ${manifest} -n ${namespace}
                    kubectl rollout status deployment/${config.app ?: 'app'} \
                        -n ${namespace} \
                        --timeout=300s
                """
            }
        }
        
        /**
         * Notify Slack
         */
        def notifySlack(String channel, String message, String color = "#36a64f") {
            steps.slackSend(
                channel: channel,
                color: color,
                message: message
            )
        }
    }
    
    return new EnterprisePipelineLib(steps)
EOF
    
    log_info "Shared pipeline library configured"
}

# verify_deployment - 验证 Jenkins 部署状态
# 检查 Pod、Service、PVC、Ingress 和 Agent 命名空间
verify_deployment() {
    log_info "Verifying Jenkins deployment..."
    
    local issues=0
    
    # 检查 Jenkins Pod 状态
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
    
    log_info "--- Ingress ---"
    kubectl get ingress -n "${NAMESPACE}" -o wide
    
    log_info "--- Agent Namespace ---"
    kubectl get all -n "${NAMESPACE_AGENTS}" 2>/dev/null || log_info "No resources in agent namespace yet"
    
    # 验证 RBAC 是否存在
    log_info "--- RBAC ---"
    if kubectl get serviceaccount jenkins-agent -n "${NAMESPACE_AGENTS}" &>/dev/null; then
        log_info "Jenkins agent ServiceAccount verified"
    else
        log_warn "Jenkins agent ServiceAccount not found"
    fi
    
    if [[ "${issues}" -eq 0 ]]; then
        log_info "Verification complete - no issues detected"
    else
        log_warn "Verification complete - ${issues} issues detected"
    fi
}

# Print credentials
print_credentials() {
    local password
    password=$(kubectl get secret jenkins -n "${NAMESPACE}" \
        -o jsonpath='{.data.jenkins-admin-password}' 2>/dev/null | base64 -d)
    
    cat <<EOF

================================================================
  Jenkins Credentials
================================================================
  URL:      https://jenkins.${DOMAIN}
  Username: admin
  Password: ${password}
================================================================

  Next steps:
  1. Access Jenkins web interface
  2. Verify Kubernetes plugin configuration
  3. Create your first pipeline job
  4. Configure Git credentials
================================================================

EOF
}

# Main
main() {
    local action="${1:-deploy}"
    
    log_info "============================================"
    log_info "  Jenkins Deployment"
    log_info "  Domain: ${DOMAIN}"
    log_info "============================================"
    
    case "${action}" in
        deploy)
            check_prereqs
            create_namespaces
            create_rbac
            create_credentials
            deploy_jenkins
            wait_for_ready
            setup_pipeline_library
            verify_deployment
            print_credentials
            ;;
        verify)
            verify_deployment
            ;;
        credentials)
            print_credentials
            ;;
        delete)
            log_warn "Deleting Jenkins deployment..."
            helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --wait
            kubectl delete pvc --all -n "${NAMESPACE}" 2>/dev/null || true
            kubectl delete namespace "${NAMESPACE_AGENTS}" 2>/dev/null || true
            log_info "Jenkins deleted"
            ;;
        *)
            echo "Usage: $0 {deploy|verify|credentials|delete}"
            exit 1
            ;;
    esac
}

main "$@"
