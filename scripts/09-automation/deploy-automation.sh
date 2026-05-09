#!/usr/bin/env bash
###############################################################################
# deploy-automation.sh - 企业级云原生平台自动化运维主脚本
# 
# 功能: 统一调度自动化部署、巡检、清理、备份等运维任务
# 用法: ./deploy-automation.sh <command> [options]
# 作者: DevOps Team
# 版本: 1.0.0
###############################################################################
set -euo pipefail

# ========================= 全局变量 =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../" && pwd)"
ANSIBLE_DIR="${PROJECT_ROOT}/ansible"
LOG_DIR="${PROJECT_ROOT}/logs/automation"
REPORT_DIR="${PROJECT_ROOT}/reports"
CONFIG_FILE="${PROJECT_ROOT}/config/automation.conf"
LOCK_FILE="/tmp/deploy-automation.lock"
DATE=$(date +"%Y%m%d_%H%M%S")
HOSTNAME=$(hostname)

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ========================= 日志函数 =========================
log_info()    { echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
log_debug()   { [[ "${DEBUG:-false}" == "true" ]] && echo -e "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

# 初始化日志目录
init_logging() {
    mkdir -p "${LOG_DIR}" "${REPORT_DIR}"
}

# ========================= 锁机制 =========================
acquire_lock() {
    if [[ -f "${LOCK_FILE}" ]]; then
        local pid
        pid=$(cat "${LOCK_FILE}")
        if kill -0 "${pid}" 2>/dev/null; then
            log_error "另一个实例正在运行 (PID: ${pid})"
            exit 1
        else
            log_warn "发现过期锁文件，正在清理..."
            rm -f "${LOCK_FILE}"
        fi
    fi
    echo $$ > "${LOCK_FILE}"
    trap 'rm -f "${LOCK_FILE}"; exit' INT TERM EXIT
}

release_lock() {
    rm -f "${LOCK_FILE}"
}

# ========================= 配置加载 =========================
load_config() {
    if [[ -f "${CONFIG_FILE}" ]]; then
        log_info "加载配置: ${CONFIG_FILE}"
        source "${CONFIG_FILE}"
    else
        log_warn "配置文件不存在，使用默认配置"
    fi
    
    # 默认值
    : "${ENVIRONMENT:=production}"
    : "${CLUSTER_NAME:=default}"
    : "${BACKUP_RETENTION_DAYS:=30}"
    : "${LOG_RETENTION_DAYS:=15}"
    : "${HEALTH_CHECK_TIMEOUT:=30}"
    : "${PARALLEL_LIMIT:=5}"
}

# ========================= 前置检查 =========================
preflight_check() {
    log_info "执行前置检查..."
    
    local errors=0
    
    # 检查必要命令
    local required_cmds=("ansible" "ansible-playbook" "kubectl" "etcdctl" "jq" "curl" "openssl")
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "${cmd}" &>/dev/null; then
            log_error "命令不存在: ${cmd}"
            ((errors++))
        fi
    done
    
    # 检查目录
    for dir in "${ANSIBLE_DIR}" "${LOG_DIR}" "${REPORT_DIR}"; do
        if [[ ! -d "${dir}" ]]; then
            mkdir -p "${dir}"
            log_debug "创建目录: ${dir}"
        fi
    done
    
    # 检查Ansible可达性
    if command -v ansible &>/dev/null; then
        if ! ansible all -m ping -i "${ANSIBLE_DIR}/inventory/hosts.yml" --timeout=5 &>/dev/null; then
            log_warn "部分主机不可达，请检查SSH连通性"
        fi
    fi
    
    if [[ ${errors} -gt 0 ]]; then
        log_error "前置检查失败，共 ${errors} 个错误"
        exit 1
    fi
    
    log_success "前置检查通过"
}

# ========================= 任务调度 =========================
cmd_setup() {
    log_info "========== 执行 Ansible 环境初始化 =========="
    bash "${SCRIPT_DIR}/01-setup-ansible.sh" 2>&1 | tee -a "${LOG_DIR}/setup_${DATE}.log"
    local rc=${PIPESTATUS[0]}
    if [[ ${rc} -eq 0 ]]; then
        log_success "Ansible 环境初始化完成"
    else
        log_error "Ansible 环境初始化失败 (exit: ${rc})"
        exit ${rc}
    fi
}

cmd_deploy() {
    log_info "========== 执行自动化部署 =========="
    
    local tags="${1:-all}"
    local limit="${2:-all}"
    
    log_info "Tags: ${tags}, Limit: ${limit}"
    
    ansible-playbook \
        -i "${ANSIBLE_DIR}/inventory/hosts.yml" \
        "${ANSIBLE_DIR}/playbooks/init-all.yml" \
        --tags "${tags}" \
        --limit "${limit}" \
        -v 2>&1 | tee -a "${LOG_DIR}/deploy_${DATE}.log"
    
    local rc=${PIPESTATUS[0]}
    if [[ ${rc} -eq 0 ]]; then
        log_success "自动化部署完成"
    else
        log_error "自动化部署失败 (exit: ${rc})"
        exit ${rc}
    fi
}

cmd_health() {
    log_info "========== 执行健康巡检 =========="
    bash "${SCRIPT_DIR}/02-health-check.sh" 2>&1 | tee -a "${LOG_DIR}/health_${DATE}.log"
    local rc=${PIPESTATUS[0]}
    if [[ ${rc} -eq 0 ]]; then
        log_success "健康巡检完成，报告已生成"
    else
        log_warn "健康巡检发现问题 (exit: ${rc})"
        exit ${rc}
    fi
}

cmd_clean() {
    log_info "========== 执行日志清理 =========="
    bash "${SCRIPT_DIR}/03-log-cleanup.sh" 2>&1 | tee -a "${LOG_DIR}/cleanup_${DATE}.log"
    local rc=${PIPESTATUS[0]}
    if [[ ${rc} -eq 0 ]]; then
        log_success "日志清理完成"
    else
        log_warn "日志清理完成但有警告 (exit: ${rc})"
    fi
}

cmd_backup() {
    log_info "========== 执行备份与校验 =========="
    bash "${SCRIPT_DIR}/04-backup-verify.sh" 2>&1 | tee -a "${LOG_DIR}/backup_${DATE}.log"
    local rc=${PIPESTATUS[0]}
    if [[ ${rc} -eq 0 ]]; then
        log_success "备份与校验完成"
    else
        log_error "备份与校验失败 (exit: ${rc})"
        exit ${rc}
    fi
}

cmd_full() {
    log_info "========== 执行完整运维流程 =========="
    local start_time=${SECONDS}
    
    cmd_health
    cmd_backup
    cmd_clean
    
    local elapsed=$(( SECONDS - start_time ))
    log_success "完整运维流程完成，耗时: ${elapsed}s"
}

# ========================= 帮助信息 =========================
usage() {
    cat << EOF
================================================================================
  企业级云原生平台 - 自动化运维主脚本
  版本: 1.0.0
================================================================================

用法: $(basename "$0") <command> [options]

命令:
  setup              安装配置 Ansible 环境
  deploy [tags]      执行自动化部署 (可指定 tags 过滤)
  health             执行健康巡检并生成报告
  clean              执行日志清理
  backup             执行备份与完整性校验
  full               执行完整运维流程 (巡检 -> 备份 -> 清理)

选项:
  -e, --env ENV       指定环境 (dev/staging/production)
  -c, --cluster NAME 指定集群名称
  -l, --limit PATTERN 限定执行主机
  -t, --tags TAGS     指定Ansible tags
  -d, --debug         开启调试模式
  -h, --help          显示帮助信息

示例:
  $(basename "$0") setup                    # 初始化Ansible
  $(basename "$0") deploy                   # 全量部署
  $(basename "$0") deploy -t docker         # 仅部署Docker相关
  $(basename "$0") health                   # 健康巡检
  $(basename "$0") full                     # 完整运维流程
  $(basename "$0") deploy -l "webserver"    # 仅对webserver组部署

================================================================================
EOF
}

# ========================= 主函数 =========================
main() {
    local command=""
    local env="production"
    local cluster="default"
    local limit="all"
    local tags="all"
    local debug="false"
    
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            setup|deploy|health|clean|backup|full)
                command="$1"
                shift
                ;;
            -e|--env)
                env="$2"
                shift 2
                ;;
            -c|--cluster)
                cluster="$2"
                shift 2
                ;;
            -l|--limit)
                limit="$2"
                shift 2
                ;;
            -t|--tags)
                tags="$2"
                shift 2
                ;;
            -d|--debug)
                debug="true"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # 设置环境
    export ENVIRONMENT="${env}"
    export CLUSTER_NAME="${cluster}"
    export DEBUG="${debug}"
    
    # 初始化
    init_logging
    load_config
    acquire_lock
    
    log_info "================================================================"
    log_info "  自动化运维平台 - 任务: ${command:-无}"
    log_info "  环境: ${ENVIRONMENT} | 集群: ${CLUSTER_NAME}"
    log_info "  主机: ${HOSTNAME} | 时间: $(date)"
    log_info "================================================================"
    
    # 执行命令
    case "${command}" in
        setup)    cmd_setup ;;
        deploy)   cmd_deploy "${tags}" "${limit}" ;;
        health)   cmd_health ;;
        clean)    cmd_clean ;;
        backup)   cmd_backup ;;
        full)     cmd_full ;;
        *)
            log_error "请指定一个命令"
            usage
            exit 1
            ;;
    esac
    
    release_lock
    log_success "任务执行完毕"
}

main "$@"
