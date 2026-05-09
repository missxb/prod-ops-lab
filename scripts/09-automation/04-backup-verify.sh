#!/usr/bin/env bash
###############################################################################
# 04-backup-verify.sh - 备份与完整性校验脚本
#
# 功能:
#   - etcd 数据备份
#   - K8s 资源导出
#   - 配置文件备份
#   - 数据库备份 (MySQL/PostgreSQL/Redis)
#   - 备份完整性校验 (SHA256)
#   - 备份过期清理
# 用法: ./04-backup-verify.sh [options]
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../" && pwd)"
BACKUP_DIR="${PROJECT_ROOT}/backups"
REPORT_DIR="${PROJECT_ROOT}/reports"
LOG_DIR="${PROJECT_ROOT}/logs/backup"
DATE=$(date +"%Y%m%d_%H%M%S")
REPORT_FILE="${REPORT_DIR}/backup-report-${DATE}.txt"
CHECKSUM_FILE="${BACKUP_DIR}/checksums-${DATE}.sha256"

# 备份保留策略
BACKUP_RETENTION_DAYS=30

# 备份目标目录
BACKUP_ETCD="${BACKUP_DIR}/etcd"
BACKUP_K8S="${BACKUP_DIR}/kubernetes"
BACKUP_CONFIG="${BACKUP_DIR}/config"
BACKUP_DB="${BACKUP_DIR}/database"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TOTAL_BACKUPS=0
PASSED_BACKUPS=0
FAILED_BACKUPS=0

log_info()    { echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }

report() {
    echo "$*" | tee -a "${REPORT_FILE}"
}

# ========================= 初始化 =========================
init() {
    mkdir -p "${BACKUP_ETCD}" "${BACKUP_K8S}" "${BACKUP_CONFIG}" "${BACKUP_DB}"
    mkdir -p "${REPORT_DIR}" "${LOG_DIR}"
    : > "${REPORT_FILE}"
    : > "${CHECKSUM_FILE}"
}

# 计算 SHA256
compute_checksum() {
    local file="$1"
    if [[ -f "${file}" ]]; then
        sha256sum "${file}" >> "${CHECKSUM_FILE}"
    fi
}

# 校验 SHA256
verify_checksum() {
    local file="$1"
    local expected_hash="$2"
    if [[ -f "${file}" ]]; then
        local actual_hash
        actual_hash=$(sha256sum "${file}" | awk '{print $1}')
        if [[ "${actual_hash}" == "${expected_hash}" ]]; then
            return 0
        fi
    fi
    return 1
}

# ========================= etcd 备份 =========================
backup_etcd() {
    report ""
    report "==================== etcd 数据备份 ===================="
    ((TOTAL_BACKUPS++))
    
    local backup_file="${BACKUP_ETCD}/etcd-snapshot-${DATE}.db"
    local endpoint="https://127.0.0.1:2379"
    local cert="/etc/kubernetes/pki/etcd/server.crt"
    local key="/etc/kubernetes/pki/etcd/server.key"
    local ca="/etc/kubernetes/pki/etcd/ca.crt"
    
    # 检查 etcd 是否可用
    if ! systemctl is-active etcd &>/dev/null && \
       ! pgrep -x etcd &>/dev/null; then
        log_warn "etcd 未运行，尝试 K8s 内置 etcd..."
    fi
    
    # 检查证书
    if [[ ! -f "${cert}" ]]; then
        cert="/etc/etcd/ssl/server.crt"
        key="/etc/etcd/ssl/server.key"
        ca="/etc/etcd/ssl/ca.crt"
    fi
    
    local etcdctl_cmd="etcdctl"
    if command -v etcdctl &>/dev/null; then
        etcdctl_cmd="etcdctl"
    else
        log_warn "etcdctl 未安装，跳过 etcd 备份"
        report "[SKIP] etcdctl 未安装"
        return 0
    fi
    
    if [[ -f "${cert}" && -f "${key}" && -f "${ca}" ]]; then
        # TLS 模式
        ETCDCTL_API=3 ${etcdctl_cmd} snapshot save "${backup_file}" \
            --endpoints="${endpoint}" \
            --cacert="${ca}" \
            --cert="${cert}" \
            --key="${key}" 2>/dev/null || {
            log_error "etcd 备份失败 (TLS)"
            report "[FAIL] etcd 备份失败 (TLS 模式)"
            ((FAILED_BACKUPS++))
            return 1
        }
    else
        # 非 TLS 模式
        ETCDCTL_API=3 ${etcdctl_cmd} snapshot save "${backup_file}" \
            --endpoints="http://127.0.0.1:2379" 2>/dev/null || {
            log_error "etcd 备份失败"
            report "[FAIL] etcd 备份失败"
            ((FAILED_BACKUPS++))
            return 1
        }
    fi
    
    # 校验快照
    if ETCDCTL_API=3 ${etcdctl_cmd} snapshot status "${backup_file}" --write-out=table &>/dev/null; then
        log_success "etcd 备份成功并校验通过"
        report "[PASS] etcd 备份: ${backup_file}"
        compute_checksum "${backup_file}"
        ((PASSED_BACKUPS++))
    else
        log_error "etcd 快照校验失败"
        report "[FAIL] etcd 快照校验失败"
        ((FAILED_BACKUPS++))
    fi
}

# ========================= K8s 资源导出 =========================
backup_kubernetes() {
    report ""
    report "==================== Kubernetes 资源备份 ===================="
    ((TOTAL_BACKUPS++))
    
    if ! command -v kubectl &>/dev/null; then
        log_warn "kubectl 未安装，跳过"
        report "[SKIP] kubectl 未安装"
        ((PASSED_BACKUPS++))
        return
    fi
    
    if ! kubectl cluster-info &>/dev/null; then
        log_warn "K8s API 不可达，跳过"
        report "[SKIP] K8s API 不可达"
        ((PASSED_BACKUPS++))
        return
    fi
    
    local resource_dir="${BACKUP_K8S}/resources-${DATE}"
    mkdir -p "${resource_dir}"
    
    local resources=(
        "namespaces"
        "configmaps"
        "secrets"
        "services"
        "deployments"
        "statefulsets"
        "daemonsets"
        "ingresses"
        "persistentvolumeclaims"
        "storageclasses"
        "roles"
        "rolebindings"
        "clusterroles"
        "clusterrolebindings"
        "serviceaccounts"
        "networkpolicies"
        "poddisruptionbudgets"
        "horizontalpodautoscalers"
        "certificates"
    )
    
    local ns_list
    ns_list=$(kubectl get ns --no-commands -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "default")
    
    # 集群级别资源
    for res in "${resources[@]}"; do
        if kubectl get "${res}" --all-namespaces -o yaml &>/dev/null 2>"${LOG_DIR}/kubectl-err.log"; then
            kubectl get "${res}" --all-namespaces -o yaml > "${resource_dir}/${res}.yaml" 2>/dev/null || true
        fi
    done
    
    # RBAC 备份
    kubectl get clusterrolebindings -o yaml > "${resource_dir}/clusterrolebindings-full.yaml" 2>/dev/null || true
    
    # CRD 备份
    kubectl get crds -o yaml > "${resource_dir}/customresourcedefinitions.yaml" 2>/dev/null || true
    
    # 命名空间级别资源
    for ns in ${ns_list}; do
        local ns_dir="${resource_dir}/ns-${ns}"
        mkdir -p "${ns_dir}"
        
        for res in configmaps secrets services deployments statefulsets; do
            kubectl get "${res}" -n "${ns}" -o yaml > "${ns_dir}/${res}.yaml" 2>/dev/null || true
        done
    done
    
    # 打包
    local tarball="${BACKUP_K8S}/k8s-resources-${DATE}.tar.gz"
    tar -czf "${tarball}" -C "${resource_dir}" . 2>/dev/null || true
    
    # 清理临时目录
    rm -rf "${resource_dir}"
    
    if [[ -f "${tarball}" ]]; then
        local size
        size=$(du -h "${tarball}" | awk '{print $1}')
        log_success "K8s 资源备份完成: ${size}"
        report "[PASS] K8s 资源备份: ${tarball} (${size})"
        compute_checksum "${tarball}"
        ((PASSED_BACKUPS++))
    else
        log_error "K8s 资源备份失败"
        report "[FAIL] K8s 资源备份失败"
        ((FAILED_BACKUPS++))
    fi
}

# ========================= 配置文件备份 =========================
backup_config() {
    report ""
    report "==================== 配置文件备份 ===================="
    ((TOTAL_BACKUPS++))
    
    local config_dir="${BACKUP_CONFIG}/config-${DATE}"
    mkdir -p "${config_dir}"
    
    # K8s 配置
    local k8s_files=(
        "/etc/kubernetes"
        "/var/lib/kubelet"
        "/etc/cni/net.d"
        "/etc/sysctl.d"
        "/etc/containerd"
        "/etc/docker"
        "/etc/rancher"
    )
    
    for path in "${k8s_files[@]}"; do
        if [[ -e "${path}" ]]; then
            local dest="${config_dir}$(echo "${path}" | sed 's|/|_|g; s|^_||')"
            cp -r "${path}" "${config_dir}/" 2>/dev/null || true
        fi
    done
    
    # 项目配置
    local project_configs=(
        "${PROJECT_ROOT}/config"
        "${PROJECT_ROOT}/ansible"
        "${PROJECT_ROOT}/manifests"
        "${PROJECT_ROOT}/helm"
    )
    
    for path in "${project_configs[@]}"; do
        if [[ -e "${path}" ]]; then
            cp -r "${path}" "${config_dir}/" 2>/dev/null || true
        fi
    done
    
    # 系统关键配置
    cp -f /etc/hosts "${config_dir}/hosts.bak" 2>/dev/null || true
    cp -f /etc/resolv.conf "${config_dir}/resolv.conf.bak" 2>/dev/null || true
    cp -f /etc/fstab "${config_dir}/fstab.bak" 2>/dev/null || true
    cp -f /etc/sysctl.conf "${config_dir}/sysctl.conf.bak" 2>/dev/null || true
    
    # 打包
    local tarball="${BACKUP_CONFIG}/config-${DATE}.tar.gz"
    tar -czf "${tarball}" -C "${config_dir}" . 2>/dev/null || true
    rm -rf "${config_dir}"
    
    if [[ -f "${tarball}" ]]; then
        local size
        size=$(du -h "${tarball}" | awk '{print $1}')
        log_success "配置文件备份完成: ${size}"
        report "[PASS] 配置文件备份: ${tarball} (${size})"
        compute_checksum "${tarball}"
        ((PASSED_BACKUPS++))
    else
        log_error "配置文件备份失败"
        report "[FAIL] 配置文件备份失败"
        ((FAILED_BACKUPS++))
    fi
}

# ========================= 数据库备份 =========================
backup_database() {
    report ""
    report "==================== 数据库备份 ===================="
    ((TOTAL_BACKUPS++))
    
    local db_count=0
    
    # MySQL 备份
    if command -v mysqldump &>/dev/null; then
        local mysql_backup="${BACKUP_DB}/mysql-${DATE}.sql.gz"
        if mysqldump --all-databases --single-transaction --routines --triggers \
            --events 2>/dev/null | gzip > "${mysql_backup}"; then
            local size
            size=$(du -h "${mysql_backup}" | awk '{print $1}')
            log_success "MySQL 备份完成: ${size}"
            report "[PASS] MySQL 备份: ${mysql_backup} (${size})"
            compute_checksum "${mysql_backup}"
            ((db_count++))
        else
            log_warn "MySQL 备份失败或 MySQL 未运行"
        fi
    fi
    
    # PostgreSQL 备份
    if command -v pg_dumpall &>/dev/null; then
        local pg_backup="${BACKUP_DB}/postgresql-${DATE}.sql.gz"
        if pg_dumpall 2>/dev/null | gzip > "${pg_backup}"; then
            local size
            size=$(du -h "${pg_backup}" | awk '{print $1}')
            log_success "PostgreSQL 备份完成: ${size}"
            report "[PASS] PostgreSQL 备份: ${pg_backup} (${size})"
            compute_checksum "${pg_backup}"
            ((db_count++))
        else
            log_warn "PostgreSQL 备份失败或 PostgreSQL 未运行"
        fi
    fi
    
    # Redis 备份
    if command -v redis-cli &>/dev/null; then
        local redis_backup="${BACKUP_DB}/redis-${DATE}.rdb"
        if redis-cli BGSAVE &>/dev/null; then
            sleep 2
            if [[ -f /var/lib/redis/dump.rdb ]]; then
                cp /var/lib/redis/dump.rdb "${redis_backup}" 2>/dev/null || true
                gzip "${redis_backup}" 2>/dev/null || true
                log_success "Redis 备份完成"
                report "[PASS] Redis 备份: ${redis_backup}.gz"
                compute_checksum "${redis_backup}.gz"
                ((db_count++))
            fi
        fi
    fi
    
    if [[ ${db_count} -eq 0 ]]; then
        log_warn "未发现可备份的数据库服务"
        report "[SKIP] 未发现数据库服务"
        ((PASSED_BACKUPS++))
    else
        ((PASSED_BACKUPS++))
    fi
}

# ========================= 完整性校验 =========================
verify_backups() {
    report ""
    report "==================== 备份完整性校验 ===================="
    
    if [[ ! -s "${CHECKSUM_FILE}" ]]; then
        log_warn "无校验文件"
        return 0
    fi
    
    local total checked passed failed
    total=$(wc -l < "${CHECKSUM_FILE}")
    checked=0
    passed=0
    failed=0
    
    while IFS= read -r line; do
        local hash file
        hash=$(echo "${line}" | awk '{print $1}')
        file=$(echo "${line}" | awk '{print $2}')
        
        ((checked++))
        
        if verify_checksum "${file}" "${hash}"; then
            ((passed++))
            log_pass "校验通过: $(basename "${file}")"
            report "[PASS] 校验通过: $(basename "${file}")"
        else
            ((failed++))
            log_error "校验失败: $(basename "${file}")"
            report "[FAIL] 校验失败: $(basename "${file}")"
        fi
    done < "${CHECKSUM_FILE}"
    
    report ""
    report "  校验结果: ${passed}/${total} 通过"
    
    if [[ ${failed} -gt 0 ]]; then
        log_error "完整性校验失败: ${failed} 个文件不匹配"
        return 1
    fi
    
    log_success "所有备份完整性校验通过 (${passed}/${total})"
    return 0
}

# ========================= 备份过期清理 =========================
cleanup_old_backups() {
    report ""
    report "==================== 过期备份清理 ===================="
    
    local total_cleaned=0
    
    for dir in "${BACKUP_ETCD}" "${BACKUP_K8S}" "${BACKUP_CONFIG}" "${BACKUP_DB}"; do
        [[ ! -d "${dir}" ]] && continue
        
        local before
        before=$(find "${dir}" -type f | wc -l)
        
        find "${dir}" -type f -mtime +"${BACKUP_RETENTION_DAYS}" -delete 2>/dev/null || true
        
        local after
        after=$(find "${dir}" -type f | wc -l)
        local cleaned=$(( before - after ))
        total_cleaned=$(( total_cleaned + cleaned ))
        
        [[ ${cleaned} -gt 0 ]] && report "  ${dir}: 清理 ${cleaned} 个过期文件"
    done
    
    if [[ ${total_cleaned} -gt 0 ]]; then
        log_info "清理过期备份: ${total_cleaned} 个文件"
        report "  共清理过期文件: ${total_cleaned} 个"
    else
        report "  无过期文件需要清理"
    fi
}

# ========================= 生成汇总报告 =========================
generate_summary() {
    report ""
    report "================================================================"
    report "  备份汇总报告"
    report "  时间: $(date)"
    report "  主机: $(hostname)"
    report "================================================================"
    report ""
    report "  总备份任务: ${TOTAL_BACKUPS}"
    report "  成功:       ${PASSED_BACKUPS}"
    report "  失败:       ${FAILED_BACKUPS}"
    report ""
    
    if [[ ${FAILED_BACKUPS} -gt 0 ]]; then
        report "  状态: *** 存在备份失败，请检查 ***"
    else
        report "  状态: 所有备份任务成功"
    fi
    
    report ""
    report "  备份目录: ${BACKUP_DIR}"
    report "  校验文件: ${CHECKSUM_FILE}"
    report "  报告文件: ${REPORT_FILE}"
    report "================================================================"
}

# ========================= 主函数 =========================
main() {
    init
    
    echo "================================================================"
    echo "  企业云原生平台 - 备份与完整性校验"
    echo "  时间: $(date)"
    echo "  主机: $(hostname)"
    echo "================================================================"
    
    report "================================================================"
    report "  备份报告"
    report "  时间: $(date)"
    report "  主机: $(hostname)"
    report "================================================================"
    
    backup_etcd
    backup_kubernetes
    backup_config
    backup_database
    verify_backups
    cleanup_old_backups
    generate_summary
    
    if [[ ${FAILED_BACKUPS} -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
