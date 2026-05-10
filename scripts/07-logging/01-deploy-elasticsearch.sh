#!/usr/bin/env bash
###############################################################################
# 部署 Elasticsearch 3节点集群
#
# 功能:
#   - 创建 StorageClass 和 PersistentVolume (3x50Gi)
#   - 部署 ConfigMap (ES配置 + JVM选项 + 启动脚本)
#   - 部署 StatefulSet (3节点集群，生产级配置)
#   - 创建 Service (Headless + Client)
#   - 配置 NetworkPolicy (安全隔离)
#   - 创建 Secret (凭证管理)
#
# JVM 配置:
#   - 堆内存: 2G (Xms2g / Xmx2g)
#   - GC: G1GC
#   - 内存锁定: 启用
#
# 使用示例:
#   ./01-deploy-elasticsearch.sh              # 部署到默认命名空间
#   ./01-deploy-elasticsearch.sh -n logging   # 指定命名空间
#
# 配置文件:
#   configs/elk/elasticsearch.yaml            (ES 配置)
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ===== 颜色与日志函数 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') [ES] $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') [ES] $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') [ES] $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') [ES] $*"; }

# ===== 参数解析 =====
NAMESPACE="logging"

while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace|-n) NAMESPACE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# ===== 前置检查 =====
log_info "检查 Elasticsearch 部署前置条件..."

# 检查必需命令
for cmd in kubectl openssl; do
    if ! command -v "$cmd" &>/dev/null; then
        log_error "必需命令未找到: $cmd，请先安装"
        exit 1
    fi
done

# 验证 Kubernetes 集群连接
if ! kubectl cluster-info &>/dev/null; then
    log_error "无法连接到 Kubernetes 集群"
    exit 1
fi

# 验证命名空间
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    log_error "命名空间 $NAMESPACE 不存在，请先创建"
    exit 1
fi
log_ok "命名空间 $NAMESPACE 存在"

# 验证 Longhorn StorageClass 可用
if kubectl get storageclass longhorn &>/dev/null; then
    log_ok "Longhorn StorageClass 已就绪"
else
    log_error "Longhorn StorageClass 不存在！Elasticsearch 需要持久化存储来保存日志数据。"
    log_error "请先部署 Longhorn: kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.5.3/deploy/longhorn.yaml"
    exit 1
fi

# 验证 ES 配置文件
ES_CONFIG="$PROJECT_ROOT/configs/elk/elasticsearch.yaml"
if [[ ! -f "$ES_CONFIG" ]]; then
    log_warn "ES 配置文件不存在: $ES_CONFIG，将使用默认配置"
fi

log_info "部署 Elasticsearch 到命名空间: $NAMESPACE"

# ===== 存储配置 =====
# Longhorn 通过 StorageClass "longhorn" 动态供应 PV，无需手动创建
log_info "确认 Longhorn StorageClass (动态存储供应)..."
if ! kubectl get storageclass longhorn &>/dev/null; then
    log_error "Longhorn StorageClass 缺失，无法动态创建 PVC"
    exit 1
fi
log_ok "Longhorn 动态存储供应已就绪"

# 注意: 无需手动创建 StorageClass 或 PV
# Longhorn 会根据 volumeClaimTemplate 自动创建 3x50Gi 的 PVC 和底层卷

# ===== 创建 ConfigMap: ES 配置 =====
log_info "创建 Elasticsearch ConfigMap..."
if [[ -f "$ES_CONFIG" ]]; then
    kubectl create configmap elasticsearch-config \
        --from-file=elasticsearch.yml="$ES_CONFIG" \
        --namespace="$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
else
    log_warn "跳过 ES 配置 ConfigMap (配置文件不存在)"
fi

# ===== 创建 ConfigMap: JVM 配置 =====
log_info "创建 Elasticsearch JVM ConfigMap..."
cat <<'JVM' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: elasticsearch-jvm
  namespace: logging
data:
  jvm.options: |
    -Xms2g
    -Xmx2g
    -XX:+UseG1GC
    -XX:MaxGCPauseMillis=200
    -XX:+HeapDumpOnOutOfMemoryError
    -XX:HeapDumpPath=/usr/share/elasticsearch/data/heapdump.hprof
    -Djava.io.tmpdir=/usr/share/elasticsearch/data/tmp
    -XX:+UseCompressedOops
    -XX:G1ReservePercent=25
    -XX:InitiatingHeapOccupancyPercent=30
    -XX:G1HeapRegionSize=4m
JVM

# ===== 创建 ConfigMap: 启动脚本 =====
log_info "创建 Elasticsearch 启动脚本 ConfigMap..."
cat <<'INITSCRIPT' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: elasticsearch-init
  namespace: logging
data:
  setup-sysctl.sh: |
    #!/bin/bash
    sysctl -w vm.max_map_count=262144
    sysctl -w net.core.somaxconn=65535
    ulimit -n 65535
    ulimit -l unlimited
    chown -R 1000:1000 /usr/share/elasticsearch/data
INITSCRIPT

# ===== 部署 Elasticsearch StatefulSet =====
log_info "部署 Elasticsearch StatefulSet (3节点)..."
cat <<'MANIFEST' | kubectl apply -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: elasticsearch
  namespace: logging
  labels:
    app: elasticsearch
    tier: logging
spec:
  serviceName: elasticsearch
  replicas: 3
  selector:
    matchLabels:
      app: elasticsearch
  template:
    metadata:
      labels:
        app: elasticsearch
        tier: logging
    spec:
      initContainers:
      - name: setup-sysctl
        image: busybox:1.36
        command: ["sh", "/etc/init/setup-sysctl.sh"]
        volumeMounts:
        - name: init-scripts
          mountPath: /etc/init
        securityContext:
          privileged: true
      - name: fix-permissions
        image: busybox:1.36
        command: ["sh", "-c", "chown -R 1000:1000 /usr/share/elasticsearch/data"]
        volumeMounts:
        - name: es-data
          mountPath: /usr/share/elasticsearch/data
      containers:
      - name: elasticsearch
        image: docker.elastic.co/elasticsearch/elasticsearch:8.11.3
        ports:
        - containerPort: 9200
          name: http
        - containerPort: 9300
          name: transport
        env:
        - name: cluster.name
          value: "logging-cluster"
        - name: node.name
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: discovery.seed_hosts
          value: "elasticsearch-0.elasticsearch,elasticsearch-1.elasticsearch,elasticsearch-2.elasticsearch"
        - name: cluster.initial_master_nodes
          value: "elasticsearch-0,elasticsearch-1,elasticsearch-2"
        - name: ES_JAVA_OPTS
          value: "-Xms2g -Xmx2g -Djava.net.preferIPv4Stack=true"
        - name: xpack.security.enabled
          value: "false"
        - name: xpack.security.enrollment.enabled
          value: "false"
        - name: bootstrap.memory_lock
          value: "true"
        - name: discovery.type
          value: "single-node"
        - name: ELASTIC_PASSWORD
          valueFrom:
            secretKeyRef:
              name: elasticsearch-credentials
              key: password
              optional: true
        resources:
          requests:
            cpu: "1"
            memory: "4Gi"
          limits:
            cpu: "2"
            memory: "4Gi"
        readinessProbe:
          httpGet:
            path: /_cluster/health
            port: 9200
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 30
        livenessProbe:
          httpGet:
            path: /_cluster/health
            port: 9200
          initialDelaySeconds: 60
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 5
        volumeMounts:
        - name: es-data
          mountPath: /usr/share/elasticsearch/data
        - name: elasticsearch-config
          mountPath: /usr/share/elasticsearch/config/elasticsearch.yml
          subPath: elasticsearch.yml
        - name: jvm-options
          mountPath: /usr/share/elasticsearch/config/jvm.options.d/jvm.options
          subPath: jvm.options
        - name: init-scripts
          mountPath: /etc/init
        - name: es-tmp
          mountPath: /usr/share/elasticsearch/data/tmp
      volumes:
      - name: elasticsearch-config
        configMap:
          name: elasticsearch-config
      - name: jvm-options
        configMap:
          name: elasticsearch-jvm
      - name: init-scripts
        configMap:
          name: elasticsearch-init
          defaultMode: 0755
      - name: es-tmp
        emptyDir: {}
      terminationGracePeriodSeconds: 120
  volumeClaimTemplates:
  - metadata:
      name: es-data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: longhorn
      resources:
        requests:
          storage: 50Gi
MANIFEST

# ===== 创建 Service =====
log_info "创建 Elasticsearch Service..."
cat <<'SVC' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: elasticsearch
  namespace: logging
  labels:
    app: elasticsearch
spec:
  ports:
  - port: 9200
    name: http
    targetPort: 9200
  - port: 9300
    name: transport
    targetPort: 9300
  selector:
    app: elasticsearch
  clusterIP: None
  publishNotReadyAddresses: true
---
apiVersion: v1
kind: Service
metadata:
  name: elasticsearch-client
  namespace: logging
  labels:
    app: elasticsearch
spec:
  ports:
  - port: 9200
    name: http
    targetPort: 9200
  selector:
    app: elasticsearch
SVC

# ===== 创建 NetworkPolicy =====
log_info "配置 Elasticsearch NetworkPolicy..."
cat <<'NETPOL' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: elasticsearch-netpol
  namespace: logging
spec:
  podSelector:
    matchLabels:
      app: elasticsearch
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: kibana
    - podSelector:
        matchLabels:
          app: fluentd
    - namespaceSelector:
        matchLabels:
          name: monitoring
    ports:
    - port: 9200
      protocol: TCP
    - port: 9300
      protocol: TCP
  egress:
  - {}  # 允许所有出站 (集群内部DNS等)
NETPOL

# ===== 创建 Secret =====
log_info "创建 Elasticsearch 凭证 Secret..."
kubectl create secret generic elasticsearch-credentials \
    --namespace="$NAMESPACE" \
    --from-literal=password="$(openssl rand -base64 24)" \
    --dry-run=client -o yaml | kubectl apply -f -

# ===== 验证部署 =====
log_info "验证 Elasticsearch 部署..."

# 检查 StatefulSet
if kubectl get statefulset elasticsearch -n "$NAMESPACE" >/dev/null 2>&1; then
    log_ok "Elasticsearch StatefulSet 已创建"

    # 检查 StatefulSet 副本状态
    local ready_replicas
    ready_replicas=$(kubectl get statefulset elasticsearch -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    local desired_replicas
    desired_replicas=$(kubectl get statefulset elasticsearch -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "3")
    log_ok "StatefulSet 副本状态: ${ready_replicas:-0}/${desired_replicas} 就绪"
else
    log_error "Elasticsearch StatefulSet 创建失败"
    exit 1
fi

# 检查 Service
if kubectl get service elasticsearch -n "$NAMESPACE" >/dev/null 2>&1; then
    log_ok "Elasticsearch Service 已创建"
else
    log_warn "Elasticsearch Service 不存在"
fi

# 检查 Secret
if kubectl get secret elasticsearch-credentials -n "$NAMESPACE" >/dev/null 2>&1; then
    log_ok "Elasticsearch Secret 已创建"
else
    log_warn "Elasticsearch Secret 不存在"
fi

# 检查 PVC 状态 (Longhorn 动态创建)
log_info "检查 PersistentVolume Claims..."
local pvc_count
pvc_count=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
if [[ "$pvc_count" -gt 0 ]]; then
    log_ok "PVC 数量: $pvc_count"
    # 列出 PVC 及其状态
    kubectl get pvc -n "$NAMESPACE" -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,STORAGE:.spec.storageClassName,CAPACITY:.status.capacity.storage 2>/dev/null || true
    # 检查是否有 Pending 的 PVC
    local pending_pvc
    pending_pvc=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c "Pending" || true)
    if [[ "$pending_pvc" -gt 0 ]]; then
        log_error "$pending_pvc 个 PVC 处于 Pending 状态，可能需要检查 Longhorn 节点状态"
    fi
else
    log_warn "未找到 PVC，StatefulSet 可能尚未创建卷"
fi

# 检查 Pod 状态
log_info "检查 Pod 状态..."
kubectl get pods -n "$NAMESPACE" -l app=elasticsearch -o wide 2>/dev/null || true

log_ok "Elasticsearch 部署完成"
