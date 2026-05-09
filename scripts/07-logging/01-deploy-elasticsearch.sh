#!/usr/bin/env bash
###############################################################################
# 部署 Elasticsearch 3节点集群
# JVM 2G堆内存，持久化存储，生产级配置
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

log_info "部署 Elasticsearch 到命名空间: $NAMESPACE"

# 创建 StorageClass (如不存在)
cat <<'SC' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: elasticsearch-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
SC

# 创建 PV 用于 Elasticsearch 持久化存储
cat <<'PV' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: es-data-pv-0
spec:
  capacity:
    storage: 50Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: elasticsearch-storage
  hostPath:
    path: /data/elasticsearch/data-0
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: es-data-pv-1
spec:
  capacity:
    storage: 50Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: elasticsearch-storage
  hostPath:
    path: /data/elasticsearch/data-1
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: es-data-pv-2
spec:
  capacity:
    storage: 50Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: elasticsearch-storage
  hostPath:
    path: /data/elasticsearch/data-2
    type: DirectoryOrCreate
PV

# ConfigMap: Elasticsearch 配置
kubectl create configmap elasticsearch-config \
    --from-file=elasticsearch.yml="$PROJECT_ROOT/configs/elk/elasticsearch.yaml" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

# ConfigMap: JVM 配置
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

# ConfigMap: 节点启动脚本
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

# 部署 Elasticsearch StatefulSet
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
      storageClassName: elasticsearch-storage
      resources:
        requests:
          storage: 50Gi
MANIFEST

# 创建 Elasticsearch Service
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

# 创建 NetworkPolicy
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

# 创建 Secret 用于凭证
kubectl create secret generic elasticsearch-credentials \
    --namespace="$NAMESPACE" \
    --from-literal=password="$(openssl rand -base64 24)" \
    --dry-run=client -o yaml | kubectl apply -f -

log_ok "Elasticsearch 部署完成"
