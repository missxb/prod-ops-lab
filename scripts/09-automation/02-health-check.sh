#!/usr/bin/env bash
###############################################################################
# 02-health-check.sh - 自动化健康巡检脚本
#
# 功能:
#   - CPU / 内存 / 磁盘 / 网络检查
#   - K8s 集群状态检查
#   - 服务状态检查
#   - 安全审计检查
#   - 生成巡检报告 (HTML / JSON / 文本)
# 用法: ./02-health-check.sh [options]
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../" && pwd)"
REPORT_DIR="${PROJECT_ROOT}/reports"
LOG_DIR="${PROJECT_ROOT}/logs/health"
DATE=$(date +"%Y%m%d_%H%M%S")
REPORT_FILE="${REPORT_DIR}/health-check-${DATE}.txt"
JSON_REPORT="${REPORT_DIR}/health-check-${DATE}.json"

# 阈值配置
CPU_WARN_THRESHOLD=70
CPU_CRIT_THRESHOLD=90
MEM_WARN_THRESHOLD=75
MEM_CRIT_THRESHOLD=90
DISK_WARN_THRESHOLD=80
DISK_CRIT_THRESHOLD=95
LOAD_WARN_MULTIPLIER=2.0

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TOTAL_CHECKS=0
PASSED_CHECKS=0
WARN_CHECKS=0
CRIT_CHECKS=0

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_pass()    { echo -e "${GREEN}[PASS]${NC} $*"; ((PASSED_CHECKS++)); ((TOTAL_CHECKS++)); }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; ((WARN_CHECKS++)); ((TOTAL_CHECKS++)); }
log_crit()    { echo -e "${RED}[CRIT]${NC} $*"; ((CRIT_CHECKS++)); ((TOTAL_CHECKS++)); }
log_check()   { echo -e "${BLUE}[CHECK]${NC} $*"; }

report_line() {
    local msg="$*"
    echo "${msg}" | tee -a "${REPORT_FILE}"
}

init() {
    mkdir -p "${REPORT_DIR}" "${LOG_DIR}"
    : > "${REPORT_FILE}"
    : > "${JSON_REPORT}"
}

# ========================= CPU 检查 =========================
check_cpu() {
    report_line ""
    report_line "==================== CPU 检查 ===================="
    
    # CPU 使用率
    local cpu_usage
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 2>/dev/null || echo "0")
    
    if (( $(echo "${cpu_usage} > ${CPU_CRIT_THRESHOLD}" | bc -l 2>/dev/null || echo 0) )); then
        log_crit "CPU 使用率过高: ${cpu_usage}% (阈值: ${CPU_CRIT_THRESHOLD}%)"
        report_line "[CRIT] CPU 使用率: ${cpu_usage}%"
    elif (( $(echo "${cpu_usage} > ${CPU_WARN_THRESHOLD}" | bc -l 2>/dev/null || echo 0) )); then
        log_warn "CPU 使用率偏高: ${cpu_usage}% (阈值: ${CPU_WARN_THRESHOLD}%)"
        report_line "[WARN] CPU 使用率: ${cpu_usage}%"
    else
        log_pass "CPU 使用率正常: ${cpu_usage}%"
        report_line "[PASS] CPU 使用率: ${cpu_usage}%"
    fi
    
    # 负载均衡
    local load_avg
    load_avg=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0")
    local cpu_count
    cpu_count=$(nproc 2>/dev/null || echo 1)
    local load_ratio
    load_ratio=$(echo "${load_avg} ${cpu_count}" | awk '{printf "%.2f", $1/$2}' 2>/dev/null || echo "0")
    
    if (( $(echo "${load_ratio} > 3.0" | bc -l 2>/dev/null || echo 0) )); then
        log_crit "系统负载过高: ${load_avg} (CPU核心: ${cpu_count})"
        report_line "[CRIT] 负载: ${load_avg} (比值: ${load_ratio})"
    elif (( $(echo "${load_ratio} > 1.5" | bc -l 2>/dev/null || echo 0) )); then
        log_warn "系统负载偏高: ${load_avg} (CPU核心: ${cpu_count})"
        report_line "[WARN] 负载: ${load_avg} (比值: ${load_ratio})"
    else
        log_pass "系统负载正常: ${load_avg} (CPU核心: ${cpu_count})"
        report_line "[PASS] 负载: ${load_avg} (比值: ${load_ratio})"
    fi
    
    # CPU 核心数
    report_line "[INFO] CPU 核心数: ${cpu_count}"
    report_line "[INFO] CPU 型号: $(grep 'model name' /proc/cpuinfo | head -1 | awk -F: '{print $2}' | xargs 2>/dev/null || echo 'N/A')"
    
    # Top 5 CPU 进程
    report_line ""
    report_line "[INFO] Top 5 CPU 进程:"
    ps aux --sort=-%cpu | head -6 | while IFS= read -r line; do
        report_line "  ${line}"
    done
}

# ========================= 内存检查 =========================
check_memory() {
    report_line ""
    report_line "==================== 内存检查 ===================="
    
    local mem_info
    mem_info=$(free -m 2>/dev/null || echo "")
    
    if [[ -z "${mem_info}" ]]; then
        log_crit "无法获取内存信息"
        report_line "[CRIT] 无法获取内存信息"
        return
    fi
    
    local total used available
    total=$(echo "${mem_info}" | awk '/^Mem:/{print $2}')
    used=$(echo "${mem_info}" | awk '/^Mem:/{print $3}')
    available=$(echo "${mem_info}" | awk '/^Mem:/{print $7}')
    
    local mem_usage
    mem_usage=$(echo "${used} ${total}" | awk '{printf "%.1f", ($1/$2)*100}')
    
    report_line "[INFO] 总内存: ${total}MB"
    report_line "[INFO] 已用内存: ${used}MB"
    report_line "[INFO] 可用内存: ${available}MB"
    
    if (( $(echo "${mem_usage} > ${MEM_CRIT_THRESHOLD}" | bc -l 2>/dev/null || echo 0) )); then
        log_crit "内存使用率过高: ${mem_usage}% (阈值: ${MEM_CRIT_THRESHOLD}%)"
        report_line "[CRIT] 内存使用率: ${mem_usage}%"
    elif (( $(echo "${mem_usage} > ${MEM_WARN_THRESHOLD}" | bc -l 2>/dev/null || echo 0) )); then
        log_warn "内存使用率偏高: ${mem_usage}% (阈值: ${MEM_WARN_THRESHOLD}%)"
        report_line "[WARN] 内存使用率: ${mem_usage}%"
    else
        log_pass "内存使用率正常: ${mem_usage}%"
        report_line "[PASS] 内存使用率: ${mem_usage}%"
    fi
    
    # Swap 检查
    local swap_total swap_used
    swap_total=$(echo "${mem_info}" | awk '/^Swap:/{print $2}')
    swap_used=$(echo "${mem_info}" | awk '/^Swap:/{print $3}')
    
    report_line "[INFO] Swap 总量: ${swap_total}MB, 已用: ${swap_used}MB"
    
    if [[ "${swap_used}" -gt 0 && "${swap_total}" -gt 0 ]]; then
        local swap_usage
        swap_usage=$(echo "${swap_used} ${swap_total}" | awk '{printf "%.1f", ($1/$2)*100}')
        if (( $(echo "${swap_usage} > 50" | bc -l 2>/dev/null || echo 0) )); then
            log_warn "Swap 使用率偏高: ${swap_usage}%"
            report_line "[WARN] Swap 使用率: ${swap_usage}%"
        else
            log_pass "Swap 使用率正常: ${swap_usage}%"
            report_line "[PASS] Swap 使用率: ${swap_usage}%"
        fi
    fi
    
    # Top 5 内存进程
    report_line ""
    report_line "[INFO] Top 5 内存进程:"
    ps aux --sort=-%mem | head -6 | while IFS= read -r line; do
        report_line "  ${line}"
    done
}

# ========================= 磁盘检查 =========================
check_disk() {
    report_line ""
    report_line "==================== 磁盘检查 ===================="
    
    # 磁盘使用率
    while IFS= read -r line; do
        local mount_point usage
        mount_point=$(echo "${line}" | awk '{print $6}')
        usage=$(echo "${line}" | awk '{print $5}' | tr -d '%')
        
        if [[ "${usage}" -ge "${DISK_CRIT_THRESHOLD}" ]]; then
            log_crit "磁盘使用率过高: ${mount_point} = ${usage}% (阈值: ${DISK_CRIT_THRESHOLD}%)"
            report_line "[CRIT] ${mount_point}: ${usage}%"
        elif [[ "${usage}" -ge "${DISK_WARN_THRESHOLD}" ]]; then
            log_warn "磁盘使用率偏高: ${mount_point} = ${usage}% (阈值: ${DISK_WARN_THRESHOLD}%)"
            report_line "[WARN] ${mount_point}: ${usage}%"
        else
            log_pass "磁盘正常: ${mount_point} = ${usage}%"
            report_line "[PASS] ${mount_point}: ${usage}%"
        fi
    done < <(df -h --output=source,size,used,avail,pcent,target 2>/dev/null | grep -vE '^Filesystem|^tmpfs|^devtmpfs|^overlay' || df -h 2>/dev/null | tail -n +2)
    
    # inode 检查
    report_line ""
    report_line "[INFO] Inode 使用率:"
    while IFS= read -r line; do
        local iuse
        iuse=$(echo "${line}" | awk '{print $5}' | tr -d '%')
        if [[ "${iuse}" =~ ^[0-9]+$ && "${iuse}" -ge 80 ]]; then
            log_warn "Inode 使用率偏高: ${line}"
            report_line "[WARN] ${line}"
        fi
    done < <(df -i 2>/dev/null | grep -vE '^Filesystem|^tmpfs|^devtmpfs|^overlay' || true)
    
    # IO 等待
    local iowait
    iowait=$(iostat 1 1 2>/dev/null | tail -1 | awk '{print $4}' || echo "N/A")
    report_line "[INFO] IO Wait: ${iowait}%"
}

# ========================= 网络检查 =========================
check_network() {
    report_line ""
    report_line "==================== 网络检查 ===================="
    
    # 网络接口
    report_line "[INFO] 网络接口状态:"
    ip -4 addr show 2>/dev/null | grep -E 'inet |^[0-9]' | while IFS= read -r line; do
        report_line "  ${line}"
    done
    
    # DNS 解析
    local dns_start dns_end
    dns_start=$(date +%s%N)
    if nslookup kubernetes.default.svc.cluster.local &>/dev/null || \
       host kubernetes.default.svc.cluster.local &>/dev/null; then
        dns_end=$(date +%s%N)
        local dns_time=$(( (dns_end - dns_start) / 1000000 ))
        log_pass "Kubernetes DNS 解析正常 (${dns_time}ms)"
        report_line "[PASS] K8s DNS 解析: ${dns_time}ms"
    else
        log_warn "Kubernetes DNS 解析失败"
        report_line "[WARN] K8s DNS 解析失败"
    fi
    
    # 外网连通
    if curl -sS --connect-timeout 5 -o /dev/null https://www.baidu.com 2>/dev/null; then
        log_pass "外网连通正常"
        report_line "[PASS] 外网连通: 正常"
    else
        log_warn "外网连通失败"
        report_line "[WARN] 外网连通: 失败"
    fi
    
    # 监听端口
    report_line "[INFO] 监听端口:"
    ss -tlnp 2>/dev/null | head -20 | while IFS= read -r line; do
        report_line "  ${line}"
    done
    
    # 网络错误统计
    local net_errors
    net_errors=$(cat /proc/net/dev 2>/dev/null | awk 'NR>2 {err+=$4} END {print err+0}' || echo "0")
    report_line "[INFO] 网络错误包总计: ${net_errors}"
}

# ========================= K8s 集群检查 =========================
check_kubernetes() {
    report_line ""
    report_line "==================== Kubernetes 集群检查 ===================="
    
    if ! command -v kubectl &>/dev/null; then
        log_warn "kubectl 未安装，跳过 K8s 检查"
        report_line "[WARN] kubectl 未安装"
        return
    fi
    
    if ! kubectl cluster-info &>/dev/null; then
        log_crit "Kubernetes API 不可达"
        report_line "[CRIT] K8s API 不可达"
        return
    fi
    
    log_pass "Kubernetes API 可达"
    report_line "[PASS] K8s API: 可达"
    
    # 节点状态
    report_line ""
    report_line "[INFO] 节点状态:"
    kubectl get nodes -o wide 2>/dev/null | while IFS= read -r line; do
        report_line "  ${line}"
    done
    
    # 检查 NotReady 节点
    local notready
    notready=$(kubectl get nodes --no-headers 2>/dev/null | grep -v " Ready " | wc -l || echo 0)
    if [[ "${notready}" -gt 0 ]]; then
        log_crit "发现 ${notready} 个非 Ready 节点"
        report_line "[CRIT] NotReady 节点: ${notready}"
    else
        log_pass "所有节点 Ready"
        report_line "[PASS] 节点状态: 全部 Ready"
    fi
    
    # Pod 状态
    report_line ""
    report_line "[INFO] Pod 状态摘要:"
    kubectl get pods --all-namespaces --no-headers 2>/dev/null | awk '{print $4}' | sort | uniq -c | sort -rn | while IFS= read -r line; do
        report_line "  ${line}"
    done
    
    # 异常 Pod
    local bad_pods
    bad_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -iE "Error|CrashLoopBackOff|ImagePullBackOff|Pending|Failed" | wc -l || echo 0)
    if [[ "${bad_pods}" -gt 0 ]]; then
        log_crit "发现 ${bad_pods} 个异常 Pod"
        report_line "[CRIT] 异常 Pod 数量: ${bad_pods}"
        kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -iE "Error|CrashLoopBackOff|ImagePullBackOff|Pending|Failed" | head -10 | while IFS= read -r line; do
            report_line "    ${line}"
        done
    else
        log_pass "所有 Pod 运行正常"
        report_line "[PASS] Pod 状态: 全部正常"
    fi
    
    # 系统组件
    report_line ""
    report_line "[INFO] 系统组件状态:"
    kubectl get pods -n kube-system --no-headers 2>/dev/null | while IFS= read -r line; do
        report_line "  ${line}"
    done
}

# ========================= 服务检查 =========================
check_services() {
    report_line ""
    report_line "==================== 系统服务检查 ===================="
    
    local services=("docker" "kubelet" "containerd" "etcd" "nginx" "haproxy" "chronyd" "sshd" "firewalld")
    
    for svc in "${services[@]}"; do
        if systemctl is-enabled "${svc}" &>/dev/null; then
            if systemctl is-active "${svc}" &>/dev/null; then
                log_pass "服务运行中: ${svc}"
                report_line "[PASS] ${svc}: active (running)"
            else
                log_crit "服务未运行: ${svc}"
                report_line "[CRIT] ${svc}: inactive (stopped)"
            fi
        fi
    done
}

# ========================= 安全检查 =========================
check_security() {
    report_line ""
    report_line "==================== 安全检查 ===================="
    
    # SSH 登录检查
    local failed_logins
    failed_logins=$(lastb 2>/dev/null | tail -5 | wc -l || echo 0)
    if [[ "${failed_logins}" -gt 0 ]]; then
        report_line "[INFO] 最近失败 SSH 登录: ${failed_logins} 条"
        lastb 2>/dev/null | head -5 | while IFS= read -r line; do
            report_line "  ${line}"
        done
    fi
    
    # 密码策略
    local no_password
    no_password=$(awk -F: '($2 == "" || $2 == "!") {print $1}' /etc/shadow 2>/dev/null | wc -l || echo 0)
    if [[ "${no_password}" -gt 0 ]]; then
        log_warn "发现 ${no_password} 个无密码账户"
        report_line "[WARN] 无密码账户: ${no_password}"
    fi
    
    # 临时文件
    local tmp_size
    tmp_size=$(du -sh /tmp 2>/dev/null | awk '{print $1}' || echo "N/A")
    report_line "[INFO] /tmp 目录大小: ${tmp_size}"
    
    # SELinux 状态
    local selinux_status
    selinux_status=$(getenforce 2>/dev/null || echo "Not installed")
    report_line "[INFO] SELinux: ${selinux_status}"
    
    # 防火墙状态
    if command -v firewall-cmd &>/dev/null; then
        local fw_status
        fw_status=$(firewall-cmd --state 2>/dev/null || echo "not running")
        report_line "[INFO] Firewalld: ${fw_status}"
    fi
}

# ========================= 生成汇总报告 =========================
generate_summary() {
    report_line ""
    report_line "================================================================"
    report_line "  健康巡检汇总报告"
    report_line "  时间: $(date)"
    report_line "  主机: $(hostname)"
    report_line "================================================================"
    report_line ""
    report_line "  总检查项: ${TOTAL_CHECKS}"
    report_line "  通过:     ${PASSED_CHECKS}"
    report_line "  警告:     ${WARN_CHECKS}"
    report_line "  严重:     ${CRIT_CHECKS}"
    report_line ""
    
    if [[ "${CRIT_CHECKS}" -gt 0 ]]; then
        report_line "  状态: *** 存在严重问题，需要立即处理 ***"
    elif [[ "${WARN_CHECKS}" -gt 0 ]]; then
        report_line "  状态: ** 存在警告，建议关注 **"
    else
        report_line "  状态: 所有检查通过"
    fi
    
    report_line ""
    report_line "  报告文件: ${REPORT_FILE}"
    report_line "  JSON 报告: ${JSON_REPORT}"
    report_line "================================================================"
    
    # 生成 JSON 报告
    cat > "${JSON_REPORT}" << EOF
{
  "timestamp": "$(date -Iseconds)",
  "hostname": "$(hostname)",
  "summary": {
    "total_checks": ${TOTAL_CHECKS},
    "passed": ${PASSED_CHECKS},
    "warnings": ${WARN_CHECKS},
    "critical": ${CRIT_CHECKS},
    "status": "$([ "${CRIT_CHECKS}" -gt 0 ] && echo "CRITICAL" || ([ "${WARN_CHECKS}" -gt 0 ] && echo "WARNING" || echo "HEALTHY"))"
  }
}
EOF
}

# ========================= 主函数 =========================
main() {
    init
    
    echo "================================================================"
    echo "  企业云原生平台 - 自动化健康巡检"
    echo "  时间: $(date)"
    echo "  主机: $(hostname)"
    echo "================================================================"
    
    report_line "================================================================"
    report_line "  健康巡检报告"
    report_line "  时间: $(date)"
    report_line "  主机: $(hostname)"
    report_line "================================================================"
    
    check_cpu
    check_memory
    check_disk
    check_network
    check_kubernetes
    check_services
    check_security
    
    generate_summary
    
    # 返回码
    if [[ "${CRIT_CHECKS}" -gt 0 ]]; then
        exit 2
    elif [[ "${WARN_CHECKS}" -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
