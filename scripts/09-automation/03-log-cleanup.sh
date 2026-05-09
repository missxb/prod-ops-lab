#!/usr/bin/env bash
###############################################################################
# 03-log-cleanup.sh - 日志清理与轮转脚本
#
# 功能:
#   - 系统日志清理 (journald / syslog / audit)
#   - 应用日志轮转
#   - 临时文件清理
#   - Docker 日志清理
#   - K8s Pod 日志清理
#   - 保留策略: 可配置天数
# 用法: ./03-log-cleanup.sh [options]
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../" && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs"
REPORT_DIR="${PROJECT_ROOT}/reports"
DATE=$(date +"%Y%m%d_%H%M%S")
REPORT_FILE="${REPORT_DIR}/cleanup-report-${DATE}.txt"

# 保留策略（天）
JOURNAL_RETENTION_DAYS=7
APP_LOG_RETENTION_DAYS=15
TMP_RETENTION_DAYS=3
DOCKER_LOG_RETENTION_DAYS=7

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

FREED_SPACE=0

log_info()    { echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }

report() {
    local msg="$*"
    echo "${msg}" | tee -a "${REPORT_FILE}"
}

# 获取目录大小（MB）
get_dir_size() {
    local dir="$1"
    if [[ -d "${dir}" ]]; then
        du -sm "${dir}" 2>/dev/null | awk '{print $1}' || echo 0
    else
        echo 0
    fi
}

# ========================= Journald 清理 =========================
clean_journald() {
    report ""
    report "==================== Journald 日志清理 ===================="
    
    if ! systemctl is-active systemd-journald &>/dev/null; then
        log_warn "systemd-journald 未运行"
        return
    fi
    
    local before_size
    before_size=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+[MG]' || echo "0M")
    report "清理前大小: ${before_size}"
    
    # 清理超过保留天数的日志
    journalctl --vacuum-time="${JOURNAL_RETENTION_DAYS}d" &>/dev/null || true
    
    # 限制 journald 大小
    mkdir -p /etc/systemd/journald.conf.d/
    cat > /etc/systemd/journald.conf.d/size-limit.conf 2>/dev/null << 'EOF' || true
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=50M
MaxRetentionSec=7day
EOF
    systemctl restart systemd-journald 2>/dev/null || true
    
    local after_size
    after_size=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+[MG]' || echo "0M")
    report "清理后大小: ${after_size}"
    log_success "Journald 清理完成"
}

# ========================= 系统日志清理 =========================
clean_syslog() {
    report ""
    report "==================== 系统日志清理 ===================="
    
    local log_dirs=(
        "/var/log"
        "/var/log/audit"
    )
    
    for dir in "${log_dirs[@]}"; do
        if [[ ! -d "${dir}" ]]; then
            continue
        fi
        
        local before
        before=$(get_dir_size "${dir}")
        
        # 清理旧日志文件
        find "${dir}" -name "*.log.*" -mtime +"${APP_LOG_RETENTION_DAYS}" -delete 2>/dev/null || true
        find "${dir}" -name "*.gz" -mtime +"${APP_LOG_RETENTION_DAYS}" -delete 2>/dev/null || true
        find "${dir}" -name "*.old" -mtime +1 -delete 2>/dev/null || true
        find "${dir}" -name "*.1" -mtime +1 -delete 2>/dev/null || true
        
        # 压缩超过3天的日志
        find "${dir}" -name "*.log" -mtime +3 -not -name "*.gz" -exec gzip -q {} \; 2>/dev/null || true
        
        # 清理空文件
        find "${dir}" -name "*.log" -empty -delete 2>/dev/null || true
        
        local after
        after=$(get_dir_size "${dir}")
        local freed=$(( before - after ))
        [[ ${freed} -gt 0 ]] && FREED_SPACE=$(( FREED_SPACE + freed ))
        
        report "  ${dir}: ${before}MB -> ${after}MB (释放: ${freed}MB)"
    done
    
    # 使用 logrotate 强制轮转
    if command -v logrotate &>/dev/null; then
        logrotate -f /etc/logrotate.conf 2>/dev/null || true
        report "  logrotate 强制轮转完成"
    fi
    
    log_success "系统日志清理完成"
}

# ========================= 应用日志清理 =========================
clean_app_logs() {
    report ""
    report "==================== 应用日志清理 ===================="
    
    local app_log_dirs=(
        "${LOG_DIR}"
        "${PROJECT_ROOT}/logs"
        "/opt/*/logs"
        "/var/log/nginx"
        "/var/log/haproxy"
        "/var/log/containers"
        "/var/log/pods"
        "/data/*/logs"
    )
    
    for pattern in "${app_log_dirs[@]}"; do
        for dir in ${pattern}; do
            [[ ! -d "${dir}" ]] && continue
            
            local before
            before=$(get_dir_size "${dir}")
            
            # 删除超过保留天数的日志
            find "${dir}" -name "*.log" -mtime +"${APP_LOG_RETENTION_DAYS}" -delete 2>/dev/null || true
            find "${dir}" -name "*.log.gz" -mtime +"${APP_LOG_RETENTION_DAYS}" -delete 2>/dev/null || true
            find "${dir}" -type d -name "archive" -mtime +"${APP_LOG_RETENTION_DAYS}" -exec rm -rf {} \; 2>/dev/null || true
            
            # 清理大文件（超过100MB的旧日志）
            find "${dir}" -name "*.log" -size +100M -mtime +1 -exec truncate -s 0 {} \; 2>/dev/null || true
            
            local after
            after=$(get_dir_size "${dir}")
            local freed=$(( before - after ))
            [[ ${freed} -gt 0 ]] && FREED_SPACE=$(( FREED_SPACE + freed ))
            
            [[ ${freed} -gt 0 ]] && report "  ${dir}: ${before}MB -> ${after}MB (释放: ${freed}MB)"
        done
    done
    
    log_success "应用日志清理完成"
}

# ========================= Docker 日志清理 =========================
clean_docker() {
    report ""
    report "==================== Docker 日志清理 ===================="
    
    if ! command -v docker &>/dev/null; then
        log_warn "Docker 未安装，跳过"
        return
    fi
    
    # 清理已停止的容器
    local stopped
    stopped=$(docker ps -a -f "status=exited" -q 2>/dev/null | wc -l || echo 0)
    if [[ "${stopped}" -gt 0 ]]; then
        docker container prune -f 2>/dev/null || true
        report "  清理已停止容器: ${stopped} 个"
    fi
    
    # 清理悬空镜像
    local dangling
    dangling=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l || echo 0)
    if [[ "${dangling}" -gt 0 ]]; then
        docker image prune -f 2>/dev/null || true
        report "  清理悬空镜像: ${dangling} 个"
    fi
    
    # 清理未使用的网络
    docker network prune -f 2>/dev/null || true
    
    # 清理未使用的卷
    docker volume prune -f 2>/dev/null || true
    
    # 清理 Docker 日志
    local docker_log_dir="/var/lib/docker/containers"
    if [[ -d "${docker_log_dir}" ]]; then
        find "${docker_log_dir}" -name "*.log" -size +50M -exec truncate -s 0 {} \; 2>/dev/null || true
        report "  Docker 容器日志已截断"
    fi
    
    # Docker 系统清理
    local docker_before
    docker_before=$(docker system df 2>/dev/null | grep "Images" | awk '{print $4}' || echo "0")
    docker system prune -af --volumes 2>/dev/null || true
    report "  Docker 系统清理完成"
    
    log_success "Docker 清理完成"
}

# ========================= K8s Pod 日志清理 =========================
clean_kubernetes() {
    report ""
    report "==================== Kubernetes 日志清理 ===================="
    
    if ! command -v kubectl &>/dev/null; then
        log_warn "kubectl 未安装，跳过"
        return
    fi
    
    if ! kubectl cluster-info &>/dev/null; then
        log_warn "K8s API 不可达，跳过"
        return
    fi
    
    # 清理已完成/失败的 Pod
    local failed_pods
    failed_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -iE "Error|Completed|Failed|Succeeded" | wc -l || echo 0)
    if [[ "${failed_pods}" -gt 0 ]]; then
        kubectl get pods --all-namespaces --no-headers 2>/dev/null | \
            grep -iE "Error|Completed|Failed|Succeeded" | \
            awk '{print $1, $2}' | \
            while read ns pod; do
                kubectl delete pod "${pod}" -n "${ns}" --grace-period=0 --force 2>/dev/null || true
            done
        report "  清理异常 Pod: ${failed_pods} 个"
    fi
    
    # 清理 Evicted Pods
    local evicted
    evicted=$(kubectl get pods --all-namespaces --field-selector=status.phase=Failed 2>/dev/null | grep -c "Evicted" || echo 0)
    if [[ "${evicted}" -gt 0 ]]; then
        kubectl get pods --all-namespaces --field-selector=status.phase=Failed --no-headers 2>/dev/null | \
            grep "Evicted" | \
            awk '{print $1, $2}' | \
            while read ns pod; do
                kubectl delete pod "${pod}" -n "${ns}" 2>/dev/null || true
            done
        report "  清理 Evicted Pod: ${evicted} 个"
    fi
    
    # 清理已完成的 Job
    kubectl delete jobs --all --field-selector status.successful=1 -A 2>/dev/null || true
    
    # 清理旧的 ReplicaSets
    kubectl delete replicasets --all -n default 2>/dev/null || true
    
    log_success "Kubernetes 日志清理完成"
}

# ========================= 临时文件清理 =========================
clean_tmp() {
    report ""
    report "==================== 临时文件清理 ===================="
    
    local tmp_dirs=("/tmp" "/var/tmp" "${HOME}/.cache")
    
    for dir in "${tmp_dirs[@]}"; do
        [[ ! -d "${dir}" ]] && continue
        
        local before
        before=$(get_dir_size "${dir}")
        
        # 清理旧临时文件（跳过关键文件）
        find "${dir}" -maxdepth 2 -type f \
            -mtime +"${TMP_RETENTION_DAYS}" \
            -not -name ".X*" \
            -not -name "ssh-*" \
            -not -name "*.lock" \
            -delete 2>/dev/null || true
        
        # 清理旧目录
        find "${dir}" -maxdepth 2 -type d \
            -mtime +"${TMP_RETENTION_DAYS}" \
            -not -name ".*" \
            -exec rm -rf {} \; 2>/dev/null || true
        
        local after
        after=$(get_dir_size "${dir}")
        local freed=$(( before - after ))
        [[ ${freed} -gt 0 ]] && FREED_SPACE=$(( FREED_SPACE + freed ))
        
        [[ ${freed} -gt 0 ]] && report "  ${dir}: ${before}MB -> ${after}MB (释放: ${freed}MB)"
    done
    
    # 清理 pip 缓存
    if command -v pip3 &>/dev/null; then
        pip3 cache purge 2>/dev/null || true
    fi
    
    # 清理 yum 缓存
    if command -v yum &>/dev/null; then
        yum clean all 2>/dev/null || true
    fi
    
    log_success "临时文件清理完成"
}

# ========================= 生成汇总 =========================
generate_summary() {
    report ""
    report "================================================================"
    report "  日志清理汇总报告"
    report "  时间: $(date)"
    report "  主机: $(hostname)"
    report "================================================================"
    report ""
    report "  释放总空间: ${FREED_SPACE} MB"
    report "  报告文件: ${REPORT_FILE}"
    report "================================================================"
    
    echo ""
    log_success "日志清理完成，共释放 ${FREED_SPACE} MB 空间"
}

# ========================= 主函数 =========================
main() {
    mkdir -p "${REPORT_DIR}"
    : > "${REPORT_FILE}"
    
    echo "================================================================"
    echo "  企业云原生平台 - 日志清理"
    echo "  时间: $(date)"
    echo "  主机: $(hostname)"
    echo "================================================================"
    
    report "================================================================"
    report "  日志清理报告"
    report "  时间: $(date)"
    report "  主机: $(hostname)"
    report "================================================================"
    
    clean_journald
    clean_syslog
    clean_app_logs
    clean_docker
    clean_kubernetes
    clean_tmp
    
    generate_summary
}

main "$@"
