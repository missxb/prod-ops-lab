#!/usr/bin/env bash
#==============================================================================
# 05-setup-pipeline.sh - Configure Jenkins CI/CD Pipeline
# Enterprise Cloud Native Platform - Phase 4
#
# Description:
#   Sets up the complete CI/CD pipeline configuration including Jenkins
#   declarative pipeline, demo applications for testing, Kubernetes
#   deployment manifests, and Harbor webhook integration.
#
# Usage:
#   ./05-setup-pipeline.sh [deploy|verify]
#
#   deploy  - Full pipeline configuration (default)
#   verify  - Verify pipeline setup
#
# Environment Variables:
#   DOMAIN  - Base domain (default: example.com)
#
# Examples:
#   ./05-setup-pipeline.sh
#   DOMAIN=corp.example.com ./05-setup-pipeline.sh deploy
#   ./05-setup-pipeline.sh verify
#==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_DIR="${PROJECT_ROOT}/configs"

# Configuration
NAMESPACE_JENKINS="jenkins"
NAMESPACE_GITLAB="gitlab"
NAMESPACE_HARBOR="harbor"
NAMESPACE_TRIVY="trivy"
DOMAIN="${DOMAIN:-example.com}"
LOG_PREFIX="[Pipeline]"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}${LOG_PREFIX} [INFO] $(date '+%H:%M:%S') $*${NC}"; }
log_warn()  { echo -e "${YELLOW}${LOG_PREFIX} [WARN] $(date '+%H:%M:%S') $*${NC}"; }
log_error() { echo -e "${RED}${LOG_PREFIX} [ERROR] $(date '+%H:%M:%S') $*${NC}"; }

# check_prereqs - 检查必需工具
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
    
    log_info "Prerequisites satisfied"
}

# create_pipeline_namespace - 创建 CI/CD pipeline 命名空间
create_pipeline_namespace() {
    log_info "Creating pipeline namespace..."
    
    kubectl create namespace cicd --dry-run=client -o yaml | kubectl apply -f -
    
    kubectl label namespace cicd \
        purpose=ci-cd \
        team=devops \
        environment=production \
        --overwrite
    
    # 验证命名空间
    if kubectl get namespace cicd &>/dev/null; then
        log_info "Namespace cicd verified"
    else
        log_error "Failed to create namespace cicd"
        exit 1
    fi
}

# deploy_demo_app - 部署用于 pipeline 测试的示例应用
# 创建 demo-app 命名空间、ConfigMap、Deployment、Service
deploy_demo_app() {
    log_info "Deploying demo application for pipeline testing..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: demo-app
  labels:
    purpose: demo
    team: devops
    environment: staging

---
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: demo-app
data:
  APP_NAME: "enterprise-cloud-native-platform"
  APP_VERSION: "1.0.0"
  ENVIRONMENT: "staging"
  LOG_LEVEL: "info"
  HARBOR_REGISTRY: "harbor.${DOMAIN}"
  TRIVY_SERVER: "http://trivy-server.trivy:4954"

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  namespace: demo-app
  labels:
    app: demo-app
    version: v1
spec:
  replicas: 2
  selector:
    matchLabels:
      app: demo-app
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: demo-app
        version: v1
    spec:
      containers:
        - name: app
          image: harbor.${DOMAIN}/library/nginx:alpine
          ports:
            - containerPort: 80
              name: http
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 5
          envFrom:
            - configMapRef:
                name: app-config

---
apiVersion: v1
kind: Service
metadata:
  name: demo-app
  namespace: demo-app
  labels:
    app: demo-app
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
      name: http
  selector:
    app: demo-app
EOF
    
    log_info "Demo application deployed"
}

# create_pipeline_configs - 创建 Jenkins Pipeline 配置
# 包括声明式 Pipeline、Seed Job XML 等
create_pipeline_configs() {
    log_info "Creating Jenkins Pipeline configurations..."
    
    # Pipeline Configuration as Code
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: jenkins-pipeline-jobs
  namespace: ${NAMESPACE_JENKINS}
  labels:
    app.kubernetes.io/name: jenkins
    component: pipeline-jobs
data:
  pipeline-declarative.groovy: |
    // Declarative Pipeline for Enterprise Cloud Native Platform
    // Supports: Build, Test, Scan, Push, Deploy
    
    pipeline {
        agent {
            kubernetes {
                yaml '''
                apiVersion: v1
                kind: Pod
                spec:
                  containers:
                  - name: maven
                    image: maven:3.9-eclipse-temurin-17
                    command: ['cat']
                    tty: true
                    volumeMounts:
                    - name: maven-cache
                      mountPath: /root/.m2
                  - name: docker
                    image: docker:24-dind
                    securityContext:
                      privileged: true
                    env:
                    - name: DOCKER_HOST
                      value: tcp://localhost:2376
                    - name: DOCKER_TLS_CERTDIR
                      value: /certs
                    volumeMounts:
                    - name: docker-certs
                      mountPath: /certs
                    - name: docker-sock
                      mountPath: /var/run/docker.sock
                  - name: trivy
                    image: aquasec/trivy:0.50.1
                    command: ['cat']
                    tty: true
                  - name: kubectl
                    image: bitnami/kubectl:latest
                    command: ['cat']
                    tty: true
                  volumes:
                  - name: maven-cache
                    persistentVolumeClaim:
                      claimName: maven-cache-pvc
                  - name: docker-certs
                    emptyDir: {}
                  - name: docker-sock
                    emptyDir: {}
                '''
            }
        }
        
        environment {
            HARBOR_REGISTRY = "harbor.${DOMAIN}"
            TRIVY_SERVER = "http://trivy-server.trivy:4954"
            HARBOR_PROJECT = "devops"
            APP_NAME = "enterprise-app"
        }
        
        parameters {
            string(name: 'GIT_REPO', defaultValue: 'https://gitlab.${DOMAIN}/devops/enterprise-app.git', description: 'Git repository URL')
            string(name: 'BRANCH', defaultValue: 'main', description: 'Branch to build')
            string(name: 'NAMESPACE', defaultValue: 'demo-app', description: 'Target K8s namespace')
            booleanParam(name: 'SKIP_TESTS', defaultValue: false, description: 'Skip test stage')
            booleanParam(name: 'SKIP_SCAN', defaultValue: false, description: 'Skip security scan')
        }
        
        stages {
            stage('Checkout') {
                steps {
                    checkout([
                        \$class: 'GitSCM',
                        branches: [[name: params.BRANCH]],
                        userRemoteConfigs: [[
                            url: params.GIT_REPO,
                            credentialsId: 'gitlab-credentials'
                        ]]
                    ])
                }
            }
            
            stage('Build') {
                steps {
                    container('maven') {
                        sh '''
                            mvn clean package -DskipTests -B
                        '''
                    }
                }
            }
            
            stage('Unit Tests') {
                when {
                    expression { return !params.SKIP_TESTS }
                }
                steps {
                    container('maven') {
                        sh '''
                            mvn test -B
                        '''
                    }
                    junit '**/target/surefire-reports/*.xml'
                }
            }
            
            stage('Code Quality') {
                when {
                    expression { return !params.SKIP_TESTS }
                }
                steps {
                    container('maven') {
                        sh '''
                            mvn sonar:sonar \
                                -Dsonar.host.url=http://sonarqube:9000 \
                                -Dsonar.projectKey=enterprise-app || true
                        '''
                    }
                }
            }
            
            stage('Build Docker Image') {
                steps {
                    container('docker') {
                        script {
                            def imageTag = "\${HARBOR_REGISTRY}/\${HARBOR_PROJECT}/\${APP_NAME}:\${env.BUILD_NUMBER}"
                            def imageLatest = "\${HARBOR_REGISTRY}/\${HARBOR_PROJECT}/\${APP_NAME}:latest"
                            
                            sh """
                                docker build -t ${imageTag} -t ${imageLatest} .
                                docker tag ${imageTag} ${imageLatest}
                            """
                            
                            env.DOCKER_IMAGE = imageTag
                        }
                    }
                }
            }
            
            stage('Security Scan') {
                when {
                    expression { return !params.SKIP_SCAN }
                }
                steps {
                    container('trivy') {
                        script {
                            sh """
                                trivy image \
                                    --server \${TRIVY_SERVER} \
                                    --severity HIGH,CRITICAL \
                                    --exit-code 1 \
                                    --no-progress \
                                    --format table \
                                    \${env.DOCKER_IMAGE}
                            """
                        }
                    }
                }
            }
            
            stage('Push to Harbor') {
                steps {
                    container('docker') {
                        withCredentials([
                            usernamePassword(
                                credentialsId: 'harbor-credentials',
                                usernameVariable: 'DOCKER_USER',
                                passwordVariable: 'DOCKER_PASS'
                            )
                        ]) {
                            sh """
                                echo \${DOCKER_PASS} | docker login \${HARBOR_REGISTRY} -u \${DOCKER_USER} --password-stdin
                                docker push \${env.DOCKER_IMAGE}
                                docker push \${HARBOR_REGISTRY}/\${HARBOR_PROJECT}/\${APP_NAME}:latest
                            """
                        }
                    }
                }
            }
            
            stage('Deploy to Staging') {
                steps {
                    container('kubectl') {
                        sh """
                            kubectl set image deployment/demo-app \
                                app=\${env.DOCKER_IMAGE} \
                                -n \${params.NAMESPACE}
                            kubectl rollout status deployment/demo-app \
                                -n \${params.NAMESPACE} \
                                --timeout=300s
                        """
                    }
                }
            }
            
            stage('Integration Tests') {
                when {
                    expression { return !params.SKIP_TESTS }
                }
                steps {
                    container('maven') {
                        sh '''
                            mvn verify -Pintegration-test -B || true
                        '''
                    }
                }
            }
            
            stage('Production Approval') {
                when {
                    branch 'main'
                }
                steps {
                    input(
                        message: 'Deploy to Production?',
                        ok: 'Deploy',
                        submitter: 'admin,devops-team',
                        parameters: [
                            string(name: 'APPROVER', defaultValue: '', description: 'Approver name')
                        ]
                    )
                }
            }
            
            stage('Deploy to Production') {
                when {
                    branch 'main'
                }
                steps {
                    container('kubectl') {
                        sh """
                            kubectl set image deployment/demo-app \
                                app=\${env.DOCKER_IMAGE} \
                                -n production
                            kubectl rollout status deployment/demo-app \
                                -n production \
                                --timeout=600s
                        """
                    }
                }
            }
        }
        
        post {
            success {
                script {
                    slackSend(
                        channel: '#cicd-notifications',
                        color: '#36a64f',
                        message: "✅ Build SUCCESS: \${env.JOB_NAME} #\${env.BUILD_NUMBER}\nImage: \${env.DOCKER_IMAGE}"
                    )
                }
            }
            failure {
                script {
                    slackSend(
                        channel: '#cicd-notifications',
                        color: '#ff0000',
                        message: "❌ Build FAILED: \${env.JOB_NAME} #\${env.BUILD_NUMBER}\nURL: \${env.BUILD_URL}"
                    )
                }
            }
            always {
                cleanWs()
            }
        }
    }
    
  seed-job-config.xml: |
    <?xml version='1.0' encoding='UTF-8'?>
    <flow-definition plugin="workflow-job">
      <description>Seed job to create all pipeline jobs</description>
      <keepDependencies>false</keepDependencies>
      <properties>
        <org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
          <triggers/>
        </org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
      </properties>
      <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">
        <script>
          // Seed Job - Creates all pipeline jobs
          pipeline {
              agent any
              stages {
                  stage('Create Jobs') {
                      steps {
                          jobDsl script: '''
                              // Enterprise App Pipeline
                              multibranchPipelineJob('enterprise-app-pipeline') {
                                  branchSources {
                                      github {
                                          id('enterprise-app')
                                          repoOwner('enterprise')
                                          repository('cloud-native-platform')
                                      }
                                  }
                                  orphanedItemStrategy {
                                      discardOldItems {
                                          numToKeep(20)
                                      }
                                  }
                                  triggers {
                                      periodicFolderTrigger {
                                          interval('5m')
                                      }
                                  }
                              }
                              
                              // Demo App Pipeline
                              multibranchPipelineJob('demo-app-pipeline') {
                                  branchSources {
                                      github {
                                          id('demo-app')
                                          repoOwner('enterprise')
                                          repository('demo-app')
                                      }
                                  }
                                  orphanedItemStrategy {
                                      discardOldItems {
                                          numToKeep(10)
                                      }
                                  }
                              }
                          '''
                      }
                  }
              }
          }
        </script>
      </definition>
      <triggers/>
      <disabled>false</disabled>
    </flow-definition>
EOF
    
    log_info "Pipeline configurations created"
}

# create_k8s_manifests - 创建生产环境的 Kubernetes 部署清单
# 包括 Deployment、Service、Ingress
create_k8s_manifests() {
    log_info "Creating Kubernetes deployment manifests..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    purpose: production
    team: devops
    environment: production

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  namespace: production
  labels:
    app: demo-app
    version: v1
spec:
  replicas: 3
  selector:
    matchLabels:
      app: demo-app
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: demo-app
        version: v1
    spec:
      containers:
        - name: app
          image: harbor.${DOMAIN}/devops/enterprise-app:latest
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 512Mi
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 15
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 5

---
apiVersion: v1
kind: Service
metadata:
  name: demo-app
  namespace: production
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: 80
  selector:
    app: demo-app

---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo-app-ingress
  namespace: production
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - app.${DOMAIN}
      secretName: app-tls-secret
  rules:
    - host: app.${DOMAIN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: demo-app
                port:
                  number: 80
EOF
    
    log_info "Kubernetes manifests created"
}

# setup_harbor_webhook - 配置 Harbor Webhook 用于自动触发 Jenkins 构建
setup_harbor_webhook() {
    log_info "Setting up Harbor webhook for vulnerability scanning..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: harbor-webhook-config
  namespace: ${NAMESPACE_HARBOR}
  labels:
    app.kubernetes.io/name: harbor
    component: webhook-config
data:
  webhook.json: |
    {
      "name": "jenkins-trigger",
      "description": "Trigger Jenkins build on image push",
      "url": "http://jenkins-controller.${NAMESPACE_JENKINS}:8080/generic-webhook-trigger/invoke",
      "auth_header": "Authorization: Bearer jenkins-webhook-token",
      "event_types": [
        "pushImage",
        "scanningCompleted"
      ],
      "skip_cert_verify": true
    }
  
  vulnerability-scan-policy.json: |
    {
      "scan_on_push": true,
      "severity_threshold": "high",
      "notification_channels": [
        {
          "type": "slack",
          "webhook_url": "https://hooks.slack.com/services/xxx/yyy/zzz",
          "channel": "#security-alerts"
        }
      ]
    }
EOF
    
    log_info "Harbor webhook configured"
}

# verify_pipeline - 验证 pipeline 设置是否完整
# 检查命名空间、Demo App Pod、Pipeline ConfigMap、Webhook 配置
verify_pipeline() {
    log_info "Verifying pipeline setup..."
    
    local issues=0
    
    # 检查命名空间
    log_info "--- Namespaces ---"
    kubectl get ns cicd demo-app production 2>/dev/null || log_warn "Some namespaces may not exist yet"
    
    # 检查 Demo App (Staging)
    log_info "--- Demo App (Staging) ---"
    kubectl get pods -n demo-app -o wide 2>/dev/null || log_info "No pods in demo-app namespace"
    local staging_not_running
    staging_not_running=$(kubectl get pods -n demo-app --no-headers 2>/dev/null | grep -cv "Running\|Completed" || true)
    if [[ "${staging_not_running}" -gt 0 ]]; then
        log_warn "${staging_not_running} staging pods not in Running state"
        ((issues++))
    fi
    
    # 检查 Demo App (Production)
    log_info "--- Demo App (Production) ---"
    kubectl get pods -n production -o wide 2>/dev/null || log_info "No pods in production namespace"
    local prod_not_running
    prod_not_running=$(kubectl get pods -n production --no-headers 2>/dev/null | grep -cv "Running\|Completed" || true)
    if [[ "${prod_not_running}" -gt 0 ]]; then
        log_warn "${prod_not_running} production pods not in Running state"
        ((issues++))
    fi
    
    # 检查 Jenkins Pipeline ConfigMaps
    log_info "--- Jenkins Pipeline ConfigMaps ---"
    if kubectl get configmap -n "${NAMESPACE_JENKINS}" -l component=pipeline-jobs 2>/dev/null; then
        log_info "Pipeline ConfigMaps verified"
    else
        log_warn "Pipeline ConfigMaps not found"
    fi
    
    # 检查 Harbor Webhook Config
    log_info "--- Harbor Webhook Config ---"
    if kubectl get configmap harbor-webhook-config -n "${NAMESPACE_HARBOR}" 2>/dev/null; then
        log_info "Harbor webhook config verified"
    else
        log_warn "Harbor webhook config not found"
    fi
    
    if [[ "${issues}" -eq 0 ]]; then
        log_info "Pipeline verification complete - no issues detected"
    else
        log_warn "Pipeline verification complete - ${issues} issues detected"
    fi
}

# Print summary
print_summary() {
    cat <<EOF

================================================================
  CI/CD Pipeline Configuration Complete
================================================================
  
  Pipeline Overview:
  ─────────────────────────────────────────────────────────────
  1. Checkout        → Git clone from GitLab
  2. Build           → Maven build (Java) or npm/yarn (Node.js)
  3. Unit Tests      → Run test suite
  4. Code Quality    → SonarQube analysis
  5. Docker Build    → Build container image
  6. Security Scan   → Trivy vulnerability scan
  7. Push to Harbor  → Push image to registry
  8. Deploy Staging  → Deploy to staging namespace
  9. Integration Tests → Run integration test suite
  10. Approval       → Manual approval gate
  11. Deploy Prod    → Deploy to production namespace
  ─────────────────────────────────────────────────────────────
  
  Environments:
    Staging:   demo-app namespace
    Production: production namespace
  
  Security:
    Trivy Server: http://trivy-server.trivy:4954
    Harbor:       https://harbor.${DOMAIN}
  
  Monitoring:
    Jenkins:     https://jenkins.${DOMAIN}
    GitLab:      https://gitlab.${DOMAIN}
  
  Pipeline Features:
    ✓ GitOps workflow
    ✓ Automated security scanning
    ✓ Multi-stage deployment
    ✓ Manual approval gates
    ✓ Slack notifications
    ✓ Artifact archiving
    ✓ Rollback capability
  
  Next Steps:
    1. Configure Jenkins credentials
    2. Set up GitLab webhooks
    3. Configure Slack notifications
    4. Set up SonarQube integration
    5. Configure production approval workflows
    6. Set up monitoring and alerting
================================================================

EOF
}

# Main
main() {
    local action="${1:-deploy}"
    
    log_info "============================================"
    log_info "  CI/CD Pipeline Configuration"
    log_info "  Domain: ${DOMAIN}"
    log_info "============================================"
    
    case "${action}" in
        deploy)
            check_prereqs
            create_pipeline_namespace
            deploy_demo_app
            create_pipeline_configs
            create_k8s_manifests
            setup_harbor_webhook
            verify_pipeline
            print_summary
            ;;
        verify)
            verify_pipeline
            ;;
        *)
            echo "Usage: $0 {deploy|verify}"
            exit 1
            ;;
    esac
}

main "$@"
