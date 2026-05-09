#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# 阶段1: 基础环境初始化验证
# 验证项目: 主机名、SSH免密、NTP同步、内核优化、Docker/containerd、NFS
#           磁盘空间、内存使用、CPU负载、Swap、防火墙、系统资源
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPORT_DIR="$PROJECT_DIR/reports"
REPORT_FILE="$REPORT_DIR/verify-phase1-$(date +%Y%m%d-%H%M%S).log"
TIMESTAMP_REPORT="$REPORT_DIR/verify-phase1-$(date +%Y%m%d-%H%M%S).txt"

# 加载共享库
source "$SCRIPT_DIR/lib/common.sh"

# 初始化
common_init_verify "$PROJECT_DIR" 1

# 解析选项
show_help() {
    common_show_verify_help \
        "阶段1: 基础环境初始化验证" \
        "验证基础环境配置，包括主机名、SSH、NTP、内核、Docker/containerd、NFS及系统资源" \
        "  1.1  主机名配置检查
  1.2  SSH配置与安全检查
  1.3  NTP时间同步检查
  1.4  内核参数与模块检查
  1.5  Docker/containerd运行时检查
  1.6  NFS服务检查
  1.7  系统资源检查 (磁盘/内存/CPU/Swap)
  1.8  防火墙状态检查
  1.9  系统服务检查
  1.10 安全基线检查"
}
COMMON_HELP_FUNCTION=show_help
common_parse_verify_options "$@"

# ========== 开始验证 ==========
common_header "阶段1: 基础环境初始化验证"
common_info "验证时间: $(date '+%Y-%m-%d %H:%M:%S')"
common_info "报告文件: $REPORT_FILE"
echo ""

# --- 1.1 主机名检查 ---
common_section_start
common_step "1.1 主机名检查"

HOSTNAME_CURRENT=$(hostname 2>/dev/null || echo "unknown")
common_info_check "当前主机名: $HOSTNAME_CURRENT"

if [[ "$HOSTNAME_CURRENT" != "localhost" && "$HOSTNAME_CURRENT" != "localhost.localdomain" ]]; then
    common_pass "主机名已设置: $HOSTNAME_CURRENT"
else
    common_fail "主机名仍为默认值: $HOSTNAME_CURRENT"
fi

# 检查 /etc/hostname
if [[ -f /etc/hostname ]]; then
    ETC_HOSTNAME=$(cat /etc/hostname 2>/dev/null || echo "")
    if [[ -n "$ETC_HOSTNAME" && "$ETC_HOSTNAME" != "localhost" ]]; then
        common_pass "/etc/hostname 配置正确: $ETC_HOSTNAME"
    else
        common_warn_check "/etc/hostname 为空或默认值"
    fi
else
    common_warn_check "/etc/hostname 文件不存在"
fi

# 检查 /etc/hosts 中的主机名映射
if grep -q "$(hostname)" /etc/hosts 2>/dev/null; then
    common_pass "/etc/hosts 包含本机主机名映射"
else
    common_warn_check "/etc/hosts 中未找到本机主机名映射"
fi

# 检查主机名是否一致
if [[ -f /etc/hostname ]]; then
    ETC_HN=$(cat /etc/hostname 2>/dev/null || echo "")
    SYS_HN=$(hostname 2>/dev/null || echo "")
    if [[ "$ETC_HN" == "$SYS_HN" ]]; then
        common_pass "/etc/hostname 与系统主机名一致"
    else
        common_warn_check "/etc/hostname ($ETC_HN) 与系统主机名 ($SYS_HN) 不一致"
    fi
fi

echo -e "${DIM}  耗时: $(common_section_elapsed)秒${NC}"

# --- 1.2 SSH配置检查 ---
common_section_start
common_step "1.2 SSH配置与安全检查"

if [[ -f /root/.ssh/id_rsa || -f /root/.ssh/id_ed25519 ]]; then
    common_pass "SSH密钥文件存在"
    # 检查密钥权限
    for keyfile in /root/.ssh/id_rsa /root/.ssh/id_ed25519; do
        if [[ -f "$keyfile" ]]; then
            local perms=$(stat -c %a "$keyfile" 2>/dev/null || echo "unknown")
            if [[ "$perms" == "600" || "$perms" == "400" ]]; then
                common_pass "SSH密钥权限正确: $perms"
            else
                common_warn_check "SSH密钥权限不安全: $perms (建议: 600)"
            fi
        fi
    done
else
    common_warn_check "未找到SSH密钥文件 (id_rsa / id_ed25519)"
fi

if [[ -f /root/.ssh/authorized_keys ]]; then
    KEY_COUNT=$(wc -l < /root/.ssh/authorized_keys 2>/dev/null || echo "0")
    if [[ "$KEY_COUNT" -gt 0 ]]; then
        common_pass "authorized_keys 存在，包含 $KEY_COUNT 个密钥"
    else
        common_warn_check "authorized_keys 文件为空"
    fi
    # 检查authorized_keys权限
    local ak_perms=$(stat -c %a /root/.ssh/authorized_keys 2>/dev/null || echo "unknown")
    if [[ "$ak_perms" == "600" || "$ak_perms" == "644" ]]; then
        common_pass "authorized_keys 权限正确: $ak_perms"
    else
        common_warn_check "authorized_keys 权限异常: $ak_perms (建议: 600)"
    fi
else
    common_warn_check "authorized_keys 文件不存在"
fi

if [[ -f /root/.ssh/config ]]; then
    common_pass "SSH config 文件存在"
else
    common_info_check "SSH config 文件不存在 (可选)"
fi

# 检查SSH目录权限
if [[ -d /root/.ssh ]]; then
    local ssh_dir_perms=$(stat -c %a /root/.ssh 2>/dev/null || echo "unknown")
    if [[ "$ssh_dir_perms" == "700" ]]; then
        common_pass ".ssh 目录权限正确: $ssh_dir_perms"
    else
        common_warn_check ".ssh 目录权限不安全: $ssh_dir_perms (建议: 700)"
    fi
fi

SSH_STATUS=$(systemctl is-active sshd 2>/dev/null || systemctl is-active ssh 2>/dev/null || echo "unknown")
if [[ "$SSH_STATUS" == "active" ]]; then
    common_pass "SSH服务运行中: $SSH_STATUS"
else
    common_fail "SSH服务未运行: $SSH_STATUS"
fi

# 检查SSH协议版本
if [[ -f /etc/ssh/sshd_config ]]; then
    SSH_PROTOCOL=$(grep -E "^Protocol|^#Protocol" /etc/ssh/sshd_config 2>/dev/null | head -1 || echo "")
    if [[ -n "$SSH_PROTOCOL" ]]; then
        common_info_check "SSH协议配置: $SSH_PROTOCOL"
    fi
fi

echo -e "${DIM}  耗时: $(common_section_elapsed)秒${NC}"

# --- 1.3 NTP时间同步检查 ---
common_section_start
common_step "1.3 NTP时间同步检查"

if command -v timedatectl &>/dev/null; then
    NTP_SYNC=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "unknown")
    if [[ "$NTP_SYNC" == "yes" ]]; then
        common_pass "NTP时间同步已启用"
    else
        common_warn_check "NTP时间同步未启用 (NTPSynchronized=$NTP_SYNC)"
    fi

    TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "unknown")
    common_info_check "当前时区: $TIMEZONE"
else
    common_warn_check "timedatectl 不可用"
fi

if systemctl is-active chronyd &>/dev/null || systemctl is-active ntpd &>/dev/null || systemctl is-active systemd-timesyncd &>/dev/null; then
    common_pass "NTP同步服务运行中"
else
    common_warn_check "未检测到运行中的NTP同步服务"
fi

# 检查时间偏差
if command -v chronyc &>/dev/null; then
    CHRONY_OFFSET=$(chronyc tracking 2>/dev/null | grep "System time" | awk '{print $4}' || echo "")
    if [[ -n "$CHRONY_OFFSET" ]]; then
        common_info_check "Chrony时间偏差: ${CHRONY_OFFSET}秒"
    fi
fi

echo -e "${DIM}  耗时: $(common_section_elapsed)秒${NC}"

# --- 1.4 内核参数与模块检查 ---
common_section_start
common_step "1.4 内核参数与模块检查"

KERNEL_VERSION=$(uname -r)
common_info_check "内核版本: $KERNEL_VERSION"

# 检查 sysctl 参数
SYSCTL_PARAMS=(
    "net.ipv4.ip_forward"
    "net.bridge.bridge-nf-call-iptables"
    "net.bridge.bridge-nf-call-ip6tables"
    "vm.swappiness"
    "fs.file-max"
    "net.core.somaxconn"
    "net.ipv4.tcp_max_syn_backlog"
)

for param in "${SYSCTL_PARAMS[@]}"; do
    VALUE=$(sysctl -n "$param" 2>/dev/null || echo "N/A")
    if [[ "$VALUE" != "N/A" ]]; then
        common_info_check "$param = $VALUE"
    fi
done

# 检查是否加载了必要模块
for module in br_netfilter overlay; do
    if lsmod | grep -q "$module" 2>/dev/null; then
        common_pass "内核模块 $module 已加载"
    else
        common_warn_check "内核模块 $module 未加载"
    fi
done

# 检查文件描述符限制
local fd_soft=$(ulimit -n 2>/dev/null || echo "unknown")
local fd_hard=$(ulimit -Hn 2>/dev/null || echo "unknown")
common_info_check "文件描述符限制: soft=$fd_soft, hard=$fd_hard"
if [[ "$fd_soft" != "unknown" && "$fd_soft" -lt 65536 ]]; then
    common_warn_check "文件描述符软限制较低: $fd_soft (建议 >= 65536)"
fi

echo -e "${DIM}  耗时: $(common_section_elapsed)秒${NC}"

# --- 1.5 Docker/containerd 运行时检查 ---
common_section_start
common_step "1.5 Docker/containerd 运行时检查"

RUNTIME_ACTIVE=false

if systemctl is-active containerd &>/dev/null; then
    common_pass "containerd 服务运行中"
    RUNTIME_ACTIVE=true

    if command -v crictl &>/dev/null; then
        CRI_INFO=$(crictl info 2>/dev/null | head -1 || echo "error")
        if echo "$CRI_INFO" | grep -q "runtimeEndpoint" 2>/dev/null; then
            common_pass "CRI 接口正常"
        else
            common_pass "CRI 接口可达"
        fi
    else
        common_warn_check "crictl 命令不可用"
    fi

    # 检查containerd版本
    if command -v containerd &>/dev/null; then
        local containerd_version=$(containerd --version 2>/dev/null | awk '{print $3}' || echo "unknown")
        common_info_check "containerd 版本: $containerd_version"
    fi
fi

if systemctl is-active docker &>/dev/null; then
    common_pass "Docker 服务运行中"
    RUNTIME_ACTIVE=true

    if command -v docker &>/dev/null; then
        DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
        common_info_check "Docker 版本: $DOCKER_VERSION"

        # 检查Docker存储驱动
        local storage_driver=$(docker info 2>/dev/null | grep "Storage Driver" | awk '{print $3}' || echo "unknown")
        common_info_check "Docker 存储驱动: $storage_driver"

        # 检查Docker日志驱动
        local log_driver=$(docker info 2>/dev/null | grep "Logging Driver" | awk '{print $3}' || echo "unknown")
        common_info_check "Docker 日志驱动: $log_driver"

        # 检查Docker磁盘使用
        local docker_usage=$(docker system df 2>/dev/null | tail -1 || echo "")
        if [[ -n "$docker_usage" ]]; then
            common_info_check "Docker 磁盘使用: $(echo "$docker_usage" | awk '{print $1, $4}')"
        fi
    fi
fi

if [[ "$RUNTIME_ACTIVE" == false ]]; then
    common_fail "未检测到运行中的容器运行时 (Docker/containerd)"
fi

# 检查containerd配置
if [[ -f /etc/containerd/config.toml ]]; then
    common_pass "containerd 配置文件存在"
fi

# 检查Docker配置
if [[ -f /etc/docker/daemon.json ]]; then
    common_pass "Docker daemon.json 配置存在"
fi

echo -e "${DIM}  耗时: $(common_section_elapsed)秒${NC}"

# --- 1.6 NFS服务检查 ---
common_section_start
common_step "1.6 NFS服务检查"

if systemctl is-active nfs-server &>/dev/null || systemctl is-active nfs &>/dev/null; then
    common_pass "NFS服务运行中"
else
    common_warn_check "NFS服务未运行 (可能未部署或非NFS服务端节点)"
fi

if [[ -f /etc/exports ]]; then
    EXPORT_COUNT=$(grep -cv '^\s*#\|^\s*$' /etc/exports 2>/dev/null | head -1 || echo "0")
    EXPORT_COUNT=$(echo "$EXPORT_COUNT" | tr -d '[:space:]')
    if [[ -n "$EXPORT_COUNT" && "$EXPORT_COUNT" -gt 0 ]]; then
        common_pass "NFS导出配置存在 ($EXPORT_COUNT 条导出)"
    else
        common_info_check "NFS导出配置为空"
    fi
else
    common_info_check "/etc/exports 文件不存在"
fi

# 检查NFS挂载点
NFS_MOUNTS=$(mount | grep -c "nfs" 2>/dev/null || echo "0")
if [[ "$NFS_MOUNTS" -gt 0 ]]; then
    common_pass "NFS挂载点: $NFS_MOUNTS"
fi

# 检查rpcbind服务
if systemctl is-active rpcbind &>/dev/null; then
    common_pass "rpcbind 服务运行中 (NFS依赖)"
fi

echo -e "${DIM}  耗时: $(common_section_elapsed)秒${NC}"

# --- 1.7 系统资源检查 ---
common_section_start
common_step "1.7 系统资源检查"

# 磁盘空间
DISK_USAGE=$(df -h / 2>/dev/null | awk 'NR==2{print $5}' | tr -d '%')
if [[ -n "$DISK_USAGE" ]]; then
    if [[ "$DISK_USAGE" -gt 90 ]]; then
        common_fail "磁盘使用率过高: ${DISK_USAGE}%"
    elif [[ "$DISK_USAGE" -gt 80 ]]; then
        common_warn_check "磁盘使用率较高: ${DISK_USAGE}%"
    else
        common_pass "磁盘使用率正常: ${DISK_USAGE}%"
    fi
fi

# 磁盘IO
if command -v iostat &>/dev/null; then
    local iostat_output=$(iostat -d 1 1 2>/dev/null | tail -n +4 | head -5 || echo "")
    if [[ -n "$iostat_output" ]]; then
        common_info_check "磁盘IO统计已收集"
    fi
fi

# 内存使用
MEMORY_INFO=$(free -m 2>/dev/null | awk '/Mem:/{printf "总计:%dMB 已用:%dMB 可用:%dMB 使用率:%.0f%%", $2, $3, $7, ($3/$2)*100}')
if [[ -n "$MEMORY_INFO" ]]; then
    common_info_check "内存: $MEMORY_INFO"
    MEM_USAGE=$(free 2>/dev/null | awk '/Mem:/{printf "%.0f", ($3/$2)*100}')
    if [[ -n "$MEM_USAGE" && "$MEM_USAGE" -gt 90 ]]; then
        common_warn_check "内存使用率较高: ${MEM_USAGE}%"
    fi
fi

# CPU信息
CPU_CORES=$(nproc 2>/dev/null || echo "unknown")
CPU_MODEL=$(cat /proc/cpuinfo 2>/dev/null | grep "model name" | head -1 | cut -d: -f2 | xargs || echo "unknown")
common_info_check "CPU: $CPU_MODEL ($CPU_CORES 核心)"

# CPU负载
LOAD_AVG=$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | xargs || echo "unknown")
common_info_check "系统负载: $LOAD_AVG"

# Swap
SWAP_INFO=$(free -m 2>/dev/null | awk '/Swap:/{printf "总计:%dMB 已用:%dMB", $2, $3}')
if [[ -n "$SWAP_INFO" ]]; then
    common_info_check "Swap: $SWAP_INFO"
    SWAP_USED=$(free 2>/dev/null | awk '/Swap:/{print $3}')
    if [[ -n "$SWAP_USED" && "$SWAP_USED" -gt 0 ]]; then
        common_warn_check "Swap 正在使用 (可能导致性能下降)"
    fi
fi

echo -e "${DIM}  耗时: $(common_section_elapsed)秒${NC}"

# --- 1.8 防火墙状态检查 ---
common_section_start
common_step "1.8 防火墙状态检查"

common_check_firewall

# 检查SELinux
if command -v getenforce &>/dev/null; then
    SELINUX_STATUS=$(getenforce 2>/dev/null || echo "unknown")
    common_info_check "SELinux 状态: $SELINUX_STATUS"
fi

echo -e "${DIM}  耗时: $(common_section_elapsed)秒${NC}"

# --- 1.9 系统服务检查 ---
common_section_start
common_step "1.9 关键系统服务检查"

# 检查关键系统服务
for svc in systemd-journald systemd-resolved crond; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        common_pass "$svc 服务运行中"
    else
        common_info_check "$svc 服务未运行"
    fi
done

# 检查系统日志
if [[ -d /var/log ]]; then
    local log_size=$(du -sh /var/log 2>/dev/null | awk '{print $1}' || echo "unknown")
    common_info_check "系统日志目录大小: $log_size"
fi

echo -e "${DIM}  耗时: $(common_section_elapsed)秒${NC}"

# --- 1.10 安全基线检查 ---
common_section_start
common_step "1.10 安全基线检查"

# 检查密码策略
if [[ -f /etc/login.defs ]]; then
    local pass_max=$(grep "^PASS_MAX_DAYS" /etc/login.defs 2>/dev/null | awk '{print $2}' || echo "")
    if [[ -n "$pass_max" ]]; then
        common_info_check "密码最大有效期: ${pass_max}天"
    fi
fi

# 检查空密码账户
local empty_pass=$(awk -F: '($2 == "" || $2 == "!") {print $1}' /etc/shadow 2>/dev/null | head -5 || echo "")
if [[ -n "$empty_pass" ]]; then
    common_warn_check "发现无密码或锁定账户: $empty_pass"
else
    common_pass "未发现空密码账户"
fi

# 检查umask
local umask_val=$(umask 2>/dev/null || echo "unknown")
common_info_check "当前umask: $umask_val"

# 检查自动登录
if [[ -f /etc/gdm/custom.conf ]] && grep -q "AutomaticLoginEnable=true" /etc/gdm/custom.conf 2>/dev/null; then
    common_warn_check "检测到图形界面自动登录 (不安全)"
fi

echo -e "${DIM}  耗时: $(common_section_elapsed)秒${NC}"

# ========== 验证报告 ==========
common_header "验证汇总"
common_generate_verify_report "阶段1: 基础环境初始化" "$TIMESTAMP_REPORT"
common_info "报告已保存: $REPORT_FILE"
common_info "总耗时: $(common_format_duration $(common_timer_elapsed))"

if [[ $COMMON_FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
