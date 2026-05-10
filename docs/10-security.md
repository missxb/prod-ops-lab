# 安全加固详细文档

## 1. 概述

本阶段部署完整的安全加固措施，包括：
- SSL/TLS证书管理
- SSH安全加固
- 防火墙策略
- 容器安全扫描
- K8s RBAC配置
- NetworkPolicy配置

## 2. SSL/TLS证书管理

### 2.1 使用cert-manager

```bash
# 安装cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# 创建ClusterIssuer
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
```

### 2.2 申请证书

```bash
# 创建Certificate
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: example-com
  namespace: default
spec:
  secretName: example-com-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - example.com
  - www.example.com
EOF
```

### 2.3 手动生成证书

```bash
# 生成自签名证书
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout server.key -out server.crt \
    -subj "/CN=example.com"

# 创建K8s Secret
kubectl create secret tls example-tls \
    --cert=server.crt \
    --key=server.key
```

## 3. SSH安全加固

### 3.1 配置SSH

```bash
# /etc/ssh/sshd_config
Port 2222
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
```

### 3.2 部署公钥

```bash
# 生成密钥对
ssh-keygen -t ed25519 -C "admin@example.com"

# 分发公钥
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.1.10
```

### 3.3 验证SSH

```bash
# 测试连接
ssh -p 2222 root@192.168.1.10

# 检查日志
journalctl -u sshd
```

## 4. 防火墙策略

### 4.1 配置firewalld

```bash
# 启用firewalld
systemctl enable firewalld
systemctl start firewalld

# 允许SSH
firewall-cmd --permanent --add-port=2222/tcp

# 允许HTTP/HTTPS
firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --permanent --add-port=443/tcp

# 允许K8s API
firewall-cmd --permanent --add-port=6443/tcp

# 允许NodePort范围
firewall-cmd --permanent --add-port=30000-32767/tcp

# 重新加载
firewall-cmd --reload

# 查看规则
firewall-cmd --list-all
```

### 4.2 配置iptables

```bash
# 允许SSH
iptables -A INPUT -p tcp --dport 2222 -j ACCEPT

# 允许HTTP/HTTPS
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT

# 允许K8s
iptables -A INPUT -p tcp --dport 6443 -j ACCEPT

# 保存规则
iptables-save > /etc/sysconfig/iptables
```

## 5. 容器安全扫描

### 5.1 使用Trivy扫描

```bash
# 扫描镜像
trivy image nginx:latest

# 扫描文件系统
trivy fs .

# 扫描K8s集群
trivy k8s --report summary

# 只显示高危和严重漏洞
trivy image --severity HIGH,CRITICAL nginx:latest
```

### 5.2 集成到CI/CD

```groovy
// Jenkins Pipeline
stage('Security Scan') {
    steps {
        sh 'trivy image --exit-code 1 --severity HIGH,CRITICAL myapp:latest'
    }
}
```

### 5.3 CronJob定时扫描

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: trivy-scan
spec:
  schedule: "0 2 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: trivy
            image: aquasec/trivy:latest
            command:
            - /bin/sh
            - -c
            - trivy image --exit-code 0 --severity HIGH,CRITICAL nginx:latest
          restartPolicy: OnFailure
```

## 6. K8s RBAC配置

### 6.1 创建角色

```yaml
# 管理员角色
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: admin
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]

# 只读角色
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: readonly
rules:
- apiGroups: [""]
  resources: ["*"]
  verbs: ["get", "list", "watch"]
```

### 6.2 绑定角色

```yaml
# 绑定到用户
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-binding
subjects:
- kind: User
  name: admin@example.com
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: admin
  apiGroup: rbac.authorization.k8s.io
```

### 6.3 验证RBAC

```bash
# 检查权限
kubectl auth can-i --list --as=admin@example.com

# 检查特定操作
kubectl auth can-i create pods --as=admin@example.com
kubectl auth can-i get pods --as=readonly@example.com
```

## 7. NetworkPolicy配置

### 7.1 默认拒绝策略

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
```

### 7.2 允许特定流量

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-webapp
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: webapp
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: nginx
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: database
```

### 7.3 验证NetworkPolicy

```bash
# 检查NetworkPolicy
kubectl get networkpolicy -A

# 测试连通性
kubectl exec pod1 -- ping pod2
```

## 8. 常见问题

### 8.1 证书申请失败

```bash
# 检查cert-manager日志
kubectl logs -n cert-manager deployment/cert-manager

# 检查Certificate状态
kubectl describe certificate example-com

# 检查Challenge状态
kubectl get challenges -A
```

### 8.2 SSH连接失败

```bash
# 检查SSH配置
sshd -T | grep -E "port|permitrootlogin|passwordauthentication"

# 检查防火墙
firewall-cmd --list-ports

# 检查日志
journalctl -u sshd
```

### 8.3 RBAC权限不足

```bash
# 检查角色绑定
kubectl get rolebinding,clusterrolebinding -A

# 检查权限
kubectl auth can-i --list --as=system:serviceaccount:default:default
```

## 9. 新增脚本说明

### 9.1 漏洞修复流程脚本 (`06-vulnerability-remediation.sh`)

该脚本用于执行漏洞扫描、分析、修复和报告生成的完整流程。

**使用方法：**
```bash
# 执行完整漏洞修复流程
bash scripts/10-security/06-vulnerability-remediation.sh

# 仅扫描不修复
bash scripts/10-security/06-vulnerability-remediation.sh --scan-only

# 生成修复报告
bash scripts/10-security/06-vulnerability-remediation.sh --report
```

**流程：**
1. **扫描**：使用 Trivy 扫描镜像和文件系统
2. **分析**：分析漏洞严重程度和影响范围
3. **修复**：自动修复可修复的漏洞（更新镜像、打补丁等）
4. **报告**：生成详细的漏洞修复报告

### 9.2 Trivy 扫描策略配置 (`configs/trivy/trivy-scan-config.yaml`)

该配置文件定义了 Trivy 的扫描策略和规则：

**配置内容：**
- 扫描目标（镜像、文件系统、K8s 集群）
- 严重程度过滤（Critical, High, Medium, Low）
- 忽略规则（已接受的风险）
- 输出格式（JSON, Table, SARIF）
- 扫描排除路径

**使用示例：**
```bash
# 使用自定义配置扫描
trivy image --config configs/trivy/trivy-scan-config.yaml nginx:latest

# 扫描文件系统
trivy fs --config configs/trivy/trivy-scan-config.yaml .
```

## 10. 最佳实践


1. **最小权限原则**: 只授予必要的权限
2. **定期轮换**: 定期轮换证书和密钥
3. **监控告警**: 监控安全事件
4. **审计日志**: 启用K8s审计日志
5. **安全更新**: 定期更新系统和组件
