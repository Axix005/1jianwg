#!/bin/bash

# WG-Easy 安装脚本（适配v15.1 - 支持自定义端口）
# 使用官方Docker Compose文件，支持HTTP/HTTPS和自动配置

set -e
# 获取脚本所在目录和文件名（绝对路径）
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_NAME=$(basename "${BASH_SOURCE[0]}")
SCRIPT_SELF="$SCRIPT_DIR/$SCRIPT_NAME"

# ==================== 颜色定义 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==================== 日志函数定义 ====================
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

# 检查curl是否存在，若不存在则自动安装
if ! command -v curl &> /dev/null; then
    echo "检测到curl未安装，正在自动安装..."
    apt-get update && apt-get install -y curl || { echo "安装curl失败，请手动安装后重试"; exit 1; }
fi

# ==================== 修复 raw.githubusercontent.com DNS ====================
fix_github_hosts() {
    # 检查是否已经绑定了可用 IP
    if grep -q "raw.githubusercontent.com" /etc/hosts; then
        # 如果已经绑定，检查当前绑定的 IP 是否可达
        local current_ip=$(grep "raw.githubusercontent.com" /etc/hosts | awk '{print $1}')
        if curl -s --connect-timeout 3 -o /dev/null "https://raw.githubusercontent.com" --resolve "raw.githubusercontent.com:443:$current_ip"; then
            return 0  # 当前 IP 可用，无需修改
        else
            # 当前 IP 不可用，删除旧绑定
            sed -i '/raw.githubusercontent.com/d' /etc/hosts
        fi
    fi

    # 尝试多个已知可用 IP
    for ip in 185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133; do
        if curl -s --connect-timeout 3 -o /dev/null "https://raw.githubusercontent.com" --resolve "raw.githubusercontent.com:443:$ip"; then
            echo "$ip raw.githubusercontent.com" >> /etc/hosts
            log_info "已绑定 raw.githubusercontent.com 到 $ip"
            return 0
        fi
    done

    log_warning "无法自动绑定 raw.githubusercontent.com，尝试直连（可能较慢）"
}

# ==================== 全自动IP探测 ====================
function get_public_ip() {
    local ip=""
    
    # 优先级1：Cloudflare DNS over HTTPS（用grep/awk解析）
    local cloudflare_resp=$(curl -sS --connect-timeout 5 -m 10 \
        -H "User-Agent: Mozilla/5.0" \
        https://cloudflare-dns.com/dns-query?name=one.one.one.one&type=A 2>/dev/null)
    ip=$(echo "$cloudflare_resp" | grep -A 1 "Answer" | awk -F '"' '{print $4}' 2>/dev/null)  # 提取Answer中的IP
    
    # 优先级2：IPify API（纯文本，无需解析）
    [ -z "$ip" ] && ip=$(curl -sS --connect-timeout 5 -m 10 https://api.ipify.org 2>/dev/null)
    
    # 优先级3：阿里云DNS（用grep/awk解析JSON）
    [ -z "$ip" ] && {
        local aliyun_resp=$(curl -sS --connect-timeout 5 -m 10 http://dns.alidns.com/dns-query?name=one.one.one.one&type=A 2>/dev/null)
        ip=$(echo "$aliyun_resp" | grep -A 1 "Answer" | awk -F '"' '{print $4}' 2>/dev/null
    }
    
    # 优先级4：OpenDNS终极兜底（纯文本）
    [ -z "$ip" ] && ip=$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null)
    
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

# ==================== 核心改进：端口配置 ====================
# 默认端口
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

install_docker() {
    # 幂等性：如果 Docker 已安装，跳过
    if command -v docker &> /dev/null; then
        log_info "Docker 已安装，跳过安装步骤"
        return 0
    fi

    log_info "安装Docker..."

    # 清理环境
    unset http_proxy https_proxy all_proxy 2>/dev/null
    rm -f /etc/apt/sources.list.d/docker.list
    rm -f /etc/apt/trusted.gpg.d/docker.gpg
    rm -f /usr/share/keyrings/docker-archive-keyring.gpg

    # 安装必要工具
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq ca-certificates curl gnupg >/dev/null 2>&1

    # 创建密钥目录
    mkdir -p /usr/share/keyrings

    # 下载 GPG 密钥（最多重试 5 次）
    local tmp_gpg="/tmp/docker.gpg"
    local retry=0
    local max_retry=5
    local success=false

    while [ $retry -lt $max_retry ]; do
        retry=$((retry + 1))
        log_info "尝试下载 Docker GPG 密钥 (第 $retry/$max_retry 次)..."
        if curl -4 -fsSL --connect-timeout 10 --retry 2 -o "$tmp_gpg" "https://download.docker.com/linux/debian/gpg"; then
            if [ -s "$tmp_gpg" ]; then
                success=true
                break
            fi
        fi
        sleep 2
    done

    if [ "$success" != "true" ]; then
        log_error "Docker GPG 密钥下载失败，请检查网络后重试"
        exit 1
    fi

    # 安装密钥（使用新格式）
    gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg "$tmp_gpg" >/dev/null 2>&1
    rm -f "$tmp_gpg"

    # 添加 Docker 源（阿里云镜像）
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://mirrors.aliyun.com/docker-ce/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

    # 更新源（失败则重试一次）
    log_info "更新 APT 源..."
    if ! apt-get update >/dev/null 2>&1; then
        log_warning "APT 更新失败，等待 3 秒后重试..."
        sleep 3
        apt-get update >/dev/null 2>&1 || {
            log_error "APT 更新仍然失败，请检查网络或源配置"
            exit 1
        }
    fi

    # 安装 Docker
    log_info "安装 Docker 组件..."
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io >/dev/null 2>&1 || {
        log_error "Docker 安装失败"
        exit 1
    }

    systemctl enable --now docker >/dev/null 2>&1

    log_success "Docker 安装完成"
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
    if ! curl -L -o docker-compose.yml --connect-timeout 10 --retry 5 --retry-delay 3 https://raw.githubusercontent.com/wg-easy/wg-easy/master/docker-compose.yml; then
	log_error "下载失败，请检查网络后重试，或手动下载该文件到 $(pwd)"
    exit 1
    fi

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
    # 检查 UFW 是否已安装
    if command -v ufw &> /dev/null; then
        log_info "检测到 UFW 已安装，直接配置防火墙规则..."
        configure_ufw_rules
        return 0
    fi

    # UFW 未安装，询问用户
    log_info "未检测到 UFW 防火墙"
    read -p "是否安装并配置 UFW 防火墙？输入 y 确认，按 Enter 跳过（默认不安装）: " ufw_choice

    if [[ "$ufw_choice" != "y" && "$ufw_choice" != "Y" ]]; then
        log_info "跳过 UFW 防火墙安装和配置"
        log_success "防火墙配置阶段完成（已跳过）"
        return 0
    fi

    # 用户确认安装 UFW
    log_info "开始安装 UFW 防火墙..."
    if apt-get update && apt-get install -y ufw >/dev/null 2>&1; then
        log_success "UFW 安装完成"
        configure_ufw_rules
    else
        log_warning "UFW 安装失败，跳过防火墙配置（不影响后续安装）"
        log_success "防火墙配置阶段完成（如有问题请手动处理）"
        return 0
    fi
}

# ==================== UFW 规则配置函数 ====================
configure_ufw_rules() {
    log_info "配置 UFW 防火墙规则..."

    # SSH 最先放行（防止启用时断连）
    if ufw allow 22/tcp >/dev/null 2>&1; then
        log_success "✅ 已放行 SSH 端口：22/TCP"
    else
        log_warning "⚠️ 无法放行 SSH 端口（请手动执行：ufw allow 22/tcp）"
    fi

    # WireGuard
    if ufw allow "${DEFAULT_WG_PORT}/udp" >/dev/null 2>&1; then
        log_success "✅ 已放行 WireGuard 端口：${DEFAULT_WG_PORT}/UDP"
    else
        log_warning "⚠️ 无法放行 WireGuard 端口（请手动执行：ufw allow ${DEFAULT_WG_PORT}/udp）"
    fi

    # Web 管理
    if ufw allow "${DEFAULT_WEB_PORT}/tcp" >/dev/null 2>&1; then
        log_success "✅ 已放行 Web 管理端口：${DEFAULT_WEB_PORT}/TCP"
    else
        log_warning "⚠️ 无法放行 Web 管理端口（请手动执行：ufw allow ${DEFAULT_WEB_PORT}/tcp）"
    fi

    # 启用防火墙（如果尚未启用）
    if ! ufw status | grep -q "Status: active"; then
        echo "y" | ufw enable >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            log_success "UFW 防火墙已成功启用"
        else
            log_warning "UFW 启用失败，规则可能未生效，请手动执行：ufw enable"
        fi
    else
        log_info "UFW 防火墙已处于启用状态"
    fi

    # 显示状态
    log_info "当前防火墙状态："
    ufw status | tee -a "$LOG_FILE"

    log_success "防火墙配置完成"
}

# 启动WG-Easy（无修改，保留原容器清理和启动逻辑）
start_wg_easy() {
    log_info "启动WG-Easy服务..."
    
    if docker ps -a | grep -q "wg-easy"; then
        log_warning "检测到旧容器，正在清理..."
		rm -rf /root/​wg-easy-install.log
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
# ==================== 记录安装信息（函数定义移到main之前） ====================
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

# ==================== 检查是否已安装 ====================
check_installed() {
    local installed=false

    # 检测 Docker
    if command -v docker &> /dev/null; then
        # 检测 WG-Easy 容器是否在运行
        if docker ps --format '{{.Names}}' | grep -q "^wg-easy$"; then
            # 检测配置文件是否存在
            if [ -f "/etc/docker/containers/wg-easy/docker-compose.yml" ]; then
                installed=true
            fi
        fi
    fi

    if [ "$installed" = true ]; then
        log_success "检测到 WG-Easy 已安装并正在运行"
        log_info "Web管理面板公网: http://${wanip}:${DEFAULT_WEB_PORT}"
		log_info "Web管理面板内网: http://$(hostname -I | awk '{print $1}'):${DEFAULT_WEB_PORT}"
        log_info "如需重新安装，请先停止并删除容器："
        log_info "  docker stop wg-easy && docker rm wg-easy"
        log_info "  rm -rf /etc/docker/containers/wg-easy"
        log_info "然后重新运行此脚本。"
        exit 0
    fi
}
# ==================== 主流程 ====================
main() {
	fix_github_hosts   # 先自动修复 DNS
	check_installed   # 先检测是否已安装
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

# ==================== 清理临时文件 ====================
# 保留 install.log 和 quick-ref.txt 供用户查阅
rm -f "$SCRIPT_SELF" 2>/dev/null
exit 0
