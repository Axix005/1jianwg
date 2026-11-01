#!/bin/bash

# WG-Easy 安装脚本（官方Docker Compose）

set -e
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_NAME=$(basename "${BASH_SOURCE[0]}")
SCRIPT_SELF="$SCRIPT_DIR/$SCRIPT_NAME"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="/root/wg-easy-install.log"
INFO_FILE="/root/wg-easy-quick-ref.txt"

log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo -e "$1" | tee -a "$LOG_FILE"
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

if ! command -v curl &> /dev/null; then
    echo "检测到curl未安装，正在自动安装..."
    apt-get update && apt-get install -y curl || { echo "安装curl失败，请手动安装后重试"; exit 1; }
fi

fix_github_hosts() {
    if grep -q "raw.githubusercontent.com" /etc/hosts; then
        local current_ip=$(grep "raw.githubusercontent.com" /etc/hosts | awk '{print $1}')
        if curl -s --connect-timeout 3 -o /dev/null "https://raw.githubusercontent.com" --resolve "raw.githubusercontent.com:443:$current_ip"; then
            return 0
        else
            sed -i '/raw.githubusercontent.com/d' /etc/hosts
        fi
    fi

    for ip in 185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133; do
        if curl -s --connect-timeout 3 -o /dev/null "https://raw.githubusercontent.com" --resolve "raw.githubusercontent.com:443:$ip"; then
            echo "$ip raw.githubusercontent.com" >> /etc/hosts
            log_info "已绑定 raw.githubusercontent.com 到 $ip"
            return 0
        fi
    done

    log_warning "无法自动绑定 raw.githubusercontent.com，依赖后续代理下载"
}

function get_public_ip() {
    local ip=""

    local cloudflare_resp=$(curl -sS --connect-timeout 5 -m 10 \
        -H "User-Agent: Mozilla/5.0" \
        https://cloudflare-dns.com/dns-query?name=one.one.one.one&type=A 2>/dev/null)
    ip=$(echo "$cloudflare_resp" | grep -A 1 "Answer" | awk -F '"' '{print $4}' 2>/dev/null)

    [ -z "$ip" ] && ip=$(curl -sS --connect-timeout 5 -m 10 https://api.ipify.org 2>/dev/null)

    [ -z "$ip" ] && {
        local aliyun_resp=$(curl -sS --connect-timeout 5 -m 10 http://dns.alidns.com/dns-query?name=one.one.one.one&type=A 2>/dev/null)
        ip=$(echo "$aliyun_resp" | grep -A 1 "Answer" | awk -F '"' '{print $4}' 2>/dev/null)
    }

    [ -z "$ip" ] && ip=$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null)

    if [[ "$ip" =~ ^10\. ]] || [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || [[ "$ip" =~ ^192\.168\. ]]; then
        ip=""
    fi

    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "❌ 获取到无效IP: $ip" >&2
        return 1
    fi

    echo "$ip"
}

wanip=$(get_public_ip)

if [ $? -ne 0 ] || [ -z "$wanip" ]; then
    echo -e "\n⚠️ 自动探测失败！正在回退到手动模式..."
    read -p "请输入你的公网IP地址: " wanip
fi

if [[ ! "$wanip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "❌ 无效的IP格式: $wanip" >&2
    exit 1
fi

echo "✅ 使用最终确认的公网IP: $wanip"

DEFAULT_WG_PORT="51820"
DEFAULT_WEB_PORT="51821"
INSTALL_UFW="false"

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
    if command -v docker &> /dev/null; then
        log_info "Docker 已安装，跳过安装步骤"
        return 0
    fi

    log_info "安装Docker..."

    unset http_proxy https_proxy all_proxy 2>/dev/null
    rm -f /etc/apt/sources.list.d/docker.list
    rm -f /etc/apt/trusted.gpg.d/docker.gpg
    rm -f /usr/share/keyrings/docker-archive-keyring.gpg

    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq ca-certificates curl gnupg >/dev/null 2>&1

    mkdir -p /usr/share/keyrings

    local tmp_gpg="/tmp/docker.gpg"
    local retry=0
    local max_retry=5
    local success=false

    while [ $retry -lt $max_retry ]; do
        retry=$((retry + 1))
        log_info "尝试下载 Docker GPG 密钥 (第 $retry/$max_retry 次)..."
        if curl -4 -fsSL --connect-timeout 10 --retry 3 -o "$tmp_gpg" "https://download.docker.com/linux/debian/gpg"; then
            if [ -s "$tmp_gpg" ]; then
                success=true
                break
            fi
        fi
        log_warning "官方源下载失败，尝试阿里云镜像..."
        if curl -4 -fsSL --connect-timeout 10 --retry 3 -o "$tmp_gpg" "https://mirrors.aliyun.com/docker-ce/linux/debian/gpg"; then
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

    gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg "$tmp_gpg" >/dev/null 2>&1
    rm -f "$tmp_gpg"

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://mirrors.aliyun.com/docker-ce/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

    log_info "更新 APT 源..."
    if ! apt-get update >/dev/null 2>&1; then
        log_warning "APT 更新失败，等待 3 秒后重试..."
        sleep 3
        if ! apt-get update >/dev/null 2>&1; then
            log_warning "阿里云 Docker 源更新失败，切换腾讯云源..."
            sed -i 's/mirrors.aliyun.com/mirrors.cloud.tencent.com/' /etc/apt/sources.list.d/docker.list
            apt-get update >/dev/null 2>&1 || {
                log_error "APT 更新仍然失败，请检查网络或源配置"
                exit 1
            }
        fi
    fi

    log_info "安装 Docker 组件..."
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io >/dev/null 2>&1 || {
        log_error "Docker 安装失败"
        exit 1
    }

    systemctl enable --now docker >/dev/null 2>&1

    log_success "Docker 安装完成"
}

install_docker_compose() {
    log_info "安装Docker Compose..."

    COMPOSE_VERSION=$(curl -s --connect-timeout 10 --max-time 10 --retry 3 "https://api.github.com/repos/docker/compose/releases/latest" | grep 'tag_name' | cut -d '"' -f 4)
    if [ -z "$COMPOSE_VERSION" ]; then
        log_warning "从 GitHub API 获取版本失败，尝试镜像..."
        COMPOSE_VERSION=$(curl -s --connect-timeout 10 --max-time 10 --retry 3 "https://githubproxy.cc/https://api.github.com/repos/docker/compose/releases/latest" | grep 'tag_name' | cut -d '"' -f 4)
        if [ -z "$COMPOSE_VERSION" ]; then
            log_error "获取 Docker Compose 版本号失败"
            exit 1
        fi
    fi

    log_info "目标版本: $COMPOSE_VERSION"

    local compose_filename="docker-compose-$(uname -s)-$(uname -m)"

    # 路径1：清华 TUNA 的 docker-compose/latest 重定向路径（不是 github-release 路径，后者会404）
    local tuna_latest_url="https://mirrors.tuna.tsinghua.edu.cn/docker-compose/latest/$(uname -s)/$(uname -m)/docker-compose"
    # 路径2：阿里云 Docker Toolbox 镜像（按版本目录）
    local aliyun_url="https://mirrors.aliyun.com/docker-toolbox/linux/compose/${COMPOSE_VERSION}/${compose_filename}"
    # 路径3：GitHub 直连
    local github_url="https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/${compose_filename}"

    log_info "下载 Docker Compose 二进制文件..."
    if curl -fL -o /usr/local/bin/docker-compose --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 2 "$tuna_latest_url"; then
        log_success "已从清华 TUNA 下载"
    elif curl -fL -o /usr/local/bin/docker-compose --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 2 "$aliyun_url"; then
        log_success "已从阿里云镜像下载"
    elif curl -fL -o /usr/local/bin/docker-compose --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 2 "$github_url"; then
        log_success "已从 GitHub 直连下载"
    else
        log_error "Docker Compose 二进制下载失败。请手动下载并放置到 /usr/local/bin/docker-compose：
  https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/${compose_filename}"
        exit 1
    fi

    chmod +x /usr/local/bin/docker-compose
    # 验证不是HTML报错页
    if ! /usr/local/bin/docker-compose version &>/dev/null; then
        log_error "下载的文件不是有效的 Docker Compose 二进制（可能是镜像返回了HTML错误页）"
        exit 1
    fi
    log_success "Docker Compose 安装完成 ($(/usr/local/bin/docker-compose version 2>&1 | head -1))"
}

setup_config() {
    log_info "创建配置目录..."
    mkdir -p /etc/docker/containers/wg-easy
    cd /etc/docker/containers/wg-easy || exit

    log_info "下载官方 Docker Compose 文件..."

    # 优先使用 githubproxy.cc 前缀代理（raw 文件有效），再尝试 ghfast.top，最后直连
    local raw_url="https://raw.githubusercontent.com/wg-easy/wg-easy/master/docker-compose.yml"
    if curl -fL -o docker-compose.yml --connect-timeout 10 --max-time 30 --retry 2 --retry-delay 2 "https://githubproxy.cc/${raw_url}"; then
        log_success "已通过 githubproxy.cc 下载"
    elif curl -fL -o docker-compose.yml --connect-timeout 10 --max-time 30 --retry 2 --retry-delay 2 "https://ghfast.top/${raw_url}"; then
        log_success "已通过 ghfast.top 下载"
    elif curl -fL -o docker-compose.yml --connect-timeout 10 --max-time 30 --retry 2 --retry-delay 2 "$raw_url"; then
        log_success "已从 raw.githubusercontent.com 直连下载"
    else
        log_error "下载失败，请手动将 https://raw.githubusercontent.com/wg-easy/wg-easy/master/docker-compose.yml 保存到 $(pwd)/docker-compose.yml"
        exit 1
    fi

    # 验证不是HTML错误页
    if ! grep -q "services:" docker-compose.yml; then
        log_error "下载的 docker-compose.yml 内容异常（可能被镜像返回了错误页）"
        exit 1
    fi
}

detect_ssh_port() {
    local ssh_port="22"
    if [ -f /etc/ssh/sshd_config ]; then
        ssh_port=$(grep -E "^Port\s+" /etc/ssh/sshd_config | awk '{print $2}')
    fi
    if [ -z "$ssh_port" ] && [ -d /etc/ssh/sshd_config.d/ ]; then
        ssh_port=$(grep -r -E "^Port\s+" /etc/ssh/sshd_config.d/ 2>/dev/null | head -1 | awk '{print $2}')
    fi
    ssh_port=${ssh_port:-22}
    echo "$ssh_port"
}

configure_firewall() {
    if [ "$INSTALL_UFW" = "installed" ]; then
        log_info "UFW 已安装，正在配置防火墙规则..."
        configure_ufw_rules
    elif [ "$INSTALL_UFW" = "true" ]; then
        log_info "正在安装 UFW 防火墙..."
        if apt-get update && apt-get install -y ufw >/dev/null 2>&1; then
            log_success "UFW 安装完成"
            configure_ufw_rules
        else
            log_warning "UFW 安装失败，跳过防火墙配置（不影响后续安装）"
        fi
    else
        log_info "UFW 防火墙未启用，跳过配置"
        log_success "防火墙配置阶段完成（已跳过）"
    fi
}

configure_ufw_rules() {
    log_info "配置 UFW 防火墙规则..."
    local ssh_port=$(detect_ssh_port)
    log_info "检测到 SSH 端口: $ssh_port"

    if ufw allow "${ssh_port}/tcp" >/dev/null 2>&1; then
        log_success "✅ 已放行 SSH 端口：${ssh_port}/TCP"
    else
        log_warning "⚠️ 无法放行 SSH 端口 ${ssh_port}（请手动执行：ufw allow ${ssh_port}/tcp）"
    fi

    if ufw allow "${DEFAULT_WG_PORT}/udp" >/dev/null 2>&1; then
        log_success "✅ 已放行 WireGuard 端口：${DEFAULT_WG_PORT}/UDP"
    else
        log_warning "⚠️ 无法放行 WireGuard 端口（请手动执行：ufw allow ${DEFAULT_WG_PORT}/udp）"
    fi

    if ufw allow "${DEFAULT_WEB_PORT}/tcp" >/dev/null 2>&1; then
        log_success "✅ 已放行 Web 管理端口：${DEFAULT_WEB_PORT}/TCP"
    else
        log_warning "⚠️ 无法放行 Web 管理端口（请手动执行：ufw allow ${DEFAULT_WEB_PORT}/tcp）"
    fi

    if ! ufw status | grep -q "Status: active"; then
        echo "y" | ufw enable >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            log_success "UFW 防火墙已成功启用"
            log_info "已放行端口: SSH(${ssh_port}), WG(${DEFAULT_WG_PORT}/UDP), WEB(${DEFAULT_WEB_PORT}/TCP)"
        else
            log_warning "UFW 启用失败，规则可能未生效，请手动执行：ufw enable"
        fi
    else
        log_info "UFW 防火墙已处于启用状态"
    fi

    log_info "当前防火墙状态："
    ufw status | tee -a "$LOG_FILE"
    log_success "防火墙配置完成"
}

start_wg_easy() {
    log_info "启动WG-Easy服务..."

    if docker ps -a | grep -q "wg-easy"; then
        log_warning "检测到旧容器，正在清理..."
        rm -rf /root/wg-easy-install.log
        rm -rf /root/wg-easy-quick-ref.txt
        docker stop wg-easy && docker rm wg-easy
    fi

    cd /etc/docker/containers/wg-easy || exit

    # 关键改动：在启动前替换 ghcr.io 为 DaoCloud ghcr 加速前缀
    # daemon.json 的 registry-mirrors 对 ghcr.io 不生效，必须直接改镜像地址
    if grep -q "ghcr.io/wg-easy/wg-easy" docker-compose.yml; then
        log_info "将镜像地址 ghcr.io 替换为 ghcr.m.daocloud.io（绕开 ghcr.io DNS 解析失败）..."
        sed -i 's#ghcr.io/wg-easy/wg-easy#ghcr.m.daocloud.io/wg-easy/wg-easy#g' docker-compose.yml
        log_success "镜像地址已替换为：ghcr.m.daocloud.io/wg-easy/wg-easy"
    fi

    docker compose up -d
    sleep 5

    if docker compose ps | grep -q "Up"; then
        log_success "WG-Easy服务已启动"
    else
        log_error "服务启动失败，请检查日志：docker compose -f /etc/docker/containers/wg-easy/docker-compose.yml logs -f"
        exit 1
    fi
}

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
镜像: ghcr.m.daocloud.io/wg-easy/wg-easy:15（已替换为DaoCloud加速）
命令:
  启动: docker compose -f /etc/docker/containers/wg-easy/docker-compose.yml up -d
  停止: docker compose -f /etc/docker/containers/wg-easy/docker-compose.yml down
  日志: docker compose -f /etc/docker/containers/wg-easy/docker-compose.yml logs -f
EOF
    log_success "安装信息已保存到$LOG_FILE和$INFO_FILE"
}

check_installed() {
    local installed=false

    if command -v docker &> /dev/null; then
        if docker ps --format '{{.Names}}' | grep -q "^wg-easy$"; then
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

main() {
    fix_github_hosts

    if command -v ufw &> /dev/null; then
        log_info "检测到 UFW 已安装，将直接配置防火墙规则"
        INSTALL_UFW="installed"
    else
        log_info "未检测到 UFW 防火墙"
        read -p "是否安装并配置 UFW 防火墙？输入 y 确认，按 Enter 跳过（默认不安装）: " ufw_choice
        if [[ "$ufw_choice" == "y" || "$ufw_choice" == "Y" ]]; then
            INSTALL_UFW="true"
            log_info "将在安装过程中安装并配置 UFW 防火墙"
        else
            INSTALL_UFW="false"
            log_info "跳过 UFW 防火墙安装和配置"
        fi
    fi

    check_installed

    log_info "开始安装WG-Easy官方版..."
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

main "$@"

rm -f "$SCRIPT_SELF" 2>/dev/null
exit 0
