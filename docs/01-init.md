# 阶段1：基础环境初始化详细文档

## 文档信息
- 版本：v1.0
- 更新日期：2026-05-09
- 维护团队：云原生平台运维组

---

## 1. 阶段目标

完成企业级云原生运维平台的基础环境准备工作，包括：
- 操作系统基础配置与安全加固
- 网络环境规划与配置
- 基础软件依赖安装
- 时间同步与DNS配置
- 用户权限与安全策略设置
- 基础监控代理部署

## 2. 架构说明

```
┌─────────────────────────────────────────────────┐
│                  管理网络 (172.16.0.0/16)         │
├──────────┬──────────┬──────────┬────────────────┤
│  Node 1  │  Node 2  │  Node 3  │   LB/HAProxy  │
│ (Master) │ (Worker) │ (Worker) │   (可选)       │
├──────────┴──────────┴──────────┴────────────────┤
│                  业务网络 (10.0.0.0/8)           │
├─────────────────────────────────────────────────┤
│                  存储网络 (192.168.0.0/24)       │
└─────────────────────────────────────────────────┘
```

### 节点角色规划
| 节点 | 内存 | CPU | 角色 | IP地址 |
|------|------|-----|------|--------|
| node-1 | 16GB+ | 8核+ | K8s Master | 172.16.0.11 |
| node-2 | 16GB+ | 8核+ | K8s Worker | 172.16.0.12 |
| node-3 | 16GB+ | 8核+ | K8s Worker | 172.16.0.13 |
| lb-1 | 4GB | 2核 | 负载均衡器 | 172.16.0.10 |

## 3. 前置条件

- 所有节点已安装 Ubuntu 22.04 LTS / CentOS 8+ / RHEL 8+
- 每节点至少 4GB RAM，推荐 16GB+
- 每节点至少 2 vCPU，推荐 8核+
- 磁盘至少 100GB 可用空间
- 网络互通（管理网络、业务网络、存储网络）
- root 或 sudo 权限
- 禁用 Swap（K8s 要求）

## 4. 详细步骤

### 4.1 系统基础配置

#### 4.1.1 设置主机名和 hosts 文件

```bash
# 设置主机名 —— 方便节点间识别和管理
hostnamectl set-hostname node-1

# 编辑 /etc/hosts 添加所有节点映射
# 避免依赖 DNS 解析失败导致集群通信异常
cat >> /etc/hosts << 'EOF'
172.16.0.10 lb-1
172.16.0.11 node-1
172.16.0.12 node-2
172.16.0.13 node-3
EOF
```

#### 4.1.2 关闭 Swap

```bash
# K8s 要求关闭 Swap，因为 kubelet 依赖内存限制
# Swap 会导致 Pod OOM 误判，影响调度策略
swapoff -a

# 永久关闭，注释 /etc/fstab 中 swap 行
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# 验证
free -h
# 输出中 Swap 应全部为 0
#               total        used        free      shared  buff/cache   available
# Mem:           15Gi       1.2Gi        12Gi       256Mi       1.8Gi        13Gi
# Swap:            0B          0B          0B
```

#### 4.1.3 配置系统参数

```bash
# 加载内核模块 —— K8s 网络插件需要这些模块
cat > /etc/modules-load.d/k8s.conf << 'EOF'
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# 配置内核网络参数 —— 确保 bridge 流量经过 iptables
cat > /etc/sysctl.d/k8s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.conf.all.forwarding        = 1
net.ipv4.conf.default.forwarding    = 1
vm.swappiness                       = 0
vm.max_map_count                   = 262144
fs.file-max                        = 655360
net.core.somaxconn                 = 65535
net.ipv4.tcp_tw_reuse              = 1
net.ipv4.tcp_fin_timeout           = 30
net.ipv4.tcp_keepalive_time        = 1200
net.core.rmem_max                  = 16777216
net.core.wmem_max                  = 16777216
EOF

# 立即生效
sysctl --system
```

#### 4.1.4 配置防火墙（可选但推荐）

```bash
# 如果使用 firewalld
# 管理网络端口 —— K8s API Server、etcd 等
firewall-cmd --permanent --add-port=6443/tcp     # K8s API
firewall-cmd --permanent --add-port=2379-2380/tcp # etcd
firewall-cmd --permanent --add-port=10250/tcp    # kubelet
firewall-cmd --permanent --add-port=10251/tcp    # kube-scheduler
firewall-cmd --permanent --add-port=10252/tcp    # kube-controller-manager
firewall-cmd --permanent --add-port=8472/udp     # Flannel VXLAN
firewall-cmd --permanent --add-port=8080/tcp     # NodePort 服务
firewall-cmd --permanent --add-port=30000-32767/tcp # NodePort 范围
firewall-cmd --reload
```

### 4.2 安装基础软件依赖

#### 4.2.1 更新系统并安装基础工具

```bash
# 更新系统包索引 —— 确保安装最新版本的软件包
apt-get update && apt-get upgrade -y

# 安装基础工具 —— 后续配置和排查需要
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    wget \
    net-tools \
    htop \
    iotop \
    sysstat \
    jq \
    vim \
    git \
    unzip \
    socat \
    conntrack \
    ipvsadm
```

#### 4.2.2 安装 Docker/Containerd

```bash
# 安装 containerd —— K8s 推荐的容器运行时
# containerd 比 Docker 更轻量，无 daemon overhead

# 安装 Docker 仓库（提供 containerd）
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) \
    signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update
apt-get install -y containerd.io

# 配置 containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# 启用 SystemdCgroup —— K8s 必需，确保 cgroup 驱动一致
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' \
    /etc/containerd/config.toml

# 使用国内镜像源（加速拉取）
sed -i 's|registry.k8s.io/pause:3.8|registry.aliyuncs.com/google_containers/pause:3.9|' \
    /etc/containerd/config.toml

# 重启 containerd 使配置生效
systemctl daemon-reload
systemctl enable --now containerd
systemctl restart containerd

# 验证
crictl info | jq .config.ContainerdConfig
```

### 4.3 时间同步配置

```bash
# 安装 chrony —— 分布式系统必须时间同步
# etcd 和 K8s 对时间偏差敏感，超过 500ms 可能导致证书验证失败
apt-get install -y chrony

# 配置 NTP 服务器
cat > /etc/chrony/chrony.conf << 'EOF'
server ntp.aliyun.com iburst
server ntp1.aliyun.com iburst
server cn.pool.ntp.org iburst

driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF

systemctl enable --now chrony
chronyc sources -v
# 应显示同步到的 NTP 服务器和 offset
```

### 4.4 DNS 配置

```bash
# 配置 DNS 解析 —— 确保集群内外域名解析正常
cat > /etc/resolv.conf << 'EOF'
nameserver 223.5.5.5
nameserver 223.6.6.6
nameserver 8.8.8.8
search cluster.local
EOF
```

### 4.5 安全配置

```bash
# 禁用 root SSH 登录（可选但推荐）
# 先创建运维用户并配置 sudo
useradd -m -s /bin/bash devops
echo 'devops ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/devops
chmod 440 /etc/sudoers.d/devops

# 配置 SSH 密钥登录
mkdir -p /home/devops/.ssh
chmod 700 /home/devops/.ssh
# 将公钥复制到 authorized_keys
# ssh-copy-id devops@node-1

# 禁用密码登录（配置密钥后）
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/PermitRootLogin yes/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl restart sshd
```

### 4.6 安装 kubeadm、kubelet、kubectl

```bash
# 添加 Kubernetes 官方 APT 仓库
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | \
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
    https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | \
    tee /etc/apt/sources.list.d/kubernetes.list

apt-get update

# 安装指定版本 —— 锁定版本避免自动升级导致集群异常
apt-get install -y kubelet=1.29.* kubeadm=1.29.* kubectl=1.29.*
apt-mark hold kubelet kubeadm kubectl

# 配置 kubelet 使用 containerd
cat > /etc/default/kubelet << 'EOF'
KUBELET_EXTRA_ARGS="--container-runtime-endpoint=unix:///run/containerd/containerd.sock"
EOF

systemctl daemon-reload
systemctl enable kubelet
```

### 4.7 部署基础监控代理

```bash
# 安装 node-exporter —— 基础节点指标采集
# 后续 Prometheus 会抓取这些指标

# 下载 node-exporter
wget https://github.com/prometheus/node_exporter/releases/download/v1.7.0/node_exporter-1.7.0.linux-amd64.tar.gz
tar xzf node_exporter-1.7.0.linux-amd64.tar.gz
cp node_exporter-1.7.0.linux-amd64/node_exporter /usr/local/bin/

# 创建 systemd 服务
cat > /etc/systemd/system/node-exporter.service << 'EOF'
[Unit]
Description=Node Exporter
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/node_exporter \
    --collector.systemd \
    --collector.processes
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node-exporter

# 验证 —— 访问 http://node-ip:9100/metrics
curl -s http://localhost:9100/metrics | head -5
```

## 5. 验证方法

```bash
# 5.1 检查系统内核参数
sysctl net.bridge.bridge-nf-call-iptables
# 预期输出: net.bridge.bridge-nf-call-iptables = 1

# 5.2 检查 Swap 状态
swapon --show
# 预期输出为空（无 swap 分区）

# 5.3 检查 containerd 运行状态
systemctl status containerd
# 预期: active (running)

# 5.4 检查时间同步
chronyc tracking
# 预期: System time offset 显示与服务器同步

# 5.5 检查 kubeadm 安装
kubeadm version
# 预期: kubeadm version: &version.Info{Major:"1", Minor:"29", ...}

# 5.6 检查所有基础服务
for svc in containerd chrony kubelet; do
    echo "=== $svc ==="
    systemctl is-active $svc
done
# 预期所有输出: active

# 5.7 节点间连通性测试
for node in node-2 node-3; do
    ping -c 3 $node
done

# 5.8 检查磁盘空间
df -h / /var
# 预期 / 和 /var 至少有 50GB 可用空间
```

## 6. 常见问题

### Q1: containerd 启动失败，报错 "failed to start daemon"
**原因**：containerd 配置文件格式错误或端口被占用
**解决**：
```bash
# 查看详细日志
journalctl -u containerd -n 100 --no-pager

# 检查端口占用
ss -tlnp | grep 9999

# 重置配置
containerd config default > /etc/containerd/config.toml
systemctl restart containerd
```

### Q2: kubeadm init 失败，报错 "swap is enabled"
**原因**：Swap 未完全关闭
**解决**：
```bash
swapoff -a
# 确认 /etc/fstab 中 swap 行已注释
# 重新 init
kubeadm init ...
```

### Q3: 时间同步异常
**原因**：NTP 服务器不可达
**解决**：
```bash
# 检查 NTP 服务器
chronyc sources -v

# 手动强制同步
chronyc makestep

# 替换为其他 NTP 服务器
# 编辑 /etc/chrony/chrony.conf
```

### Q4: kubelet 启动失败
**原因**：containerd 未运行或配置不匹配
**解决**：
```bash
# 确认 containerd 运行
systemctl status containerd

# 确认 cgroup driver 一致
crictl info | grep SystemdCgroup
# 应输出: "SystemdCgroup": true

# 检查 kubelet 日志
journalctl -u kubelet -n 50
```

### Q5: 防火墙导致端口不通
**解决**：
```bash
# 检查端口监听
ss -tlnp | grep 6443

# 临时关闭防火墙测试（生产环境慎用）
systemctl stop firewalld

# 正确做法：添加规则
firewall-cmd --add-port=6443/tcp --permanent
firewall-cmd --reload
```

## 7. 回滚方案

### 7.1 完全回滚到初始状态

```bash
# 停止所有自定义服务
systemctl stop kubelet containerd chrony node-exporter

# 卸载 kubeadm/kubelet/kubectl
apt-get remove -y kubelet kubeadm kubectl
apt-get autoremove -y

# 移除 containerd
apt-get remove -y containerd.io
apt-get autoremove -y

# 清理配置文件
rm -rf /etc/containerd/
rm -rf /etc/sysctl.d/k8s.conf
rm -rf /etc/modules-load.d/k8s.conf

# 恢复 /etc/hosts
# 手动编辑移除添加的行

# 重新启用 Swap（如果生产需要）
sed -i '/^#.*swap/s/^#//' /etc/fstab
swapon -a
```

### 7.2 部分回滚（仅回滚配置）

```bash
# 恢复 containerd 默认配置
containerd config default > /etc/containerd/config.toml
systemctl restart containerd

# 恢复系统参数
rm /etc/sysctl.d/k8s.conf
sysctl --system
```

## 8. 新增脚本说明

### 8.1 时区设置脚本 (`07-timezone.sh`)

该脚本用于设置和管理系统时区，支持通过 `--timezone` 参数指定时区。

**使用方法：**
```bash
# 设置时区为上海
bash scripts/01-init/07-timezone.sh --timezone Asia/Shanghai

# 查看当前时区
bash scripts/01-init/07-timezone.sh
```

**功能：**
- 自动检测当前时区设置
- 支持 `--timezone` 参数设置新时区
- 同步设置 `timedatectl` 和 `/etc/localtime`
- 验证时区是否生效

### 8.2 防火墙基础配置 (`08-firewall.sh`)

该脚本用于配置基础防火墙规则，支持 `firewalld` 和 `iptables` 两种管理方式。

**使用方法：**
```bash
# 自动检测并配置防火墙
bash scripts/01-init/08-firewall.sh

# 配置 K8s 所需端口
bash scripts/01-init/08-firewall.sh --role master
bash scripts/01-init/08-firewall.sh --role worker
```

**功能：**
- 自动检测 firewalld/iptables 并选择对应方式
- 配置 K8s 集群所需端口（6443, 2379-2380, 10250 等）
- 支持 `--role` 参数区分 Master/Worker 端口
- 验证端口开放状态

## 9. 最佳实践


1. **版本锁定**：使用 `apt-mark hold` 锁定 kubeadm/kubelet/kubectl 版本
2. **配置管理**：所有配置文件使用版本控制管理，变更需审批
3. **安全加固**：
   - 禁用密码 SSH 登录
   - 使用 RBAC 控制权限
   - 定期更新系统补丁
4. **监控先行**：先部署基础监控，再进行后续操作
5. **文档记录**：每步操作记录日志，便于问题追溯
6. **备份策略**：操作前备份关键配置文件
7. **分批执行**：多个节点时分批操作，验证后再继续
8. **测试环境验证**：生产部署前在测试环境完整验证
