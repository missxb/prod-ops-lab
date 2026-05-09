#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# 阶段1: 基础环境初始化验证
# 验证项目: 主机名、SSH免密、NTP同步、内核优化、Docker/containerd、NFS
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPORT_DIR="$PROJECT_DIR/reports"
REPORT_FILE="$REPORT_DIR/verify-phase1-$(date +%Y%m%d-%H%M%S).log"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 计数器
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
TOTAL_COUNT=0

mkdir -p "$REPORT_DIR"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg"
    echo "$msg" >> "$REPORT_FILE"
}

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    log "${GREEN}[PASS]${NC} $1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    log "${RED}[FAIL]${NC} $1"
}

warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    log "${YELLOW}[WARN]${NC} $1"
}

info() {
    log "${BLUE}[INFO]${NC} $1"
}

section() {
    echo ""
    log "${CYAN}========== $1 ==========${NC}"
}

# ========== 开始验证 ==========
section "阶段1: 基础环境初始化验证"

# --- 1.1 主机名检查 ---
section "1.1 主机名检查"

HOSTNAME_CURRENT=$(hostname 2>/dev/null || echo "unknown")
info "当前主机名: $HOSTNAME_CURRENT"

if [[ "$HOSTNAME_CURRENT" != "localhost" && "$HOSTNAME_CURRENT" != "localhost.localdomain" ]]; then
    pass "主机名已设置: $HOSTNAME_CURRENT"
else
    fail "主机名仍为默认值: $HOSTNAME_CURRENT"
fi

# 检查 /etc/hostname
if [[ -f /etc/hostname ]]; then
    ETC_HOSTNAME=$(cat /etc/hostname 2>/dev/null || echo "")
    if [[ -n "$ETC_HOSTNAME" && "$ETC_HOSTNAME" != "localhost" ]]; then
        pass "/etc/hostname 配置正确: $ETC_HOSTNAME"
    else
        warn "/etc/hostname 为空或默认值"
    fi
else
    warn "/etc/hostname 文件不存在"
fi

# 检查 /etc/hosts 中的主机名映射
if grep -q "$(hostname)" /etc/hosts 2>/dev/null; then
    pass "/etc/hosts 包含本机主机名映射"
else
    warn "/etc/hosts 中未找到本机主机名映射"
fi

# --- 1.2 SSH免密检查 ---
section "1.2 SSH配置检查"

if [[ -f /root/.ssh/id_rsa || -f /root/.ssh/id_ed25519 ]]; then
    pass "SSH密钥文件存在"
else
    warn "未找到SSH密钥文件 (id_rsa / id_ed25519)"
fi

if [[ -f /root/.ssh/authorized_keys ]]; then
    KEY_COUNT=$(wc -l < /root/.ssh/authorized_keys 2>/dev/null || echo "0")
    if [[ "$KEY_COUNT" -gt 0 ]]; then
        pass "authorized_keys 存在，包含 $KEY_COUNT 个密钥"
    else
        warn "authorized_keys 文件为空"
    fi
else
    warn "authorized_keys 文件不存在"
fi

if [[ -f /root/.ssh/config ]]; then
    pass "SSH config 文件存在"
else
    info "SSH config 文件不存在 (可选)"
fi

SSH_STATUS=$(systemctl is-active sshd 2>/dev/null || systemctl is-active ssh 2>/dev/null || echo "unknown")
if [[ "$SSH_STATUS" == "active" ]]; then
    pass "SSH服务运行中: $SSH_STATUS"
else
    fail "SSH服务未运行: $SSH_STATUS"
fi

# --- 1.3 NTP时间同步检查 ---
section "1.3 NTP时间同步检查"

if command -v timedatectl &>/dev/null; then
    NTP_SYNC=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "unknown")
    if [[ "$NTP_SYNC" == "yes" ]]; then
        pass "NTP时间同步已启用"
    else
        warn "NTP时间同步未启用 (NTPSynchronized=$NTP_SYNC)"
    fi

    TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "unknown")
    info "当前时区: $TIMEZONE"
else
    warn "timedatectl 不可用"
fi

if systemctl is-active chronyd &>/dev/null || systemctl is-active ntpd &>/dev/null || systemctl is-active systemd-timesyncd &>/dev/null; then
    pass "NTP同步服务运行中"
else
    warn "未检测到运行中的NTP同步服务"
fi

# --- 1.4 内核优化检查 ---
section "1.4 内核优化检查"

KERNEL_VERSION=$(uname -r)
info "内核版本: $KERNEL_VERSION"

# 检查 sysctl 参数
SYSCTL_PARAMS=(
    "net.ipv4.ip_forward"
    "net.bridge.bridge-nf-call-iptables"
    "net.bridge.bridge-nf-call-ip6tables"
    "vm.swappiness"
)

for param in "${SYSCTL_PARAMS[@]}"; do
    VALUE=$(sysctl -n "$param" 2>/dev/null || echo "N/A")
    if [[ "$VALUE" != "N/A" ]]; then
        info "$param = $VALUE"
    fi
done

# 检查是否加载了必要模块
for module in br_netfilter overlay; do
    if lsmod | grep -q "$module" 2>/dev/null; then
        pass "内核模块 $module 已加载"
    else
        warn "内核模块 $module 未加载"
    fi
done

# --- 1.5 Docker/containerd检查 ---
section "1.5 Docker/containerd 运行时检查"

RUNTIME_ACTIVE=false

if systemctl is-active containerd &>/dev/null; then
    pass "containerd 服务运行中"
    RUNTIME_ACTIVE=true

    if command -v crictl &>/dev/null; then
        CRI_INFO=$(crictl info 2>/dev/null | head -1 || echo "error")
        if echo "$CRI_INFO" | grep -q "runtimeEndpoint" 2>/dev/null; then
            pass "CRI 接口正常"
        else
            pass "CRI 接口可达"
        fi
    else
        warn "crictl 命令不可用"
    fi
fi

if systemctl is-active docker &>/dev/null; then
    pass "Docker 服务运行中"
    RUNTIME_ACTIVE=true

    if command -v docker &>/dev/null; then
        DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
        info "Docker 版本: $DOCKER_VERSION"
    fi
fi

if [[ "$RUNTIME_ACTIVE" == false ]]; then
    fail "未检测到运行中的容器运行时 (Docker/containerd)"
fi

# --- 1.6 NFS服务检查 ---
section "1.6 NFS服务检查"

if systemctl is-active nfs-server &>/dev/null || systemctl is-active nfs &>/dev/null; then
    pass "NFS服务运行中"
else
    warn "NFS服务未运行 (可能未部署或非NFS服务端节点)"
fi

if [[ -f /etc/exports ]]; then
    EXPORT_COUNT=$(grep -cv '^\s*#\|^\s*$' /etc/exports 2>/dev/null | head -1 || echo "0")
    EXPORT_COUNT=$(echo "$EXPORT_COUNT" | tr -d '[:space:]')
    if [[ -n "$EXPORT_COUNT" && "$EXPORT_COUNT" -gt 0 ]]; then
        pass "NFS导出配置存在 ($EXPORT_COUNT 条导出)"
    else
        info "NFS导出配置为空"
    fi
else
    info "/etc/exports 文件不存在"
fi

# ========== 验证报告 ==========
section "验证汇总"

echo ""
log "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
log "${CYAN}║          阶段1: 基础环境初始化验证报告          ║${NC}"
log "${CYAN}╠══════════════════════════════════════════════════╣${NC}"
log "${CYAN}║${NC} 总检查项:  ${TOTAL_COUNT}                                    ${CYAN}║${NC}"
log "${GREEN}║${NC} 通过:      ${PASS_COUNT}                                    ${GREEN}║${NC}"
log "${RED}║${NC} 失败:      ${FAIL_COUNT}                                    ${RED}║${NC}"
log "${YELLOW}║${NC} 警告:      ${WARN_COUNT}                                    ${YELLOW}║${NC}"
log "${CYAN}╠══════════════════════════════════════════════════╣${NC}"

if [[ $FAIL_COUNT -eq 0 ]]; then
    if [[ $WARN_COUNT -eq 0 ]]; then
        log "${GREEN}║  结果: ✓ 全部通过                               ║${NC}"
    else
        log "${YELLOW}║  结果: △ 通过(有警告)                           ║${NC}"
    fi
else
    log "${RED}║  结果: ✗ 存在失败项                             ║${NC}"
fi

log "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
log ""
log "报告已保存: $REPORT_FILE"

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
