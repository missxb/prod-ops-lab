# 自动化运维详细文档

## 1. 概述

本阶段部署完整的自动化运维体系，包括：
- Ansible: 批量管理工具
- 自动巡检: 系统健康检查
- 备份恢复: 数据备份和恢复
- 日志清理: 自动清理日志

## 2. Ansible配置

### 2.1 安装Ansible

```bash
# 安装Ansible
pip install ansible

# 验证安装
ansible --version
```

### 2.2 配置Inventory

```yaml
# ansible/inventory/hosts.yml
all:
  children:
    masters:
      hosts:
        master1:
          ansible_host: 192.168.1.10
          node_role: master
        master2:
          ansible_host: 192.168.1.11
          node_role: master
        master3:
          ansible_host: 192.168.1.12
          node_role: master
    workers:
      hosts:
        worker1:
          ansible_host: 192.168.1.20
          node_role: worker
        worker2:
          ansible_host: 192.168.1.21
          node_role: worker
        worker3:
          ansible_host: 192.168.1.22
          node_role: worker
```

### 2.3 测试连通性

```bash
# 测试所有主机
ansible all -m ping

# 测试特定组
ansible masters -m ping

# 执行命令
ansible all -m shell -a "uptime"
```

## 3. Playbook编写

### 3.1 初始化Playbook

```yaml
# ansible/playbooks/init-all.yml
---
- name: 初始化所有节点
  hosts: all
  become: yes
  vars:
    docker_version: "24.0"
    k8s_version: "1.28"
  
  tasks:
    - name: 设置主机名
      hostname:
        name: "{{ inventory_hostname }}"
    
    - name: 配置hosts文件
      lineinfile:
        path: /etc/hosts
        line: "{{ hostvars[item].ansible_host }} {{ item }}"
      loop: "{{ groups['all'] }}"
    
    - name: 禁用Swap
      command: swapoff -a
      when: ansible_swaptotal_mb > 0
    
    - name: 安装Docker
      yum:
        name: docker-ce
        state: present
      when: ansible_os_family == "RedHat"
    
    - name: 启动Docker
      systemd:
        name: docker
        state: started
        enabled: yes
```

### 3.2 运行Playbook

```bash
# 运行初始化
ansible-playbook ansible/playbooks/init-all.yml

# 只运行特定任务
ansible-playbook ansible/playbooks/init-all.yml --tags "docker"

# 检查模式
ansible-playbook ansible/playbooks/init-all.yml --check

# 限制主机
ansible-playbook ansible/playbooks/init-all.yml --limit master1
```

## 4. 自动巡检

### 4.1 巡检脚本

```bash
# scripts/09-automation/02-health-check.sh
#!/bin/bash
# 自动巡检脚本

LOG_DIR="/var/log/health-checks"
DATE=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="${LOG_DIR}/health-check-${DATE}.txt"

# 检查CPU
check_cpu() {
    echo "=== CPU检查 ==="
    mpstat 1 5 | tail -1
}

# 检查内存
check_memory() {
    echo "=== 内存检查 ==="
    free -m
}

# 检查磁盘
check_disk() {
    echo "=== 磁盘检查 ==="
    df -h | grep -v tmpfs
}

# 检查网络
check_network() {
    echo "=== 网络检查 ==="
    ping -c 3 8.8.8.8
}

# 检查服务
check_services() {
    echo "=== 服务检查 ==="
    systemctl status docker containerd kubelet
}

# 生成报告
generate_report() {
    {
        echo "健康检查报告"
        echo "时间: $(date)"
        echo "主机: $(hostname)"
        echo ""
        check_cpu
        echo ""
        check_memory
        echo ""
        check_disk
        echo ""
        check_network
        echo ""
        check_services
    } > "${REPORT_FILE}"
    
    echo "报告已生成: ${REPORT_FILE}"
}

# 主函数
main() {
    mkdir -p "${LOG_DIR}"
    generate_report
}

main "$@"
```

### 4.2 定时执行

```bash
# 添加Crontab
crontab -e

# 每天凌晨2点执行
0 2 * * * /root/enterprise-cloud-native-platform/scripts/09-automation/02-health-check.sh

# 每小时执行
0 * * * * /root/enterprise-cloud-native-platform/scripts/09-automation/02-health-check.sh
```

## 5. 备份恢复

### 5.1 备份脚本

```bash
# scripts/09-automation/04-backup-verify.sh
#!/bin/bash
# 备份脚本

BACKUP_DIR="/backup"
DATE=$(date +%Y%m%d_%H%M%S)

# 备份etcd
backup_etcd() {
    echo "=== 备份etcd ==="
    etcdctl snapshot save "${BACKUP_DIR}/etcd-${DATE}.db"
    etcdctl snapshot status "${BACKUP_DIR}/etcd-${DATE}.db" --write-out=table
}

# 备份K8s资源
backup_k8s() {
    echo "=== 备份K8s资源 ==="
    kubectl get all --all-namespaces -o yaml > "${BACKUP_DIR}/k8s-resources-${DATE}.yaml"
}

# 备份配置文件
backup_configs() {
    echo "=== 备份配置文件 ==="
    tar czf "${BACKUP_DIR}/configs-${DATE}.tar.gz" /etc/kubernetes /etc/docker /etc/containerd
}

# 校验备份
verify_backup() {
    echo "=== 校验备份 ==="
    sha256sum "${BACKUP_DIR}"/*-${DATE}.* > "${BACKUP_DIR}/checksum-${DATE}.txt"
}

# 主函数
main() {
    mkdir -p "${BACKUP_DIR}"
    backup_etcd
    backup_k8s
    backup_configs
    verify_backup
    echo "备份完成"
}

main "$@"
```

### 5.2 恢复脚本

```bash
# 恢复etcd
etcdctl snapshot restore /backup/etcd-20240101_020000.db \
    --data-dir=/var/lib/etcd-restore

# 恢复K8s资源
kubectl apply -f /backup/k8s-resources-20240101_020000.yaml

# 恢复配置文件
tar xzf /backup/configs-20240101_020000.tar.gz -C /
```

## 6. 日志清理

### 6.1 清理脚本

```bash
# scripts/09-automation/03-log-cleanup.sh
#!/bin/bash
# 日志清理脚本

# 清理Journald日志
cleanup_journald() {
    echo "=== 清理Journald日志 ==="
    journalctl --vacuum-time=7d
    journalctl --vacuum-size=500M
}

# 清理Docker日志
cleanup_docker() {
    echo "=== 清理Docker日志 ==="
    docker system prune -a -f
    docker volume prune -f
}

# 清理K8s日志
cleanup_k8s() {
    echo "=== 清理K8s日志 ==="
    # 清理Evicted Pods
    kubectl get pods --all-namespaces | grep Evicted | awk '{print $1, $2}' | \
        xargs -L1 kubectl delete pod
    
    # 清理 Completed Pods
    kubectl get pods --all-namespaces --field-selector=status.phase=Succeeded | \
        awk 'NR>1{print $1, $2}' | xargs -L1 kubectl delete pod
}

# 清理临时文件
cleanup_temp() {
    echo "=== 清理临时文件 ==="
    find /tmp -type f -atime +7 -delete
    find /var/tmp -type f -atime +7 -delete
}

# 主函数
main() {
    cleanup_journald
    cleanup_docker
    cleanup_k8s
    cleanup_temp
    echo "清理完成"
}

main "$@"
```

## 7. 常见问题

### 7.1 Ansible连接失败

```bash
# 检查SSH连通性
ssh root@192.168.1.10

# 检查Inventory
ansible-inventory --list

# 检查权限
chmod 600 ~/.ssh/id_rsa
```

### 7.2 Playbook执行失败

```bash
# 检查语法
ansible-playbook --syntax-check playbook.yml

# 检查模式
ansible-playbook --check playbook.yml

# 调试模式
ansible-playbook -vvv playbook.yml
```

### 7.3 备份失败

```bash
# 检查etcd
etcdctl endpoint health

# 检查磁盘空间
df -h /backup

# 检查权限
ls -la /backup
```

## 8. 新增脚本说明

### 8.1 资产管理脚本 (`05-asset-management.sh`)

该脚本用于管理运维资产信息，支持多种输出格式和批量扫描。

**使用方法：**
```bash
# 生成文本格式报告
bash scripts/09-automation/05-asset-management.sh --format text

# 生成 JSON 格式报告
bash scripts/09-automation/05-asset-management.sh --format json

# 生成 CSV 格式报告
bash scripts/09-automation/05-asset-management.sh --format csv

# SSH 批量扫描资产
bash scripts/09-automation/05-asset-management.sh --scan --hosts "192.168.1.0/24"
```

**功能：**
- `--format text|json|csv`：指定输出格式
- `--scan`：启用 SSH 批量扫描
- `--hosts`：指定扫描的主机范围
- 收集主机名、IP、操作系统、CPU、内存、磁盘等信息
- 自动生成资产清单报告
- 支持定时扫描（可配合 crontab）

## 9. 最佳实践


1. **版本控制**: 将Playbook和配置文件纳入Git管理
2. **测试环境**: 先在测试环境验证Playbook
3. **幂等性**: 确保Playbook可以重复执行
4. **日志记录**: 记录所有操作日志
5. **监控告警**: 监控自动化任务执行状态
