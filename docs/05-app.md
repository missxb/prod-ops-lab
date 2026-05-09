# 阶段5：应用部署详细文档

## 目录

1. [概述](#概述)
2. [Deployment 配置详解](#1-deployment-配置详解)
3. [Service 配置详解](#2-service-配置详解)
4. [Ingress 配置详解](#3-ingress-配置详解)
5. [HPA 自动扩缩容](#4-hpa-自动扩缩容)
6. [ConfigMap 与 Secret 管理](#5-configmap-与-secret-管理)
7. [滚动更新策略](#6-滚动更新策略)
8. [故障转移测试](#7-故障转移测试)
9. [生产最佳实践](#8-生产最佳实践)

---

## 概述

本阶段详细介绍 Kubernetes 应用部署的各个方面，包括工作负载管理、网络配置、自动扩缩容、配置管理等核心内容。

### 部署架构

```
用户请求
    ↓
Ingress Controller (Nginx)
    ↓
Service (ClusterIP / NodePort)
    ↓
Pod (Deployment / StatefulSet)
    ↓
Container (Application + Sidecar)
```

### 命名空间规划

| 命名空间 | 用途 | 说明 |
|----------|------|------|
| production | 生产环境 | 核心业务应用 |
| staging | 预发布环境 | 上线前验证 |
| development | 开发环境 | 开发测试 |
| monitoring | 监控系统 | Prometheus/Grafana |
| logging | 日志系统 | ELK Stack |
| kube-system | K8s 系统组件 | CoreDNS, Ingress等 |

---

## 1. Deployment 配置详解

### 1.1 基础 Deployment

```yaml
# k8s/production/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
  namespace: production
  labels:
    app: web-app
    team: backend
    environment: production
  annotations:
    # 部署说明
    deployment.kubernetes.io/revision: "1"
    kubernetes.io/change-cause: "初始部署 v1.0.0"
spec:
  # 副本数量
  replicas: 3
  
  # 保留的历史版本数（用于回滚）
  revisionHistoryLimit: 10
  
  # 选择器（必须与 template.labels 匹配）
  selector:
    matchLabels:
      app: web-app
  
  # 更新策略
  strategy:
    type: RollingUpdate
    rollingUpdate:
      # 最大超出数量
      maxSurge: 1
      # 最大不可用数量
      maxUnavailable: 0
  
  # Pod 模板
  template:
    metadata:
      labels:
        app: web-app
        version: v1.0.0
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
    spec:
      # 启动容忍（如果需要调度到特定节点）
      tolerations:
      - key: "dedicated"
        operator: "Equal"
        value: "web"
        effect: "NoSchedule"
      
      # 节点亲和性
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
                  - web-app
              topologyKey: kubernetes.io/hostname
      
      # 安全上下文
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      
      # 初始化容器
      initContainers:
      - name: wait-for-db
        image: busybox:1.36
        command: ['sh', '-c', 'until nc -z postgres-service 5432; do echo waiting for db; sleep 2; done']
      
      # 主容器
      containers:
      - name: web-app
        image: harbor.example.com/production/web-app:v1.0.0
        imagePullPolicy: Always
        
        # 端口
        ports:
        - name: http
          containerPort: 8080
          protocol: TCP
        
        # 资源限制
        resources:
          requests:
            cpu: 250m
            memory: 256Mi
          limits:
            cpu: 1000m
            memory: 512Mi
        
        # 存活探针
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 15
          periodSeconds: 20
          timeoutSeconds: 5
          failureThreshold: 3
          successThreshold: 1
        
        # 就绪探针
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
          timeoutSeconds: 3
          failureThreshold: 3
          successThreshold: 1
        
        # 启动探针（慢启动应用）
        startupProbe:
          httpGet:
            path: /health
            port: 8080
          failureThreshold: 30
          periodSeconds: 10
        
        # 环境变量
        env:
        - name: APP_ENV
          value: "production"
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: web-app-secrets
              key: database-url
        - name: REDIS_URL
          valueFrom:
            configMapKeyRef:
              name: web-app-config
              key: redis-url
        
        # 环境变量文件
        envFrom:
        - configMapRef:
            name: web-app-env
        - secretRef:
            name: web-app-secrets
        
        # 卷挂载
        volumeMounts:
        - name: config-volume
          mountPath: /app/config
          readOnly: true
        - name: data-volume
          mountPath: /app/data
        - name: tmp-volume
          mountPath: /tmp
        
        # 容器安全上下文
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
            - ALL
        
        # 生命周期钩子
        lifecycle:
          preStop:
            exec:
              command: ["/bin/sh", "-c", "sleep 15"]
      
      # 卷定义
      volumes:
      - name: config-volume
        configMap:
          name: web-app-config
      - name: data-volume
        persistentVolumeClaim:
          claimName: web-app-data
      - name: tmp-volume
        emptyDir:
          sizeLimit: 100Mi
      
      # 镜像拉取密钥
      imagePullSecrets:
      - name: harbor-registry-secret
      
      # 终止宽限期
      terminationGracePeriodSeconds: 30
```

### 1.2 多容器 Pod（Sidecar 模式）

```yaml
# k8s/production/sidecar-pod.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app-with-sidecar
  namespace: production
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web-app-with-sidecar
  template:
    metadata:
      labels:
        app: web-app-with-sidecar
    spec:
      containers:
      # 主容器：应用
      - name: app
        image: harbor.example.com/production/web-app:v1.0.0
        ports:
        - containerPort: 8080
        
      # Sidecar：日志收集
      - name: log-collector
        image: fluentd:v1.16
        volumeMounts:
        - name: app-logs
          mountPath: /var/log/app
        - name: fluentd-config
          mountPath: /fluentd/etc
        
      # Sidecar：Prometheus Exporter
      - name: exporter
        image: prom/statsd-exporter:latest
        ports:
        - containerPort: 9102
        args:
        - '--web.listen-address=:9102'
        - '--statsd.mapping-config=/etc/statsd-exporter.yml'
      
      # Sidecar：链路追踪 Agent
      - name: tracer
        image: jaegertracing/jaeger-agent:latest
        ports:
        - containerPort: 5775
          protocol: UDP
        - containerPort: 6831
          protocol: UDP
        args:
        - '--reporter.grpc.host-port=jaeger-collector:14250'
      
      volumes:
      - name: app-logs
        emptyDir: {}
      - name: fluentd-config
        configMap:
          name: fluentd-config
```

### 1.3 DaemonSet 配置

```yaml
# k8s/monitoring/node-exporter.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
  namespace: monitoring
  labels:
    app: node-exporter
spec:
  selector:
    matchLabels:
      app: node-exporter
  template:
    metadata:
      labels:
        app: node-exporter
    spec:
      hostNetwork: true
      hostPID: true
      containers:
      - name: node-exporter
        image: prom/node-exporter:v1.7.0
        args:
        - '--path.procfs=/host/proc'
        - '--path.sysfs=/host/sys'
        - '--path.rootfs=/host/root'
        - '--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|var/lib/docker/.+)($|/)'
        ports:
        - containerPort: 9100
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
        volumeMounts:
        - name: proc
          mountPath: /host/proc
          readOnly: true
        - name: sys
          mountPath: /host/sys
          readOnly: true
        - name: root
          mountPath: /host/root
          readOnly: true
          mountPropagation: HostToContainer
      volumes:
      - name: proc
        hostPath:
          path: /proc
      - name: sys
        hostPath:
          path: /sys
      - name: root
        hostPath:
          path: /
```

### 1.4 StatefulSet 配置

```yaml
# k8s/database/postgresql-statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgresql
  namespace: production
spec:
  serviceName: postgresql
  replicas: 3
  selector:
    matchLabels:
      app: postgresql
  template:
    metadata:
      labels:
        app: postgresql
    spec:
      containers:
      - name: postgresql
        image: postgres:16-alpine
        ports:
        - containerPort: 5432
          name: postgres
        env:
        - name: POSTGRES_DB
          value: "myapp"
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef:
              name: postgresql-secrets
              key: username
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgresql-secrets
              key: password
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        resources:
          requests:
            cpu: 500m
            memory: 1Gi
          limits:
            cpu: 2000m
            memory: 4Gi
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
        - name: config
          mountPath: /etc/postgresql/postgresql.conf
          subPath: postgresql.conf
      volumes:
      - name: config
        configMap:
          name: postgresql-config
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: fast-ssd
      resources:
        requests:
          storage: 50Gi
```

---

## 2. Service 配置详解

### 2.1 ClusterIP Service

```yaml
# k8s/production/service-clusterip.yaml
apiVersion: v1
kind: Service
metadata:
  name: web-app
  namespace: production
  labels:
    app: web-app
  annotations:
    # Prometheus 服务发现
    prometheus.io/scrape: "true"
    prometheus.io/port: "8080"
spec:
  type: ClusterIP
  selector:
    app: web-app
  ports:
  - name: http
    port: 80
    targetPort: 8080
    protocol: TCP
  - name: metrics
    port: 9090
    targetPort: 9090
    protocol: TCP
  # 会话亲和性（可选）
  # sessionAffinity: ClientIP
  # sessionAffinityConfig:
  #   clientIP:
  #     timeoutSeconds: 10800
```

### 2.2 NodePort Service

```yaml
# k8s/production/service-nodeport.yaml
apiVersion: v1
kind: Service
metadata:
  name: web-app-nodeport
  namespace: production
spec:
  type: NodePort
  selector:
    app: web-app
  ports:
  - name: http
    port: 80
    targetPort: 8080
    nodePort: 30080
    protocol: TCP
```

### 2.3 LoadBalancer Service

```yaml
# k8s/production/service-loadbalancer.yaml
apiVersion: v1
kind: Service
metadata:
  name: web-app-lb
  namespace: production
  annotations:
    # AWS NLB 配置
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
    service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
    # Azure 配置
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
spec:
  type: LoadBalancer
  selector:
    app: web-app
  ports:
  - name: https
    port: 443
    targetPort: 8080
    protocol: TCP
  externalTrafficPolicy: Local  # 保留源 IP
```

### 2.4 Headless Service（用于 StatefulSet）

```yaml
# k8s/database/service-headless.yaml
apiVersion: v1
kind: Service
metadata:
  name: postgresql
  namespace: production
spec:
  clusterIP: None  # Headless
  selector:
    app: postgresql
  ports:
  - name: postgres
    port: 5432
    targetPort: 5432
```

---

## 3. Ingress 配置详解

### 3.1 Nginx Ingress Controller 安装

```bash
# 安装 Nginx Ingress Controller
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.replicaCount=2 \
  --set controller.resources.requests.cpu=200m \
  --set controller.resources.requests.memory=256Mi \
  --set controller.resources.limits.cpu=1000m \
  --set controller.resources.limits.memory=1Gi \
  --set controller.metrics.enabled=true \
  --set controller.config.use-forwarded-headers="true" \
  --set controller.config.enable-real-ip="true" \
  --set controller.config.ssl-protocols="TLSv1.2 TLSv1.3" \
  --set controller.config.ssl-ciphers="ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256"
```

### 3.2 基础 Ingress 配置

```yaml
# k8s/production/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-app-ingress
  namespace: production
  labels:
    app: web-app
  annotations:
    # Ingress 类型
    kubernetes.io/ingress.class: nginx
    
    # TLS 配置
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    
    # 限流
    nginx.ingress.kubernetes.io/limit-rps: "100"
    nginx.ingress.kubernetes.io/limit-connections: "50"
    
    # 超时配置
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "60"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "60"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "60"
    
    # 缓冲配置
    nginx.ingress.kubernetes.io/proxy-buffer-size: "16k"
    nginx.ingress.kubernetes.io/proxy-buffers-number: "4"
    
    # 负载均衡算法
    nginx.ingress.kubernetes.io/upstream-hash-by: "$request_uri"
    
    # CORS 配置
    nginx.ingress.kubernetes.io/enable-cors: "true"
    nginx.ingress.kubernetes.io/cors-allow-origin: "https://app.example.com"
    nginx.ingress.kubernetes.io/cors-allow-methods: "GET, POST, PUT, DELETE, OPTIONS"
    
    # 安全头
    nginx.ingress.kubernetes.io/configuration-snippet: |
      more_set_headers "X-Frame-Options: DENY";
      more_set_headers "X-Content-Type-Options: nosniff";
      more_set_headers "X-XSS-Protection: 1; mode=block";
      more_set_headers "Strict-Transport-Security: max-age=31536000; includeSubDomains";
    
    # 证书管理
    cert-manager.io/cluster-issuer: letsencrypt-prod

spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - app.example.com
    - api.example.com
    secretName: app-tls-secret
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-app
            port:
              number: 80
  - host: api.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: api-app
            port:
              number: 80
      - path: /v1
        pathType: Prefix
        backend:
          service:
            name: api-v1
            port:
              number: 80
      - path: /v2
        pathType: Prefix
        backend:
          service:
            name: api-v2
            port:
              number: 80
```

### 3.3 金丝雀发布 Ingress

```yaml
# k8s/production/ingress-canary.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-app-canary
  namespace: production
  annotations:
    nginx.ingress.kubernetes.io/canary: "true"
    nginx.ingress.kubernetes.io/canary-weight: "10"  # 10% 流量到金丝雀
    # 或基于 Header
    # nginx.ingress.kubernetes.io/canary-by-header: "X-Canary"
    # nginx.ingress.kubernetes.io/canary-by-header-value: "always"
spec:
  ingressClassName: nginx
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-app-canary
            port:
              number: 80
```

### 3.4 Ingress 流量拆分

```yaml
# k8s/production/ingress-traffic-split.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-app-traffic-split
  namespace: production
  annotations:
    nginx.ingress.kubernetes.io/canary: "true"
    # 基于 Header 路由
    nginx.ingress.kubernetes.io/canary-by-header: "X-Routing"
    nginx.ingress.kubernetes.io/canary-by-header-pattern: "beta-.*"
    # 基于 Cookie 路由
    nginx.ingress.kubernetes.io/canary-by-cookie: "canary_cookie"
spec:
  ingressClassName: nginx
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-app-beta
            port:
              number: 80
```

---

## 4. HPA 自动扩缩容

### 4.1 基于 CPU/Memory 的 HPA

```yaml
# k8s/production/hpa-cpu.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web-app-hpa
  namespace: production
  labels:
    app: web-app
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web-app
  minReplicas: 3
  maxReplicas: 20
  
  # 扩缩容行为配置
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
      - type: Percent
        value: 100
        periodSeconds: 60
      - type: Pods
        value: 4
        periodSeconds: 60
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 10
        periodSeconds: 120
      - type: Pods
        value: 2
        periodSeconds: 120
      selectPolicy: Min
  
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
```

### 4.2 基于自定义指标的 HPA

```yaml
# k8s/production/hpa-custom-metrics.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web-app-hpa-custom
  namespace: production
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web-app
  minReplicas: 3
  maxReplicas: 50
  metrics:
  # 基于请求数
  - type: Pods
    pods:
      metric:
        name: http_requests_per_second
      target:
        type: AverageValue
        averageValue: "1000"
  
  # 基于队列长度
  - type: Pods
    pods:
      metric:
        name: queue_length
      target:
        type: AverageValue
        averageValue: "50"
  
  # 基于外部指标（如 SQS 队列）
  - type: External
    external:
      metric:
        name: sqs_queue_length
        selector:
          matchLabels:
            queue: "web-app-queue"
      target:
        type: AverageValue
        averageValue: "100"
```

### 4.3 Pod Disruption Budget

```yaml
# k8s/production/pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-app-pdb
  namespace: production
spec:
  minAvailable: 2  # 或使用 maxUnavailable: 1
  selector:
    matchLabels:
      app: web-app
```

### 4.4 Vertical Pod Autoscaler

```yaml
# k8s/production/vpa.yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: web-app-vpa
  namespace: production
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web-app
  updatePolicy:
    updateMode: "Auto"  # Off, Initial, Recreate, Auto
  resourcePolicy:
    containerPolicies:
    - containerName: web-app
      minAllowed:
        cpu: 100m
        memory: 128Mi
      maxAllowed:
        cpu: 2000m
        memory: 2Gi
      controlledResources: ["cpu", "memory"]
```

### 4.5 KEDA（事件驱动扩缩容）

```yaml
# k8s/production/keda-scaledobject.yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: web-app-keda
  namespace: production
spec:
  scaleTargetRef:
    name: web-app
  pollingInterval: 15
  cooldownPeriod: 300
  minReplicaCount: 3
  maxReplicaCount: 50
  triggers:
  - type: prometheus
    metadata:
      serverAddress: http://prometheus.monitoring:9090
      metricName: http_requests_total
      query: |
        sum(rate(http_requests_total{app="web-app"}[5m]))
      threshold: "1000"
      activationThreshold: "100"
  
  - type: kafka
    metadata:
      bootstrapServers: kafka:9092
      consumerGroup: web-app-consumer
      topic: requests
      lagThreshold: "50"
  
  - type: rabbitmq
    metadata:
      host: rabbitmq.default.svc
      queueName: web-app-queue
      queueLength: "50"
```

---

## 5. ConfigMap 与 Secret 管理

### 5.1 ConfigMap 配置

```yaml
# k8s/production/configmap-app-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: web-app-config
  namespace: production
  labels:
    app: web-app
data:
  # 应用配置文件
  application.yaml: |
    server:
      port: 8080
      shutdown: graceful
    spring:
      datasource:
        url: jdbc:postgresql://postgresql:5432/myapp
        hikari:
          maximum-pool-size: 20
          minimum-idle: 5
          idle-timeout: 300000
          max-lifetime: 1200000
      redis:
        host: redis
        port: 6379
      jackson:
        default-property-inclusion: non-null
    logging:
      level:
        root: INFO
        com.example: DEBUG
      pattern:
        console: "%d{yyyy-MM-dd HH:mm:ss} [%thread] %-5level %logger{36} - %msg%n"
    management:
      endpoints:
        web:
          exposure:
            include: health,info,metrics,prometheus
      endpoint:
        health:
          show-details: always
    metrics:
      export:
        prometheus:
          enabled: true
  
  # 环境变量配置
  redis-url: "redis://redis:6379/0"
  
  # Nginx 配置
  nginx.conf: |
    upstream backend {
        least_conn;
        server localhost:8080 weight=5;
        server localhost:8081 weight=3;
    }
    
    server {
        listen 80;
        server_name app.example.com;
        
        location / {
            proxy_pass http://backend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
```

### 5.2 Secret 配置

```bash
# 创建 Secret
kubectl create secret generic web-app-secrets \
  --namespace production \
  --from-literal=database-url='postgresql://user:password@postgresql:5432/myapp' \
  --from-literal=redis-url='redis://:password@redis:6379/0' \
  --from-literal=api-key='your-api-key' \
  --from-literal=jwt-secret='your-jwt-secret'
```

```yaml
# k8s/production/secret-tls.yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-tls-secret
  namespace: production
type: kubernetes.io/tls
data:
  tls.crt: <base64-encoded-cert>
  tls.key: <base64-encoded-key>

---
# k8s/production/secret-docker-registry.yaml
apiVersion: v1
kind: Secret
metadata:
  name: harbor-registry-secret
  namespace: production
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: <base64-encoded-docker-config>
```

### 5.3 External Secrets Operator

```yaml
# k8s/production/externalsecret.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: web-app-external-secrets
  namespace: production
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: web-app-secrets
    creationPolicy: Owner
  data:
  - secretKey: database-url
    remoteRef:
      key: production/web-app/database-url
  - secretKey: api-key
    remoteRef:
      key: production/web-app/api-key

---
# SecretStore 配置
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: production
spec:
  provider:
    vault:
      server: "http://vault:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "web-app"
          serviceAccountRef:
            name: external-secrets
```

### 5.4 Sealed Secrets

```bash
# 安装 Sealed Secrets Controller
helm install sealed-secrets bitnami/sealed-secrets \
  --namespace kube-system

# 创建 Sealed Secret
echo -n 'my-secret-value' | kubectl create secret generic my-secret \
  --dry-run=client --from-file=password=/dev/stdin -o yaml | \
  kubeseal --format yaml > sealed-secret.yaml

# 应用 Sealed Secret
kubectl apply -f sealed-secret.yaml
```

---

## 6. 滚动更新策略

### 6.1 滚动更新配置

```yaml
# k8s/production/deployment-strategy.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
  namespace: production
spec:
  replicas: 5
  strategy:
    # 滚动更新策略
    type: RollingUpdate
    rollingUpdate:
      # 一次最多创建的 Pod 数量超出期望值
      maxSurge: 2
      # 一次最多终止的 Pod 数量
      maxUnavailable: 0
  template:
    spec:
      containers:
      - name: web-app
        image: harbor.example.com/production/web-app:v2.0.0
        # 优雅终止
        lifecycle:
          preStop:
            exec:
              command: ["/bin/sh", "-c", "sleep 15"]
      terminationGracePeriodSeconds: 60
```

### 6.2 蓝绿部署

```yaml
# k8s/production/blue-green/blue-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app-blue
  namespace: production
  labels:
    app: web-app
    slot: blue
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web-app
      slot: blue
  template:
    metadata:
      labels:
        app: web-app
        slot: blue
        version: v1.0.0
    spec:
      containers:
      - name: web-app
        image: harbor.example.com/production/web-app:v1.0.0

---
# k8s/production/blue-green/green-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app-green
  namespace: production
  labels:
    app: web-app
    slot: green
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web-app
      slot: green
  template:
    metadata:
      labels:
        app: web-app
        slot: green
        version: v2.0.0
    spec:
      containers:
      - name: web-app
        image: harbor.example.com/production/web-app:v2.0.0

---
# 切换 Service 到新版本
# k8s/production/blue-green/service-switch.yaml
apiVersion: v1
kind: Service
metadata:
  name: web-app
  namespace: production
spec:
  type: ClusterIP
  selector:
    app: web-app
    slot: green  # 从 blue 切换到 green
  ports:
  - port: 80
    targetPort: 8080
```

```bash
#!/bin/bash
# scripts/blue-green-switch.sh - 蓝绿切换脚本
set -euo pipefail

NAMESPACE="production"
SERVICE="web-app"
OLD_SLOT="blue"
NEW_SLOT="green"

echo "=========================================="
echo "  蓝绿部署切换"
echo "  从 ${OLD_SLOT} 切换到 ${NEW_SLOT}"
echo "=========================================="

# 验证新版本 Pod 就绪
echo "检查新版本 Pod 状态..."
kubectl get pods -n ${NAMESPACE} -l app=${SERVICE},slot=${NEW_SLOT}

READY=$(kubectl get pods -n ${NAMESPACE} -l app=${SERVICE},slot=${NEW_SLOT} \
  -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | \
  grep -c "True")

TOTAL=$(kubectl get pods -n ${NAMESPACE} -l app=${SERVICE},slot=${NEW_SLOT} --no-headers | wc -l)

if [ "${READY}" -ne "${TOTAL}" ]; then
    echo "错误: 新版本 Pod 未全部就绪 (${READY}/${TOTAL})"
    exit 1
fi

# 切换 Service
echo "切换 Service 到 ${NEW_SLOT}..."
kubectl patch service ${SERVICE} -n ${NAMESPACE} \
  -p "{\"spec\":{\"selector\":{\"slot\":\"${NEW_SLOT}\"}}}"

echo "切换完成！当前流量路由到 ${NEW_SLOT}"
kubectl get service ${SERVICE} -n ${NAMESPACE} -o yaml | grep -A 5 selector:
```

### 6.3 金丝雀部署

```yaml
# k8s/production/canary/canary-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app-canary
  namespace: production
  labels:
    app: web-app
    track: canary
spec:
  replicas: 1  # 金丝雀副本数（10%）
  selector:
    matchLabels:
      app: web-app
      track: canary
  template:
    metadata:
      labels:
        app: web-app
        track: canary
        version: v2.0.0
    spec:
      containers:
      - name: web-app
        image: harbor.example.com/production/web-app:v2.0.0
        resources:
          requests:
            cpu: 250m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
```

```bash
#!/bin/bash
# scripts/canary-deploy.sh - 金丝雀部署脚本
set -euo pipefail

NAMESPACE="production"
APP="web-app"
NEW_VERSION="$1"
CANARY_WEIGHT="${2:-10}"  # 默认 10% 流量

echo "=========================================="
echo "  金丝雀部署"
echo "  应用: ${APP}"
echo "  新版本: ${NEW_VERSION}"
echo "  流量比例: ${CANARY_WEIGHT}%"
echo "=========================================="

# 创建金丝雀 Deployment
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP}-canary
  namespace: ${NAMESPACE}
  labels:
    app: ${APP}
    track: canary
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP}
      track: canary
  template:
    metadata:
      labels:
        app: ${APP}
        track: canary
        version: ${NEW_VERSION}
    spec:
      containers:
      - name: ${APP}
        image: harbor.example.com/production/${APP}:${NEW_VERSION}
        resources:
          requests:
            cpu: 250m
            memory: 256Mi
EOF

# 配置金丝雀 Ingress
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${APP}-canary
  namespace: ${NAMESPACE}
  annotations:
    nginx.ingress.kubernetes.io/canary: "true"
    nginx.ingress.kubernetes.io/canary-weight: "${CANARY_WEIGHT}"
spec:
  ingressClassName: nginx
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${APP}-canary
            port:
              number: 80
EOF

echo "金丝雀部署完成！"
echo "监控金丝雀版本的指标..."
echo "使用以下命令监控:"
echo "  kubectl logs -f deployment/${APP}-canary -n ${NAMESPACE}"
echo "  kubectl top pods -n ${NAMESPACE} -l track=canary"
```

### 6.4 滚动更新监控脚本

```bash
#!/bin/bash
# scripts/rolling-update-monitor.sh - 滚动更新监控
set -euo pipefail

NAMESPACE="${1:-production}"
DEPLOYMENT="${2:-myapp}"
TIMEOUT="${3:-300}"

echo "=========================================="
echo "  滚动更新监控"
echo "  部署: ${DEPLOYMENT}"
echo "  命名空间: ${NAMESPACE}"
echo "  超时: ${TIMEOUT}秒"
echo "=========================================="

# 获取初始版本
INITIAL_REVISION=$(kubectl rollout history deployment/${DEPLOYMENT} -n ${NAMESPACE} | tail -2 | head -1 | awk '{print $1}')
echo "初始版本: ${INITIAL_REVISION}"

# 监控更新进度
START_TIME=$(date +%s)
while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo "错误: 更新超时 (${TIMEOUT}秒)"
        kubectl rollout undo deployment/${DEPLOYMENT} -n ${NAMESPACE}
        exit 1
    fi
    
    # 获取部署状态
    STATUS=$(kubectl rollout status deployment/${DEPLOYMENT} -n ${NAMESPACE} --timeout=10s 2>&1)
    
    echo "[${ELAPSED}秒] ${STATUS}"
    
    if echo "$STATUS" | grep -q "successfully"; then
        echo "=========================================="
        echo "  更新完成！"
        echo "=========================================="
        break
    fi
    
    # 检查 Pod 健康状态
    READY_PODS=$(kubectl get pods -n ${NAMESPACE} -l app=${DEPLOYMENT} \
      -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | \
      grep -c "True")
    
    TOTAL_PODS=$(kubectl get pods -n ${NAMESPACE} -l app=${DEPLOYMENT} --no-headers | wc -l)
    
    echo "  Pod 状态: ${READY_PODS}/${TOTAL_PODS} 就绪"
    
    sleep 5
done

# 显示最终状态
echo "=========================================="
echo "  最终状态"
echo "=========================================="
kubectl get pods -n ${NAMESPACE} -l app=${DEPLOYMENT}
kubectl get deployment ${DEPLOYMENT} -n ${NAMESPACE}
```

---

## 7. 故障转移测试

### 7.1 Pod 故障测试

```bash
#!/bin/bash
# scripts/pod-failure-test.sh - Pod 故障测试
set -euo pipefail

NAMESPACE="${1:-production}"
DEPLOYMENT="${2:-myapp}"

echo "=========================================="
echo "  Pod 故障测试"
echo "=========================================="

# 1. 随机删除 Pod
echo "测试1: 随机删除 Pod"
kubectl get pods -n ${NAMESPACE} -l app=${DEPLOYMENT}
RANDOM_POD=$(kubectl get pods -n ${NAMESPACE} -l app=${DEPLOYMENT} \
  -o jsonpath='{.items[0].metadata.name}')
echo "删除 Pod: ${RANDOM_POD}"
kubectl delete pod ${RANDOM_POD} -n ${NAMESPACE}
echo "等待 Pod 重建..."
kubectl wait --for=condition=Ready pod -l app=${DEPLOYMENT} \
  -n ${NAMESPACE} --timeout=120s
echo "Pod 已重建"
kubectl get pods -n ${NAMESPACE} -l app=${DEPLOYMENT}

# 2. 模拟 Pod OOM
echo "测试2: 模拟 OOM Kill"
kubectl get pods -n ${NAMESPACE} -l app=${DEPLOYMENT}
OOM_POD=$(kubectl get pods -n ${NAMESPACE} -l app=${DEPLOYMENT} \
  -o jsonpath='{.items[0].metadata.name}')
echo "触发 OOM: ${OOM_POD}"
kubectl exec ${OOM_POD} -n ${NAMESPACE} -- dd if=/dev/zero of=/tmp/oom-test bs=100M count=10 || true
sleep 5
echo "等待 Pod 重建..."
kubectl wait --for=condition=Ready pod -l app=${DEPLOYMENT} \
  -n ${NAMESPACE} --timeout=120s
echo "Pod 已重建"

# 3. 测试节点故障
echo "测试3: 节点故障模拟"
NODE=$(kubectl get pods -n ${NAMESPACE} -l app=${DEPLOYMENT} \
  -o jsonpath='{.items[0].spec.nodeName}')
echo "模拟节点故障: ${NODE}"
echo "使用 cordon 模拟节点不可用..."
kubectl cordon ${NODE}
echo "节点已 cordon"
sleep 30
kubectl uncordon ${NODE}
echo "节点已 uncordon"

echo "=========================================="
echo "  故障转移测试完成"
echo "=========================================="
```

### 7.2 节点故障测试

```bash
#!/bin/bash
# scripts/node-failure-test.sh - 节点故障测试
set -euo pipefail

NODE="${1}"
NAMESPACE="${2:-production}"

echo "=========================================="
echo "  节点故障测试"
echo "  节点: ${NODE}"
echo "=========================================="

# 1. 记录当前 Pod 分布
echo "当前 Pod 分布:"
kubectl get pods -n ${NAMESPACE} -o wide | grep ${NODE} || echo "该节点无 Pod"

# 2. Cordon 节点
echo "Cordon 节点..."
kubectl cordon ${NODE}

# 3. 驱逐 Pod
echo "Drain 节点..."
kubectl drain ${NODE} \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force \
  --grace-period=60

# 4. 等待 Pod 重新调度
echo "等待 Pod 重新调度..."
sleep 30

# 5. 检查 Pod 状态
echo "Pod 分布情况:"
kubectl get pods -n ${NAMESPACE} -o wide

# 6. Uncordon 节点
echo "Uncordon 节点..."
kubectl uncordon ${NODE}

echo "=========================================="
echo "  节点故障测试完成"
echo "=========================================="
```

### 7.3 网络故障测试

```bash
#!/bin/bash
# scripts/network-failure-test.sh - 网络故障测试
set -euo pipefail

NAMESPACE="${1:-production}"
DEPLOYMENT="${2:-myapp}"
SERVICE="${3:-myapp-service}"

echo "=========================================="
echo "  网络故障测试"
echo "=========================================="

# 1. DNS 故障
echo "测试1: DNS 故障"
# 创建临时 Pod 测试 DNS
kubectl run dns-test --rm -it --restart=Never \
  --image=busybox --namespace=${NAMESPACE} -- \
  nslookup ${SERVICE}.${NAMESPACE}.svc.cluster.local

# 2. 网络延迟
echo "测试2: 网络延迟模拟"
# 使用 tc 模拟网络延迟
kubectl exec -n ${NAMESPACE} $(kubectl get pods -n ${NAMESPACE} -l app=${DEPLOYMENT} \
  -o jsonpath='{.items[0].metadata.name}') -- \
  tc qdisc add dev eth0 root netem delay 100ms 50ms || echo "tc 命令不可用"

# 3. 服务不可达
echo "测试3: 服务不可达测试"
kubectl get endpoints ${SERVICE} -n ${NAMESPACE}

# 4. 超时测试
echo "测试4: 超时测试"
kubectl run timeout-test --rm -it --restart=Never \
  --image=curlimages/curl --namespace=${NAMESPACE} -- \
  curl -m 5 http://${SERVICE}.${NAMESPACE}.svc.cluster.local/health || echo "请求超时"

echo "=========================================="
echo "  网络故障测试完成"
echo "=========================================="
```

### 7.4 自动故障转移验证

```yaml
# k8s/test/failure-test-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: failure-test
  namespace: testing
spec:
  template:
    spec:
      serviceAccountName: test-runner
      containers:
      - name: test
        image: bitnami/kubectl:latest
        command:
        - /bin/bash
        - -c
        - |
          echo "=== 自动故障转移测试 ==="
          
          # 测试1: 删除 Pod
          echo "测试1: 删除所有 Pod"
          kubectl delete pods -n production -l app=myapp
          sleep 10
          
          # 验证 Pod 重建
          READY=$(kubectl get pods -n production -l app=myapp \
            -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | \
            grep -c "True")
          echo "Pod 就绪数: ${READY}"
          
          # 测试2: 修改 Service selector
          echo "测试2: Service 故障转移"
          kubectl patch service myapp -n production \
            -p '{"spec":{"selector":{"app":"nonexistent"}}}' || true
          sleep 5
          
          # 验证 Service 路由
          kubectl get service myapp -n production -o yaml | grep -A 5 selector:
          
          # 恢复 Service
          kubectl patch service myapp -n production \
            -p '{"spec":{"selector":{"app":"myapp"}}}'
          
          echo "=== 故障转移测试完成 ==="
      restartPolicy: Never
  backoffLimit: 1
```

### 7.5 Chaos Engineering（混沌工程）

```bash
# 安装 Litmus Chaos
helm repo add litmuschaos https://litmuschaos.github.io/litmus-helm
helm repo update

helm install litmus litmuschaos/litmus \
  --namespace litmus \
  --create-namespace \
  --set portalServer.frontend.service.type=LoadBalancer
```

```yaml
# k8s/chaos/pod-delete-chaos.yaml
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: pod-delete-chaos
  namespace: litmus
spec:
  appinfo:
    appns: production
    applabel: app=myapp
    appkind: deployment
  chaosServiceAccount: litmus-admin
  experiments:
  - name: pod-delete
    spec:
      components:
        env:
        - name: TOTAL_CHAOS_DURATION
          value: '30'
        - name: CHAOS_INTERVAL
          value: '10'
        - name: FORCE
          value: 'false'
```

---

## 8. 生产最佳实践

### 8.1 资源配额

```yaml
# k8s/production/resource-quota.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: production-quota
  namespace: production
spec:
  hard:
    requests.cpu: "20"
    requests.memory: 40Gi
    limits.cpu: "40"
    limits.memory: 80Gi
    pods: "50"
    services: "20"
    persistentvolumeclaims: "20"

---
# k8s/production/limit-range.yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: production-limit-range
  namespace: production
spec:
  limits:
  - type: Container
    default:
      cpu: 500m
      memory: 512Mi
    defaultRequest:
      cpu: 100m
      memory: 128Mi
    max:
      cpu: 2000m
      memory: 2Gi
    min:
      cpu: 50m
      memory: 64Mi
```

### 8.2 网络策略

```yaml
# k8s/production/network-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-app-network-policy
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: web-app
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: ingress-nginx
    ports:
    - protocol: TCP
      port: 8080
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: production
    ports:
    - protocol: TCP
      port: 5432  # PostgreSQL
    - protocol: TCP
      port: 6379  # Redis
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: TCP
      port: 53  # DNS
    - protocol: UDP
      port: 53
```

### 8.3 Pod 安全标准

```yaml
# k8s/production/pod-security-policy.yaml
apiVersion: v1
kind: PodSecurityPolicy
metadata:
  name: restricted-psp
spec:
  privileged: false
  allowPrivilegeEscalation: false
  requiredDropCapabilities:
  - ALL
  runAsUser:
    rule: MustRunAsNonRoot
  seLinux:
    rule: RunAsAny
  fsGroup:
    rule: RunAsAny
  supplementalGroups:
    rule: RunAsAny
  volumes:
  - configMap
  - emptyDir
  - persistentVolumeClaim
  - secret
```

---

## 小结

本阶段详细介绍了 Kubernetes 应用部署的各个方面：

1. **Deployment** - 工作负载管理、Pod 模板配置、健康检查
2. **Service** - 网络服务、负载均衡、服务发现
3. **Ingress** - HTTP 路由、TLS 终止、金丝雀发布
4. **HPA** - 自动扩缩容、自定义指标、KEDA 事件驱动
5. **ConfigMap/Secret** - 配置管理、密钥管理、外部密钥管理
6. **滚动更新** - 更新策略、蓝绿部署、金丝雀发布
7. **故障转移** - 故障测试、混沌工程、自动化验证

通过这些配置和实践，可以构建高可用、可扩展、安全的 Kubernetes 应用部署体系。
