# 变更日志

所有版本变更记录。

## [v1.0.0] - 2026-05-09

### 新增功能

#### 基础设施模块
- Kubernetes 多集群管理
- 云资源统一纳管（AWS、Azure、GCP、阿里云、腾讯云）
- 基础设施即代码（Terraform/Ansible）

#### 监控告警模块
- Prometheus 监控采集与存储
- Grafana 可视化仪表盘
- 基于 Prometheus Alertmanager 的告警通知
- 自定义指标采集（主机、容器、应用）

#### 日志管理模块
- Fluentd/Fluent Bit 日志收集
- Elasticsearch 日志存储与索引
- Kibana 日志查询与分析
- 结构化日志标准

#### 链路追踪模块
- Jaeger 分布式追踪
- OpenTelemetry 数据采集
- 调用链可视化

#### 安全审计模块
- 镜像安全扫描（Trivy）
- 网络策略管理
- RBAC 权限控制
- 操作审计日志

#### 自动化运维模块
- CI/CD 流水线（ArgoCD）
- 自动化发布与回滚
- 金丝雀发布支持
- GitOps 工作流

#### 统一管理平台
- Web 控制台（Vue.js）
- RESTful API 网关
- 多租户管理
- 用户与权限管理（JWT + RBAC）

### 技术特性
- 微服务架构，模块化设计
- Helm Chart 标准化部署
- Docker 容器化
- 中文化文档
