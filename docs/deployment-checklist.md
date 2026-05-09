# 企业级云原生运维平台 - 部署检查清单

> 版本: v1.0.0  
> 最后更新: 2026-05-10  
> 适用环境: 生产环境 / 预发布环境

---

## 目录

1. [部署前准备](#1-部署前准备)
2. [基础设施部署](#2-基础设施部署)
3. [平台服务部署](#3-平台服务部署)
4. [应用服务部署](#4-应用服务部署)
5. [监控系统部署](#5-监控系统部署)
6. [安全加固](#6-安全加固)
7. [部署后验证](#7-部署后验证)

---

## 1. 部署前准备

### 1.1 环境检查

| 检查项 | 验证命令 | 预期结果 | 状态 |
|--------|---------|---------|------|
| K8s 集群就绪 | `kubectl get nodes` | 所有节点 Ready | ☐ |
| kubectl 版本 | `kubectl version --client` | >= 1.28 | ☐ |
| Helm 版本 | `helm version` | >= 3.14 | ☐ |
| Helm 仓库已添加 | `helm repo list` | 包含所有必要仓库 | ☐ |
| Docker/containerd | `crictl info` | 运行正常 | ☐ |
| 存储类可用 | `kubectl get sc` | 包含所需存储类 | ☐ |
| DNS 解析 | `nslookup kubernetes.default` | 正常解析 | ☐ |

#### 验证脚本

```bash
#!/bin/bash
# scripts/check-prerequisites.sh

echo "=== 检查 K8s 集群状态 ==="
kubectl get nodes -o wide
echo ""

echo "=== 检查组件版本 ==="
echo "kubectl: $(kubectl version --client --short 2>/dev/null || echo 'N/A')"
echo "helm: $(helm version --short 2>/dev/null || echo 'N/A')"
echo ""

echo "=== 检查存储类 ==="
kubectl get storageclass
echo ""

echo "=== 检查系统 Pod 状态 ==="
kubectl get pods -n kube-system
echo ""

echo "=== 检查命名空间 ==="
kubectl get namespaces
echo ""

echo "=== 检查证书状态 ==="
kubectl get certificates -A
```

### 1.2 凭证准备

| 凭证 | 存储位置 | 状态 |
|------|---------|------|
| K8s kubeconfig | ~/.kube/config | ☐ |
| 云平台 Access Key | Vault/kv/cloud-creds | ☐ |
| Docker Registry | Vault/kv/docker-registry | ☐ |
| 数据库密码 | Vault/kv/db-credentials | ☐ |
| TLS 证书 | Vault/pki | ☐ |
| API 密钥 | Vault/kv/api-keys | ☐ |
| Vault Unseal Key | 安全存储 | ☐ |

### 1.3 资源配额确认

```bash
# 检查命名空间资源配额
kubectl describe resourcequota -n production
kubectl describe resourcequota -n monitoring

# 检查节点资源
kubectl describe nodes | grep -A 5 "Allocated resources"
```

### 1.4 网络预配置

| 检查项 | 命令 | 预期结果 | 状态 |
|--------|------|---------|------|
| CNI 就绪 | `kubectl get pods -n kube-system -l k8s-app=cilium` | 所有 Pod Running | ☐ |
| Ingress 控制器 | `kubectl get pods -n ingress-nginx` | Pod Running | ☐ |
| DNS 服务 | `kubectl get pods -n kube-system -l k8s-app=kube-dns` | Pod Running | ☐ |
| 网络策略 | `kubectl get networkpolicy -A` | 策略已定义 | ☐ |

---

## 2. 基础设施部署

### 2.1 Vault 部署

| 步骤 | 操作 | 验证命令 | 预期结果 | 状态 |
|------|------|---------|---------|------|
| 1 | 部署 Vault | `kubectl get pods -n vault` | Pod Running | ☐ |
| 2 | 初始化 Vault | `vault operator init` | 获取 Unseal Keys | ☐ |
| 3 | 解封 Vault | `vault operator unseal` | Vault 已解封 | ☐ |
| 4 | 配置认证 | `vault auth list` | 包含所需认证方式 | ☐ |
| 5 | 配置秘密引擎 | `vault secrets list` | 包含 kv/pki 引擎 | ☐ |
| 6 | 存储初始凭证 | `vault kv list -mount=kv` | 凭证已存储 | ☐ |

#### 验证命令

```bash
# 检查 Vault 状态
kubectl exec -n vault vault-0 -- vault status

# 测试读取
vault kv get -mount=kv cloud-creds
```

### 2.2 数据库部署

| 步骤 | 操作 | 验证命令 | 预期结果 | 状态 |
|------|------|---------|---------|------|
| 1 | 部署 CloudNative-PG Operator | `kubectl get pods -n cnpg-system` | Operator Running | ☐ |
| 2 | 创建 PostgreSQL 集群 | `kubectl get clusters -n data` | 集群 Created | ☐ |
| 3 | 等待集群就绪 | `kubectl get pods -n data` | 3/3 Running | ☐ |
| 4 | 验证复制 | `psql -c "SELECT * FROM pg_stat_replication"` | 2 个副本连接 | ☐ |
| 5 | 测试连接 | `psql -h pg-svc -U admin -d appdb` | 连接成功 | ☐ |
| 6 | 创建应用数据库 | `psql -c "CREATE DATABASE app;"` | 数据库创建 | ☐ |

#### 验证脚本

```bash
#!/bin/bash
# scripts/verify-postgresql.sh

echo "=== 检查 PostgreSQL 集群状态 ==="
kubectl get clusters -n data -o wide

echo ""
echo "=== 检查 PostgreSQL Pod ==="
kubectl get pods -n data -l cnpg.io/cluster=postgresql-production

echo ""
echo "=== 检查服务 ==="
kubectl get svc -n data

echo ""
echo "=== 测试数据库连接 ==="
kubectl exec -n data postgresql-production-1 -- \
  psql -U postgres -c "SELECT version();"

echo ""
echo "=== 检查复制状态 ==="
kubectl exec -n data postgresql-production-1 -- \
  psql -U postgres -c "SELECT client_addr, state FROM pg_stat_replication;"
```

### 2.3 Redis 部署

| 步骤 | 操作 | 验证命令 | 预期结果 | 状态 |
|------|------|---------|---------|------|
| 1 | 部署 Redis Operator | `kubectl get pods -n redis-operator` | Operator Running | ☐ |
| 2 | 创建 Redis 集群 | `kubectl get redis -n data` | 集群 Created | ☐ |
| 3 | 等待集群就绪 | `kubectl get pods -n data -l app=redis` | 6/6 Running | ☐ |
| 4 | 验证集群 | `redis-cli cluster info` | cluster_state: ok | ☐ |
| 5 | 测试连接 | `redis-cli -h redis-svc ping` | PONG | ☐ |

---

## 3. 平台服务部署

### 3.1 ArgoCD 部署

| 步骤 | 操作 | 验证命令 | 预期结果 | 状态 |
|------|------|---------|---------|------|
| 1 | 部署 ArgoCD | `kubectl get pods -n argocd` | 所有 Pod Running | ☐ |
| 2 | 获取初始密码 | `kubectl -n argocd get secret` | 密码已获取 | ☐ |
| 3 | 登录 Web UI | `argocd login argocd.example.com` | 登录成功 | ☐ |
| 4 | 配置 Git 仓库 | `argocd repo list` | 仓库已添加 | ☐ |
| 5 | 创建 Application | `argocd app list` | 应用已创建 | ☐ |
| 6 | 同步应用 | `argocd app sync <app-name>` | 同步成功 | ☐ |

#### 验证命令

```bash
# 检查 ArgoCD 状态
kubectl get applications -n argocd
kubectl get appprojects -n argocd

# 检查同步状态
argocd app list -o wide
```

### 3.2 Cert-Manager 部署

| 步骤 | 操作 | 验证命令 | 预期结果 | 状态 |
|------|------|---------|---------|------|
| 1 | 部署 Cert-Manager | `kubectl get pods -n cert-manager` | 3 Pods Running | ☐ |
| 2 | 创建 ClusterIssuer | `kubectl get clusterissuer` | Issuer Ready | ☐ |
| 3 | 验证证书签发 | `kubectl get certificates -A` | 证书 Ready | ☐ |
| 4 | 检查证书有效期 | `kubectl describe certificate` | 有效期 > 30天 | ☐ |

### 3.3 服务网格部署 (Istio)

| 步骤 | 操作 | 验证命令 | 预期结果 | 状态 |
|------|------|---------|---------|------|
| 1 | 安装 Istio | `istioctl verify-install` | 安装验证通过 | ☐ |
| 2 | 部署 Istiod | `kubectl get pods -n istio-system` | Istiod Running | ☐ |
| 3 | 启用 Sidecar 注入 | `kubectl get namespace production` | istio-injection: enabled | ☐ |
| 4 | 部署 Ingress Gateway | `kubectl get pods -n istio-system` | Gateway Running | ☐ |
| 5 | 验证 mTLS | `istioctl x describe pod <pod>` | mTLS STRICT | ☐ |

---

## 4. 应用服务部署

### 4.1 部署顺序

```
1. 基础服务 (ConfigMap, Secret, ServiceAccount)
   ↓
2. 后端服务 (API Server, Worker)
   ↓
3. 前端服务 (Web UI, Static Assets)
   ↓
4. Ingress 配置 (路由规则)
   ↓
5. 集成测试
```

### 4.2 部署检查

| 检查项 | 命令 | 预期结果 | 状态 |
|--------|------|---------|------|
| Deployment 就绪 | `kubectl get deploy -n production` | 所有 Deployment Available | ☐ |
| Pod 运行正常 | `kubectl get pods -n production` | 所有 Pod Running | ☐ |
| Service 创建 | `kubectl get svc -n production` | Service 已创建 | ☐ |
| Endpoint 已关联 | `kubectl get endpoints -n production` | Endpoint 有 IP | ☐ |
| Ingress 配置 | `kubectl get ingress -n production` | Ingress 规则正确 | ☐ |
| HPA 配置 | `kubectl get hpa -n production` | HPA 已创建 | ☐ |

### 4.3 集成测试

```bash
#!/bin/bash
# scripts/integration-test.sh

API_BASE="https://api.example.com"

echo "=== 健康检查测试 ==="
curl -s -o /dev/null -w "%{http_code}" ${API_BASE}/health
# 预期: 200

echo ""
echo "=== API 响应时间测试 ==="
curl -s -o /dev/null -w "HTTP Status: %{http_code}\nTime Total: %{time_total}s\n" ${API_BASE}/api/v1/status
# 预期: HTTP 200, Time < 1s

echo ""
echo "=== TLS 证书验证 ==="
echo | openssl s_client -connect api.example.com:443 2>/dev/null | openssl x509 -noout -dates
# 预期: 证书有效期 > 30天

echo ""
echo "=== DNS 解析测试 ==="
nslookup api.example.com
# 预期: 正确解析到 Ingress IP

echo ""
echo "=== 端到端测试 ==="
# 运行完整的 E2E 测试套件
# e2e-test --suite=smoke
```

---

## 5. 监控系统部署

### 5.1 Prometheus 部署

| 步骤 | 操作 | 验证命令 | 预期结果 | 状态 |
|------|------|---------|---------|------|
| 1 | 部署 Prometheus Operator | `kubectl get pods -n monitoring` | Operator Running | ☐ |
| 2 | 部署 Prometheus | `kubectl get pods -n monitoring` | Prometheus Running | ☐ |
| 3 | 部署 Alertmanager | `kubectl get pods -n monitoring` | Alertmanager Running | ☐ |
| 4 | 配置 ServiceMonitor | `kubectl get servicemonitor` | 监控目标已添加 | ☐ |
| 5 | 配置告警规则 | `kubectl get prometheusrule` | 规则已加载 | ☐ |
| 6 | 验证抓取 | 浏览器访问 Prometheus UI | Target 全部 UP | ☐ |

#### 验证命令

```bash
# 检查 Prometheus 状态
kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus

# 检查告警规则
kubectl get prometheusrule -n monitoring -o yaml

# 检查抓取目标
kubectl port-forward -n monitoring svc/prometheus 9090
# 浏览器访问 http://localhost:9090/targets
```

### 5.2 Grafana 部署

| 步骤 | 操作 | 验证命令 | 预期结果 | 状态 |
|------|------|---------|---------|------|
| 1 | 部署 Grafana | `kubectl get pods -n monitoring` | Grafana Running | ☐ |
| 2 | 配置数据源 | Grafana UI → Data Sources | Prometheus 已添加 | ☐ |
| 3 | 导入仪表板 | Grafana UI → Dashboards | 仪表板已导入 | ☐ |
| 4 | 配置告警通道 | Grafana UI → Alerting | 告警通知已配置 | ☐ |

### 5.3 日志系统部署

| 步骤 | 操作 | 验证命令 | 预期结果 | 状态 |
|------|------|---------|---------|------|
| 1 | 部署 Loki | `kubectl get pods -n logging` | Loki Running | ☐ |
| 2 | 部署 Fluent Bit | `kubectl get pods -n logging` | Fluent Bit Running | ☐ |
| 3 | 配置日志采集 | Grafana Explore → Loki | 日志可查询 | ☐ |
| 4 | 验证日志格式 | 查询示例日志 | JSON 格式正确 | ☐ |

---

## 6. 安全加固

### 6.1 安全检查清单

| 检查项 | 命令 | 预期结果 | 状态 |
|--------|------|---------|------|
| RBAC 策略 | `kubectl get clusterrolebinding` | 最小权限配置 | ☐ |
| Pod 安全策略 | `kubectl get psp` | 策略已启用 | ☐ |
| 网络策略 | `kubectl get networkpolicy -A` | 策略已定义 | ☐ |
| Secret 加密 | `kubectl get secret -o yaml` | 数据已加密 | ☐ |
| 镜像签名 | `cosign verify <image>` | 签名验证通过 | ☐ |
| 漏洞扫描 | `trivy image <image>` | 无高危漏洞 | ☐ |

### 6.2 合规检查

```bash
#!/bin/bash
# scripts/compliance-check.sh

echo "=== CIS Benchmark 检查 ==="
# 使用 kube-bench 运行 CIS Benchmark
kube-bench run --targets=master,node,policies

echo ""
echo "=== 镜像漏洞扫描 ==="
# 扫描所有运行中的镜像
kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | \
  sort -u | while read image; do
    echo "扫描: $image"
    trivy image --severity HIGH,CRITICAL "$image"
  done

echo ""
echo "=== 配置审计 ==="
# 使用 KubeAudit 进行安全审计
kube-bench audit
```

### 6.3 密钥轮换

| 密钥类型 | 轮换周期 | 执行方式 | 状态 |
|----------|---------|---------|------|
| TLS 证书 | 90天 | Cert-Manager 自动 | ☐ |
| 数据库密码 | 30天 | Vault 动态密钥 | ☐ |
| API 密钥 | 60天 | 手动轮换 | ☐ |
| K8s Service Account Token | 自动 | K8s 自动轮换 | ☐ |

---

## 7. 部署后验证

### 7.1 功能验证

| 测试项 | 方法 | 预期结果 | 状态 |
|--------|------|---------|------|
| API 健康检查 | curl /health | HTTP 200 | ☐ |
| 用户登录 | 浏览器测试 | 登录成功 | ☐ |
| 数据查询 | API 调用 | 数据正确返回 | ☐ |
| 文件上传 | API 调用 | 上传成功 | ☐ |
| 告警测试 | 触发测试告警 | 告警通知已发送 | ☐ |
| 备份测试 | 手动触发备份 | 备份成功 | ☐ |

### 7.2 性能验证

```bash
#!/bin/bash
# scripts/performance-test.sh

echo "=== 负载测试 ==="
# 使用 k6 进行负载测试
k6 run --vus 100 --duration 5m performance-test.js

echo ""
echo "=== 响应时间测试 ==="
# P99 延迟检查
curl -s http://prometheus:9090/api/v1/query?query=histogram_quantile(0.99,rate(http_request_duration_seconds_bucket[5m])) | \
  jq '.data.result[0].value[1]'

echo ""
echo "=== 错误率检查 ==="
# 5xx 错误率
curl -s "http://prometheus:9090/api/v1/query?query=100*sum(rate(http_requests_total{status=~'5..'}[5m]))/sum(rate(http_requests_total[5m]))" | \
  jq '.data.result[0].value[1]'
```

### 7.3 灾难恢复测试

| 测试项 | 方法 | 预期结果 | 状态 |
|--------|------|---------|------|
| Pod 故障恢复 | `kubectl delete pod <pod>` | Pod 自动重建 | ☐ |
| Node 故障转移 | 关闭一个 Node | Pod 迁移到其他节点 | ☐ |
| 数据库故障转移 | 停止主节点 | 副本提升为主 | ☐ |
| 备份恢复 | 恢复备份数据 | 数据完整恢复 | ☐ |

### 7.4 部署文档

| 文档 | 位置 | 状态 |
|------|------|------|
| 架构文档 | docs/architecture.md | ☐ |
| API 文档 | docs/api-reference.md | ☐ |
| 运维手册 | docs/runbooks/ | ☐ |
| 故障排查 | docs/troubleshooting.md | ☐ |
| 变更日志 | CHANGELOG.md | ☐ |

---

## 附录: 部署命令速查

```bash
# 基础设施
helm install vault hashicorp/vault -n vault -f configs/vault/values.yaml
helm install cert-manager jetstack/cert-manager -n cert-manager -f configs/cert-manager/values.yaml

# 监控
helm install prometheus prometheus-community/kube-prometheus-stack -n monitoring -f configs/prometheus/values.yaml
helm install loki grafana/loki-stack -n logging -f configs/loki/values.yaml

# 平台服务
helm install argocd argo/argo-cd -n argocd -f configs/argocd/values.yaml
helm install istio istio/base -n istio-system
helm install istiod istio/istiod -n istio-system

# 应用部署
kubectl apply -f k8s/production/
```
