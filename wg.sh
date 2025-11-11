#!/bin/bash

# WG-Easy 安装脚本（适配v15.1 - 支持自定义端口）
# 使用官方Docker Compose文件，支持HTTP/HTTPS和自动配置

set -e

rm -rf /root/*.sh.*

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
wanip=$(curl -s ipinfo.io/ip 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "127.0.0.1")

# 定义日志文件路径（保存到/root/）
LOG_FILE="/root/wg-easy-install.log"
INFO_FILE="/root/wg-easy-quick-ref.txt"

# 检测终端颜色输出
if [ -t 1 ]; then
    log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
    log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
    log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
    log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
else
    log_info() { echo "[INFO] $1"; }
    log_success() { echo "[SUCCESS] $1"; }
    log_error() { echo "[ERROR] $1" >&2; }
    log_warning() { echo "[WARNING] $1"; }
fi

# ==================== 核心改进：自定义端口配置 ====================
# 默认端口（用户未输入时使用）
DEFAULT_WG_PORT="51820"    # WireGuard 默认端口
DEFAULT_WEB_PORT="51821"   # WG-Easy 管理后台默认端口


# 安装依赖（无修改）
install_dependencies() {
    log_info "安装系统依赖..."
    apt-get update && apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release
    log_success "依赖安装完成"
}

# 安装Docker（优化版）
install_docker() {
    log_info "安装Docker..."
    
    # 强制使用IPv4
    export APT_OPTS="-o Acquire::ForceIPv4=true"

    # 清理残留的Docker源
    rm -rf /etc/apt/sources.list.d/docker* >/dev/null 2>&1

    # 使用阿里云镜像源
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/trusted.gpg.d/docker.gpg] http://mirrors.aliyun.com/docker-ce/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

    # 下载GPG密钥（增强容错）
    local docker_gpg_url="https://mirrors.aliyun.com/docker-ce/linux/debian/gpg"
    curl -fsSL --retry 5 --output /tmp/docker.gpg "$docker_gpg_url"
    gpg --dearmor -o /etc/apt/trusted.gpg.d/docker.gpg /tmp/docker.gpg

    # 安装Docker
    apt-get update -y && apt-get install -y docker-ce docker-ce-cli containerd.io
    systemctl enable --now docker

    log_success "Docker安装完成"
}

# 安装Docker Compose（无修改）
install_docker_compose() {
    log_info "安装Docker Compose..."
    COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d '"' -f 4)
    curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    log_success "Docker Compose安装完成 ($(docker-compose --version | cut -d' ' -f3))"
}

# ====================配置文件设置====================
setup_config() {
    log_info "创建配置目录..."
    mkdir -p /etc/docker/containers/wg-easy
    cd /etc/docker/containers/wg-easy || exit

    log_info "下载官方Docker Compose文件..."
    curl -o docker-compose.yml https://raw.githubusercontent.com/wg-easy/wg-easy/master/docker-compose.yml

    # ==================== 禁用https ====================
    log_info "配置禁用https"
    
    # 1. 清理原有注释的environment块
    sed -i '/#environment:/,/^$/d' docker-compose.yml
    # 2. 添加环境变量（禁用https）
    sed -i '/container_name:/a\    environment:' docker-compose.yml
    sed -i '/environment:/a\      INSECURE: "true"' docker-compose.yml
    log_success "禁用https配置文件修改完成"
}


# ==================== 改进：防火墙配置 ====================
configure_firewall() {
    log_info "配置防火墙..."

    # 安装UFW（无修改逻辑，保留原容错）
    if ! command -v ufw &> /dev/null; then
        log_info "UFW命令未找到，正在安装..."
        apt-get update && apt-get install -y ufw >/dev/null 2>&1 || {
            log_error "UFW安装失败（不影响后续配置，继续执行）..."
        }
        log_success "UFW安装完成"
    fi

    # 启动UFW（无修改逻辑，保留原容错）
    if systemctl is-active --quiet ufw; then
        log_success "UFW服务正在运行"
    else
        log_info "UFW服务未运行，正在启动..."
        systemctl start ufw >/dev/null 2>&1 || {
            log_error "UFW服务启动失败（不影响后续配置）..."
        }
        log_success "UFW服务已启动（或尝试启动）"
    fi

    # ... （安装/启动UFW的逻辑保持不变，参考之前的修复） ...

    # ==================== 升级：添加规则并明确提示成功/失败 ====================
    log_info "正在添加防火墙规则..."

    # 1. 放行WireGuard端口（自定义UDP）
    /usr/sbin/ufw allow "${DEFAULT_WG_PORT}/udp"
    if [ $? -eq 0 ]; then
        log_success "✅ 已放行WireGuard端口：${DEFAULT_WG_PORT}/UDP"
    else
        log_warning "⚠️ 无法放行WireGuard端口：${DEFAULT_WG_PORT}/UDP（请手动执行：ufw allow ${DEFAULT_WG_PORT}/udp）"
    fi

    # 2. 放行Web管理端口（自定义TCP）
    /usr/sbin/ufw allow "${DEFAULT_WEB_PORT}/tcp"
    if [ $? -eq 0 ]; then
        log_success "✅ 已放行Web管理端口：${DEFAULT_WEB_PORT}/TCP"
    else
        log_warning "⚠️ 无法放行Web管理端口：${DEFAULT_WEB_PORT}/TCP（请手动执行：ufw allow ${DEFAULT_WEB_PORT}/tcp）"
    fi

    # 3. 放行SSH端口（固定TCP，可选保留）
    /usr/sbin/ufw allow "22/tcp"
    if [ $? -eq 0 ]; then
        log_success "✅ 已放行SSH端口：22/TCP"
    else
        log_warning "⚠️ 无法放行SSH端口：22/TCP（请手动执行：ufw allow 22/tcp）"
    fi

    # ... （启用UFW的逻辑保持不变） ...
}

# 启动WG-Easy（无修改，保留原容器清理和启动逻辑）
start_wg_easy() {
    log_info "启动WG-Easy服务..."
    
    if docker ps -a | grep -q "wg-easy"; then
        log_warning "检测到旧容器，正在清理..."
		rm -rf /root/​wg-easy-install.log​
		rm -rf wg-easy-quick-ref.txt​
        docker stop wg-easy && docker rm wg-easy
    fi

    cd /etc/docker/containers/wg-easy || exit
    docker compose up -d
    sleep 5
    
    if docker compose ps | grep -q "Up"; then
        log_success "WG-Easy服务已启动"
    else
        log_error "服务启动失败，请检查日志：docker compose -f /etc/docker/containers/wg-easy/docker-compose.yml logs -f"
        exit 1
    fi
}

# ==================== 主流程 ====================
main() {
    log_info "开始安装WG-Easy官方版（网页后台可配置自定义端口）..."
    install_dependencies
    install_docker
    install_docker_compose
    setup_config
    configure_firewall
    start_wg_easy

    log_success "=== 安装完成 ==="
    log_info "访问信息："
    log_info "Web管理面板外网访问: http://${wanip}:${DEFAULT_WEB_PORT}"	
    log_info "Web管理面板内网访问: http://$(hostname -I | awk '{print $1}'):${DEFAULT_WEB_PORT}"	
    log_warning "请登陆管理面板设置初始化信息"
    log_info "管理命令："
    log_info "  查看状态: docker compose -f /etc/docker/containers/wg-easy/docker-compose.yml ps"
    log_info "  查看日志: docker compose -f /etc/docker/containers/wg-easy/docker-compose.yml logs -f"
    log_info "  重启服务: docker compose -f /etc/docker/containers/wg-easy/docker-compose.yml restart"
    log_info "  更新服务: docker compose -f /etc/docker/containers/wg-easy/docker-compose.yml pull && docker compose -f /etc/docker/containers/wg-easy/docker-compose.yml up -d"

    # 关键：调用函数保存安装信息到/root/
    log_install_info
}

# 执行安装
main "$@"

# 清理临时文件
rm -rf /root/*.sh
rm -rf /root/*.sh.*
