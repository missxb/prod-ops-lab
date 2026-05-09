# 快速开始指南

## 10步快速部署

### 前置条件
- Kubernetes 1.24+
- Helm 3.0+
- kubectl 已配置

### 部署步骤

1. 克隆项目
```bash
git clone https://github.com/your-org/enterprise-cloud-native-platform.git && cd enterprise-cloud-native-platform
```
> 项目已下载到本地目录

2. 安装依赖
```bash
make install-deps
```
> 自动安装 Helm 依赖和系统工具

3. 初始化基础设施
```bash
make init-infrastructure
```
> 创建命名空间和基础资源

4. 部署监控系统
```bash
make deploy-monitoring
```
> Prometheus、Grafana、Alertmanager 就绪

5. 部署日志系统
```bash
make deploy-logging
```
> ELK/EFK 日志收集管道就绪

6. 部署追踪系统
```bash
make deploy-tracing
```
> Jaeger 链路追踪服务就绪

7. 部署安全模块
```bash
make deploy-security
```
> 安全扫描和审计服务就绪

8. 部署自动化运维
```bash
make deploy-automation
```
> Ansible + ArgoCD 自动化引擎就绪

9. 部署统一管理平台
```bash
make deploy-platform
```
> Web 控制台和 API 网关就绪

10. 验证部署
```bash
make verify-deployment
```
> 所有组件健康检查通过，访问 http://localhost:3000 进入控制台

### 常用命令

```bash
make status        # 查看部署状态
make logs          # 查看组件日志
make teardown      # 清理所有资源
```
