# 项目经历 - 简历写法参考

> 本文档为 `企业级云原生运维平台` 项目的简历撰写指南，帮助你将项目经验转化为有竞争力的简历内容。

---

## 一、项目标题（简历用）

**企业级云原生运维平台** | 个人项目 | 2026.05

---

## 二、项目描述（一段话版本）

独立设计并搭建了一套完整的企业级云原生运维平台，涵盖 Kubernetes 集群部署、CI/CD 流水线、分布式存储、监控告警、日志收集、高可用架构、自动化运维及安全加固共 10 个核心模块。基于 CentOS/Rocky Linux 环境，使用 kubeadm 部署 Kubernetes 1.28 集群，集成 Calico 网络插件、NFS 动态供给、Prometheus+Grafana 监控体系、EFK 日志栈、Keepalived+MySQL 主从高可用方案，编写了 70+ 生产级 Shell 脚本和 30+ Ansible 自动化 Playbook，实现了从基础环境初始化到应用部署的全流程自动化。

---

## 三、技术栈（简历用）

| 类别 | 技术 |
|------|------|
| 操作系统 | CentOS 7/8, Rocky Linux 8/9 |
| 容器运行时 | Docker CE, containerd |
| 容器编排 | Kubernetes 1.28, kubeadm |
| CNI 网络 | Calico |
| 存储 | NFS, Longhorn, Velero |
| CI/CD | GitLab, Jenkins, Harbor, Trivy |
| 监控 | Prometheus, Grafana, Alertmanager, Zabbix, Node Exporter |
| 日志 | Elasticsearch, Fluentd, Kibana |
| 高可用 | Keepalived, Nginx, MySQL 主从, PostgreSQL 主从, Redis Sentinel |
| 自动化 | Ansible, Shell (Bash) |
| 安全 | cert-manager, RBAC, NetworkPolicy, OPA/Gatekeeper, fail2ban |

---

## 四、项目经历（简历详细版）

### 项目名称：企业级云原生运维平台
**时间**：2026.05  
**角色**：独立完成  
**技术栈**：Kubernetes, Docker, Prometheus, Elasticsearch, Ansible, MySQL, Redis, Nginx

**项目背景**：  
为满足企业级应用的容器化部署需求，从零设计并搭建了一套覆盖全生命周期的云原生运维平台，实现应用从代码提交到生产部署的自动化流水线。

**主要工作**：

1. **Kubernetes 集群搭建**（2-3天）
   - 使用 kubeadm 部署 3 Master + N Worker 的高可用 Kubernetes 集群
   - 部署 Calico CNI 网络插件，配置 Pod CIDR 和 NetworkPolicy
   - 验证 CoreDNS 服务可用性，完成集群高可用测试（节点故障模拟、Pod 自动漂移）

2. **CI/CD 流水线建设**（2-3天）
   - 部署 GitLab 代码仓库、Jenkins 持续集成、Harbor 镜像仓库
   - 集成 Trivy 容器安全扫描，实现镜像构建后自动漏洞检测
   - 编写 Jenkins Pipeline，实现代码提交 → 自动构建 → 安全扫描 → 镜像推送 → 自动部署的完整流程

3. **监控告警体系**（2-3天）
   - 部署 Prometheus + Grafana + Alertmanager 监控栈
   - 配置 Node Exporter 采集节点指标，自定义业务监控指标
   - 配置 Alertmanager 多级告警路由，集成钉钉/邮件通知
   - 部署 Zabbix 监控物理机和传统服务

4. **日志收集与分析**（1-2天）
   - 部署 EFK（Elasticsearch + Fluentd + Kibana）日志栈
   - Fluentd DaemonSet 全节点日志采集，配置日志告警规则
   - Elasticsearch ILM 生命周期管理（热/温/冷分层，30天自动清理）

5. **高可用架构设计**（1-2天）
   - Keepalived VIP 漂移实现入口高可用（非抢占模式）
   - Nginx L7 负载均衡，配置 SSL 终止和 WebSocket 支持
   - MySQL 半同步主从复制 + GTID，PostgreSQL 流复制热备
   - Redis Sentinel 哨兵集群（3 Sentinels + 1 Master + 2 Slaves）
   - 编写故障转移自动化测试脚本，验证数据一致性

6. **自动化运维体系**（1-2天）
   - 编写 70+ 生产级 Shell 脚本（set -euo pipefail, trap 错误处理, 日志框架）
   - 构建 Ansible 自动化体系（7 Playbook + 8 Role），覆盖监控/日志/CI-CD/高可用/安全/存储
   - 开发资产管理系统，支持多主机 SSH 扫描和多格式报告导出

7. **安全加固**（1天）
   - cert-manager + Let's Encrypt 自动化 SSL 证书管理
   - SSH 加固（禁用密码认证、强制密钥登录、fail2ban）
   - K8s RBAC 角色管理（admin/readonly/developer/devops）
   - Trivy + OPA/Gatekeeper 容器安全策略，漏洞扫描与修复流程

**项目成果**：
- 平台包含 228 个文件，覆盖 10 个核心运维领域
- 从零到一完成生产级云原生运维平台的完整部署
- 全部脚本通过语法检查，具备完整的错误处理和回滚机制
- 项目已开源至 GitHub：https://github.com/missxb/prod-ops-lab

---

## 五、简历精简版（适合空间有限的简历）

### 企业级云原生运维平台 | 个人项目 | 2026.05

独立设计并搭建的完整云原生运维平台，涵盖 K8s 集群、CI/CD、监控、日志、高可用、自动化、安全 10 大模块。

- 使用 kubeadm 部署 Kubernetes 1.28 高可用集群，集成 Calico CNI 和 NFS 动态存储
- 搭建 Jenkins + Harbor + Trivy CI/CD 流水线，实现代码到生产的自动化部署
- 构建 Prometheus + Grafana + EFK 监控日志体系，配置多级告警和钉钉/邮件通知
- 实现 Keepalived + MySQL/PostgreSQL/Redis 多组件高可用方案
- 编写 70+ Shell 脚本和 30+ Ansible Playbook，覆盖全流程自动化
- 技术栈：Kubernetes, Docker, Prometheus, Elasticsearch, Ansible, MySQL, Redis, Nginx

---

## 六、面试常见问题准备

### Q: 为什么用 kubeadm 而不是二进制部署？
**答**：kubeadm 是 Kubernetes 官方推荐的部署工具，能快速搭建标准化集群，适合快速验证和中小规模生产环境。二进制部署虽然灵活但维护成本高，适合超大规模或有特殊定制需求的场景。实际工作中两者都可能用到，kubeadm 更常见。

### Q: Calico 和 Flannel 怎么选？
**答**：Calico 支持 NetworkPolicy 网络策略，适合需要精细化网络控制的企业环境；Flannel 配置简单但不支持 NetworkPolicy。生产环境推荐 Calico，因为它还支持 BGP 模式，性能更好。

### Q: 为什么用 NFS 而不是 Ceph？
**答**：NFS 部署简单、维护成本低，适合中小规模和学习环境。Ceph 提供块/对象/文件三种存储接口，性能更好但部署复杂度高。实际生产中根据性能需求和运维能力选择，数据库等 IO 密集型场景推荐 Ceph。

### Q: Prometheus 怎么实现高可用？
**答**：常见方案：1) Thanos 联邦模式，多 Prometheus 实例 + 对象存储；2) Prometheus + Remote Write 到远程存储；3) Kubernetes 上部署多副本 StatefulSet。我项目中用的是 kube-prometheus-stack，可以配合 Thanos 实现长期存储和高可用。

### Q: MySQL 主从复制用半同步还是异步？
**答**：异步复制性能好但可能丢数据；半同步复制确保至少一个从库收到数据才返回，兼顾性能和数据安全。生产环境推荐半同步 + GTID 模式，故障切换更可靠。

### Q: 遇到过什么问题？怎么解决的？
**答**：
1. containerd 双配置冲突（certs.d 和 registry.mirrors 同时存在），通过只保留 certs.d 方式解决
2. MySQL MGR 的 binlog-do-db 设置与 GTID 冲突，去掉 binlog-do-db 用 GTID 过滤
3. K8s 节点 ip_forward=0 和安全加固脚本矛盾，统一设置为 1
4. etcd 备份脚本在集群重启后失效，改用 etcdctl API 方式

---

## 七、简历优化建议

1. **量化成果**：尽量用数字（228个文件、70+脚本、30+ Playbook）
2. **突出重点**：面试运维岗重点写 CI/CD + 监控 + 高可用
3. **面试运维岗重点写**：CI/CD + 监控 + 高可用 + 故障排查
4. **面试开发岗重点写**：K8s 部署 + 应用发布 + 容器化
5. **不要造假**：这是个人学习项目，诚实说明是个人项目即可
6. **准备演示**：GitHub 地址写在简历上，面试时可以现场演示
