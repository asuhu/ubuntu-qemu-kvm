#!/usr/bin/env bash
# =============================================================================
# Cockpit 自动安装脚本
# 适配系统: Rocky 8/9 / CentOS Stream 8/9 / Ubuntu 20.04/22.04/24.04 /
#           Debian 11/12
# 功能: 自动安装 Cockpit 及插件，启动服务，开放防火墙端口
# =============================================================================

set -euo pipefail

# =============================================================================
# 颜色定义
# =============================================================================
GREEN='\e[1;32m'
YELLOW='\e[1;33m'
RED='\e[1;31m'
CYAN='\e[1;36m'
RESET='\e[0m'

# =============================================================================
# 检测系统类型
# =============================================================================
if [ ! -f /etc/os-release ]; then
    echo -e "${RED}错误: 无法识别系统类型，缺少 /etc/os-release${RESET}"
    exit 1
fi

. /etc/os-release
OS_ID="${ID}"
OS_VER="${VERSION_ID%%.*}"   # 只取主版本号，如 22.04 → 22

echo -e "${CYAN}================================================================${RESET}"
echo -e "${CYAN} Cockpit 自动安装脚本${RESET}"
echo -e "${CYAN}----------------------------------------------------------------${RESET}"
echo -e " 检测到系统: ${PRETTY_NAME}"
echo -e "${CYAN}================================================================${RESET}"

# =============================================================================
# Root 权限检查
# =============================================================================
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 请使用 root 权限运行此脚本${RESET}"
    exit 1
fi

# =============================================================================
# 公共插件列表
# 这些插件在 RHEL 系 和 Debian 系均有对应包
# =============================================================================
COMMON_PLUGINS=(
    cockpit-machines          # KVM 虚拟机管理
    cockpit-storaged          # 磁盘/存储管理
    cockpit-networkmanager    # 网络管理
    cockpit-packagekit        # 软件包更新
    cockpit-podman            # 容器管理
    cockpit-sosreport         # 系统诊断报告
)

# =============================================================================
# 各系统专属插件
# 部分插件只在特定平台存在，单独管理避免安装失败
# =============================================================================
RHEL_ONLY_PLUGINS=(
    cockpit-selinux           # SELinux 策略管理  (RHEL 系专属)
    cockpit-kdump             # 内核崩溃转储      (RHEL 系专属)
    cockpit-ostree            # OSTree 系统更新   (Fedora/RHEL 专属)
    cockpit-composer          # Image Builder     (RHEL 系专属)
    cockpit-session-recording # 会话录制           (RHEL 系专属)
    cockpit-files             # 文件管理器         (较新版本支持)
)

DEBIAN_ONLY_PLUGINS=(
    cockpit-files             # 文件管理器         (较新版本支持)
)

# =============================================================================
# 尝试安装插件（逐个安装，跳过不存在的包，不中断整体流程）
# 参数: 包管理器命令前缀、插件数组
# =============================================================================
install_plugins() {
    local pkg_cmd="$1"
    shift
    local plugins=("$@")
    local ok=0
    local skip=0

    for plugin in "${plugins[@]}"; do
        echo -n "  安装 ${plugin} ... "
        if eval "$pkg_cmd $plugin" > /dev/null 2>&1; then
            echo -e "${GREEN}✓${RESET}"
            (( ok++ )) || true
        else
            echo -e "${YELLOW}跳过（包不存在或安装失败）${RESET}"
            (( skip++ )) || true
        fi
    done

    echo -e "  插件安装完成: ${GREEN}成功 ${ok} 个${RESET} / ${YELLOW}跳过 ${skip} 个${RESET}"
}

# =============================================================================
# 防火墙配置（自动检测 firewalld / ufw / iptables）
# =============================================================================
configure_firewall() {
    echo "配置防火墙，开放 9090 端口..."
    if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        firewall-cmd --permanent --add-service=cockpit
        firewall-cmd --permanent --add-port=9090/tcp
        firewall-cmd --reload
        echo -e "  ${GREEN}firewalld: 已开放 9090/tcp${RESET}"
    elif command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow 9090/tcp
        echo -e "  ${GREEN}ufw: 已开放 9090/tcp${RESET}"
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport 9090 -j ACCEPT
        echo -e "  ${YELLOW}iptables: 已临时开放 9090/tcp（重启后失效，请自行持久化）${RESET}"
    else
        echo -e "  ${YELLOW}未检测到防火墙，请手动确认 9090 端口可访问${RESET}"
    fi
}

# =============================================================================
# 启动 Cockpit 服务
# =============================================================================
enable_cockpit() {
    echo "启动 Cockpit 服务..."
    systemctl enable --now cockpit.socket
    echo -e "  ${GREEN}cockpit.socket 已启动并设为开机自启${RESET}"
}

# =============================================================================
# 安装完成提示
# =============================================================================
finish() {
    local ip
    ip=$(hostname -I | awk '{print $1}')
    echo ""
    echo -e "${GREEN}================================================================${RESET}"
    echo -e "${GREEN} Cockpit 安装完成！${RESET}"
    echo -e "${GREEN}----------------------------------------------------------------${RESET}"
    echo -e " 访问地址: ${CYAN}https://${ip}:9090${RESET}"
    echo -e " 或使用:   ${CYAN}https://$(hostname):9090${RESET}"
    echo -e "${GREEN}================================================================${RESET}"
}

# =============================================================================
# RHEL 系安装流程 (Rocky / CentOS Stream / AlmaLinux)
# =============================================================================
install_rhel() {
    echo "安装基础包 cockpit..."
    dnf install -y cockpit

    echo "安装公共插件..."
    install_plugins "dnf install -y" "${COMMON_PLUGINS[@]}"

    echo "安装 RHEL 系专属插件..."
    install_plugins "dnf install -y" "${RHEL_ONLY_PLUGINS[@]}"

    enable_cockpit
    configure_firewall
    finish
}

# =============================================================================
# Debian 系安装流程 (Ubuntu / Debian)
# =============================================================================
install_debian() {
    echo "更新软件源..."
    apt-get update -y

    echo "安装基础包 cockpit..."
    apt-get install -y cockpit

    echo "安装公共插件..."
    install_plugins "apt-get install -y" "${COMMON_PLUGINS[@]}"

    echo "安装 Debian 系专属插件..."
    install_plugins "apt-get install -y" "${DEBIAN_ONLY_PLUGINS[@]}"

    enable_cockpit
    configure_firewall
    finish
}

# =============================================================================
# 系统分发路由
# =============================================================================
case "$OS_ID" in
    rocky|centos|almalinux|rhel)
        echo "系统类型: RHEL 系 (${OS_ID} ${OS_VER})"
        install_rhel
        ;;
    ubuntu|debian)
        echo "系统类型: Debian 系 (${OS_ID} ${OS_VER})"
        install_debian
        ;;
    *)
        echo -e "${RED}错误: 不支持的系统 '${OS_ID} ${OS_VER}'${RESET}"
        echo "支持的系统: Rocky / CentOS Stream / AlmaLinux / Ubuntu / Debian"
        exit 1
        ;;
esac
