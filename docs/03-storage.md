# 阶段3：存储层配置详细文档

## 文档信息
- 版本：v1.0
- 更新日期：2026-05-09
- 维护团队：云原生平台运维组

---

## 1. 阶段目标

完成企业级云原生运维平台的存储层建设，包括：
- 分布式存储系统部署（Longhorn / Ceph）
- StorageClass 配置与管理
- 动态存储供给（Dynamic Provisioning）
- 持久卷（PV/PVC）管理策略
- 存储快照与备份
- 存储性能优化
- 存储监控与告警

## 2. 架构说明

```
┌─────────────────────────────────────────────────────────────────┐
│                      存储架构总览                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                   Kubernetes 集群                         │    │
│  │                                                         │    │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐                  │    │
│  │  │ Worker1 │  │ Worker2 │  │ Worker3 │                  │    │
│  │  │ 100GB   │  │ 100GB   │  │ 100GB   │                  │    │
│  │  └────┬────┘  └────┬────┘  └────┬────┘                  │    │
│  │       │            │            │                        │    │
│  │  ┌────┴────────────┴────────────┴────┐                   │    │
│  │  │     CSI Driver (Longhorn/Ceph)    │                   │    │
│  │  │     ┌─────────────────────┐       │                   │    │
│  │  │     │   StorageClass      │       │                   │    │
│  │  │     │   - longhorn        │       │                   │    │
│  │  │     │   - ceph-rbd        │       │                   │    │
│  │  │     │   - cephfs          │       │                   │    │
│  │  │     └─────────────────────┘       │                   │    │
│  │  └───────────────────────────────────┘                   │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                   存储后端                                │    │
│  │                                                         │    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │    │
│  │  │   Longhorn  │  │  Ceph (RBD) │  │  CephFS     │     │    │
│  │  │  轻量分布式  │  │  块存储      │  │  文件存储    │     │    │
│  │  │  副本复制    │  │  高性能      │  │  共享存储    │     │    │
│  │  └─────────────┘  └─────────────┘  └─────────────┘     │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                   备份与恢复                              │    │
│  │  - etcd 备份      - PV 快照       - 远程备份             │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

### 存储类型对比
| 特性 | Longhorn | Ceph RBD | CephFS | NFS |
|------|----------|----------|--------|-----|
| 类型 | 块存储 | 块存储 | 文件存储 | 文件存储 |
| 性能 | 中等 | 高 | 中等 | 中等 |
| 部署复杂度 | 低 | 高 | 高 | 低 |
| 适用场景 | 有状态应用 | 数据库 | 共享数据 | 共享数据 |
| 快照支持 | 是 | 是 | 是 | 否 |
| 多节点访问 | 否 | 否 | 是 | 是 |

## 3. 前置条件

- 阶段2（K8s 集群部署）已完成
- 至少 3 个 Worker 节点
- 每个节点有额外磁盘用于存储（建议 SSD，至少 100GB）
- 节点间网络带宽 >= 1Gbps
- 已安装 Helm（包管理器）
- 已配置存储网络（推荐独立网段）

## 4. 详细步骤

### 4.1 安装 Helm（如果没有）

```bash
# Helm 是 K8s 的包管理器，简化存储组件安装
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# 验证
helm version
# version.BuildInfo{Version:"v3.14.0", ...}

# 添加常用仓库
helm repo add longhorn https://charts.longhorn.io
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
```

### 4.2 安装 Longhorn（推荐轻量方案）

#### 4.2.1 前置依赖安装

```bash
# Longhorn 依赖一些系统工具
# 在所有节点安装
apt-get install -y \
    open-iscsi \
    nfs-common \
    util-linux \
    curl \
    jq

# 启动 iSCSI 服务
systemctl enable --now iscsid

# 验证
systemctl status iscsid
# Active: active (running)
```

#### 4.2.2 安装 Longhorn

```bash
# 创建 longhorn-system namespace
kubectl create namespace longhorn-system

# 使用 Helm 安装 Longhorn
helm install longhorn longhorn/longhorn \
    --namespace longhorn-system \
    --set defaultSettings.defaultDataPath="/mnt/longhorn" \
    --set defaultSettings.defaultReplicaCount=3 \
    --set defaultSettings.defaultDataLocality="best-effort" \
    --set defaultSettings.staleReplicaTimeout=30 \
    --set defaultSettings.createDefaultDiskLabeledNodes=true \
    --set defaultSettings.defaultDiskSelector.enable=true \
    --set defaultSettings.defaultDiskSelector.nodeSelector="*" \
    --set persistence.defaultClassReplicaCount=3 \
    --set persistence.reclaimPolicy=Delete \
    --set ingress.enabled=true \
    --set ingress.host="longhorn.example.com" \
    --version 1.6.0

# 等待 Longhorn 组件就绪
kubectl -n longhorn-system rollout status daemonset/longhorn-manager --timeout=600s
kubectl -n longhorn-system rollout status deployment/longhorn-driver-deployer --timeout=600s

# 验证安装
kubectl -n longhorn-system get pods
# NAME                                                READY   STATUS    RESTARTS   AGE
# longhorn-manager-xxxxx                              2/2     Running   0          5m
# longhorn-manager-yyyyy                              2/2     Running   0          5m
# longhorn-manager-zzzzz                              2/2     Running   0          5m
# longhorn-driver-deployer-xxxxx                      1/1     Running   0          5m
# longhorn-csi-plugin-xxxxx                           3/3     Running   0          4m
# longhorn-csi-provisioner-xxxxx                      3/3     Running   0          4m
```

#### 4.2.3 配置 Longhorn UI

```bash
# 访问 Longhorn UI（可选，也可通过 Ingress 访问）
# 端口转发方式
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80 &

# 在浏览器访问 http://localhost:8080
# UI 中可以看到：
# - 所有节点的磁盘状态
# - 卷（Volume）列表
# - 快照管理
# - 备份管理
```

### 4.3 配置 StorageClass

#### 4.3.1 创建 Longhorn StorageClass

```yaml
# longhorn-storageclass.yaml
# 定义存储类型，应用通过 StorageClass 请求存储
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn
  annotations:
    # 设置为默认 StorageClass
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: driver.longhorn.io
parameters:
  # 副本数 —— 决定数据冗余级别
  numberOfReplica: "3"
  # 数据本地性 —— best-effort 将副本放在调度 Pod 的节点
  dataLocality: "best-effort"
  # 文件系统类型
  fsType: "ext4"
  # 卷加密（可选）
  encrypted: "false"
# 回收策略 —— PVC 删除时自动删除 PV 和数据
reclaimPolicy: Delete
# 允许卷扩展 —— 支持在线扩容
allowVolumeExpansion: true
# 卷绑定模式 —— WaitForFirstConsumer 确保 Pod 调度后再绑定
volumeBindingMode: WaitForFirstConsumer
```

#### 4.3.2 创建高性能 StorageClass（可选）

```yaml
# longhorn-fast-storageclass.yaml
# 针对数据库等高性能场景
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-fast
provisioner: driver.longhorn.io
parameters:
  # 高性能配置
  numberOfReplica: "2"  # 较少副本提高性能
  dataLocality: "strict-local"  # 强制本地存储
  fsType: "ext4"
reclaimPolicy: Retain  # 保留策略，防止误删数据
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
```

#### 4.3.3 创建共享存储 StorageClass

```yaml
# longhorn-shared-storageclass.yaml
# 用于需要多节点同时访问的场景
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-shared
provisioner: driver.longhorn.io
parameters:
  # NFS 共享模式
  numberOfReplica: "3"
  fromBackup: ""
  # 启用 NFS 共享
  nfs: "true"
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
```

#### 4.3.4 应用 StorageClass

```bash
# 应用配置
kubectl apply -f longhorn-storageclass.yaml
kubectl apply -f longhorn-fast-storageclass.yaml
kubectl apply -f longhorn-shared-storageclass.yaml

# 验证
kubectl get storageclass
# NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ...
# longhorn (default)   driver.longhorn.io      Delete          WaitForFirstConsumer   ...
# longhorn-fast        driver.longhorn.io      Retain          WaitForFirstConsumer   ...
# longhorn-shared      driver.longhorn.io      Delete          Immediate              ...
```

### 4.4 创建 PVC 示例

#### 4.4.1 通用 PVC

```yaml
# example-pvc.yaml
# 通用持久化存储，用于一般有状态应用
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: example-pvc
  namespace: default
spec:
  # 引用 StorageClass
  accessModes:
    - ReadWriteOnce  # 单节点读写
  resources:
    requests:
      storage: 10Gi  # 请求 10GB 存储
  # 指定 StorageClass（可选，使用默认）
  storageClassName: longhorn
```

#### 4.4.2 数据库存储 PVC

```yaml
# postgres-pvc.yaml
# PostgreSQL 数据库存储，需要高可靠性
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data-pvc
  namespace: databases
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
  storageClassName: longhorn-fast
```

#### 4.4.3 日志存储 PVC

```yaml
# logging-pvc.yaml
# 日志存储，需要较大空间和快速写入
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: elasticsearch-data-pvc
  namespace: logging
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi
  storageClassName: longhorn
```

#### 4.4.4 应用 PVC

```bash
# 创建命名空间
kubectl create namespace databases
kubectl create namespace logging

# 应用 PVC
kubectl apply -f example-pvc.yaml
kubectl apply -f postgres-pvc.yaml
kubectl apply -f logging-pvc.yaml

# 验证 PVC 状态
kubectl get pvc -A
# NAME                  STATUS   VOLUME                                     CAPACITY   ...
# example-pvc           Bound    pvc-a1b2c3d4-e5f6-7890-abcd-ef1234567890   10Gi       ...
# postgres-data-pvc     Bound    pvc-b2c3d4e5-f6a7-8901-bcde-f12345678901   50Gi       ...
# elasticsearch-data-pvc Bound   pvc-c3d4e5f6-a7b8-9012-cdef-123456789012   100Gi      ...
```

### 4.5 使用 PVC 示例

#### 4.5.1 单 Pod 使用 PVC

```yaml
# pod-with-pvc.yaml
# 演示如何在 Pod 中挂载 PVC
apiVersion: v1
kind: Pod
metadata:
  name: app-with-storage
  namespace: default
spec:
  containers:
    - name: app
      image: nginx:latest
      # 挂载 PVC 到容器
      volumeMounts:
        - name: storage-volume
          mountPath: /usr/share/nginx/html  # 容器内路径
          readOnly: false
      # 资源限制
      resources:
        requests:
          memory: "64Mi"
          cpu: "50m"
        limits:
          memory: "128Mi"
          cpu: "100m"
  volumes:
    - name: storage-volume
      persistentVolumeClaim:
        claimName: example-pvc  # 引用 PVC 名称
```

#### 4.5.2 StatefulSet 使用 PVC

```yaml
# statefulset-with-pvc.yaml
# 有状态应用使用 PVC，每个副本独立存储
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: databases
spec:
  serviceName: postgres
  replicas: 3
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:15
          env:
            - name: POSTGRES_DB
              value: myapp
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: postgres-secrets
                  key: username
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-secrets
                  key: password
          volumeMounts:
            - name: postgres-data
              mountPath: /var/lib/postgresql/data  # PostgreSQL 数据目录
          resources:
            requests:
              memory: "512Mi"
              cpu: "500m"
            limits:
              memory: "2Gi"
              cpu: "2"
  volumeClaimTemplates:
    # 为每个 Pod 创建独立的 PVC
    - metadata:
        name: postgres-data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: longhorn-fast
        resources:
          requests:
            storage: 50Gi
```

### 4.6 存储快照管理

#### 4.6.1 安装 VolumeSnapshot CRD

```bash
# 安装 VolumeSnapshot CRD —— K8s 1.20+ 原生支持
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.3.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.3.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.3.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml

# 安装 snapshot-controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.3.0/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.3.0/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml
```

#### 4.6.2 创建 VolumeSnapshotClass

```yaml
# volumesnapshotclass.yaml
# 定义快照策略和存储后端
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: longhorn-snapshot
  labels:
    velero.io/csi-volumesnapshot-class: "true"
driver: driver.longhorn.io
deletionPolicy: Retain  # 保留快照，防止误删
parameters:
  # Longhorn 快照参数
  type: "snap"  # 快照类型
  # 可选：设置快照标签
```

#### 4.6.3 创建手动快照

```yaml
# manual-snapshot.yaml
# 手动创建 PVC 快照
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: postgres-snapshot-manual
  namespace: databases
spec:
  volumeSnapshotClassName: longhorn-snapshot
  source:
    # 指定要快照的 PVC
    persistentVolumeClaimName: postgres-data-pvc
```

#### 4.6.4 自动快照（Velero）

```bash
# 安装 Velero —— 企业级备份和恢复工具
# 下载 Velero CLI
wget https://github.com/vmware-tanzu/velero/releases/download/v1.13.0/velero-v1.13.0-linux-amd64.tar.gz
tar xzf velero-v1.13.0-linux-amd64.tar.gz
cp velero-v1.13.0-linux-amd64/velero /usr/local/bin/

# 使用 MinIO 作为备份存储（本地 S3 兼容存储）
# 启动 MinIO
docker run -d \
    --name minio \
    -p 9000:9000 \
    -p 9001:9001 \
    -e MINIO_ROOT_USER=minioadmin \
    -e MINIO_ROOT_PASSWORD=minioadmin \
    -v /data/minio:/data \
    minio/minio server /data --console-address :9001

# 创建 MinIO bucket
mc alias set local http://localhost:9000 minioadmin minioadmin
mc mb local/velero-backups

# 安装 Velero
velero install \
    --provider aws \
    --plugins velero/velero-plugin-for-aws:v1.8.0 \
    --bucket velero-backups \
    --secret-file ./credentials-velero \
    --backup-location-config region=minio,s3ForcePathStyle=true,s3Url=http://minio.velero.svc:9000 \
    --snapshot-location-config region=minio

# 创建自动备份计划
velero schedule create daily-backup \
    --schedule="@every 24h" \
    --ttl 720h \
    --include-namespaces default,databases,logging

# 查看备份
velero get backups
```

### 4.7 存储性能优化

#### 4.7.1 IO 调度器优化

```bash
# 检查当前 IO 调度器
cat /sys/block/sda/queue/scheduler
# noop [mq-deadline] bfq none

# 设置为 deadline（适合数据库）
echo mq-deadline > /sys/block/sda/queue/scheduler

# 永久设置
cat > /etc/udev/rules.d/60-io-scheduler.rules << 'EOF'
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
EOF
```

#### 4.7.2 文件系统优化

```bash
# ext4 优化（默认文件系统）
# 在创建卷时使用优化参数
# Longhorn 创建的卷已经是优化配置

# 检查文件系统状态
df -Th /mnt/longhorn
# Filesystem     Type  Size  Used Avail Use% Mounted on
# /dev/longhorn/ pvc-xxx ext4  10G   50M  9.9G   1% /mnt/longhorn

# 调整挂载选项
# 在 StorageClass 中添加参数
# parameters:
#   mountOptions: "noatime,nodiratime"
```

#### 4.7.3 缓存配置

```bash
# 设置页面缓存
echo 10 > /proc/sys/vm/swappiness

# 调整脏页回写策略
echo 5 > /proc/sys/vm/dirty_ratio
echo 1 > /proc/sys/vm/dirty_background_ratio

# 永久配置
cat > /etc/sysctl.d/99-storage-performance.conf << 'EOF'
vm.swappiness = 10
vm.dirty_ratio = 5
vm.dirty_background_ratio = 1
vm.vfs_cache_pressure = 50
EOF

sysctl -p /etc/sysctl.d/99-storage-performance.conf
```

### 4.8 存储监控

#### 4.8.1 Longhorn 指标

```bash
# Longhorn 暴露 Prometheus 指标
# 端点：http://<longhorn-manager>:9500/metrics

# 关键指标：
# - longhorn_volume_size_bytes: 卷大小
# - longhorn_volume_used_bytes: 已用空间
# - longhorn_volume_robustness: 卷健康状态
# - longhorn_node_disk_size_bytes: 节点磁盘大小
# - longhorn_node_disk_used_bytes: 节点磁盘已用

# 验证指标
curl http://<longhorn-manager-ip>:9500/metrics | grep longhorn_volume
```

#### 4.8.2 配置 Prometheus 告警

```yaml
# prometheus-storage-alerts.yaml
# 存储相关告警规则
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: storage-alerts
  namespace: monitoring
spec:
  groups:
    - name: storage.rules
      rules:
        # 磁盘使用率告警
        - alert: StorageSpaceLow
          expr: |
            (1 - longhorn_volume_used_bytes / longhorn_volume_size_bytes) < 0.2
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "存储空间不足"
            description: "卷 {{ $labels.volume }} 使用率超过 80%"

        # 卷健康状态告警
        - alert: VolumeUnhealthy
          expr: longhorn_volume_robustness != 1
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "存储卷不健康"
            description: "卷 {{ $labels.volume }} 状态异常"

        # 节点磁盘使用告警
        - alert: NodeDiskSpaceLow
          expr: |
            (1 - longhorn_node_disk_used_bytes / longhorn_node_disk_size_bytes) < 0.15
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "节点磁盘空间不足"
            description: "节点 {{ $labels.node }} 磁盘使用率超过 85%"
```

### 4.9 存储维护操作

#### 4.9.1 扩容 PVC

```bash
# 在线扩容（支持热扩容）
kubectl edit pvc example-pvc -n default
# 修改 spec.resources.requests.storage: 20Gi

# 验证扩容
kubectl get pvc example-pvc -n default
# NAME          STATUS   VOLUME                                     CAPACITY   ...
# example-pvc   Bound    pvc-a1b2c3d4-e5f6-7890-abcd-ef1234567890   20Gi       ...
```

#### 4.9.2 迁移数据

```bash
# 1. 创建快照
kubectl apply -f manual-snapshot.yaml

# 2. 验证快照
kubectl get volumesnapshot -n databases
# NAME                      READYTOUSE   SOURCEPVC          SOURCESNAPSHOTCONTENT   ...
# postgres-snapshot-manual   true         postgres-data-pvc                           ...

# 3. 从快照恢复（如果需要）
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data-restored
  namespace: databases
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
  storageClassName: longhorn-fast
  dataSource:
    name: postgres-snapshot-manual
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
EOF
```

#### 4.9.3 清理无用存储

```bash
# 查找未绑定的 PV
kubectl get pv | grep Released

# 删除未使用的 PVC
kubectl delete pvc <pvc-name> -n <namespace>

# 清理 Longhorn 卷
# 通过 UI 删除，或使用命令
kubectl -n longhorn-system exec -it <longhorn-manager-pod> -- \
    longhorn volume delete <volume-name>

# 清理过期快照
kubectl delete volumesnapshot <snapshot-name> -n <namespace>
```

## 5. 验证方法

```bash
# 5.1 验证 StorageClass
kubectl get storageclass
# 预期：至少一个 StorageClass 标记为 default

# 5.2 验证 PVC 绑定
kubectl get pvc -A
# 预期：所有 PVC 状态为 Bound

# 5.3 测试动态存储供给
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-dynamic-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: longhorn
EOF

# 等待 PVC 绑定
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/test-dynamic-pvc --timeout=60s

# 5.4 测试 Pod 挂载
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-storage-pod
spec:
  containers:
    - name: test
      image: busybox:1.36
      command: ["sleep", "3600"]
      volumeMounts:
        - name: test-volume
          mountPath: /data
  volumes:
    - name: test-volume
      persistentVolumeClaim:
        claimName: test-dynamic-pvc
EOF

# 等待 Pod 就绪
kubectl wait --for=condition=Ready pod/test-storage-pod --timeout=120s

# 5.5 测试数据持久化
kubectl exec test-storage-pod -- sh -c 'echo "Hello Storage" > /data/test.txt'
kubectl exec test-storage-pod -- cat /data/test.txt
# 输出: Hello Storage

# 5.6 测试数据在 Pod 重启后保留
kubectl delete pod test-storage-pod
# 重新创建 Pod
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-storage-pod-new
spec:
  containers:
    - name: test
      image: busybox:1.36
      command: ["sleep", "3600"]
      volumeMounts:
        - name: test-volume
          mountPath: /data
  volumes:
    - name: test-volume
      persistentVolumeClaim:
        claimName: test-dynamic-pvc
EOF
kubectl wait --for=condition=Ready pod/test-storage-pod-new --timeout=120s
kubectl exec test-storage-pod-new -- cat /data/test.txt
# 预期输出: Hello Storage（数据保留）

# 5.7 测试快照功能
kubectl apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: test-snapshot
spec:
  volumeSnapshotClassName: longhorn-snapshot
  source:
    persistentVolumeClaimName: test-dynamic-pvc
EOF

kubectl wait --for=jsonpath='{.status.readyToUse}'=true volumesnapshot/test-snapshot --timeout=120s

# 5.8 测试存储性能
kubectl exec test-storage-pod -- sh -c '
    dd if=/dev/zero of=/data/testfile bs=1M count=100
    dd if=/data/testfile of=/dev/null bs=1M
    rm /data/testfile
'
# 输出：显示读写速度

# 5.9 验证 Longhorn 卷健康
kubectl -n longhorn-system get volumes.longhorn.io
# NAME                                       STATE      ROBUSTNESS   SIZE          ...
# pvc-a1b2c3d4-e5f6-7890-abcd-ef1234567890   healthy    healthy      10737418240   ...

# 5.10 清理测试资源
kubectl delete pod test-storage-pod-new
kubectl delete pvc test-dynamic-pvc
kubectl delete volumesnapshot test-snapshot
```

## 6. 常见问题

### Q1: PVC 一直处于 Pending 状态
**原因**：StorageClass 未正确配置或没有可用磁盘
**解决**：
```bash
# 检查 PVC 事件
kubectl describe pvc <pvc-name>

# 检查 StorageClass
kubectl get sc

# 检查 Longhorn 磁盘状态
kubectl -n longhorn-system get disks.longhorn.io

# 确保节点有可用磁盘
lsblk
```

### Q2: 卷创建失败
**原因**：磁盘空间不足或 Longhorn 组件异常
**解决**：
```bash
# 检查 Longhorn 日志
kubectl -n longhorn-system logs <longhorn-manager-pod>

# 检查磁盘空间
df -h /mnt/longhorn

# 检查卷状态
kubectl -n longhorn-system get volumes.longhorn.io

# 重启 Longhorn 组件
kubectl -n longhorn-system rollout restart daemonset/longhorn-manager
```

### Q3: 数据丢失
**原因**：卷回收策略设置错误或误删 PVC
**解决**：
```bash
# 如果有快照，从快照恢复
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: restored-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: longhorn
  dataSource:
    name: <snapshot-name>
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
EOF

# 如果没有快照，检查 Longhorn 卷副本
kubectl -n longhorn-system get volumes.longhorn.io -o yaml
```

### Q4: 存储性能差
**原因**：IO 调度器不当、缓存配置错误或副本过多
**解决**：
```bash
# 检查 IO 调度器
cat /sys/block/sda/queue/scheduler

# 优化 IO 调度器
echo mq-deadline > /sys/block/sda/queue/scheduler

# 检查副本数（减少副本提高性能）
kubectl get sc longhorn-fast -o yaml | grep numberOfReplica

# 使用本地存储（最高性能）
kubectl get sc longhorn-fast -o yaml | grep dataLocality
# 确保为 strict-local
```

### Q5: 快照创建失败
**原因**：VolumeSnapshot CRD 未安装或配置错误
**解决**：
```bash
# 检查 CRD
kubectl get crd | grep snapshot

# 检查 VolumeSnapshotClass
kubectl get volumesnapshotclass

# 检查快照控制器
kubectl get pods -n kube-system | grep snapshot

# 重新安装快照控制器
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.3.0/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml
```

### Q6: 节点磁盘故障
**原因**：物理磁盘损坏
**解决**：
```bash
# 检查 Longhorn 磁盘状态
kubectl -n longhorn-system get disks.longhorn.io

# 标记磁盘为不可用
kubectl -n longhorn-system patch disks.longhorn.io <disk-name> \
    --type merge -p '{"spec":{"diskType":"Invalid"}}'

# Longhorn 会自动重建副本到健康磁盘
# 等待卷恢复健康
kubectl -n longhorn-system get volumes.longhorn.io -w
```

## 7. 回滚方案

### 7.1 完全回滚 Longhorn

```bash
# 卸载 Longhorn
helm uninstall longhorn -n longhorn-system

# 删除 PVC 和 PV
kubectl delete pvc --all -n default
kubectl delete pv --all

# 删除 StorageClass
kubectl delete sc longhorn longhorn-fast longhorn-shared

# 删除 Longhorn 数据
rm -rf /mnt/longhorn/*

# 删除 Longhorn namespace
kubectl delete namespace longhorn-system

# 重新开始
```

### 7.2 部分回滚（恢复特定 PVC）

```bash
# 1. 从快照恢复
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: restored-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: longhorn
  dataSource:
    name: <backup-snapshot-name>
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
EOF

# 2. 验证数据完整性
kubectl exec <pod-name> -- md5sum /data/*
```

### 7.3 紧急恢复（卷损坏）

```bash
# 如果卷损坏且无法恢复，使用备份
# 1. 从 Velero 恢复
velero restore create --from-backup <backup-name>

# 2. 如果 Velero 不可用，使用 etcd 备份恢复
# 恢复 PVC/PV 定义
ETCDCTL_API=3 etcdctl snapshot restore <etcd-backup> \
    --data-dir=/var/lib/etcd-restored

# 3. 重新创建 PVC 并挂载
```

## 8. 最佳实践

1. **存储类型选择**：
   - 数据库：使用高性能 StorageClass（fewer replicas, local）
   - 日志/缓存：使用标准 StorageClass（more replicas）
   - 共享数据：使用 NFS/Longhorn 共享模式

2. **容量规划**：
   - 预留 20% 容量用于快照和临时数据
   - 监控磁盘使用率，设置告警阈值
   - 定期清理过期快照和备份

3. **性能优化**：
   - 使用 SSD 作为存储后端
   - 合理设置副本数（性能 vs 可靠性）
   - 启用 IO 调度器优化
   - 配置适当的缓存策略

4. **安全配置**：
   - 启用存储加密（敏感数据）
   - 使用 RBAC 控制存储访问权限
   - 定期轮换加密密钥
   - 监控异常访问

5. **备份策略**：
   - 每天自动备份关键数据
   - 保留 30 天备份
   - 定期测试恢复流程
   - 使用异地备份（防止数据中心故障）

6. **监控告警**：
   - 监控磁盘使用率、IO 性能
   - 监控卷健康状态
   - 监控 Longhorn 组件状态
   - 配置关键指标告警

7. **维护操作**：
   - 扩容前在测试环境验证
   - 使用快照保护数据
   - 记录所有变更操作
   - 定期审查存储配置

8. **文档维护**：
   - 记录所有 StorageClass 配置
   - 维护 PVC 使用清单
   - 记录故障处理流程
   - 定期更新文档
