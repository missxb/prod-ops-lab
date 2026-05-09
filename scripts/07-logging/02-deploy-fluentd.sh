#!/usr/bin/env bash
###############################################################################
# 部署 Fluentd 日志收集 DaemonSet
#
# 功能:
#   - 创建 ServiceAccount 和 RBAC 权限
#   - 部署 Fluentd 配置 (容器日志 + 系统日志 + 认证日志)
#   - 配置 Elasticsearch 索引模板
#   - 部署 Fluentd DaemonSet (每节点一个 Pod)
#   - 创建监控 Service
#
# 日志源:
#   - /var/log/containers/*.log (Kubernetes 容器日志)
#   - /var/log/syslog, /var/log/messages (系统日志)
#   - /var/log/auth.log, /var/log/secure (认证日志)
#
# 输出目标:
#   - kubernetes-* (容器日志)
#   - system-logs (系统日志)
#   - auth-logs (认证日志)
#
# 使用示例:
#   ./02-deploy-fluentd.sh                    # 部署到默认命名空间
#   ./02-deploy-fluentd.sh -n logging         # 指定命名空间
#
# 配置文件:
#   configs/elk/fluentd-config.yaml          (Fluentd 配置)
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

log_info()  { echo -e "${BLUE}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') [Fluentd] $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') [Fluentd] $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') [Fluentd] $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') [Fluentd] $*"; }

# ===== 参数解析 =====
NAMESPACE="logging"

while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace|-n) NAMESPACE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# ===== 前置检查 =====
log_info "检查 Fluentd 部署前置条件..."

# 验证命名空间
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    log_error "命名空间 $NAMESPACE 不存在"
    exit 1
fi
log_ok "命名空间 $NAMESPACE 存在"

# 验证 Fluentd 配置文件
FLUENTD_CONFIG="$PROJECT_ROOT/configs/elk/fluentd-config.yaml"
if [[ ! -f "$FLUENTD_CONFIG" ]]; then
    log_warn "Fluentd 配置文件不存在: $FLUENTD_CONFIG，将使用内嵌配置"
fi

log_info "部署 Fluentd DaemonSet 到命名空间: $NAMESPACE"

# ===== 创建 ServiceAccount 和 RBAC =====
log_info "创建 Fluentd ServiceAccount 和 RBAC..."
cat <<'RBAC' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fluentd
  namespace: logging
  labels:
    app: fluentd
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: fluentd
  labels:
    app: fluentd
rules:
- apiGroups: [""]
  resources:
  - pods
  - namespaces
  - nodes
  - nodes/proxy
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: fluentd
  labels:
    app: fluentd
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: fluentd
subjects:
- kind: ServiceAccount
  name: fluentd
  namespace: logging
RBAC

# ===== 创建 Fluentd 配置 ConfigMap =====
log_info "创建 Fluentd ConfigMap..."
if [[ -f "$FLUENTD_CONFIG" ]]; then
    kubectl create configmap fluentd-config \
        --from-file=fluent.conf="$FLUENTD_CONFIG" \
        --namespace="$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
else
    log_warn "跳过外部配置文件加载，使用内嵌配置"
fi

# ===== 创建 Fluentd 配置 =====
log_info "创建 Fluentd 配置 ConfigMap (内嵌配置)..."
cat <<'CONFIGMAP' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluentd-config-files
  namespace: logging
  labels:
    app: fluentd
data:
  fluent.conf: |
    # ===== 输入源 =====
    # 容器日志
    <source>
      @type tail
      @id in_tail_container_logs
      path /var/log/containers/*.log
      pos_file /var/log/fluentd-containers.log.pos
      tag kubernetes.*
      exclude_path ["/var/log/containers/fluentd*"]
      read_from_head true
      <parse>
        @type multi_format
        <pattern>
          format json
          time_key time
          time_format %Y-%m-%dT%H:%M:%S.%NZ
          keep_time_key true
        </pattern>
        <pattern>
          format regexp
          expression /^(?<time>.+) (?<stream>stdout|stderr) [^ ]* (?<log>.*)$/
          time_format %Y-%m-%dT%H:%M:%S.%N%:z
        </pattern>
      </parse>
    </source>

    # 系统日志
    <source>
      @type tail
      @id in_tail_syslog
      path /var/log/syslog,/var/log/messages
      pos_file /var/log/fluentd-syslog.log.pos
      tag system.*
      <parse>
        @type syslog
      </parse>
    </source>

    # 认证日志
    <source>
      @type tail
      @id in_tail_auth
      path /var/log/auth.log,/var/log/secure
      pos_file /var/log/fluentd-auth.log.pos
      tag auth.*
      <parse>
        @type syslog
      </parse>
    </source>

    # ===== Kubernetes 元数据过滤 =====
    <filter kubernetes.**>
      @type kubernetes_metadata
      @id filter_kube_metadata
      kubernetes_url "https://#{ENV['KUBERNETES_SERVICE_HOST']}:#{ENV['KUBERNETES_SERVICE_PORT']}"
      verify_ssl true
      ca_file /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
      bearer_token_file /var/run/secrets/kubernetes.io/serviceaccount/token
      skip_labels false
      skip_container_metadata false
      skip_master_url true
      skip_namespace_metadata false
    </filter>

    # ===== 日志过滤与处理 =====
    # 过滤空日志
    <filter kubernetes.**>
      @type grep
      <exclude>
        key log
        pattern /^\s*$/
      </exclude>
    </filter>

    # 添加日志级别检测
    <filter kubernetes.**>
      @type record_transformer
      enable_ruby true
      <record>
        log_level ${record["log"] =~ /ERROR|FATAL|CRITICAL/i ? "error" : record["log"] =~ /WARN/i ? "warn" : record["log"] =~ /INFO/i ? "info" : record["log"] =~ /DEBUG/i ? "debug" : "unknown"}
        timestamp ${Time.now.iso8601}
        hostname ${Socket.gethostname}
      </record>
    </filter>

    # 添加索引日期
    <filter kubernetes.**>
      @type record_transformer
      enable_ruby true
      <record>
        index_date ${Time.now.strftime("%Y.%m.%d")}
      </record>
    </filter>

    # ===== 输出到 Elasticsearch =====
    <match kubernetes.**>
      @type elasticsearch
      @id out_es_kubernetes
      @log_level info
      host elasticsearch.logging.svc.cluster.local
      port 9200
      scheme http
      user elastic
      password "#{ENV['ELASTIC_PASSWORD']}"
      index_name kubernetes-${tag_parts[2]}
      type_name _doc
      include_tag_key true
      tag_key @log_name

      # 索引模板
      template_name kubernetes
      template_overwrite true
      template_file /etc/fluentd/templates/kubernetes-template.json

      # 缓冲区配置
      <buffer>
        @type file
        path /var/log/fluentd-buffers/kubernetes.buffer
        flush_mode interval
        flush_interval 30s
        flush_thread_count 2
        retry_type exponential_backoff
        retry_forever true
        retry_max_interval 300
        chunk_limit_size 5M
        total_limit_size 2G
        overflow_action block
        compress gzip
      </buffer>
    </match>

    <match system.**>
      @type elasticsearch
      @id out_es_system
      host elasticsearch.logging.svc.cluster.local
      port 9200
      scheme http
      user elastic
      password "#{ENV['ELASTIC_PASSWORD']}"
      index_name system-logs
      type_name _doc

      <buffer>
        @type file
        path /var/log/fluentd-buffers/system.buffer
        flush_mode interval
        flush_interval 30s
        flush_thread_count 2
        retry_type exponential_backoff
        retry_forever true
        chunk_limit_size 2M
        total_limit_size 1G
        compress gzip
      </buffer>
    </match>

    <match auth.**>
      @type elasticsearch
      @id out_es_auth
      host elasticsearch.logging.svc.cluster.local
      port 9200
      scheme http
      user elastic
      password "#{ENV['ELASTIC_PASSWORD']}"
      index_name auth-logs
      type_name _doc

      <buffer>
        @type file
        path /var/log/fluentd-buffers/auth.buffer
        flush_mode interval
        flush_interval 15s
        retry_type exponential_backoff
        retry_forever true
        chunk_limit_size 1M
        total_limit_size 512M
        compress gzip
      </buffer>
    </match>

    # ===== 监控 =====
    <source>
      @type monitor_agent
      @id monitor_agent
      bind 0.0.0.0
      port 24220
    </source>
CONFIGMAP

# ===== 创建 Elasticsearch 索引模板 =====
log_info "创建 Elasticsearch 索引模板..."
cat <<'TEMPLATE' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluentd-templates
  namespace: logging
  labels:
    app: fluentd
data:
  kubernetes-template.json: |
    {
      "index_patterns": ["kubernetes-*"],
      "version": 80001,
      "settings": {
        "number_of_shards": 2,
        "number_of_replicas": 1,
        "index.lifecycle.name": "kubernetes-policy",
        "index.lifecycle.rollover_alias": "kubernetes"
      },
      "mappings": {
        "properties": {
          "@timestamp": { "type": "date" },
          "log": { "type": "text" },
          "stream": { "type": "keyword" },
          "kubernetes": {
            "properties": {
              "pod_name": { "type": "keyword" },
              "namespace_name": { "type": "keyword" },
              "container_name": { "type": "keyword" },
              "labels": { "type": "object", "enabled": false },
              "host": { "type": "keyword" }
            }
          },
          "log_level": { "type": "keyword" }
        }
      }
    }
TEMPLATE

# ===== 部署 Fluentd DaemonSet =====
log_info "部署 Fluentd DaemonSet..."
cat <<'MANIFEST' | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluentd
  namespace: logging
  labels:
    app: fluentd
    tier: logging
spec:
  selector:
    matchLabels:
      app: fluentd
  template:
    metadata:
      labels:
        app: fluentd
        tier: logging
    spec:
      serviceAccountName: fluentd
      tolerations:
      - key: node-role.kubernetes.io/master
        effect: NoSchedule
      - key: node-role.kubernetes.io/control-plane
        effect: NoSchedule
      - operator: Exists
        effect: NoSchedule
      containers:
      - name: fluentd
        image: fluent/fluentd-kubernetes-daemonset:v1.16-debian-elasticsearch8-1
        imagePullPolicy: IfNotPresent
        env:
        - name: FLUENT_ELASTICSEARCH_HOST
          value: "elasticsearch.logging.svc.cluster.local"
        - name: FLUENT_ELASTICSEARCH_PORT
          value: "9200"
        - name: FLUENT_ELASTICSEARCH_SCHEME
          value: "http"
        - name: FLUENT_ELASTICSEARCH_USER
          value: "elastic"
        - name: ELASTIC_PASSWORD
          valueFrom:
            secretKeyRef:
              name: elasticsearch-credentials
              key: password
              optional: true
        - name: FLUENT_ELASTICSEARCH_SSL_VERIFY
          value: "false"
        - name: FLUENT_ELASTICSEARCH_SSL_VERSION
          value: "TLSv1_2"
        - name: KUBERNETES_SERVICE_HOST
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: KUBERNETES_SERVICE_PORT
          value: "6443"
        resources:
          requests:
            cpu: 200m
            memory: 512Mi
          limits:
            cpu: 500m
            memory: 1Gi
        volumeMounts:
        - name: varlog
          mountPath: /var/log
          readOnly: true
        - name: containers
          mountPath: /var/lib/docker/containers
          readOnly: true
        - name: fluentd-config
          mountPath: /fluentd/etc/fluent.conf
          subPath: fluent.conf
        - name: fluentd-buffer
          mountPath: /var/log/fluentd-buffers
        - name: fluentd-templates
          mountPath: /etc/fluentd/templates
        - name: pos-files
          mountPath: /var/log/fluentd-containers.log.pos
          subPath: fluentd-containers.log.pos
        ports:
        - containerPort: 24220
          name: monitor
          protocol: TCP
        livenessProbe:
          httpGet:
            path: /metrics
            port: 24220
          initialDelaySeconds: 30
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /metrics
            port: 24220
          initialDelaySeconds: 10
          periodSeconds: 10
      volumes:
      - name: varlog
        hostPath:
          path: /var/log
          type: Directory
      - name: containers
        hostPath:
          path: /var/lib/docker/containers
          type: Directory
      - name: fluentd-config
        configMap:
          name: fluentd-config-files
      - name: fluentd-buffer
        hostPath:
          path: /var/log/fluentd-buffers
          type: DirectoryOrCreate
      - name: fluentd-templates
        configMap:
          name: fluentd-templates
      - name: pos-files
        hostPath:
          path: /var/log/fluentd-containers.log.pos
          type: FileOrCreate
      terminationGracePeriodSeconds: 30
MANIFEST

# ===== 创建 Fluentd Service (用于监控) =====
log_info "创建 Fluentd 监控 Service..."
cat <<'SVC' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: fluentd-monitor
  namespace: logging
  labels:
    app: fluentd
spec:
  ports:
  - port: 24220
    name: monitor
    targetPort: 24220
  selector:
    app: fluentd
SVC

# ===== 验证部署 =====
log_info "验证 Fluentd 部署..."

# 检查 DaemonSet
if kubectl get daemonset fluentd -n "$NAMESPACE" >/dev/null 2>&1; then
    log_ok "Fluentd DaemonSet 已创建"
else
    log_error "Fluentd DaemonSet 创建失败"
    exit 1
fi

# 检查 ConfigMap
if kubectl get configmap fluentd-config-files -n "$NAMESPACE" >/dev/null 2>&1; then
    log_ok "Fluentd ConfigMap 已创建"
else
    log_warn "Fluentd ConfigMap 不存在"
fi

# 检查 RBAC
if kubectl get serviceaccount fluentd -n "$NAMESPACE" >/dev/null 2>&1; then
    log_ok "Fluentd ServiceAccount 已创建"
else
    log_warn "Fluentd ServiceAccount 不存在"
fi

log_ok "Fluentd DaemonSet 部署完成"
