#!/bin/bash
###############################################################################
# 07-验证数据一致性脚本
# 功能: 验证PostgreSQL主从数据一致性
# 特性: 复制延迟检查、行数对比、WAL同步验证、写入测试
# 版本: 1.1.0
# 作者: 运维平台团队
###############################################################################

set -euo pipefail
umask 077

# 锁文件
LOCK_FILE="/tmp/07-verify-data-consistency.lock"

# 清理函数
cleanup() {
    rm -f "$LOCK_FILE"
    echo -e "\033[0;33m[INFO]\033[0m 清理完成"
}

# 错误处理
trap 'echo -e "\033[0;31m[ERROR]\033[0m 数据一致性验证脚本异常退出 (行号: $LINENO)" >&2; cleanup' ERR
trap cleanup EXIT SIGINT SIGTERM

# 检查root权限
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[0;31m[ERROR]\033[0m 此脚本需要root权限运行" >&2
    exit 1
fi

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
LOG_DIR="${PROJECT_ROOT}/logs/08-ha/"
REPORT_DIR="${PROJECT_ROOT}/reports"

# 连接参数
MASTER_HOST="${MASTER_HOST:-192.168.100.10}"
MASTER_PORT="${MASTER_PORT:-5432}"
SLAVE_HOST="${SLAVE_HOST:-192.168.100.11}"
SLAVE_PORT="${SLAVE_PORT:-5432}"
PG_USER="${PG_USER:-postgres}"
PG_DB="${PG_DB:-postgres}"

# 阈值配置
MAX_REPL_LAG_BYTES="${MAX_REPL_LAG_BYTES:-1048576}"  # 1MB
MAX_REPL_LAG_TIME="${MAX_REPL_LAG_TIME:-10}"  # 10秒

# 验证计数器
TOTAL_CHECKS=0
PASS_CHECKS=0
FAIL_CHECKS=0
WARN_CHECKS=0

# ==================== 用法说明 ====================
usage() {
    cat << EOF
用法: $(basename "$0") [options]

功能: 验证PostgreSQL主从数据一致性

选项:
  --master-host <IP>       主节点IP（默认: 192.168.100.10）
  --master-port <PORT>     主节点端口（默认: 5432）
  --slave-host <IP>        从节点IP（默认: 192.168.100.11）
  --slave-port <PORT>      从节点端口（默认: 5432）
  --pg-user <user>         PostgreSQL用户（默认: postgres）
  --pg-db <db>             数据库名（默认: postgres）
  --help                   显示此帮助信息

验证项目:
  1. 复制延迟检查 (pg_stat_replication)
  2. 关键表行数对比
  3. WAL位置同步验证
  4. 复制冲突检查
  5. 写入测试验证
  6. 生成详细对比报告

示例:
  $(basename "$0")
  $(basename "$0") --master-host 10.0.0.10 --slave-host 10.0.0.11
EOF
    exit 0
}

# ==================== 参数解析 ====================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --master-host) MASTER_HOST="$2"; shift 2 ;;
            --master-port) MASTER_PORT="$2"; shift 2 ;;
            --slave-host)  SLAVE_HOST="$2"; shift 2 ;;
            --slave-port)  SLAVE_PORT="$2"; shift 2 ;;
            --pg-user)     PG_USER="$2"; shift 2 ;;
            --pg-db)       PG_DB="$2"; shift 2 ;;
            --help|-h)     usage ;;
            *) log_error "未知参数: $1"; usage ;;
        esac
    done
}

# ==================== 辅助函数 ====================
record_check() {
    local status=$1  # pass/fail/warn
    local message=$2
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    case "$status" in
        pass)
            PASS_CHECKS=$((PASS_CHECKS + 1))
            echo -e "${GREEN}[PASS]${NC}  $message"
            ;;
        fail)
            FAIL_CHECKS=$((FAIL_CHECKS + 1))
            echo -e "${RED}[FAIL]${NC}  $message"
            ;;
        warn)
            WARN_CHECKS=$((WARN_CHECKS + 1))
            echo -e "${YELLOW}[WARN]${NC}  $message"
            ;;
    esac
}

# 执行SQL查询（主节点）
exec_master_sql() {
    local sql=$1
    if command -v psql &>/dev/null; then
        psql -h "$MASTER_HOST" -p "$MASTER_PORT" -U "$PG_USER" -d "$PG_DB" -t -A -c "$sql" 2>/dev/null
    elif command -v docker &>/dev/null; then
        docker exec -i postgres-master psql -U "$PG_USER" -d "$PG_DB" -t -A -c "$sql" 2>/dev/null
    else
        log_error "无法连接到主节点（psql或docker不可用）"
        return 1
    fi
}

# 执行SQL查询（从节点）
exec_slave_sql() {
    local sql=$1
    if command -v psql &>/dev/null; then
        psql -h "$SLAVE_HOST" -p "$SLAVE_PORT" -U "$PG_USER" -d "$PG_DB" -t -A -c "$sql" 2>/dev/null
    elif command -v docker &>/dev/null; then
        docker exec -i postgres-slave psql -U "$PG_USER" -d "$PG_DB" -t -A -c "$sql" 2>/dev/null
    else
        log_error "无法连接到从节点（psql或docker不可用）"
        return 1
    fi
}

# ==================== 检查1: 复制延迟 ====================
check_replication_lag() {
    log_step "[1/6] 检查复制延迟..."

    local repl_info
    repl_info=$(exec_master_sql "
SELECT
    application_name,
    client_addr,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    pg_wal_lsn_diff(sent_lsn, replay_lsn) AS replay_lag_bytes
FROM pg_stat_replication;
" 2>/dev/null || echo "")

    if [[ -z "$repl_info" ]]; then
        record_check "fail" "无法获取复制状态信息"
        return 1
    fi

    # 解析复制信息
    echo "$repl_info" | while IFS='|' read -r app_name client_addr state sent write flush replay lag_bytes; do
        [[ -z "$app_name" ]] && continue

        log_info "从库连接: $app_name ($client_addr)"
        log_info "  状态: $state"
        log_info "  发送LSN: $sent"
        log_info "  写入LSN: $write"
        log_info "  刷新LSN: $flush"
        log_info "  重放LSN: $replay"
        log_info "  重放延迟: ${lag_bytes} bytes"

        if [[ -n "$lag_bytes" ]]; then
            if [[ "$lag_bytes" -gt "$MAX_REPL_LAG_BYTES" ]]; then
                record_check "warn" "复制延迟超过阈值: ${lag_bytes} bytes (阈值: ${MAX_REPL_LAG_BYTES})"
            else
                record_check "pass" "复制延迟正常: ${lag_bytes} bytes"
            fi
        fi
    done
}

# ==================== 检查2: 行数对比 ====================
check_row_counts() {
    log_step "[2/6] 对比关键表行数..."

    # 获取主节点的表列表
    local tables
    tables=$(exec_master_sql "
SELECT tablename
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY tablename;
" 2>/dev/null || echo "")

    if [[ -z "$tables" ]]; then
        log_info "主节点无用户表，跳过行数对比"
        record_check "pass" "无用户表需要对比"
        return 0
    fi

    local table_count=0
    local match_count=0

    while IFS= read -r table; do
        [[ -z "$table" ]] && continue
        table_count=$((table_count + 1))

        # 获取主节点行数
        local master_count
        master_count=$(exec_master_sql "SELECT count(*) FROM ${table};" 2>/dev/null || echo "-1")

        # 获取从节点行数
        local slave_count
        slave_count=$(exec_slave_sql "SELECT count(*) FROM ${table};" 2>/dev/null || echo "-1")

        if [[ "$master_count" == "-1" || "$slave_count" == "-1" ]]; then
            record_check "warn" "表 ${table}: 无法获取行数信息"
            continue
        fi

        if [[ "$master_count" == "$slave_count" ]]; then
            record_check "pass" "表 ${table}: 行数一致 (${master_count})"
            match_count=$((match_count + 1))
        else
            record_check "fail" "表 ${table}: 行数不一致 (主: ${master_count}, 从: ${slave_count})"
        fi
    done <<< "$tables"

    if [[ $table_count -gt 0 ]]; then
        log_info "行数对比完成: ${match_count}/${table_count} 表一致"
    fi
}

# ==================== 检查3: WAL位置同步 ====================
check_wal_sync() {
    log_step "[3/6] 检查WAL位置同步..."

    # 获取主节点当前WAL位置
    local master_lsn
    master_lsn=$(exec_master_sql "SELECT pg_current_wal_lsn();" 2>/dev/null || echo "")

    # 获取从节点接收的WAL位置
    local slave_lsn
    slave_lsn=$(exec_slave_sql "SELECT pg_last_wal_receive_lsn();" 2>/dev/null || echo "")

    # 获取从节点重放的WAL位置
    local slave_replay_lsn
    slave_replay_lsn=$(exec_slave_sql "SELECT pg_last_wal_replay_lsn();" 2>/dev/null || echo "")

    if [[ -z "$master_lsn" ]]; then
        record_check "fail" "无法获取主节点WAL位置"
        return 1
    fi

    log_info "主节点WAL位置: $master_lsn"
    log_info "从节点接收位置: $slave_lsn"
    log_info "从节点重放位置: $slave_replay_lsn"

    # 计算WAL差异
    local wal_diff
    wal_diff=$(exec_master_sql "
SELECT pg_wal_lsn_diff(
    pg_current_wal_lsn(),
    '${slave_replay_lsn:-0/0}'
);" 2>/dev/null || echo "-1")

    if [[ "$wal_diff" == "-1" ]]; then
        record_check "warn" "无法计算WAL差异"
    elif [[ "$wal_diff" -le 0 ]]; then
        record_check "pass" "WAL同步正常 (差异: 0 bytes)"
    elif [[ "$wal_diff" -lt "$MAX_REPL_LAG_BYTES" ]]; then
        record_check "pass" "WAL同步正常 (差异: ${wal_diff} bytes)"
    else
        record_check "fail" "WAL同步延迟 (差异: ${wal_diff} bytes)"
    fi
}

# ==================== 检查4: 复制冲突检查 ====================
check_replication_conflicts() {
    log_step "[4/6] 检查复制冲突..."

    # 检查复制槽
    local replication_slots
    replication_slots=$(exec_master_sql "
SELECT
    slot_name,
    slot_type,
    active,
    xmin,
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS retained_bytes
FROM pg_replication_slots;
" 2>/dev/null || echo "")

    if [[ -n "$replication_slots" ]]; then
        echo "$replication_slots" | while IFS='|' read -r slot_name slot_type active xmin retained; do
            [[ -z "$slot_name" ]] && continue

            log_info "复制槽: $slot_name (类型: $slot_type, 活跃: $active)"
            if [[ -n "$retained" && "$retained" -gt 0 ]]; then
                log_info "  保留WAL: ${retained} bytes"
            fi
        done
    fi

    # 检查复制延迟查询
    local lag_queries
    lag_queries=$(exec_slave_sql "
SELECT count(*)
FROM pg_stat_activity
WHERE wait_event_type = 'Replication'
  AND state = 'active';
" 2>/dev/null || echo "0")

    if [[ "$lag_queries" -gt 0 ]]; then
        log_info "当前有 ${lag_queries} 个复制等待事件"
    fi

    # 检查冲突统计
    local conflict_count
    conflict_count=$(exec_master_sql "
SELECT
    COALESCE(sum(confl_tablespace), 0) +
    COALESCE(sum(confl_lock), 0) +
    COALESCE(sum(confl_snapshot), 0) +
    COALESCE(sum(confl_bufferpin), 0) +
    COALESCE(sum(confl_deadlock), 0) AS total_conflicts
FROM pg_stat_database;
" 2>/dev/null || echo "0")

    if [[ "$conflict_count" -gt 0 ]]; then
        record_check "warn" "检测到复制冲突: ${conflict_count} 次"
    else
        record_check "pass" "无复制冲突"
    fi
}

# ==================== 检查5: 写入测试 ====================
test_write_consistency() {
    log_step "[5/6] 写入一致性测试..."

    local test_table="_replication_test_$(date +%s)"
    local test_value="test_$(date +%s%N)"

    # 在主节点创建测试表
    exec_master_sql "
CREATE TABLE IF NOT EXISTS ${test_table} (
    id SERIAL PRIMARY KEY,
    test_value TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);
" 2>/dev/null

    # 在主节点插入测试数据
    exec_master_sql "
INSERT INTO ${test_table} (test_value) VALUES ('${test_value}');
" 2>/dev/null

    log_info "已在主节点插入测试数据: ${test_value}"

    # 等待复制同步
    local max_wait=10
    local waited=0
    local found=false

    while [[ $waited -lt $max_wait ]]; do
        sleep 1
        waited=$((waited + 1))

        local slave_result
        slave_result=$(exec_slave_sql "
SELECT test_value FROM ${test_table} WHERE test_value = '${test_value}';
" 2>/dev/null || echo "")

        if [[ "$slave_result" == "$test_value" ]]; then
            found=true
            break
        fi
    done

    if [[ "$found" == true ]]; then
        record_check "pass" "写入一致性测试通过 (延迟: ${waited}秒)"
    else
        record_check "fail" "写入一致性测试失败 - 从节点未同步"
    fi

    # 清理测试表
    exec_master_sql "DROP TABLE IF EXISTS ${test_table};" 2>/dev/null || true
    log_info "已清理测试表"
}

# ==================== 检查6: 数据库状态概览 ====================
check_database_overview() {
    log_step "[6/6] 数据库状态概览..."

    # 主节点状态
    local master_status
    master_status=$(exec_master_sql "
SELECT
    (SELECT count(*) FROM pg_stat_activity WHERE state = 'active') AS active_conns,
    (SELECT count(*) FROM pg_stat_activity) AS total_conns,
    (SELECT pg_size_pretty(pg_database_size('${PG_DB}'))) AS db_size;
" 2>/dev/null || echo "0|0|unknown")

    log_info "主节点状态: $master_status"

    # 从节点状态
    local slave_status
    slave_status=$(exec_slave_sql "
SELECT
    (SELECT count(*) FROM pg_stat_activity WHERE state = 'active') AS active_conns,
    (SELECT count(*) FROM pg_stat_activity) AS total_conns,
    (SELECT pg_size_pretty(pg_database_size('${PG_DB}'))) AS db_size;
" 2>/dev/null || echo "0|0|unknown")

    log_info "从节点状态: $slave_status"

    record_check "pass" "数据库状态概览完成"
}

# ==================== 生成验证报告 ====================
generate_report() {
    local report_file="${REPORT_DIR}/data-consistency-$(date +%Y%m%d-%H%M%S).txt"
    mkdir -p "$REPORT_DIR"

    cat > "$report_file" <<REPORT
=================================================================
PostgreSQL 数据一致性验证报告
生成时间: $(date '+%Y-%m-%d %H:%M:%S')
=================================================================

验证配置:
  主节点: ${MASTER_HOST}:${MASTER_PORT}
  从节点: ${SLAVE_HOST}:${SLAVE_PORT}
  数据库: ${PG_DB}
  用户:   ${PG_USER}

验证结果:
  总检查项: ${TOTAL_CHECKS}
  通过:     ${PASS_CHECKS}
  失败:     ${FAIL_CHECKS}
  警告:     ${WARN_CHECKS}

阈值配置:
  最大复制延迟(bytes): ${MAX_REPL_LAG_BYTES}
  最大复制延迟(秒):   ${MAX_REPL_LAG_TIME}

结论: $(if [[ $FAIL_CHECKS -eq 0 ]]; then
    if [[ $WARN_CHECKS -eq 0 ]]; then
        echo "数据一致性验证通过"
    else
        echo "数据一致性验证通过(存在警告)"
    fi
else
    echo "数据一致性验证失败 - 存在不一致"
fi)

=================================================================
REPORT

    log_info "验证报告已保存: $report_file"
}

# ==================== 主函数 ====================
main() {
    parse_args "$@"

    echo ""
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${CYAN}  PostgreSQL 数据一致性验证${NC}"
    echo -e "${CYAN}  版本: 1.1.0${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo ""

    # 执行验证步骤
    check_replication_lag
    check_row_counts
    check_wal_sync
    check_replication_conflicts
    test_write_consistency
    check_database_overview

    # 生成报告
    generate_report

    # 输出汇总
    echo ""
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${CYAN}  验证汇总${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo -e "  总检查项: ${TOTAL_CHECKS}"
    echo -e "  ${GREEN}通过:     ${PASS_CHECKS}${NC}"
    echo -e "  ${RED}失败:     ${FAIL_CHECKS}${NC}"
    echo -e "  ${YELLOW}警告:     ${WARN_CHECKS}${NC}"
    echo -e "${CYAN}================================================================${NC}"

    if [[ $FAIL_CHECKS -gt 0 ]]; then
        echo -e "\n${RED}数据一致性验证失败!${NC}"
        exit 1
    elif [[ $WARN_CHECKS -gt 0 ]]; then
        echo -e "\n${YELLOW}数据一致性验证通过(存在警告)${NC}"
        exit 0
    else
        echo -e "\n${GREEN}数据一致性验证通过!${NC}"
        exit 0
    fi
}

# 执行主函数
main "$@"
