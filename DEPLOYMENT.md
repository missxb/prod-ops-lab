# 部署指南

## 1. 前置条件

### 1.1 硬件要求

| 节点 | CPU | 内存 | 磁盘 | 数量 |
|------|-----|------|------|------|
| Master | 2C+ | 4G+ | 50G+ | 3台 |
| Worker | 2C+ | 4G+ | 100G+ | 3台 |
| Infra | 4C+ | 8G+ | 200G+ | 1台 |
| Monitor | 4C+ | 8G+ | 200G+ | 1台 |

### 1.2 软件要求

- 操作系统: CentOS 7/8 或 Rocky Linux 8/9
- Docker/containerd: 1.7+
- Kubernetes: 1.28+
- Ansible: 2.12+
- Helm: 3.12+

### 1.3 网络要求

- 管理网络: 192.168.1.0/24
- Pod网络: 10.244.0.0/16 (Calico)
- Service网络: 10.96.0.0/12
- 节点间互通
- 外网访问 (可选)

## 2. 快速开始

### 2.1 一键部署

```bash
cd /root/enterprise-cloud-native-platform

# 1. 配置主机信息
vim ansible/inventory/hosts.yml

# 2. 初始化所有节点
bash scripts/01-init/init-all.sh

# 3. 部署K8s集群
bash scripts/02-k8s/deploy-k8s.sh

# 4. 按阶段继续...
```

### 2.2 分阶段部署

每个阶段独立，可单独执行和回滚。

## 3. 详细部署步骤

### 阶段1: 基础环境初始化

```bash
# 执行初始化
bash scripts/01-init/init-all.sh

# 或单独执行某个步骤
bash scripts/01-init/01-hostname.sh    # 设置主机名
bash scripts/01-init/02-ssh.sh         # SSH免密
bash scripts/01-init/03-ntp.sh         # NTP同步
bash scripts/01-init/04-kernel.sh      # 内核优化
bash scripts/01-init/05-docker.sh      # Docker/containerd
bash scripts/01-init/06-nfs.sh         # NFS服务端
```

**验证:**
```bash
# 检查主机名
hostnamectl

# 检查SSH
ssh master2 "hostname"

# 检查NTP
timedatectl status

# 检查containerd
systemctl status containerd
crictl info
```

### 阶段2: K8s集群部署

```bash
# 部署集群
bash scripts/02-k8s/deploy-k8s.sh

# 或分步执行
bash scripts/02-k8s/01-install-kubeadm.sh  # 所有节点
bash scripts/02-k8s/02-init-master.sh       # master1
bash scripts/02-k8s/03-join-workers.sh      # worker1-3
bash scripts/02-k8s/04-install-calico.sh    # 安装网络插件
bash scripts/02-k8s/05-verify-cluster.sh    # 验证集群
```

**验证:**
```bash
# 检查节点
kubectl get nodes

# 检查系统Pod
kubectl get pods -n kube-system

# 检查CoreDNS
kubectl get svc -n kube-system

# 测试DNS
kubectl run test --image=busybox --rm -it -- nslookup kubernetes
```

### 阶段3: 存储层配置

```bash
# 部署存储
bash scripts/03-storage/deploy-storage.sh

# 或分步执行
bash scripts/03-storage/01-nfs-provisioner.sh
bash scripts/03-storage/02-storageclass.sh
bash scripts/03-storage/03-verify-storage.sh
```

**验证:**
```bash
# 检查StorageClass
kubectl get sc

# 检查NFS Provisioner
kubectl get pods -n nfs-provisioner

# 测试PVC
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: nfs-client
EOF

kubectl get pvc test-pvc
```

### 阶段4: CI/CD流水线

```bash
# 部署CI/CD
bash scripts/04-cicd/deploy-cicd.sh

# 或分步执行
bash scripts/04-cicd/01-deploy-gitlab.sh
bash scripts/04-cicd/02-deploy-jenkins.sh
bash scripts/04-cicd/03-deploy-harbor.sh
bash scripts/04-cicd/04-deploy-trivy.sh
bash scripts/04-cicd/05-setup-pipeline.sh
```

**验证:**
```bash
# 检查GitLab
kubectl get pods -n gitlab
curl -k https://gitlab.local

# 检查Jenkins
kubectl get pods -n jenkins
curl -k https://jenkins.local

# 检查Harbor
kubectl get pods -n harbor
curl -k https://harbor.local
```

### 阶段5: 应用部署

```bash
# 部署应用
bash scripts/05-app/deploy-app.sh

# 或分步执行
bash scripts/05-app/01-create-namespace.sh
bash scripts/05-app/02-deploy-demo-app.sh
bash scripts/05-app/03-configure-hpa.sh
bash scripts/05-app/04-test-rolling-update.sh
bash scripts/05-app/05-test-failover.sh
```

**验证:**
```bash
# 检查应用
kubectl get pods -n dev
kubectl get svc -n dev
kubectl get ingress -n dev

# 测试访问
curl http://demo-app.local

# 测试HPA
kubectl get hpa -n dev
```

### 阶段6: 监控告警

```bash
# 部署监控
bash scripts/06-monitor/deploy-monitor.sh

# 或分步执行
bash scripts/06-monitor/01-deploy-prometheus.sh
bash scripts/06-monitor/02-deploy-grafana.sh
bash scripts/06-monitor/03-deploy-alertmanager.sh
bash scripts/06-monitor/04-config-rules.sh
```

**验证:**
```bash
# 检查Prometheus
kubectl get pods -n monitoring
curl http://prometheus.local:9090

# 检查Grafana
curl http://grafana.local:3000

# 检查Alertmanager
curl http://alertmanager.local:9093
```

### 阶段7: 日志系统

```bash
# 部署日志
bash scripts/07-logging/deploy-logging.sh

# 或分步执行
bash scripts/07-logging/01-deploy-elasticsearch.sh
bash scripts/07-logging/02-deploy-fluentd.sh
bash scripts/07-logging/03-deploy-kibana.sh
bash scripts/07-logging/04-verify-logging.sh
```

**验证:**
```bash
# 检查ES
kubectl get pods -n logging
curl http://elasticsearch.local:9200

# 检查Kibana
curl http://kibana.local:5601

# 检查Fluentd
kubectl get pods -n logging -l app=fluentd
```

### 阶段8: 高可用架构

```bash
# 部署高可用
bash scripts/08-ha/deploy-ha.sh

# 或分步执行
bash scripts/08-ha/01-deploy-keepalived.sh
bash scripts/08-ha/02-deploy-nginx-lb.sh
bash scripts/08-ha/03-deploy-mysql-ha.sh
bash scripts/08-ha/04-deploy-redis-sentinel.sh
bash scripts/08-ha/05-test-failover.sh
```

**验证:**
```bash
# 检查Keepalived
systemctl status keepalived
ip addr show | grep 192.168.1.100

# 检查Nginx
systemctl status nginx
curl http://192.168.1.100

# 检查MySQL
mysql -h 192.168.1.100 -u root -p -e "SHOW MASTER STATUS"

# 检查Redis
redis-cli -h 192.168.1.100 sentinel masters
```

### 阶段9: 自动化运维

```bash
# 部署自动化
bash scripts/09-automation/deploy-automation.sh

# 或分步执行
bash scripts/09-automation/01-setup-ansible.sh
bash scripts/09-automation/02-health-check.sh
bash scripts/09-automation/03-log-cleanup.sh
bash scripts/09-automation/04-backup-verify.sh
```

**验证:**
```bash
# 检查Ansible
ansible --version
ansible all -m ping

# 检查巡检报告
cat /var/log/health-check-*.txt
```

### 阶段10: 安全加固

```bash
# 部署安全
bash scripts/10-security/deploy-security.sh

# 或分步执行
bash scripts/10-security/01-ssl-certs.sh
bash scripts/10-security/02-ssh-hardening.sh
bash scripts/10-security/03-firewall-rules.sh
bash scripts/10-security/04-container-scan.sh
bash scripts/10-security/05-k8s-rbac.sh
```

**验证:**
```bash
# 检查SSL
kubectl get certificates -A

# 检查SSH
ss -tlnp | grep 2222

# 检查防火墙
firewall-cmd --list-all

# 检查RBAC
kubectl auth can-i --list --as=system:serviceaccount:dev:default
```

## 4. 验证检查清单

### 4.1 基础环境
- [ ] 所有节点主机名正确
- [ ] SSH免密登录正常
- [ ] NTP时间同步正常
- [ ] containerd运行正常
- [ ] NFS服务正常

### 4.2 K8s集群
- [ ] 所有节点Ready
- [ ] 系统Pod运行正常
- [ ] CoreDNS工作正常
- [ ] Calico网络正常
- [ ] kubectl可正常操作

### 4.3 存储
- [ ] StorageClass存在
- [ ] NFS Provisioner运行
- [ ] PVC可动态绑定
- [ ] Pod可挂载PVC

### 4.4 CI/CD
- [ ] GitLab可访问
- [ ] Jenkins可访问
- [ ] Harbor可访问
- [ ] Pipeline可执行

### 4.5 应用
- [ ] 应用Pod运行正常
- [ ] Service可访问
- [ ] Ingress工作正常
- [ ] HPA自动扩缩容

### 4.6 监控
- [ ] Prometheus采集数据
- [ ] Grafana显示图表
- [ ] Alertmanager发送告警

### 4.7 日志
- [ ] ES集群健康
- [ ] Fluentd收集日志
- [ ] Kibana可查询

### 4.8 高可用
- [ ] VIP可漂移
- [ ] Nginx负载均衡
- [ ] MySQL主从正常
- [ ] Redis Sentinel正常

## 5. 常见问题

### 5.1 节点NotReady

```bash
# 检查kubelet
systemctl status kubelet
journalctl -u kubelet -f

# 检查网络
ping <其他节点IP>
```

### 5.2 Pod CrashLoopBackOff

```bash
# 查看日志
kubectl logs <pod-name> --previous

# 查看事件
kubectl describe pod <pod-name>
```

### 5.3 PVC Pending

```bash
# 检查PVC
kubectl describe pvc <pvc-name>

# 检查StorageClass
kubectl get sc

# 检查NFS Provisioner
kubectl logs -n nfs-provisioner <pod-name>
```

### 5.4 Ingress不工作

```bash
# 检查Ingress Controller
kubectl get pods -n ingress-nginx

# 检查Ingress资源
kubectl describe ingress <ingress-name>

# 检查DNS
nslookup <域名>
```

## 6. 回滚方案

### 6.1 回滚K8s

```bash
# 重置集群
kubeadm reset -f

# 清理网络
rm -rf /etc/cni/net.d
iptables -F && iptables -t nat -F

# 重新初始化
kubeadm init --config kubeadm-config.yaml
```

### 6.2 回滚CI/CD

```bash
# 删除Helm Release
helm uninstall gitlab -n gitlab
helm uninstall jenkins -n jenkins
helm uninstall harbor -n harbor

# 删除PVC
kubectl delete pvc --all -n gitlab
```

### 6.3 回滚监控

```bash
# 删除Helm Release
helm uninstall kube-prometheus-stack -n monitoring
helm uninstall elasticsearch -n logging
helm uninstall kibana -n logging
```
