#!/bin/bash
###############################################################################
# 脚本名称: 05-docker.sh
# 功能描述: 安装Docker和containerd，配置Docker Daemon
# 适用系统: CentOS 7/8, Rocky Linux 8/9
# 依赖条件: root权限, 网络连接
# 作者: 运维平台团队
# 版本: 1.0.0
# 创建日期: 2026-05-09
###############################################################################
set -euo pipefail
umask 077

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/01-init"
LOG_FILE="${LOG_DIR}/05-docker_$(date +%Y%m%d_%H%M%S).log"
LOCK_FILE="/var/lock/05-docker.lock"
DOCKER_VERSION="${DOCKER_VERSION:-24.0}"
DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-/var/lib/docker}"
DOCKER_CONFIG="/etc/docker/daemon.json"
DOCKER_SERVICE="/etc/systemd/system/docker.service.d"

# ========================= 颜色定义 =========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ========================= 日志函数 =========================
log_info()    { echo -e "${GREEN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_step()    { echo -e "${CYAN}[STEP]${NC}  $(date '+%Y-%m-%d %H:%M:%S') === $* ===" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }

# ========================= 错误处理 =========================
cleanup() {
    local exit_code=$?
    rm -f "$LOCK_FILE"
    if [[ $exit_code -ne 0 ]]; then
        log_error "脚本执行失败，退出码: $exit_code"
    fi
    return $exit_code
}
trap cleanup EXIT
trap 'log_error "收到信号，正在退出..."; exit 1' SIGINT SIGTERM

# ========================= 工具函数 =========================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以root权限运行"
        exit 1
    fi
}

check_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log_error "另一个实例正在运行 (PID: $pid)"
            exit 1
        fi
        log_warn "发现残留锁文件，已清理"
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID}"
        OS_NAME="${PRETTY_NAME}"
    fi
    log_info "检测到系统: ${OS_NAME:-Unknown}"
}

# ========================= Docker安装函数 =========================
remove_old_docker() {
    log_step "清理旧版本Docker"

    local old_packages=(
        docker docker-client docker-client-latest
        docker-common docker-latest docker-latest-logrotate
        docker-logrotate docker-engine docker-ce docker-ce-cli
        containerd.io
    )

    local removed=false
    for pkg in "${old_packages[@]}"; do
        if rpm -q "$pkg" >/dev/null 2>&1; then
            yum remove -y "$pkg" 2>>"$LOG_FILE" || true
            removed=true
            log_info "已移除旧包: $pkg"
        fi
    done

    if [[ "$removed" == "true" ]]; then
        log_success "旧版本Docker已清理"
    else
        log_info "未发现旧版本Docker"
    fi
}

install_docker() {
    log_step "安装Docker CE"

    # 检查Docker是否已安装
    if command -v docker >/dev/null 2>&1; then
        local installed_version
        installed_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
        log_info "Docker已安装，版本: $installed_version"

        # 检查是否满足最低版本要求
        local major_version
        major_version=$(echo "$installed_version" | cut -d. -f1)
        if [[ "$major_version" -ge 20 ]]; then
            log_success "Docker版本满足要求，跳过安装"
            return 0
        else
            log_warn "Docker版本过低，将升级"
        fi
    fi

    # 安装依赖
    case "${OS_ID}" in
        centos|rhel|rocky|almalinux)
            local os_version="${OS_VERSION%%.*}"
            yum install -y yum-utils device-mapper-persistent-data lvm2 2>>"$LOG_FILE"

            # 添加Docker官方源
            if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
                yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>>"$LOG_FILE"

                # 替换为阿里云镜像源（加速）
                sed -i 's|https://download.docker.com|https://mirrors.aliyun.com/docker-ce|' /etc/yum.repos.d/docker-ce.repo
                log_info "已配置Docker阿里云镜像源"
            fi

            yum makecache fast 2>>"$LOG_FILE"
            yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>>"$LOG_FILE"
            ;;
        *)
            log_error "不支持的操作系统: ${OS_ID}"
            return 1
            ;;
    esac

    if command -v docker >/dev/null 2>&1; then
        log_success "Docker安装成功"
    else
        log_error "Docker安装失败"
        return 1
    fi
}

configure_docker() {
    log_step "配置Docker Daemon"

    # 创建配置目录
    mkdir -p /etc/docker
    mkdir -p "$DOCKER_DATA_ROOT"
    mkdir -p /etc/systemd/system/docker.service.d

    # 备份原配置
    local backup="${DOCKER_CONFIG}.bak.$(date +%Y%m%d)"
    if [[ -f "$DOCKER_CONFIG" && ! -f "$backup" ]]; then
        cp "$DOCKER_CONFIG" "$backup"
        log_info "已备份Docker配置: $backup"
    fi

    # 获取本机IP用于集群通信
    local local_ip
    local_ip=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    [[ -z "$local_ip" ]] && local_ip="0.0.0.0"

    # 生成daemon.json配置
    cat > "$DOCKER_CONFIG" << DOCKER_EOF
{
    "data-root": "${DOCKER_DATA_ROOT}",
    "storage-driver": "overlay2",
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m",
        "max-file": "3"
    },
    "registry-mirrors": [
        "https://mirror.ccs.tencentyun.com",
        "https://registry.docker-cn.com",
        "https://hub-mirror.c.163.com"
    ],
    "insecure-registries": [
        "harbor.internal:443",
        "harbor.internal:80"
    ],
    "exec-opts": ["native.cgroupdriver=systemd"],
    "default-address-pools": [
        {"base": "172.17.0.0/12", "size": 24},
        {"base": "192.168.0.0/16", "size": 24}
    ],
    "max-concurrent-downloads": 10,
    "max-concurrent-uploads": 5,
    "live-restore": true,
    "oom-score-adjust": -500,
    "default-ulimits": {
        "nofile": {
            "Name": "nofile",
            "Hard": 1048576,
            "Soft": 1048576
        },
        "nproc": {
            "Name": "nproc",
            "Hard": 131072,
            "Soft": 131072
        }
    }
}
DOCKER_EOF

    log_success "Docker Daemon配置已更新"
}

configure_containerd() {
    log_step "配置containerd"

    local containerd_config="/etc/containerd/config.toml"
    local backup="${containerd_config}.bak.$(date +%Y%m%d)"

    if [[ -f "$containerd_config" && ! -f "$backup" ]]; then
        cp "$containerd_config" "$backup"
        log_info "已备份containerd配置: $backup"
    fi

    # 生成默认配置（如果不存在或需要重新生成）
    if [[ ! -f "$containerd_config" ]] || ! grep -q "SystemdCgroup" "$containerd_config"; then
        # containerd默认配置生成
        mkdir -p /etc/containerd
        containerd config default > "$containerd_config" 2>/dev/null || true

        # 修改SystemdCgroup为true（Kubernetes需要）
        if grep -q 'SystemdCgroup = false' "$containerd_config"; then
            sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "$containerd_config"
            log_info "已设置containerd SystemdCgroup = true"
        fi

        # 配置sandbox镜像
        if ! grep -q "sandbox_image" "$containerd_config"; then
            sed -i '/\[plugins.*registry.*mirrors\]/a\        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]\n          endpoint = ["https://mirror.ccs.tencentyun.com", "https://registry.docker-cn.com"]' "$containerd_config" 2>/dev/null || true
        fi
    fi

    log_success "containerd配置已更新"
}

start_docker() {
    log_step "启动Docker服务"

    systemctl daemon-reload
    systemctl enable docker containerd 2>>"$LOG_FILE"
    systemctl restart containerd 2>>"$LOG_FILE"
    systemctl restart docker 2>>"$LOG_FILE"

    # 等待Docker启动
    local retries=30
    while [[ $retries -gt 0 ]]; do
        if docker info >/dev/null 2>&1; then
            break
        fi
        retries=$((retries - 1))
        sleep 2
    done

    if docker info >/dev/null 2>&1; then
        log_success "Docker服务启动成功"
    else
        log_error "Docker服务启动失败"
        systemctl status docker --no-pager 2>&1 | tee -a "$LOG_FILE"
        return 1
    fi
}

verify_docker() {
    log_step "验证Docker安装"

    # 显示版本信息
    log_info "Docker版本:"
    docker version 2>&1 | tee -a "$LOG_FILE" || true

    log_info "Docker信息摘要:"
    docker info 2>&1 | grep -E "(Server Version|Storage Driver|Logging Driver|Cgroup|Operating System|Kernel Version)" | tee -a "$LOG_FILE" || true

    # 运行测试容器
    log_info "运行Docker hello-world测试..."
    if docker run --rm hello-world >/dev/null 2>&1; then
        log_success "Docker运行测试通过"
    else
        log_warn "Docker运行测试失败，可能是网络问题"
    fi

    # 清理测试容器
    docker rmi hello-world >/dev/null 2>&1 || true

    # containerd状态
    if systemctl is-active containerd >/dev/null 2>&1; then
        log_success "containerd服务运行正常"
    else
        log_warn "containerd服务未运行"
    fi
}

# ========================= 主逻辑 =========================
main() {
    mkdir -p "$LOG_DIR"
    check_root
    check_lock
    detect_os

    log_step "阶段1-任务5: Docker/containerd安装"

    # 清理旧版本
    remove_old_docker

    # 安装Docker
    install_docker

    # 配置Docker
    configure_docker

    # 配置containerd
    configure_containerd

    # 启动服务
    start_docker

    # 验证安装
    verify_docker

    log_success "阶段1-任务5完成: Docker/containerd安装成功"
}

main "$@"
