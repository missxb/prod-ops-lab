# 企业级云原生运维平台

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-CentOS%207%2F8%2FRocky%20Linux-green.svg)]()
[![Kubernetes](https://img.shields.io/badge/kubernetes-1.28%2B-blue.svg)]()

> 从零搭建企业级云原生运维平台，覆盖基础环境、K8s集群、存储、CI/CD、应用部署、监控、日志、高可用、自动化、安全加固十大核心领域。

## 项目架构

```
enterprise-cloud-native-platform/
├── scripts/           # 部署脚本（10阶段 × 多个子脚本）
│   ├── 01-init/       # 基础环境初始化
│   ├── 02-k8s/        # Kubernetes集群搭建
│   ├── 03-storage/    # 存储方案
│   ├── 04-cicd/       # CI/CD流水线
│   ├── 05-app/        # 应用部署
│   ├── 06-monitor/    # 监控告警
│   ├── 07-logging/    # 日志系统
│   ├── 08-ha/         # 高可用架构
│   ├── 09-automation/ # 自动化运维
│   ├── 10-security/   # 安全加固
│   ├── lib/           # 共享函数库
│   ├── verify-*.sh    # 验证脚本
│   └── teardown/      # 回滚脚本
├── configs/           # 配置文件
├── manifests/         # Kubernetes Manifests
├── ansible/           # Ansible自动化
├── docs/              # 文档
└── reports/           # 报告输出
```

## 技术栈

| 领域 | 技术 |
|------|------|
| 容器运行时 | Docker CE + containerd |
| 容器编排 | Kubernetes 1.28 + kubeadm |
| CNI网络 | Calico |
| 存储 | NFS + Longhorn |
| CI/CD | GitLab + Jenkins + Harbor + Trivy |
| 监控 | Prometheus + Grafana + Zabbix |
| 日志 | Elasticsearch + Fluentd + Kibana |
| 高可用 | Keepalived + Nginx + MySQL主从 + Redis哨兵 + PostgreSQL主从 |
| 自动化 | Ansible |
| 安全 | cert-manager + RBAC + NetworkPolicy + OPA/Gatekeeper |

## 快速开始

### 环境要求
- 操作系统: CentOS 7/8 或 Rocky Linux 8/9
- 内存: ≥4GB
- 磁盘: ≥40GB
- 网络: 节点间可通信
- 权限: root

### 部署步骤

```bash
# 1. 克隆项目
git clone https://github.com/missxb/enterprise-cloud-native-platform.git
cd enterprise-cloud-native-platform

# 2. 阶段1: 基础环境初始化
bash scripts/01-init/init-all.sh

# 3. 验证部署
bash scripts/verify-phase1.sh

# 4. 继续后续阶段...
# bash scripts/02-k8s/deploy-k8s.sh
# bash scripts/03-storage/deploy-storage.sh
# ...
```

### 完整部署

```bash
# 部署所有阶段
bash scripts/01-init/init-all.sh
bash scripts/02-k8s/deploy-k8s.sh
bash scripts/03-storage/deploy-storage.sh
bash scripts/04-cicd/deploy-cicd.sh
bash scripts/05-app/deploy-app.sh
bash scripts/06-monitor/deploy-monitor.sh
bash scripts/07-logging/deploy-logging.sh
bash scripts/08-ha/deploy-ha.sh
bash scripts/09-automation/deploy-automation.sh
bash scripts/10-security/deploy-security.sh

# 全局验证
bash scripts/verify-all.sh
```

### 回滚

```bash
# 回滚单个阶段
bash scripts/teardown/teardown-phase1.sh

# 回滚所有阶段
bash scripts/teardown/teardown-all.sh
```

## 各阶段说明

### 阶段1: 基础环境初始化
主机名设置、SSH免密、NTP时间同步、内核参数优化、Docker/containerd安装、NFS配置、时区设置、防火墙基础配置。

### 阶段2: Kubernetes集群搭建
kubeadm安装、Master初始化、Worker加入、Calico网络插件、CoreDNS验证、集群高可用测试。

### 阶段3: 存储方案
NFS动态供给、StorageClass、Longhorn分布式存储、VolumeSnapshot、Velero备份。

### 阶段4: CI/CD流水线
GitLab代码仓库、Jenkins持续集成、Harbor镜像仓库、Trivy安全扫描、完整流水线配置。

### 阶段5: 应用部署
示例应用、Deployment/Service/Ingress、ConfigMap/Secret、HPA自动扩缩容、滚动更新、故障转移。

### 阶段6: 监控告警
Prometheus + Grafana + Alertmanager、Node Exporter、自定义监控指标、Zabbix物理机监控。

### 阶段7: 日志系统
Elasticsearch集群、Fluentd日志收集、Kibana可视化、日志告警规则。

### 阶段8: 高可用架构
Keepalived VIP漂移、Nginx负载均衡、MySQL主从、PostgreSQL主从、Redis哨兵、数据一致性验证。

### 阶段9: 自动化运维
Ansible自动化、健康检查、日志清理、备份校验、资产管理。

### 阶段10: 安全加固
SSL证书管理、SSH加固、防火墙策略、容器安全扫描、K8s RBAC、漏洞修复流程。

## 脚本特性

- `set -euo pipefail` 严格错误处理
- `umask 077` 安全权限
- `trap ERR/EXIT/INT/TERM` 完整信号处理
- 锁文件防并发执行
- 统一日志框架（彩色输出）
- `--help` 帮助信息
- `--dry-run` 干运行模式
- `--task/--skip` 选择性执行
- 中文注释全覆盖

## 文档

- [基础环境初始化](docs/01-init.md)
- [Kubernetes集群搭建](docs/02-k8s.md)
- [存储方案](docs/03-storage.md)
- [CI/CD流水线](docs/04-cicd.md)
- [应用部署](docs/05-app.md)
- [监控告警](docs/06-monitor.md)
- [日志系统](docs/07-logging.md)
- [高可用架构](docs/08-ha.md)
- [自动化运维](docs/09-automation.md)
- [安全加固](docs/10-security.md)
- [架构深度解析](docs/architecture-deep-dive.md)
- [部署检查清单](docs/deployment-checklist.md)
- [监控运维手册](docs/monitoring-runbook.md)
- [安全运维手册](docs/security-runbook.md)
- [常见问题](docs/faq.md)
- [最佳实践](docs/best-practices.md)

## 📝 做完这个项目，简历上可以写什么

> 完成本项目后，你可以将以下内容写入简历的「项目经历」板块。

### 项目标题
**企业级云原生运维平台** | 个人项目 | 2026.05

### 一句话描述（简历用）
独立设计并搭建了一套完整的企业级云原生运维平台，涵盖 Kubernetes 集群部署、CI/CD 流水线、分布式存储、监控告警、日志收集、高可用架构、自动化运维及安全加固共 10 个核心模块，编写了 70+ 生产级 Shell 脚本和 30+ Ansible Playbook。

### 你可以写的核心工作内容

| 模块 | 简历写法 |
|------|----------|
| K8s集群 | 使用 kubeadm 部署 Kubernetes 1.28 高可用集群，集成 Calico CNI 网络插件和 NFS 动态存储供给 |
| CI/CD | 搭建 Jenkins + Harbor + Trivy CI/CD 流水线，实现代码提交到生产部署的全流程自动化 |
| 监控 | 构建 Prometheus + Grafana + EFK 监控日志体系，配置多级告警和钉钉/邮件通知 |
| 高可用 | 实现 Keepalived + MySQL/PostgreSQL/Redis 多组件高可用方案，编写故障转移自动化测试脚本 |
| 自动化 | 编写 70+ 生产级 Shell 脚本（含错误处理、日志框架、回滚机制），构建 Ansible 自动化体系 |
| 安全 | 部署 cert-manager 自动化证书管理，配置 K8s RBAC 和 NetworkPolicy，集成 Trivy + OPA 安全策略 |

### 简历精简版（直接复制）

> **企业级云原生运维平台** | 个人项目 | 2026.05
>
> 独立设计并搭建的完整云原生运维平台，涵盖 K8s 集群、CI/CD、监控、日志、高可用、自动化、安全 10 大模块。
> - 使用 kubeadm 部署 Kubernetes 1.28 高可用集群，集成 Calico CNI 和 NFS 动态存储
> - 搭建 Jenkins + Harbor + Trivy CI/CD 流水线，实现代码到生产的自动化部署
> - 构建 Prometheus + Grafana + EFK 监控日志体系，配置多级告警和钉钉/邮件通知
> - 实现 Keepalived + MySQL/PostgreSQL/Redis 多组件高可用方案
> - 编写 70+ Shell 脚本和 30+ Ansible Playbook，覆盖全流程自动化
> - 技术栈：Kubernetes, Docker, Prometheus, Elasticsearch, Ansible, MySQL, Redis, Nginx

### 面试怎么说这个项目

> 面试官：介绍一下你的项目？
>
> **30秒版本**：我独立搭建了一套企业级云原生运维平台，从基础环境到 K8s 集群、CI/CD、监控、高可用、安全加固，覆盖了运维工程师日常工作的核心领域。整个项目包含 228 个文件、70+ 脚本，全部按照生产标准编写。
>
> **2分钟版本**：先说背景——运维工程师需要掌握从集群搭建到应用部署的全链路能力，所以我设计了这个 10 阶段的项目。技术选型上，K8s 用 kubeadm 部署，网络用 Calico，存储用 NFS 动态供给，监控用 Prometheus+Grafana，日志用 EFK，高可用用 Keepalived+MySQL 主从+Redis 哨兵。实施过程中遇到的最大问题是 containerd 双配置冲突和 K8s 网络参数与安全加固的矛盾，最终通过统一配置标准解决。成果是实现了从环境初始化到应用部署的全流程自动化，所有脚本都有错误处理和回滚机制。

详细简历撰写指南见 [docs/resume-guide.md](docs/resume-guide.md)。

## License

MIT
