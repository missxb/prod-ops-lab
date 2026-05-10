#!/bin/bash
###############################################################################
# 05-资产管理脚本
# 功能: 资产信息采集与报告生成
# 特性: 主机信息采集、多格式报告、多主机扫描、资产清单
# 版本: 1.1.0
# 作者: 运维平台团队
###############################################################################

set -euo pipefail
umask 077

# 锁文件
LOCK_FILE="/tmp/05-asset-management.lock"

# 清理函数
cleanup() {
    rm -f "$LOCK_FILE"
}

# 错误处理
trap 'echo -e "\033[0;31m[ERROR]\033[0m 资产管理脚本异常退出 (行号: $LINENO)" >&2; cleanup' ERR
trap cleanup EXIT SIGINT SIGTERM

# 检查锁文件
if [[ -f "$LOCK_FILE" ]]; then
    old_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
        echo -e "\033[0;31m[ERROR]\033[0m 另一个实例正在运行 (PID: $old_pid)" >&2
        exit 1
    fi
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 日志函数
log_info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*"; }
log_step()  { echo -e "${CYAN}[STEP]${NC}  $(date '+%H:%M:%S') $*"; }

# ==================== 配置变量 ====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../" && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/09-automation/"
LOG_FILE="${LOG_DIR}/asset-management-$(date +%Y%m%d-%H%M%S).log"
REPORT_DIR="${PROJECT_ROOT}/reports/assets"

# 输出格式
OUTPUT_FORMAT="${OUTPUT_FORMAT:-text}"
HOSTS_FILE="${HOSTS_FILE:-}"

# SSH配置
SSH_USER="${SSH_USER:-root}"
SSH_KEY="${SSH_KEY:-}"
SSH_TIMEOUT="${SSH_TIMEOUT:-10}"

# ==================== 用法说明 ====================
usage() {
    cat << EOF
用法: $(basename "$0") [options]

功能: 资产信息采集与报告生成

选项:
  --format <text|json|csv>  输出格式（默认: text）
  --hosts <file>            主机列表文件（每行一个IP）
  --ssh-user <user>         SSH用户名（默认: root）
  --ssh-key <key>           SSH密钥路径
  --help                    显示此帮助信息

功能说明:
  1. 采集主机信息:
     - 主机名、IP地址（所有接口）
     - 操作系统版本、内核版本
     - CPU型号、核心数、线程数
     - 内存总量/已用/空闲
     - 磁盘信息（总量、已用、挂载点）
     - 网络接口和IP
     - 已安装软件包数量
     - Docker版本（如已安装）
     - Kubernetes节点信息（如适用）

  2. 生成报告:
     - Text: 人类可读的表格格式
     - JSON: 程序化使用的结构化格式
     - CSV: 电子表格导入格式

  3. 支持多主机扫描:
     - 通过SSH采集远程主机信息
     - 聚合多主机资产清单

示例:
  $(basename "$0")                          # 采集本地主机信息
  $(basename "$0") --format json            # JSON格式输出
  $(basename "$0") --hosts hosts.txt        # 扫描主机列表
  $(basename "$0") --format csv --hosts hosts.txt  # CSV格式，扫描多主机
EOF
    exit 0
}

# ==================== 参数解析 ====================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --format)    OUTPUT_FORMAT="$2"; shift 2 ;;
            --hosts)     HOSTS_FILE="$2"; shift 2 ;;
            --ssh-user)  SSH_USER="$2"; shift 2 ;;
            --ssh-key)   SSH_KEY="$2"; shift 2 ;;
            --help|-h)   usage ;;
            *) log_error "未知参数: $1"; usage ;;
        esac
    done

    # 验证输出格式
    case "$OUTPUT_FORMAT" in
        text|json|csv) ;;
        *) log_error "不支持的输出格式: $OUTPUT_FORMAT (支持: text, json, csv)"; exit 1 ;;
    esac
}

# ==================== 信息采集函数 ====================

# 采集主机信息
collect_host_info() {
    local hostname_val
    hostname_val=$(hostname 2>/dev/null || echo "unknown")

    local ip_addresses
    ip_addresses=$(hostname -I 2>/dev/null | tr ' ' ',' || echo "unknown")

    local os_version
    os_version=$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || echo "unknown")

    local kernel_version
    kernel_version=$(uname -r 2>/dev/null || echo "unknown")

    local cpu_model
    cpu_model=$(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs || echo "unknown")

    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || echo "1")

    local cpu_threads
    cpu_threads=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "$cpu_cores")

    local mem_total
    mem_total=$(free -h 2>/dev/null | awk '/Mem:/{print $2}' || echo "unknown")

    local mem_used
    mem_used=$(free -h 2>/dev/null | awk '/Mem:/{print $3}' || echo "unknown")

    local mem_free
    mem_free=$(free -h 2>/dev/null | awk '/Mem:/{print $4}' || echo "unknown")

    local disk_info
    disk_info=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}' || echo "unknown")

    local mount_points
    mount_points=$(df -h 2>/dev/null | awk 'NR>1{print $6}' | tr '\n' ',' || echo "/")

    local network_interfaces
    network_interfaces=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v "^lo$" | tr '\n' ',' || echo "unknown")

    local package_count
    if command -v rpm &>/dev/null; then
        package_count=$(rpm -qa 2>/dev/null | wc -l || echo "0")
    elif command -v dpkg &>/dev/null; then
        package_count=$(dpkg -l 2>/dev/null | grep "^ii" | wc -l || echo "0")
    else
        package_count="unknown"
    fi

    local docker_version
    docker_version=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo "not_installed")

    local k8s_node_info
    if command -v kubectl &>/dev/null; then
        k8s_node_info=$(kubectl get node $(hostname) -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null || echo "not_available")
    else
        k8s_node_info="kubectl_not_available"
    fi

    local uptime
    uptime=$(uptime -p 2>/dev/null || uptime | awk -F'up ' '{print $2}' | cut -d, -f1 || echo "unknown")

    local load_avg
    load_avg=$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | xargs || echo "unknown")

    # 返回数据（JSON格式）
    cat <<JSON
{
    "hostname": "${hostname_val}",
    "ip_addresses": "${ip_addresses}",
    "os_version": "${os_version}",
    "kernel_version": "${kernel_version}",
    "cpu_model": "${cpu_model}",
    "cpu_cores": "${cpu_cores}",
    "cpu_threads": "${cpu_threads}",
    "memory_total": "${mem_total}",
    "memory_used": "${mem_used}",
    "memory_free": "${mem_free}",
    "disk_info": "${disk_info}",
    "mount_points": "${mount_points}",
    "network_interfaces": "${network_interfaces}",
    "package_count": "${package_count}",
    "docker_version": "${docker_version}",
    "k8s_node_info": "${k8s_node_info}",
    "uptime": "${uptime}",
    "load_average": "${load_avg}",
    "collection_time": "$(date '+%Y-%m-%d %H:%M:%S')"
}
JSON
}

# 采集远程主机信息
collect_remote_host_info() {
    local host=$1
    local ssh_opts=""

    if [[ -n "$SSH_KEY" ]]; then
        ssh_opts="-i $SSH_KEY"
    fi

    ssh $ssh_opts -o ConnectTimeout=$SSH_TIMEOUT -o StrictHostKeyChecking=no \
        "${SSH_USER}@${host}" 'bash -s' < <(
        cat <<'REMOTE_SCRIPT'
#!/bin/bash
set -euo pipefail

hostname_val=$(hostname 2>/dev/null || echo "unknown")
ip_addresses=$(hostname -I 2>/dev/null | tr ' ' ',' || echo "unknown")
os_version=$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || echo "unknown")
kernel_version=$(uname -r 2>/dev/null || echo "unknown")
cpu_model=$(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs || echo "unknown")
cpu_cores=$(nproc 2>/dev/null || echo "1")
cpu_threads=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "$cpu_cores")
mem_total=$(free -h 2>/dev/null | awk '/Mem:/{print $2}' || echo "unknown")
mem_used=$(free -h 2>/dev/null | awk '/Mem:/{print $3}' || echo "unknown")
mem_free=$(free -h 2>/dev/null | awk '/Mem:/{print $4}' || echo "unknown")
disk_info=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}' || echo "unknown")
mount_points=$(df -h 2>/dev/null | awk 'NR>1{print $6}' | tr '\n' ',' || echo "/")
network_interfaces=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v "^lo$" | tr '\n' ',' || echo "unknown")
if command -v rpm &>/dev/null; then
    package_count=$(rpm -qa 2>/dev/null | wc -l || echo "0")
elif command -v dpkg &>/dev/null; then
    package_count=$(dpkg -l 2>/dev/null | grep "^ii" | wc -l || echo "0")
else
    package_count="unknown"
fi
docker_version=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo "not_installed")
if command -v kubectl &>/dev/null; then
    k8s_node_info=$(kubectl get node $(hostname) -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null || echo "not_available")
else
    k8s_node_info="kubectl_not_available"
fi
uptime_val=$(uptime -p 2>/dev/null || uptime | awk -F'up ' '{print $2}' | cut -d, -f1 || echo "unknown")
load_avg=$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | xargs || echo "unknown")

cat <<JSON
{
    "hostname": "${hostname_val}",
    "ip_addresses": "${ip_addresses}",
    "os_version": "${os_version}",
    "kernel_version": "${kernel_version}",
    "cpu_model": "${cpu_model}",
    "cpu_cores": "${cpu_cores}",
    "cpu_threads": "${cpu_threads}",
    "memory_total": "${mem_total}",
    "memory_used": "${mem_used}",
    "memory_free": "${mem_free}",
    "disk_info": "${disk_info}",
    "mount_points": "${mount_points}",
    "network_interfaces": "${network_interfaces}",
    "package_count": "${package_count}",
    "docker_version": "${docker_version}",
    "k8s_node_info": "${k8s_node_info}",
    "uptime": "${uptime_val}",
    "load_average": "${load_avg}",
    "collection_time": "$(date '+%Y-%m-%d %H:%M:%S')"
}
JSON
REMOTE_SCRIPT
    )
}

# ==================== 报告生成函数 ====================

# 生成Text格式报告
generate_text_report() {
    local data=$1
    local output_file=$2

    echo "=================================================================" > "$output_file"
    echo "  企业级云原生运维平台 - 资产清单报告" >> "$output_file"
    echo "  生成时间: $(date '+%Y-%m-%d %H:%M:%S')" >> "$output_file"
    echo "=================================================================" >> "$output_file"
    echo "" >> "$output_file"

    # 解析JSON数据
    local hostname_val ip_addresses os_version kernel_version cpu_model
    local cpu_cores cpu_threads mem_total mem_used mem_free disk_info
    local mount_points network_interfaces package_count docker_version
    local k8s_node_info uptime load_avg collection_time

    hostname_val=$(echo "$data" | grep '"hostname"' | cut -d'"' -f4)
    ip_addresses=$(echo "$data" | grep '"ip_addresses"' | cut -d'"' -f4)
    os_version=$(echo "$data" | grep '"os_version"' | cut -d'"' -f4)
    kernel_version=$(echo "$data" | grep '"kernel_version"' | cut -d'"' -f4)
    cpu_model=$(echo "$data" | grep '"cpu_model"' | cut -d'"' -f4)
    cpu_cores=$(echo "$data" | grep '"cpu_cores"' | awk -F': ' '{print $2}' | tr -d ' ",' || echo "")
    cpu_threads=$(echo "$data" | grep '"cpu_threads"' | awk -F': ' '{print $2}' | tr -d ' ",' || echo "")
    mem_total=$(echo "$data" | grep '"memory_total"' | cut -d'"' -f4)
    mem_used=$(echo "$data" | grep '"memory_used"' | cut -d'"' -f4)
    mem_free=$(echo "$data" | grep '"memory_free"' | cut -d'"' -f4)
    disk_info=$(echo "$data" | grep '"disk_info"' | cut -d'"' -f4)
    mount_points=$(echo "$data" | grep '"mount_points"' | cut -d'"' -f4)
    network_interfaces=$(echo "$data" | grep '"network_interfaces"' | cut -d'"' -f4)
    package_count=$(echo "$data" | grep '"package_count"' | awk -F': ' '{print $2}' | tr -d ' ",' || echo "")
    docker_version=$(echo "$data" | grep '"docker_version"' | cut -d'"' -f4)
    k8s_node_info=$(echo "$data" | grep '"k8s_node_info"' | cut -d'"' -f4)
    uptime_val=$(echo "$data" | grep '"uptime"' | cut -d'"' -f4)
    load_avg=$(echo "$data" | grep '"load_average"' | cut -d'"' -f4)
    collection_time=$(echo "$data" | grep '"collection_time"' | cut -d'"' -f4)

    cat >> "$output_file" <<REPORT
主机名:       ${hostname_val}
IP地址:       ${ip_addresses}
操作系统:     ${os_version}
内核版本:     ${kernel_version}

CPU信息:
  型号:       ${cpu_model}
  核心数:     ${cpu_cores}
  线程数:     ${cpu_threads}

内存信息:
  总量:       ${mem_total}
  已用:       ${mem_used}
  空闲:       ${mem_free}

磁盘信息:
  使用情况:   ${disk_info}
  挂载点:     ${mount_points}

网络接口:     ${network_interfaces}

软件包数量:   ${package_count}
Docker版本:   ${docker_version}
K8s节点信息:  ${k8s_node_info}

系统运行时间: ${uptime_val}
系统负载:     ${load_avg}
采集时间:     ${collection_time}

=================================================================
REPORT

    echo "$output_file"
}

# 生成JSON格式报告
generate_json_report() {
    local data=$1
    local output_file=$2

    echo "$data" > "$output_file"
    echo "$output_file"
}

# 生成CSV格式报告
generate_csv_report() {
    local data=$1
    local output_file=$2

    # CSV表头
    echo "hostname,ip_addresses,os_version,kernel_version,cpu_model,cpu_cores,cpu_threads,memory_total,memory_used,memory_free,disk_info,mount_points,network_interfaces,package_count,docker_version,k8s_node_info,uptime,load_average,collection_time" > "$output_file"

    # 解析JSON数据并生成CSV行
    local hostname_val ip_addresses os_version kernel_version cpu_model
    local cpu_cores cpu_threads mem_total mem_used mem_free disk_info
    local mount_points network_interfaces package_count docker_version
    local k8s_node_info uptime load_avg collection_time

    hostname_val=$(echo "$data" | grep '"hostname"' | cut -d'"' -f4)
    ip_addresses=$(echo "$data" | grep '"ip_addresses"' | cut -d'"' -f4)
    os_version=$(echo "$data" | grep '"os_version"' | cut -d'"' -f4)
    kernel_version=$(echo "$data" | grep '"kernel_version"' | cut -d'"' -f4)
    cpu_model=$(echo "$data" | grep '"cpu_model"' | cut -d'"' -f4)
    cpu_cores=$(echo "$data" | grep '"cpu_cores"' | awk -F': ' '{print $2}' | tr -d ' ",' || echo "")
    cpu_threads=$(echo "$data" | grep '"cpu_threads"' | awk -F': ' '{print $2}' | tr -d ' ",' || echo "")
    mem_total=$(echo "$data" | grep '"memory_total"' | cut -d'"' -f4)
    mem_used=$(echo "$data" | grep '"memory_used"' | cut -d'"' -f4)
    mem_free=$(echo "$data" | grep '"memory_free"' | cut -d'"' -f4)
    disk_info=$(echo "$data" | grep '"disk_info"' | cut -d'"' -f4)
    mount_points=$(echo "$data" | grep '"mount_points"' | cut -d'"' -f4)
    network_interfaces=$(echo "$data" | grep '"network_interfaces"' | cut -d'"' -f4)
    package_count=$(echo "$data" | grep '"package_count"' | awk -F': ' '{print $2}' | tr -d ' ",' || echo "")
    docker_version=$(echo "$data" | grep '"docker_version"' | cut -d'"' -f4)
    k8s_node_info=$(echo "$data" | grep '"k8s_node_info"' | cut -d'"' -f4)
    uptime_val=$(echo "$data" | grep '"uptime"' | cut -d'"' -f4)
    load_avg=$(echo "$data" | grep '"load_average"' | cut -d'"' -f4)
    collection_time=$(echo "$data" | grep '"collection_time"' | cut -d'"' -f4)

    # 输出CSV行
    echo "\"${hostname_val}\",\"${ip_addresses}\",\"${os_version}\",\"${kernel_version}\",\"${cpu_model}\",\"${cpu_cores}\",\"${cpu_threads}\",\"${mem_total}\",\"${mem_used}\",\"${mem_free}\",\"${disk_info}\",\"${mount_points}\",\"${network_interfaces}\",\"${package_count}\",\"${docker_version}\",\"${k8s_node_info}\",\"${uptime_val}\",\"${load_avg}\",\"${collection_time}\"" >> "$output_file"

    echo "$output_file"
}

# ==================== 主函数 ====================
main() {
    parse_args "$@"

    echo ""
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${CYAN}  企业级云原生运维平台 - 资产管理${NC}"
    echo -e "${CYAN}  版本: 1.1.0${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo ""

    mkdir -p "$REPORT_DIR"

    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)

    if [[ -n "$HOSTS_FILE" && -f "$HOSTS_FILE" ]]; then
        # 多主机扫描模式
        log_step "多主机扫描模式"
        log_info "主机列表文件: $HOSTS_FILE"

        local all_data="["
        local first=true
        local host_count=0
        local success_count=0
        local fail_count=0

        while IFS= read -r host; do
            [[ -z "$host" || "$host" == \#* ]] && continue
            host_count=$((host_count + 1))

            log_info "扫描主机: $host"

            if host_data=$(collect_remote_host_info "$host" 2>/dev/null); then
                if [[ "$first" == true ]]; then
                    first=false
                else
                    all_data+=","
                fi
                all_data+="$host_data"
                success_count=$((success_count + 1))
                log_info "主机 $host 采集成功"
            else
                fail_count=$((fail_count + 1))
                log_warn "主机 $host 采集失败"
            fi
        done < "$HOSTS_FILE"

        all_data+="]"

        # 生成报告
        local report_file="${REPORT_DIR}/asset-inventory-${timestamp}.${OUTPUT_FORMAT}"

        case "$OUTPUT_FORMAT" in
            text)
                generate_text_report "$all_data" "$report_file"
                ;;
            json)
                generate_json_report "$all_data" "$report_file"
                ;;
            csv)
                generate_csv_report "$all_data" "$report_file"
                ;;
        esac

        # 输出汇总
        echo ""
        echo -e "${CYAN}================================================================${NC}"
        echo -e "${CYAN}  扫描汇总${NC}"
        echo -e "${CYAN}================================================================${NC}"
        echo -e "  主机总数:   ${host_count}"
        echo -e "  ${GREEN}成功:       ${success_count}${NC}"
        echo -e "  ${RED}失败:       ${fail_count}${NC}"
        echo -e "  报告文件:   ${report_file}"
        echo -e "${CYAN}================================================================${NC}"

    else
        # 单主机采集模式
        log_step "单主机采集模式"

        # 采集本地主机信息
        local host_data
        host_data=$(collect_host_info)

        log_info "主机信息采集完成"

        # 生成报告
        local report_file="${REPORT_DIR}/asset-inventory-$(hostname)-${timestamp}.${OUTPUT_FORMAT}"

        case "$OUTPUT_FORMAT" in
            text)
                generate_text_report "$host_data" "$report_file"
                ;;
            json)
                generate_json_report "$host_data" "$report_file"
                ;;
            csv)
                generate_csv_report "$host_data" "$report_file"
                ;;
        esac

        echo ""
        echo -e "${GREEN}================================================================${NC}"
        echo -e "${GREEN}  资产信息采集完成${NC}"
        echo -e "${GREEN}  报告文件: ${report_file}${NC}"
        echo -e "${GREEN}================================================================${NC}"

        # 在终端显示文本报告
        if [[ "$OUTPUT_FORMAT" == "text" ]]; then
            echo ""
            cat "$report_file"
        fi
    fi

    echo ""
}

# 执行主函数
main "$@"
