# 阶段6：监控告警详细文档

## 目录

1. [概述](#概述)
2. [Prometheus 配置详解](#1-prometheus-配置详解)
3. [Grafana Dashboard 配置](#2-grafana-dashboard-配置)
4. [Alertmanager 告警规则](#3-alertmanager-告警规则)
5. [自定义监控指标](#4-自定义监控指标)
6. [告警通知配置](#5-告警通知配置)
7. [监控最佳实践](#6-监控最佳实践)

---

## 概述

本阶段构建完整的监控告警体系，实现对 Kubernetes 集群和应用的全面监控。

### 监控架构

```
应用/Pod (暴露 /metrics)
    ↓
Prometheus Server (抓取、存储、查询)
    ↓
Grafana (可视化)
Alertmanager (告警管理)
    ↓
通知渠道 (Email/Slack/钉钉/Webhook)
```

### 技术栈

| 组件 | 用途 | 版本 |
|------|------|------|
| Prometheus | 指标收集与存储 | 2.x |
| Alertmanager | 告警管理与路由 | 0.26+ |
| Grafana | 可视化 Dashboard | 10.x |
| Node Exporter | 主机指标 | 1.7+ |
| kube-state-metrics | K8s 对象指标 | 2.x |
| Prometheus Adapter | 自定义指标 | 0.11+ |

---

## 1. Prometheus 配置详解

### 1.1 Prometheus 安装（kube-prometheus-stack）

```bash
# 添加 Helm 仓库
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# 创建命名空间
kubectl create namespace monitoring

# 创建 values 文件
cat > prometheus-values.yaml <<'EOF'
# kube-prometheus-stack values
prometheus:
  prometheusSpec:
    # 数据保留时间
    retention: 15d
    retentionSize: "50GB"
    
    # 存储配置
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          storageClassName: managed-csi
          resources:
            requests:
              storage: 100Gi
    
    # 资源限制
    resources:
      requests:
        cpu: 500m
        memory: 2Gi
      limits:
        cpu: 2000m
        memory: 4Gi
    
    # 抓取配置
    scrapeInterval: 15s
    evaluationInterval: 15s
    
    # 额外抓取配置
    additionalScrapeConfigs:
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
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: pod
      - source_labels: [__meta_kubernetes_pod_label_app]
        action: replace
        target_label: app
    
    # 服务发现配置
    additionalScrapeConfigs:
    - job_name: 'kubernetes-services'
      kubernetes_sd_configs:
      - role: endpoints
      relabel_configs:
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scrape]
        action: keep
        regex: true
    
    # 外部标签
    externalLabels:
      cluster: production
      environment: production

# Alertmanager 配置
alertmanager:
  config:
    global:
      resolve_timeout: 5m
      smtp_smarthost: 'smtp.example.com:587'
      smtp_from: 'alertmanager@example.com'
      smtp_auth_username: 'alertmanager@example.com'
      smtp_auth_password: 'your-password'
      smtp_require_tls: true
    
    route:
      receiver: 'default'
      group_by: ['alertname', 'namespace', 'severity']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      
      routes:
      - match:
          severity: critical
        receiver: 'critical-alerts'
        group_wait: 10s
        repeat_interval: 1h
      - match:
          severity: warning
        receiver: 'warning-alerts'
        repeat_interval: 4h
      - match:
          severity: info
        receiver: 'info-alerts'
        repeat_interval: 12h
    
    receivers:
    - name: 'default'
      email_configs:
      - to: 'ops-team@example.com'
        send_resolved: true
    
    - name: 'critical-alerts'
      email_configs:
      - to: 'critical-alerts@example.com'
        send_resolved: true
      webhook_configs:
      - url: 'http://alertmanager-webhook:9095/webhook'
        send_resolved: true
    
    - name: 'warning-alerts'
      email_configs:
      - to: 'warning-alerts@example.com'
        send_resolved: true
    
    - name: 'info-alerts'
      email_configs:
      - to: 'info-alerts@example.com'
        send_resolved: false
    
    inhibit_rules:
    - source_match:
        severity: 'critical'
      target_match:
        severity: 'warning'
      equal: ['alertname', 'namespace']
  
  # Alertmanager 资源配置
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi
  
  # 持久化存储
  storageSpec:
    volumeClaimTemplate:
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: managed-csi
        resources:
          requests:
            storage: 10Gi

# Grafana 配置
grafana:
  enabled: true
  adminPassword: "admin123"
  
  # 数据源配置
  datasources:
    datasources.yaml:
      apiVersion: 1
      datasources:
      - name: Prometheus
        type: prometheus
        url: http://prometheus-kube-prometheus-prometheus:9090
        access: proxy
        isDefault: true
  
  # Dashboard 配置
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
      - name: 'default'
        orgId: 1
        folder: 'Kubernetes'
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /var/lib/grafana/dashboards/default
  
  # 资源配置
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 1Gi

# Node Exporter
nodeExporter:
  enabled: true

# kube-state-metrics
kubeStateMetrics:
  enabled: true
EOF

# 安装 kube-prometheus-stack
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f prometheus-values.yaml \
  --wait
```

### 1.2 Prometheus 配置文件详解

```yaml
# prometheus-config.yaml - Prometheus 核心配置
global:
  # 默认抓取间隔
  scrape_interval: 15s
  # 默认评估间隔
  evaluation_interval: 15s
  # 抓取超时
  scrape_timeout: 10s
  # 外部标签
  external_labels:
    cluster: 'production'
    environment: 'production'

# 告警规则文件
rule_files:
  - /etc/prometheus/rules/*.yml

# Alertmanager 配置
alerting:
  alertmanagers:
  - static_configs:
    - targets:
      - alertmanager:9093

# 抓取配置
scrape_configs:
  # Prometheus 自身
  - job_name: 'prometheus'
    static_configs:
    - targets: ['localhost:9090']

  # Kubernetes API 服务器
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

  # Kubernetes 节点
  - job_name: 'kubernetes-nodes'
    kubernetes_sd_configs:
    - role: node
    scheme: https
    tls_config:
      ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
    relabel_configs:
    - action: labelmap
      regex: __meta_kubernetes_node_label_(.+)
    - target_label: __address__
      replacement: kubernetes.default.svc:443
    - source_labels: [__meta_kubernetes_node_name]
      regex: (.+)
      target_label: __metrics_path__
      replacement: /api/v1/nodes/${1}/proxy/metrics

  # Kubernetes Pods（自动发现）
  - job_name: 'kubernetes-pods'
    kubernetes_sd_configs:
    - role: pod
    relabel_configs:
    # 只抓取带注解的 Pod
    - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
      action: keep
      regex: true
    # 自定义指标路径
    - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
      action: replace
      target_label: __metrics_path__
      regex: (.+)
    # 自定义端口
    - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
      action: replace
      regex: ([^:]+)(?::\d+)?;(\d+)
      replacement: $1:$2
      target_label: __address__
    # 添加标签
    - source_labels: [__meta_kubernetes_namespace]
      action: replace
      target_label: namespace
    - source_labels: [__meta_kubernetes_pod_name]
      action: replace
      target_label: pod
    - source_labels: [__meta_kubernetes_pod_label_app]
      action: replace
      target_label: app

  # Kubernetes Services
  - job_name: 'kubernetes-services'
    kubernetes_sd_configs:
    - role: endpoints
    relabel_configs:
    - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scrape]
      action: keep
      regex: true
    - source_labels: [__meta_kubernetes_namespace]
      action: replace
      target_label: namespace
    - source_labels: [__meta_kubernetes_service_name]
      action: replace
      target_label: service

  # Kubernetes Ingress
  - job_name: 'kubernetes-ingress'
    kubernetes_sd_configs:
    - role: ingress
    relabel_configs:
    - source_labels: [__meta_kubernetes_ingress_annotation_prometheus_io_scrape]
      action: keep
      regex: true
    - source_labels: [__meta_kubernetes_ingress_annotation_prometheus_io_path]
      action: replace
      target_label: __metrics_path__
      regex: (.+)
    - source_labels: [__address__, __meta_kubernetes_ingress_annotation_prometheus_io_port]
      action: replace
      regex: ([^:]+)(?::\d+)?;(\d+)
      replacement: $1:$2
      target_label: __address__
    - source_labels: [__meta_kubernetes_ingress_annotation_prometheus_io_scheme]
      action: replace
      target_label: __scheme__
      regex: (https?)

  # kube-state-metrics
  - job_name: 'kube-state-metrics'
    static_configs:
    - targets: ['kube-state-metrics.kube-system:8080']

  # Node Exporter
  - job_name: 'node-exporter'
    kubernetes_sd_configs:
    - role: pod
    relabel_configs:
    - source_labels: [__meta_kubernetes_pod_node_name]
      action: replace
      target_label: node
    - source_labels: [__meta_kubernetes_namespace]
      action: keep
      regex: monitoring
    - source_labels: [__meta_kubernetes_pod_label_app]
      action: keep
      regex: node-exporter

  # cAdvisor
  - job_name: 'cadvisor'
    kubernetes_sd_configs:
    - role: node
    scheme: https
    tls_config:
      ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
    metrics_path: /metrics/cadvisor
    relabel_configs:
    - target_label: __address__
      replacement: kubernetes.default.svc:443
    - source_labels: [__meta_kubernetes_node_name]
      regex: (.+)
      target_label: __metrics_path__
      replacement: /api/v1/nodes/${1}/proxy/metrics/cadvisor

# 远程写入配置
remote_write:
  - url: "http://thanos-receive:19291/api/v1/receive"
    queue_config:
      capacity: 1000
      max_samples_per_send: 500
      batch_send_deadline: 5s
      max_shards: 20
    write_relabel_configs:
    - source_labels: [__name__]
      regex: 'go_.*'
      action: drop
```

### 1.3 服务发现配置

```yaml
# k8s/monitoring/servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: myapp-servicemonitor
  namespace: production
  labels:
    app: myapp
    release: prometheus
spec:
  selector:
    matchLabels:
      app: myapp
  namespaceSelector:
    matchNames:
    - production
  endpoints:
  - port: http
    path: /metrics
    interval: 15s
    scrapeTimeout: 10s
  - port: metrics
    path: /metrics
    interval: 30s

---
# k8s/monitoring/podmonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: myapp-podmonitor
  namespace: production
  labels:
    app: myapp
spec:
  selector:
    matchLabels:
      app: myapp
  namespaceSelector:
    matchNames:
    - production
  podMetricsEndpoints:
  - port: http
    path: /metrics
    interval: 15s

---
# k8s/monitoring/prometheusrule.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: myapp-alerts
  namespace: production
  labels:
    app: myapp
spec:
  groups:
  - name: myapp.rules
    rules:
    - alert: MyAppHighErrorRate
      expr: rate(http_requests_total{app="myapp",status=~"5.."}[5m]) > 0.1
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "高错误率"
        description: "应用 {{ $labels.app }} 错误率超过 10%"

  - name: myapp-recording.rules
    rules:
    - record: myapp:http_requests:rate5m
      expr: rate(http_requests_total{app="myapp"}[5m])
    - record: myapp:http_errors:rate5m
      expr: rate(http_requests_total{app="myapp",status=~"5.."}[5m])
```

---

## 2. Grafana Dashboard 配置

### 2.1 Grafana 安装与配置

```bash
# Grafana 访问
# 默认地址: http://grafana.example.com
# 默认账号: admin / admin123

# 配置 Grafana 数据源
curl -X POST http://admin:admin123@grafana.example.com/api/datasources \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Prometheus",
    "type": "prometheus",
    "url": "http://prometheus-kube-prometheus-prometheus:9090",
    "access": "proxy",
    "isDefault": true
  }'
```

### 2.2 Kubernetes 集群 Dashboard

```json
{
  "dashboard": {
    "title": "Kubernetes Cluster Overview",
    "tags": ["kubernetes", "cluster"],
    "timezone": "browser",
    "panels": [
      {
        "title": "CPU Usage",
        "type": "graph",
        "targets": [
          {
            "expr": "100 - (avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)",
            "legendFormat": "CPU Usage %"
          }
        ],
        "yaxes": [
          {"format": "percent", "min": 0, "max": 100},
          {"format": "short"}
        ]
      },
      {
        "title": "Memory Usage",
        "type": "graph",
        "targets": [
          {
            "expr": "100 - ((node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100)",
            "legendFormat": "Memory Usage %"
          }
        ],
        "yaxes": [
          {"format": "percent", "min": 0, "max": 100},
          {"format": "short"}
        ]
      },
      {
        "title": "Pod Status",
        "type": "stat",
        "targets": [
          {
            "expr": "sum(kube_pod_status_phase{phase=\"Running\"})",
            "legendFormat": "Running"
          },
          {
            "expr": "sum(kube_pod_status_phase{phase=\"Pending\"})",
            "legendFormat": "Pending"
          },
          {
            "expr": "sum(kube_pod_status_phase{phase=\"Failed\"})",
            "legendFormat": "Failed"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "thresholds": {
              "mode": "absolute",
              "steps": [
                {"color": "green", "value": null},
                {"color": "yellow", "value": 50},
                {"color": "red", "value": 100}
              ]
            }
          }
        }
      },
      {
        "title": "Network I/O",
        "type": "graph",
        "targets": [
          {
            "expr": "rate(node_network_receive_bytes_total{device!~\"lo|veth.*|docker.*|flannel.*\"}[5m]) * 8",
            "legendFormat": "{{device}} receive"
          },
          {
            "expr": "rate(node_network_transmit_bytes_total{device!~\"lo|veth.*|docker.*|flannel.*\"}[5m]) * 8",
            "legendFormat": "{{device}} transmit"
          }
        ],
        "yaxes": [
          {"format": "bps"},
          {"format": "short"}
        ]
      },
      {
        "title": "Disk Usage",
        "type": "graph",
        "targets": [
          {
            "expr": "100 - ((node_filesystem_avail_bytes{fstype!~\"tmpfs|overlay\"} / node_filesystem_size_bytes{fstype!~\"tmpfs|overlay\"}) * 100)",
            "legendFormat": "{{mountpoint}} {{instance}}"
          }
        ],
        "yaxes": [
          {"format": "percent", "min": 0, "max": 100},
          {"format": "short"}
        ]
      }
    ]
  }
}
```

### 2.3 应用 Dashboard

```yaml
# k8s/monitoring/grafana-dashboard-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: myapp-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  myapp-overview.json: |
    {
      "dashboard": {
        "title": "MyApp Application Dashboard",
        "tags": ["myapp", "application"],
        "panels": [
          {
            "title": "Request Rate",
            "type": "graph",
            "targets": [
              {
                "expr": "sum(rate(http_requests_total{app=\"myapp\"}[5m])) by (method)",
                "legendFormat": "{{method}}"
              }
            ]
          },
          {
            "title": "Response Time (p95)",
            "type": "graph",
            "targets": [
              {
                "expr": "histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{app=\"myapp\"}[5m])) by (le))",
                "legendFormat": "p95"
              },
              {
                "expr": "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{app=\"myapp\"}[5m])) by (le))",
                "legendFormat": "p99"
              }
            ]
          },
          {
            "title": "Error Rate",
            "type": "graph",
            "targets": [
              {
                "expr": "sum(rate(http_requests_total{app=\"myapp\",status=~\"5..\"}[5m])) / sum(rate(http_requests_total{app=\"myapp\"}[5m])) * 100",
                "legendFormat": "Error %"
              }
            ]
          },
          {
            "title": "Active Connections",
            "type": "stat",
            "targets": [
              {
                "expr": "sum(http_connections_active{app=\"myapp\"})",
                "legendFormat": "Active"
              }
            ]
          },
          {
            "title": "Database Pool",
            "type": "graph",
            "targets": [
              {
                "expr": "hikaricp_connections_active{app=\"myapp\"}",
                "legendFormat": "Active"
              },
              {
                "expr": "hikaricp_connections_idle{app=\"myapp\"}",
                "legendFormat": "Idle"
              },
              {
                "expr": "hikaricp_connections_pending{app=\"myapp\"}",
                "legendFormat": "Pending"
              }
            ]
          }
        ]
      }
    }
```

### 2.4 Grafana Dashboard 导入

```bash
# 通过 API 导入 Dashboard
curl -X POST http://admin:admin123@grafana.example.com/api/dashboards/import \
  -H "Content-Type: application/json" \
  -d '{
    "dashboard": {
      "id": null,
      "title": "Kubernetes Cluster Overview",
      "tags": ["kubernetes", "cluster"],
      "timezone": "browser",
      "panels": []
    },
    "folderId": 0,
    "overwrite": true
  }'

# 导入推荐的 Dashboard
# 1. Kubernetes Cluster Monitoring (ID: 7249)
# 2. Node Exporter Full (ID: 1860)
# 3. Prometheus Stats (ID: 2)
# 4. Docker Monitoring (ID: 893)
```

### 2.5 常用 PromQL 查询

```promql
# ========== 节点指标 ==========

# CPU 使用率
100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# 内存使用率
100 - ((node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100)

# 磁盘使用率
100 - ((node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay"}) * 100)

# 网络接收速率 (bps)
rate(node_network_receive_bytes_total{device!~"lo|veth.*|docker.*|flannel.*"}[5m]) * 8

# ========== Pod 指标 ==========

# Pod CPU 使用率
sum(rate(container_cpu_usage_seconds_total{namespace="production"}[5m])) by (pod) /
sum(kube_pod_container_resource_requests{resource="cpu", namespace="production"}) by (pod) * 100

# Pod 内存使用率
sum(container_memory_working_set_bytes{namespace="production"}) by (pod) /
sum(kube_pod_container_resource_requests{resource="memory", namespace="production"}) by (pod) * 100

# Pod 重启次数
increase(kube_pod_container_status_restarts_total{namespace="production"}[1h])

# ========== 应用指标 ==========

# 请求速率
sum(rate(http_requests_total{app="myapp"}[5m])) by (method, status)

# 响应时间 (p95)
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{app="myapp"}[5m])) by (le))

# 错误率
sum(rate(http_requests_total{app="myapp",status=~"5.."}[5m])) / sum(rate(http_requests_total{app="myapp"}[5m])) * 100

# 活跃连接数
sum(http_connections_active{app="myapp"})

# ========== Kubernetes 指标 ==========

# Deployment 副本数
kube_deployment_spec_replicas{namespace="production"}

# Deployment 可用副本数
kube_deployment_status_available_replicas{namespace="production"}

# PVC 使用率
kubelet_volume_stats_used_bytes{namespace="production"} / kubelet_volume_stats_capacity_bytes{namespace="production"} * 100

# Namespace 资源使用
sum(rate(container_cpu_usage_seconds_total{namespace="production"}[5m])) by (namespace)
sum(container_memory_working_set_bytes{namespace="production"}) by (namespace)
```

---

## 3. Alertmanager 告警规则

### 3.1 节点告警

```yaml
# k8s/monitoring/alerts-node.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: node-alerts
  namespace: monitoring
spec:
  groups:
  - name: node.rules
    rules:
    # CPU 使用率过高
    - alert: HighCPUUsage
      expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 85
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "节点 {{ $labels.instance }} CPU 使用率过高"
        description: "CPU 使用率已达 {{ $value }}%，持续超过10分钟"

    # 内存使用率过高
    - alert: HighMemoryUsage
      expr: 100 - ((node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100) > 90
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "节点 {{ $labels.instance }} 内存使用率过高"
        description: "内存使用率已达 {{ $value }}%，可能导致 OOM"

    # 磁盘使用率过高
    - alert: HighDiskUsage
      expr: 100 - ((node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay"}) * 100) > 85
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "节点 {{ $labels.instance }} 磁盘使用率过高"
        description: "挂载点 {{ $labels.mountpoint }} 使用率已达 {{ $value }}%"

    # 磁盘即将满
    - alert: DiskWillFull
      expr: predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}[6h], 24*3600) < 0
      for: 30m
      labels:
        severity: critical
      annotations:
        summary: "节点 {{ $labels.instance }} 磁盘将在24小时内满"
        description: "基于当前趋势，挂载点 {{ $labels.mountpoint }} 将在24小时内满"

    # 节点不可用
    - alert: NodeDown
      expr: up{job="kubernetes-nodes"} == 0
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "节点 {{ $labels.instance }} 不可达"
        description: "节点已不可达超过5分钟"
```

### 3.2 Pod 告警

```yaml
# k8s/monitoring/alerts-pod.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: pod-alerts
  namespace: monitoring
spec:
  groups:
  - name: pod.rules
    rules:
    # Pod 重启次数过多
    - alert: PodRestartTooMany
      expr: increase(kube_pod_container_status_restarts_total[1h]) > 5
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "Pod {{ $labels.pod }} 重启次数过多"
        description: "1小时内重启了 {{ $value }} 次"

    # Pod 处于 Pending 状态
    - alert: PodPending
      expr: kube_pod_status_phase{phase="Pending"} == 1
      for: 15m
      labels:
        severity: warning
      annotations:
        summary: "Pod {{ $labels.pod }} 处于 Pending 状态"
        description: "Pod 已 pending 超过15分钟"

    # Pod 处于 CrashLoopBackOff
    - alert: PodCrashLooping
      expr: kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"} == 1
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "Pod {{ $labels.pod }} 处于 CrashLoopBackOff"
        description: "容器 {{ $labels.container }} 持续崩溃重启"

    # Pod OOM Kill
    - alert: PodOOMKilled
      expr: kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "Pod {{ $labels.pod }} 被 OOM Kill"
        description: "容器 {{ $labels.container }} 因内存不足被终止"

    # Pod CPU 使用率超过请求值
    - alert: PodCPUThrottling
      expr: rate(container_cpu_cfs_throttled_periods_total{namespace="production"}[5m]) / rate(container_cpu_cfs_periods_total{namespace="production"}[5m]) > 0.5
      for: 15m
      labels:
        severity: warning
      annotations:
        summary: "Pod {{ $labels.pod }} CPU 被限流"
        description: "CPU 限流率已达 {{ $value | humanizePercentage }}"

    # Pod 内存接近限制
    - alert: PodMemoryNearLimit
      expr: container_memory_working_set_bytes{namespace="production"} / container_spec_memory_limit_bytes{namespace="production"} > 0.9
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "Pod {{ $labels.pod }} 内存接近限制"
        description: "内存使用已达限制的 {{ $value | humanizePercentage }}"
```

### 3.3 Deployment 告警

```yaml
# k8s/monitoring/alerts-deployment.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: deployment-alerts
  namespace: monitoring
spec:
  groups:
  - name: deployment.rules
    rules:
    # Deployment 副本数不足
    - alert: DeploymentReplicasMismatch
      expr: kube_deployment_spec_replicas{namespace="production"} != kube_deployment_status_available_replicas{namespace="production"}
      for: 15m
      labels:
        severity: warning
      annotations:
        summary: "Deployment {{ $labels.deployment }} 副本数不匹配"
        description: "期望 {{ $labels.spec_replicas }} 个副本，实际 {{ $labels.status_replicas }} 个"

    # Deployment 不可用
    - alert: DeploymentUnavailable
      expr: kube_deployment_status_unavailable_replicas{namespace="production"} > 0
      for: 10m
      labels:
        severity: critical
      annotations:
        summary: "Deployment {{ $labels.deployment }} 有不可用副本"
        description: "{{ $value }} 个副本不可用"

    # HPA 达到最大副本数
    - alert: HPAAtMaxReplicas
      expr: kube_horizontalpodautoscaler_status_current_replicas{namespace="production"} == kube_horizontalpodautoscaler_spec_max_replicas{namespace="production"}
      for: 15m
      labels:
        severity: warning
      annotations:
        summary: "HPA {{ $labels.horizontalpodautoscaler }} 达到最大副本数"
        description: "当前副本数 {{ $value }} 已达到上限"
```

### 3.4 应用告警

```yaml
# k8s/monitoring/alerts-application.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: application-alerts
  namespace: monitoring
spec:
  groups:
  - name: application.rules
    rules:
    # 高错误率
    - alert: HighErrorRate
      expr: sum(rate(http_requests_total{app="myapp",status=~"5.."}[5m])) / sum(rate(http_requests_total{app="myapp"}[5m])) > 0.05
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "应用错误率过高"
        description: "错误率已达 {{ $value | humanizePercentage }}，超过5%阈值"

    # 响应时间过长
    - alert: HighResponseTime
      expr: histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{app="myapp"}[5m])) by (le)) > 2
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "应用响应时间过长"
        description: "p95 响应时间已达 {{ $value }}s"

    # 数据库连接池耗尽
    - alert: DatabasePoolExhausted
      expr: hikaricp_connections_pending{app="myapp"} > 10
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "数据库连接池即将耗尽"
        description: "{{ $value }} 个连接正在等待"

    # Redis 连接失败
    - alert: RedisConnectionFailed
      expr: redis_up{app="myapp"} == 0
      for: 2m
      labels:
        severity: critical
      annotations:
        summary: "Redis 连接失败"
        description: "无法连接到 Redis 服务"
```

### 3.5 集群告警

```yaml
# k8s/monitoring/alerts-cluster.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cluster-alerts
  namespace: monitoring
spec:
  groups:
  - name: cluster.rules
    rules:
    # 节点资源不足
    - alert: NodeResourcePressure
      expr: kube_node_status_condition{condition="MemoryPressure",status="true"} == 1
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "节点 {{ $labels.node }} 内存压力"
        description: "节点内存不足"

    # 节点磁盘压力
    - alert: NodeDiskPressure
      expr: kube_node_status_condition{condition="DiskPressure",status="true"} == 1
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "节点 {{ $labels.node }} 磁盘压力"
        description: "节点磁盘不足"

    # PVC 即将满
    - alert: PVCNearFull
      expr: kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes > 0.85
      for: 15m
      labels:
        severity: warning
      annotations:
        summary: "PVC {{ $labels.persistentvolumeclaim }} 即将满"
        description: "使用率已达 {{ $value | humanizePercentage }}"

    # etcd 延迟高
    - alert: EtcdHighLatency
      expr: histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m])) > 0.5
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "etcd fsync 延迟高"
        description: "p99 延迟已达 {{ $value }}s"

    # API Server 请求延迟
    - alert: APIServerHighLatency
      expr: histogram_quantile(0.99, sum(rate(apiserver_request_duration_seconds_bucket{verb=~"GET|LIST"}[5m])) by (le)) > 1
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "API Server 请求延迟高"
        description: "GET/LIST 请求 p99 延迟已达 {{ $value }}s"
```

---

## 4. 自定义监控指标

### 4.1 应用指标暴露（Python）

```python
# app/metrics.py - Prometheus 指标暴露
from prometheus_client import Counter, Histogram, Gauge, Info, start_http_server
import time
import functools

# ========== 计数器 (Counter) ==========

# HTTP 请求总数
http_requests_total = Counter(
    'http_requests_total',
    'HTTP 请求总数',
    ['method', 'endpoint', 'status', 'app']
)

# HTTP 请求错误数
http_errors_total = Counter(
    'http_errors_total',
    'HTTP 请求错误数',
    ['method', 'endpoint', 'status', 'error_type', 'app']
)

# 业务操作计数
business_operations_total = Counter(
    'business_operations_total',
    '业务操作总数',
    ['operation', 'status', 'app']
)

# ========== 直方图 (Histogram) ==========

# HTTP 请求延迟
http_request_duration_seconds = Histogram(
    'http_request_duration_seconds',
    'HTTP 请求延迟（秒）',
    ['method', 'endpoint', 'app'],
    buckets=(0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0)
)

# 数据库查询延迟
db_query_duration_seconds = Histogram(
    'db_query_duration_seconds',
    '数据库查询延迟（秒）',
    ['operation', 'table', 'app'],
    buckets=(0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0)
)

# ========== 仪表盘 (Gauge) ==========

# 活跃连接数
active_connections = Gauge(
    'http_connections_active',
    '活跃连接数',
    ['app']
)

# 队列长度
queue_length = Gauge(
    'queue_length',
    '队列长度',
    ['queue_name', 'app']
)

# 缓存命中率
cache_hit_ratio = Gauge(
    'cache_hit_ratio',
    '缓存命中率',
    ['cache_name', 'app']
)

# ========== 信息 (Info) ==========

# 应用信息
app_info = Info(
    'app',
    '应用信息'
)

# ========== 装饰器 ==========

def track_metrics(app_name='myapp'):
    """装饰器：自动跟踪 HTTP 请求指标"""
    def decorator(func):
        @functools.wraps(func)
        async def wrapper(*args, **kwargs):
            start_time = time.time()
            
            # 增加活跃连接数
            active_connections.labels(app=app_name).inc()
            
            try:
                result = await func(*args, **kwargs)
                
                # 记录成功请求
                duration = time.time() - start_time
                http_request_duration_seconds.labels(
                    method=kwargs.get('method', 'UNKNOWN'),
                    endpoint=kwargs.get('endpoint', 'UNKNOWN'),
                    app=app_name
                ).observe(duration)
                
                http_requests_total.labels(
                    method=kwargs.get('method', 'UNKNOWN'),
                    endpoint=kwargs.get('endpoint', 'UNKNOWN'),
                    status='success',
                    app=app_name
                ).inc()
                
                return result
                
            except Exception as e:
                # 记录错误请求
                duration = time.time() - start_time
                http_request_duration_seconds.labels(
                    method=kwargs.get('method', 'UNKNOWN'),
                    endpoint=kwargs.get('endpoint', 'UNKNOWN'),
                    app=app_name
                ).observe(duration)
                
                http_errors_total.labels(
                    method=kwargs.get('method', 'UNKNOWN'),
                    endpoint=kwargs.get('endpoint', 'UNKNOWN'),
                    status='error',
                    error_type=type(e).__name__,
                    app=app_name
                ).inc()
                
                raise
                
            finally:
                # 减少活跃连接数
                active_connections.labels(app=app_name).dec()
        
        return wrapper
    return decorator


# ========== 使用示例 ==========

# 初始化应用信息
app_info.info({
    'version': '1.0.0',
    'environment': 'production',
    'cluster': 'production-cluster'
})

# 启动指标服务器
def start_metrics_server(port=9090):
    """启动 Prometheus 指标服务器"""
    start_http_server(port)
    print(f"Metrics server started on port {port}")

# 在 FastAPI 应用中使用
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

app = FastAPI()

@app.on_event("startup")
async def startup_event():
    start_metrics_server(9090)

@app.get("/api/users")
@track_metrics(app_name='myapp')
async def get_users(request: Request):
    # 模拟业务逻辑
    business_operations_total.labels(
        operation='get_users',
        status='success',
        app='myapp'
    ).inc()
    
    return {"users": []}

@app.get("/api/orders")
@track_metrics(app_name='myapp')
async def get_orders(request: Request):
    # 模拟数据库查询
    start_time = time.time()
    # await db.query(...)
    duration = time.time() - start_time
    
    db_query_duration_seconds.labels(
        operation='select',
        table='orders',
        app='myapp'
    ).observe(duration)
    
    business_operations_total.labels(
        operation='get_orders',
        status='success',
        app='myapp'
    ).inc()
    
    return {"orders": []}
```

### 4.2 Go 应用指标

```go
// app/metrics.go - Go Prometheus 指标
package main

import (
    "time"
    "net/http"
    
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
    "github.com/prometheus/client_golang/prometheus/promhttp"
)

// 计数器
var (
    httpRequestsTotal = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "http_requests_total",
            Help: "HTTP 请求总数",
        },
        []string{"method", "endpoint", "status", "app"},
    )
    
    httpErrorsTotal = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "http_errors_total",
            Help: "HTTP 请求错误数",
        },
        []string{"method", "endpoint", "status", "error_type", "app"},
    )
)

// 直方图
var (
    httpRequestDuration = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "http_request_duration_seconds",
            Help:    "HTTP 请求延迟（秒）",
            Buckets: prometheus.DefBuckets,
        },
        []string{"method", "endpoint", "app"},
    )
    
    dbQueryDuration = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "db_query_duration_seconds",
            Help:    "数据库查询延迟（秒）",
            Buckets: []float64{0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0},
        },
        []string{"operation", "table", "app"},
    )
)

// 仪表盘
var (
    activeConnections = promauto.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "http_connections_active",
            Help: "活跃连接数",
        },
        []string{"app"},
    )
    
    queueLength = promauto.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "queue_length",
            Help: "队列长度",
        },
        []string{"queue_name", "app"},
    )
)

// 中间件
func MetricsMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        start := time.Now()
        
        activeConnections.WithLabelValues("myapp").Inc()
        defer activeConnections.WithLabelValues("myapp").Dec()
        
        // 包装 ResponseWriter 以捕获状态码
        wrapped := &responseWriter{ResponseWriter: w, statusCode: 200}
        
        next.ServeHTTP(wrapped, r)
        
        duration := time.Since(start).Seconds()
        
        httpRequestDuration.WithLabelValues(
            r.Method,
            r.URL.Path,
            "myapp",
        ).Observe(duration)
        
        status := "success"
        if wrapped.statusCode >= 400 {
            status = "error"
        }
        
        httpRequestsTotal.WithLabelValues(
            r.Method,
            r.URL.Path,
            status,
            "myapp",
        ).Inc()
    })
}

type responseWriter struct {
    http.ResponseWriter
    statusCode int
}

func (rw *responseWriter) WriteHeader(code int) {
    rw.statusCode = code
    rw.ResponseWriter.WriteHeader(code)
}

// 启动指标服务器
func startMetricsServer(addr string) {
    http.Handle("/metrics", promhttp.Handler())
    go http.ListenAndServe(addr, nil)
}
```

### 4.3 Kubernetes 自定义指标配置

```yaml
# k8s/monitoring/prometheus-adapter.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus-adapter
  namespace: monitoring
spec:
  replicas: 2
  selector:
    matchLabels:
      app: prometheus-adapter
  template:
    metadata:
      labels:
        app: prometheus-adapter
    spec:
      containers:
      - name: prometheus-adapter
        image: registry.k8s.io/prometheus-adapter/prometheus-adapter:v0.11.1
        args:
        - --prometheus-url=http://prometheus-kube-prometheus-prometheus:9090
        - --metrics-relist-interval=30s
        - --config=/etc/adapter/config.yaml
        - --secure-port=6443
        ports:
        - containerPort: 6443
        volumeMounts:
        - name: config
          mountPath: /etc/adapter
        - name: tls
          mountPath: /etc/tls
      volumes:
      - name: config
        configMap:
          name: prometheus-adapter-config
      - name: tls
        secret:
          secretName: prometheus-adapter-tls

---
# k8s/monitoring/prometheus-adapter-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-adapter-config
  namespace: monitoring
data:
  config.yaml: |
    rules:
    # Pod CPU 使用率
    - seriesQuery: 'sum(rate(container_cpu_usage_seconds_total{namespace!="",pod!=""}[5m])) by (namespace,pod)'
      resources:
        overrides:
          namespace: {resource: "namespace"}
          pod: {resource: "pod"}
      name:
        matches: "^(.*)_pod_cpu_usage$"
        as: "${1}_cpu_usage"
      metricsQuery: 'sum(rate(container_cpu_usage_seconds_total{namespace="<<.GroupBy.resource.namespace>>",pod="<<.GroupBy.resource.pod>>"}[5m])) by (<<.GroupBy>>)'
    
    # Pod 内存使用率
    - seriesQuery: 'sum(container_memory_working_set_bytes{namespace!="",pod!=""}) by (namespace,pod)'
      resources:
        overrides:
          namespace: {resource: "namespace"}
          pod: {resource: "pod"}
      name:
        matches: "^(.*)_pod_memory_usage$"
        as: "${1}_memory_usage"
      metricsQuery: 'sum(container_memory_working_set_bytes{namespace="<<.GroupBy.resource.namespace>>",pod="<<.GroupBy.resource.pod>>"}) by (<<.GroupBy>>)'
    
    # 自定义应用指标
    - seriesQuery: 'http_requests_total{app!=""}'
      resources:
        overrides:
          app: {resource: "pod"}
      name:
        matches: "^(.*)_requests_total$"
        as: "${1}_requests_per_second"
      metricsQuery: 'sum(rate(http_requests_total{app="<<.GroupBy.resource.app>>"}[5m])) by (<<.GroupBy>>)'
```

---

## 5. 告警通知配置

### 5.1 Alertmanager 通知配置

```yaml
# k8s/monitoring/alertmanager-config.yaml
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-config
  namespace: monitoring
type: Opaque
stringData:
  alertmanager.yml: |
    global:
      resolve_timeout: 5m
      smtp_smarthost: 'smtp.example.com:587'
      smtp_from: 'alertmanager@example.com'
      smtp_auth_username: 'alertmanager@example.com'
      smtp_auth_password: 'your-password'
      smtp_require_tls: true
    
    # 模板
    templates:
    - '/etc/alertmanager/templates/*.tmpl'
    
    # 路由配置
    route:
      receiver: 'default'
      group_by: ['alertname', 'namespace', 'severity']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      
      # 子路由
      routes:
      # 严重告警
      - match:
          severity: critical
        receiver: 'critical-alerts'
        group_wait: 10s
        repeat_interval: 1h
        continue: true
      
      # 警告告警
      - match:
          severity: warning
        receiver: 'warning-alerts'
        repeat_interval: 4h
      
      # 信息告警
      - match:
          severity: info
        receiver: 'info-alerts'
        repeat_interval: 12h
      
      # 特定应用告警
      - match:
          app: myapp
        receiver: 'myapp-alerts'
        group_by: ['alertname', 'namespace', 'pod']
    
    # 接收者配置
    receivers:
    - name: 'default'
      email_configs:
      - to: 'ops-team@example.com'
        send_resolved: true
        headers:
          subject: '[{{ .Status | toUpper }}] {{ .GroupLabels.alertname }}'
    
    - name: 'critical-alerts'
      email_configs:
      - to: 'critical-alerts@example.com'
        send_resolved: true
      webhook_configs:
      - url: 'http://alertmanager-webhook:9095/webhook'
        send_resolved: true
        http_config:
          bearer_token: 'your-webhook-token'
    
    - name: 'warning-alerts'
      email_configs:
      - to: 'warning-alerts@example.com'
        send_resolved: true
    
    - name: 'info-alerts'
      email_configs:
      - to: 'info-alerts@example.com'
        send_resolved: false
    
    - name: 'myapp-alerts'
      email_configs:
      - to: 'myapp-team@example.com'
        send_resolved: true
      slack_configs:
      - api_url: 'https://hooks.slack.com/services/xxx/yyy/zzz'
        channel: '#myapp-alerts'
        send_resolved: true
        title: '{{ .GroupLabels.alertname }}'
        text: '{{ .CommonAnnotations.description }}'
      pagerduty_configs:
      - service_key: 'your-pagerduty-key'
        severity: '{{ if eq .CommonLabels.severity "critical" }}critical{{ else }}warning{{ end }}'
    
    # 静默规则
    inhibit_rules:
    # 严重告警抑制警告告警
    - source_match:
        severity: 'critical'
      target_match:
        severity: 'warning'
      equal: ['alertname', 'namespace']
    
    # Pod 告警抑制 Deployment 告警
    - source_match:
        alertname: 'PodCrashLooping'
      target_match:
        alertname: 'DeploymentReplicasMismatch'
      equal: ['namespace', 'deployment']
```

### 5.2 钉钉通知 Webhook

```yaml
# k8s/monitoring/dingtalk-webhook.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alertmanager-dingtalk
  namespace: monitoring
spec:
  replicas: 2
  selector:
    matchLabels:
      app: alertmanager-dingtalk
  template:
    metadata:
      labels:
        app: alertmanager-dingtalk
    spec:
      containers:
      - name: dingtalk
        image: timonwong/prometheus-webhook-dingtalk:latest
        args:
        - --config.file=/etc/dingtalk/config.yml
        ports:
        - containerPort: 8060
        volumeMounts:
        - name: config
          mountPath: /etc/dingtalk
      volumes:
      - name: config
        configMap:
          name: dingtalk-config

---
apiVersion: v1
kind: ConfigMap
metadata:
  name: dingtalk-config
  namespace: monitoring
data:
  config.yml: |
    targets:
      ops-team:
        url: https://oapi.dingtalk.com/robot/send?access_token=your-token
        secret: your-secret
        message:
          title: '{{ template "dingtalk.title" . }}'
          text: '{{ template "dingtalk.content" . }}'

---
apiVersion: v1
kind: Service
metadata:
  name: alertmanager-dingtalk
  namespace: monitoring
spec:
  selector:
    app: alertmanager-dingtalk
  ports:
  - port: 8060
    targetPort: 8060
```

### 5.3 飞书通知 Webhook

```yaml
# k8s/monitoring/feishu-webhook.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alertmanager-feishu
  namespace: monitoring
spec:
  replicas: 2
  selector:
    matchLabels:
      app: alertmanager-feishu
  template:
    metadata:
      labels:
        app: alertmanager-feishu
    spec:
      containers:
      - name: feishu
        image: greatgitsby/alertmanager-webhook-feishu:latest
        ports:
        - containerPort: 5001
        env:
        - name: FEISHU_WEBHOOK_URL
          valueFrom:
            secretKeyRef:
              name: feishu-secret
              key: webhook-url
        - name: FEISHU_WEBHOOK_SECRET
          valueFrom:
            secretKeyRef:
              name: feishu-secret
              key: webhook-secret
```

### 5.4 Webhook 接收器

```python
# alertmanager-webhook/receiver.py - Webhook 接收器
from fastapi import FastAPI, Request
import httpx
import json
from datetime import datetime

app = FastAPI()

# 告警处理器
class AlertHandler:
    def __init__(self):
        self.channels = {
            'slack': self.send_slack,
            'dingtalk': self.send_dingtalk,
            'feishu': self.send_feishu,
            'wechat': self.send_wechat,
        }
    
    async def send_slack(self, alert):
        """发送 Slack 通知"""
        async with httpx.AsyncClient() as client:
            await client.post(
                "https://hooks.slack.com/services/xxx/yyy/zzz",
                json={
                    "text": f"🚨 *{alert['labels']['alertname']}*\n"
                           f"Severity: {alert['labels']['severity']}\n"
                           f"Description: {alert['annotations'].get('description', 'N/A')}\n"
                           f"Time: {datetime.now().isoformat()}"
                }
            )
    
    async def send_dingtalk(self, alert):
        """发送钉钉通知"""
        async with httpx.AsyncClient() as client:
            await client.post(
                "https://oapi.dingtalk.com/robot/send?access_token=your-token",
                json={
                    "msgtype": "markdown",
                    "markdown": {
                        "title": f"告警: {alert['labels']['alertname']}",
                        "text": f"### 🚨 {alert['labels']['alertname']}\n"
                               f"- **严重程度**: {alert['labels']['severity']}\n"
                               f"- **描述**: {alert['annotations'].get('description', 'N/A')}\n"
                               f"- **时间**: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n"
                    }
                }
            )
    
    async def send_feishu(self, alert):
        """发送飞书通知"""
        async with httpx.AsyncClient() as client:
            await client.post(
                "https://open.feishu.cn/open-apis/bot/v2/hook/your-token",
                json={
                    "msg_type": "interactive",
                    "card": {
                        "header": {
                            "title": {"tag": "plain_text", "content": f"告警: {alert['labels']['alertname']}"},
                            "template": "red" if alert['labels']['severity'] == 'critical' else "orange"
                        },
                        "elements": [
                            {"tag": "div", "text": {"tag": "lark_md", "content": f"**严重程度**: {alert['labels']['severity']}"}},
                            {"tag": "div", "text": {"tag": "lark_md", "content": f"**描述**: {alert['annotations'].get('description', 'N/A')}"}},
                            {"tag": "div", "text": {"tag": "lark_md", "content": f"**时间**: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"}}
                        ]
                    }
                }
            )

handler = AlertHandler()

@app.post("/webhook")
async def webhook(request: Request):
    """接收 Alertmanager Webhook"""
    data = await request.json()
    
    for alert in data.get('alerts', []):
        # 根据告警标签选择通知渠道
        if alert['labels'].get('severity') == 'critical':
            await handler.send_slack(alert)
            await handler.send_dingtalk(alert)
        elif alert['labels'].get('severity') == 'warning':
            await handler.send_dingtalk(alert)
        else:
            await handler.send_feishu(alert)
    
    return {"status": "ok"}

@app.post("/resolve")
async def resolve(request: Request):
    """处理告警恢复"""
    data = await request.json()
    
    for alert in data.get('alerts', []):
        # 发送恢复通知
        await handler.send_dingtalk(alert)
    
    return {"status": "ok"}
```

### 5.5 告警静默管理

```bash
# 创建静默规则（维护窗口）
curl -X POST http://alertmanager:9093/api/v2/silences \
  -H "Content-Type: application/json" \
  -d '{
    "matchers": [
      {
        "name": "namespace",
        "value": "production",
        "isRegex": false
      }
    ],
    "startsAt": "2024-01-01T02:00:00Z",
    "endsAt": "2024-01-01T04:00:00Z",
    "createdBy": "ops-team",
    "comment": "维护窗口：2024-01-01 02:00-04:00"
  }'

# 查询静默规则
curl http://alertmanager:9093/api/v2/silences

# 删除静默规则
curl -X DELETE http://alertmanager:9093/api/v2/silence/<silence-id>

# 通过 kubectl 管理
kubectl get silences -n monitoring
kubectl delete silence <silence-id> -n monitoring
```

---

## 6. 监控最佳实践

### 6.1 指标命名规范

```
# 命名格式: <namespace>_<subsystem>_<name>_<unit>
# 示例:
http_requests_total          # HTTP 请求总数
http_request_duration_seconds  # HTTP 请求延迟
cpu_usage_percent            # CPU 使用率
memory_usage_bytes           # 内存使用量
disk_io_operations_total     # 磁盘 IO 操作数
```

### 6.2 告警分级

| 级别 | 响应时间 | 通知方式 | 示例 |
|------|----------|----------|------|
| Critical | 5分钟 | 电话+短信+邮件+钉钉 | 服务不可用、数据丢失 |
| Warning | 30分钟 | 邮件+钉钉 | 性能下降、资源紧张 |
| Info | 24小时 | 邮件 | 信息通知、趋势预警 |

### 6.3 监控覆盖检查清单

```yaml
# monitoring-checklist.yaml
checks:
  # 基础设施监控
  - name: "节点 CPU 使用率"
    metric: "100 - (avg(rate(node_cpu_seconds_total{mode='idle'}[5m])) * 100)"
    threshold: 85
    severity: warning
  
  - name: "节点内存使用率"
    metric: "100 - ((node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100)"
    threshold: 90
    severity: critical
  
  - name: "节点磁盘使用率"
    metric: "100 - ((node_filesystem_avail_bytes / node_filesystem_size_bytes) * 100)"
    threshold: 85
    severity: warning
  
  # Kubernetes 监控
  - name: "Pod 重启次数"
    metric: "increase(kube_pod_container_status_restarts_total[1h])"
    threshold: 5
    severity: warning
  
  - name: "Deployment 副本数"
    metric: "kube_deployment_spec_replicas != kube_deployment_status_available_replicas"
    threshold: 1
    severity: critical
  
  # 应用监控
  - name: "HTTP 错误率"
    metric: "sum(rate(http_requests_total{status=~'5..'}[5m])) / sum(rate(http_requests_total[5m])) * 100"
    threshold: 5
    severity: critical
  
  - name: "响应时间 (p95)"
    metric: "histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))"
    threshold: 2
    severity: warning
```

### 6.4 性能优化

```yaml
# Prometheus 性能优化配置
global:
  scrape_interval: 15s
  evaluation_interval: 15s

# 使用录制规则预计算常用查询
rule_files:
  - /etc/prometheus/rules/recording-rules.yml

# recording-rules.yml
groups:
- name: recording-rules
  interval: 30s
  rules:
  # 预计算 HTTP 请求速率
  - record: http_requests:rate5m
    expr: sum(rate(http_requests_total[5m])) by (app, method, status)
  
  # 预计算错误率
  - record: http_errors:ratio5m
    expr: sum(rate(http_requests_total{status=~"5.."}[5m])) by (app) / sum(rate(http_requests_total[5m])) by (app)
  
  # 预计算节点 CPU 使用率
  - record: node_cpu:usage5m
    expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

---

## 小结

本阶段构建了完整的监控告警体系，包括：

1. **Prometheus** - 指标收集、存储、查询
2. **Grafana** - 可视化 Dashboard
3. **Alertmanager** - 告警管理、路由、通知
4. **自定义指标** - 应用指标暴露和采集
5. **告警通知** - 多渠道通知配置

通过这些组件的组合，实现了对 Kubernetes 集群和应用的全面监控，确保及时发现和处理问题。
