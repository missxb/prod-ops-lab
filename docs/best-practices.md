# 企业级云原生运维平台 - 最佳实践指南

## 目录

- [容器最佳实践](#容器最佳实践)
- [Kubernetes最佳实践](#kubernetes最佳实践)
- [CI/CD最佳实践](#cicd最佳实践)
- [监控最佳实践](#监控最佳实践)
- [安全最佳实践](#安全最佳实践)
- [成本优化最佳实践](#成本优化最佳实践)

---

## 容器最佳实践

### 1. 镜像构建最佳实践

#### 1.1 使用多阶段构建

```dockerfile
# 多阶段构建示例
# 阶段1: 构建应用
FROM golang:1.21-alpine AS builder

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /app/main .

# 阶段2: 运行应用
FROM alpine:3.18

# 安装必要的系统包
RUN apk --no-cache add ca-certificates tzdata

# 创建非root用户
RUN addgroup -g 1001 -S appgroup && \
    adduser -u 1001 -S appuser -G appgroup

# 设置工作目录
WORKDIR /app

# 复制构建产物
COPY --from=builder /app/main .

# 使用非root用户运行
USER appuser

# 暴露端口
EXPOSE 8080

# 启动命令
CMD ["./main"]
```

#### 1.2 使用最小化基础镜像

```dockerfile
# 推荐使用alpine或distroless镜像
# Alpine镜像
FROM alpine:3.18

# 或者使用distroless镜像（Google提供）
FROM gcr.io/distroless/static-debian12

# 避免使用ubuntu或centos等完整镜像
# 这些镜像体积大，包含不必要的组件
```

#### 1.3 优化镜像层缓存

```dockerfile
# 正确的层顺序（从变化最少到变化最多）
FROM node:18-alpine

# 1. 系统依赖（变化最少）
RUN apk add --no-cache dumb-init

# 2. 依赖文件
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --only=production

# 3. 应用代码（变化最多）
COPY . .

# 4. 构建命令
RUN npm run build

# 启动命令
ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "server.js"]
```

#### 1.4 使用.dockerignore

```dockerignore
# .dockerignore文件示例
.git
.gitignore
.env
.env.*
*.md
LICENSE
docker-compose*.yml
Dockerfile*
.dockerignore
node_modules
npm-debug.log
coverage
.nyc_output
dist
build
```

### 2. 容器运行最佳实践

#### 2.1 资源限制

```yaml
# Pod资源限制配置
apiVersion: v1
kind: Pod
metadata:
  name: example-pod
spec:
  containers:
  - name: app
    image: nginx:1.25-alpine
    resources:
      requests:
        cpu: "100m"        # 请求100m CPU
        memory: "128Mi"    # 请求128Mi内存
      limits:
        cpu: "500m"        # 最大500m CPU
        memory: "256Mi"    # 最大256Mi内存
    # 临时存储限制
    ephemeral-storage:
      requests:
        storage: "1Gi"
      limits:
        storage: "2Gi"
```

#### 2.2 健康检查配置

```yaml
# 健康检查配置示例
apiVersion: v1
kind: Pod
metadata:
  name: example-pod
spec:
  containers:
  - name: app
    image: nginx:1.25-alpine
    
    # 就绪探针：检查服务是否准备好接收流量
    readinessProbe:
      httpGet:
        path: /healthz
        port: 8080
      initialDelaySeconds: 10
      periodSeconds: 5
      timeoutSeconds: 3
      failureThreshold: 3
    
    # 存活探针：检查服务是否正常运行
    livenessProbe:
      httpGet:
        path: /healthz
        port: 8080
      initialDelaySeconds: 15
      periodSeconds: 10
      timeoutSeconds: 3
      failureThreshold: 3
    
    # 启动探针：检查服务是否启动成功
    startupProbe:
      httpGet:
        path: /healthz
        port: 8080
      initialDelaySeconds: 5
      periodSeconds: 5
      timeoutSeconds: 3
      failureThreshold: 30
```

#### 2.3 安全上下文配置

```yaml
# 安全上下文配置
apiVersion: v1
kind: Pod
metadata:
  name: example-pod
spec:
  # Pod级安全上下文
  securityContext:
    runAsNonRoot: true
    runAsUser: 1001
    runAsGroup: 1001
    fsGroup: 1001
    supplementalGroups: [1001]
  
  containers:
  - name: app
    image: nginx:1.25-alpine
    
    # 容器级安全上下文
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
          - ALL
        add:
          - NET_BIND_SERVICE
    
    # 挂载可写目录
    volumeMounts:
    - name: tmp
      mountPath: /tmp
    - name: cache
      mountPath: /var/cache/nginx
    - name: run
      mountPath: /var/run
  
  # 可写临时目录
  volumes:
  - name: tmp
    emptyDir: {}
  - name: cache
    emptyDir: {}
  - name: run
    emptyDir: {}
```

### 3. 日志管理最佳实践

#### 3.1 结构化日志

```python
# Python结构化日志示例
import logging
import json
from datetime import datetime

class JSONFormatter(logging.Formatter):
    def format(self, record):
        log_entry = {
            "timestamp": datetime.utcnow().isoformat(),
            "level": record.levelname,
            "message": record.getMessage(),
            "module": record.module,
            "function": record.funcName,
            "line": record.lineno,
            "thread": record.thread,
            "process": record.process
        }
        
        # 添加额外字段
        if hasattr(record, 'extra_data'):
            log_entry["extra"] = record.extra_data
        
        return json.dumps(log_entry)

# 配置日志
logger = logging.getLogger(__name__)
handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logger.addHandler(handler)
logger.setLevel(logging.INFO)

# 使用示例
logger.info("用户登录成功", extra={"user_id": "12345", "ip": "192.168.1.1"})
```

#### 3.2 日志轮转配置

```yaml
# Kubernetes日志轮转配置
apiVersion: v1
kind: Pod
metadata:
  name: example-pod
spec:
  containers:
  - name: app
    image: nginx:1.25-alpine
    
    # 日志驱动配置
    env:
    - name: MAX_LOG_SIZE
      value: "10m"
    - name: MAX_LOG_FILES
      value: "3"
    
    # 挂载日志目录
    volumeMounts:
    - name: logs
      mountPath: /var/log/nginx
  
  volumes:
  - name: logs
    emptyDir:
      sizeLimit: 100Mi
```

### 4. 网络配置最佳实践

#### 4.1 网络策略

```yaml
# 网络策略示例
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: production
spec:
  podSelector: {}
  policyTypes:
  - Ingress

---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 8080
```

#### 4.2 Service配置

```yaml
# Service最佳实践配置
apiVersion: v1
kind: Service
metadata:
  name: backend-service
  namespace: production
  labels:
    app: backend
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8080"
    prometheus.io/path: "/metrics"
spec:
  type: ClusterIP
  ports:
  - name: http
    port: 80
    targetPort: 8080
    protocol: TCP
  - name: metrics
    port: 9090
    targetPort: 9090
    protocol: TCP
  selector:
    app: backend
  sessionAffinity: None
```

---

## Kubernetes最佳实践

### 1. 命名空间管理

#### 1.1 命名空间规划

```yaml
# 命名空间规划示例
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    name: production
    environment: production
    team: platform
  annotations:
    description: "生产环境命名空间"
    contact: "platform-team@example.com"
```

#### 1.2 资源配额

```yaml
# 资源配额配置
apiVersion: v1
kind: ResourceQuota
metadata:
  name: production-quota
  namespace: production
spec:
  hard:
    requests.cpu: "20"
    requests.memory: "40Gi"
    limits.cpu: "40"
    limits.memory: "80Gi"
    pods: "50"
    services: "20"
    persistentvolumeclaims: "20"
    configmaps: "50"
    secrets: "50"

---
# 限制范围
apiVersion: v1
kind: LimitRange
metadata:
  name: production-limits
  namespace: production
spec:
  limits:
  - type: Container
    default:
      cpu: "500m"
      memory: "512Mi"
    defaultRequest:
      cpu: "100m"
      memory: "128Mi"
    max:
      cpu: "4"
      memory: "8Gi"
    min:
      cpu: "50m"
      memory: "64Mi"
  - type: Pod
    max:
      cpu: "8"
      memory: "16Gi"
```

### 2. Deployment管理

#### 2.1 Deployment配置最佳实践

```yaml
# Deployment最佳实践配置
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-deployment
  namespace: production
  labels:
    app: backend
    version: v1.2.3
    environment: production
spec:
  replicas: 3
  
  # 更新策略
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  
  # 选择器
  selector:
    matchLabels:
      app: backend
  
  # Pod模板
  template:
    metadata:
      labels:
        app: backend
        version: v1.2.3
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
    spec:
      # 调度配置
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values:
                  - backend
              topologyKey: kubernetes.io/hostname
      
      # 安全上下文
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        fsGroup: 1001
      
      # 容器配置
      containers:
      - name: backend
        image: registry.example.com/backend:v1.2.3
        imagePullPolicy: Always
        
        # 资源限制
        resources:
          requests:
            cpu: "200m"
            memory: "256Mi"
          limits:
            cpu: "1"
            memory: "512Mi"
        
        # 环境变量
        env:
        - name: APP_ENV
          value: "production"
        - name: DB_HOST
          valueFrom:
            configMapKeyRef:
              name: backend-config
              key: db-host
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: backend-secrets
              key: db-password
        
        # 健康检查
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
        
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 15
          periodSeconds: 10
        
        startupProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
          failureThreshold: 30
        
        # 端口配置
        ports:
        - containerPort: 8080
          name: http
          protocol: TCP
        - containerPort: 9090
          name: metrics
          protocol: TCP
        
        # 挂载卷
        volumeMounts:
        - name: config
          mountPath: /app/config
          readOnly: true
        - name: secrets
          mountPath: /app/secrets
          readOnly: true
        - name: tmp
          mountPath: /tmp
      
      # 卷配置
      volumes:
      - name: config
        configMap:
          name: backend-config
      - name: secrets
        secret:
          secretName: backend-secrets
      - name: tmp
        emptyDir: {}
      
      # 终止宽限期
      terminationGracePeriodSeconds: 30
```

#### 2.2 PodDisruptionBudget

```yaml
# PodDisruptionBudget配置
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: backend-pdb
  namespace: production
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: backend
```

### 3. ConfigMap和Secret管理

#### 3.1 ConfigMap最佳实践

```yaml
# ConfigMap配置
apiVersion: v1
kind: ConfigMap
metadata:
  name: backend-config
  namespace: production
  labels:
    app: backend
data:
  # 应用配置
  APP_CONFIG: |
    {
      "debug": false,
      "log_level": "info",
      "max_connections": 100,
      "timeout": 30
    }
  
  # Nginx配置示例
  nginx.conf: |
    server {
        listen 80;
        server_name localhost;
        
        location / {
            root /usr/share/nginx/html;
            index index.html;
        }
        
        location /healthz {
            return 200 'OK';
            add_header Content-Type text/plain;
        }
    }
  
  # 环境配置
  DATABASE_HOST: "db.example.com"
  DATABASE_PORT: "5432"
  REDIS_HOST: "redis.example.com"
  REDIS_PORT: "6379"
```

#### 3.2 Secret最佳实践

```yaml
# Secret配置
apiVersion: v1
kind: Secret
metadata:
  name: backend-secrets
  namespace: production
  labels:
    app: backend
type: Opaque
data:
  # Base64编码的敏感信息
  DB_PASSWORD: cGFzc3dvcmQxMjM=
  API_KEY: YWJjZGVmZzEyMzQ1Ng==
  JWT_SECRET: c2VjcmV0and0a2V5MTIzNDU2

---
# 使用外部密钥管理（推荐）
# 使用CSI Driver挂载外部密钥
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: backend-vault
  namespace: production
spec:
  provider: vault
  parameters:
    vaultAddress: "https://vault.example.com"
    roleName: "backend-role"
    objects: |
      - objectName: "db-password"
        secretPath: "secret/data/backend/db"
        secretKey: "password"
```

### 4. 存储管理

#### 4.1 StorageClass配置

```yaml
# StorageClass配置
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: kubernetes.io/aws-ebs
parameters:
  type: gp3
  fsType: ext4
  encrypted: "true"
reclaimPolicy: Retain
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
mountOptions:
  - noatime
  - nodiratime
```

#### 4.2 PersistentVolumeClaim配置

```yaml
# PersistentVolumeClaim配置
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: backend-data
  namespace: production
  labels:
    app: backend
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: fast-ssd
  resources:
    requests:
      storage: 50Gi
```

### 5. 调度和亲和性

#### 5.1 节点亲和性

```yaml
# 节点亲和性配置
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-deployment
spec:
  replicas: 3
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      affinity:
        # 节点亲和性
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/worker
                operator: In
                values:
                - "true"
          
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
              - key: topology.kubernetes.io/zone
                operator: In
                values:
                - zone-a
        
        # Pod反亲和性
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
              - key: app
                operator: In
                values:
                - backend
            topologyKey: kubernetes.io/hostname
```

#### 5.2 拓扑分布约束

```yaml
# 拓扑分布约束
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-deployment
spec:
  replicas: 6
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: topology.kubernetes.io/zone
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: backend
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: ScheduleAnyway
        labelSelector:
          matchLabels:
            app: backend
```

---

## CI/CD最佳实践

### 1. GitLab CI/CD配置

#### 1.1 完整的GitLab CI/CD配置

```yaml
# .gitlab-ci.yml
stages:
  - build
  - test
  - security
  - package
  - deploy
  - monitor

variables:
  DOCKER_IMAGE: registry.example.com/${CI_PROJECT_NAME}
  K8S_NAMESPACE: production

# 构建阶段
build:
  stage: build
  image: golang:1.21-alpine
  script:
    - go mod download
    - go build -o /build/app .
  artifacts:
    paths:
      - /build/app
    expire_in: 1 hour

# 测试阶段
test:unit:
  stage: test
  image: golang:1.21-alpine
  script:
    - go test -v ./... -coverprofile=coverage.out
    - go tool cover -html=coverage.out -o coverage.html
  artifacts:
    reports:
      coverage_report:
        coverage_format: cobertura
        path: coverage.out
    paths:
      - coverage.html
    expire_in: 1 week

test:integration:
  stage: test
  image: docker:24-dind
  services:
    - docker:24-dind
  script:
    - docker-compose -f docker-compose.test.yml up --build --abort-on-container-exit
  only:
    - main
    - develop

# 安全扫描
security:scan:
  stage: security
  image: aquasec/trivy:latest
  script:
    - trivy image --exit-code 1 --severity HIGH,CRITICAL ${DOCKER_IMAGE}:${CI_COMMIT_SHA}
  only:
    - main
    - develop

security:dependency:
  stage: security
  image: golang:1.21-alpine
  script:
    - go install golang.org/x/vuln/cmd/govulncheck@latest
    - govulncheck ./...
  only:
    - main
    - develop

# 打包阶段
package:build:
  stage: package
  image: docker:24-dind
  services:
    - docker:24-dind
  script:
    - docker build -t ${DOCKER_IMAGE}:${CI_COMMIT_SHA} .
    - docker push ${DOCKER_IMAGE}:${CI_COMMIT_SHA}
    - docker tag ${DOCKER_IMAGE}:${CI_COMMIT_SHA} ${DOCKER_IMAGE}:latest
    - docker push ${DOCKER_IMAGE}:latest
  only:
    - main
    - develop

# 部署阶段
deploy:staging:
  stage: deploy
  image: bitnami/kubectl:latest
  script:
    - kubectl set image deployment/backend backend=${DOCKER_IMAGE}:${CI_COMMIT_SHA} -n staging
    - kubectl rollout status deployment/backend -n staging --timeout=300s
  environment:
    name: staging
    url: https://staging.example.com
  only:
    - develop

deploy:production:
  stage: deploy
  image: bitnami/kubectl:latest
  script:
    - kubectl set image deployment/backend backend=${DOCKER_IMAGE}:${CI_COMMIT_SHA} -n production
    - kubectl rollout status deployment/backend -n production --timeout=300s
  environment:
    name: production
    url: https://example.com
  when: manual
  only:
    - main

# 监控阶段
monitor:health:
  stage: monitor
  image: curlimages/curl:latest
  script:
    - |
      for i in $(seq 1 30); do
        if curl -sf https://example.com/healthz > /dev/null; then
          echo "Health check passed"
          exit 0
        fi
        echo "Attempt $i failed, retrying in 10s..."
        sleep 10
      done
      echo "Health check failed after 30 attempts"
      exit 1
  only:
    - main
    - develop
```

### 2. GitHub Actions配置

#### 2.1 完整的GitHub Actions配置

```yaml
# .github/workflows/ci-cd.yml
name: CI/CD Pipeline

on:
  push:
    branches: [ main, develop ]
  pull_request:
    branches: [ main ]

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    
    steps:
    - name: Checkout repository
      uses: actions/checkout@v4
    
    - name: Set up Go
      uses: actions/setup-go@v4
      with:
        go-version: '1.21'
    
    - name: Build
      run: go build -o ./build/app .
    
    - name: Test
      run: go test -v ./... -coverprofile=coverage.out
    
    - name: Upload coverage
      uses: actions/upload-artifact@v3
      with:
        name: coverage
        path: coverage.out

  security:
    runs-on: ubuntu-latest
    needs: build
    
    steps:
    - name: Checkout repository
      uses: actions/checkout@v4
    
    - name: Run Trivy vulnerability scanner
      uses: aquasecurity/trivy-action@master
      with:
        image-ref: '${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.sha }}'
        format: 'sarif'
        output: 'trivy-results.sarif'
        severity: 'CRITICAL,HIGH'

  package:
    runs-on: ubuntu-latest
    needs: [build, security]
    if: github.event_name != 'pull_request'
    
    steps:
    - name: Checkout repository
      uses: actions/checkout@v4
    
    - name: Log in to the Container registry
      uses: docker/login-action@v3
      with:
        registry: ${{ env.REGISTRY }}
        username: ${{ github.actor }}
        password: ${{ secrets.GITHUB_TOKEN }}
    
    - name: Extract metadata (tags, labels) for Docker
      id: meta
      uses: docker/metadata-action@v5
      with:
        images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
        tags: |
          type=sha
          type=ref,event=branch
          type=semver,pattern={{version}}
    
    - name: Build and push Docker image
      uses: docker/build-push-action@v5
      with:
        context: .
        push: true
        tags: ${{ steps.meta.outputs.tags }}
        labels: ${{ steps.meta.outputs.labels }}

  deploy:
    runs-on: ubuntu-latest
    needs: package
    if: github.ref == 'refs/heads/main'
    
    steps:
    - name: Deploy to production
      uses: azure/k8s-deploy@v4
      with:
        namespace: production
        manifests: k8s/
        images: |
          ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.sha }}
        strategy: canary
        percentage: 10
```

### 3. Docker最佳实践

#### 3.1 多阶段构建优化

```dockerfile
# 优化的多阶段构建
# 阶段1: 依赖缓存
FROM golang:1.21-alpine AS deps
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download && go mod verify

# 阶段2: 构建
FROM deps AS builder
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-w -s" -o /app/main .

# 阶段3: 运行
FROM gcr.io/distroless/static-debian12
COPY --from=builder /app/main /app/main
EXPOSE 8080
ENTRYPOINT ["/app/main"]
```

#### 3.2 安全最佳实践

```dockerfile
# 安全的Dockerfile
FROM node:18-alpine AS builder

# 安装安全更新
RUN apk update && apk upgrade && apk add --no-cache dumb-init

# 创建非root用户
RUN addgroup -g 1001 -S appgroup && \
    adduser -u 1001 -S appuser -G appgroup

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --only=production

COPY . .
RUN npm run build

FROM node:18-alpine

# 安装安全更新
RUN apk update && apk upgrade

# 复制应用
WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./

# 使用非root用户
USER appuser

# 暴露端口
EXPOSE 3000

# 启动命令
ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "dist/server.js"]
```

---

## 监控最佳实践

### 1. Prometheus配置

#### 1.1 Prometheus配置最佳实践

```yaml
# prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  scrape_timeout: 10s

# 告警规则文件
rule_files:
  - "rules/*.yml"

# 告警管理器配置
alerting:
  alertmanagers:
    - static_configs:
        - targets:
          - alertmanager:9093

# 采集配置
scrape_configs:
  # Prometheus自身监控
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  # Kubernetes API Server
  - job_name: 'kubernetes-apiservers'
    kubernetes_sd_configs:
      - role: endpoints
    scheme: https
    tls_config:
      ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
    relabel_configs:
      - source_labels: [__meta_kubernetes_namespace, __meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
        action: keep
        regex: default;kubernetes;https

  # Kubernetes节点
  - job_name: 'kubernetes-nodes'
    scheme: https
    tls_config:
      ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
    kubernetes_sd_configs:
      - role: node
    relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
      - target_label: __address__
        replacement: kubernetes.default.svc:443
      - source_labels: [__meta_kubernetes_node_name]
        regex: (.+)
        target_label: __metrics_path__
        replacement: /api/v1/nodes/${1}/proxy/metrics

  # Kubernetes Pods
  - job_name: 'kubernetes-pods'
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: true
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: pod
```

#### 1.2 告警规则最佳实践

```yaml
# rules/infrastructure.yml
groups:
  - name: infrastructure
    rules:
      # 节点CPU使用率告警
      - alert: HighNodeCPUUsage
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "节点CPU使用率过高"
          description: "节点 {{ $labels.instance }} CPU使用率超过80%，当前值为 {{ $value }}%"

      # 节点内存使用率告警
      - alert: HighNodeMemoryUsage
        expr: 100 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100) > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "节点内存使用率过高"
          description: "节点 {{ $labels.instance }} 内存使用率超过85%，当前值为 {{ $value }}%"

      # 节点磁盘使用率告警
      - alert: HighNodeDiskUsage
        expr: 100 - (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"} * 100) > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "节点磁盘使用率过高"
          description: "节点 {{ $labels.instance }} 磁盘使用率超过85%，当前值为 {{ $value }}%"

  - name: application
    rules:
      # Pod重启次数告警
      - alert: PodRestartCount
        expr: increase(kube_pod_container_status_restarts_total[1h]) > 5
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Pod重启次数过多"
          description: "Pod {{ $labels.pod }} 在过去1小时内重启了 {{ $value }} 次"

      # Pod内存使用率告警
      - alert: PodHighMemoryUsage
        expr: container_memory_working_set_bytes{container!="POD",container!=""} / container_spec_memory_limit_bytes{container!="POD",container!=""} > 0.8
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Pod内存使用率过高"
          description: "Pod {{ $labels.pod }} 内存使用率超过80%，当前值为 {{ $value }}%"

      # Pod CPU使用率告警
      - alert: PodHighCPUUsage
        expr: rate(container_cpu_usage_seconds_total{container!="POD",container!=""}[5m]) / container_spec_cpu_quota{container!="POD",container!=""} * 100000 > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Pod CPU使用率过高"
          description: "Pod {{ $labels.pod }} CPU使用率超过80%，当前值为 {{ $value }}%"
```

### 2. Grafana仪表板

#### 2.1 Kubernetes集群监控仪表板

```json
{
  "dashboard": {
    "title": "Kubernetes Cluster Monitoring",
    "tags": ["kubernetes", "cluster"],
    "timezone": "browser",
    "panels": [
      {
        "title": "节点CPU使用率",
        "type": "graph",
        "targets": [
          {
            "expr": "100 - (avg by(instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)",
            "legendFormat": "{{ instance }}"
          }
        ],
        "thresholds": [
          {
            "value": 80,
            "color": "red",
            "op": "gt"
          }
        ]
      },
      {
        "title": "节点内存使用率",
        "type": "graph",
        "targets": [
          {
            "expr": "100 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100)",
            "legendFormat": "{{ instance }}"
          }
        ]
      },
      {
        "title": "Pod状态",
        "type": "stat",
        "targets": [
          {
            "expr": "count(kube_pod_status_phase{phase=\"Running\"})",
            "legendFormat": "Running"
          },
          {
            "expr": "count(kube_pod_status_phase{phase=\"Pending\"})",
            "legendFormat": "Pending"
          },
          {
            "expr": "count(kube_pod_status_phase{phase=\"Failed\"})",
            "legendFormat": "Failed"
          }
        ]
      }
    ]
  }
}
```

### 3. 日志监控

#### 3.1 日志收集配置

```yaml
# Fluentd配置示例
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluentd-config
  namespace: logging
data:
  fluent.conf: |
    # 输入配置
    <source>
      @type tail
      @id in_tail_container_logs
      path /var/log/containers/*.log
      pos_file /var/log/fluentd-containers.log.pos
      tag kubernetes.*
      read_from_head true
      <parse>
        @type json
        time_key time
        time_format %Y-%m-%dT%H:%M:%S.%NZ
      </parse>
    </source>

    # 过滤配置
    <filter kubernetes.**>
      @type kubernetes_metadata
      @id filter_kube_metadata
      kubernetes_url "https://#{ENV['KUBERNETES_SERVICE_HOST']}:#{ENV['KUBERNETES_SERVICE_PORT']}"
      verify_ssl true
      ca_file /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
      bearer_token_file /var/run/secrets/kubernetes.io/serviceaccount/token
      skip_labels false
      skip_container_metadata false
      skip_namespace_metadata true
      skip_master_url true
    </filter>

    # 输出配置
    <match kubernetes.**>
      @type elasticsearch
      @id out_es
      @log_level info
      include_tag_key true
      host elasticsearch.logging.svc.cluster.local
      port 9200
      logstash_format true
      logstash_prefix kubernetes
      logstash_dateformat %Y.%m.%d
      reload_connections false
      reconnect_on_error true
      reload_on_failure true
      <buffer>
        @type file
        path /var/log/fluentd-buffers/kubernetes.system.buffer
        flush_mode interval
        flush_thread_count 2
        flush_interval 5s
        retry_type exponential_backoff
        retry_forever true
        retry_max_interval 30
        chunk_limit_size 2M
        queue_limit_length 8
        overflow_action block
      </buffer>
    </match>
```

---

## 安全最佳实践

### 1. RBAC配置

#### 1.1 最小权限原则

```yaml
# RBAC最佳实践
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: developer-role
  namespace: development
rules:
- apiGroups: ["", "apps", "batch"]
  resources: ["pods", "pods/log", "services", "deployments", "jobs"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["configmaps", "secrets"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["get", "list", "watch"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: developer-binding
  namespace: development
subjects:
- kind: User
  name: developer@example.com
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: developer-role
  apiGroup: rbac.authorization.k8s.io
```

### 2. 网络安全

#### 2.1 网络策略最佳实践

```yaml
# 默认拒绝所有入站流量
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: production
spec:
  podSelector: {}
  policyTypes:
  - Ingress

---
# 允许前端访问后端
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 8080

---
# 允许后端访问数据库
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-backend-to-database
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: database
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: backend
    ports:
    - protocol: TCP
      port: 5432
```

### 3. 镜像安全

#### 3.1 镜像签名和验证

```yaml
# 使用Cosign签名镜像
# 签名命令
# cosign sign --key cosign.key registry.example.com/backend:v1.2.3

# 验证命令
# cosign verify --key cosign.pub registry.example.com/backend:v1.2.3

# Kubernetes验证策略
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: image-verification
webhooks:
- name: image-verification.example.com
  clientConfig:
    service:
      namespace: kube-system
      name: image-verification
      path: /verify
  rules:
  - operations: ["CREATE", "UPDATE"]
    apiGroups: [""]
    apiVersions: ["v1"]
    resources: ["pods"]
  failurePolicy: Fail
  sideEffects: None
```

---

## 成本优化最佳实践

### 1. 资源优化

#### 1.1 资源请求和限制

```yaml
# 资源优化配置
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-deployment
spec:
  replicas: 3
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      containers:
      - name: backend
        image: registry.example.com/backend:v1.2.3
        
        # 根据实际使用情况设置资源
        resources:
          requests:
            cpu: "100m"      # 请求较少资源，提高调度成功率
            memory: "128Mi"
          limits:
            cpu: "500m"      # 设置合理的上限，避免资源浪费
            memory: "256Mi"
        
        # 使用垂直Pod自动扩缩器
        # 需要安装VPA组件
```

#### 1.2 自动扩缩配置

```yaml
# 水平Pod自动扩缩器
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: backend-hpa
  namespace: production
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: backend-deployment
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
      - type: Percent
        value: 100
        periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 10
        periodSeconds: 60

---
# 集群自动扩缩器
apiVersion: autoscaling.k8s.io/v1
kind: ClusterAutoscaler
metadata:
  name: cluster-autoscaler
  namespace: kube-system
spec:
  scaleDownDelayAfterAdd: 10m
  scaleDownUnneededTime: 10m
  scaleDownUtilizationThreshold: 0.5
  skipNodesWithLocalStorage: false
  skipNodesWithSystemPods: false
```

### 2. 存储优化

#### 2.1 存储类选择

```yaml
# 根据性能需求选择存储类
# 高性能存储（SSD）
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: kubernetes.io/aws-ebs
parameters:
  type: gp3
  fsType: ext4
reclaimPolicy: Retain
allowVolumeExpansion: true

---
# 标准存储（HDD）
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: standard
provisioner: kubernetes.io/aws-ebs
parameters:
  type: gp2
  fsType: ext4
reclaimPolicy: Delete
allowVolumeExpansion: true

---
# 归档存储（低成本）
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: archive
provisioner: kubernetes.io/aws-ebs
parameters:
  type: sc1
  fsType: ext4
reclaimPolicy: Delete
allowVolumeExpansion: true
```

### 3. 网络优化

#### 3.1 网络策略优化

```yaml
# 网络策略优化
# 减少不必要的网络策略
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: production
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector: {}
```

---

## 总结

### 关键要点

1. **容器最佳实践**
   - 使用多阶段构建减小镜像体积
   - 使用最小化基础镜像（alpine、distroless）
   - 配置资源限制和健康检查
   - 使用非root用户运行容器
   - 实施结构化日志

2. **Kubernetes最佳实践**
   - 使用命名空间隔离环境
   - 配置资源配额和限制范围
   - 使用PodDisruptionBudget保证可用性
   - 配置适当的调度策略
   - 使用ConfigMap和Secret管理配置

3. **CI/CD最佳实践**
   - 实施完整的CI/CD流水线
   - 集成安全扫描
   - 使用自动化测试
   - 实施蓝绿或金丝雀部署
   - 配置监控和告警

4. **监控最佳实践**
   - 实施全面的监控覆盖
   - 配置适当的告警规则
   - 使用Grafana创建可视化仪表板
   - 实施日志收集和分析
   - 定期审查监控配置

5. **安全最佳实践**
   - 实施最小权限原则
   - 配置网络策略
   - 使用镜像签名和验证
   - 定期进行安全扫描
   - 实施审计日志

6. **成本优化最佳实践**
   - 根据实际使用设置资源请求
   - 使用自动扩缩器
   - 选择合适的存储类型
   - 优化网络配置
   - 定期审查资源使用情况

通过遵循这些最佳实践，可以构建一个安全、高效、可扩展的企业级云原生运维平台。
