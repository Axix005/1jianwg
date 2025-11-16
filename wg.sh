#!/bin/bash

# WG-Easy 安装脚本（适配v15.1 - 支持自定义端口）
# 使用官方Docker Compose文件，支持HTTP/HTTPS和自动配置

set -e

rm -rf /root/*.sh.*

# ==================== 先定义日志系统（避免函数未定义） ====================
LOG_FILE="/root/wg-easy-install.log"
INFO_FILE="/root/wg-easy-quick-ref.txt"

# 日志函数（确保目录存在）
log() {
    mkdir -p "$(dirname "$LOG_FILE")"  # 创建日志目录（避免tee报错）
    echo -e "$1" | tee -a "$LOG_FILE"   # 追加写入日志
}
error() { 
    echo -e "${RED}[ERROR] $1${NC}" >&2 
    log "$1" 
    exit 1 
}
success() { 
    echo -e "${GREEN}[SUCCESS] $1${NC}" | tee -a "$LOG_FILE" 
}
warning() { 
    echo -e "${YELLOW}[WARNING] $1${NC}" | tee -a "$LOG_FILE" 
}

# 颜色定义（放在日志函数后不影响）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 检查curl是否存在，若不存在则自动安装
if ! command -v curl &> /dev/null; then
    echo "检测到curl未安装，正在自动安装..."
    apt-get update && apt-get install -y curl || { echo "安装curl失败，请手动安装后重试"; exit 1; }
fi

# ==================== 全自动IP探测 ====================
function get_public_ip() {
    local ip=""
    
    # 优先级1：Cloudflare DNS over HTTPS（用grep/awk解析）
    local cloudflare_resp=$(curl -sS --connect-timeout 5 -m 10 \
        -H "User-Agent: Mozilla/5.0" \
        https://cloudflare-dns.com/dns-query?name=one.one.one.one&type=A 2>/dev/null)
    ip=$(echo "$cloudflare_resp" | grep -A 1 "Answer" | awk -F '"' '{print $4}')  # 提取Answer中的IP
    
    # 优先级2：IPify API（纯文本，无需解析）
    [ -z "$ip" ] && ip=$(curl -sS --connect-timeout 5 -m 10 https://api.ipify.org)
    
    # 优先级3：阿里云DNS（用grep/awk解析JSON）
    [ -z "$ip" ] && {
        local aliyun_resp=$(curl -sS --connect-timeout 5 -m 10 http://dns.alidns.com/dns-query?name=one.one.one.one&type=A 2>/dev/null)
        ip=$(echo "$aliyun_resp" | grep -A 1 "Answer" | awk -F '"' '{print $4}')
    }
    
    # 优先级4：OpenDNS终极兜底（纯文本）
    [ -z "$ip" ] && ip=$(dig +short myip.opendns.com @resolver1.opendns.com)
    
    # 过滤私有IP（确保是公网IP）
    if [[ "$ip" =~ ^10\. ]] || [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || [[ "$ip" =~ ^192\.168\. ]]; then
        ip=""  # 私有IP无效，清空
    fi
    
    # 验证IP格式
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "❌ 获取到无效IP: $ip" >&2
        return 1
    fi
    
    echo "$ip"
}

# ==================== 主逻辑 ====================
wanip=$(get_public_ip)

# 失败回退到手动输入
if [ $? -ne 0 ] || [ -z "$wanip" ]; then
    echo -e "
⚠️ 自动探测失败！正在回退到手动模式..."
    read -p "请输入你的公网IP地址: " wanip
fi

# 最终验证IP有效性
if [[ ! "$wanip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "❌ 无效的IP格式: $wanip" >&2
    exit 1
fi

echo "✅ 使用最终确认的公网IP: $wanip"


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

# ==================== 核心改进：端口配置 ====================
# 默认端口
DEFAULT_WG_PORT="51820"    # WireGuard 默认端口
DEFAULT_WEB_PORT="51821"   # WG-Easy 管理后台默认端口


# 安装依赖
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

# 安装Docker
install_docker() {
    log_info "安装Docker..."
    
    unset http_proxy https_proxy all_proxy >/dev/null 2>&1
    
    apt-get update && apt-get install -y --force-yes ca-certificates curl >/dev/null 2>&1
    
    rm -f /etc/apt/trusted.gpg.d/docker.gpg >/dev/null 2>&1
    
    local docker_gpg_url="https://download.docker.com/linux/debian/gpg"
    if [[ ! "$docker_gpg_url" =~ ^https?://[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/.*$ ]]; then
        log_error "Docker GPG URL格式错误：$docker_gpg_url"
        exit 1
    fi
    
    local tmp_gpg="/tmp/docker.gpg"
    curl -fsSL \
        --retry 3 \
        --retry-delay 2 \
        -o "$tmp_gpg" "$docker_gpg_url" >/dev/null 2>&1
    
    if [ ! -s "$tmp_gpg" ]; then
        log_error "Docker GPG密钥下载失败（请检查网络/DNS）！"
        exit 1
    fi
    
    gpg --dearmor -o /etc/apt/trusted.gpg.d/docker.gpg "$tmp_gpg" >/dev/null 2>&1
    rm -f "$tmp_gpg" >/dev/null 2>&1
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/trusted.gpg.d/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    
    apt-get update && apt-get install -y --force-yes docker-ce docker-ce-cli containerd.io >/dev/null 2>&1
    
    systemctl enable --now docker >/dev/null 2>&1
    
    log_success "Docker安装完成"
}

# 安装Docker Compose
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
# ==================== 记录安装信息 ====================
log_install_info() {
    {
        log_success "=== 安装完成 ==="
        echo "访问信息："
        echo "Web管理面板外网访问: http://${wanip}:${DEFAULT_WEB_PORT}"	
        echo "Web管理面板内网访问: http://$(hostname -I | awk '{print $1}'):${DEFAULT_WEB_PORT}"	
        echo "现在可登陆管理面板设置初始化信息"
        echo "管理命令："
        echo "  查看状态: docker compose -f /etc/docker/containers/wg-easy/docker-compose.yml ps"
        echo "  查看日志: docker compose -f /etc/docker/containers/wg-easy/docker-compose.yml logs -f"
        echo "  重启服务: docker compose -f /etc/docker/containers/wg-easy/docker-compose.yml restart"
        echo "  更新服务: docker compose -f /etc/docker/containers/wg-easy/docker-compose.yml pull && docker compose -f /etc/docker/containers/wg-easy/docker-compose.yml up -d"
        echo "============================="
    } > "$LOG_FILE"

    cat > "$INFO_FILE" << EOF
=== 快速参考 ===
面板: http://${wanip}:${DEFAULT_WEB_PORT}
用户: admin（首次登录需初始化）
密码: 首次登录会提示设置
WG端口: ${DEFAULT_WG_PORT}/udp
客户端IP: $(hostname -I | awk '{print $1}')
DNS: 1.1.1.1, 8.8.8.8（默认）
保活: 25秒（默认）
数据目录: /etc/docker/containers/wg-easy/wg-easy-data
命令: 
  启动: docker compose -f /etc/docker/containers/wg-easy/docker-compose.yml up -d
  停止: docker compose -f /etc/docker/containers/wg-easy/docker-compose.yml down
  日志: docker compose -f /etc/docker/containers/wg-easy/docker-compose.yml logs -f
EOF
    log_success "安装信息已保存到$LOG_FILE和$INFO_FILE"
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


    log_install_info
}

# 执行安装
main "$@"

# 清理临时文件
rm -rf /root/*.sh
rm -rf /root/*.sh.*