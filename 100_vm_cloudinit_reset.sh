#!/usr/bin/env bash
# =============================================================================
# vm_cloudinit_reset.sh — 虚拟机 IP 查询 + cloud-init 密码重置脚本
#
# 功能:
#   1. 扫描所有虚拟机，查询 IP（Guest Agent → DHCP 两级兜底）
#   2. 检测虚拟机是否安装 cloud-init，提示或自动安装
#   3. 通过 cloud-init ISO 重置密码（Linux / Windows 均支持）
#   4. 重置完成后自动卸载 ISO，防止重启后再次触发 cloud-init
#   5. 写入操作日志
#
# 依赖:
#   宿主机: cloud-localds (cloud-image-utils 包) / genisoimage
#   虚拟机: cloud-init（Linux），或 cloudbase-init（Windows）
#
# 用法:
#   bash vm_cloudinit_reset.sh               # 交互模式（逐台询问）
#   bash vm_cloudinit_reset.sh --all         # 对所有运行中 VM 批量重置
#   bash vm_cloudinit_reset.sh --vm VM10     # 只处理指定 VM
# =============================================================================

set -euo pipefail

# =============================================================================
# ★ 配置区
# =============================================================================
DEFAULT_PASSWORD="NewPass123!"          # 默认重置密码
LOG_FILE="/root/cloudinit_reset.log"   # 操作日志
ISO_BASE="/tmp/cloudinit_iso"          # 临时 ISO 存放目录

# cloud-init ISO 卸载等待时间（秒）
# cloud-init 首次启动需要时间处理，等待后再卸载
EJECT_WAIT=60

# =============================================================================
# 颜色 & 工具函数
# =============================================================================
GREEN='\e[1;32m'; YELLOW='\e[1;33m'
RED='\e[1;31m';   CYAN='\e[1;36m'; RESET='\e[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }

log_event() {
    local status="$1"; shift
    local msg="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${ts} | 状态:${status} | ${msg}" >> "${LOG_FILE}"
}

# =============================================================================
# 参数解析
# =============================================================================
MODE="interactive"    # interactive / all / single
TARGET_VM=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)    MODE="all" ;;
        --vm)     MODE="single"; TARGET_VM="${2:-}"; shift ;;
        --pass)   DEFAULT_PASSWORD="${2:-}"; shift ;;
        -h|--help)
            echo "用法: $0 [--all] [--vm <VM名称>] [--pass <密码>]"
            exit 0 ;;
        *) warn "未知参数: $1" ;;
    esac
    shift
done

# =============================================================================
# 权限 & 依赖检查
# =============================================================================
[[ $EUID -ne 0 ]] && error "请使用 root 权限运行此脚本"
command -v virsh >/dev/null 2>&1 || error "未找到 virsh，请先安装 libvirt"

touch "${LOG_FILE}"
mkdir -p "${ISO_BASE}"

# =============================================================================
# 检测并安装 cloud-localds（宿主机生成 ISO 所需工具）
# cloud-localds 来自 cloud-image-utils 包，是生成 cloud-init ISO 的标准工具；
# 若不可用则回退到 genisoimage 手动构建符合 cloud-init 规范的 ISO
# =============================================================================
ensure_cloud_localds() {
    if command -v cloud-localds >/dev/null 2>&1; then
        return 0
    fi
    warn "宿主机未安装 cloud-localds，尝试自动安装..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y cloud-image-utils >/dev/null 2>&1 \
            && success "cloud-image-utils 安装完成" && return 0
    elif command -v yum >/dev/null 2>&1; then
        yum install -y cloud-utils >/dev/null 2>&1 \
            && success "cloud-utils 安装完成" && return 0
    fi
    # 最终兜底：用 genisoimage 手动制作符合 NoCloud 格式的 ISO
    if command -v genisoimage >/dev/null 2>&1 || \
       command -v mkisofs >/dev/null 2>&1; then
        warn "将使用 genisoimage/mkisofs 替代 cloud-localds 生成 ISO"
        return 0
    fi
    error "无法找到 cloud-localds 或 genisoimage，请手动安装 cloud-image-utils"
}

ensure_cloud_localds

# =============================================================================
# 生成 cloud-init ISO
#
# cloud-init NoCloud 数据源需要一张包含以下两个文件的 ISO：
#   meta-data  : 必须存在（可为空），提供实例 ID
#   user-data  : cloud-config 格式，包含密码重置指令
#
# ISO 卷标必须为 "cidata"（cloud-init NoCloud 规范要求）
# =============================================================================
make_cloudinit_iso() {
    local vm_name="$1"
    local password="$2"
    local iso_path="${ISO_BASE}/${vm_name}_cloudinit.iso"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    # user-data: cloud-config 格式
    # chpasswd.list 支持同时重置多个用户；这里重置 root 和默认用户
    cat > "${tmp_dir}/user-data" << EOF
#cloud-config
# 重置 root 及常见默认用户密码
chpasswd:
  list: |
    root:${password}
    ubuntu:${password}
    centos:${password}
    rocky:${password}
    kylin:${password}
  expire: false
# 允许 SSH 密码登录
ssh_pwauth: true
# Windows cloudbase-init 密码重置（Linux 环境忽略此字段）
password: ${password}
EOF

    # meta-data: 提供实例 ID，内容可为空但文件必须存在
    cat > "${tmp_dir}/meta-data" << EOF
instance-id: ${vm_name}-reset-$(date +%s)
local-hostname: ${vm_name}
EOF

    # 生成 ISO（优先 cloud-localds，兜底 genisoimage）
    if command -v cloud-localds >/dev/null 2>&1; then
        cloud-localds "${iso_path}" "${tmp_dir}/user-data" "${tmp_dir}/meta-data"
    else
        local giso_cmd
        giso_cmd=$(command -v genisoimage 2>/dev/null || command -v mkisofs 2>/dev/null)
        "${giso_cmd}" -output "${iso_path}" \
            -volid cidata -joliet -rock \
            "${tmp_dir}/user-data" "${tmp_dir}/meta-data" 2>/dev/null
    fi

    rm -rf "${tmp_dir}"
    echo "${iso_path}"
}

# =============================================================================
# 检测虚拟机内是否安装 cloud-init
# 通过 Guest Agent 执行命令检测；若 agent 不可用则只能提示用户
# =============================================================================
check_cloudinit_in_vm() {
    local vm_name="$1"
    # 尝试通过 Guest Agent 执行命令
    if virsh qemu-agent-command "${vm_name}" \
            '{"execute":"guest-exec","arguments":{"path":"which","arg":["cloud-init"],"capture-output":true}}' \
            >/dev/null 2>&1; then
        return 0   # 有 agent，cloud-init 存在
    fi
    return 1       # 无法确认
}

# =============================================================================
# 安装 cloud-init 到虚拟机（通过 Guest Agent 执行）
# =============================================================================
install_cloudinit_in_vm() {
    local vm_name="$1"
    info "尝试通过 Guest Agent 在虚拟机内安装 cloud-init..."

    # 检测包管理器并安装
    local install_cmd
    install_cmd=$(cat << 'GCMD'
if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y cloud-init
elif command -v yum >/dev/null 2>&1; then
    yum install -y cloud-init
else
    echo "UNSUPPORTED"
fi
GCMD
)
    # 通过 Guest Agent 执行 shell 命令
    virsh qemu-agent-command "${vm_name}" \
        "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"/bin/bash\",\"arg\":[\"-c\",\"${install_cmd}\"],\"capture-output\":true}}" \
        2>/dev/null || warn "Guest Agent 执行失败，请在虚拟机内手动安装 cloud-init"
}

# =============================================================================
# 获取虚拟机 IP
# 策略: Guest Agent（最准确） → DHCP 租约（兜底）
# =============================================================================
get_vm_ip() {
    local vm_name="$1"
    local ip=""

    # 方法一: Guest Agent（直接从虚拟机内获取，支持多网卡）
    ip=$(virsh domifaddr "${vm_name}" --source agent 2>/dev/null \
        | awk '/ipv4/ && !/127\.0\.0/ {split($4,a,"/"); print a[1]}' \
        | head -1 || true)
    if [ -n "${ip}" ]; then
        echo "${ip}|agent"
        return
    fi

    # 方法二: DHCP 租约（适用于 NAT 网络）
    local mac
    mac=$(virsh domiflist "${vm_name}" 2>/dev/null \
        | awk 'NR>2 && $5~/([0-9a-f]{2}:){5}/ {print $5}' | head -1 || true)
    if [ -n "${mac}" ]; then
        ip=$(virsh net-dhcp-leases default 2>/dev/null \
            | grep -i "${mac}" \
            | awk '{split($5,a,"/"); print a[1]}' | head -1 || true)
        if [ -n "${ip}" ]; then
            echo "${ip}|dhcp"
            return
        fi
    fi

    echo "|unknown"
}

# =============================================================================
# 重置单台 VM 密码的完整流程
# =============================================================================
reset_vm_password() {
    local vm_name="$1"
    local password="${2:-${DEFAULT_PASSWORD}}"

    local state
    state=$(virsh domstate "${vm_name}" 2>/dev/null || echo "unknown")

    echo ""
    echo -e "${CYAN}----------------------------------------------------------------${RESET}"
    echo -e " VM: ${CYAN}${vm_name}${RESET}  状态: ${state}"
    echo -e "${CYAN}----------------------------------------------------------------${RESET}"

    # ── 获取 IP ──────────────────────────────────────────────────────────
    local ip_result ip ip_method
    ip_result=$(get_vm_ip "${vm_name}")
    ip="${ip_result%%|*}"
    ip_method="${ip_result##*|}"

    if [ -n "${ip}" ]; then
        success "IP: ${ip}  (来源: ${ip_method})"
        log_event "IP_FOUND" "VM:${vm_name} | IP:${ip} | 来源:${ip_method}"
    else
        warn "无法获取 IP（Guest Agent 不可用或网络未就绪）"
        log_event "IP_UNKNOWN" "VM:${vm_name} | 状态:${state}"
    fi

    # ── 检测虚拟机内 cloud-init ───────────────────────────────────────────
    info "检测虚拟机内 cloud-init 状态..."
    if ! check_cloudinit_in_vm "${vm_name}"; then
        warn "无法通过 Guest Agent 确认虚拟机内 cloud-init 安装状态"
        warn "可能原因: Guest Agent 未运行，或虚拟机为 Windows"
        if [[ "${MODE}" == "interactive" ]]; then
            read -rp "  是否尝试通过 Guest Agent 自动安装 cloud-init？(y/n/skip) " choice
            case "${choice}" in
                [Yy]) install_cloudinit_in_vm "${vm_name}" ;;
                skip|[Ss]) info "跳过 cloud-init 安装检测" ;;
                *) warn "已跳过，请手动确认虚拟机内 cloud-init 已安装" ;;
            esac
        fi
    else
        success "虚拟机内 cloud-init 已安装"
    fi

    # ── 交互模式确认 ─────────────────────────────────────────────────────
    if [[ "${MODE}" == "interactive" ]]; then
        echo ""
        read -rp "  是否重置 ${vm_name} 的密码？(y/n) [默认密码: ${password}] " choice
        [[ ! "${choice}" =~ ^[Yy]$ ]] && info "已跳过 ${vm_name}" && return
        read -rp "  输入新密码（直接回车使用默认密码）: " custom_pass
        [ -n "${custom_pass}" ] && password="${custom_pass}"
    fi

    # ── 生成 cloud-init ISO ───────────────────────────────────────────────
    info "生成 cloud-init ISO..."
    local iso_path
    iso_path=$(make_cloudinit_iso "${vm_name}" "${password}")
    success "ISO 已生成: ${iso_path}"

    # ── 挂载 ISO 到虚拟机 ─────────────────────────────────────────────────
    # 先尝试弹出已有的 cdrom，再挂载新 ISO（避免冲突）
    for dev in hdb sdb; do
        virsh change-media "${vm_name}" "${dev}" --eject --config --force \
            >/dev/null 2>&1 || true
    done

    # 使用 attach-disk 挂载（--type cdrom 声明为光驱）
    virsh attach-disk "${vm_name}" "${iso_path}" hdb \
        --type cdrom --mode readonly \
        --persistent --live 2>/dev/null || \
    virsh attach-disk "${vm_name}" "${iso_path}" hdb \
        --type cdrom --mode readonly \
        --persistent 2>/dev/null
    success "ISO 已挂载到 hdb"

    # ── 启动或重启虚拟机以触发 cloud-init ────────────────────────────────
    if [[ "${state}" == "shut off" || "${state}" == "关闭" ]]; then
        info "虚拟机已关机，正在启动..."
        virsh start "${vm_name}"
        success "虚拟机已启动，cloud-init 将在首次启动时执行"
    else
        info "虚拟机运行中，正在重启以触发 cloud-init..."
        virsh reboot "${vm_name}" >/dev/null 2>&1
        success "虚拟机已发送重启指令"
    fi

    log_event "RESET_TRIGGERED" \
        "VM:${vm_name} | IP:${ip:-未知} | ISO:${iso_path} | 密码已设置"

    # ── 等待 cloud-init 执行完成后自动卸载 ISO ────────────────────────────
    # 在后台等待，避免阻塞其他 VM 的处理
    (
        info "[${vm_name}] 等待 ${EJECT_WAIT}s 后自动卸载 ISO..."
        sleep "${EJECT_WAIT}"
        virsh change-media "${vm_name}" hdb --eject --config --force \
            >/dev/null 2>&1 && \
            info "[${vm_name}] cloud-init ISO 已自动卸载" || \
            warn "[${vm_name}] ISO 卸载失败，请手动执行: virsh change-media ${vm_name} hdb --eject"
        rm -f "${iso_path}"
        log_event "ISO_EJECTED" "VM:${vm_name} | ISO:${iso_path}"
    ) &

    echo ""
    success "VM [${vm_name}] 密码重置完成"
    echo -e "  新密码 : ${CYAN}${password}${RESET}"
    echo -e "  IP     : ${CYAN}${ip:-未知}${RESET}"
    echo -e "  日志   : ${LOG_FILE}"
}

# =============================================================================
# 主流程：根据运行模式选择处理范围
# =============================================================================
echo -e "${CYAN}================================================================${RESET}"
echo -e "${CYAN} 虚拟机 IP 查询 + cloud-init 密码重置${RESET}"
echo -e "${CYAN}----------------------------------------------------------------${RESET}"
echo -e " 模式     : ${MODE}"
echo -e " 默认密码 : ${DEFAULT_PASSWORD}"
echo -e " 日志文件 : ${LOG_FILE}"
echo -e "${CYAN}================================================================${RESET}"

log_event "START" "模式:${MODE} | 操作者:$(whoami)"

case "${MODE}" in
    single)
        # 只处理指定 VM
        [ -z "${TARGET_VM}" ] && error "请通过 --vm 指定虚拟机名称"
        virsh dominfo "${TARGET_VM}" >/dev/null 2>&1 \
            || error "虚拟机 '${TARGET_VM}' 不存在"
        reset_vm_password "${TARGET_VM}"
        ;;
    all)
        # 批量处理所有运行中的 VM（不询问确认）
        while IFS= read -r vm; do
            [ -z "$vm" ] && continue
            reset_vm_password "${vm}"
        done < <(virsh list --name 2>/dev/null)
        ;;
    interactive)
        # 遍历所有 VM，逐台询问是否重置
        while IFS= read -r vm; do
            [ -z "$vm" ] && continue
            reset_vm_password "${vm}"
        done < <(virsh list --all --name 2>/dev/null)
        ;;
esac

echo ""
echo -e "${GREEN}================================================================${RESET}"
echo -e "${GREEN} 操作完成${RESET}"
echo -e "${GREEN}----------------------------------------------------------------${RESET}"
echo -e " 查看日志: ${CYAN}cat ${LOG_FILE}${RESET}"
echo -e " 查询结果: ${CYAN}grep RESET_TRIGGERED ${LOG_FILE}${RESET}"
echo -e "${GREEN}================================================================${RESET}"

log_event "DONE" "模式:${MODE} | 操作完成"
