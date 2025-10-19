#!/bin/bash

# ==============================================
# WG-Easy Docker Compose 安装脚本（精简优化版）
# 核心功能：限制客户端IP从 .2 开始分配，避免与服务器 .1 冲突
# ==============================================

set -e # 出错自动退出

# -------------------------- 基础配置 --------------------------
DEFAULT_WG_HOST="your-server-ip-or-domain" # 替换为你的服务器IP/域名
DEFAULT_WG_PORT="51820"                  # WireGuard UDP 端口
DEFAULT_WEB_PORT="51821"                 # Web管理 TCP 端口
DEFAULT_WG_ADDRESS="10.88.8.0/24"        # 客户端IP池（默认10.88.8.0/24）
DEFAULT_ADMIN_PASSWORD="wg-easy-admin"   # 管理员密码（建议修改）
DEFAULT_DNS1="1.1.1.1"                   # 主DNS
DEFAULT_DNS2="8.8.8.8"                   # 辅DNS
COMPOSE_FILE="docker-compose.yml"        # Docker Compose 文件名
ENV_FILE=".env"                          # 环境变量文件名


# -------------------------- 工具函数 --------------------------
# 日志输出（带颜色）
log_info() { echo -e "\033[34m[INFO]\033[0m $1"; }
log_success() { echo -e "\033[32m[SUCCESS]\033[0m $1"; }
log_warning() { echo -e "\033[33m[WARNING]\033[0m $1"; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $1" >&2; }

# 验证端口有效性
validate_port() {
    local port=$1 default=$2 type=$3
    [[ -z $port ]] && { echo $default; return; }
    ! [[ $port =~ ^[0-9]+$ ]] && { log_warning "$type端口需为数字，使用默认$default"; echo $default; return; }
    (( port < 1024 || port > 65535 )) && { log_warning "$type端口需在1024-65535，使用默认$default"; echo $default; return; }
    [[ $type == "WireGuard" ]] && netstat -uln | grep -q ":$port " && { log_warning "UDP端口$port已占用，使用默认$default"; echo $default; return; }
    [[ $type == "Web" ]] && netstat -tln | grep -q ":$port " && { log_warning "TCP端口$port已占用，使用默认$default"; echo $default; return; }
    echo $port
}

# 验证IP段有效性
validate_ip_range() {
    local ip=$1 default=$2
    [[ -z $ip ]] && { echo $default; return; }
    ! [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]] && { log_warning "IP段格式错误（如10.88.8.0/24），使用默认$default"; echo $default; return; }
    IFS='./' read -ra parts <<< "$ip"
    for i in {0..3}; do (( parts[i] < 0 || parts[i] > 255 )) && { log_warning "IP段无效，使用默认$default"; echo $default; return; }; done
    (( parts[4] < 8 || parts[4] > 30 )) && { log_warning "子网掩码需8-30，使用默认$default"; echo $default; return; }
    echo $ip
}


# -------------------------- 核心步骤 --------------------------
# 1. 获取用户输入（或使用默认值）
get_user_input() {
    log_info "=== 请配置WG-Easy参数 ==="
    read -p "服务器地址（IP/域名，默认：$DEFAULT_WG_HOST）: " WG_HOST; WG_HOST=${WG_HOST:-$DEFAULT_WG_HOST}
    WG_PORT=$(validate_port "$WG_PORT" "$DEFAULT_WG_PORT" "WireGuard")
    WEB_PORT=$(validate_port "$WEB_PORT" "$DEFAULT_WEB_PORT" "Web")
    WG_ADDRESS=$(validate_ip_range "$WG_ADDRESS" "$DEFAULT_WG_ADDRESS")
    read -p "DNS1（默认：$DEFAULT_DNS1）: " DEFAULT_DNS1; read -p "DNS2（默认：$DEFAULT_DNS2）: " DEFAULT_DNS2
    read -p "管理员密码（默认：$DEFAULT_ADMIN_PASSWORD）: " ADMIN_PASSWORD; ADMIN_PASSWORD=${ADMIN_PASSWORD:-$DEFAULT_ADMIN_PASSWORD}
    log_success "配置完成：服务器=$WG_HOST:$WG_PORT，客户端IP段=$WG_ADDRESS"
}

# 2. 生成密码哈希（WG-Easy要求）
generate_password_hash() {
    log_info "生成管理员密码哈希..."
    docker run --rm ghcr.io/wg-easy/wg-easy wgpw "$ADMIN_PASSWORD" 2>/dev/null || echo '$2a$12$ztM8XHe1Ae/M3cTUBrrJhOnmIx40NiOFvPWKaA.jylXUm4gralq6C'
}

# 3. 创建环境变量文件（关键：限制客户端IP从 .2 开始）
create_env_file() {
    log_info "创建环境配置文件..."
    IFS='/' read -ra ip_parts <<< "$WG_ADDRESS"
    local base_ip=${ip_parts[0]} mask=${ip_parts[1]}
    IFS='.' read -ra octets <<< "$base_ip"
    
    # 服务器用 .1，客户端从 .2 开始
    local server_ip="${octets[0]}.${octets[1]}.${octets[2]}.1"
    local client_ip_range="${octets[0]}.${octets[1]}.${octets[2]}.2/$mask"
    
    cat > $ENV_FILE << EOF
# WG-Easy 核心配置
WG_HOST=$WG_HOST
PASSWORD_HASH=$(generate_password_hash)
WG_PORT=$WG_PORT
PORT=$WEB_PORT
WG_DEFAULT_DNS=$DEFAULT_DNS1,$DEFAULT_DNS2
WG_DEFAULT_ADDRESS=$server_ip       # 服务器自身IP（.1）
WG_DEFAULT_MASK=$mask               # 子网掩码
WG_DEFAULT_CLIENT_IP_RANGE=$client_ip_range  # 客户端IP范围（强制从.2开始）
WG_PERSISTENT_KEEPALIVE=25          # 连接保活（秒）
LANG=chs                            # 中文界面
UI_TRAFFIC_STATS=true               # 启用流量统计
EOF
    log_success "环境文件生成：客户端将从 $client_ip_range 分配IP"
}

# 4. 创建Docker Compose文件
create_docker_compose() {
    log_info "创建Docker Compose配置..."
    cat > $COMPOSE_FILE << EOF
version: '3.8'
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:latest
    container_name: wg-easy
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./wg-easy-data:/etc/wireguard  # 数据持久化
    ports:
      - "$WG_PORT:$WG_PORT/udp"        # WireGuard端口
      - "$WEB_PORT:$WEB_PORT/tcp"      # Web管理端口
    cap_add:
      - NET_ADMIN                      # 需要网络管理权限
      - SYS_MODULE                     # 加载内核模块
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv4.ip_forward=1         # 启用IP转发
EOF
    log_success "Docker Compose文件生成完成"
}

# 5. 清理旧安装（避免冲突）
cleanup_old() {
    log_info "清理旧安装..."
    docker rm -f wg-easy >/dev/null 2>&1 || true  # 删除旧容器
    rm -f $COMPOSE_FILE $ENV_FILE                # 删除旧配置
    rm -rf wg-easy-data                          # 删除旧数据
    log_success "旧安装已清理"
}

# 6. 安装Docker（若未安装）
install_docker() {
    log_info "检查Docker环境..."
    if ! command -v docker &> /dev/null; then
        log_info "安装Docker..."
        curl -fsSL https://get.docker.com | sh -s -- --version
        systemctl start docker && systemctl enable docker
    fi
    if ! docker compose version &> /dev/null; then
        log_info "安装Docker Compose..."
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi
    log_success "Docker环境就绪"
}

# 7. 启动服务
start_service() {
    log_info "启动WG-Easy服务..."
    docker compose up -d
    sleep 3  # 等待服务启动
    
    # 验证服务状态
    if docker compose ps | grep -q "Up"; then
        log_success "WG-Easy服务运行正常"
    else
        log_error "服务启动失败，查看日志：docker compose logs"
        exit 1
    fi
}


# -------------------------- 结束流程 --------------------------
# 主函数
main() {
    get_user_input
    cleanup_old
    install_docker
    create_env_file
    create_docker_compose
    start_service
    
    # 显示最终信息
    log_success "\n=== WG-Easy安装完成 ==="
    log_success "管理地址：http://$WG_HOST:$WEB_PORT"
    log_success "用户名：admin"
    log_success "密码：$ADMIN_PASSWORD"
    log_success "客户端IP范围：${WG_ADDRESS%/*}.2 - ${WG_ADDRESS%/*}.254"
    log_success "数据目录：./wg-easy-data"
    
    # 保存快速参考
    cat > /root/wg-easy-ref.txt << EOF
管理命令：
  启动：docker compose up -d
  停止：docker compose down
  日志：docker compose logs -f
  更新：docker compose pull && docker compose up -d
EOF
}

# 执行主流程
main