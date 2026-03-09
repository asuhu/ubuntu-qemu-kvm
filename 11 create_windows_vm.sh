#!/bin/bash
# =============================================================================
# KVM 虚拟机统一创建脚本
# 支持系统: win7 / win2k16 / win2k19 / win2k22 / win2k25 / win10 / win10cn
# 用法:
#   bash create_vm.sh <编号> <内存M> <槽数> <核心数> <线程数> <磁盘G> <系统类型> [uefi]
#
# 参数说明:
#   $1  VM 编号        — 用于命名 (VM<编号>) 及计算 VNC 端口 (5900 + 编号)
#   $2  内存大小 (MiB) — 例如 8192 表示 8 GiB
#   $3  CPU 槽数       — 例如 2
#   $4  每槽核心数     — 例如 4
#   $5  每核线程数     — 例如 2  (总逻辑核心 = 槽数 × 核心数 × 线程数)
#   $6  磁盘大小 (GiB) — 例如 100
#   $7  操作系统类型   — 见下方《支持的系统类型》
#   $8  是否启用 UEFI  — 可选, 填写 uefi 则启用; 不填则使用 Legacy BIOS
#
# 支持的系统类型:
#   win7         Windows 7
#   win2k16      Windows Server 2016
#   win2k19      Windows Server 2019
#   win2k22      Windows Server 2022
#   win2k25      Windows Server 2025
#   win10        Windows 10 英文版
#   win10cn      Windows 10 中文版 (VirtIO 驱动集成)
#
# 示例:
#   bash create_vm.sh 10 16384 2 4 2 200 win2k19
#   bash create_vm.sh 20 32768 2 8 2 500 win2k16 uefi
#   bash create_vm.sh 5  8192  1 4 2 80  win10cn
# =============================================================================

set -euo pipefail

# =============================================================================
# 路径配置区 — 按实际环境修改以下变量
# =============================================================================

# ISO 镜像存放根目录
ISO_BASE="/data/iso"

# 虚拟磁盘镜像存放根目录 (默认; win10/win10cn 各自有独立路径，见下方 case)
DISK_BASE="/data/instance"

# UEFI 固件路径，用于检测本机是否支持 UEFI 启动
# 常见路径 (取消对应行注释):
#   OVMF_PATH="/usr/share/OVMF/OVMF_CODE.fd"        # Debian / Ubuntu
#   OVMF_PATH="/usr/share/edk2/ovmf/OVMF_CODE.fd"   # CentOS / RHEL 8+
#   OVMF_PATH="/usr/share/qemu/OVMF.fd"             # 部分其他发行版
OVMF_PATH="/usr/share/OVMF/OVMF_CODE.fd"

# 实例信息日志文件
INSTANCE_LOG="/root/instance.log"

# =============================================================================
# 参数校验
# =============================================================================
if [ $# -lt 7 ] || [ $# -gt 8 ]; then
    echo "错误: 参数数量不正确，需要 7 或 8 个参数。"
    echo ""
    echo "用法: bash $0 <编号> <内存M> <槽数> <核心数> <线程数> <磁盘G> <系统类型> [uefi]"
    echo ""
    echo "系统类型: win7 | win2k16 | win2k19 | win2k22 | win2k25 | win10 | win10cn"
    echo ""
    echo "示例:"
    echo "  bash $0 10 16384 2 4 2 200 win2k19"
    echo "  bash $0 20 32768 2 8 2 500 win2k16 uefi"
    exit 1
fi

# =============================================================================
# 基础变量赋值
# =============================================================================
NUMBER="$1"           # VM 编号
MEM="$2"              # 内存 (MiB)
CPU_SOCKETS="$3"      # CPU 槽数
CPU_CORES="$4"        # 每槽核心数
CPU_THREADS="$5"      # 每核线程数
DISK_SIZE="$6"        # 磁盘大小 (GiB)
OS_TYPE="$7"          # 操作系统类型
UEFI_FLAG="${8:-}"    # 第 8 参数: 填 uefi 启用 UEFI，留空则 Legacy BIOS

VM_NAME="VM${NUMBER}"
VNC_PORT=$((5900 + NUMBER))
VNC_PASS=$(date +%s%N | sha256sum | base64 | head -c 8)
CREATE_TIME=$(date "+Instance Create Time %Y-%m-%d %H:%M.%S")
SERIAL_LOG="/data/${VM_NAME}console.log"

# CPU 固定使用三元格式: sockets / cores / threads
VCPUS_PARAM="sockets=${CPU_SOCKETS},cores=${CPU_CORES},threads=${CPU_THREADS}"

# =============================================================================
# UEFI 支持检测
# 若用户指定了 uefi 参数，检查固件文件是否存在；
# 固件不存在则报错退出，避免虚拟机因缺少固件启动失败。
# =============================================================================
USE_UEFI=false
if [[ "${UEFI_FLAG,,}" == "uefi" ]]; then
    if [ ! -f "${OVMF_PATH}" ]; then
        echo "错误: 已指定 UEFI 模式，但未找到 UEFI 固件文件: ${OVMF_PATH}"
        echo "请安装 OVMF 软件包，或修改脚本顶部的 OVMF_PATH 变量。"
        echo "  Debian/Ubuntu: apt install ovmf"
        echo "  CentOS/RHEL:   yum install edk2-ovmf"
        exit 1
    fi
    USE_UEFI=true
    echo "UEFI 固件检测通过: ${OVMF_PATH}"
fi

# =============================================================================
# 操作系统配置映射
# 根据 OS_TYPE 设定差异化参数:
#   ISO_PATH     — 安装镜像完整路径
#   OS_VARIANT   — osinfo-query 对应的变体标识 (osinfo-query os 可查询)
#   DISK_PATH    — 虚拟磁盘完整路径
#   USE_Q35      — 是否使用 Q35 芯片组 (UEFI / Win10+ 推荐)
#   HYPERV_BASE  — 桥接模式的 features 参数
#   HYPERV_NAT   — NAT 模式的 features 参数 (部分系统追加更多 HyperV 优化)
# =============================================================================
case "$OS_TYPE" in
    win7)
        ISO_PATH="${ISO_BASE}/win7.iso"
        OS_VARIANT="win7"
        DISK_PATH="${DISK_BASE}/${VM_NAME}.qcow2"
        USE_Q35=false
        HYPERV_BASE="kvm_hidden=on"
        HYPERV_NAT="kvm_hidden=on"
        ;;
    win2k16)
        ISO_PATH="${ISO_BASE}/2016.iso"
        OS_VARIANT="win2k16"
        DISK_PATH="${DISK_BASE}/${VM_NAME}.qcow2"
        USE_Q35=false
        HYPERV_BASE="kvm_hidden=on"
        # NAT 模式追加完整 HyperV 半虚拟化优化，提升网络与 CPU 性能
        HYPERV_NAT="kvm_hidden=on,hyperv_relaxed=on,hyperv_spinlocks=on,hyperv_spinlocks_retries=8191,hyperv_vapic=on"
        ;;
    win2k19)
        ISO_PATH="${ISO_BASE}/2019.iso"
        OS_VARIANT="win2k19"
        DISK_PATH="${DISK_BASE}/${VM_NAME}.qcow2"
        USE_Q35=false
        HYPERV_BASE="kvm_hidden=on"
        HYPERV_NAT="kvm_hidden=on,hyperv_relaxed=on,hyperv_spinlocks=on,hyperv_spinlocks_retries=8191,hyperv_vapic=on"
        ;;
    win2k22)
        ISO_PATH="${ISO_BASE}/2022.iso"
        OS_VARIANT="win2k22"
        DISK_PATH="${DISK_BASE}/${VM_NAME}.qcow2"
        # Server 2022 建议 Q35 以获得最佳硬件兼容性
        USE_Q35=true
        HYPERV_BASE="kvm_hidden=on"
        HYPERV_NAT="kvm_hidden=on,hyperv_relaxed=on,hyperv_spinlocks=on,hyperv_spinlocks_retries=8191,hyperv_vapic=on"
        ;;
    win2k25)
        ISO_PATH="${ISO_BASE}/2025.iso"
        OS_VARIANT="win2k25"
        DISK_PATH="${DISK_BASE}/${VM_NAME}.qcow2"
        # Server 2025 强烈建议 Q35
        USE_Q35=true
        HYPERV_BASE="kvm_hidden=on"
        HYPERV_NAT="kvm_hidden=on,hyperv_relaxed=on,hyperv_spinlocks=on,hyperv_spinlocks_retries=8191,hyperv_vapic=on"
        ;;
    win10)
        ISO_PATH="${ISO_BASE}/win10.iso"
        OS_VARIANT="win10"
        DISK_PATH="/home/data/ISO/${VM_NAME}.qcow2"
        USE_Q35=true
        HYPERV_BASE="kvm_hidden=on"
        HYPERV_NAT="kvm_hidden=on"
        ;;
    win10cn)
        # 中文版，集成 VirtIO 驱动的 ISO，安装时无需额外加载驱动盘
        ISO_PATH="${ISO_BASE}/cn_win10_virtio_20h2.iso"
        OS_VARIANT="win10"
        DISK_PATH="/data/image/${VM_NAME}.qcow2"
        USE_Q35=false
        HYPERV_BASE="kvm_hidden=on"
        HYPERV_NAT="kvm_hidden=on"
        ;;
    *)
        echo "错误: 不支持的系统类型 '${OS_TYPE}'。"
        echo "支持的类型: win7 | win2k16 | win2k19 | win2k22 | win2k25 | win10 | win10cn"
        exit 1
        ;;
esac

# 验证 ISO 文件是否存在，不存在则提前报错
if [ ! -f "${ISO_PATH}" ]; then
    echo "错误: ISO 文件不存在: ${ISO_PATH}"
    echo "请将镜像放置到该路径，或修改脚本顶部的 ISO_BASE 变量。"
    exit 1
fi

# =============================================================================
# 启动参数与芯片组参数构建
#
# UEFI 模式  → --boot uefi,cdrom,hd,network,menu=on  且强制使用 Q35
# BIOS 模式  → --boot cdrom,hd,network,menu=on
# Q35 芯片组 → --machine q35  (UEFI 及 Win10/2022/2025 推荐)
# =============================================================================
if $USE_UEFI; then
    BOOT_PARAM="--boot uefi,cdrom,hd,network,menu=on"
    USE_Q35=true   # UEFI 必须配合 Q35 芯片组
else
    BOOT_PARAM="--boot cdrom,hd,network,menu=on"
fi

# 根据 USE_Q35 决定是否追加 --machine q35
MACHINE_PARAM=""
$USE_Q35 && MACHINE_PARAM="--machine q35"

# =============================================================================
# virt-install 执行函数
# 将桥接/NAT 两种网络模式的差异收束到参数传入，消除重复代码
#
# 参数1: --network 完整参数字符串
# 参数2: --features 完整参数字符串
# =============================================================================
run_virt_install() {
    local NET_PARAM="$1"
    local FEAT_PARAM="$2"

    virt-install \
        --virt-type kvm \
        --name "${VM_NAME}" \
        --ram="${MEM}" \
        --vcpus ${VCPUS_PARAM} \
        --cpu=host-passthrough \
        --accelerate \
        --hvm \
        ${NET_PARAM} \
        --cdrom "${ISO_PATH}" \
        --input tablet,bus=usb \
        --features ${FEAT_PARAM} \
        ${BOOT_PARAM} \
        ${MACHINE_PARAM} \
        --serial file,path="${SERIAL_LOG}" \
        --disk path="${DISK_PATH}",size="${DISK_SIZE}",bus=virtio,cache=writeback,sparse=true,format=qcow2 \
        --graphics vnc,listen=0.0.0.0,port="${VNC_PORT}",keymap=en-us,password="${VNC_PASS}" \
        --noautoconsole \
        --os-type=windows \
        --os-variant="${OS_VARIANT}" \
        --video virtio \
        --clock offset=localtime,hypervclock_present=yes \
        --debug \
        --force \
        --autostart
}

# =============================================================================
# 网络模式判断
# 检测物理桥接网卡 br0:
#   存在  → 桥接模式，VM 直连物理网络，性能最佳
#   不存在 → NAT 模式，通过 libvirt default 网络转发
# =============================================================================
if brctl show | grep -v vir | grep -q br0; then
    # ── 桥接模式 ─────────────────────────────────────────────────────────────
    echo "检测到桥接网络 br0，使用桥接模式启动。"
    run_virt_install "--network bridge=br0,model=virtio" "${HYPERV_BASE}"
else
    # ── NAT 模式 ─────────────────────────────────────────────────────────────
    echo "未检测到桥接网络 br0，使用 NAT 模式启动。"
    run_virt_install "--network network=default,model=virtio" "${HYPERV_NAT}"
fi

# =============================================================================
# 创建结果输出及日志记录
# =============================================================================
if [ $? -eq 0 ]; then
    echo ""
    echo "================================================================"
    echo " 虚拟机创建成功"
    echo "----------------------------------------------------------------"
    echo " 实例名称 : ${VM_NAME}"
    echo " 系统类型 : ${OS_TYPE}  (variant: ${OS_VARIANT})"
    echo " 内存     : ${MEM} MiB"
    echo " CPU      : sockets=${CPU_SOCKETS}, cores=${CPU_CORES}, threads=${CPU_THREADS}"
    echo " 磁盘     : ${DISK_SIZE} GiB  →  ${DISK_PATH}"
    echo " 芯片组   : $( $USE_Q35 && echo 'Q35' || echo 'i440fx (默认)' )"
    echo " 启动模式 : $( $USE_UEFI && echo 'UEFI' || echo 'Legacy BIOS' )"
    echo " VNC 端口 : ${VNC_PORT}"
    echo " VNC 密码 : ${VNC_PASS}"
    echo "================================================================"
    # 追加写入实例日志，便于后续查阅
    echo "${CREATE_TIME} - 实例 ${VM_NAME} - OS ${OS_TYPE} - VNC :${VNC_PORT} - Pass ${VNC_PASS}" >> "${INSTANCE_LOG}"
else
    echo "错误: 虚拟机创建失败，请检查上方 virt-install 输出日志。"
    exit 1
fi
