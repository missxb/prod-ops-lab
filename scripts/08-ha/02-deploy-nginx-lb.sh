#!/bin/bash
###############################################################################
# 02-部署Nginx负载均衡脚本
# 功能: 部署Nginx作为7层负载均衡器，代理K8s API Server和应用服务
# 特性: 7层LB、健康检查、SSL终止、WebSocket支持、速率限制
###############################################################################

set -euo pipefail

# 错误处理
trap 'log_error "Nginx LB部署脚本异常退出 (行号: $LINENO)"' ERR

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

# ==================== 用法说明 ====================
usage() {
    cat << EOF
用法: $(basename "$0") [options]

功能: 部署Nginx作为7层负载均衡器

环境变量:
  K8S_API_SERVERS   K8s API服务器列表（逗号分隔）
  APP_SERVERS        应用服务器列表（逗号分隔）
  LB_ADDRESS         监听地址（默认: 0.0.0.0）
  LB_PORT            HTTP端口（默认: 80）
  LB_SSL_PORT        HTTPS端口（默认: 443）

示例:
  K8S_API_SERVERS=10.0.0.1:6443,10.0.0.2:6443 $(basename "$0")
EOF
}

# ==================== 配置变量 ====================
NGINX_VERSION="${NGINX_VERSION:-1.24.0}"
NGINX_CONF_DIR="/etc/nginx"
NGINX_HTML_DIR="/usr/share/nginx/html"
NGINX_LOG_DIR="/var/log/nginx"
SSL_DIR="/etc/nginx/ssl"

# 上游服务器配置
K8S_API_SERVERS="${K8S_API_SERVERS:-192.168.100.10:6443,192.168.100.11:6443,192.168.100.12:6443}"
APP_SERVERS="${APP_SERVERS:-192.168.100.20:8080,192.168.100.21:8080,192.168.100.22:8080}"
LB_ADDRESS="${LB_ADDRESS:-0.0.0.0}"
LB_PORT="${LB_PORT:-80}"
LB_SSL_PORT="${LB_SSL_PORT:-443}"

# ==================== 安装Nginx ====================
install_nginx() {
    log_step "[1/5] 安装Nginx..."

    if command -v nginx &>/dev/null; then
        local installed_version
        installed_version=$(nginx -v 2>&1 | awk -F'/' '{print $2}')
        log_info "Nginx已安装，版本: $installed_version"
    else
        log_info "开始安装Nginx..."

        if [[ -f /etc/redhat-release ]]; then
            # 安装稳定版Nginx
            cat > /etc/yum.repos.d/nginx.repo <<'EOF'
[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF
            yum install -y nginx 2>&1 | tail -3
        elif [[ -f /etc/debian_version ]]; then
            apt-get update -qq
            apt-get install -y nginx 2>&1 | tail -3
        else
            log_error "不支持的操作系统"
            exit 1
        fi
    fi

    log_info "Nginx安装完成"
}

# ==================== 创建目录结构 ====================
create_directories() {
    log_step "[2/5] 创建目录结构..."

    local dirs=(
        "$NGINX_CONF_DIR/conf.d"
        "$NGINX_CONF_DIR/stream.d"
        "$NGINX_CONF_DIR/ssl"
        "$NGINX_CONF_DIR/certs"
        "$NGINX_HTML_DIR"
        "$NGINX_LOG_DIR"
        "$NGINX_LOG_DIR/access"
        "$NGINX_LOG_DIR/error"
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
    done

    # 创建Nginx用户（如不存在）
    if ! id -u nginx &>/dev/null; then
        useradd -r -s /sbin/nologin -d /var/cache/nginx nginx
    fi

    log_info "目录结构创建完成"
}

# ==================== 生成SSL证书（自签名，用于开发） ====================
generate_ssl_cert() {
    log_step "[3/5] 生成SSL证书..."

    if [[ -f "$SSL_DIR/server.crt" ]] && [[ -f "$SSL_DIR/server.key" ]]; then
        log_info "SSL证书已存在，跳过生成"
        return
    fi

    log_info "生成自签名SSL证书（开发环境）..."

    openssl req -x509 -nodes -days 365 \
        -newkey rsa:2048 \
        -keyout "$SSL_DIR/server.key" \
        -out "$SSL_DIR/server.crt" \
        -subj "/C=CN/ST=Beijing/L=Beijing/O=Enterprise/CN=k8s-api.example.com" \
        2>/dev/null

    # 生成DH参数（增强SSL安全）
    if [[ ! -f "$SSL_DIR/dhparam.pem" ]]; then
        openssl dhparam -out "$SSL_DIR/dhparam.pem" 2048 2>/dev/null &
        log_info "DH参数生成中（后台运行）..."
    fi

    chmod 600 "$SSL_DIR/server.key"
    log_info "SSL证书生成完成"
}

# ==================== 生成Nginx负载均衡配置 ====================
generate_config() {
    log_step "[4/5] 生成Nginx负载均衡配置..."

    # 解析上游服务器列表
    IFS=',' read -ra K8S_NODES <<< "$K8S_API_SERVERS"
    IFS=',' read -ra APP_NODES <<< "$APP_SERVERS"

    # 主配置文件
    cat > "$NGINX_CONF_DIR/nginx.conf" <<'CONF'
###############################################################################
# Nginx 高可用负载均衡配置
# 项目: 企业级云原生运维平台
# 功能: 7层负载均衡，K8s API Server代理，SSL终止
###############################################################################

# 工作进程数（auto=CPU核心数）
worker_processes auto;

# 错误日志
error_log /var/log/nginx/error.log warn;

# PID文件
pid /var/run/nginx.pid;

# 工作进程打开文件数限制
worker_rlimit_nofile 65535;

events {
    # 每个工作进程最大连接数
    worker_connections 4096;

    # 使用epoll事件模型（Linux）
    use epoll;

    # 允许同时接受多个连接
    multi_accept on;

    # 开启高效文件传输
    sendfile on;
}

http {
    # ==================== 基本配置 ====================
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # 日志格式（包含上游服务器信息）
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for" '
                    'upstream=$upstream_addr '
                    'upstream_status=$upstream_status '
                    'upstream_response_time=$upstream_response_time '
                    'request_time=$request_time';

    # 访问日志
    access_log /var/log/nginx/access.log main buffer=32k flush=5s;

    # ==================== 性能优化 ====================
    # 开启高效文件传输
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;

    # 保持连接超时
    keepalive_timeout 65;
    keepalive_requests 1000;

    # 超时设置
    client_body_timeout 30;
    client_header_timeout 30;
    send_timeout 30;

    # 缓冲区设置
    client_body_buffer_size 128k;
    client_max_body_size 50m;
    client_header_buffer_size 1k;
    large_client_header_buffers 4 8k;

    # ==================== Gzip压缩 ====================
    gzip on;
    gzip_min_length 1k;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript
               application/xml application/xml+rss text/javascript application/x-javascript;
    gzip_vary on;
    gzip_proxied any;
    gzip_disable "MSIE [1-6]\.";

    # ==================== 速率限制 ====================
    # 客户端请求限制
    limit_req_zone $binary_remote_addr zone=api_limit:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=login_limit:10m rate=1r/s;

    # 连接数限制
    limit_conn_zone $binary_remote_addr zone=conn_limit:10m;

    # 限流返回状态码
    limit_req_status 429;
    limit_conn_status 429;

    # ==================== 上游服务器组 ====================
    # 包含各上游服务器配置
    include /etc/nginx/conf.d/*.conf;

    # 默认服务器（拒绝未匹配的请求）
    server {
        listen 80 default_server;
        listen 443 ssl default_server;
        server_name _;

        # SSL配置
        ssl_certificate /etc/nginx/ssl/server.crt;
        ssl_certificate_key /etc/nginx/ssl/server.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384;
        ssl_prefer_server_ciphers off;

        # 拒绝所有请求
        return 444;
    }
}

# ==================== TCP/UDP代理（4层负载均衡）====================
# stream {
#     include /etc/nginx/stream.d/*.conf;
# }
CONF

    # 构建K8s API Server上游配置
    {
        echo "###############################################################################"
        echo "# K8s API Server 上游服务器组"
        echo "# 7层负载均衡，支持健康检查和会话保持"
        echo "###############################################################################"
        echo ""
        echo "upstream k8s_api_servers {"
        echo "    # 负载均衡算法"
        echo "    # least_conn: 最少连接数（推荐后端服务器性能不均时）"
        echo "    # round-robin: 轮询（默认，推荐后端服务器性能一致时）"
        echo "    # ip_hash: 基于IP的哈希（需要会话保持时）"
        echo "    # hash: 自定义哈希（基于指定参数）"
        echo "    least_conn;"
        echo ""
        echo "    # 会话保持（基于cookie）"
        echo "    # sticky cookie srv_id expires=1h domain=.example.com path=/;"
        echo ""
        echo "    # 最大连接失败次数，超过后标记为不可用"
        echo "    max_fails=3;"
        echo ""
        echo "    # 失败连接超时时间"
        echo "    fail_timeout=30s;"
        echo ""
        echo "    # 健康检查间隔"
        echo "    # Nginx Plus才有主动健康检查，OSS版本通过max_fails+fail_timeout实现"
        echo ""
        # 添加上游服务器
        for server in "${K8S_NODES[@]}"; do
            IFS=':' read -r host port <<< "$server"
            echo "    server ${host}:${port} weight=1 max_fails=3 fail_timeout=30s;"
        done
        echo ""
        echo "    # 备用服务器（所有主服务器不可用时启用）"
        echo "    # server 192.168.100.100:6443 backup;"
        echo ""
        echo "    # 长连接（与后端保持HTTP长连接）"
        echo "    keepalive 32;"
        echo "    keepalive_requests 100;"
        echo "    keepalive_timeout 60s;"
        echo "}"
    } > "$NGINX_CONF_DIR/conf.d/upstream-k8s-api.conf"

    # 构建应用服务上游配置
    {
        echo "###############################################################################"
        echo "# 应用服务上游服务器组"
        echo "###############################################################################"
        echo ""
        echo "upstream app_servers {"
        echo "    least_conn;"
        echo "    max_fails=3;"
        echo "    fail_timeout=30s;"
        echo ""
        for server in "${APP_NODES[@]}"; do
            IFS=':' read -r host port <<< "$server"
            echo "    server ${host}:${port} weight=1 max_fails=3 fail_timeout=30s;"
        done
        echo ""
        echo "    keepalive 16;"
        echo "}"
    } > "$NGINX_CONF_DIR/conf.d/upstream-app.conf"

    # K8s API Server负载均衡配置
    cat > "$NGINX_CONF_DIR/conf.d/k8s-api-lb.conf" <<'CONF'
###############################################################################
# K8s API Server 负载均衡器
# 功能: 代理Kubernetes API Server请求，支持SSL终止
###############################################################################

server {
    listen 6443 ssl;
    server_name k8s-api.example.com;

    # SSL证书配置
    ssl_certificate     /etc/nginx/ssl/server.crt;
    ssl_certificate_key /etc/nginx/ssl/server.key;

    # SSL安全配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # 客户端证书验证（可选）
    # ssl_client_certificate /etc/nginx/ssl/ca.crt;
    # ssl_verify_client on;

    # 速率限制
    limit_req zone=api_limit burst=50 nodelay;

    # 连接数限制
    limit_conn conn_limit 100;

    # 代理到K8s API Server
    location / {
        # 代理配置
        proxy_pass http://k8s_api_servers;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket支持（kubectl exec, kubectl logs等）
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        # 超时设置（长连接）
        proxy_connect_timeout 10s;
        proxy_send_timeout 60s;
        proxy_read_timeout 3600s;  # 1小时，支持长时间exec

        # 缓冲设置
        proxy_buffering off;
        proxy_buffer_size 4k;
        proxy_buffers 8 4k;

        # 失败重试
        proxy_next_upstream error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries 3;
        proxy_next_upstream_timeout 30s;
    }

    # 健康检查端点
    location /healthz {
        proxy_pass http://k8s_api_servers;
        proxy_set_header Host $host;
        access_log off;
    }

    # 指标端点
    location /metrics {
        proxy_pass http://k8s_api_servers;
        proxy_set_header Host $host;
        allow 127.0.0.1;
        allow 10.0.0.0/8;
        deny all;
    }
}

# HTTP到HTTPS重定向（可选）
server {
    listen 80;
    server_name k8s-api.example.com;
    return 301 https://$host$request_uri;
}
CONF

    # 应用负载均衡配置
    cat > "$NGINX_CONF_DIR/conf.d/app-lb.conf" <<'CONF'
###############################################################################
# 应用服务负载均衡器
# 功能: 代理后端应用服务，支持SSL终止和健康检查
###############################################################################

server {
    listen 80;
    listen 443 ssl;
    server_name app.example.com;

    # SSL证书配置
    ssl_certificate     /etc/nginx/ssl/server.crt;
    ssl_certificate_key /etc/nginx/ssl/server.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;

    # 安全头
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # 速率限制
    limit_req zone=api_limit burst=20 nodelay;
    limit_conn conn_limit 50;

    # 主应用代理
    location / {
        proxy_pass http://app_servers;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # HTTP/1.1长连接
        proxy_http_version 1.1;
        proxy_set_header Connection "";

        # 超时设置
        proxy_connect_timeout 10s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;

        # 缓冲设置
        proxy_buffering on;
        proxy_buffer_size 8k;
        proxy_buffers 16 8k;

        # 失败重试
        proxy_next_upstream error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries 3;
    }

    # WebSocket代理
    location /ws {
        proxy_pass http://app_servers;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 3600s;
    }

    # 静态资源（本地缓存）
    location /static/ {
        alias /usr/share/nginx/html/static/;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

    # 健康检查端点
    location /health {
        proxy_pass http://app_servers;
        access_log off;
    }

    # 登录限流（更严格的速率限制）
    location /api/auth/login {
        limit_req zone=login_limit burst=5 nodelay;
        proxy_pass http://app_servers;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
CONF

    # Nginx内置健康检查端点
    cat > "$NGINX_CONF_DIR/conf.d/nginx-health.conf" <<'CONF'
###############################################################################
# Nginx自身健康检查端点
###############################################################################

server {
    listen 8080;
    server_name localhost;

    # Nginx状态页
    location /nginx_status {
        stub_status on;
        access_log off;
        allow 127.0.0.1;
        allow 10.0.0.0/8;
        deny all;
    }

    # 健康检查
    location /health {
        return 200 '{"status":"healthy","service":"nginx-lb","timestamp":"$time_iso8601"}';
        add_header Content-Type application/json;
    }

    # 就绪检查
    location /ready {
        return 200 '{"status":"ready"}';
        add_header Content-Type application/json;
    }
}
CONF

    log_info "Nginx配置文件生成完成"
}

# ==================== 启动Nginx ====================
start_nginx() {
    log_step "[5/5] 启动Nginx..."

    # 测试配置文件
    if nginx -t 2>&1; then
        log_info "Nginx配置测试通过"
    else
        log_error "Nginx配置测试失败"
        exit 1
    fi

    # 启动Nginx
    systemctl daemon-reload
    systemctl enable nginx
    systemctl restart nginx

    sleep 2

    if systemctl is-active nginx &>/dev/null; then
        log_info "Nginx启动成功"
        # 显示监听端口
        ss -tlnp | grep nginx | awk '{print "  " $4 " " $6}'
    else
        log_error "Nginx启动失败"
        systemctl status nginx --no-pager
        exit 1
    fi
}

# ==================== 主流程 ====================
main() {
    log_step "========== 部署Nginx负载均衡 =========="
    install_nginx
    create_directories
    generate_ssl_cert
    generate_config
    start_nginx
    log_success "========== Nginx负载均衡部署完成 =========="
}

main "$@"
