#!/bin/bash

# WG-Easy Docker Compose 安装脚本（完全修复版）
# 使用 .env 文件安全传递环境变量

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# 默认配置变量
DEFAULT_WG_HOST="123.123.123.123"  # 修改为默认IP地址保护隐私
DEFAULT_WG_PORT="51820"
DEFAULT_WEB_PORT="51821"
DEFAULT_WG_DNS1="1.1.1.1"    # 主DNS
DEFAULT_WG_DNS2="8.8.8.8"          # 辅DNS
DEFAULT_ADMIN_PASSWORD="123456"
DEFAULT_WG_ADDRESS="10.88.8.0/24"   # 默认客户端IP地址范围
COMPOSE_FILE="docker-compose.yml"
ENV_FILE=".env"
LOG_FILE="/root/wg-easy-install.log"
INFO_FILE="/root/wg-easy-info.txt"

# 用户配置变量
WG_HOST=""
ADMIN_PASSWORD=""
PASSWORD_HASH=""
WG_DNS1=""
WG_DNS2=""
WG_PORT=""
WEB_PORT=""
WG_ADDRESS=""

# 生成密码哈希
generate_password_hash() {
    local password="$1"
    log_info "生成密码哈希..."
    
    # 使用docker命令生成密码哈希
    if hash_result=$(docker run --rm ghcr.io/wg-easy/wg-easy wgpw "$password" 2>/dev/null); then
        echo "$hash_result"
    else
        log_error "密码哈希生成失败，使用默认哈希"
        # 123456的默认哈希
        echo '$2a$12$ztM8XHe1Ae/M3cTUBrrJhOnmIx40NiOFvPWKaA.jylXUm4gralq6C'
    fi
}

# 验证端口号
validate_port() {
    local port="$1"
    local default="$2"
    local type="$3"
    
    # 检查是否为空
    if [ -z "$port" ]; then
        echo "$default"
        return 0
    fi
    
    # 检查是否为数字
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        log_warning "$type 端口必须是数字，使用默认值 $default"
        echo "$default"
        return 1
    fi
    
    # 检查端口范围
    if [ "$port" -lt 1024 ] || [ "$极光" -gt 65535 ]; then
        log_warning "$type 端口必须在 1024-65535 范围内，使用默认值 $default"
        echo "$default"
        return 1
    fi
    
    # 检查端口是否已被使用
    if [ "$type" == "WireGuard" ]; then
        if netstat -uln | grep -q ":$port "; then
            log_warning "UDP 端口 $port 已被使用，使用默认值 $default"
            echo "$default"
            return 1
        fi
    else
        if netstat -tln | grep -q ":$port "; then
            log_warning "TCP 端口 $port 已被使用，使用默认值 $default"
            echo "$default"
            return 1
        fi
    fi
    
    echo "$port"
}

# 验证IP地址范围
validate_ip_range() {
    local ip_range="$1"
    local default="$2"
    
    # 检查是否为空
    if [ -z "$ip_range" ]; then
        echo "$default"
        return 0
    fi
    
    # 检查格式是否为X.X.X.X/X
    if ! [[ "$ip_range" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        log_warning "IP地址范围格式无效，使用默认值 $default"
        echo "$default"
        return 1
    fi
    
    # 检查每个部分是否在0-255范围内
    IFS='./' read -r -a parts <<< "$ip_range"
    for i in {0..3}; do
        if [ "${parts[$i]}" -lt 0 ] || [ "${parts[$i]}" -gt 255 ]; then
            log_warning "IP地址范围无效，使用默认值 $default"
            echo "$default"
            return 1
        fi
    done
    
    # 检查子网掩码是否在8-30范围内
    if [ "${parts[4]}" -lt 8 ] || [ "${parts[4]}" -gt 30 ]; then
        log_warning "子网掩码必须在8-30范围内，使用默认值 $default"
        echo "$default"
        return 1
    fi
    
    echo "$ip_range"
}

# 获取用户输入
get_user_input() {
    echo
    log_info "=== WG-Easy 配置设置 ==="
    
    # 获取主机地址
    read -p "请输入WireGuard服务器域名或IP地址 [默认: $DEFAULT_WG_HOST]: " input_host
    WG_HOST="${input_host:-$DEFAULT_WG_HOST}"
    
    # 获取WireGuard端口
    read -p "请输入WireGuard端口 (UDP) [默认: $DEFAULT_WG_PORT]: " input_wg_port
    WG_PORT=$(validate_port "$input_wg_port" "$DEFAULT_WG_PORT" "WireGuard")
    
    # 获取Web管理端口
    read -p "请输入Web管理端口 (TCP) [默认: $DEFAULT_WEB_PORT]: " input_web_port
    WEB_PORT=$(validate_port "$input_web_port" "$DEFAULT_WEB_PORT" "Web管理")
    
    # 获取客户端IP地址范围
    log_info "请输入客户端IP地址范围 (CIDR格式，如10.88.8.0/24)"
    log_warning "⚠️  小白用户如果不懂IP设置，请保留默认值 $DEFAULT_WG_ADDRESS"
    read -p "客户端IP地址范围 [默认: $DEFAULT_WG_ADDRESS]: " input_address
    WG_ADDRESS=$(validate_ip_range "$input_address" "$DEFAULT_WG_ADDRESS")
    
    # 获取DNS服务器
    log_info "请输入两个DNS服务器（用空格分隔）"
    read -p "主DNS和辅DNS [默认: $DEFAULT_WG_DNS1 $DEFAULT_WG_DNS2]: " input_dns
    
    if [ -z "$input_dns" ]; then
        WG_DNS1="$DEFAULT_WG_DNS1"
        WG_DNS2="$DEFAULT_WG_DNS2"
    else
        # 分割输入的DNS
        WG_DNS1=$(echo "$input_dns" | awk '{print $1}')
        WG_DNS2=$(echo "$input_dns" | awk '{print $2}')
        
        # 验证DNS格式
        if ! [[ $WG_DNS1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log_warning "主DNS格式无效，使用默认值"
            WG_DNS1="$DEFAULT_WG_DNS1"
        fi
        
        if ! [[ $WG_DNS2 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log_warning "辅DNS格式无效，使用默认值"
            WG_DNS2="$DEFAULT_WG_DNS2"
        fi
    fi
    
    # 获取管理员密码
    read -p "请输入Web管理面板密码 [默认: $DEFAULT_ADMIN_PASSWORD]: " input_password
    ADMIN_PASSWORD="${input_password:-$DEFAULT_ADMIN_PASSWORD}"
    
    # 生成密码哈希
    PASSWORD_HASH=$(generate_password_hash "$ADMIN_PASSWORD")
    
    echo
    log_success "配置摘要:"
    echo "  - 服务器地址: $WG_HOST"
    echo "  - WireGuard端口: $WG_PORT/udp"
    echo "  - Web管理端口: $WEB_PORT/tcp"
    echo "  - 客户端IP范围: $WG_ADDRESS"
    echo "  - DNS服务器: $WG_DNS1, $WG_DNS2"
    echo "  - 管理员密码: $ADMIN_PASSWORD"
    echo
}

# 创建环境文件
create_env_file() {
    log_info "创建环境变量文件..."
    
    # 从IP范围中提取服务器IP和子网掩码
    IFS='/' read -r -a ip_parts <<< "$WG_ADDRESS"
    base_ip="${ip_parts[0]}"
    mask="${ip_parts[1]}"
    IFS='.' read -r -a octets <<< "$base_ip"
    server_ip="${octets[0]}.${octets[1]}.${octets[2]}.$((octets[3] + 1))"
    
    cat > $ENV_FILE << EOF
# WG-Easy 环境变量
WG_HOST=$WG_HOST
PASSWORD_HASH=$PASSWORD_HASH
WG_PORT=$WG_PORT
PORT=$WEB_PORT
WG_DEFAULT_DNS=$WG_DNS1,$WG_DNS2
WG_DEFAULT_ADDRESS=$server_ip  # 只设置IP地址，不带子网掩码
WG_DEFAULT_MASK=$mask         # 单独设置子网掩码
LANG=chs
UI_TRAFFIC_STATS=true
EOF

    log_success "环境变量文件创建完成"
    log_info "服务器接口IP设置为: $server_ip"
    log_info "子网掩码设置为: $mask"
}

# 创建Docker Compose配置文件
create_docker_compose() {
    log_info "创建Docker Compose配置文件..."
    
    cat > $COMPOSE_FILE << EOF
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy
    container_name: wg-easy
    restart: unless-stopped
    env_file:
      - .env
    volumes:
      - ./wg-easy-data:/etc/wireguard
    ports:
      - "${WG_PORT}:${WG_PORT}/udp"
      - "${WEB_PORT}:${WEB_PORT}/tcp"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv4.ip_forward=1
EOF

    log_success "Docker Compose文件创建完成"
}

# 记录安装信息
log_install_info() {
    {
        echo "=== WG-Easy 安装信息 ==="
        echo "安装时间: $(date)"
        echo "主机地址: $WG_HOST"
        echo "WireGuard端口: $WG_PORT/udp"
        echo "Web管理端口: $WEB_PORT/tcp"
        echo "客户端IP范围: $WG_ADDRESS"
        echo "DNS服务器: $WG_DNS1, $WG_DNS2"
        echo "管理员密码: $ADMIN_PASSWORD"
        echo "密码哈希: $PASSWORD_HASH"
        echo "数据目录: $(pwd)/wg-easy-data"
        echo "访问地址: http://$WG_HOST:$WEB_PORT"
        echo "用户名: admin"
        echo "密码: $ADMIN_PASSWORD"
        echo "管理命令:"
        echo "  查看状态: docker compose ps"
        echo "  查看日志: docker compose logs -f"
        echo "  重启服务: docker compose restart"
        echo "  停止服务: docker compose down"
        echo "  更新服务: docker compose pull && docker compose up -d"
        echo "========================="
    } > "$LOG_FILE"
    
    # 创建简洁版信息文件到/root目录
    cat > "$INFO_FILE" << EOF
=== WG-Easy 快速参考 ===
管理面板: http://$WG_HOST:$WEB_PORT
用户名: admin
密码: $ADMIN_PASSWORD
WireGuard端口: $WG_PORT/udp
客户端IP范围: $WG_ADDRESS
DNS服务器: $WG_DNS1, $WG_DNS2
数据目录: $(pwd)/wg-easy-data
管理命令:
  启动: docker compose up -d
  停止: docker compose down
  查看日志: docker compose logs -f
EOF
    
    log_success "安装信息已保存到 $LOG_FILE"
    log_success "快速参考信息已保存到 $INFO_FILE"
}

# 修复APT源
fix_apt_sources() {
    log_info "修复APT软件源配置..."
    
    cp /etc/apt/sources.list /etc/apt/sources.list.backup.$(date +%Y%m%d) 2>/dev/null || true
    
    if grep -q "trixie" /etc/os-release; then
        log_info "检测到Debian Trixie (12)"
        cat > /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free
deb http://deb.debian.org/debian trixie-updates main contrib non-free
deb http://security.debian.org/debian-security trixie-security main contrib non-free
EOF
    elif grep -q "bookworm" /etc/os-release; then
        log_info "检测到Debian Bookworm (11)"
        cat > /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free
deb http://deb.debian.org/debian bookworm-updates main contrib non-free
deb http://security.debian.org/debian-security bookworm-security main contrib non-free
EOF
    else
        log_warning "未知Debian版本，使用通用源"
        cat > /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian stable main contrib non-free
deb http://deb.debian.org/debian stable-updates main contrib non-free
deb http://security.debian.org/debian-security stable-security main contrib non-free
EOF
    fi
    
    log_success "APT源配置已修复"
}

# 清理错误的Docker源
clean_docker_sources() {
    log_info "清理错误的Docker软件源..."
    rm -f /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.list.save
    log_success "Docker源已清理"
}

# 安装系统依赖
install_dependencies() {
    log_info "安装系统依赖..."
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release net-tools
}

# 安装Docker和Docker Compose插件
install_docker() {
    log_info "安装Docker和Docker Compose..."
    
    # 添加Docker官方GPG密钥和源
    mkdir -p /etc/apt/keyrings
    # 强制覆盖现有文件，避免手动确认
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    
    # 安装Docker（包含docker-compose-plugin）
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    # 启动并启用Docker服务
    systemctl start docker
    systemctl enable docker
    
    # 验证安装
    if docker --version &> /dev/null && docker compose version &> /dev/null; then
        log_success "Docker安装成功: $(docker --version | cut -d' ' -f3 | tr -d ',')"
        log_success "Docker Compose可用"
    else
        log_error "Docker安装失败"
        exit 1
    fi
}

# 配置防火墙
configure_firewall() {
    log_info "配置防火墙规则..."
    
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "$WG_PORT/udp"
        ufw allow "$WEB_PORT/tcp"
        log_success "UFW防火墙规则已添加"
    fi
    
    # 启用IP转发
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    fi
    sysctl -p &> /dev/null
    log_success "IP转发已启用"
}

# 清理旧安装
cleanup_old_installation() {
    log_info "清理旧安装..."
    
    # 停止并删除容器
    if docker ps -a --format '{{.Names}}' | grep -q "^wg-easy$"; then
        log_info "停止并删除旧容器..."
        docker rm -f wg-easy >/dev/null 2>&1 || true
    fi
    
    # 删除docker-compose文件
    if [ -f "$COMPOSE_FILE" ]; then
        rm -f "$COMPOSE_FILE"
        log_info "删除旧docker-compose文件"
    fi
    
    # 删除环境文件
    if [ -f "$ENV_FILE" ]; then
        rm -f "$ENV_FILE"
        log_info "删除旧环境文件"
    fi
    
    # 删除数据目录
    if [ -d "wg-easy-data" ]; then
        rm -rf "wg-easy-data"
        log_info "删除旧数据目录"
    fi
    
    # 清理/root目录下的残留文件
    log_info "清理/root目录下的残留文件..."
    rm -f /root/wg-easy-install.log
    rm -f /root/wg-easy-info.txt
    rm -f /root/docker-compose.yml
    rm -f /root/.env
    
    log_success "旧安装清理完成"
}

# 使用Docker Compose启动服务
start_with_compose() {
    log_info "使用Docker Compose启动WG-Easy服务..."
    
    # 拉取最新镜像
    log_info "拉取WG-Easy镜像..."
    docker compose pull
    
    # 启动服务
    docker compose up -d
    
    # 等待服务启动 - 直接等待2秒
    log_info "等待服务启动（2秒）..."
    sleep 2
    
    # 检查服务状态
    if docker compose ps | grep -q "Up"; then
        log_success "WG-Easy服务运行正常"
    else
        log_error "WG-Easy服务启动失败"
        docker compose logs
        exit 1
    fi
}

# 验证密码设置
verify_password() {
    log_info "验证密码设置..."
    
    # 等待一段时间让服务完全启动
    sleep 5
    
    # 尝试访问Web界面验证密码
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$WEB_PORT" | grep -q "200"; then
        log_success "Web服务可访问，密码设置正常"
        return 0
    else
        log_warning "Web服务访问测试失败，但服务可能仍在启动中"
        return 1
    fi
}

# 显示安装结果
show_result() {
    echo
    log_success "=== WG-Easy Docker Compose 安装完成 ==="
    echo
    echo "📱 访问信息:"
    echo "   ├── Web管理面板: http://$WG_HOST:$WEB_PORT"
    echo "   ├── 用户名: admin"
    echo "   └── 密码: $ADMIN_PASSWORD"
    echo
    echo "🔧 服务器信息:"
    echo "   ├── WireGuard端口: $WG_PORT/udp"
    echo "   ├── Web管理端口: $WEB_PORT/tcp"
    echo "   ├── 客户端IP范围: $WG_ADDRESS"
    echo "   ├── 主DNS服务器: $WG_DNS1"
    echo "   └── 辅DNS服务器: $WG_DNS2"
    echo
    echo "⚡ Docker Compose 管理命令:"
    echo "   ├── 查看服务状态: docker compose ps"
    echo "   ├── 查看实时日志: docker compose logs -f"
    echo "   ├── 重启服务: docker compose restart"
    echo "   ├── 停止服务: docker compose down"
    echo "   └── 更新服务: docker compose pull && docker compose up -d"
    echo
    echo "📁 数据目录: $(pwd)/wg-easy-data/"
    echo
    echo "📝 安装信息已保存到:"
    echo "   ├── 详细日志: $LOG_FILE"
    echo "   └── 快速参考: $INFO_FILE"
    echo
    log_warning "⚠️  请确保云服务商安全组已开放端口: $WG_PORT(UDP) 和 $WEB_PORT(TCP)"
    echo
    
    # 检查密码状态
    if verify_password; then
        log_success "✅ 密码设置正确，可以正常登录"
    else
        log_warning "⚠️  Web服务访问测试失败，但密码可能已正确设置"
        log_warning "请手动尝试访问 http://$WG_HOST:$WEB_PORT 确认"
    fi
    echo
}

# 验证安装
verify_installation() {
    log_info "验证安装..."
    
    # 检查Docker Compose文件
    if [ -f "$COMPOSE_FILE" ]; then
        log_success "Docker Compose文件存在"
    else
        log_error "Docker Compose文件不存在"
        exit 1
    fi
    
    # 检查环境文件
    if [ -f "$ENV_FILE" ]; then
        log_success "环境变量文件存在"
    else
        log_error "环境变量文件不存在"
        exit 1
    fi
    
    # 检查服务状态
    if docker compose ps | grep -q "Up"; then
        log_success "WG-Easy服务运行正常"
    else
        log_error "WG-Easy服务未正常运行"
        docker compose logs
        exit 1
    fi
}

# 主函数
main() {
    log_info "开始使用Docker Compose模式安装WG-Easy..."
    
    # 获取用户配置
    get_user_input
    
    # 修复系统环境
    fix_apt_sources
    clean_docker_sources
    install_dependencies
    
    # 安装Docker和Docker Compose
    install_docker
    
    # 清理旧安装
    cleanup_old_installation
    
    # 创建配置和启动服务
    create_env_file
    create_docker_compose
    configure_firewall
    start_with_compose
    
    # 验证安装
    verify_installation
    
    # 显示结果
    show_result
    
    # 记录安装信息
    log_install_info
}

# 执行主函数
main "$@"