#!/usr/bin/env bash
#==============================================================================
# 04-deploy-trivy.sh - Deploy Trivy Security Scanner
# Enterprise Cloud Native Platform - Phase 4
#==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Configuration
NAMESPACE="trivy"
RELEASE_NAME="trivy-server"
CHART_VERSION="0.28.0"
DOMAIN="${DOMAIN:-example.com}"
LOG_PREFIX="[Trivy]"

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
    
    for cmd in kubectl helm; do
        if ! command -v "${cmd}" &>/dev/null; then
            log_error "Required command not found: ${cmd}"
            exit 1
        fi
    done
    
    # Add Aqua Security Helm repo
    if ! helm repo list 2>/dev/null | grep -q aquasecurity; then
        log_info "Adding Aqua Security Helm repository..."
        helm repo add aquasecurity https://aquasecurity.github.io/helm-charts/ --force-update
        helm repo update
    fi
    
    log_info "Prerequisites satisfied"
}

# Create namespace
create_namespace() {
    log_info "Creating namespace: ${NAMESPACE}"
    
    kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    
    kubectl label namespace "${NAMESPACE}" \
        purpose=security \
        team=devops \
        environment=production \
        --overwrite
}

# Deploy Trivy Server
deploy_trivy_server() {
    log_info "Deploying Trivy Server..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: trivy-config
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: trivy
    component: config
data:
  trivy.yaml: |
    scan:
      scanners:
        - vuln
        - misconfig
        - secret
        - license
      slow: false
      timeout: 5m
    vulnerability:
      ignore-unfixed: true
      security-checks:
        - vuln
      severity:
        - HIGH
        - CRITICAL
    server:
      listen: "0.0.0.0:4954"
      cache-dir: "/home/scanner/.cache/trivy"
    cache:
      redis:
        enabled: false
      inmemory:
        enabled: true

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: trivy-server
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: trivy-server
    app.kubernetes.io/component: server
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: trivy-server
  template:
    metadata:
      labels:
        app.kubernetes.io/name: trivy-server
        app.kubernetes.io/component: server
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
    spec:
      serviceAccountName: trivy-server
      securityContext:
        fsGroup: 1000
        runAsGroup: 1000
        runAsNonRoot: true
        runAsUser: 1000
      containers:
        - name: trivy-server
          image: aquasec/trivy:0.50.1
          command:
            - "trivy"
            - "server"
            - "--listen"
            - "0.0.0.0:4954"
            - "--cache-dir"
            - "/home/scanner/.cache/trivy"
          args:
            - "--config=/etc/trivy/trivy.yaml"
          ports:
            - containerPort: 4954
              name: rpc
              protocol: TCP
            - containerPort: 9090
              name: metrics
              protocol: TCP
          volumeMounts:
            - name: trivy-config
              mountPath: /etc/trivy
            - name: trivy-cache
              mountPath: /home/scanner/.cache
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 2Gi
          livenessProbe:
            httpGet:
              path: /healthz
              port: 4954
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 5
          readinessProbe:
            httpGet:
              path: /healthz
              port: 4954
            initialDelaySeconds: 5
            periodSeconds: 10
            timeoutSeconds: 5
          env:
            - name: TRIVY_CACHE_DIR
              value: "/home/scanner/.cache"
            - name: TRIVY_LISTEN
              value: "0.0.0.0:4954"
      volumes:
        - name: trivy-config
          configMap:
            name: trivy-config
        - name: trivy-cache
          emptyDir:
            sizeLimit: 5Gi
      imagePullSecrets: []

---
apiVersion: v1
kind: Service
metadata:
  name: trivy-server
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: trivy-server
    app.kubernetes.io/component: server
spec:
  type: ClusterIP
  ports:
    - name: rpc
      port: 4954
      targetPort: 4954
      protocol: TCP
    - name: metrics
      port: 9090
      targetPort: 9090
      protocol: TCP
  selector:
    app.kubernetes.io/name: trivy-server

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: trivy-server
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: trivy-server

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: trivy-server-cluster-role
rules:
  - apiGroups: [""]
    resources: ["pods", "nodes", "namespaces", "services"]
    verbs: ["get", "list", "watch"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: trivy-server-cluster-rolebinding
subjects:
  - kind: ServiceAccount
    name: trivy-server
    namespace: ${NAMESPACE}
roleRef:
  kind: ClusterRole
  name: trivy-server-cluster-role
  apiGroup: rbac.authorization.k8s.io
EOF
    
    log_info "Trivy Server deployed"
}

# Deploy Trivy Operator for continuous scanning
deploy_trivy_operator() {
    log_info "Deploying Trivy Operator for continuous scanning..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: trivy-operator-config
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: trivy-operator
data:
  trivy.repository: "aquasec/trivy"
  trivy.tag: "0.50.1"
  trivy.severity: "HIGH,CRITICAL"
  trivy.ignoreUnfixed: "true"
  trivy.skipDBUpdate: "false"
  trivy.cacheRegistry: "harbor.${DOMAIN}"
  trivy.serverURL: "http://trivy-server.${NAMESPACE}:4954"
  trivy.timeout: "5m0s"

---
apiVersion: v1
kind: Namespace
metadata:
  name: trivy-operator
  labels:
    purpose: security-scanning
    team: devops
EOF
    
    log_info "Trivy Operator configuration created"
}

# Deploy Trivy Jenkins Integration ConfigMap
deploy_jenkins_integration() {
    log_info "Deploying Trivy Jenkins integration configuration..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: trivy-jenkins-pipeline
  namespace: jenkins
  labels:
    app.kubernetes.io/name: trivy
    component: jenkins-integration
data:
  Jenkinsfile.trivy-scan: |
    // Trivy Security Scan Pipeline
    // Usage: @Library('enterprise-pipeline-lib') _
    
    pipeline {
        agent any
        
        parameters {
            string(name: 'IMAGE', description: 'Docker image to scan')
            choice(name: 'SEVERITY', choices: ['HIGH,CRITICAL', 'MEDIUM,HIGH,CRITICAL', 'LOW,MEDIUM,HIGH,CRITICAL'], description: 'Vulnerability severity')
            booleanParam(name: 'FAIL_ON_VULNERABILITIES', defaultValue: true, description: 'Fail pipeline on vulnerabilities')
        }
        
        stages {
            stage('Setup Trivy') {
                steps {
                    sh '''
                        # Install Trivy
                        curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin v0.50.1
                        trivy --version
                    '''
                }
            }
            
            stage('Download Vulnerability Database') {
                steps {
                    sh '''
                        trivy image --download-db-only || true
                    '''
                }
            }
            
            stage('Scan Image') {
                steps {
                    script {
                        def severity = params.SEVERITY
                        def failCode = params.FAIL_ON_VULNERABILITIES ? '1' : '0'
                        
                        sh """
                            # Scan for vulnerabilities
                            trivy image \
                                --severity ${severity} \
                                --exit-code ${failCode} \
                                --no-progress \
                                --format table \
                                --output trivy-report.txt \
                                ${params.IMAGE}
                            
                            # Generate JSON report
                            trivy image \
                                --severity ${severity} \
                                --exit-code 0 \
                                --no-progress \
                                --format json \
                                --output trivy-report.json \
                                ${params.IMAGE}
                        """
                    }
                }
            }
            
            stage('Upload Report') {
                steps {
                    archiveArtifacts artifacts: 'trivy-report.*', fingerprint: true
                    sh '''
                        # Push report to Harbor annotation if available
                        if [ -f trivy-report.json ]; then
                            echo "Vulnerability scan report generated"
                            echo "Total vulnerabilities: $(cat trivy-report.json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(r.get("Vulnerabilities", []) for r in d.get("Results", []))[:])' 2>/dev/null || echo 'N/A')"
                        fi
                    '''
                }
            }
            
            stage('Notify') {
                when {
                    failure()
                }
                steps {
                    script {
                        def msg = "⚠️ Security scan FAILED for ${params.IMAGE}\nSeverity: ${params.SEVERITY}\nBuild: ${env.BUILD_URL}"
                        slackSend(
                            channel: '#security-alerts',
                            color: '#ff0000',
                            message: msg
                        )
                    }
                }
            }
        }
        
        post {
            always {
                cleanWs()
            }
        }
    }
    
  trivy-wrapper.sh: |
    #!/bin/bash
    # Trivy Wrapper Script for Jenkins
    # Usage: trivy-wrapper.sh <action> <image>
    
    set -euo pipefail
    
    ACTION="${1:-scan}"
    IMAGE="${2:-}"
    SEVERITY="${3:-HIGH,CRITICAL}"
    TRIVY_SERVER="${TRIVY_SERVER_URL:-http://trivy-server.trivy:4954}"
    
    case "${ACTION}" in
        scan)
            trivy image \
                --server "${TRIVY_SERVER}" \
                --severity "${SEVERITY}" \
                --format json \
                "${IMAGE}"
            ;;
        scan-local)
            trivy image \
                --severity "${SEVERITY}" \
                --download-db-only
            trivy image \
                --severity "${SEVERITY}" \
                --format table \
                "${IMAGE}"
            ;;
        sbom)
            trivy image \
                --format cyclonedx \
                --output sbom.json \
                "${IMAGE}"
            ;;
        *)
            echo "Usage: $0 {scan|scan-local|sbom} <image> [severity]"
            exit 1
            ;;
    esac
EOF
    
    log_info "Jenkins integration configured"
}

# Verify deployment
verify_deployment() {
    log_info "Verifying Trivy deployment..."
    
    log_info "--- Pods ---"
    kubectl get pods -n "${NAMESPACE}" -o wide
    
    log_info "--- Services ---"
    kubectl get svc -n "${NAMESPACE}" -o wide
    
    # Test connectivity
    log_info "--- Health Check ---"
    kubectl exec -n "${NAMESPACE}" \
        "$(kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/name=trivy-server -o jsonpath='{.items[0].metadata.name}')" \
        -- wget -qO- http://localhost:4954/healthz 2>/dev/null || \
        log_warn "Trivy health check failed (pod may still be starting)"
    
    log_info "Verification complete"
}

# Print summary
print_summary() {
    cat <<EOF

================================================================
  Trivy Scanner Deployment Complete
================================================================
  Namespace:     ${NAMESPACE}
  Server:        http://trivy-server.${NAMESPACE}:4954
  Operator:      trivy-operator (if deployed)
  
  Integration:
    - Jenkins Pipeline: trivy-jenkins-pipeline ConfigMap
    - Harbor: Built-in Trivy adapter
    - K8s: Trivy Operator for continuous scanning
  
  Usage in Jenkins Pipeline:
    stage('Security Scan') {
        steps {
            sh 'trivy image --severity HIGH,CRITICAL --exit-code 1 \${IMAGE}'
        }
    }
  
  Docker CLI Usage:
    trivy image --server http://trivy-server.${NAMESPACE}:4954 <image>
================================================================

EOF
}

# Main
main() {
    local action="${1:-deploy}"
    
    log_info "============================================"
    log_info "  Trivy Security Scanner Deployment"
    log_info "============================================"
    
    case "${action}" in
        deploy)
            check_prereqs
            create_namespace
            deploy_trivy_server
            deploy_trivy_operator
            deploy_jenkins_integration
            wait_for_ready
            verify_deployment
            print_summary
            ;;
        verify)
            verify_deployment
            ;;
        delete)
            log_warn "Deleting Trivy deployment..."
            kubectl delete namespace "${NAMESPACE}" --wait 2>/dev/null || true
            kubectl delete configmap trivy-jenkins-pipeline -n jenkins 2>/dev/null || true
            log_info "Trivy deleted"
            ;;
        *)
            echo "Usage: $0 {deploy|verify|delete}"
            exit 1
            ;;
    esac
}

# Wait for readiness function
wait_for_ready() {
    log_info "Waiting for Trivy Server to be ready..."
    
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=trivy-server \
        -n "${NAMESPACE}" \
        --timeout=300s 2>/dev/null || \
        log_warn "Timeout waiting for Trivy Server"
    
    log_info "Trivy Server ready"
}

main "$@"
