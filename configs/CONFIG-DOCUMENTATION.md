# =============================================================================
# 企业级云原生运维平台 - 配置文件文档
# 项目: 企业级云原生运维平台
# 描述: 所有配置文件的使用说明和验证方法
# =============================================================================

# =============================================================================
# 目录结构
# =============================================================================
# configs/
# ├── calico/
# │   └── calico.yaml                    # Calico网络插件配置
# ├── elk/
# │   ├── elasticsearch.yaml             # Elasticsearch配置
# │   ├── fluentd-config.yaml            # Fluentd日志收集配置
# │   ├── index-template.json            # ES索引模板
# │   └── kibana.yaml                    # Kibana可视化配置
# ├── fluentd/
# │   └── fluentd.conf                   # Fluentd完整配置
# ├── gitlab/
# │   └── gitlab-values.yaml             # GitLab Helm配置
# ├── grafana/
# │   ├── dashboard-configmap.yaml       # Grafana Dashboard配置
# │   ├── dashboards/
# │   │   └── k8s-cluster.json           # K8s集群监控Dashboard
# │   └── datasource.yaml                # Grafana数据源配置
# ├── harbor/
# │   └── harbor-values.yaml             # Harbor镜像仓库配置
# ├── jenkins/
# │   └── jenkins-values.yaml            # Jenkins CI/CD配置
# ├── k8s/
# │   └── kubeadm-config.yaml            # K8s集群初始化配置
# ├── keepalived/
# │   ├── keepalived-master.conf         # Keepalived主节点配置
# │   └── keepalived-slave.conf          # Keepalived备节点配置
# ├── kubernetes/
# │   ├── network-policy.yaml            # 网络策略配置
# │   ├── pod-security.yaml              # Pod安全策略配置
# │   ├── rbac-admin.yaml                # RBAC管理员配置
# │   └── rbac-readonly.yaml             # RBAC只读配置
# ├── mysql/
# │   ├── master.cnf                     # MySQL主节点配置
# │   └── slave.cnf                      # MySQL从节点配置
# ├── nfs/
# │   ├── nfs-provisioner.yaml           # NFS动态供给配置
# │   └── storageclass.yaml              # StorageClass配置
# ├── nginx/
# │   └── nginx-lb.conf                  # Nginx负载均衡配置
# ├── prometheus/
# │   ├── alert-rules.yaml               # 告警规则配置
# │   ├── alertmanager.yaml              # Alertmanager配置
# │   ├── prometheus-rules.yaml          # Prometheus规则
# │   └── prometheus.yaml                # Prometheus Helm配置
# └── redis/
#     ├── redis-master.conf              # Redis主节点配置
#     └── redis-sentinel.conf            # Redis Sentinel配置

# =============================================================================
# 配置文件说明
# =============================================================================

## 1. Kubernetes核心配置

### k8s/kubeadm-config.yaml
- 功能: K8s集群初始化配置
- 使用: kubeadm init --config kubeadm-config.yaml
- 验证: kubeadm config validate --config kubeadm-config.yaml
- 替换变量: __HOST_IP__, __CLUSTER_NAME__, __K8S_VERSION__, __POD_CIDR__, __SERVICE_CIDR__

### kubernetes/rbac-admin.yaml
- 功能: 管理员角色配置
- 部署: kubectl apply -f rbac-admin.yaml
- 验证: kubectl auth can-i list pods -n production --as admin@example.com

### kubernetes/rbac-readonly.yaml
- 功能: 只读角色配置
- 部署: kubectl apply -f rbac-readonly.yaml
- 验证: kubectl auth can-i list pods --as readonly@example.com

### kubernetes/network-policy.yaml
- 功能: 网络策略配置
- 前提: 需要支持NetworkPolicy的CNI (Calico/Cilium)
- 部署: kubectl apply -f network-policy.yaml
- 验证: kubectl get networkpolicy -n production

### kubernetes/pod-security.yaml
- 功能: Pod安全策略配置
- 部署: kubectl apply -f pod-security.yaml
- 验证: kubectl get psp,constrainttemplate

## 2. 网络配置

### calico/calico.yaml
- 功能: Calico CNI网络插件
- 前提: 已安装Tigera Operator
- 部署: kubectl apply -f calico.yaml
- 验证: kubectl get pods -n calico-system
- 替换变量: __POD_CIDR__

### nginx/nginx-lb.conf
- 功能: Nginx负载均衡配置
- 部署: 将配置文件复制到Nginx服务器
- 验证: nginx -t && systemctl reload nginx

### keepalived/keepalived-master.conf
- 功能: Keepalived主节点配置
- 部署: 将配置文件复制到Keepalived服务器
- 验证: keepalived -t -f /etc/keepalived/keepalived.conf

### keepalived/keepalived-slave.conf
- 功能: Keepalived备节点配置
- 部署: 将配置文件复制到Keepalived服务器
- 验证: keepalived -t -f /etc/keepalived/keepalived.conf

## 3. 数据库配置

### mysql/master.cnf
- 功能: MySQL主节点配置
- 部署: 将配置文件复制到MySQL服务器
- 验证: mysqladmin -u root -p status

### mysql/slave.cnf
- 功能: MySQL从节点配置
- 部署: 将配置文件复制到MySQL服务器
- 验证: mysql -u root -p -e "SHOW SLAVE STATUS\G"

### redis/redis-master.conf
- 功能: Redis主节点配置
- 部署: 将配置文件复制到Redis服务器
- 验证: redis-cli -a redis_pass_2024 ping

### redis/redis-sentinel.conf
- 功能: Redis Sentinel配置
- 部署: 将配置文件复制到Sentinel服务器
- 验证: redis-cli -p 26379 info sentinel

## 4. 监控配置

### prometheus/prometheus.yaml
- 功能: Prometheus Helm配置
- 部署: helm install prometheus prometheus-community/kube-prometheus-stack -f prometheus.yaml -n monitoring
- 验证: kubectl get pods -n monitoring
- 访问: kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090

### prometheus/alertmanager.yaml
- 功能: Alertmanager Secret配置
- 部署: kubectl apply -f alertmanager.yaml
- 验证: kubectl get secret alertmanager-config -n monitoring

### prometheus/alert-rules.yaml
- 功能: 告警规则配置
- 部署: kubectl apply -f alert-rules.yaml
- 验证: kubectl get prometheusrule -n monitoring

### prometheus/prometheus-rules.yaml
- 功能: Prometheus规则配置
- 部署: kubectl apply -f prometheus-rules.yaml
- 验证: kubectl get prometheusrule -n monitoring

## 5. 日志配置

### elk/elasticsearch.yaml
- 功能: Elasticsearch配置
- 部署: kubectl apply -f elasticsearch.yaml
- 验证: curl -k http://localhost:9200/_cluster/health

### elk/kibana.yaml
- 功能: Kibana配置
- 部署: kubectl apply -f kibana.yaml
- 验证: curl -k http://localhost:5601/api/status

### elk/fluentd-config.yaml
- 功能: Fluentd配置
- 部署: kubectl apply -f fluentd-config.yaml
- 验证: kubectl get pods -l app=fluentd

### fluentd/fluentd.conf
- 功能: Fluentd完整配置
- 部署: 将配置文件复制到Fluentd服务器
- 验证: fluentd -c /etc/fluentd/fluentd.conf --dry-run

## 6. 存储配置

### nfs/nfs-provisioner.yaml
- 功能: NFS动态供给配置
- 前提: 已部署NFS服务器
- 部署: kubectl apply -f nfs-provisioner.yaml
- 验证: kubectl get pods -n nfs-provisioner
- 替换变量: NFS_SERVER_PLACEHOLDER, NFS_PATH_PLACEHOLDER

### nfs/storageclass.yaml
- 功能: StorageClass配置
- 部署: kubectl apply -f storageclass.yaml
- 验证: kubectl get storageclass

## 7. CI/CD配置

### harbor/harbor-values.yaml
- 功能: Harbor镜像仓库配置
- 部署: helm install harbor harbor/harbor -f harbor-values.yaml -n harbor
- 验证: kubectl get pods -n harbor
- 访问: https://harbor.example.com

### jenkins/jenkins-values.yaml
- 功能: Jenkins CI/CD配置
- 部署: helm install jenkins jenkins/jenkins -f jenkins-values.yaml -n jenkins
- 验证: kubectl get pods -n jenkins
- 访问: http://jenkins.example.com

### gitlab/gitlab-values.yaml
- 功能: GitLab配置
- 部署: helm install gitlab gitlab/gitlab -f gitlab-values.yaml -n gitlab
- 验证: kubectl get pods -n gitlab
- 访问: https://gitlab.example.com

# =============================================================================
# 配置验证方法
# =============================================================================

## 1. 语法验证

### YAML语法检查
```bash
# 使用yamllint检查语法
yamllint configs/**/*.yaml

# 使用kubectl验证
kubectl apply --dry-run=client -f configs/**/*.yaml

# 使用helm验证
helm lint charts/**/*
```

### JSON语法检查
```bash
# 使用jq检查JSON
cat configs/**/*.json | jq .

# 使用python检查
python3 -m json.tool configs/**/*.json
```

## 2. 配置验证

### Kubernetes配置
```bash
# 验证kubeadm配置
kubeadm config validate --config configs/k8s/kubeadm-config.yaml

# 验证RBAC
kubectl auth can-i list pods --as admin@example.com -n production

# 验证网络策略
kubectl get networkpolicy -n production

# 验证Pod安全
kubectl get psp,constrainttemplate
```

### 数据库配置
```bash
# 验证MySQL配置
mysqladmin -u root -p status

# 验证Redis配置
redis-cli -a redis_pass_2024 ping
redis-cli -p 26379 info sentinel
```

### 监控配置
```bash
# 验证Prometheus
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
curl http://localhost:9090/-/healthy

# 验证Alertmanager
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093
curl http://localhost:9093/-/healthy
```

## 3. 安全验证

### RBAC验证
```bash
# 测试管理员权限
kubectl auth can-i list pods -n production --as admin@example.com
kubectl auth can-i create deployments -n production --as admin@example.com

# 测试只读权限
kubectl auth can-i list pods -n production --as readonly@example.com
kubectl auth can-i create deployments -n production --as readonly@example.com
```

### 网络策略验证
```bash
# 测试网络连通性
kubectl run test --image=nicolaka/netshoot -n production --rm -it -- curl http://<service>

# 查看网络策略
kubectl get networkpolicy -n production -o yaml
```

### Pod安全验证
```bash
# 测试Pod安全策略
kubectl apply -f restricted-pod.yaml -n production
kubectl get events --field-selector reason=FailedCreate
```

## 4. 性能验证

### 资源使用
```bash
# 查看Pod资源使用
kubectl top pods -n monitoring
kubectl top nodes

# 查看节点资源
kubectl describe nodes
```

### 存储使用
```bash
# 查看PV/PVC状态
kubectl get pv,pvc --all-namespaces

# 查看存储类
kubectl get storageclass
```

# =============================================================================
# 配置更新流程
# =============================================================================

## 1. 开发环境更新
```bash
# 1. 修改配置文件
vim configs/**/*.yaml

# 2. 验证语法
yamllint configs/**/*.yaml

# 3. 测试应用
kubectl apply --dry-run=client -f configs/**/*.yaml

# 4. 应用配置
kubectl apply -f configs/**/*.yaml
```

## 2. 生产环境更新
```bash
# 1. 创建备份
kubectl get -o yaml -n <namespace> <resource> > backup.yaml

# 2. 验证配置
helm lint charts/**/*
kubectl apply --dry-run=client -f configs/**/*.yaml

# 3. 灰度发布
kubectl apply -f configs/**/*.yaml

# 4. 验证结果
kubectl get pods -n <namespace>
kubectl logs -n <namespace> -l app=<app>
```

# =============================================================================
# 常见问题排查
# =============================================================================

## 1. 部署失败
```bash
# 查看Pod状态
kubectl get pods -n <namespace>

# 查看Pod日志
kubectl logs -n <namespace> -l app=<app> -f

# 查看事件
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

## 2. 连接问题
```bash
# 测试网络连通性
kubectl run test --image=nicolaka/netshoot -n <namespace> --rm -it -- curl <service>

# 查看服务状态
kubectl get svc -n <namespace>
kubectl describe svc <service> -n <namespace>
```

## 3. 权限问题
```bash
# 查看RBAC
kubectl get clusterrole,clusterrolebinding,rolebinding --all-namespaces

# 测试权限
kubectl auth can-i list pods --as <user> -n <namespace>
```

# =============================================================================
# 配置最佳实践
# =============================================================================

## 1. 安全性
- 使用Secret管理敏感信息 (密码、token)
- 启用RBAC和网络策略
- 配置Pod安全策略
- 定期轮换证书和密钥

## 2. 可靠性
- 配置健康检查和就绪探针
- 设置资源限制
- 配置自动扩缩容
- 实施备份和恢复策略

## 3. 可观测性
- 启用监控和告警
- 配置日志收集
- 实施分布式追踪
- 配置审计日志

## 4. 可维护性
- 使用配置模板
- 实施配置版本控制
- 编写配置文档
- 定期审计配置

# =============================================================================
# 联系方式
# =============================================================================
# 项目: 企业级云原生运维平台
# 文档: https://docs.example.com
# 仓库: https://gitlab.example.com/devops/enterprise-cloud-native-platform
# 支持: ops-team@example.com
# =============================================================================
