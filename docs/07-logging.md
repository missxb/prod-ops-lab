# 日志系统详细文档

## 1. 概述

本阶段部署完整的日志系统，包括：
- Elasticsearch: 日志存储和索引
- Fluentd: 日志收集和转发
- Kibana: 日志查询和可视化

## 2. Elasticsearch配置

### 2.1 架构说明

```
Elasticsearch集群架构：

┌─────────────────────────────────────────────────────────────┐
│                    Elasticsearch集群                         │
├─────────────────────────────────────────────────────────────┤
│  Master节点 (3个)                                           │
│  ├── 负责集群管理                                           │
│  ├── 元数据存储                                             │
│  └── 不存储数据                                             │
├─────────────────────────────────────────────────────────────┤
│  Data节点 (3个)                                             │
│  ├── 存储日志数据                                           │
│  ├── 执行搜索和聚合                                         │
│  └── JVM堆内存: 2G                                         │
├─────────────────────────────────────────────────────────────┤
│  存储                                                       │
│  ├── 50Gi PV per Data节点                                  │
│  └── ILM策略: 30天自动删除                                  │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 部署Elasticsearch

```bash
# 部署ES集群
kubectl apply -f manifests/logging/elasticsearch.yaml

# 检查Pod状态
kubectl get pods -n logging -l app=elasticsearch

# 检查集群健康
kubectl exec -n logging elasticsearch-0 -- curl -s localhost:9200/_cluster/health?pretty
```

### 2.3 配置说明

**关键配置项：**
- `cluster.name`: 集群名称
- `node.name`: 节点名称
- `discovery.seed_hosts`: 节点发现
- `ES_JAVA_OPTS`: JVM堆内存设置

### 2.4 验证ES

```bash
# 检查集群状态
curl -s localhost:9200/_cluster/health | jq .

# 检查节点状态
curl -s localhost:9200/_cat/nodes?v

# 检查索引
curl -s localhost:9200/_cat/indices?v
```

## 3. Fluentd配置

### 3.1 架构说明

```
Fluentd日志收集架构：

┌─────────────────────────────────────────────────────────────┐
│                    Fluentd DaemonSet                        │
├─────────────────────────────────────────────────────────────┤
│  每个节点运行一个Pod                                        │
│  ├── 收集容器日志 (stdout/stderr)                           │
│  ├── 收集系统日志 (/var/log)                                │
│  ├── 添加Kubernetes元数据                                   │
│  └── 转发到Elasticsearch                                    │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 部署Fluentd

```bash
# 部署Fluentd
kubectl apply -f manifests/logging/fluentd.yaml

# 检查Pod状态
kubectl get pods -n logging -l app=fluentd

# 查看日志
kubectl logs -n logging -l app=fluentd --tail=50
```

### 3.3 配置说明

**日志源配置：**
- 容器日志: `/var/log/containers/*.log`
- 系统日志: `/var/log/syslog`
- Docker日志: `/var/log/docker.log`

**过滤器配置：**
- kubernetes_metadata: 添加Pod/Node信息
- grep: 过滤特定日志
- record_transformer: 修改日志格式

**输出配置：**
- Elasticsearch: 转发到ES
- Buffer: 缓冲配置
- Retry: 重试策略

### 3.4 验证Fluentd

```bash
# 检查Fluentd配置
kubectl get configmap -n logging fluentd-config -o yaml

# 查看Fluentd日志
kubectl logs -n logging -l app=fluentd -f

# 测试日志收集
kubectl run test --image=busybox -- echo "test log" && \
kubectl logs -n default test
```

## 4. Kibana配置

### 4.1 部署Kibana

```bash
# 部署Kibana
kubectl apply -f manifests/logging/kibana.yaml

# 检查Pod状态
kubectl get pods -n logging -l app=kibana

# 访问Kibana
kubectl port-forward -n logging svc/kibana 5601:5601
```

### 4.2 配置说明

**关键配置项：**
- `ELASTICSEARCH_HOSTS`: ES连接地址
- `SERVER_NAME`: Kibana服务器名称
- `SERVER_HOST`: 监听地址

### 4.3 使用Kibana

**创建Index Pattern：**
1. 访问Kibana Web界面
2. 进入 Management -> Stack Management -> Index Patterns
3. 创建Index Pattern: `kubernetes-*`
4. 选择 `@timestamp` 作为时间字段

**查询日志：**
1. 进入 Discover
2. 选择Index Pattern
3. 使用KQL查询语法

**KQL查询示例：**
```kql
# 查找特定Pod的日志
kubernetes.pod.name: "my-pod"

# 查找特定命名空间的日志
kubernetes.namespace_name: "default"

# 查找错误日志
message: "error" OR message: "ERROR"

# 组合查询
kubernetes.pod.name: "my-pod" AND message: "error"
```

## 5. 日志查询语法

### 5.1 KQL语法

```kql
# 精确匹配
status: 200

# 范围查询
response_time > 1000

# 存在字段
error.message: *

# 通配符
message: *error*

# 布尔运算
status: 200 AND method: "GET"
status: 200 OR status: 304
NOT status: 500
```

### 5.2 Lucene语法

```lucene
# 精确匹配
status:200

# 范围查询
response_time:[1000 TO *]

# 存在字段
error.message:*

# 通配符
message:error*

# 布尔运算
status:200 AND method:GET
status:200 OR status:304
NOT status:500
```

## 6. 索引生命周期管理

### 6.1 ILM策略

```bash
# 创建ILM策略
curl -X PUT "localhost:9200/_ilm/policy/logs-policy" -H 'Content-Type: application/json' -d'
{
  "policy": {
    "phases": {
      "hot": {
        "actions": {
          "rollover": {
            "max_size": "10gb",
            "max_age": "1d"
          }
        }
      },
      "warm": {
        "min_age": "7d",
        "actions": {
          "shrink": {
            "number_of_shards": 1
          }
        }
      },
      "delete": {
        "min_age": "30d",
        "actions": {
          "delete": {}
        }
      }
    }
  }
}'
```

### 6.2 索引模板

```bash
# 创建索引模板
curl -X PUT "localhost:9200/_index_template/logs-template" -H 'Content-Type: application/json' -d'
{
  "index_patterns": ["kubernetes-*"],
  "template": {
    "settings": {
      "number_of_shards": 3,
      "number_of_replicas": 1,
      "index.lifecycle.name": "logs-policy",
      "index.lifecycle.rollover_alias": "kubernetes"
    }
  }
}'
```

## 7. 性能优化

### 7.1 ES优化

```bash
# 调整JVM堆内存
# 建议设置为物理内存的50%，不超过32G

# 调整分片数
# 建议每个分片不超过50GB

# 调整副本数
# 生产环境建议1-2个副本
```

### 7.2 Fluentd优化

```bash
# 调整缓冲区大小
buffer_chunk_limit 2M
buffer_total_limit 512M

# 调整刷新间隔
flush_interval 5s

# 调整重试策略
retry_max_interval 30s
```

## 8. 常见问题

### 8.1 ES集群状态黄色

```bash
# 检查分片状态
curl -s localhost:9200/_cat/shards?v

# 检查未分配分片
curl -s localhost:9200/_cluster/allocation/explain?pretty
```

### 8.2 Fluentd日志丢失

```bash
# 检查Fluentd日志
kubectl logs -n logging -l app=fluentd --tail=100

# 检查缓冲区
kubectl exec -n logging fluentd-xxxxx -- ls /var/log/fluentd-buffers/
```

### 8.3 Kibana查询慢

```bash
# 检查索引状态
curl -s localhost:9200/_cat/indices?v

# 优化查询
# 使用时间范围过滤
# 避免使用通配符开头的查询
# 使用filter代替query
```

## 9. 最佳实践

1. **索引命名**: 使用时间戳命名索引，如`kubernetes-2024.01.01`
2. **ILM策略**: 配置自动 rollover 和删除策略
3. **日志格式**: 统一日志格式，便于查询
4. **监控告警**: 监控ES集群健康状态
5. **备份策略**: 定期备份ES数据
