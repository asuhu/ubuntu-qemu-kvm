#!/usr/bin/env bash
# =============================================================================
# noVNC 映射服务启动脚本
#
# 功能:
#   1. 扫描所有正在运行的 KVM 虚拟机
#   2. 读取每台 VM 的 VNC 端口（从 virsh dumpxml 获取）
#   3. 为每台 VM 启动一个 websockify 实例，映射 Web 端口 → VNC 端口
#   4. 支持 SSL（自动检测证书）
#   5. 结果写入汇总日志，便于查询访问地址
#
# 端口映射规则:
#   VM1: Web:6080 → VNC:5901
#   VM2: Web:6081 → VNC:5902
#   ...（按 BASE_PORT 递增，与 VM 的 VNC 端口一一对应）
#
# 定时执行（建议加入 crontab）:
#   */5 * * * * /bin/bash /root/start_novnc.sh >> /var/log/novnc/cron.log 2>&1
# =============================================================================

set -euo pipefail

# =============================================================================
# 配置区 — 按需修改
# =============================================================================
NOVNC_DIR="/opt/noVNC"               # noVNC 静态文件目录
LOG_DIR="/var/log/novnc"             # 各 VM 独立日志目录
MAIN_LOG="/root/novnc.log"           # 汇总日志（记录所有 VM 映射信息）
BASE_WEB_PORT=6080                   # Web 端口起始值（依次递增）
VNC_TARGET_HOST="127.0.0.1"         # VNC 服务监听地址（通常为本机）
SSL_CERT="/etc/ssl/novnc/novnc.crt"  # SSL 证书路径（不存在则使用 HTTP）
SSL_KEY="/etc/ssl/novnc/novnc.key"   # SSL 私钥路径
WEBSOCKIFY_PATH_FILE="/etc/novnc_websockify_path"  # 安装脚本写入的路径文件

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
# 初始化
# =============================================================================
[[ $EUID -ne 0 ]] && error "请使用 root 权限运行此脚本"

mkdir -p "${LOG_DIR}"
touch "${MAIN_LOG}"

# =============================================================================
# 定位 websockify 可执行文件
# 优先读取安装脚本写入的路径文件，否则在常见路径中查找
# =============================================================================
WEBSOCKIFY_BIN=""
if [ -f "${WEBSOCKIFY_PATH_FILE}" ]; then
    WEBSOCKIFY_BIN=$(cat "${WEBSOCKIFY_PATH_FILE}" | tr -d '[:space:]')
fi
if [ -z "${WEBSOCKIFY_BIN}" ] || [ ! -x "${WEBSOCKIFY_BIN}" ]; then
    for p in /usr/local/bin/websockify /usr/bin/websockify \
              "${HOME}/.local/bin/websockify" \
              "$(which websockify 2>/dev/null || true)"; do
        [ -x "$p" ] && WEBSOCKIFY_BIN="$p" && break
    done
fi
[ -z "${WEBSOCKIFY_BIN}" ] && \
    error "未找到 websockify，请先运行 install_novnc.sh"

# =============================================================================
# noVNC 目录校验
# =============================================================================
[ ! -f "${NOVNC_DIR}/vnc.html" ] && \
    error "noVNC 未安装或目录异常: ${NOVNC_DIR}/vnc.html 不存在"

# =============================================================================
# 获取本机 IP（取第一个非 127.x 地址）
# =============================================================================
HOST_IP=$(hostname -I | awk '{for(i=1;i<=NF;i++) if($i !~ /^127/) {print $i; exit}}')
[ -z "${HOST_IP}" ] && HOST_IP="127.0.0.1"

# =============================================================================
# SSL 检测
# 证书和私钥同时存在时启用 HTTPS，否则使用 HTTP
# =============================================================================
SSL_OPT=""
if [[ -f "${SSL_CERT}" && -f "${SSL_KEY}" ]]; then
    SSL_OPT="--cert=${SSL_CERT} --key=${SSL_KEY}"
    PROTO="https"
    info "检测到 SSL 证书，使用 HTTPS"
else
    PROTO="http"
    info "未找到 SSL 证书，使用 HTTP（路径: ${SSL_CERT}）"
fi

# =============================================================================
# 停止旧的 websockify 实例
# 只停止本脚本管理的实例（通过 PID 文件精确控制），
# 不使用 pkill -f 避免误杀其他 websockify 进程
# =============================================================================
PID_DIR="/var/run/novnc"
mkdir -p "${PID_DIR}"

stop_old_instances() {
    info "停止旧的 websockify 实例..."
    local stopped=0
    for pidfile in "${PID_DIR}"/*.pid; do
        [ -f "$pidfile" ] || continue
        local pid
        pid=$(cat "$pidfile" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null && (( stopped++ )) || true
        fi
        rm -f "$pidfile"
    done
    [ $stopped -gt 0 ] && info "已停止 ${stopped} 个旧实例"
}

stop_old_instances

# =============================================================================
# 写日志函数
# =============================================================================
write_log() {
    echo "$*" >> "${MAIN_LOG}"
}

# =============================================================================
# 扫描运行中的 VM 并逐一启动 websockify 映射
# =============================================================================
START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
write_log ""
write_log "========================================================"
write_log "${START_TIME} 开始扫描 VM 并启动 noVNC 映射..."
write_log "========================================================"

echo -e "${CYAN}================================================================${RESET}"
echo -e "${CYAN} noVNC 映射服务启动${RESET}"
echo -e "${CYAN}----------------------------------------------------------------${RESET}"
echo -e " 启动时间   : ${START_TIME}"
echo -e " 服务器 IP  : ${HOST_IP}"
echo -e " 协议       : ${PROTO}"
echo -e " websockify : ${WEBSOCKIFY_BIN}"
echo -e "${CYAN}================================================================${RESET}"

WEB_PORT=${BASE_WEB_PORT}
VM_COUNT=0
SKIP_COUNT=0

# virsh list --name 输出运行中 VM 的名称，最后一行为空行
while IFS= read -r vm; do
    [ -z "$vm" ] && continue

    # ── 获取 VNC 端口 ─────────────────────────────────────────────────────
    # 从 VM XML 中解析 graphics type='vnc' 的 port 属性
    # 返回 -1 表示 VNC 端口由系统自动分配（启动后才确定），
    # 需通过 virsh vncdisplay 获取实际端口
    VNC_PORT=$(virsh dumpxml "$vm" 2>/dev/null \
        | grep -oP "(?<=<graphics type='vnc' port=')[0-9]+" \
        | head -1 || true)

    # 兜底: 尝试 virsh vncdisplay（返回 :N 格式，转为 590N）
    if [ -z "${VNC_PORT}" ] || [ "${VNC_PORT}" = "-1" ]; then
        VNC_DISPLAY=$(virsh vncdisplay "$vm" 2>/dev/null | tr -d ' ' || true)
        if [[ "${VNC_DISPLAY}" =~ ^:[0-9]+$ ]]; then
            VNC_PORT=$((5900 + ${VNC_DISPLAY#:}))
        fi
    fi

    # 仍无法获取则跳过
    if [ -z "${VNC_PORT}" ] || [ "${VNC_PORT}" = "-1" ]; then
        warn "VM [${vm}] 无法获取 VNC 端口，已跳过"
        write_log "${START_TIME} | VM:${vm} | 状态:SKIP | 原因:无法获取VNC端口"
        (( SKIP_COUNT++ )) || true
        continue
    fi

    # ── 检查目标 VNC 端口是否可达 ─────────────────────────────────────────
    if ! timeout 1 bash -c "echo > /dev/tcp/${VNC_TARGET_HOST}/${VNC_PORT}" 2>/dev/null; then
        warn "VM [${vm}] VNC 端口 ${VNC_PORT} 无响应，已跳过"
        write_log "${START_TIME} | VM:${vm} | VNC:${VNC_PORT} | 状态:SKIP | 原因:VNC端口无响应"
        (( SKIP_COUNT++ )) || true
        continue
    fi

    # ── 检查 Web 端口是否已被占用 ─────────────────────────────────────────
    if ss -tlnp 2>/dev/null | grep -q ":${WEB_PORT} "; then
        warn "Web 端口 ${WEB_PORT} 已被占用，跳过 VM [${vm}]"
        write_log "${START_TIME} | VM:${vm} | Web:${WEB_PORT} | 状态:SKIP | 原因:Web端口被占用"
        WEB_PORT=$(( WEB_PORT + 1 ))
        (( SKIP_COUNT++ )) || true
        continue
    fi

    # ── 启动 websockify 实例 ───────────────────────────────────────────────
    VM_LOG="${LOG_DIR}/${vm}.log"
    nohup "${WEBSOCKIFY_BIN}" \
        --web="${NOVNC_DIR}" \
        ${SSL_OPT} \
        "${WEB_PORT}" \
        "${VNC_TARGET_HOST}:${VNC_PORT}" \
        > "${VM_LOG}" 2>&1 &

    WS_PID=$!
    echo "${WS_PID}" > "${PID_DIR}/${vm}.pid"

    # 等待 0.3 秒确认进程未立即退出
    sleep 0.3
    if ! kill -0 "${WS_PID}" 2>/dev/null; then
        warn "VM [${vm}] websockify 启动失败，请查看日志: ${VM_LOG}"
        write_log "${START_TIME} | VM:${vm} | VNC:${VNC_PORT} | Web:${WEB_PORT} | PID:${WS_PID} | 状态:FAIL | 日志:${VM_LOG}"
        (( SKIP_COUNT++ )) || true
    else
        ACCESS_URL="${PROTO}://${HOST_IP}:${WEB_PORT}/vnc.html?host=${HOST_IP}&port=${WEB_PORT}"
        success "VM [${vm}]  VNC:${VNC_PORT} → Web:${WEB_PORT}  ${PROTO}://${HOST_IP}:${WEB_PORT}/vnc.html"
        write_log "${START_TIME} | VM:${vm} | VNC:${VNC_PORT} | Web:${WEB_PORT} | PID:${WS_PID} | 协议:${PROTO} | 状态:SUCCESS | URL:${ACCESS_URL}"
        (( VM_COUNT++ )) || true
    fi

    WEB_PORT=$(( WEB_PORT + 1 ))

done < <(virsh list --name 2>/dev/null)

# =============================================================================
# 汇总输出
# =============================================================================
DONE_TIME=$(date '+%Y-%m-%d %H:%M:%S')
write_log "--------------------------------------------------------"
write_log "${DONE_TIME} 扫描完成 | 成功:${VM_COUNT} | 跳过/失败:${SKIP_COUNT}"
write_log "========================================================"

echo ""
echo -e "${GREEN}================================================================${RESET}"
echo -e "${GREEN} noVNC 映射服务启动完成${RESET}"
echo -e "${GREEN}----------------------------------------------------------------${RESET}"
printf " 成功启动 : ${GREEN}%d 个 VM${RESET}\n" "${VM_COUNT}"
printf " 跳过/失败: ${YELLOW}%d 个 VM${RESET}\n" "${SKIP_COUNT}"
echo -e " 汇总日志  : ${MAIN_LOG}"
echo -e " 单机日志  : ${LOG_DIR}/<VM名称>.log"
echo -e "${GREEN}----------------------------------------------------------------${RESET}"
echo -e " 查看所有映射: ${CYAN}grep SUCCESS ${MAIN_LOG} | tail -20${RESET}"
echo -e " 停止所有服务: ${CYAN}for f in ${PID_DIR}/*.pid; do kill \$(cat \$f); done${RESET}"
echo -e "${GREEN}================================================================${RESET}"
