#!/usr/bin/env bash
###############################################################################
# 01-setup-ansible.sh - 安装配置 Ansible 及 SSH 免密
#
# 功能:
#   - 安装 Ansible (pip/yum/apt)
#   - 配置 SSH 免密登录
#   - 配置 Ansible 全局参数
#   - 验证连通性
# 用法: ./01-setup-ansible.sh [options]
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../" && pwd)"
ANSIBLE_DIR="${PROJECT_ROOT}/ansible"
INVENTORY="${ANSIBLE_DIR}/inventory/hosts.yml"
ANSIBLE_CFG="${ANSIBLE_DIR}/ansible.cfg"
SSH_DIR="${HOME}/.ssh"
DATE=$(date +"%Y%m%d_%H%M%S")

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }

# ========================= Ansible 安装 =========================
install_ansible() {
    log_info "安装 Ansible..."
    
    # 优先使用 pip 安装（获取最新版本）
    if command -v pip3 &>/dev/null; then
        log_info "使用 pip3 安装 Ansible..."
        pip3 install --upgrade ansible ansible-core 2>/dev/null || \
        pip3 install --upgrade ansible 2>/dev/null || true
    elif command -v pip &>/dev/null; then
        log_info "使用 pip 安装 Ansible..."
        pip install --upgrade ansible 2>/dev/null || true
    elif command -v yum &>/dev/null; then
        log_info "使用 yum 安装 Ansible..."
        yum install -y epel-release 2>/dev/null || true
        yum install -y ansible 2>/dev/null || true
    elif command -v apt-get &>/dev/null; then
        log_info "使用 apt 安装 Ansible..."
        apt-get update -qq
        apt-get install -y software-properties-common 2>/dev/null || true
        apt-add-repository -y ppa:ansible/ansible 2>/dev/null || true
        apt-get update -qq
        apt-get install -y ansible 2>/dev/null || true
    else
        log_error "无法确定包管理器，请手动安装 Ansible"
        exit 1
    fi
    
    # 验证安装
    if ! command -v ansible &>/dev/null; then
        log_error "Ansible 安装失败"
        exit 1
    fi
    
    local ansible_version
    ansible_version=$(ansible --version 2>/dev/null | head -1 || echo "unknown")
    log_success "Ansible 已安装: ${ansible_version}"
}

# ========================= Ansible 配置 =========================
configure_ansible() {
    log_info "配置 Ansible..."
    
    mkdir -p "${ANSIBLE_DIR}"
    
    cat > "${ANSIBLE_CFG}" << 'EOF'
# Ansible 全局配置 - 企业云原生平台
[defaults]
inventory           = inventory/hosts.yml
remote_user         = root
private_key_file    = ~/.ssh/id_rsa
host_key_checking   = False
timeout             = 30
forks               = 10
retry_files_enabled = False
gathering           = smart
fact_caching        = jsonfile
fact_caching_connection = /tmp/ansible_facts_cache
fact_caching_timeout    = 3600
log_path            = /var/log/ansible.log
stdout_callback     = yaml
callback_whitelist  = timer, profile_tasks
nocows              = 1
deprecation_warnings = False

# 并行与性能
internal_poll_interval = 0.001
command_timeout      = 30
poll_interval        = 5

[privilege_escalation]
become               = True
become_method        = sudo
become_user          = root
become_ask_pass      = False

[ssh_connection]
ssh_args             = -C -o ControlMaster=auto -o ControlPersist=60s -o StrictHostKeyChecking=no
pipelining           = True
control_path         = /tmp/ansible-ssh-%%h-%%p-%%r

[accelerate]
accelerate_port      = 5099
accelerate_timeout   = 30
accelerate_daemon_timeout = 30

[colors]
highlight            = white
verbose              = blue
warn                 = bright purple
error                = red
debug                = dark gray
ok                   = green
changed              = yellow
diff_add             = green
diff_remove          = red
unreachable          = bright red

[different]
host_string_format = %s [PID:%s]
EOF
    
    log_success "Ansible 配置已生成: ${ANSIBLE_CFG}"
}

# ========================= SSH 免密配置 =========================
setup_ssh() {
    log_info "配置 SSH 免密登录..."
    
    mkdir -p "${SSH_DIR}"
    chmod 700 "${SSH_DIR}"
    
    # 生成密钥（如果不存在）
    if [[ ! -f "${SSH_DIR}/id_rsa" ]]; then
        log_info "生成 SSH 密钥对..."
        ssh-keygen -t rsa -b 4096 -N "" -f "${SSH_DIR}/id_rsa" -q
        log_success "SSH 密钥对已生成"
    else
        log_info "SSH 密钥已存在，跳过生成"
    fi
    
    chmod 600 "${SSH_DIR}/id_rsa"
    chmod 644 "${SSH_DIR}/id_rsa.pub"
    
    # 配置 known_hosts
    touch "${SSH_DIR}/known_hosts"
    chmod 644 "${SSH_DIR}/known_hosts"
    
    # 配置 SSH 客户端
    cat > "${SSH_DIR}/config" << 'EOF'
# SSH 客户端配置 - 自动化运维
Host *
    ServerAliveInterval 60
    ServerAliveCountMax 3
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    Compression yes
    TCPKeepAlive yes

Host k8s-master-*
    IdentityFile ~/.ssh/id_rsa
    User root

Host k8s-worker-*
    IdentityFile ~/.ssh/id_rsa
    User root

Host etcd-*
    IdentityFile ~/.ssh/id_rsa
    User root
EOF
    chmod 600 "${SSH_DIR}/config"
    
    log_success "SSH 配置完成"
}

# ========================= 分发公钥 =========================
distribute_keys() {
    log_info "分发 SSH 公钥到各节点..."
    
    if [[ ! -f "${INVENTORY}" ]]; then
        log_warn "主机清单不存在，跳过分发: ${INVENTORY}"
        return 0
    fi
    
    # 从 inventory 提取所有主机
    local hosts
    hosts=$(grep -oP '(?<=ansible_host: )\S+' "${INVENTORY}" 2>/dev/null | sort -u || true)
    
    if [[ -z "${hosts}" ]]; then
        log_warn "未找到主机地址，跳过分发"
        return 0
    fi
    
    local success=0
    local failed=0
    
    while IFS= read -r host; do
        [[ -z "${host}" ]] && continue
        log_info "  分发公钥到: ${host}"
        if ssh-copy-id -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            -i "${SSH_DIR}/id_rsa.pub" "root@${host}" &>/dev/null; then
            ((success++))
            log_success "  ${host} - 成功"
        else
            ((failed++))
            log_warn "  ${host} - 失败 (可能需要手动分发)"
        fi
    done <<< "${hosts}"
    
    log_info "公钥分发结果: 成功=${success}, 失败=${failed}"
}

# ========================= 安装额外工具 =========================
install_tools() {
    log_info "安装额外运维工具..."
    
    local tools=("python3" "jq" "curl" "wget" "net-tools" "sysstat" "htop" "lsof" "telnet" "nc")
    local to_install=()
    
    for tool in "${tools[@]}"; do
        if ! command -v "${tool}" &>/dev/null; then
            to_install+=("${tool}")
        fi
    done
    
    if [[ ${#to_install[@]} -gt 0 ]]; then
        log_info "安装: ${to_install[*]}"
        if command -v yum &>/dev/null; then
            yum install -y "${to_install[@]}" &>/dev/null || true
        elif command -v apt-get &>/dev/null; then
            apt-get install -y "${to_install[@]}" &>/dev/null || true
        fi
    else
        log_info "所有工具已安装"
    fi
    
    # 安装 Python Ansible 依赖
    log_info "安装 Python Ansible 依赖..."
    if command -v pip3 &>/dev/null; then
        pip3 install jinja2 pyyaml kubernetes openshift &>/dev/null || true
    fi
}

# ========================= 验证连通性 =========================
verify_connectivity() {
    log_info "验证 Ansible 连通性..."
    
    if [[ ! -f "${INVENTORY}" ]]; then
        log_warn "主机清单不存在，跳过连通性验证"
        return 0
    fi
    
    if ! ansible all -m ping -i "${INVENTORY}" --timeout=10 2>/dev/null; then
        log_warn "部分主机连通性验证失败"
        log_info "请检查:"
        log_info "  1. SSH 免密是否配置正确"
        log_info "  2. 目标主机是否在线"
        log_info "  3. 防火墙规则是否放行"
        return 1
    fi
    
    log_success "所有主机连通性验证通过"
    return 0
}

# ========================= 主函数 =========================
main() {
    echo "================================================================"
    echo "  Ansible 环境安装配置"
    echo "  时间: $(date)"
    echo "================================================================"
    
    install_ansible
    configure_ansible
    setup_ssh
    install_tools
    distribute_keys
    verify_connectivity
    
    echo ""
    log_success "Ansible 环境配置完成!"
    echo ""
    echo "后续步骤:"
    echo "  1. 确认 inventory/hosts.yml 中的主机信息正确"
    echo "  2. 手动分发公钥: ssh-copy-id root@<target_host>"
    echo "  3. 测试连通: ansible all -m ping -i ansible/inventory/hosts.yml"
    echo "  4. 执行部署: ./deploy-automation.sh deploy"
    echo ""
}

main "$@"
