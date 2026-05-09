# 故障排查手册

## 1. 排查方法论

### 1.1 排查思路

```
问题定位流程：

1. 确认现象 → 服务不可用？性能下降？数据丢失？
2. 确定范围 → 单节点？全部节点？特定服务？
3. 检查日志 → 系统日志？应用日志？K8s事件？
4. 检查资源 → CPU/内存/磁盘/网络
5. 检查配置 → 配置文件？环境变量？权限？
6. 验证连接 → 网络连通？端口监听？DNS解析？
7. 逐步缩小 → 二分法排除
```

### 1.2 常用工具

```bash
# 系统工具
top, htop, vmstat, iostat, sar, netstat, ss
df, du, lsblk, fdisk
ping, traceroute, nslookup, dig, curl, wget

# K8s工具
kubectl, crictl, ctr, helm, jq, yq

# 日志工具
journalctl, dmesg, tail, grep, awk, sed
```

## 2. K8s集群问题

### 2.1 节点NotReady

**现象:** kubectl get nodes 显示 NotReady

**可能原因:**
- kubelet未运行或崩溃
- 容器运行时(containerd)故障
- 网络插件(Calico)故障
- 资源不足(磁盘/内存压力)

**排查命令:**
```bash
# 检查kubelet状态
systemctl status kubelet
journalctl -u kubelet -f --no-pager -n 50

# 检查容器运行时
systemctl status containerd
crictl info
crictl pods

# 检查网络插件
kubectl get pods -n kube-system -l k8s-app=calico-node
kubectl logs -n kube-system -l k8s-app=calico-node --tail=50

# 检查节点资源
df -h
free -m
dmesg | tail -20
```

**解决方案:**
```bash
# 重启kubelet
systemctl restart kubelet

# 重启containerd
systemctl restart containerd

# 如果是磁盘压力，清理空间
crictl rmi --prune
docker system prune -a

# 如果是网络问题，重启Calico
kubectl delete pod -n kube-system -l k8s-app=calico-node
```

### 2.2 Pod CrashLoopBackOff

**现象:** Pod不断重启

**可能原因:**
- 应用启动失败
- 配置错误
- 依赖服务不可用
- 资源不足(OOMKilled)

**排查命令:**
```bash
# 查看Pod状态
kubectl describe pod <pod-name>

# 查看当前日志
kubectl logs <pod-name>

# 查看上一次崩溃日志
kubectl logs <pod-name> --previous

# 检查资源使用
kubectl top pod <pod-name>

# 检查Pod事件
kubectl get events --field-selector involvedObject.name=<pod-name>
```

**解决方案:**
```bash
# 如果是OOMKilled，增加资源限制
kubectl patch deployment <deploy-name> -p '{"spec":{"template":{"spec":{"containers":[{"name":"app","resources":{"limits":{"memory":"512Mi"}}}]}}}}'

# 如果是配置错误，检查ConfigMap
kubectl get configmap <cm-name> -o yaml

# 如果是镜像问题，检查镜像是否存在
docker pull <image>
```

### 2.3 Pod Pending

**现象:** Pod一直处于Pending状态

**可能原因:**
- 节点资源不足
- PVC未绑定
- 节点亲和性不匹配
-污点(taint)未容忍

**排查命令:**
```bash
# 查看Pod事件
kubectl describe pod <pod-name>

# 查看节点资源
kubectl top nodes
kubectl describe nodes

# 查看PVC状态
kubectl get pvc
kubectl describe pvc <pvc-name>

# 查看调度失败原因
kubectl get events --field-selector reason=FailedScheduling
```

**解决方案:**
```bash
# 如果是资源不足，扩容节点或减少Pod资源请求
kubectl patch deployment <deploy-name> -p '{"spec":{"template":{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"100m","memory":"128Mi"}}}]}}}}'

# 如果是PVC问题，检查NFS
showmount -e <nfs-server>

# 如果是亲和性问题，调整nodeSelector
kubectl patch deployment <deploy-name> -p '{"spec":{"template":{"spec":{"nodeSelector":{}}}}}'
```

### 2.4 Service无法访问

**现象:** 通过Service无法访问应用

**可能原因:**
- Service selector不匹配
- Pod未就绪
- 端口配置错误
- kube-proxy故障

**排查命令:**
```bash
# 检查Service
kubectl describe svc <svc-name>

# 检查Endpoints
kubectl get endpoints <svc-name>

# 检查Pod标签
kubectl get pods --show-labels

# 检查kube-proxy
kubectl get pods -n kube-system -l k8s-app=kube-proxy
kubectl logs -n kube-system -l k8s-app=kube-proxy

# 测试连接
kubectl run test --image=busybox --rm -it -- wget -qO- http://<svc-name>:<port>
```

**解决方案:**
```bash
# 如果selector不匹配，修改Service
kubectl patch svc <svc-name> -p '{"spec":{"selector":{"app":"myapp"}}}'

# 如果Pod未就绪，检查readinessProbe
kubectl describe pod <pod-name>

# 如果端口错误，修改Service
kubectl patch svc <svc-name> -p '{"spec":{"ports":[{"port":80,"targetPort":8080}]}}'
```

### 2.5 DNS解析失败

**现象:** Pod内无法解析Service名称

**可能原因:**
- CoreDNS故障
- 配置错误
- 网络问题

**排查命令:**
```bash
# 检查CoreDNS
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns

# 检查CoreDNS配置
kubectl get configmap -n kube-system coredns -o yaml

# 测试DNS
kubectl run test --image=busybox --rm -it -- nslookup kubernetes.default
kubectl run test --image=busybox --rm -it -- nslookup <svc-name>.<namespace>.svc.cluster.local
```

**解决方案:**
```bash
# 重启CoreDNS
kubectl delete pod -n kube-system -l k8s-app=kube-dns

# 检查resolv.conf
kubectl run test --image=busybox --rm -it -- cat /etc/resolv.conf
```

## 3. 网络问题

### 3.1 Pod间通信失败

**现象:** 两个Pod之间无法ping通

**可能原因:**
- Calico网络插件故障
- NetworkPolicy阻止
- CNI配置错误

**排查命令:**
```bash
# 检查Calico
kubectl get pods -n kube-system -l k8s-app=calico-node
kubectl logs -n kube-system -l k8s-app=calico-node

# 检查NetworkPolicy
kubectl get networkpolicy -A

# 检查Pod IP
kubectl get pod <pod-name> -o wide

# 测试连通性
kubectl exec <pod-name> -- ping <other-pod-ip>
```

**解决方案:**
```bash
# 重启Calico
kubectl delete pod -n kube-system -l k8s-app=calico-node

# 如果是NetworkPolicy，删除或修改
kubectl delete networkpolicy <np-name>
```

### 3.2 Ingress不工作

**现象:** 通过域名无法访问应用

**可能原因:**
- Ingress Controller未运行
- Ingress配置错误
- DNS未解析
- TLS证书问题

**排查命令:**
```bash
# 检查Ingress Controller
kubectl get pods -n ingress-nginx
kubectl logs -n ingress-nginx <controller-pod>

# 检查Ingress资源
kubectl describe ingress <ingress-name>

# 检查DNS
nslookup <域名>
dig <域名>

# 检查证书
kubectl get certificates -A
kubectl describe certificate <cert-name>
```

**解决方案:**
```bash
# 如果Ingress Controller未运行，重启
kubectl delete pod -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx

# 如果是DNS问题，配置hosts文件
echo "192.168.1.20 <域名>" >> /etc/hosts

# 如果是证书问题，重新签发
kubectl delete secret <secret-name>
```

## 4. 存储问题

### 4.1 PVC Pending

**现象:** PVC一直处于Pending状态

**可能原因:**
- StorageClass不存在
- NFS Provisioner故障
- NFS服务不可用

**排查命令:**
```bash
# 检查PVC
kubectl describe pvc <pvc-name>

# 检查StorageClass
kubectl get sc

# 检查NFS Provisioner
kubectl get pods -n nfs-provisioner
kubectl logs -n nfs-provisioner <pod-name>

# 检查NFS服务
showmount -e <nfs-server>
mount -t nfs <nfs-server>:/exports /mnt
```

**解决方案:**
```bash
# 如果NFS不可用，重启NFS服务
systemctl restart nfs-server

# 如果Provisioner故障，重启
kubectl delete pod -n nfs-provisioner -l app=nfs-provisioner

# 如果StorageClass不存在，创建
kubectl apply -f configs/nfs/storageclass.yaml
```

### 4.2 PV绑定失败

**现象:** PV和PVC无法绑定

**可能原因:**
- 容量不匹配
- 访问模式不匹配
- StorageClass不匹配

**排查命令:**
```bash
# 检查PV
kubectl get pv
kubectl describe pv <pv-name>

# 检查PVC
kubectl get pvc
kubectl describe pvc <pvc-name>

# 检查绑定状态
kubectl get pv,pvc --show-kind
```

**解决方案:**
```bash
# 修改PVC匹配PV
kubectl patch pvc <pvc-name> -p '{"spec":{"storageClassName":"nfs-client"}}'
```

## 5. CI/CD问题

### 5.1 GitLab无法访问

**现象:** 无法访问GitLab Web界面

**可能原因:**
- Pod未运行
- Service配置错误
- Ingress配置错误

**排查命令:**
```bash
# 检查Pod
kubectl get pods -n gitlab
kubectl logs -n gitlab <pod-name>

# 检查Service
kubectl get svc -n gitlab

# 检查Ingress
kubectl get ingress -n gitlab
```

**解决方案:**
```bash
# 重启GitLab
kubectl delete pod -n gitlab -l app=gitlab

# 检查资源
kubectl top pods -n gitlab
```

### 5.2 Jenkins构建失败

**现象:** Jenkins Pipeline执行失败

**可能原因:**
- 插件问题
- 配置错误
- 权限不足

**排查命令:**
```bash
# 检查Jenkins日志
kubectl logs -n jenkins <pod-name>

# 检查Pipeline日志
# 在Jenkins UI查看Console Output

# 检查RBAC
kubectl auth can-i --list --as=system:serviceaccount:jenkins:default
```

**解决方案:**
```bash
# 重启Jenkins
kubectl delete pod -n jenkins -l app=jenkins

# 检查插件
# 在Jenkins UI Manage Jenkins -> Manage Plugins
```

### 5.3 Harbor推送失败

**现象:** docker push到Harbor失败

**可能原因:**
- Harbor未运行
- TLS证书问题
- 项目权限问题

**排查命令:**
```bash
# 检查Harbor
kubectl get pods -n harbor
kubectl logs -n harbor <pod-name>

# 测试连接
curl -k https://harbor.local/v2/

# 检查证书
openssl s_client -connect harbor.local:443
```

**解决方案:**
```bash
# 重启Harbor
kubectl delete pod -n harbor -l app=harbor

# 如果是证书问题，添加到信任
cp ca.crt /etc/pki/ca-trust/source/anchors/
update-ca-trust

# 如果是权限问题，在Harbor UI配置
```

## 6. 监控日志问题

### 6.1 Prometheus无数据

**现象:** Prometheus查询无结果

**可能原因:**
- Prometheus未运行
- ServiceMonitor配置错误
- 目标不可达

**排查命令:**
```bash
# 检查Prometheus
kubectl get pods -n monitoring
kubectl logs -n monitoring <prometheus-pod>

# 检查目标
curl http://prometheus.local:9090/api/v1/targets

# 检查ServiceMonitor
kubectl get servicemonitor -A
```

**解决方案:**
```bash
# 重启Prometheus
kubectl delete pod -n monitoring -l app=prometheus

# 检查抓取配置
kubectl get configmap -n monitoring prometheus-config -o yaml
```

### 6.2 Grafana无法显示

**现象:** Grafana Dashboard无数据

**可能原因:**
- 数据源配置错误
- Prometheus不可达
- 查询语法错误

**排查命令:**
```bash
# 检查Grafana
kubectl get pods -n monitoring
kubectl logs -n monitoring <grafana-pod>

# 检查数据源
curl -u admin:password http://grafana.local:3000/api/datasources

# 测试查询
curl "http://prometheus.local:9090/api/v1/query?query=up"
```

**解决方案:**
```bash
# 重启Grafana
kubectl delete pod -n monitoring -l app=grafana

# 重新配置数据源
kubectl apply -f configs/grafana/datasource.yaml
```

### 6.3 ELK索引失败

**现象:** Kibana查不到日志

**可能原因:**
- Elasticsearch故障
- Fluentd配置错误
- 索引模式不匹配

**排查命令:**
```bash
# 检查ES
kubectl get pods -n logging
curl http://elasticsearch.local:9200/_cluster/health

# 检查Fluentd
kubectl get pods -n logging -l app=fluentd
kubectl logs -n logging <fluentd-pod>

# 检查索引
curl http://elasticsearch.local:9200/_cat/indices
```

**解决方案:**
```bash
# 重启Fluentd
kubectl delete pod -n logging -l app=fluentd

# 检查Fluentd配置
kubectl get configmap -n logging fluentd-config -o yaml
```

## 7. 高可用问题

### 7.1 Keepalived VIP漂移

**现象:** VIP无法漂移或频繁漂移

**可能原因:**
- 网络问题
- 健康检查失败
- 配置错误

**排查命令:**
```bash
# 检查Keepalived
systemctl status keepalived
journalctl -u keepalived -f

# 检查VIP
ip addr show | grep 192.168.1.100

# 检查健康检查脚本
bash /etc/keepalived/check_apiserver.sh
```

**解决方案:**
```bash
# 重启Keepalived
systemctl restart keepalived

# 检查防火墙(允许VRRP协议)
firewall-cmd --add-protocol=vrrp --permanent
firewall-cmd --reload
```

### 7.2 MySQL主从延迟

**现象:** Slave lag很大

**可能原因:**
- 网络延迟
- 大事务
- Slave性能不足

**排查命令:**
```bash
# 检查主从状态
mysql -e "SHOW SLAVE STATUS\G"

# 检查网络延迟
ping <master-ip>

# 检查大事务
mysql -e "SHOW PROCESSLIST"
```

**解决方案:**
```bash
# 如果是大事务，优化SQL
# 如果是性能不足，增加Slave资源
# 如果是网络问题，检查网络
```

### 7.3 Redis Sentinel故障转移

**现象:** Sentinel无法自动故障转移

**可能原因:**
- Sentinel配置错误
- 网络问题
- 主节点假死

**排查命令:**
```bash
# 检查Sentinel状态
redis-cli -h <sentinel-ip> -p 26379 sentinel masters

# 检查Sentinel日志
cat /var/log/redis/sentinel.log

# 测试故障转移
redis-cli -h <sentinel-ip> -p 26379 sentinel failover mymaster
```

**解决方案:**
```bash
# 重启Sentinel
systemctl restart redis-sentinel

# 检查配置
cat /etc/redis/sentinel.conf
```

## 8. 性能问题

### 8.1 节点资源不足

**现象:** Pod被驱逐或无法调度

**可能原因:**
- CPU/内存不足
- 磁盘空间不足
- 进程数过多

**排查命令:**
```bash
# 检查资源使用
kubectl top nodes
kubectl top pods

# 检查磁盘
df -h

# 检查进程数
ps aux | wc -l
```

**解决方案:**
```bash
# 清理磁盘
docker system prune -a
crictl rmi --prune

# 扩容节点
# 添加新的Worker节点

# 优化Pod资源请求
kubectl patch deployment <deploy-name> -p '{"spec":{"template":{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"50m","memory":"64Mi"}}}]}}}}'
```

### 8.2 磁盘IO高

**现象:** 系统响应慢

**可能原因:**
- 日志写入过多
- 数据库查询慢
- 存储性能差

**排查命令:**
```bash
# 检查IO
iostat -x 1 5

# 检查进程
iotop

# 检查日志
tail -f /var/log/messages
```

**解决方案:**
```bash
# 清理日志
journalctl --vacuum-time=7d

# 优化数据库
# 使用SSD存储
```

## 9. 安全问题

### 9.1 RBAC权限不足

**现象:** 操作被拒绝

**可能原因:**
- ServiceAccount权限不足
- Role/ClusterRole配置错误
- RoleBinding未绑定

**排查命令:**
```bash
# 检查权限
kubectl auth can-i <verb> <resource> --as=system:serviceaccount:<ns>:<sa>

# 检查Role
kubectl get role -A
kubectl describe role <role-name> -n <namespace>

# 检查RoleBinding
kubectl get rolebinding -A
```

**解决方案:**
```bash
# 授予权限
kubectl create rolebinding <name> --role=<role> --serviceaccount=<ns>:<sa> -n <ns>
```

### 9.2 网络策略阻止

**现象:** Pod间通信被阻止

**可能原因:**
- NetworkPolicy配置错误
- 默认拒绝策略

**排查命令:**
```bash
# 检查NetworkPolicy
kubectl get networkpolicy -A
kubectl describe networkpolicy <np-name>

# 测试连通性
kubectl exec <pod-name> -- ping <other-pod-ip>
```

**解决方案:**
```bash
# 删除NetworkPolicy
kubectl delete networkpolicy <np-name>

# 修改NetworkPolicy允许通信
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-all
spec:
  podSelector: {}
  ingress:
  - from:
    - podSelector: {}
  egress:
  - to:
    - podSelector: {}
EOF
```

### 9.3 证书过期

**现象:** HTTPS访问报错

**可能原因:**
- 证书过期
- 证书配置错误
- CA不信任

**排查命令:**
```bash
# 检查证书
openssl x509 -in cert.pem -noout -dates

# 检查K8s证书
kubeadm certs check-expiration

# 检查Ingress证书
kubectl get secret <secret-name> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates
```

**解决方案:**
```bash
# 续签K8s证书
kubeadm certs renew all

# 重新签发证书
cert-manager issuers
```

## 10. 排查工具箱

### 10.1 一键排查脚本

```bash
#!/bin/bash
# cluster-debug.sh - K8s集群一键排查

echo "=== 节点状态 ==="
kubectl get nodes -o wide

echo -e "\n=== 系统Pod ==="
kubectl get pods -n kube-system

echo -e "\n=== 异常Pod ==="
kubectl get pods -A | grep -E "CrashLoop|Error|Pending"

echo -e "\n=== 资源使用 ==="
kubectl top nodes 2>/dev/null || echo "Metrics Server未安装"

echo -e "\n=== 事件(最近10分钟) ==="
kubectl get events --sort-by='.lastTimestamp' | tail -20

echo -e "\n=== 存储 ==="
kubectl get pv,pvc -A

echo -e "\n=== 网络 ==="
kubectl get svc,ingress -A
```

### 10.2 日志收集

```bash
# 收集所有节点日志
for node in $(kubectl get nodes -o name); do
    echo "=== $node ==="
    kubectl debug node/$node -it --image=busybox -- cat /var/log/syslog
done
```

### 10.3 资源快照

```bash
# 导出所有资源
kubectl get all --all-namespaces -o yaml > all-resources.yaml
```
