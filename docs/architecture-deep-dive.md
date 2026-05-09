# 企业级云原生运维平台 - 架构深度解析

> 版本: v1.0.0  
> 最后更新: 2026-05-10  
> 适用环境: 生产环境 / 预发布环境

---

## 目录

1. [整体架构概览](#1-整体架构概览)
2. [网络架构详解](#2-网络架构详解)
3. [存储架构详解](#3-存储架构详解)
4. [安全架构详解](#4-安全架构详解)
5. [监控架构详解](#5-监控架构详解)

---

## 1. 整体架构概览

### 1.1 设计原则

| 原则 | 说明 |
|------|------|
| 高可用性 | 所有核心组件至少3副本，跨可用区部署 |
| 可扩展性 | 水平扩展优先，支持自动扩缩容 |
| 安全性 | 零信任架构，最小权限原则 |
| 可观测性 | 全链路追踪、结构化日志、指标监控 |
| 自愈能力 | 自动故障检测与恢复 |

### 1.2 组件层次

```
┌─────────────────────────────────────────────────────────┐
│                    接入层 (Ingress)                       │
│         Nginx Ingress / Envoy / CloudFlare               │
├─────────────────────────────────────────────────────────┤
│                    服务网格 (Service Mesh)                 │
│              Istio / Linkerd / Cilium                    │
├─────────────────────────────────────────────────────────┤
│                    应用服务层                              │
│    ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐  │
│    │ API 网关 │ │ 业务服务 │ │ 数据服务 │ │ 运维服务 │  │
│    └──────────┘ └──────────┘ └──────────┘ └──────────┘  │
├─────────────────────────────────────────────────────────┤
│                    平台服务层                              │
│  K8s / Helm / ArgoCD / Vault / Cert-Manager             │
├─────────────────────────────────────────────────────────┤
│                    基础设施层                              │
│  计算 / 网络 / 存储 / 虚拟化 / 容器运行时                   │
└─────────────────────────────────────────────────────────┘
```

---

## 2. 网络架构详解

### 2.1 网络分层设计

#### 2.1.1 物理网络层

```
Internet
    │
    ▼
┌──────────────────┐
│   边缘路由器      │  BGP 路由，DDoS 防护
│   (Edge Router)  │  多 ISP 接入
└────────┬─────────┘
         │
    ┌────▼────┐
    │  防火墙  │   状态检测，入侵防御 (IPS)
    │ (WAF)   │   规则集: OWASP Top 10
    └────┬────┘
         │
    ┌────▼────┐
    │   负载    │   L4/L7 负载均衡
    │   均衡    │   健康检查，故障转移
    │  (LB)    │   支持: TLS 终止
    └────┬────┘
         │
    ┌────▼────┐
    │  K8s     │   Pod 网络，Service 网络
    │  集群    │   CNI 插件: Cilium
    └─────────┘
```

#### 2.1.2 集群内部网络

```
┌─────────────────────────────────────────────────────┐
│                   VPC (10.0.0.0/16)                 │
│                                                     │
│  ┌─────────────────────────────────────────────┐    │
│  │  子网: 私有子网 (10.0.1.0/24, 10.0.2.0/24) │    │
│  │                                             │    │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  │    │
│  │  │ Master-1 │  │ Master-2 │  │ Master-3 │  │    │
│  │  │.1.10     │  │.1.11     │  │.1.12     │  │    │
│  │  └──────────┘  └──────────┘  └──────────┘  │    │
│  │                                             │    │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  │    │
│  │  │ Worker-1 │  │ Worker-2 │  │ Worker-3 │  │    │
│  │  │.2.10     │  │.2.11     │  │.2.12     │  │    │
│  │  └──────────┘  └──────────┘  └──────────┘  │    │
│  │                                             │    │
│  │  Service 网络: 10.96.0.0/12                 │    │
│  │  Pod 网络:     10.244.0.0/16               │    │
│  └─────────────────────────────────────────────┘    │
│                                                     │
│  ┌─────────────────────────────────────────────┐    │
│  │  子网: 公有子网 (10.0.10.0/24)              │    │
│  │  ┌──────────┐  ┌──────────┐                │    │
│  │  │  NAT GW  │  │  Bastion │                │    │
│  │  └──────────┘  └──────────┘                │    │
│  └─────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────┘
```

### 2.2 CNI 网络插件 (Cilium)

#### 2.2.1 配置说明

```yaml
# configs/network/cilium-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cilium-config
  namespace: kube-system
data:
  # 使用 eBPF 替代 iptables，性能提升 10x+
  kube-proxy-replacement: "strict"
  
  # 启用 host-routing 提升网络性能
  enable-host-routing: "true"
  
  # BGP 对等配置 (与物理网络集成)
  enable-bgp-control-plane: "true"
  
  # Hubble 可观测性
  enable-hubble: "true"
  hubble-listen-address: ":4244"
  
  # 加密 (WireGuard)
  enable-wireguard: "true"
  
  # 网络策略
  enable-network-policy: "true"
  enable-k8s-network-policy: "true"
```

#### 2.2.2 网络策略架构

```
┌─────────────────────────────────────────────┐
│              Namespace 隔离                 │
│                                             │
│  ┌─────────────┐    ┌─────────────┐         │
│  │ 生产环境     │    │ 预发布环境   │         │
│  │             │    │             │         │
│  │ Pod ←→ Pod │ ✗ │ Pod ←→ Pod │         │
│  │ (同NS内)    │    │ (跨NS)      │         │
│  └─────────────┘    └─────────────┘         │
│                                             │
│  策略层级:                                   │
│  1. NetworkPolicy (L3/L4)                   │
│  2. CiliumNetworkPolicy (L3-L7)             │
│  3. CiliumClusterwideNetworkPolicy (集群级)  │
│  4. ServiceAccount 级别策略                   │
└─────────────────────────────────────────────┘
```

### 2.3 Ingress 架构

```
                    ┌──────────┐
                    │ CloudFlare│  CDN + DDoS 防护
                    │   DNS    │
                    └─────┬────┘
                          │
                    ┌─────▼────┐
                    │  Global   │  全局负载均衡
                    │   LB      │  健康检查
                    └─────┬────┘
                          │
                    ┌─────▼────┐
                    │  Istio    │  Ingress Gateway
                    │  Gateway  │  TLS 终止
                    │  API      │  路由规则
                    └─────┬────┘
                          │
                ┌─────────┼─────────┐
                │         │         │
          ┌─────▼──┐ ┌────▼───┐ ┌──▼─────┐
          │ 服务 A  │ │ 服务 B │ │ 服务 C  │
          │ /api/* │ │ /web/* │ │ /grpc  │
          └────────┘ └────────┘ └────────┘
```

### 2.4 DNS 架构

```
┌─────────────────────────────────────────────────────┐
│                    DNS 解析链                        │
│                                                     │
│  1. 外部 DNS (CloudFlare/Route53)                   │
│     ├── api.example.com → CloudFlare               │
│     └── *.example.com  → CloudFlare               │
│                                                     │
│  2. 内部 DNS (CoreDNS)                              │
│     ├── *.svc.cluster.local → K8s Service          │
│     ├── *.ns.svc.cluster.local → 命名空间隔离       │
│     └── 自定义解析: *.internal.example.com          │
│                                                     │
│  3. 服务发现 (Consul/Etcd)                          │
│     ├── 服务注册                                    │
│     └── 健康检查                                    │
└─────────────────────────────────────────────────────┘
```

### 2.5 网络安全

#### 2.5.1 网络分段

| 区域 | CIDR | 用途 | 访问控制 |
|------|------|------|---------|
| DMZ | 10.0.10.0/24 | 公网入口 | 仅允许 80/443 |
| Management | 10.0.20.0/24 | 运维管理 | 堡垒机跳转 |
| Production | 10.0.30.0/24 | 生产业务 | 内网访问 |
| Monitoring | 10.0.40.0/24 | 监控系统 | 内网访问 |
| Storage | 10.0.50.0/24 | 存储系统 | 内网访问 |

#### 2.5.2 流量加密

```
外部流量:  TLS 1.3 (ECDHE-RSA-AES256-GCM-SHA384)
内部流量:  mTLS (Istio Service Mesh)
存储流量:  IPSec / WireGuard
管理流量:  SSH + MFA
```

---

## 3. 存储架构详解

### 3.1 存储分层

```
┌─────────────────────────────────────────────────────┐
│                    存储架构                          │
│                                                     │
│  ┌─────────────────────────────────────────────┐    │
│  │  应用数据存储                                │    │
│  │  ├── PostgreSQL (OLTP)     - 热数据          │    │
│  │  ├── MongoDB (文档)        - 半结构化数据    │    │
│  │  ├── Redis (缓存)          - 热缓存          │    │
│  │  └── Elasticsearch (搜索)  - 全文检索        │    │
│  └─────────────────────────────────────────────┘    │
│                                                     │
│  ┌─────────────────────────────────────────────┐    │
│  │  文件存储                                    │    │
│  │  ├── MinIO (对象存储)     - 文件/备份         │    │
│  │  ├── NFS (共享存储)       - 配置/日志         │    │
│  │  └── Local PV (本地存储)  - 高性能需求       │    │
│  └─────────────────────────────────────────────┘    │
│                                                     │
│  ┌─────────────────────────────────────────────┐    │
│  │  消息队列                                    │    │
│  │  ├── Kafka (事件流)       - 事件总线          │    │
│  │  ├── RabbitMQ (消息)      - 任务队列          │    │
│  │  └── NATS (轻量消息)      - 内部通信          │    │
│  └─────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────┘
```

### 3.2 持久化卷配置

#### 3.2.1 StorageClass 定义

```yaml
# 高性能存储 (NVMe SSD)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: high-performance
provisioner: ebs.csi.aws.com
parameters:
  type: io2          # IOPS 优化型
  iopsPerGB: "50"    # 每GB 50 IOPS
  encrypted: "true"  # 静态加密
reclaimPolicy: Retain
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer

---
# 标准存储 (通用 SSD)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: standard
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
reclaimPolicy: Delete
allowVolumeExpansion: true

---
# 冷数据存储 (归档)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: cold-storage
provisioner: ebs.csi.aws.com
parameters:
  type: sc1          # 低频访问
reclaimPolicy: Retain
```

#### 3.2.2 数据库高可用配置

```yaml
# PostgreSQL 集群 (Patroni + etcd)
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgresql-production
  namespace: data
spec:
  description: 生产环境 PostgreSQL 集群
  imageName: ghcr.io/cloudnative-pg/postgresql:16.2
  instances: 3          # 主 + 2 只读副本
  
  postgresql:
    parameters:
      shared_buffers: "4GB"         # 25% 总内存
      effective_cache_size: "12GB"  # 75% 总内存
      work_mem: "64MB"
      maintenance_work_mem: "512MB"
      max_connections: "200"
      wal_level: "replica"
      max_wal_senders: "5"
      hot_standby: "on"
      
  bootstrap:
    initdb:
      database: appdb
      secret:
        name: postgresql-credentials
        key: password
    recovery:
      backup:
        name: latest-backup
      
  backup:
    barmanObjectStore:
      destinationPath: "s3://backups/postgresql"
      s3Credentials:
        accessKeyId:
          name: s3-credentials
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: s3-credentials
          key: SECRET_ACCESS_KEY
      destinationConfiguration:
        compression: gzip
        encryption: AES256
    retentionPolicy: "30d"
    
  storage:
    size: 100Gi
    storageClassName: high-performance
    
  resources:
    requests:
      memory: "8Gi"
      cpu: "2"
    limits:
      memory: "16Gi"
      cpu: "4"
```

### 3.3 备份策略

```
┌─────────────────────────────────────────────────────┐
│                    备份架构                          │
│                                                     │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐      │
│  │  数据库   │───▶│  备份代理 │───▶│  对象存储 │      │
│  │  数据源   │    │  Agent   │    │  (S3)    │      │
│  └──────────┘    └──────────┘    └──────────┘      │
│                      │                              │
│                      ▼                              │
│               ┌──────────┐                          │
│               │  备份目录 │                          │
│               │  规划     │                          │
│               ├──────────┤                          │
│               │ 全量: 每周日 02:00                   │
│               │ 增量: 每天 02:00                     │
│               │ WAL: 实时归档                        │
│               │ 保留: 30天                           │
│               │ 跨区域: 同步到 DR 区域               │
│               └──────────┘                          │
│                                                     │
│  恢复目标:                                          │
│  ├── RPO: < 1 分钟 (WAL 流复制)                     │
│  └── RTO: < 15 分钟 (PITR 恢复)                     │
└─────────────────────────────────────────────────────┘
```

### 3.4 数据一致性保障

| 级别 | 策略 | 适用场景 |
|------|------|---------|
| 强一致性 | 同步复制 + 两阶段提交 | 金融交易、支付 |
| 最终一致性 | 异步复制 + 事件溯源 | 社交、通知 |
| 因果一致性 | 因果时钟 + 版本向量 | 协同编辑 |

---

## 4. 安全架构详解

### 4.1 零信任架构

```
┌─────────────────────────────────────────────────────┐
│                    零信任架构                        │
│                                                     │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐      │
│  │  身份    │───▶│  认证    │───▶│  授权    │      │
│  │  验证    │    │  (AuthN) │    │  (AuthZ) │      │
│  └──────────┘    └──────────┘    └──────────┘      │
│       │              │              │              │
│       ▼              ▼              ▼              │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐      │
│  │  MFA     │    │  OIDC    │    │  RBAC    │      │
│  │  硬件密钥│    │  SAML    │    │  ABAC    │      │
│  └──────────┘    └──────────┘    └──────────┘      │
│                                                     │
│  原则: 永不信任，始终验证                            │
│  └── 每次请求都要经过身份验证和授权                   │
│  └── 最小权限访问                                   │
│  └── 持续监控和审计                                 │
└─────────────────────────────────────────────────────┘
```

### 4.2 认证架构

#### 4.2.1 多层认证

```
外部用户认证流程:
1. 用户 → CloudFlare Access (零信任网关)
2. CloudFlare → Auth0/Okta (企业 SSO)
3. Auth0 → MFA (TOTP/WebAuthn/SMS)
4. 认证成功 → JWT Token (15分钟有效期)
5. Token → Istio Ingress (验证)
6. Ingress → 应用服务 (授权检查)
```

#### 4.2.2 服务间认证 (mTLS)

```yaml
# Istio PeerAuthentication 配置
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT    # 强制 mTLS
---
# 允许的 TLS 版本和密码套件
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: strict-tls
spec:
  mtls:
    mode: STRICT
  tls:
    minProtocolVersion: TLSV1_3
    cipherSuites:
      - ECDHE-RSA-AES256-GCM-SHA384
      - ECDHE-RSA-CHACHA20-POLY1305
```

### 4.3 密钥管理

```
┌─────────────────────────────────────────────────────┐
│                    密钥管理架构                      │
│                                                     │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐      │
│  │  Vault   │    │  KMS     │    │  HSM     │      │
│  │  (密钥   │    │  (云密钥 │    │  (硬件   │      │
│  │   存储)  │    │   管理)  │    │   加密)  │      │
│  └────┬─────┘    └────┬─────┘    └────┬─────┘      │
│       │              │              │              │
│       ▼              ▼              ▼              │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐      │
│  │ 动态密钥  │    │ 加密密钥  │    │ 根密钥   │      │
│  │ 自动轮换  │    │ KMS 加密 │    │ 保护     │      │
│  │ 临时凭证  │    │  envelope │    │          │      │
│  └──────────┘    └──────────┘    └──────────┘      │
│                                                     │
│  密钥分类:                                          │
│  ├── 静态密钥: 数据库密码、API密钥                   │
│  ├── 动态密钥: 临时数据库凭证、短期Token             │
│  ├── 加密密钥: TLS证书、数据加密密钥                 │
│  └── 根密钥: 用于解封Vault的Unseal Key              │
└─────────────────────────────────────────────────────┘
```

### 4.4 RBAC 配置

```yaml
# K8s RBAC 示例
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: app-developer
rules:
  # 允许访问应用相关资源
  - apiGroups: ["", "apps"]
    resources: ["pods", "services", "deployments", "configmaps"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/logs"]
    verbs: ["get"]
  # 禁止访问敏感资源 (需显式禁止)
  - apiGroups: [""]
    resources: ["secrets", "serviceaccounts"]
    verbs: []  # 无权限
---
# 命名空间级别权限
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: app-developer-binding
  namespace: production
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: app-developer
subjects:
  - kind: Group
    name: "dev-team"
    apiGroup: rbac.authorization.k8s.io
```

### 4.5 网络安全

#### 4.5.1 WAF 规则

```
OWASP ModSecurity Core Rule Set (CRS):
├── SQL 注入防护
├── XSS 防护
├── 路径遍历防护
├── 远程代码执行防护
├── 文件包含防护
└── 协议攻击防护

自定义规则:
├── 地理围栏: 仅允许特定地区访问
├── 频率限制: 防止暴力破解
├── 签名验证: API 请求签名
└── 内容检查: 敏感数据检测 (PII/PCI)
```

#### 4.5.2 网络审计日志

```yaml
# Cilium 网络策略审计
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: audit-all-traffic
spec:
  endpointSelector:
    matchLabels:
      app: "audit-target"
  ingress:
    - fromEndpoints:
        - matchLabels: {}
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
          rules:
            http:
              - method: "GET"
                path: "/health"
              # 其他请求记录审计日志
```

---

## 5. 监控架构详解

### 5.1 可观测性全景

```
┌─────────────────────────────────────────────────────┐
│                  可观测性架构                        │
│                                                     │
│  ┌─────────────────────────────────────────────┐    │
│  │  指标 (Metrics)                              │    │
│  │  ├── Prometheus: 指标收集与存储              │    │
│  │  ├── Thanos: 长期存储与全局查询              │    │
│  │  ├── Grafana: 指标可视化                    │    │
│  │  └── Alertmanager: 告警路由                 │    │
│  └─────────────────────────────────────────────┘    │
│                                                     │
│  ┌─────────────────────────────────────────────┐    │
│  │  日志 (Logs)                                 │    │
│  │  ├── Fluentd/FluentBit: 日志收集            │    │
│  │  ├── Elasticsearch: 日志索引                │    │
│  │  ├── Kibana: 日志可视化                     │    │
│  │  └── Loki: 轻量级日志查询                   │    │
│  └─────────────────────────────────────────────┘    │
│                                                     │
│  ┌─────────────────────────────────────────────┐    │
│  │  追踪 (Traces)                               │    │
│  │  ├── OpenTelemetry: 遥测数据收集            │    │
│  │  ├── Jaeger/Tempo: 分布式追踪存储           │    │
│  │  └── 链路可视化与延迟分析                    │    │
│  └─────────────────────────────────────────────┘    │
│                                                     │
│  ┌─────────────────────────────────────────────┐    │
│  │  告警 (Alerting)                             │    │
│  │  ├── Prometheus: 指标告警                   │    │
│  │  ├── Loki: 日志告警                         │    │
│  │  ├── PagerDuty: 事件管理                    │    │
│  │  └── Slack/企微: 通知路由                   │    │
│  └─────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────┘
```

### 5.2 Prometheus 架构

```
                    ┌──────────┐
                    │ Grafana  │  仪表板
                    └────┬─────┘
                         │
              ┌──────────┼──────────┐
              │          │          │
        ┌─────▼──┐ ┌─────▼──┐ ┌─────▼──┐
        │Thanos  │ │Thanos  │ │Thanos  │
        │Query-1 │ │Query-2 │ │Query-3 │
        └─────┬──┘ └─────┬──┘ └─────┬──┘
              │          │          │
              ▼          ▼          ▼
        ┌──────────────────────────────┐
        │        Object Storage        │
        │     (S3/MinIO - 长期存储)     │
        └──────────────────────────────┘
              │          │          │
              ▼          ▼          ▼
        ┌─────┐   ┌─────┐   ┌─────┐
        │Prom │   │Prom │   │Prom │
        │1    │   │2    │   │3    │
        │(AZ1)│   │(AZ2)│   │(AZ3)│
        └──┬──┘   └──┬──┘   └──┬──┘
           │         │         │
           ▼         ▼         ▼
        ┌────────────────────────────┐
        │     Targets (应用实例)      │
        │  /metrics 端点              │
        └────────────────────────────┘
```

### 5.3 日志架构

```
┌─────────────────────────────────────────────────────┐
│                    日志流向                          │
│                                                     │
│  应用 Pod ──stdout/stderr──▶ Fluent Bit             │
│                             │                      │
│                    ┌────────┴────────┐              │
│                    │                 │              │
│              ┌─────▼────┐     ┌─────▼────┐         │
│              │Loki      │     │S3/MinIO  │         │
│              │(实时查询) │     │(长期存储) │         │
│              └─────┬────┘     └─────┬────┘         │
│                    │                 │              │
│              ┌─────▼────┐           │              │
│              │Grafana   │           │              │
│              │Explore   │           │              │
│              └──────────┘     ┌─────▼────┐         │
│                               │Analytics │         │
│                               │Pipeline  │         │
│                               └──────────┘         │
│                                                     │
│  日志分类:                                          │
│  ├── access.log   - 访问日志                        │
│  ├── error.log    - 错误日志                        │
│  ├── audit.log    - 审计日志                        │
│  └── trace.log    - 追踪日志                        │
│                                                     │
│  日志格式: JSON Structured Logging                  │
│  保留策略: 30天热存储 / 90天冷存储 / 1年归档        │
└─────────────────────────────────────────────────────┘
```

### 5.4 告警架构

```
┌─────────────────────────────────────────────────────┐
│                    告警路由                          │
│                                                     │
│  数据源                    处理层                    │
│  ┌──────────┐          ┌──────────┐                │
│  │Prometheus│──alert──▶│          │                │
│  └──────────┘          │          │                │
│  ┌──────────┐          │Alert     │──路由──▶ ┌────┐│
│  │Loki      │──alert──▶│Manager   │         │P1  ││
│  └──────────┘          │          │         │紧急 ││
│  ┌──────────┐          │          │         ├────┤│
│  │Custom    │──alert──▶│          │         │P2  ││
│  │Webhook   │          │          │         │重要 ││
│  └──────────┘          │          │         ├────┤│
│                        └──────────┘         │P3  ││
│                                             │一般 ││
│  通知渠道                                    └────┘│
│  ├── PagerDuty (P1/P2 紧急)                      │
│  ├── 企业微信 (所有级别)                          │
│  ├── Slack (团队通知)                             │
│  └── Email (非紧急)                               │
│                                                     │
│  告警升级:                                          │
│  P1: 0→1分钟→5分钟→15分钟→30分钟→升级               │
│  P2: 0→5分钟→15分钟→30分钟→升级                    │
│  P3: 0→30分钟→2小时→第二天处理                     │
└─────────────────────────────────────────────────────┘
```

### 5.5 SLI/SLO 定义

| SLI 指标 | SLO 目标 | 监控方式 |
|----------|---------|---------|
| 可用性 | 99.95% | Prometheus Blackbox |
| 延迟 (P99) | < 500ms | Request Latency |
| 延迟 (P99.9) | < 2s | Request Latency |
| 错误率 | < 0.1% | HTTP 5xx 比例 |
| 吞吐量 | > 1000 RPS | Request Rate |
| 数据持久性 | 99.999999999% | Backup Verification |

### 5.6 性能基线

```
关键性能指标基线:
├── CPU 使用率
│   ├── 正常: < 60%
│   ├── 警告: 60-80%
│   └── 危险: > 80%
├── 内存使用率
│   ├── 正常: < 70%
│   ├── 警告: 70-85%
│   └── 危险: > 85%
├── 磁盘 IOPS
│   ├── 正常: < 80% 容量
│   ├── 警告: 80-90%
│   └── 危险: > 90%
└── 网络带宽
    ├── 正常: < 70%
    ├── 警告: 70-90%
    └── 危险: > 90%
```

---

## 附录

### A. 架构决策记录 (ADR)

| 编号 | 决策 | 日期 | 状态 |
|------|------|------|------|
| ADR-001 | 选择 Cilium 作为 CNI | 2026-01 | 已批准 |
| ADR-002 | 选择 Thanos 作为长期存储 | 2026-02 | 已批准 |
| ADR-003 | 选择 CloudNative-PG 作为数据库 | 2026-03 | 已批准 |

### B. 容量规划

| 组件 | 最小配置 | 推荐配置 | 最大配置 |
|------|---------|---------|---------|
| K8s Master | 3×4C8G | 3×8C16G | 5×16C32G |
| K8s Worker | 3×8C32G | 6×16C64G | 10×32C128G |
| PostgreSQL | 3×4C16G | 3×8C32G | 3×16C64G |
| Redis | 3×2C4G | 3×4C8G | 3×8C16G |
| Elasticsearch | 3×4C16G | 3×8C32G | 5×16C64G |
| Prometheus | 1×4C16G | 3×8C32G | 5×16C64G |
