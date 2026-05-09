#!/usr/bin/env bash
###############################################################################
# 部署 Kibana 可视化平台
# 配置ES连接，预置Index Pattern
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }

NAMESPACE="logging"

while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace|-n) NAMESPACE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

log_info "部署 Kibana 到命名空间: $NAMESPACE"

# 创建 Kibana 配置 ConfigMap
cat <<'CONFIGMAP' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: kibana-config
  namespace: logging
  labels:
    app: kibana
data:
  kibana.yml: |
    server.name: kibana
    server.host: "0.0.0.0"
    server.port: 5601
    server.basePath: ""
    server.publicBaseUrl: ""
    monitoring.ui.container.elasticsearch.enabled: true

    # Elasticsearch 连接配置
    elasticsearch.hosts: ["http://elasticsearch-logging:9200"]
    elasticsearch.username: "elastic"
    elasticsearch.password: "${ELASTICSEARCH_PASSWORD}"
    elasticsearch.ssl.verificationMode: none

    # 日志配置
    logging.root.level: info
    logging.appenders.file.type: file
    logging.appenders.file.fileName: /usr/share/kibana/logs/kibana.log
    logging.appenders.file.layout.type: json

    # 性能优化
    ops.interval: 30000
    i18n.locale: "zh-CN"
    i18n.fallbackLocale: "en"
CONFIGMAP

# 部署 Kibana Deployment
cat <<'MANIFEST' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kibana
  namespace: logging
  labels:
    app: kibana
    tier: logging
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kibana
  template:
    metadata:
      labels:
        app: kibana
        tier: logging
    spec:
      containers:
      - name: kibana
        image: docker.elastic.co/kibana/kibana:8.11.3
        ports:
        - containerPort: 5601
          name: http
        env:
        - name: ELASTICSEARCH_HOSTS
          value: "http://elasticsearch.logging.svc.cluster.local:9200"
        - name: ELASTICSEARCH_USERNAME
          value: "elastic"
        - name: ELASTICSEARCH_PASSWORD
          valueFrom:
            secretKeyRef:
              name: elasticsearch-credentials
              key: password
              optional: true
        - name: KIBANA_SYSTEM_PASSWORD
          valueFrom:
            secretKeyRef:
              name: kibana-credentials
              key: password
              optional: true
        resources:
          requests:
            cpu: 500m
            memory: 1Gi
          limits:
            cpu: "1"
            memory: 2Gi
        readinessProbe:
          httpGet:
            path: /api/status
            port: 5601
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 30
        livenessProbe:
          httpGet:
            path: /api/status
            port: 5601
          initialDelaySeconds: 60
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 5
        volumeMounts:
        - name: kibana-data
          mountPath: /usr/share/kibana/data
        - name: kibana-logs
          mountPath: /usr/share/kibana/logs
      volumes:
      - name: kibana-data
        emptyDir: {}
      - name: kibana-logs
        emptyDir: {}
MANIFEST

# 创建 Kibana Service
cat <<'SVC' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: kibana
  namespace: logging
  labels:
    app: kibana
spec:
  ports:
  - port: 5601
    name: http
    targetPort: 5601
  selector:
    app: kibana
---
apiVersion: v1
kind: Service
metadata:
  name: kibana-external
  namespace: logging
  labels:
    app: kibana
spec:
  type: NodePort
  ports:
  - port: 5601
    name: http
    targetPort: 5601
    nodePort: 30561
  selector:
    app: kibana
SVC

# 创建 NetworkPolicy
cat <<'NETPOL' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kibana-netpol
  namespace: logging
spec:
  podSelector:
    matchLabels:
      app: kibana
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: monitoring
    - ipBlock:
        cidr: 0.0.0.0/0
    ports:
    - port: 5601
      protocol: TCP
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: elasticsearch
    ports:
    - port: 9200
      protocol: TCP
  - {}  # DNS
NETPOL

# 创建用于存储 Index Pattern 配置的 ConfigMap
cat <<'PATTERN' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: kibana-index-patterns
  namespace: logging
  labels:
    app: kibana
data:
  index-patterns.json: |
    {
      "patterns": [
        {
          "id": "kubernetes-logs",
          "title": "kubernetes-*",
          "timeFieldName": "@timestamp",
          "description": "Kubernetes 容器日志"
        },
        {
          "id": "system-logs",
          "title": "system-logs-*",
          "timeFieldName": "@timestamp",
          "description": "系统日志"
        },
        {
          "id": "auth-logs",
          "title": "auth-logs-*",
          "timeFieldName": "@timestamp",
          "description": "认证日志"
        }
      ],
      "defaultIndexPattern": "kubernetes-*"
    }
PATTERN

# 创建用于初始化 Kibana 的 Job
cat <<'JOB' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kibana-init
  namespace: logging
  labels:
    app: kibana
spec:
  backoffLimit: 3
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app: kibana-init
    spec:
      restartPolicy: OnFailure
      containers:
      - name: kibana-init
        image: curlimages/curl:latest
        command:
        - /bin/sh
        - -c
        - |
          echo "Waiting for Kibana to be ready..."
          for i in $(seq 1 60); do
            if curl -s http://kibana.logging.svc.cluster.local:5601/api/status | grep -q '"available"'; then
              echo "Kibana is ready!"
              break
            fi
            echo "Attempt $i/60..."
            sleep 10
          done
          
          echo "Creating index patterns..."
          
          # 创建 Kubernetes 日志索引模式
          curl -X POST "http://kibana.logging.svc.cluster.local:5601/api/saved_objects/index-pattern/kubernetes-*" \
            -H "kbn-xsrf: true" \
            -H "Content-Type: application/json" \
            -d '{
              "attributes": {
                "title": "kubernetes-*",
                "timeFieldName": "@timestamp",
                "description": "Kubernetes 容器日志"
              }
            }' || true
          
          # 创建系统日志索引模式
          curl -X POST "http://kibana.logging.svc.cluster.local:5601/api/saved_objects/index-pattern/system-logs-*" \
            -H "kbn-xsrf: true" \
            -H "Content-Type: application/json" \
            -d '{
              "attributes": {
                "title": "system-logs-*",
                "timeFieldName": "@timestamp",
                "description": "系统日志"
              }
            }' || true
          
          # 创建认证日志索引模式
          curl -X POST "http://kibana.logging.svc.cluster.local:5601/api/saved_objects/index-pattern/auth-logs-*" \
            -H "kbn-xsrf: true" \
            -H "Content-Type: application/json" \
            -d '{
              "attributes": {
                "title": "auth-logs-*",
                "timeFieldName": "@timestamp",
                "description": "认证日志"
              }
            }' || true
          
          # 设置默认索引模式
          curl -X POST "http://kibana.logging.svc.cluster.local:5601/api/kibana/settings/defaultIndex" \
            -H "kbn-xsrf: true" \
            -H "Content-Type: application/json" \
            -d '{"value": "kubernetes-*"}' || true
          
          echo "Index patterns created successfully!"
JOB

# 创建 Secret
kubectl create secret generic kibana-credentials \
    --namespace="$NAMESPACE" \
    --from-literal=password="$(openssl rand -base64 24)" \
    --dry-run=client -o yaml | kubectl apply -f -

log_ok "Kibana 部署完成"
log_info "Kibana 将在 Pod 就绪后自动创建 Index Patterns"
