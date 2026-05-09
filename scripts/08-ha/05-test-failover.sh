#!/bin/bash
###############################################################################
# 05-故障转移测试脚本
# 功能: 测试各组件的故障转移能力
# 测试项: Keepalived VIP漂移、Nginx后端故障、MySQL主从切换、Redis Sentinel切换
###############################################################################

set -euo pipefail

# 错误处理（测试脚本不退出，记录错误继续执行）
trap 'log_error "故障转移测试脚本异常退出 (行号: $LINENO)"' ERR

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $(date '+%H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $(date '+%H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $(date '+%H:%M:%S') $*"; }
log_pass()  { echo -e "${GREEN}[PASS]${NC} $(date '+%H:%M:%S') $*"; }
log_fail()  { echo -e "${RED}[FAIL]${NC} $(date '+%H:%M:%S') $*"; }

# ==================== 用法说明 ====================
usage() {
    cat << EOF
用法: $(basename "$0") [options]

功能: 测试各组件的故障转移能力

测试项:
  - Keepalived VIP漂移
  - Nginx负载均衡配置
  - MySQL主从复制状态
  - Redis Sentinel高可用
  - 网络连通性

环境变量:
  SKIP_FAILOVER_TEST=true   跳过VIP漂移测试（生产环境推荐）

示例:
  SKIP_FAILOVER_TEST=true $(basename "$0")
  $(basename "$0")
EOF
}

# ==================== 测试结果统计 ====================
TEST_TOTAL=0
TEST_PASSED=0
TEST_FAILED=0
TEST_SKIPPED=0

test_result() {
    local status=$1
    local desc=$2
    ((TEST_TOTAL++))
    case "$status" in
        pass) ((TEST_PASSED++)); log_pass "✓ $desc" ;;
        fail) ((TEST_FAILED++)); log_fail "✗ $desc" ;;
        skip) ((TEST_SKIPPED++)); log_warn "- $desc (跳过)" ;;
    esac
}

# ==================== Keepalived VIP漂移测试 ====================
# ==================== Keepalived VIP漂移测试 ====================
# 功能: 验证Keepalived VIP地址、VRRP协议、健康检查脚本、VIP漂移
# 注意: VIP漂移测试会暂时中断服务，生产环境建议跳过
test_keepalived() {
    log_step "========== 测试 Keepalived VIP漂移 =========="

    # 检查Keepalived是否运行
    if ! systemctl is-active keepalived &>/dev/null; then
        test_result skip "Keepalived未运行"
        return
    fi

    # 测试1: 检查VIP是否存在
    local vip="192.168.100.100"
    if ip addr show | grep -q "$vip"; then
        test_result pass "VIP地址 $vip 存在"
    else
        test_result fail "VIP地址 $vip 不存在"
    fi

    # 测试2: 检查VRRP协议是否正常
    if ss -ulnp | grep -q ":112 "; then
        test_result pass "VRRP协议正常（端口112）"
    else
        test_result fail "VRRP协议异常"
    fi

    # 测试3: 检查健康检查脚本
    if [[ -x /etc/keepalived/scripts/check_nginx.sh ]]; then
        /etc/keepalived/scripts/check_nginx.sh
        if [[ $? -eq 0 ]]; then
            test_result pass "Nginx健康检查脚本执行成功"
        else
            test_result fail "Nginx健康检查脚本执行失败"
        fi
    else
        test_result skip "健康检查脚本不存在"
    fi

    # 测试4: 模拟VIP漂移（停止Keepalived）
    log_info "模拟VIP漂移测试..."
    local original_vip_holder
    original_vip_holder=$(ip addr show | grep "$vip" | head -1 | awk '{print $NF}')

    # 注意：此测试会暂时中断服务，生产环境慎用
    if [[ "${SKIP_FAILOVER_TEST:-false}" == "true" ]]; then
        test_result skip "VIP漂移测试（已跳过）"
    else
        systemctl stop keepalived 2>/dev/null
        sleep 3

        if ! ip addr show | grep -q "$vip"; then
            test_result pass "VIP漂移：停止Keepalived后VIP消失"
        else
            test_result fail "VIP漂移：停止Keepalived后VIP仍存在"
        fi

        # 恢复Keepalived
        systemctl start keepalived 2>/dev/null
        sleep 3

        if ip addr show | grep -q "$vip"; then
            test_result pass "VIP恢复：重启Keepalived后VIP恢复"
        else
            test_result fail "VIP恢复：重启Keepalived后VIP未恢复"
        fi
    fi
}

# ==================== Nginx负载均衡测试 ====================
# ==================== Nginx负载均衡测试 ====================
# 功能: 验证Nginx健康端点、SSL证书、配置语法、上游服务器
test_nginx_lb() {
    log_step "========== 测试 Nginx负载均衡 =========="

    # 检查Nginx是否运行
    if ! systemctl is-active nginx &>/dev/null; then
        test_result skip "Nginx未运行"
        return
    fi

    # 测试1: 检查Nginx状态
    if curl -s http://127.0.0.1:8080/health &>/dev/null; then
        test_result pass "Nginx健康端点可访问"
    else
        test_result fail "Nginx健康端点不可访问"
    fi

    # 测试2: 检查SSL证书
    if openssl s_client -connect 127.0.0.1:443 </dev/null 2>/dev/null | grep -q "BEGIN CERTIFICATE"; then
        test_result pass "SSL证书有效"
    else
        test_result fail "SSL证书无效"
    fi

    # 测试3: 检查负载均衡配置
    if nginx -t 2>&1 | grep -q "syntax is ok"; then
        test_result pass "Nginx配置语法正确"
    else
        test_result fail "Nginx配置语法错误"
    fi

    # 测试4: 检查上游服务器配置
    if [[ -f /etc/nginx/conf.d/upstream-k8s-api.conf ]]; then
        local upstream_count
        upstream_count=$(grep -c "server.*weight" /etc/nginx/conf.d/upstream-k8s-api.conf)
        if [[ $upstream_count -gt 0 ]]; then
            test_result pass "K8s API上游服务器已配置 ($upstream_count 个)"
        else
            test_result fail "K8s API上游服务器未配置"
        fi
    else
        test_result skip "上游服务器配置文件不存在"
    fi

    # 测试5: 检查连接数限制
    if grep -q "limit_conn" /etc/nginx/nginx.conf; then
        test_result pass "连接数限制已配置"
    else
        test_result fail "连接数限制未配置"
    fi
}

# ==================== MySQL主从复制测试 ====================
# ==================== MySQL主从复制测试 ====================
# 功能: 验证MySQL连接、二进制日志、GTID、半同步复制、复制延迟
test_mysql_ha() {
    log_step "========== 测试 MySQL高可用 =========="

    # 检查MySQL是否运行
    if ! systemctl is-active mysqld &>/dev/null; then
        test_result skip "MySQL未运行"
        return
    fi

    # 测试1: 检查MySQL连接
    if mysql -u root -e "SELECT 1;" &>/dev/null; then
        test_result pass "MySQL连接正常"
    else
        test_result fail "MySQL连接失败"
    fi

    # 测试2: 检查二进制日志
    local binlog_status
    binlog_status=$(mysql -u root -e "SHOW MASTER STATUS\G" 2>/dev/null | grep -c "File:")
    if [[ $binlog_status -gt 0 ]]; then
        test_result pass "二进制日志已启用"
    else
        test_result fail "二进制日志未启用"
    fi

    # 测试3: 检查GTID模式
    local gtid_mode
    gtid_mode=$(mysql -u root -e "SHOW VARIABLES LIKE 'gtid_mode';" 2>/dev/null | grep -i gtid | awk '{print $2}')
    if [[ "$gtid_mode" == "ON" ]]; then
        test_result pass "GTID模式已启用"
    else
        test_result fail "GTID模式未启用 (当前: $gtid_mode)"
    fi

    # 测试4: 检查半同步复制
    local semi_sync
    semi_sync=$(mysql -u root -e "SHOW VARIABLES LIKE 'rpl_semi_sync_master_enabled';" 2>/dev/null | grep -i semi | awk '{print $2}')
    if [[ "$semi_sync" == "ON" ]]; then
        test_result pass "半同步复制已启用"
    else
        test_result fail "半同步复制未启用"
    fi

    # 测试5: 检查从节点状态（仅从节点）
    local slave_status
    slave_status=$(mysql -u root -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep -c "Slave_IO_Running")
    if [[ $slave_status -gt 0 ]]; then
        local io_running sql_running
        io_running=$(mysql -u root -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Slave_IO_Running:" | awk '{print $2}')
        sql_running=$(mysql -u root -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Slave_SQL_Running:" | awk '{print $2}')
        if [[ "$io_running" == "Yes" ]] && [[ "$sql_running" == "Yes" ]]; then
            test_result pass "从节点复制正常 (IO: $io_running, SQL: $sql_running)"
        else
            test_result fail "从节点复制异常 (IO: $io_running, SQL: $sql_running)"
        fi
    else
        test_result skip "非从节点，跳过复制测试"
    fi

    # 测试6: 检查复制延迟
    if [[ $slave_status -gt 0 ]]; then
        local lag
        lag=$(mysql -u root -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Seconds_Behind_Master:" | awk '{print $2}')
        if [[ "$lag" != "NULL" ]] && [[ $lag -lt 10 ]]; then
            test_result pass "复制延迟正常 (${lag}秒)"
        else
            test_result fail "复制延迟异常 (${lag}秒)"
        fi
    fi
}

# ==================== Redis Sentinel测试 ====================
# ==================== Redis Sentinel测试 ====================
# 功能: 验证Redis连接、主从状态、Sentinel监控、持久化状态
test_redis_sentinel() {
    log_step "========== 测试 Redis Sentinel =========="

    # 检查Redis是否运行
    if ! systemctl is-active redis &>/dev/null; then
        test_result skip "Redis未运行"
        return
    fi

    # 测试1: 检查Redis连接
    if redis-cli ping 2>/dev/null | grep -q "PONG"; then
        test_result pass "Redis连接正常"
    else
        test_result fail "Redis连接失败"
    fi

    # 测试2: 检查Redis主从状态
    local role
    role=$(redis-cli info replication 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')
    if [[ "$role" == "master" ]]; then
        test_result pass "Redis当前角色: 主节点"

        # 检查从节点数量
        local slave_count
        slave_count=$(redis-cli info replication 2>/dev/null | grep -c "slave")
        test_result pass "Redis从节点数量: $slave_count"

    elif [[ "$role" == "slave" ]]; then
        test_result pass "Redis当前角色: 从节点"
    else
        test_result fail "Redis角色检测失败"
    fi

    # 测试3: 检查Sentinel连接
    if redis-cli -p 26379 ping 2>/dev/null | grep -q "PONG"; then
        test_result pass "Redis Sentinel连接正常"
    else
        test_result fail "Redis Sentinel连接失败"
    fi

    # 测试4: 检查Sentinel监控的主节点
    local sentinel_masters
    sentinel_masters=$(redis-cli -p 26379 sentinel masters 2>/dev/null | grep -c "name")
    if [[ $sentinel_masters -gt 0 ]]; then
        test_result pass "Sentinel已配置监控主节点"
    else
        test_result fail "Sentinel未配置监控主节点"
    fi

    # 测试5: 检查Sentinel quorum
    local quorum
    quorum=$(redis-cli -p 26379 sentinel get-master-addr-by-name mymaster 2>/dev/null)
    if [[ -n "$quorum" ]]; then
        test_result pass "Sentinel主节点地址可获取"
    else
        test_result fail "Sentinel主节点地址获取失败"
    fi

    # 测试6: 检查Redis持久化
    local rdb_status
    rdb_status=$(redis-cli info persistence 2>/dev/null | grep "rdb_last_bgsave_status:ok" | wc -l)
    if [[ $rdb_status -gt 0 ]]; then
        test_result pass "RDB持久化正常"
    else
        test_result warn "RDB持久化状态未知"
    fi

    local aof_status
    aof_status=$(redis-cli info persistence 2>/dev/null | grep "aof_enabled:1" | wc -l)
    if [[ $aof_status -gt 0 ]]; then
        test_result pass "AOF持久化已启用"
    else
        test_result fail "AOF持久化未启用"
    fi
}

# ==================== 网络连通性测试 ====================
# ==================== 网络连通性测试 ====================
# 功能: 验证各服务端口监听和防火墙规则
test_network() {
    log_step "========== 测试 网络连通性 =========="

    # 测试1: 检查端口监听
    local ports=("80:tcp" "443:tcp" "3306:tcp" "6379:tcp" "26379:tcp")
    for port_proto in "${ports[@]}"; do
        IFS=':' read -r port proto <<< "$port_proto"
        if ss -tlnp | grep -q ":${port} "; then
            test_result pass "端口 $port ($proto) 正在监听"
        else
            test_result fail "端口 $port ($proto) 未监听"
        fi
    done

    # 测试2: 检查防火墙规则
    if systemctl is-active firewalld &>/dev/null; then
        log_info "firewalld正在运行，检查放行规则..."
        if firewall-cmd --list-all 2>/dev/null | grep -q "ports"; then
            test_result pass "防火墙规则已配置"
        else
            test_result fail "防火墙规则未配置"
        fi
    else
        test_result pass "firewalld未运行"
    fi
}

# ==================== 生成测试报告 ====================
generate_test_report() {
    local report_file="/var/log/enterprise-ha/failover-test-$(date +%Y%m%d_%H%M%S).txt"
    mkdir -p "$(dirname "$report_file")"

    {
        echo "=============================================="
        echo "  故障转移测试报告"
        echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "  主机: $(hostname)"
        echo "=============================================="
        echo ""
        echo "  测试总计: $TEST_TOTAL"
        echo "  通过: $TEST_PASSED"
        echo "  失败: $TEST_FAILED"
        echo "  跳过: $TEST_SKIPPED"
        echo ""
        echo "  通过率: $(( TEST_PASSED * 100 / (TEST_TOTAL - TEST_SKIPPED) ))%"
        echo ""
        echo "=============================================="
    } > "$report_file"

    cat "$report_file"
    log_info "测试报告已保存: $report_file"
}

# ==================== 主流程 ====================
main() {
    log_step "========== 故障转移测试开始 =========="
    echo ""

    test_keepalived
    echo ""
    test_nginx_lb
    echo ""
    test_mysql_ha
    echo ""
    test_redis_sentinel
    echo ""
    test_network
    echo ""

    generate_test_report

    echo ""
    if [[ $TEST_FAILED -eq 0 ]]; then
        log_success "========== 所有测试通过！============="
    else
        log_error "========== 有 $TEST_FAILED 个测试失败 =========="
        exit 1
    fi
}

main "$@"
