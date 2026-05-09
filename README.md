# 企业级云原生运维平台

> 从零搭建生产级K8s集群 + CI/CD + 监控日志 + 高可用架构

## 项目定位

本项目是一个**完整链路的生产级云原生运维平台**，涵盖从基础设施到应用部署的全栈技术。适合运维工程师学习和面试使用。

## 技术栈

```
┌─────────────────────────────────────────────────────────────┐
│                      用户访问层                              │
│              Nginx反向代理 + Keepalived VIP                  │
├─────────────────────────────────────────────────────────────┤
│                      应用服务层                              │
│         K8s集群 (3 Master + 3 Worker) + Calico             │
├─────────────────────────────────────────────────────────────┤
│                      CI/CD层                                │
│         GitLab + Jenkins + Harbor + Trivy                   │
├─────────────────────────────────────────────────────────────┤
│                      监控日志层                              │
│         Prometheus + Grafana + Alertmanager                  │
│         Elasticsearch + Fluentd + Kibana                     │
├─────────────────────────────────────────────────────────────┤
│                      存储层                                  │
│              NFS + StorageClass + PV/PVC                    │
├─────────────────────────────────────────────────────────────┤
│                      数据层                                  │
│         MySQL主从 + Redis Sentinel                           │
├─────────────────────────────────────────────────────────────┤
│                      基础设施层                              │
│           8台虚拟机 + Ansible自动化                          │
└─────────────────────────────────────────────────────────────┘
```

## 资源规划

| 主机名 | IP | 角色 | 配置 |
|--------|-----|------|------|
| master1 | 192.168.1.10 | K8s Master + etcd | 2C4G |
| master2 | 192.168.1.11 | K8s Master + etcd | 2C4G |
| master3 | 192.168.1.12 | K8s Master + etcd | 2C4G |
| worker1 | 192.168.1.20 | K8s Worker | 2C4G |
| worker2 | 192.168.1.21 | K8s Worker | 2C4G |
| worker3 | 192.168.1.22 | K8s Worker | 2C4G |
| infra1 | 192.168.1.30 | GitLab + Jenkins + Harbor | 4C8G |
| monitor | 192.168.1.40 | Prometheus + Grafana + ELK | 4C8G |

**总计：20C40G**

## 项目结构

```
enterprise-cloud-native-platform/
├── README.md                    # 项目说明
├── ARCHITECTURE.md              # 架构设计文档
├── DEPLOYMENT.md                # 部署指南
├── TROUBLESHOOTING.md           # 故障排查手册
├── docs/                        # 详细文档
│   ├── 01-init.md               # 基础环境初始化
│   ├── 02-k8s.md                # K8s集群部署
│   ├── 03-storage.md            # 存储层配置
│   ├── 04-cicd.md               # CI/CD流水线
│   ├── 05-app.md                # 应用部署
│   ├── 06-monitor.md            # 监控告警
│   ├── 07-logging.md            # 日志系统
│   ├── 08-ha.md                 # 高可用架构
│   ├── 09-automation.md         # 自动化运维
│   └── 10-security.md           # 安全加固
├── scripts/                     # 部署脚本
│   ├── 01-init/                 # 基础环境脚本
│   ├── 02-k8s/                  # K8s部署脚本
│   ├── 03-storage/              # 存储配置脚本
│   ├── 04-cicd/                 # CI/CD部署脚本
│   ├── 05-app/                  # 应用部署脚本
│   ├── 06-monitor/              # 监控部署脚本
│   ├── 07-logging/              # 日志部署脚本
│   ├── 08-ha/                   # 高可用脚本
│   ├── 09-automation/           # 自动化脚本
│   └── 10-security/             # 安全加固脚本
├── configs/                     # 配置文件模板
│   ├── k8s/                     # K8s配置
│   ├── calico/                  # Calico网络配置
│   ├── nfs/                     # NFS配置
│   ├── prometheus/              # Prometheus配置
│   ├── grafana/                 # Grafana配置
│   ├── elk/                     # ELK配置
│   ├── harbor/                  # Harbor配置
│   ├── jenkins/                 # Jenkins配置
│   ├── gitlab/                  # GitLab配置
│   ├── keepalived/              # Keepalived配置
│   ├── nginx/                   # Nginx配置
│   ├── mysql/                   # MySQL配置
│   └── redis/                   # Redis配置
├── ansible/                     # Ansible自动化
│   ├── inventory/               # 主机清单
│   ├── playbooks/               # Playbook
│   └── roles/                   # Role
└── manifests/                   # K8s清单文件
    ├── namespace/               # 命名空间
    ├── app/                     # 应用部署
    ├── monitoring/              # 监控组件
    └── logging/                 # 日志组件
```

## 实施阶段

| 阶段 | 内容 | 预计时间 | 状态 |
|------|------|----------|------|
| 1 | 基础环境初始化 | 1-2天 | ⬜ |
| 2 | K8s集群部署 | 2-3天 | ⬜ |
| 3 | 存储层配置 | 1天 | ⬜ |
| 4 | CI/CD流水线 | 2-3天 | ⬜ |
| 5 | 应用部署 | 1-2天 | ⬜ |
| 6 | 监控告警 | 2-3天 | ⬜ |
| 7 | 日志系统 | 1-2天 | ⬜ |
| 8 | 高可用架构 | 1-2天 | ⬜ |
| 9 | 自动化运维 | 1-2天 | ⬜ |
| 10 | 安全加固 | 1天 | ⬜ |

## 快速开始

```bash
# 1. 克隆项目
git clone https://github.com/missxb/enterprise-cloud-native-platform.git
cd enterprise-cloud-native-platform

# 2. 修改配置
cp configs/k8s/kubeadm-config.yaml.example configs/k8s/kubeadm-config.yaml
vim configs/k8s/kubeadm-config.yaml

# 3. 执行初始化
bash scripts/01-init/init-all.sh

# 4. 部署K8s集群
bash scripts/02-k8s/deploy-k8s.sh

# 5. 按阶段继续部署...
```

## 学习路径

```
阶段1-3: 基础设施 → 能搭建K8s集群
    ↓
阶段4-5: CI/CD + 应用 → 能实现自动化部署
    ↓
阶段6-7: 监控日志 → 能保障系统可观测性
    ↓
阶段8-10: 高可用+自动化+安全 → 能达到生产级标准
```

## 简历亮点

完成本项目后，你可以在简历中写：

- 从零搭建3节点高可用Kubernetes集群（kubeadm + etcd + Calico）
- 实现CI/CD全流程自动化（GitLab → Jenkins → Harbor → Trivy → K8s）
- 建立Prometheus + Grafana + ELK全方位监控日志体系
- 设计Keepalived + Nginx + MySQL主从 + Redis Sentinel高可用架构
- 使用Ansible实现批量自动化运维（初始化、巡检、备份）
- 实施容器安全扫描（Trivy）和等保2.0基础合规

## License

MIT
