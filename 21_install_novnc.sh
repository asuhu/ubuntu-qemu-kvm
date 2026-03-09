#!/usr/bin/env bash
# =============================================================================
# noVNC + websockify 安装脚本
#
# 适配系统: Ubuntu 20.04/22.04/24.04 / Debian 11/12 /
#           Rocky 8/9 / CentOS Stream 8/9 / 麒麟 Kylin V10
#
# 功能:
#   1. 安装系统依赖
#   2. 安装 websockify（pip 优先，源码兜底）
#   3. 下载 noVNC（git 优先，tar.gz 兜底）
#   4. 配置防火墙基础端口
#
# noVNC 工作原理:
#   浏览器 → WebSocket(:608x) → websockify → VNC TCP(:590x) → 虚拟机
#   websockify 负责协议转换，noVNC 提供纯静态 Web 界面（无需 npm 构建）
#
# 安装完成后通过 start_novnc.sh 启动各 VM 的映射服务
# =============================================================================

set -euo pipefail

# =============================================================================
# ★ 配置区 — 按需修改
# =============================================================================
NOVNC_DIR="/opt/noVNC"                                   # noVNC 安装目录
NOVNC_VERSION="v1.5.0"                                   # noVNC git tag 版本
WEBSOCKIFY_VERSION="0.12.0"                              # websockify pip 版本
PYPI_MIRROR="https://mirrors.aliyun.com/pypi/simple"     # pip 镜像源

# =============================================================================
# 颜色 & 工具函数
# =============================================================================
GREEN='\e[1;32m'; YELLOW='\e[1;33m'
RED='\e[1;31m';   CYAN='\e[1;36m'; RESET='\e[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }

# =============================================================================
# 系统检测与权限校验
# =============================================================================
[ ! -f /etc/os-release ] && error "无法识别系统类型，缺少 /etc/os-release"
. /etc/os-release
OS_ID="${ID}"
[[ $EUID -ne 0 ]] && error "请使用 root 权限运行此脚本"

echo -e "${CYAN}================================================================${RESET}"
echo -e "${CYAN} noVNC + websockify 安装脚本${RESET}"
echo -e "${CYAN}----------------------------------------------------------------${RESET}"
echo -e " 检测到系统 : ${PRETTY_NAME}"
echo -e " noVNC 版本 : ${NOVNC_VERSION}"
echo -e " 安装目录   : ${NOVNC_DIR}"
echo -e "${CYAN}================================================================${RESET}"

# =============================================================================
# 一、安装系统依赖
# =============================================================================
info "安装系统依赖..."

case "$OS_ID" in
    ubuntu|debian)
        apt-get update -y -qq
        apt-get install -y git python3 python3-pip python3-venv \
            libssl-dev wget curl
        ;;
    rocky|centos|almalinux|rhel|kylin)
        yum install -y git python3 python3-pip gcc \
            openssl-devel libffi-devel wget curl
        ;;
    *)
        error "不支持的系统 '${OS_ID}'，支持: Ubuntu/Debian/Rocky/CentOS/麒麟"
        ;;
esac
success "系统依赖安装完成"

# =============================================================================
# 二、安装 websockify
#
# websockify 是浏览器 WebSocket 与 VNC TCP 之间的协议转换层。
# 优先级: pip 安装（版本固定） → pip 安装最新版 → 源码编译兜底
# =============================================================================
info "安装 websockify ${WEBSOCKIFY_VERSION}..."

pip3 config set global.index-url "${PYPI_MIRROR}" > /dev/null 2>&1 || true

if pip3 install -U "websockify==${WEBSOCKIFY_VERSION}" 2>/dev/null || \
   pip3 install -U websockify 2>/dev/null; then
    success "websockify 通过 pip 安装成功"
else
    warn "pip 安装失败，尝试从 GitHub 源码安装..."
    WEBSOCKIFY_SRC="/opt/websockify"
    if [ -d "${WEBSOCKIFY_SRC}" ]; then
        git -C "${WEBSOCKIFY_SRC}" pull --ff-only 2>/dev/null || true
    else
        git clone --depth=1 https://github.com/novnc/websockify.git "${WEBSOCKIFY_SRC}"
    fi
    # 使用 pip install . 替代已废弃的 setup.py install
    pip3 install "${WEBSOCKIFY_SRC}"
    success "websockify 通过源码安装成功"
fi

# 验证安装路径（pip 有时装到 ~/.local/bin，不在默认 PATH 中）
WEBSOCKIFY_BIN=$(which websockify 2>/dev/null || true)
if [ -z "${WEBSOCKIFY_BIN}" ]; then
    for p in /usr/local/bin/websockify /usr/bin/websockify \
              "${HOME}/.local/bin/websockify"; do
        [ -x "$p" ] && WEBSOCKIFY_BIN="$p" && break
    done
fi
[ -z "${WEBSOCKIFY_BIN}" ] && error "websockify 安装后未找到可执行文件，请检查 PATH"
success "websockify 路径: ${WEBSOCKIFY_BIN}"

# 将实际路径写入配置，供 start_novnc.sh 读取
echo "${WEBSOCKIFY_BIN}" > /etc/novnc_websockify_path
success "websockify 路径已保存至 /etc/novnc_websockify_path"

# =============================================================================
# 三、下载 noVNC
#
# noVNC 是纯静态 Web 文件 (HTML/JS/CSS)，无需 npm 构建，
# 直接将目录通过 websockify --web 参数提供 HTTP 服务即可。
# 优先级: git clone（可后续 git pull 升级） → tar.gz 备用
# =============================================================================
if [ -d "${NOVNC_DIR}/.git" ]; then
    info "noVNC 已安装（git），执行更新检查..."
    git -C "${NOVNC_DIR}" pull --ff-only 2>/dev/null \
        && success "noVNC 已是最新" \
        || warn "git pull 失败，保留现有版本"
elif [ -d "${NOVNC_DIR}" ]; then
    info "noVNC 目录已存在（非 git 方式安装），跳过下载"
else
    info "下载 noVNC ${NOVNC_VERSION}..."
    if git clone --depth=1 --branch "${NOVNC_VERSION}" \
            https://github.com/novnc/noVNC.git "${NOVNC_DIR}" 2>/dev/null; then
        success "noVNC 通过 git 下载完成"
    else
        warn "git 下载失败，尝试 tar.gz 备用下载..."
        TARBALL="/tmp/novnc.tar.gz"
        TARBALL_URL="https://github.com/novnc/noVNC/archive/refs/tags/${NOVNC_VERSION}.tar.gz"
        wget -q --show-progress -O "${TARBALL}" "${TARBALL_URL}" \
            || curl -L -o "${TARBALL}" "${TARBALL_URL}" \
            || error "noVNC 下载失败，请检查网络连接"
        mkdir -p "${NOVNC_DIR}"
        tar -xzf "${TARBALL}" -C /opt/
        EXTRACTED=$(find /opt -maxdepth 1 -type d -name "noVNC-*" | head -1)
        [ -z "${EXTRACTED}" ] && error "noVNC 解压失败"
        mv "${EXTRACTED}" "${NOVNC_DIR}"
        rm -f "${TARBALL}"
        success "noVNC 通过 tar.gz 安装完成"
    fi
fi

[ ! -f "${NOVNC_DIR}/vnc.html" ] && \
    error "noVNC 安装异常，入口文件 ${NOVNC_DIR}/vnc.html 不存在"
success "noVNC 目录: ${NOVNC_DIR}"

# =============================================================================
# 四、防火墙预配置
# 开放 noVNC Web 端口范围 6080-6120（最多 40 台 VM 同时映射）
# 实际使用的端口由 start_novnc.sh 根据运行中 VM 数量动态分配
# =============================================================================
info "配置防火墙，开放 Web 端口范围 6080-6120..."
if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
    firewall-cmd --permanent --add-port=6080-6120/tcp
    firewall-cmd --reload
    success "firewalld: 已开放 6080-6120/tcp"
elif command -v ufw &>/dev/null && ufw status | grep -q "active"; then
    ufw allow 6080:6120/tcp
    success "ufw: 已开放 6080-6120/tcp"
elif command -v iptables &>/dev/null; then
    iptables -I INPUT -p tcp --dport 6080:6120 -j ACCEPT
    warn "iptables: 已临时开放 6080-6120/tcp（重启后失效，请手动持久化）"
else
    warn "未检测到防火墙，请手动确认端口可访问"
fi

# =============================================================================
# 完成提示
# =============================================================================
echo ""
echo -e "${GREEN}================================================================${RESET}"
echo -e "${GREEN} noVNC + websockify 安装完成！${RESET}"
echo -e "${GREEN}----------------------------------------------------------------${RESET}"
echo -e " noVNC 目录    : ${NOVNC_DIR}"
echo -e " websockify    : ${WEBSOCKIFY_BIN}"
echo -e "${GREEN}----------------------------------------------------------------${RESET}"
echo -e " 下一步: 运行 ${CYAN}bash start_novnc.sh${RESET} 启动各 VM 的映射服务"
echo -e "${GREEN}================================================================${RESET}"
