# 企业级云原生运维平台 - 监控运维手册

> 版本: v1.0.0  
> 最后更新: 2026-05-10  
> 适用环境: 生产环境 / 预发布环境

---

## 目录

1. [监控系统概览](#1-监控系统概览)
2. [常见告警处理](#2-常见告警处理)
3. [性能调优](#3-性能调优)
4. [故障排查](#4-故障排查)
5. [日常运维任务](#5-日常运维任务)
6. [紧急响应流程](#6-紧急响应流程)

---

## 1. 监控系统概览

### 1.1 组件清单

| 组件 | 用途 | 副本数 | 存储 |
|------|------|--------|------|
| Prometheus | 指标收集与查询 | 3 | 100Gi SSD |
| Thanos | 长期存储 | 3 | S3 |
| Alertmanager | 告警管理 | 3 | 无状态 |
| Grafana | 可视化 | 2 | 10Gi |
| Loki | 日志存储 | 3 | 50Gi SSD |
| Fluent Bit | 日志收集 | DaemonSet | 无 |
| Jaeger | 分布式追踪 | 3 | 50Gi |

### 1.2 监控端点

```
Prometheus:     https://prometheus.internal:9090
Grafana:        https://grafana.internal:3000
Alertmanager:   https://alertmanager.internal:9093
Loki:           https://loki.internal:3100
Jaeger:         https://jaeger.internal:16686
```

### 1.3 告警路由

```
P1 (紧急) → PagerDuty → 电话 + 短信 + Slack
P2 (重要) → Slack + 企业微信
P3 (一般) → 企业微信
P4 (信息) → 仅 Grafana Dashboard
```

---

## 2. 常见告警处理

### 2.1 Pod 相关告警

#### 告警: PodCrashLooping

**严重级别**: P2 (重要)  
**触发条件**: Pod 在5分钟内重启超过5次

**排查步骤**:

```bash
# 1. 查看 Pod 状态
kubectl get pods -n <namespace> | grep CrashLoopBackOff

# 2. 查看 Pod 事件
kubectl describe pod <pod-name> -n <namespace>

# 3. 查看容器日志
kubectl logs <pod-name> -n <namespace> --previous

# 4. 检查资源限制
kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.spec.containers[*].resources}'

# 5. 检查 OOMKilled
kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.status.containerStatuses[*].lastState.terminated.reason}'
```

**常见原因及解决方案**:

| 原因 | 症状 | 解决方案 |
|------|------|---------|
| OOMKilled | lastState.terminated.reason=OOMKilled | 增加内存限制 |
| 应用错误 | 日志中有异常堆栈 | 修复应用代码 |
| 配置错误 | 配置文件不存在 | 检查 ConfigMap/Secret |
| 依赖不可用 | 连接数据库失败 | 检查依赖服务状态 |
| 健康检查失败 | livenessProbe 失败 | 调整探针参数 |

**修复命令**:

```bash
# 增加内存限制 (临时)
kubectl patch deployment <deployment> -n <namespace> --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/memory", "value": "2Gi"}
]'

# 滚动重启
kubectl rollout restart deployment/<deployment> -n <namespace>
```

#### 告警: PodNotReady

**严重级别**: P2 (重要)  
**触发条件**: Pod 处于 NotReady 状态超过3分钟

**排查步骤**:

```bash
# 1. 查看 Pod 状态
kubectl get pod <pod-name> -n <namespace> -o wide

# 2. 查看容器状态
kubectl describe pod <pod-name> -n <namespace> | grep -A 5 "Containers:"

# 3. 检查探针配置
kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.spec.containers[*].livenessProbe}'

# 4. 检查节点资源
kubectl describe node <node-name> | grep -A 5 "Allocated resources"
```

**解决方案**:

```bash
# 检查并修复探针
kubectl patch deployment <deployment> -n <namespace> --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/initialDelaySeconds", "value": 30}
]'

# 检查节点压力
kubectl top nodes
kubectl describe node <node-name> | grep Conditions
```

#### 告警: PodEvicted

**严重级别**: P3 (一般)  
**触发条件**: Pod 被驱逐

**排查步骤**:

```bash
# 1. 查看被驱逐的 Pod
kubectl get pods -n <namespace> --field-selector=status.phase=Failed | grep Evicted

# 2. 查看驱逐原因
kubectl describe pod <pod-name> -n <namespace> | grep -A 3 "Reason:"

# 3. 检查节点状态
kubectl get nodes
kubectl describe node <node-name> | grep Conditions
```

**解决方案**:

```bash
# 清理被驱逐的 Pod
kubectl get pods -n <namespace> --field-selector=status.phase=Failed | grep Evicted | \
  awk '{print $1}' | xargs kubectl delete pod -n <namespace>

# 如果是磁盘压力，清理日志
kubectl exec -n <namespace> <pod-name> -- du -sh /var/log/*
```

### 2.2 资源相关告警

#### 告警: HighCPUUsage

**严重级别**: P2 (重要)  
**触发条件**: CPU 使用率 > 80% 持续5分钟

**排查步骤**:

```bash
# 1. 查看节点 CPU 使用
kubectl top nodes

# 2. 查看 Pod CPU 使用
kubectl top pods -n <namespace> --sort-by=cpu

# 3. 检查 HPA 状态
kubectl get hpa -n <namespace>

# 4. 查看 CPU 限流
kubectl top pods -n <namespace> -l app=<app>
```

**解决方案**:

```bash
# 扩容 Deployment
kubectl scale deployment <deployment> -n <namespace> --replicas=5

# 更新 HPA 配置
kubectl patch hpa <hpa-name> -n <namespace> --type='json' -p='[
  {"op": "replace", "path": "/spec/maxReplicas", "value": 20},
  {"op": "replace", "path": "/spec/metrics/0/resource/target/averageUtilization", "value": 60}
]'
```

#### 告警: HighMemoryUsage

**严重级别**: P2 (重要)  
**触发条件**: 内存使用率 > 85% 持续5分钟

**排查步骤**:

```bash
# 1. 查看内存使用
kubectl top pods -n <namespace> --sort-by=memory

# 2. 检查内存泄漏
kubectl exec -n <namespace> <pod-name> -- free -m

# 3. 查看 OOM 事件
kubectl get events -n <namespace> --field-selector reason=OOMKilling
```

**解决方案**:

```bash
# 增加内存限制
kubectl patch deployment <deployment> -n <namespace> --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/memory", "value": "4Gi"}
]'

# 如果是内存泄漏，重启 Pod
kubectl delete pod <pod-name> -n <namespace>
```

#### 告警: HighDiskUsage

**严重级别**: P1 (紧急) - 如果 > 90%  
**触发条件**: 磁盘使用率 > 80%

**排查步骤**:

```bash
# 1. 检查 PVC 使用情况
kubectl exec -n <namespace> <pod-name> -- df -h

# 2. 查找大文件
kubectl exec -n <namespace> <pod-name> -- find / -type f -size +100M 2>/dev/null

# 3. 检查日志大小
kubectl exec -n <namespace> <pod-name> -- du -sh /var/log/*

# 4. 检查临时文件
kubectl exec -n <namespace> <pod-name> -- du -sh /tmp/*
```

**解决方案**:

```bash
# 扩容 PVC
kubectl patch pvc <pvc-name> -n <namespace> --type='json' -p='[
  {"op": "replace", "path": "/spec/resources/requests/storage", "value": "200Gi"}
]'

# 清理日志 (谨慎)
kubectl exec -n <namespace> <pod-name> -- find /var/log -name "*.log" -mtime +7 -delete
```

### 2.3 网络相关告警

#### 告警: HighLatency

**严重级别**: P2 (重要)  
**触发条件**: P99 延迟 > 2秒 持续5分钟

**排查步骤**:

```bash
# 1. 查看请求延迟
# Grafana Dashboard: Service Latency

# 2. 检查网络策略
kubectl get networkpolicy -n <namespace>

# 3. 检查 DNS 解析
kubectl exec -n <namespace> <pod-name> -- nslookup kubernetes.default

# 4. 检查连接数
kubectl exec -n <namespace> <pod-name> -- ss -s
```

**解决方案**:

```bash
# 检查并调整网络策略
kubectl get networkpolicy -n <namespace> -o yaml

# 检查 Service 配置
kubectl get svc -n <namespace> -o yaml

# 如果是 DNS 问题，检查 CoreDNS
kubectl get pods -n kube-system -l k8s-app=kube-dns
```

#### 告警: HighErrorRate

**严重级别**: P2 (重要)  
**触发条件**: 5xx 错误率 > 1% 持续5分钟

**排查步骤**:

```bash
# 1. 查看错误日志
kubectl logs -n <namespace> <pod-name> --tail=100 | grep -i error

# 2. 检查 HTTP 状态码
# Grafana Dashboard: HTTP Status Codes

# 3. 检查依赖服务
kubectl exec -n <namespace> <pod-name> -- curl -s http://dependency-svc:8080/health

# 4. 检查数据库连接
kubectl exec -n <namespace> <pod-name> -- psql -h pg-svc -U admin -c "SELECT 1"
```

**解决方案**:

```bash
# 检查服务健康状态
kubectl get pods -n <namespace> -l app=<app>

# 检查事件
kubectl get events -n <namespace> --sort-by='.lastTimestamp'

# 滚动重启
kubectl rollout restart deployment/<deployment> -n <namespace>
```

### 2.4 存储相关告警

#### 告警: PVCPending

**严重级别**: P2 (重要)  
**触发条件**: PVC 处于 Pending 状态超过5分钟

**排查步骤**:

```bash
# 1. 查看 PVC 状态
kubectl get pvc -n <namespace>

# 2. 查看 PVC 事件
kubectl describe pvc <pvc-name> -n <namespace>

# 3. 检查存储类
kubectl get storageclass

# 4. 检查可用存储
kubectl get pv
```

**解决方案**:

```bash
# 检查存储类是否正确
kubectl get pvc <pvc-name> -n <namespace> -o yaml | grep storageClassName

# 检查云平台配额
# AWS: 检查 EBS 配额
# GCP: 检查 Persistent Disk 配额
# Azure: 检查 Disk 配额
```

#### 告警: VolumeHighUsage

**严重级别**: P2 (重要)  
**触发条件**: 卷使用率 > 80%

**排查步骤**:

```bash
# 1. 检查卷使用情况
kubectl exec -n <namespace> <pod-name> -- df -h /data

# 2. 查找大文件
kubectl exec -n <namespace> <pod-name> -- du -sh /data/* | sort -rh | head -10

# 3. 检查是否可以清理
kubectl exec -n <namespace> <pod-name> -- ls -la /data/
```

**解决方案**:

```bash
# 扩容卷
kubectl patch pvc <pvc-name> -n <namespace> --type='json' -p='[
  {"op": "replace", "path": "/spec/resources/requests/storage", "value": "200Gi"}
]'

# 或者清理旧数据
kubectl exec -n <namespace> <pod-name> -- rm -rf /data/old-backups/*
```

---

## 3. 性能调优

### 3.1 Prometheus 性能调优

#### 3.1.1 查询优化

```bash
# 慢查询分析
# 访问 Prometheus UI → Status → Runtime & Build Information

# 使用 recording rules 预计算常用查询
# 示例: 预计算 5 分钟平均请求率
# recording_rule.yaml
groups:
  - name: http_requests
    rules:
      - record: http_requests:rate5m
        expr: sum(rate(http_requests_total[5m])) by (service)
```

#### 3.1.2 存储优化

```bash
# 检查存储使用
# Grafana Dashboard: Prometheus Stats

# 调整保留期
# values.yaml
prometheus:
  retention: 30d
  retentionSize: "50GB"

# 使用 Thanos 优化长期存储
thanos:
  sidecar:
    objectStorageConfig:
      name: thanos-objstore
      key: objstore.yml
```

#### 3.1.3 内存优化

```bash
# 检查内存使用
kubectl top pods -n monitoring -l app.kubernetes.io/name=prometheus

# 调整内存限制
kubectl patch deployment prometheus-kube-prometheus-prometheus -n monitoring --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/memory", "value": "16Gi"}
]'
```

### 3.2 Grafana 性能调优

```bash
# 检查仪表板加载时间
# Grafana → Dashboard → Settings → Insights

# 优化查询
# 1. 使用变量减少查询范围
# 2. 使用 recording rules 预计算
# 3. 避免高基数查询

# 调整 Grafana 配置
# values.yaml
grafana:
 .ini:
    unified_alerting:
      min_interval_seconds: 10
    dashboards:
      min_refresh_interval: 30s
```

### 3.3 日志系统调优

```bash
# Fluent Bit 性能优化
# fluent-bit-config.yaml
pipeline:
  inputs:
    - name: tail
      path: /var/log/containers/*.log
      refresh_interval: 5
      mem_buf_limit: 50MB
      
  outputs:
    - name: loki
      host: loki.logging.svc
      port: 3100
      batch_size: 1000
      batch_wait: 1s
      line_format: json
```

---

## 4. 故障排查

### 4.1 Prometheus 无法抓取目标

**症状**: Prometheus Targets 显示 DOWN

**排查步骤**:

```bash
# 1. 检查目标状态
kubectl port-forward -n monitoring svc/prometheus 9090
# 浏览器访问 http://localhost:9090/targets

# 2. 检查 ServiceMonitor
kubectl get servicemonitor -A
kubectl describe servicemonitor <name> -n <namespace>

# 3. 手动测试抓取
kubectl exec -n monitoring <prometheus-pod> -- wget -qO- http://<target>:8080/metrics

# 4. 检查网络策略
kubectl get networkpolicy -n <namespace>
```

**常见原因**:

| 原因 | 解决方案 |
|------|---------|
| 网络不通 | 检查网络策略和防火墙 |
| 端口错误 | 确认 ServiceMonitor 端口配置 |
| 认证失败 | 检查 mTLS 或 Basic Auth 配置 |
| 目标不可用 | 确认目标 Pod 运行正常 |

### 4.2 告警未发送

**症状**: 告警触发但未收到通知

**排查步骤**:

```bash
# 1. 检查告警状态
kubectl port-forward -n monitoring svc/alertmanager 9093
# 浏览器访问 http://localhost:9093/#/alerts

# 2. 检查告警规则
kubectl get prometheusrule -n monitoring -o yaml

# 3. 检查 Alertmanager 配置
kubectl get secret alertmanager-config -n monitoring -o yaml

# 4. 检查路由配置
kubectl exec -n monitoring <alertmanager-pod> -- amtool config show
```

**常见原因**:

| 原因 | 解决方案 |
|------|---------|
| 静默期 | 检查是否处于静默期 |
| 路由错误 | 检查 Alertmanager 路由配置 |
| 接收器配置错误 | 检查 Webhook/PagerDuty 配置 |
| 网络不通 | 检查外部服务连通性 |

### 4.3 Grafana 仪表板加载慢

**症状**: 仪表板加载时间 > 10秒

**排查步骤**:

```bash
# 1. 检查 Grafana 性能
kubectl top pods -n monitoring -l app.kubernetes.io/name=grafana

# 2. 检查查询性能
# Grafana → Explore → 查看查询时间

# 3. 检查数据源连接
# Grafana → Settings → Data Sources → Test

# 4. 优化仪表板
# - 减少面板数量
# - 使用变量
# - 调整时间范围
```

**优化建议**:

```yaml
# 使用 recording rules 预计算
# 添加到 Prometheus 配置
rule_files:
  - /etc/prometheus/recording_rules/*.yaml

# 录音规则示例
groups:
  - name: performance
    rules:
      - record: job:http_requests:rate5m
        expr: sum(rate(http_requests_total[5m])) by (job)
      - record: job:http_requests_duration:histogram99
        expr: histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, job))
```

### 4.4 日志查询失败

**症状**: Loki 查询超时或无结果

**排查步骤**:

```bash
# 1. 检查 Loki 状态
kubectl get pods -n logging -l app=loki

# 2. 检查 Fluent Bit 日志
kubectl logs -n logging <fluent-bit-pod> --tail=50

# 3. 手动查询 Loki
curl -G "http://loki:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={namespace="production"}' \
  --data-urlencode 'limit=10'

# 4. 检查标签配置
kubectl get pod -n logging -l app=loki -o yaml | grep -A 20 "config"
```

**常见原因**:

| 原因 | 解决方案 |
|------|---------|
| Fluent Bit 未运行 | 重启 Fluent Bit DaemonSet |
| 标签配置错误 | 检查 Loki 标签配置 |
| 索引损坏 | 重建 Loki 索引 |
| 存储空间不足 | 清理旧日志或扩容 |

---

## 5. 日常运维任务

### 5.1 每日检查

```bash
#!/bin/bash
# scripts/daily-monitoring-check.sh

echo "=== 监控系统健康检查 ==="

echo "1. Prometheus 状态"
kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus
kubectl exec -n monitoring <prometheus-pod> -- wget -qO- http://localhost:9090/-/healthy

echo ""
echo "2. Alertmanager 状态"
kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager
kubectl exec -n monitoring <alertmanager-pod> -- wget -qO- http://localhost:9093/-/healthy

echo ""
echo "3. Grafana 状态"
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana

echo ""
echo "4. 活跃告警数量"
kubectl exec -n monitoring <alertmanager-pod> -- amtool alert --format=json | jq length

echo ""
echo "5. 存储使用情况"
kubectl get pv | grep monitoring
```

### 5.2 每周检查

```bash
#!/bin/bash
# scripts/weekly-monitoring-check.sh

echo "=== 每周监控系统检查 ==="

echo "1. Prometheus 存储使用趋势"
# 检查过去7天的存储增长

echo ""
echo "2. 告警规则有效性"
# 检查过去7天触发的告警数量

echo ""
echo "3. 仪表板访问统计"
# 检查仪表板使用情况

echo ""
echo "4. 日志系统性能"
# 检查 Fluent Bit 和 Loki 性能指标

echo ""
echo "5. 证书有效期"
kubectl get certificates -A -o custom-columns=\
  NAME:.metadata.name,\
  SECRET:.spec.secretName,\
  NOT_AFTER:.status.notAfter
```

### 5.3 每月检查

```bash
#!/bin/bash
# scripts/monthly-monitoring-check.sh

echo "=== 每月监控系统检查 ==="

echo "1. Prometheus 数据清理"
# 检查超过保留期的数据是否已清理

echo ""
echo "2. 日志归档"
# 检查日志归档状态

echo ""
echo "3. 性能基线对比"
# 与上月性能基线对比

echo ""
echo "4. 安全审计"
# 检查监控系统安全配置

echo ""
echo "5. 容量规划"
# 根据增长趋势规划下月容量
```

---

## 6. 紧急响应流程

### 6.1 P1 紧急告警响应

**触发条件**: 系统完全不可用或数据丢失

**响应流程**:

```
1. 接收告警 (0-2分钟)
   ├── 确认告警有效性
   ├── 评估影响范围
   └── 启动应急响应

2. 问题定位 (2-10分钟)
   ├── 检查监控仪表板
   ├── 查看日志和追踪
   └── 定位问题根源

3. 临时缓解 (10-30分钟)
   ├── 执行紧急修复
   ├── 流量切换
   └── 回滚操作

4. 根因修复 (30-60分钟)
   ├── 修复根本原因
   ├── 验证修复效果
   └── 监控恢复情况

5. 复盘总结 (24小时内)
   ├── 编写故障报告
   ├── 更新运维手册
   └── 预防措施
```

### 6.2 应急联系人

| 角色 | 姓名 | 联系方式 | 职责 |
|------|------|---------|------|
| On-Call 工程师 | 轮值 | PagerDuty | 一线响应 |
| 技术负责人 | [姓名] | [电话] | 技术决策 |
| 管理层 | [姓名] | [电话] | 资源协调 |

### 6.3 应急工具

```bash
# 紧急回滚
kubectl rollout undo deployment/<deployment> -n <namespace>

# 流量切换
kubectl patch svc <service> -n <namespace> --type='json' -p='[
  {"op": "replace", "path": "/spec/selector/version", "value": "v1"}
]'

# 重启所有 Pod
kubectl rollout restart deployment/<deployment> -n <namespace>

# 查看紧急事件
kubectl get events -n <namespace> --sort-by='.lastTimestamp' --field-selector type=Warning
```

---

## 附录: 有用的 PromQL 查询

```promql
# Pod CPU 使用率
100 * (sum(rate(container_cpu_usage_seconds_total{namespace="<namespace>"}[5m])) by (pod) / 
sum(kube_pod_container_resource_limits{namespace="<namespace>", resource="cpu"}) by (pod))

# Pod 内存使用率
100 * (sum(container_memory_working_set_bytes{namespace="<namespace>"}[5m]) by (pod) / 
sum(kube_pod_container_resource_limits{namespace="<namespace>", resource="memory"}) by (pod))

# HTTP 请求错误率
100 * sum(rate(http_requests_total{namespace="<namespace>", status=~"5.."}[5m])) / 
sum(rate(http_requests_total{namespace="<namespace>"}[5m]))

# P99 延迟
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace="<namespace>"}[5m])) by (le))

# PVC 使用率
100 * kubelet_volume_stats_used_bytes{namespace="<namespace>"} / 
kubelet_volume_stats_capacity_bytes{namespace="<namespace>"}
```
