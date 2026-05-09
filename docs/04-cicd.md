# CI/CD流水线详细文档

## 1. 概述

本阶段部署完整的CI/CD流水线，包括：
- GitLab: 代码仓库
- Jenkins: CI/CD引擎
- Harbor: 镜像仓库
- Trivy: 安全扫描

## 2. GitLab配置

### 2.1 部署GitLab

```bash
# 添加GitLab Helm仓库
helm repo add gitlab https://charts.gitlab.io/
helm repo update

# 部署GitLab
helm install gitlab gitlab/gitlab \
  --namespace gitlab --create-namespace \
  -f configs/gitlab/gitlab-values.yaml
```

### 2.2 配置说明

**关键配置项：**
- `global.hosts.gitlab.name`: GitLab域名
- `global.hosts.gitlab.https`: 是否启用HTTPS
- `global.ingress.tls.secretName`: TLS证书
- `gitlab-runner.enabled`: 启用Runner

### 2.3 访问GitLab

```bash
# 获取初始密码
kubectl get secret -n gitlab gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d

# 访问Web界面
https://gitlab.local
```

## 3. Jenkins配置

### 3.1 部署Jenkins

```bash
# 添加Jenkins Helm仓库
helm repo add jenkins https://charts.jenkins.io
helm repo update

# 部署Jenkins
helm install jenkins jenkins/jenkins \
  --namespace jenkins --create-namespace \
  -f configs/jenkins/jenkins-values.yaml
```

### 3.2 配置说明

**关键配置项：**
- `controller.adminPassword`: 管理员密码
- `controller.installPlugins`: 安装的插件
- `controller.JCasC.configScripts`: JCasC配置
- `agent.enabled`: 启用K8s Agent

### 3.3 访问Jenkins

```bash
# 获取初始密码
kubectl exec -n jenkins jenkins-0 -- cat /var/jenkins_home/secrets/initialAdminPassword

# 访问Web界面
https://jenkins.local
```

## 4. Harbor配置

### 4.1 部署Harbor

```bash
# 添加Harbor Helm仓库
helm repo add harbor https://helm.goharbor.io
helm repo update

# 部署Harbor
helm install harbor harbor/harbor \
  --namespace harbor --create-namespace \
  -f configs/harbor/harbor-values.yaml
```

### 4.2 配置说明

**关键配置项：**
- `expose.ingress.hosts.core`: Harbor域名
- `expose.tls.commonName`: TLS证书
- `persistence.persistentVolumeClaim.registry.size`: 存储大小
- `trivy.enabled`: 启用Trivy扫描

### 4.3 访问Harbor

```bash
# 访问Web界面
https://harbor.local

# 默认账号: admin / Harbor12345
```

## 5. Trivy配置

### 5.1 部署Trivy

```bash
# 添加Trivy Helm仓库
helm repo add aquasecurity https://aquasecurity.github.io/helm-charts/
helm repo update

# 部署Trivy
helm install trivy aquasecurity/trivy \
  --namespace trivy --create-namespace
```

### 5.2 使用Trivy

```bash
# 扫描镜像
trivy image nginx:latest

# 扫描文件系统
trivy fs .

# 扫描K8s集群
trivy k8s --report summary
```

## 6. Jenkins Pipeline

### 6.1 Pipeline示例

```groovy
pipeline {
    agent {
        kubernetes {
            yaml '''
                apiVersion: v1
                kind: Pod
                spec:
                  containers:
                  - name: maven
                    image: maven:3.8-openjdk-11
                    command: ['sleep']
                    args: ['infinity']
                  - name: docker
                    image: docker:24-dind
                    securityContext:
                      privileged: true
                  - name: trivy
                    image: aquasec/trivy:latest
                    command: ['sleep']
                    args: ['infinity']
            '''
        }
    }
    
    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }
        
        stage('Build') {
            steps {
                container('maven') {
                    sh 'mvn clean package -DskipTests'
                }
            }
        }
        
        stage('Test') {
            steps {
                container('maven') {
                    sh 'mvn test'
                }
            }
        }
        
        stage('Docker Build') {
            steps {
                container('docker') {
                    sh '''
                        docker build -t harbor.local/myproject/app:${BUILD_NUMBER} .
                    '''
                }
            }
        }
        
        stage('Security Scan') {
            steps {
                container('trivy') {
                    sh '''
                        trivy image --exit-code 1 --severity HIGH,CRITICAL \
                            harbor.local/myproject/app:${BUILD_NUMBER}
                    '''
                }
            }
        }
        
        stage('Push Image') {
            steps {
                container('docker') {
                    sh '''
                        docker login harbor.local -u admin -p Harbor12345
                        docker push harbor.local/myproject/app:${BUILD_NUMBER}
                    '''
                }
            }
        }
        
        stage('Deploy to Dev') {
            steps {
                container('kubectl') {
                    sh '''
                        kubectl set image deployment/app \
                            app=harbor.local/myproject/app:${BUILD_NUMBER} \
                            -n dev
                    '''
                }
            }
        }
        
        stage('Approval') {
            steps {
                input message: '是否部署到生产环境？'
            }
        }
        
        stage('Deploy to Prod') {
            steps {
                container('kubectl') {
                    sh '''
                        kubectl set image deployment/app \
                            app=harbor.local/myproject/app:${BUILD_NUMBER} \
                            -n prod
                    '''
                }
            }
        }
    }
    
    post {
        always {
            cleanWs()
        }
        failure {
            slackSend channel: '#ci-cd', message: "构建失败: ${env.JOB_NAME} #${env.BUILD_NUMBER}"
        }
        success {
            slackSend channel: '#ci-cd', message: "构建成功: ${env.JOB_NAME} #${env.BUILD_NUMBER}"
        }
    }
}
```

## 7. 完整CI/CD流程

```
代码提交流程：

1. 开发者提交代码到GitLab
2. GitLab触发Webhook
3. Jenkins拉取代码
4. 执行单元测试
5. 代码质量扫描 (SonarQube)
6. 构建Docker镜像
7. Trivy安全扫描
8. 推送镜像到Harbor
9. 部署到开发环境
10. 人工审批
11. 部署到生产环境
```

## 8. 常见问题

### 8.1 GitLab无法访问

```bash
# 检查Pod状态
kubectl get pods -n gitlab

# 检查Service
kubectl get svc -n gitlab

# 查看日志
kubectl logs -n gitlab <pod-name>
```

### 8.2 Jenkins构建失败

```bash
# 检查构建日志
# 在Jenkins UI查看Console Output

# 检查K8s Agent
kubectl get pods -n jenkins -l jenkins=agent
```

### 8.3 Harbor推送失败

```bash
# 检查TLS证书
openssl s_client -connect harbor.local:443

# 测试连接
curl -k https://harbor.local/v2/
```

## 9. 最佳实践

1. **镜像标签**: 使用`${BUILD_NUMBER}`作为标签，避免使用`latest`
2. **安全扫描**: 在CI流程中集成Trivy扫描
3. **权限控制**: 使用Harbor项目隔离不同环境
4. **备份策略**: 定期备份GitLab和Harbor数据
5. **监控告警**: 监控CI/CD流水线执行状态
