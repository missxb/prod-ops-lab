# 企业级云原生运维平台 - 常见问题汇总

## 目录

- [部署问题](#部署问题)
- [网络问题](#网络问题)
- [存储问题](#存储问题)
- [性能问题](#性能问题)
- [安全问题](#安全问题)
- [监控问题](#监控问题)

---

## 部署问题

### 1. Pod无法启动，状态为CrashLoopBackOff

**问题描述：**
Pod反复重启，状态显示为CrashLoopBackOff。

**可能原因：**
- 应用启动失败
- 依赖服务未就绪
- 资源限制过低
- 配置错误

**解决方案：**
```bash
# 1. 查看Pod状态
kubectl get pods -n <namespace> <pod-name>

# 2. 查看Pod事件
kubectl describe pod -n <namespace> <pod-name>

# 3. 查看Pod日志
kubectl logs -n <namespace> <pod-name> --previous

# 4. 进入Pod调试（如果Pod能启动）
kubectl exec -it -n <namespace> <pod-name> -- /bin/sh

# 5. 检查资源限制
kubectl get pod -n <namespace> <pod-name> -o yaml | grep -A 10 resources
```

**预防措施：**
- 为Pod配置合适的资源限制
- 配置健康检查探针
- 使用Init容器处理依赖服务
- 记录详细的日志

### 2. Service无法访问

**问题描述：**
Service创建后无法访问，或访问超时。

**可能原因：**
- Service selector与Pod label不匹配
- Pod未就绪
- 网络策略限制
- DNS解析失败

**解决方案：**
```bash
# 1. 检查Service配置
kubectl get svc -n <namespace> <service-name> -o yaml

# 2. 检查Endpoints
kubectl get endpoints -n <namespace> <service-name>

# 3. 检查Pod标签
kubectl get pods -n <namespace> --show-labels

# 4. 检查DNS解析
kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup <service-name>

# 5. 检查网络策略
kubectl get networkpolicies -n <namespace>
```

### 3. Deployment更新失败

**问题描述：**
Deployment滚动更新失败，新版本Pod无法启动。

**可能原因：**
- 镜像拉取失败
- 依赖资源未创建
- 资源配额不足
- 节点资源不足

**解决方案：**
```bash
# 1. 查看Deployment状态
kubectl rollout status deployment/<deployment-name> -n <namespace>

# 2. 查看Deployment历史
kubectl rollout history deployment/<deployment-name> -n <namespace>

# 3. 回滚到上一版本
kubectl rollout undo deployment/<deployment-name> -n <namespace>

# 4. 检查资源配额
kubectl describe resourcequota -n <namespace>

# 5. 检查节点资源
kubectl top nodes
```

### 4. ConfigMap/Secret挂载失败

**问题描述：**
Pod中的ConfigMap或Secret挂载失败。

**可能原因：**
- ConfigMap/Secret不存在
- 文件名冲突
- 挂载路径错误
- 权限问题

**解决方案：**
```bash
# 1. 检查ConfigMap/Secret是否存在
kubectl get configmap -n <namespace> <configmap-name>
kubectl get secret -n <namespace> <secret-name>

# 2. 检查ConfigMap/Secret内容
kubectl describe configmap -n <namespace> <configmap-name>

# 3. 检查Pod日志
kubectl logs -n <namespace> <pod-name>

# 4. 检查挂载路径
kubectl get pod -n <namespace> <pod-name> -o yaml | grep -A 20 volumes
```

### 5. PV/PVC绑定失败

**问题描述：**
PersistentVolumeClaim无法绑定到PersistentVolume。

**可能原因：**
- StorageClass不存在
- PV容量不足
- 访问模式不匹配
- 节点亲和性不满足

**解决方案：**
```bash
# 1. 检查PVC状态
kubectl get pvc -n <namespace> <pvc-name>

# 2. 检查PV状态
kubectl get pv

# 3. 检查StorageClass
kubectl get storageclass

# 4. 检查PVC详情
kubectl describe pvc -n <namespace> <pvc-name>

# 5. 检查PV详情
kubectl describe pv <pv-name>
```

---

## 网络问题

### 1. Pod间通信失败

**问题描述：**
Pod之间无法通信，或Pod无法访问Service。

**可能原因：**
- CNI插件配置错误
- 网络策略限制
- 节点网络配置错误
- 防火墙规则

**解决方案：**
```bash
# 1. 检查Pod IP
kubectl get pod -n <namespace> <pod-name> -o wide

# 2. 从一个Pod ping另一个Pod
kubectl exec -it -n <namespace> <pod-name-1> -- ping <pod-ip-2>

# 3. 检查网络策略
kubectl get networkpolicies -n <namespace>

# 4. 检查CNI插件
kubectl get pods -n kube-system | grep -E "calico|flannel|cilium"

# 5. 检查节点网络配置
ip addr show
route -n
```

### 2. DNS解析失败

**问题描述：**
Pod无法解析Service名称或外部域名。

**可能原因：**
- CoreDNS未运行
- DNS配置错误
- 网络策略限制
- DNS服务不可用

**解决方案：**
```bash
# 1. 检查CoreDNS状态
kubectl get pods -n kube-system -l k8s-app=kube-dns

# 2. 检查CoreDNS配置
kubectl get configmap -n kube-system coredns -o yaml

# 3. 测试DNS解析
kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup kubernetes.default

# 4. 检查resolv.conf
kubectl exec -it -n <namespace> <pod-name> -- cat /etc/resolv.conf

# 5. 检查DNS服务
kubectl get svc -n kube-system kube-dns
```

### 3. Ingress无法访问

**问题描述：**
Ingress创建后无法通过域名访问。

**可能原因：**
- Ingress Controller未运行
- TLS证书配置错误
- 后端Service不可用
- DNS未解析到Ingress IP

**解决方案：**
```bash
# 1. 检查Ingress状态
kubectl get ingress -n <namespace> <ingress-name>

# 2. 检查Ingress Controller
kubectl get pods -n ingress-nginx

# 3. 检查Ingress详情
kubectl describe ingress -n <namespace> <ingress-name>

# 4. 检查TLS证书
kubectl get secret -n <namespace> <tls-secret>

# 5. 检查DNS解析
nslookup <domain-name>
```

### 4. NodePort无法访问

**问题描述：**
通过NodePort无法访问Service。

**可能原因：**
- 节点防火墙限制
- NodePort范围未开放
- Service选择器错误
- Pod未就绪

**解决方案：**
```bash
# 1. 检查Service状态
kubectl get svc -n <namespace> <service-name>

# 2. 检查Endpoints
kubectl get endpoints -n <namespace> <service-name>

# 3. 检查防火墙
sudo iptables -L -n | grep <nodeport>

# 4. 从节点本地测试
curl http://localhost:<nodeport>

# 5. 检查节点IP
kubectl get nodes -o wide
```

### 5. LoadBalancer无法访问

**问题描述：**
LoadBalancer类型的Service无法通过外部IP访问。

**可能原因：**
- 云提供商LB未创建
- 安全组/防火墙限制
- 健康检查失败
- 后端Pod未就绪

**解决方案：**
```bash
# 1. 检查Service状态
kubectl get svc -n <namespace> <service-name>

# 2. 检查云控制台LB状态
# 根据云提供商查看LB状态

# 3. 检查安全组/防火墙
# 确保LB端口已开放

# 4. 检查Pod健康状态
kubectl get endpoints -n <namespace> <service-name>

# 5. 检查LB健康检查配置
# 确保健康检查路径和端口正确
```

---

## 存储问题

### 1. PVC无法绑定到PV

**问题描述：**
PersistentVolumeClaim长时间处于Pending状态。

**可能原因：**
- 没有满足要求的PV
- StorageClass配置错误
- 访问模式不匹配
- 资源容量不足

**解决方案：**
```bash
# 1. 检查PVC状态
kubectl get pvc -n <namespace> <pvc-name>

# 2. 检查PV列表
kubectl get pv

# 3. 检查StorageClass
kubectl get storageclass -o yaml

# 4. 检查PVC详情
kubectl describe pvc -n <namespace> <pvc-name>

# 5. 检查是否有可用的PV
kubectl get pv --field-selector spec.claimRef.name=<pvc-name>
```

### 2. PVC挂载失败

**问题描述：**
Pod启动时无法挂载PVC。

**可能原因：**
- PVC未绑定
- PV不可用
- 节点存储空间不足
- 挂载路径冲突

**解决方案：**
```bash
# 1. 检查Pod事件
kubectl describe pod -n <namespace> <pod-name>

# 2. 检查PVC状态
kubectl get pvc -n <namespace> <pvc-name>

# 3. 检查PV状态
kubectl get pv

# 4. 检查节点存储空间
df -h

# 5. 检查节点存储信息
kubectl describe node <node-name> | grep -A 10 "Allocated resources"
```

### 3. 存储性能问题

**问题描述：**
Pod中的存储操作性能低下。

**可能原因：**
- 存储后端性能不足
- 网络延迟高
- 文件系统配置不当
- 存储类型选择错误

**解决方案：**
```bash
# 1. 检查存储类型
kubectl get pv <pv-name> -o yaml | grep -A 5 persistentVolumeReclaimPolicy

# 2. 测试存储性能
kubectl exec -it -n <namespace> <pod-name> -- dd if=/dev/zero of=/tmp/test bs=1M count=100

# 3. 检查网络延迟
kubectl exec -it -n <namespace> <pod-name> -- ping <storage-ip>

# 4. 检查存储IOPS
# 使用fio等工具测试IOPS

# 5. 考虑使用更快的存储类型
# 如SSD、NVMe等
```

### 4. 数据持久化问题

**问题描述：**
Pod重启后数据丢失。

**可能原因：**
- 使用emptyDir存储
- PVC回收策略问题
- PV未正确配置

**解决方案：**
```bash
# 1. 检查Pod存储配置
kubectl get pod -n <namespace> <pod-name> -o yaml | grep -A 20 volumes

# 2. 检查PVC配置
kubectl get pvc -n <namespace> -o yaml

# 3. 检查PV配置
kubectl get pv -o yaml

# 4. 确保使用持久化存储
# 使用PVC而不是emptyDir

# 5. 检查回收策略
kubectl get pv <pv-name> -o yaml | grep persistentVolumeReclaimPolicy
```

### 5. 存储扩容问题

**问题描述：**
需要扩容PVC但无法执行。

**可能原因：**
- StorageClass不支持扩容
- PV已达上限
- 云存储限制

**解决方案：**
```bash
# 1. 检查StorageClass是否支持扩容
kubectl get storageclass <storageclass-name> -o yaml | grep allowVolumeExpansion

# 2. 检查PVC当前大小
kubectl get pvc -n <namespace> <pvc-name> -o yaml | grep resources

# 3. 修改PVC大小
kubectl patch pvc -n <namespace> <pvc-name> -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'

# 4. 检查PV大小
kubectl get pv <pv-name> -o yaml | grep capacity

# 5. 注意：扩容可能需要重启Pod
```

---

## 性能问题

### 1. Pod启动缓慢

**问题描述：**
Pod启动时间过长，影响服务可用性。

**可能原因：**
- 镜像拉取慢
- 依赖服务未就绪
- 资源不足
- Init容器耗时

**解决方案：**
```bash
# 1. 检查Pod事件
kubectl describe pod -n <namespace> <pod-name>

# 2. 检查镜像拉取时间
kubectl get events -n <namespace> | grep Pulling

# 3. 使用镜像预热
# 提前拉取镜像到节点

# 4. 优化镜像大小
# 使用多阶段构建，减小镜像体积

# 5. 配置镜像拉取策略
# 使用imagePullPolicy: IfNotPresent
```

### 2. 节点资源不足

**问题描述：**
节点CPU或内存使用率过高，Pod无法调度。

**可能原因：**
- 节点资源配额过低
- Pod资源请求不合理
- 资源碎片化
- 系统进程占用过多

**解决方案：**
```bash
# 1. 检查节点资源使用
kubectl top nodes

# 2. 检查Pod资源使用
kubectl top pods -n <namespace>

# 3. 检查节点资源分配
kubectl describe node <node-name> | grep -A 20 "Allocated resources"

# 4. 调整Pod资源请求
kubectl patch deployment -n <namespace> <deployment-name> -p '{"spec":{"template":{"spec":{"containers":[{"name":"<container-name>","resources":{"requests":{"cpu":"200m","memory":"256Mi"}}}]}}}}'

# 5. 添加节点
kubectl label node <node-name> node-role.kubernetes.io/worker=
```

### 3. 网络延迟高

**问题描述：**
Pod间网络通信延迟高。

**可能原因：**
- CNI插件性能问题
- 网络策略过多
- 跨节点通信延迟
- 网络带宽不足

**解决方案：**
```bash
# 1. 测试网络延迟
kubectl exec -it -n <namespace> <pod-1> -- ping <pod-ip-2>

# 2. 检查CNI插件状态
kubectl get pods -n kube-system | grep -E "calico|flannel|cilium"

# 3. 检查网络策略数量
kubectl get networkpolicies -n <namespace>

# 4. 使用Pod亲和性
# 将相关Pod调度到同一节点

# 5. 优化网络配置
# 调整MTU、TCP缓冲区等参数
```

### 4. 应用响应缓慢

**问题描述：**
应用响应时间过长，用户体验差。

**可能原因：**
- 后端服务性能瓶颈
- 数据库查询慢
- 缓存命中率低
- 资源限制过低

**解决方案：**
```bash
# 1. 检查Pod资源使用
kubectl top pods -n <namespace>

# 2. 检查应用日志
kubectl logs -n <namespace> <pod-name> --tail=100

# 3. 检查后端服务状态
kubectl get pods -n <namespace> -l app=<backend-app>

# 4. 优化应用代码
# 使用profiling工具分析性能瓶颈

# 5. 增加副本数
kubectl scale deployment -n <namespace> <deployment-name> --replicas=5
```

### 5. 存储I/O性能差

**问题描述：**
存储操作延迟高，影响应用性能。

**可能原因：**
- 存储后端性能不足
- 网络存储延迟
- 文件系统配置不当
- 并发访问过多

**解决方案：**
```bash
# 1. 测试存储性能
kubectl exec -it -n <namespace> <pod-name> -- dd if=/dev/zero of=/tmp/test bs=1M count=100

# 2. 检查存储类型
kubectl get pv <pv-name> -o yaml | grep -A 5 persistentVolumeReclaimPolicy

# 3. 使用本地存储
# 对于性能敏感的应用，使用本地SSD

# 4. 优化文件系统
# 使用ext4、xfs等高性能文件系统

# 5. 增加存储容量
# 扩容PVC，避免存储空间不足
```

---

## 安全问题

### 1. 镜像安全问题

**问题描述：**
容器镜像存在安全漏洞。

**可能原因：**
- 使用不安全的基础镜像
- 未及时更新镜像
- 镜像中包含敏感信息
- 镜像来源不可信

**解决方案：**
```bash
# 1. 扫描镜像漏洞
trivy image <image-name>:<tag>

# 2. 使用官方镜像
# 优先使用官方或可信来源的镜像

# 3. 定期更新镜像
# 重建镜像以包含最新的安全补丁

# 4. 使用镜像签名
# 验证镜像来源和完整性

# 5. 使用最小化镜像
# 使用distroless或alpine镜像
```

### 2. 权限配置问题

**问题描述：**
容器以root权限运行，存在安全风险。

**可能原因：**
- 容器以root用户运行
- 容器具有特权模式
- RBAC配置不当
- ServiceAccount权限过大

**解决方案：**
```bash
# 1. 检查容器运行用户
kubectl get pod -n <namespace> <pod-name> -o yaml | grep securityContext

# 2. 配置非root用户运行
# 在Pod spec中配置securityContext.runAsUser

# 3. 禁用特权模式
# 设置securityContext.privileged: false

# 4. 检查RBAC配置
kubectl get clusterrolebindings -o wide
kubectl get rolebindings -n <namespace> -o wide

# 5. 最小权限原则
# 为ServiceAccount配置最小必要权限
```

### 3. 网络安全问题

**问题描述：**
网络暴露敏感端口或服务。

**可能原因：**
- Service暴露过多端口
- 网络策略未配置
- 防火墙规则不严格
- 使用不安全的协议

**解决方案：**
```bash
# 1. 检查Service端口
kubectl get svc -n <namespace> -o wide

# 2. 配置网络策略
kubectl apply -f network-policy.yaml

# 3. 使用TLS/SSL
# 为所有对外服务配置HTTPS

# 4. 限制Service类型
# 仅必要时使用LoadBalancer或NodePort

# 5. 监控网络流量
# 使用网络监控工具检测异常流量
```

### 4. 敏感信息泄露

**问题描述：**
敏感信息（如密码、密钥）被泄露。

**可能原因：**
- Secret未正确加密
- 敏感信息硬编码在配置中
- 日志中包含敏感信息
- 环境变量泄露

**解决方案：**
```bash
# 1. 检查Secret配置
kubectl get secret -n <namespace> -o yaml

# 2. 使用外部密钥管理
# 如HashiCorp Vault、AWS Secrets Manager

# 3. 加密etcd数据
# 配置etcd加密

# 4. 清理日志中的敏感信息
# 使用日志脱敏工具

# 5. 使用Secret挂载而非环境变量
# 通过volume挂载Secret文件
```

### 5. 集群安全配置问题

**问题描述：**
Kubernetes集群安全配置不完善。

**可能原因：**
- API Server未配置认证
- etcd未加密
- 审计日志未启用
- 安全扫描未执行

**解决方案：**
```bash
# 1. 检查API Server配置
kubectl get configmap -n kube-system kube-apiserver -o yaml

# 2. 启用API Server审计日志
# 配置审计策略和日志路径

# 3. 加密etcd数据
# 配置EncryptionConfiguration

# 4. 执行安全扫描
# 使用kube-bench、kube-hunter等工具

# 5. 配置Pod安全策略
# 使用PodSecurityPolicy或PodSecurityAdmission
```

---

## 监控问题

### 1. Prometheus无法采集指标

**问题描述：**
Prometheus无法采集到集群或应用的指标。

**可能原因：**
- Prometheus配置错误
- 目标不可达
- 网络策略限制
- 服务发现失败

**解决方案：**
```bash
# 1. 检查Prometheus状态
kubectl get pods -n monitoring

# 2. 检查Prometheus配置
kubectl get configmap -n monitoring prometheus-config -o yaml

# 3. 检查目标状态
# 访问Prometheus Web UI查看targets

# 4. 检查ServiceMonitor
kubectl get servicemonitor -n monitoring

# 5. 检查网络策略
kubectl get networkpolicies -n monitoring
```

### 2. Grafana无法显示数据

**问题描述：**
Grafana仪表板无法显示数据或显示不正确。

**可能原因：**
- 数据源配置错误
- 查询语句错误
- 时间范围设置不当
- 仪表板配置错误

**解决方案：**
```bash
# 1. 检查Grafana数据源配置
# 访问Grafana Web UI检查数据源

# 2. 测试数据源连接
# 在Grafana中测试数据源连接

# 3. 检查查询语句
# 使用Prometheus Web UI测试查询

# 4. 检查时间范围
# 确保Grafana时间范围包含数据

# 5. 导入标准仪表板
# 使用Kubernetes标准仪表板
```

### 3. 告警规则不生效

**问题描述：**
配置的告警规则未触发或触发不准确。

**可能原因：**
- 告警规则语法错误
- 阈值设置不当
- 告警通知渠道配置错误
- 告警抑制规则冲突

**解决方案：**
```bash
# 1. 检查告警规则语法
# 使用Prometheus Rule Checker工具

# 2. 检查告警状态
# 访问Prometheus Web UI查看alerts

# 3. 测试告警规则
# 手动触发告警测试

# 4. 检查通知渠道配置
# 验证Email、Slack等配置

# 5. 检查告警抑制规则
# 确保没有冲突的抑制规则
```

### 4. 日志收集不完整

**问题描述：**
日志收集不完整或丢失。

**可能原因：**
- 日志收集器配置错误
- 日志格式不正确
- 存储空间不足
- 网络传输问题

**解决方案：**
```bash
# 1. 检查日志收集器状态
kubectl get pods -n logging

# 2. 检查日志收集配置
kubectl get configmap -n logging fluentd-config -o yaml

# 3. 检查日志文件
kubectl logs -n logging <fluentd-pod>

# 4. 检查存储空间
df -h /var/log

# 5. 检查网络连接
# 确保日志收集器能连接到存储后端
```

### 5. 监控资源消耗过高

**问题描述：**
监控系统本身消耗过多资源。

**可能原因：**
- 指标保留时间过长
- 查询过于频繁
- 仪表板过多
- 资源限制不当

**解决方案：**
```bash
# 1. 检查Prometheus资源使用
kubectl top pods -n monitoring

# 2. 优化指标保留配置
# 调整retention时间

# 3. 优化查询
# 使用Recording Rules预计算常用查询

# 4. 减少仪表板数量
# 合并或删除不必要的仪表板

# 5. 调整资源限制
# 为监控组件配置合适的资源限制
```

---

## 故障排查工具

### 1. kubectl调试命令

```bash
# 查看Pod状态
kubectl get pods -n <namespace> -o wide

# 查看Pod事件
kubectl describe pod -n <namespace> <pod-name>

# 查看Pod日志
kubectl logs -n <namespace> <pod-name> --previous

# 进入Pod调试
kubectl exec -it -n <namespace> <pod-name> -- /bin/sh

# 调试Pod（无应用的调试容器）
kubectl debug -it -n <namespace> <pod-name> --image=busybox --target=<container-name>
```

### 2. 网络调试命令

```bash
# 测试网络连通性
kubectl run -it --rm debug --image=busybox --restart=Never -- ping <target-ip>

# 测试DNS解析
kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup <service-name>

# 测试端口连通性
kubectl run -it --rm debug --image=busybox --restart=Never -- nc -zv <service-name> <port>

# 抓包分析
kubectl run -it --rm debug --image=nicolaka/netshoot --restart=Never -- tcpdump -i eth0
```

### 3. 性能分析工具

```bash
# 节点资源使用
kubectl top nodes

# Pod资源使用
kubectl top pods -n <namespace>

# 节点资源分配
kubectl describe node <node-name> | grep -A 20 "Allocated resources"

# 节点存储使用
kubectl describe node <node-name> | grep -A 10 "Allocated resources"
```

### 4. 日志分析工具

```bash
# 查看Pod日志
kubectl logs -n <namespace> <pod-name> --tail=100

# 实时查看日志
kubectl logs -f -n <namespace> <pod-name>

# 查看多个Pod日志
kubectl logs -l app=<app-name> -n <namespace> --all-containers

# 查看历史日志
kubectl logs -n <namespace> <pod-name> --previous
```

### 5. 配置检查工具

```bash
# 检查YAML语法
kubectl apply -f <file.yaml> --dry-run=client

# 检查资源配额
kubectl describe resourcequota -n <namespace>

# 检查RBAC
kubectl auth can-i --list -n <namespace>

# 检查网络策略
kubectl get networkpolicies -n <namespace> -o yaml
```

---

## 联系支持

如果以上解决方案都无法解决您的问题，请通过以下方式联系支持团队：

- **工单系统**: https://support.example.com
- **即时通讯**: #k8s-support (Slack)
- **电话**: 400-xxx-xxxx
- **邮箱**: support@example.com

**请在联系支持时提供以下信息：**
- Kubernetes版本
- 问题现象描述
- 相关日志和事件
- 已尝试的解决方案
- 环境配置信息
