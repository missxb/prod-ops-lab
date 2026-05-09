# 企业级云原生运维平台 - 安全运维手册

> 版本: v1.0.0  
> 最后更新: 2026-05-10  
> 适用环境: 生产环境 / 预发布环境

---

## 目录

1. [安全事件响应](#1-安全事件响应)
2. [漏洞修复流程](#2-漏洞修复流程)
3. [合规检查](#3-合规检查)
4. [安全运维任务](#4-安全运维任务)
5. [密钥管理](#5-密钥管理)
6. [安全审计](#6-安全审计)

---

## 1. 安全事件响应

### 1.1 安全事件分级

| 级别 | 定义 | 响应时间 | 示例 |
|------|------|---------|------|
| P1 (严重) | 数据泄露、系统入侵 | 15分钟 | 未授权访问生产数据 |
| P2 (高危) | 权限提升、恶意软件 | 1小时 | 容器逃逸、后门植入 |
| P3 (中危) | 配置错误、弱密码 | 4小时 | 公开暴露的敏感服务 |
| P4 (低危) | 信息泄露、策略违规 | 24小时 | 日志中包含敏感信息 |

### 1.2 事件响应流程

```
┌─────────────────────────────────────────────────────────┐
│                    安全事件响应流程                       │
│                                                         │
│  1. 检测与识别 (Detection)                               │
│     ├── 监控系统告警                                     │
│     ├── 入侵检测系统 (IDS)                               │
│     ├── 日志分析                                         │
│     └── 外部报告                                         │
│                         │                               │
│                         ▼                               │
│  2. 评估与分类 (Assessment)                              │
│     ├── 确认事件真实性                                   │
│     ├── 评估影响范围                                     │
│     ├── 确定事件级别                                     │
│     └── 启动响应流程                                     │
│                         │                               │
│                         ▼                               │
│  3. 遏制与消除 (Containment)                             │
│     ├── 隔离受影响系统                                   │
│     ├── 阻断攻击路径                                     │
│     ├── 保存证据                                         │
│     └── 临时缓解措施                                     │
│                         │                               │
│                         ▼                               │
│  4. 恢复与修复 (Recovery)                                │
│     ├── 清除恶意代码                                     │
│     ├── 修复漏洞                                         │
│     ├── 恢复服务                                         │
│     └── 验证系统完整性                                   │
│                         │                               │
│                         ▼                               │
│  5. 复盘与改进 (Post-Incident)                           │
│     ├── 编写事件报告                                     │
│     ├── 根因分析                                         │
│     ├── 更新安全策略                                     │
│     └── 改进监控措施                                     │
└─────────────────────────────────────────────────────────┘
```

### 1.3 常见安全事件处理

#### 1.3.1 未授权访问

**症状**:
- 异常登录日志
- 未知 IP 访问敏感服务
- 异常 API 调用模式

**响应步骤**:

```bash
# 1. 立即锁定账户
kubectl get secret <secret-name> -n <namespace> -o yaml

# 2. 检查访问日志
kubectl logs -n <namespace> <pod-name> | grep -i "unauthorized\|failed"

# 3. 检查网络连接
kubectl exec -n <namespace> <pod-name> -- ss -tnp | grep ESTABLISHED

# 4. 隔离受影响 Pod
kubectl delete pod <pod-name> -n <namespace>

# 5. 强制轮换凭证
kubectl delete secret <secret-name> -n <namespace>
kubectl apply -f new-secret.yaml
```

#### 1.3.2 数据泄露

**症状**:
- 异常数据传输
- 敏感数据出现在日志中
- 未授权的数据访问

**响应步骤**:

```bash
# 1. 立即停止数据传输
kubectl exec -n <namespace> <pod-name> -- iptables -A OUTPUT -j DROP

# 2. 保存证据
kubectl logs -n <namespace> <pod-name> > /tmp/evidence/$(date +%Y%m%d_%H%M%S).log

# 3. 隔离受影响系统
kubectl cordon <node-name>

# 4. 通知相关方
# - 安全团队
# - 法务团队
# - 受影响用户 (如需要)

# 5. 清理数据
# 根据数据类型和法规要求决定清理方式
```

#### 1.3.3 恶意软件

**症状**:
- 容器内发现未知进程
- 异常网络连接
- 文件系统变更

**响应步骤**:

```bash
# 1. 隔离容器
kubectl delete pod <pod-name> -n <namespace>

# 2. 取证分析
# 导出容器文件系统
kubectl cp <namespace>/<pod-name>:/ /tmp/evidence/container-fs/

# 3. 检查镜像完整性
cosign verify <image>
trivy image <image>

# 4. 重新部署
kubectl rollout undo deployment/<deployment> -n <namespace>

# 5. 更新镜像签名
cosign sign <new-image>
```

#### 1.3.4 DDoS 攻击

**症状**:
- 流量异常激增
- 服务响应超时
- 502/503 错误增加

**响应步骤**:

```bash
# 1. 启用限流
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: rate-limit
  namespace: <namespace>
spec:
  host: <service>
  trafficPolicy:
    connectionPool:
      http:
        h2UpgradePolicy: DEFAULT
        http1MaxPendingRequests: 100
        http2MaxRequests: 1000
EOF

# 2. 配置 WAF 规则
# CloudFlare / AWS WAF / 自定义规则

# 3. 启用 CDN 缓存
# 静态资源通过 CDN 提供

# 4. 联系 ISP/云服务商
# 请求 DDoS 防护
```

### 1.4 事件报告模板

```markdown
# 安全事件报告

## 事件概述
- 事件ID: [自动生成]
- 发现时间: [YYYY-MM-DD HH:MM]
- 事件级别: [P1/P2/P3/P4]
- 影响范围: [系统/数据/用户]

## 事件详情
- 攻击类型: [未授权访问/数据泄露/恶意软件/DDoS]
- 攻击向量: [网络/应用/内部]
- 涉及系统: [系统列表]
- 数据影响: [泄露/损坏/未受影响]

## 响应过程
- 发现时间: [具体时间]
- 响应时间: [具体时间]
- 遏制时间: [具体时间]
- 恢复时间: [具体时间]

## 根因分析
- [详细分析]

## 改进措施
- [具体措施]
- [负责人]
- [完成时间]
```

---

## 2. 漏洞修复流程

### 2.1 漏洞分级

| 级别 | CVSS 分数 | 修复时间 | 示例 |
|------|-----------|---------|------|
| 严重 (Critical) | 9.0-10.0 | 24小时 | 远程代码执行、认证绕过 |
| 高危 (High) | 7.0-8.9 | 7天 | 权限提升、信息泄露 |
| 中危 (Medium) | 4.0-6.9 | 30天 | 跨站脚本、SQL注入 |
| 低危 (Low) | 0.1-3.9 | 90天 | 信息泄露、配置问题 |

### 2.2 漏洞扫描

#### 2.2.1 镜像扫描

```bash
#!/bin/bash
# scripts/image-scan.sh

IMAGE=$1
NAMESPACE=${2:-production}

echo "=== 扫描镜像: $IMAGE ==="

# Trivy 扫描
trivy image --severity HIGH,CRITICAL --exit-code 1 $IMAGE

# Cosign 验证
cosign verify $IMAGE

# 检查基础镜像漏洞
trivy image --severity HIGH,CRITICAL $(echo $IMAGE | cut -d: -f1):latest
```

#### 2.2.2 集群扫描

```bash
#!/bin/bash
# scripts/cluster-scan.sh

echo "=== 集群安全扫描 ==="

# Kube-Bench (CIS Benchmark)
kube-bench run --targets=master,node,policies

# Kube-Hunter (渗透测试)
kube-hunter --active

# OPA Gatekeeper 检查
kubectl get constrainttemplates
kubectl get constraints
```

#### 2.2.3 代码扫描

```bash
#!/bin/bash
# scripts/code-scan.sh

echo "=== 代码安全扫描 ==="

# SAST (静态分析)
semgrep --config auto .

# 依赖扫描
npm audit
pip-audit

# 密钥检测
trufflehog filesystem .
```

### 2.3 漏洞修复流程

```
┌─────────────────────────────────────────────────────────┐
│                    漏洞修复流程                          │
│                                                         │
│  1. 漏洞识别                                            │
│     ├── 自动扫描报告                                     │
│     ├── 外部安全研究                                     │
│     └── 用户报告                                         │
│                         │                               │
│                         ▼                               │
│  2. 漏洞评估                                            │
│     ├── CVSS 评分                                       │
│     ├── 影响范围评估                                     │
│     ├── 利用难度分析                                     │
│     └── 修复优先级确定                                   │
│                         │                               │
│                         ▼                               │
│  3. 修复实施                                            │
│     ├── 开发修复补丁                                     │
│     ├── 测试验证                                         │
│     ├── 安全审查                                         │
│     └── 部署更新                                         │
│                         │                               │
│                         ▼                               │
│  4. 验证确认                                            │
│     ├── 重新扫描验证                                     │
│     ├── 渗透测试                                         │
│     └── 监控确认                                         │
└─────────────────────────────────────────────────────────┘
```

### 2.4 紧急漏洞修复

#### 零日漏洞响应

```bash
#!/bin/bash
# scripts/emergency-patch.sh

# 1. 隔离受影响系统
kubectl cordon <affected-node>

# 2. 启动应急更新
# 更新镜像到修复版本
kubectl set image deployment/<deployment> \
  <container>=<fixed-image>:<tag> \
  -n <namespace>

# 3. 验证更新
kubectl rollout status deployment/<deployment> -n <namespace>

# 4. 重新扫描
trivy image <fixed-image>:<tag>

# 5. 解除隔离
kubectl uncordon <affected-node>
```

#### 供应链攻击响应

```bash
#!/bin/bash
# scripts/supply-chain-incident.sh

# 1. 识别受影响镜像
kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | \
  sort -u | grep <compromised-registry>

# 2. 停止受影响 Pod
kubectl delete pods -n <namespace> -l app=<affected-app>

# 3. 切换到可信镜像源
kubectl set image deployment/<deployment> \
  <container>=<trusted-registry>/<image>:<tag> \
  -n <namespace>

# 4. 审计镜像签名
cosign verify <trusted-image>

# 5. 更新镜像策略
kubectl apply -f - <<EOF
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sAllowedRepos
metadata:
  name: repo-is-trusted
spec:
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    namespaces:
      - production
  parameters:
    repos:
      - "trusted-registry.com/"
      - "docker.io/library/"
EOF
```

---

## 3. 合规检查

### 3.1 合规标准

| 标准 | 要求 | 检查频率 |
|------|------|---------|
| CIS Kubernetes Benchmark | K8s 安全配置 | 每月 |
| SOC 2 | 数据安全与隐私 | 每季度 |
| PCI DSS | 支付数据安全 | 每年 |
| GDPR | 个人数据保护 | 持续 |
| ISO 27001 | 信息安全管理 | 每年 |

### 3.2 自动化合规检查

```bash
#!/bin/bash
# scripts/compliance-check.sh

echo "=== 合规检查报告 ==="
echo "检查时间: $(date)"
echo ""

# 1. CIS Benchmark 检查
echo "1. CIS Kubernetes Benchmark"
kube-bench run --targets=master,node,policies --output-format=json > /tmp/cis-report.json

# 2. RBAC 检查
echo ""
echo "2. RBAC 配置检查"
echo "--- 过度权限检查 ---"
kubectl get clusterrolebindings -o json | \
  jq -r '.items[] | select(.subjects != null) | select(.subjects[].kind == "User" or .subjects[].kind == "ServiceAccount") | .metadata.name'

# 3. 网络策略检查
echo ""
echo "3. 网络策略检查"
echo "--- 无网络策略的命名空间 ---"
for ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}'); do
  if [ $(kubectl get networkpolicy -n $ns --no-headers 2>/dev/null | wc -l) -eq 0 ]; then
    echo "警告: $ns 没有网络策略"
  fi
done

# 4. Secret 加密检查
echo ""
echo "4. Secret 加密检查"
kubectl get secrets -A -o json | \
  jq -r '.items[] | select(.type == "Opaque") | select(.data | keys | length > 0) | "\(.metadata.namespace)/\(.metadata.name)"' | \
  head -20

# 5. Pod 安全检查
echo ""
echo "5. Pod 安全检查"
echo "--- 特权 Pod ---"
kubectl get pods -A -o json | \
  jq -r '.items[] | select(.spec.containers[].securityContext.privileged == true) | "\(.metadata.namespace)/\(.metadata.name)"'

echo ""
echo "--- 以 root 运行的 Pod ---"
kubectl get pods -A -o json | \
  jq -r '.items[] | select(.spec.containers[].securityContext.runAsUser == 0) | "\(.metadata.namespace)/\(.metadata.name)"'
```

### 3.3 合规报告

#### 报告生成

```bash
#!/bin/bash
# scripts/generate-compliance-report.sh

REPORT_DIR="/tmp/compliance-reports"
DATE=$(date +%Y%m%d)
REPORT_FILE="${REPORT_DIR}/compliance-report-${DATE}.md"

mkdir -p $REPORT_DIR

cat > $REPORT_FILE <<EOF
# 合规检查报告

生成时间: $(date)
检查范围: 生产环境

## 1. CIS Benchmark 结果

$(kube-bench run --targets=master,node,policies 2>&1)

## 2. RBAC 配置

$(kubectl get clusterrolebindings -o wide)

## 3. 网络策略

$(kubectl get networkpolicy -A -o wide)

## 4. Secret 管理

$(kubectl get secrets -A --field-selector type=Opaque -o wide | head -20)

## 5. Pod 安全

$(kubectl get pods -A -o wide | head -20)

## 6. 证书状态

$(kubectl get certificates -A -o wide)

## 7. 建议改进

- [ ] 为所有命名空间配置网络策略
- [ ] 启用 Pod 安全策略
- [ ] 配置 Secret 加密
- [ ] 定期轮换证书
- [ ] 启用审计日志
EOF

echo "报告已生成: $REPORT_FILE"
```

---

## 4. 安全运维任务

### 4.1 每日安全任务

```bash
#!/bin/bash
# scripts/daily-security-check.sh

echo "=== 每日安全检查 ==="

# 1. 检查异常登录
echo "1. 异常登录检查"
kubectl logs -n kube-system kube-apiserver-<node> --since=24h | grep -i "failed\|unauthorized"

# 2. 检查 Pod 变更
echo ""
echo "2. Pod 变更检查"
kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp' | tail -20

# 3. 检查 RBAC 变更
echo ""
echo "3. RBAC 变更检查"
kubectl get events -A --field-selector reason=RoleBinding -A --sort-by='.lastTimestamp' | tail -10

# 4. 检查 Secret 访问
echo ""
echo "4. Secret 访问检查"
kubectl logs -n kube-system kube-apiserver-<node> --since=24h | grep -i "secret"

# 5. 检查网络策略
echo ""
echo "5. 网络策略状态"
kubectl get networkpolicy -A --no-headers | wc -l
```

### 4.2 每周安全任务

```bash
#!/bin/bash
# scripts/weekly-security-check.sh

echo "=== 每周安全检查 ==="

# 1. 镜像漏洞扫描
echo "1. 镜像漏洞扫描"
kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | \
  sort -u | while read image; do
    echo "扫描: $image"
    trivy image --severity HIGH,CRITICAL --quiet "$image" 2>&1 | grep -E "Total|HIGH|CRITICAL"
  done

# 2. 证书过期检查
echo ""
echo "2. 证书过期检查"
kubectl get certificates -A -o custom-columns=\
  NAMESPACE:.metadata.namespace,\
  NAME:.metadata.name,\
  EXPIRY:.status.notAfter,\
  READY:.status.conditions[0].status

# 3. 权限审计
echo ""
echo "3. 权限审计"
kubectl get clusterrolebindings -o json | \
  jq -r '.items[] | select(.subjects != null) | "\(.metadata.name): \(.subjects | map(.kind + ":" + .name) | join(", "))"'

# 4. 网络策略审计
echo ""
echo "4. 网络策略审计"
for ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}'); do
  count=$(kubectl get networkpolicy -n $ns --no-headers 2>/dev/null | wc -l)
  echo "$ns: $count 条策略"
done

# 5. 漏洞修复跟踪
echo ""
echo "5. 待修复漏洞"
# 从扫描报告中提取未修复漏洞
```

### 4.3 每月安全任务

```bash
#!/bin/bash
# scripts/monthly-security-check.sh

echo "=== 每月安全检查 ==="

# 1. CIS Benchmark 审计
echo "1. CIS Benchmark 审计"
kube-bench run --targets=master,node,policies > /tmp/cis-monthly-$(date +%Y%m).txt

# 2. 密钥轮换
echo ""
echo "2. 密钥轮换检查"
# 检查需要轮换的密钥
kubectl get secrets -A -o json | \
  jq -r '.items[] | select(.type == "kubernetes.io/tls") | "\(.metadata.namespace)/\(.metadata.name)"'

# 3. 合规报告
echo ""
echo "3. 生成合规报告"
./scripts/generate-compliance-report.sh

# 4. 安全培训记录
echo ""
echo "4. 安全培训"
# 记录本月安全培训情况

# 5. 事件回顾
echo ""
echo "5. 安全事件回顾"
# 回顾本月安全事件
```

---

## 5. 密钥管理

### 5.1 密钥分类

| 类型 | 示例 | 存储方式 | 轮换周期 |
|------|------|---------|---------|
| TLS 证书 | 服务器证书 | Cert-Manager | 90天 |
| 数据库密码 | PostgreSQL 密码 | Vault | 30天 |
| API 密钥 | 第三方 API 密钥 | Vault | 60天 |
| 服务账户 | K8s SA Token | K8s 自动 | 自动 |
| 加密密钥 | 数据加密密钥 | Vault + KMS | 按需 |

### 5.2 Vault 配置

```yaml
# configs/vault/policy.hcl
path "secret/data/production/*" {
  capabilities = ["read", "list"]
}

path "secret/data/monitoring/*" {
  capabilities = ["read", "list"]
}

path "pki/issue/production" {
  capabilities = ["create", "update"]
}

path "transit/encrypt/production-key" {
  capabilities = ["update"]
}

path "transit/decrypt/production-key" {
  capabilities = ["update"]
}
```

### 5.3 密钥轮换流程

```bash
#!/bin/bash
# scripts/rotate-secrets.sh

SECRET_NAME=$1
NAMESPACE=$2

echo "=== 密钥轮换: $NAMESPACE/$SECRET_NAME ==="

# 1. 生成新密钥
NEW_PASSWORD=$(openssl rand -base64 32)

# 2. 更新 Vault
vault kv put -mount=secret ${NAMESPACE}/${SECRET_NAME} password="${NEW_PASSWORD}"

# 3. 更新 K8s Secret
kubectl create secret generic ${SECRET_NAME} \
  --from-literal=password="${NEW_PASSWORD}" \
  -n ${NAMESPACE} \
  --dry-run=client -o yaml | kubectl apply -f -

# 4. 重启受影响 Pod
kubectl rollout restart deployment -l app=${SECRET_NAME} -n ${NAMESPACE}

# 5. 验证
kubectl get pods -n ${NAMESPACE} -l app=${SECRET_NAME}

echo "密钥轮换完成"
```

### 5.4 密钥访问审计

```bash
#!/bin/bash
# scripts/audit-secret-access.sh

echo "=== Secret 访问审计 ==="

# 1. 检查 Secret 访问日志
kubectl logs -n kube-system kube-apiserver-* --since=24h | \
  grep -i "secret" | \
  jq -r '.user.username + " accessed " + .objectRef.name' | \
  sort | uniq -c | sort -rn

# 2. 检查 RBAC 权限
echo ""
echo "=== 有 Secret 访问权限的角色 ==="
kubectl get clusterrolebindings -o json | \
  jq -r '.items[] | select(.subjects != null) | 
    select(.roleRef.name | test("secret|admin"; "i")) | 
    "\(.metadata.name): \(.subjects | map(.kind + ":" + .name) | join(", "))"'

# 3. 检查异常访问
echo ""
echo "=== 异常访问模式 ==="
kubectl logs -n kube-system kube-apiserver-* --since=24h | \
  grep -i "secret" | \
  jq -r 'select(.responseStatus.code != 200) | .user.username + " failed to access " + .objectRef.name'
```

---

## 6. 安全审计

### 6.1 审计日志配置

```yaml
# configs/kubernetes/audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # 不记录系统组件的日志
  - level: None
    users: ["system:kube-proxy"]
    verbs: ["watch"]
    resources:
      - group: ""
        resources: ["endpoints", "services", "services/status"]

  # 记录 Secret 访问
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

  # 记录 RBAC 变更
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

  # 记录所有其他请求
  - level: Metadata
    resources:
      - group: ""
        resources: ["pods", "services", "deployments"]
```

### 6.2 审计日志分析

```bash
#!/bin/bash
# scripts/analyze-audit-logs.sh

echo "=== 审计日志分析 ==="

# 1. 检查高危操作
echo "1. 高危操作检查"
kubectl logs -n kube-system kube-apiserver-* --since=24h | \
  jq -r 'select(.verb == "delete" or .verb == "create" or .verb == "update") | 
    .user.username + " " + .verb + " " + .objectRef.resource + "/" + .objectRef.name' | \
  sort | uniq -c | sort -rn | head -20

# 2. 检查失败操作
echo ""
echo "2. 失败操作检查"
kubectl logs -n kube-system kube-apiserver-* --since=24h | \
  jq -r 'select(.responseStatus.code >= 400) | 
    .user.username + " failed " + .verb + " " + .objectRef.resource + "/" + .objectRef.name + " (HTTP " + (.responseStatus.code|tostring) + ")"' | \
  sort | uniq -c | sort -rn | head -20

# 3. 检查敏感资源访问
echo ""
echo "3. 敏感资源访问"
kubectl logs -n kube-system kube-apiserver-* --since=24h | \
  jq -r 'select(.objectRef.resource == "secrets" or .objectRef.resource == "configmaps") | 
    .user.username + " " + .verb + " " + .objectRef.resource + "/" + .objectRef.namespace + "/" + .objectRef.name' | \
  sort | uniq -c | sort -rn | head -20

# 4. 检查异常用户
echo ""
echo "4. 异常用户检查"
kubectl logs -n kube-system kube-apiserver-* --since=24h | \
  jq -r '.user.username' | \
  sort | uniq -c | sort -rn | head -10
```

### 6.3 安全基线检查

```bash
#!/bin/bash
# scripts/security-baseline-check.sh

echo "=== 安全基线检查 ==="

# 1. 检查 Pod 安全上下文
echo "1. Pod 安全上下文"
kubectl get pods -A -o json | \
  jq -r '.items[] | 
    select(.spec.securityContext.runAsNonRoot != true or 
           .spec.containers[].securityContext.allowPrivilegeEscalation == true) | 
    "\(.metadata.namespace)/\(.metadata.name) - 违反安全基线"'

# 2. 检查资源限制
echo ""
echo "2. 资源限制"
kubectl get pods -A -o json | \
  jq -r '.items[] | 
    select(.spec.containers[].resources.limits == null) | 
    "\(.metadata.namespace)/\(.metadata.name) - 无资源限制"'

# 3. 检查镜像来源
echo ""
echo "3. 镜像来源"
kubectl get pods -A -o json | \
  jq -r '.items[].spec.containers[].image' | \
  sort -u | while read image; do
    if [[ $image != *"trusted-registry.com"* ]] && [[ $image != *"docker.io/library"* ]]; then
      echo "警告: 非可信镜像 $image"
    fi
  done

# 4. 检查网络策略
echo ""
echo "4. 网络策略覆盖"
for ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}'); do
  if [ $(kubectl get networkpolicy -n $ns --no-headers 2>/dev/null | wc -l) -eq 0 ]; then
    echo "警告: $ns 无网络策略"
  fi
done

# 5. 检查 RBAC 配置
echo ""
echo "5. RBAC 配置"
kubectl get clusterrolebindings -o json | \
  jq -r '.items[] | 
    select(.subjects != null) | 
    select(.subjects[] | .kind == "User" or .kind == "ServiceAccount") | 
    "\(.metadata.name): \(.roleRef.name)"' | \
  grep -i "admin\|cluster-admin"
```

---

## 附录: 安全工具清单

| 工具 | 用途 | 部署方式 |
|------|------|---------|
| Trivy | 镜像漏洞扫描 | CLI / K8s Operator |
| Cosign | 镜像签名验证 | CLI |
| OPA Gatekeeper | 策略执行 | K8s Operator |
| Vault | 密钥管理 | Helm |
| kube-bench | CIS Benchmark | CLI |
| kube-hunter | 渗透测试 | CLI |
| Falco | 运行时安全 | K8s Operator |
| NetworkPolicy | 网络隔离 | K8s 原生 |
| PodSecurityPolicy | Pod 安全 | K8s 原生 |
| cert-manager | 证书管理 | K8s Operator |
