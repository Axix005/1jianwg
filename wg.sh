#!/bin/bash
# WG-Easy 安装脚本【最小补丁版｜仅修复ghcr拉取失败，其余保留原版原貌】
set -e

WG_PORT="51820"
WEB_PORT="51821"
DNS_MAIN="223.5.5.5"
DNS_FALLBACK="114.114.114.114"
WG_IMAGE_SRC="ghcr.nju.edu.cn/wg-easy/wg-easy:15"
COMPOSE_DIR="/etc/docker/containers/wg-easy"
LOG_FILE="/root/wg-easy-install.log"
INFO_FILE="/root/wg-easy-quick-ref.txt"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo -e "$1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
    log "[ERROR] $1"
    exit 1
}

success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}" | tee -a "$LOG_FILE"
}

warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}" | tee -a "$LOG_FILE"
}

if [ -t 1 ]; then
    log_info() { echo -e "${BLUE}[INFO] $1${NC}"; }
else
    log_info() { echo "[INFO] $1"; }
fi

# 修复raw.githubusercontent hosts
fix_github_hosts() {
    log_info "正在修复 raw.githubusercontent.com 解析..."
    local domain="raw.githubusercontent.com"
    if grep -q "$domain" /etc/hosts; then
        local ip=$(grep "$domain" /etc/hosts | awk '{print $1}')
        if curl -4 -s --connect-timeout 3 -o /dev/null "https://raw.githubusercontent.com" --resolve "$domain:443:$ip"; then
            log_info "hosts已有可用记录，跳过"
            return 0
        else
            sed -i "/$domain/d" /etc/hosts
        fi
    fi
    local ip_list=("185.199.108.133" "185.199.109.133" "185.199.110.133" "185.199.111.133")
    for ip in "${ip_list[@]}"; do
        if curl -4 -s --connect-timeout 3 -o /dev/null "https://raw.githubusercontent.com" --resolve "$domain:443:$ip"; then
            echo "$ip $domain" >> /etc/hosts
            log_info "已绑定 $domain -> $ip"
            return 0
        fi
    done
    warning "无法绑定raw.githubusercontent hosts，将使用ghproxy备用链路下载"
}

# 系统DNS配置
setup_dns() {
    log_info "配置系统DNS：${DNS_MAIN} ${DNS_FALLBACK}"
    if [ -f /etc/resolv.conf ] && [ ! -f /etc/resolv.conf.bak.wgeasy ]; then
        cp -f /etc/resolv.conf /etc/resolv.conf.bak.wgeasy 2>/dev/null || true
    fi
    chattr -i /etc/resolv.conf 2>/dev/null || true
    if systemctl is-active --quiet systemd-resolved; then
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/wgeasy-dns.conf <<EOF
[Resolve]
DNS=${DNS_MAIN} ${DNS_FALLBACK}
FallbackDNS=
EOF
        systemctl restart systemd-resolved 2>/dev/null || true
    fi
    if [ -L /etc/resolv.conf ]; then
        rm -f /etc/resolv.conf
    fi
    cat > /etc/resolv.conf <<EOF
nameserver ${DNS_MAIN}
nameserver ${DNS_FALLBACK}
EOF
}

# 获取公网IP
get_public_ip() {
    local ip=""
    ip=$(curl -4 -s --connect-timeout 5 https://api.ipify.org 2>/dev/null)
    [ -z "$ip" ] && ip=$(curl -4 -s --connect-timeout 5 https://ifconfig.me/ip 2>/dev/null)
    [ -z "$ip" ] && ip=$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null)
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip"
    else
        echo ""
    fi
}

# 检测SSH端口
detect_ssh_port() {
    local sp="22"
    if [ -f /etc/ssh/sshd_config ]; then
        sp=$(grep -E "^Port\s+" /etc/ssh/sshd_config | awk '{print $2}' | head -n1)
    fi
    if [ -z "$sp" ] && [ -d /etc/ssh/sshd_config.d/ ]; then
        sp=$(grep -rE "^Port\s+" /etc/ssh/sshd_config.d/ 2>/dev/null | awk '{print $2}' | head -n1)
    fi
    echo "${sp:-22}"
}

# UFW配置
configure_ufw() {
    local ssh_port=$(detect_ssh_port)
    log_info "检测SSH端口：$ssh_port"
    ufw allow "${ssh_port}/tcp" >/dev/null 2>&1 || warning "SSH放行失败，请手动 ufw allow ${ssh_port}/tcp"
    ufw allow "${WG_PORT}/udp" >/dev/null 2>&1 || warning "WireGuard端口放行失败，请手动 ufw allow ${WG_PORT}/udp"
    ufw allow "${WEB_PORT}/tcp" >/dev/null 2>&1 || warning "Web面板端口放行失败，请手动 ufw allow ${WEB_PORT}/tcp"
    if ! ufw status | grep -q "Status: active"; then
        echo "y" | ufw enable >/dev/null 2>&1
        success "UFW已启用"
    fi
    log_info "UFW状态："
    ufw status | tee -a "$LOG_FILE"
}

# 安装Docker
install_docker() {
    if command -v docker &>/dev/null; then
        log_info "Docker已存在，跳过安装"
        return 0
    fi
    log_info "开始安装Docker（阿里云源）"
    rm -f /etc/apt/sources.list.d/docker.list /usr/share/keyrings/docker-archive-keyring.gpg
    mkdir -p /usr/share/keyrings
    local gpg_tmp="/tmp/docker.gpg"
    local ok=false
    for i in {1..5}; do
        if curl -4 -fsSL --connect-timeout 10 https://download.docker.com/linux/debian/gpg -o "$gpg_tmp"; then
            ok=true
            break
        fi
        warning "GPG密钥下载失败，重试 $i/5"
        sleep 2
    done
    if [ "$ok" = false ]; then
        error "Docker GPG密钥多次下载失败"
    fi
    gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg "$gpg_tmp"
    rm -f "$gpg_tmp"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://mirrors.aliyun.com/docker-ce/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq || { warning "apt update失败，重试"; apt-get update -qq; }
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
    success "Docker安装完成"
}

# 下载compose.yml【补丁点：多链路 + 自动替换镜像】
download_compose() {
    log_info "下载docker-compose.yml"
    mkdir -p "$COMPOSE_DIR"
    cd "$COMPOSE_DIR" || error "无法进入目录 $COMPOSE_DIR"
    local target="docker-compose.yml"
    local url_list=(
        "https://raw.githubusercontent.com/wg-easy/wg-easy/master/docker-compose.yml"
        "https://ghfast.top/https://raw.githubusercontent.com/wg-easy/wg-easy/master/docker-compose.yml"
        "https://mirror.ghproxy.com/https://raw.githubusercontent.com/wg-easy/wg-easy/master/docker-compose.yml"
    )
    local dl_ok=false
    for u in "${url_list[@]}"; do
        if curl -4 -fsSL --connect-timeout 10 -o "$target" "$u"; then
            dl_ok=true
            break
        fi
        warning "链路 $u 下载失败，切换下一个"
    done
    if [ "$dl_ok" = false ]; then
        error "所有链路下载docker-compose.yml失败"
    fi
    # 替换ghcr.io镜像为南大镜像，解决拉取失败
    sed -i "s|image: ghcr.io/wg-easy/wg-easy:.*|image: ${WG_IMAGE_SRC}|g" "$target"
    log_info "已替换镜像为：${WG_IMAGE_SRC}"
}

# 清理旧容器
clean_old() {
    if docker ps -a --format '{{.Names}}' | grep -q "^wg-easy$"; then
        warning "检测到旧wg-easy容器，停止并删除"
        docker stop wg-easy >/dev/null
        docker rm wg-easy >/dev/null
    fi
}

# 启动服务
start_service() {
    cd "$COMPOSE_DIR" || error "无法进入 $COMPOSE_DIR"
    log_info "拉取镜像并启动wg-easy"
    docker compose up -d
    sleep 5
    if docker ps --format '{{.Names}}' | grep -q "^wg-easy$"; then
        success "WG-Easy容器启动成功"
    else
        error "容器启动失败，请执行 docker compose logs 查看"
    fi
}

# 写入信息文件
write_info() {
    local pub_ip="$1"
    local lan_ip=$(hostname -I | awk '{print $1}')
    cat > "$INFO_FILE" <<EOF
=== WG-Easy 快速参考 ===
公网面板: http://${pub_ip}:${WEB_PORT}
内网面板: http://${lan_ip}:${WEB_PORT}
WireGuard UDP端口: ${WG_PORT}
数据目录: ${COMPOSE_DIR}

常用命令：
查看状态: docker compose ps
查看日志: docker compose logs -f
重启: docker compose restart
停止: docker compose down
更新: docker compose pull && docker compose up -d
EOF
    log_info "信息已写入：$INFO_FILE"
}

# 检测是否已安装
check_installed() {
    if command -v docker &>/dev/null && docker ps --format '{{.Names}}' | grep -q "^wg-easy$" && [ -f "${COMPOSE_DIR}/docker-compose.yml" ]; then
        log_info "WG-Easy 已经在运行，无需重复安装"
        log_info "如需重装：docker stop wg-easy && docker rm wg-easy && rm -rf ${COMPOSE_DIR}"
        exit 0
    fi
}

# 主流程
main() {
    check_installed
    fix_github_hosts
    setup_dns
    install_docker
    check_compose() {
        if docker compose version >/dev/null 2>&1; then
            log_info "Docker Compose Plugin就绪"
            return 0
        fi
        warning "未检测到compose插件，尝试安装"
        apt-get update -qq
        apt-get install -y -qq docker-compose-plugin
        if ! docker compose version >/dev/null 2>&1; then
            error "compose插件安装失败"
        fi
        success "compose插件安装完成"
    }
    check_compose

    wanip=$(get_public_ip)
    if [ -z "$wanip" ]; then
        warning "自动获取公网IP失败，请手动输入"
        read -p "公网IP: " wanip
        if [[ ! "$wanip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            error "IP格式非法"
        fi
    fi
    log_info "使用公网IP：$wanip"

    local UFW_INSTALL="false"
    if command -v ufw &>/dev/null; then
        log_info "UFW已安装，准备放行端口"
        configure_ufw
    else
        read -p "是否安装UFW防火墙？y/回车跳过：" ufw_choice
        if [[ "$ufw_choice" == "y" || "$ufw_choice" == "Y" ]]; then
            log_info "安装UFW"
            apt-get install -y -qq ufw
            configure_ufw
        else
            log_info "跳过UFW安装，请自行放行端口 ${WG_PORT}/udp ${WEB_PORT}/tcp"
        fi
    fi

    download_compose
    clean_old
    start_service
    write_info "$wanip"

    success "===== 安装全部完成 ====="
    log_info "外网面板：http://${wanip}:${WEB_PORT}"
    log_info "内网面板：http://$(hostname -I | awk '{print $1}'):${WEB_PORT}"
    log_warn() { echo -e "${YELLOW}[提示] 首次打开面板设置管理员密码${NC}"; }
    log_warn
}

main "$@"
rm -f "$0"
exit 0
