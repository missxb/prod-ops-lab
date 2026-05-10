#!/bin/bash
###############################################################################
# 脚本名称: install-iscsi.sh
# 功能描述: 在Kubernetes集群所有节点安装open-iscsi依赖
# 适用系统: Ubuntu/Debian, CentOS/RHEL
# 作者: 运维平台团队
# 版本: 1.1.0
# 创建日期: 2026-05-10
# 更新日期: 2026-05-10
#
# 使用方法:
#   ./install-iscsi.sh          # 本地安装
#   在所有节点执行此脚本
#
# 说明:
#   Longhorn需要open-iscsi来创建和管理iSCSI卷
#   此脚本在所有支持的操作系统上安装open-iscsi
###############################################################################
set -euo pipefail
umask 077

# ========================= 日志函数 =========================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }

# ========================= 错误处理 =========================
cleanup() {
    local exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
        log_error "open-iscsi安装失败 (exit code: ${exit_code})"
    fi
    return $exit_code
}
trap cleanup EXIT
trap 'log_error "收到信号，正在退出..."; exit 1' SIGINT SIGTERM

# ========================= 检测操作系统 =========================
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-0}"
    elif [[ -f /etc/redhat-release ]]; then
        OS_ID="rhel"
        OS_VERSION=$(grep -oP '\d+\.\d+' /etc/redhat-release | head -1)
    else
        OS_ID="unknown"
        OS_VERSION="0"
    fi
    log_info "操作系统: ${OS_ID} ${OS_VERSION}"
}

# ========================= 安装open-iscsi =========================
install_iscsi_debian() {
    log_info "安装open-iscsi (Debian/Ubuntu)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq open-iscsi 2>/dev/null
    systemctl enable iscsid
    systemctl start iscsid
    systemctl enable iscsi
    systemctl start iscsi
    log_info "open-iscsi安装完成"
}

install_iscsi_rhel() {
    log_info "安装open-iscsi (CentOS/RHEL)..."
    yum install -y -q iscsi-initiator-utils 2>/dev/null || \
        dnf install -y -q iscsi-initiator-utils 2>/dev/null
    systemctl enable iscsid
    systemctl start iscsid
    systemctl enable iscsi
    systemctl start iscsi
    log_info "open-iscsi安装完成"
}

install_iscsi_suse() {
    log_info "安装open-iscsi (SUSE/openSUSE)..."
    zypper install -y open-iscsi 2>/dev/null
    systemctl enable iscsid
    systemctl start iscsid
    systemctl enable iscsi
    systemctl start iscsi
    log_info "open-iscsi安装完成"
}

# ========================= 验证安装 =========================
verify_install() {
    log_info "验证open-iscsi安装..."
    if command -v iscsiadm &>/dev/null; then
        log_info "iscsiadm已安装: $(iscsiadm --version 2>&1 | head -1)"
    else
        log_error "iscsiadm未安装"
        return 1
    fi

    if systemctl is-active --quiet iscsid 2>/dev/null; then
        log_info "iscsid服务运行中"
    else
        log_warn "iscsid服务未运行"
    fi
}

# ========================= 主逻辑 =========================
main() {
    log_info "开始安装open-iscsi依赖..."

    # 检测操作系统
    detect_os

    # 根据操作系统安装
    case "${OS_ID}" in
        ubuntu|debian)
            install_iscsi_debian
            ;;
        centos|rhel|rocky|almalinux|fedora)
            install_iscsi_rhel
            ;;
        sles|opensuse*)
            install_iscsi_suse
            ;;
        *)
            log_warn "未知操作系统: ${OS_ID}，尝试通用安装..."
            if command -v apt-get &>/dev/null; then
                install_iscsi_debian
            elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
                install_iscsi_rhel
            else
                log_error "无法确定包管理器，请手动安装open-iscsi"
                return 1
            fi
            ;;
    esac

    # 验证安装
    verify_install

    log_info "open-iscsi安装完成 ✓"
}

# 检查root权限
if [[ $EUID -ne 0 ]]; then
    log_error "此脚本必须以root权限运行"
    exit 1
fi

main "$@"
