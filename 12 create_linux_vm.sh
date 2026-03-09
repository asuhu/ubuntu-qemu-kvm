#!/bin/bash
# =============================================================================
# KVM Linux 虚拟机统一创建脚本
#   bash create_linux_vm.sh <编号> <内存M> <槽数> <核心数> <线程数> <磁盘G> <系统类型> [uefi]
# 参数说明:
#   $1  VM 编号        — 用于命名 (VM<编号>) 及计算 VNC 端口 (5900 + 编号)
#   $2  内存大小 (MiB) — 例如 16384 表示 16 GiB
#   $3  CPU 槽数       — 例如 2
#   $4  每槽核心数     — 例如 4
#   $5  每核线程数     — 例如 2  (总逻辑核心 = 槽数 × 核心数 × 线程数)
#   $6  磁盘大小 (GiB) — 例如 100
#   $7  操作系统类型   — 见下方《支持的系统类型》
#   $8  是否启用 UEFI  — 可选, 填写 uefi 则启用; 不填则使用 Legacy BIOS
#
# 支持的系统类型:
#   centos7      CentOS 7
#   centos8      CentOS 8 / CentOS Stream 8
#   centos9      CentOS Stream 9
#   kylin        麒麟 Kylin Server V10
#   ubuntu20     Ubuntu 20.04 LTS
#   ubuntu22     Ubuntu 22.04 LTS
#   ubuntu24     Ubuntu 24.04 LTS
#   debian11     Debian 11
#   debian12     Debian 12
#   rocky8       Rocky Linux 8
#   rocky9       Rocky Linux 9
#
# AIO 说明:
#   脚本会自动检测磁盘镜像所在分区对应的物理块设备是否为 SSD；
#   若为 SSD，磁盘参数自动追加 cache=none,aio=io_uring 以获得最优 I/O 性能；
#   若为 HDD，使用 cache=writeback (传统缓存模式，兼容性更好)。
#   (需要 Linux 内核 >= 5.1 且 QEMU >= 5.0 才支持 io_uring)
#
# 示例:
#   bash create_linux_vm.sh 10 16384 2 4 2 100 centos8
#   bash create_linux_vm.sh 20 32768 2 8 2 500 kylin uefi
# =============================================================================

set -euo pipefail

# =============================================================================
# 路径配置区 — 按实际环境修改以下变量
# =============================================================================

# ISO 镜像存放根目录
ISO_BASE="/data/iso"

# 虚拟磁盘镜像存放根目录
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
    echo "系统类型: centos7 | centos8 | centos9 | kylin |"
    echo "          ubuntu20 | ubuntu22 | ubuntu24 | debian11 | debian12 |"
    echo "          rocky8 | rocky9"
    echo ""
    echo "示例:"
    echo "  bash $0 10 16384 2 4 2 100 centos8"
    echo "  bash $0 20 32768 2 8 2 500 kylin uefi"
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
DISK_PATH="${DISK_BASE}/${VM_NAME}.qcow2"

# CPU 总逻辑核心数 = 槽数 × 每槽核心数 × 每核线程数
# 新版 virt-install 要求:
#   --vcpus    只接受总核心数整数
#   --cpu      承载拓扑信息 (sockets/cores/threads) 及 CPU 模式
CPU_TOTAL=$(( CPU_SOCKETS * CPU_CORES * CPU_THREADS ))
CPU_PARAM="host-passthrough,sockets=${CPU_SOCKETS},cores=${CPU_CORES},threads=${CPU_THREADS}"

# =============================================================================
# UEFI 支持检测
# 若用户指定了 uefi 参数，检查固件文件是否存在；
# 固件不存在则报错退出，避免虚拟机创建后无法启动。
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
# SSD 检测 → 动态决定磁盘 AIO 模式
#
# 原理: 通过磁盘目标目录反查其挂载点对应的块设备，
#       再读取 /sys/block/<dev>/queue/rotational 的值:
#         0 = SSD (非旋转介质) → cache=none, aio=io_uring  (零拷贝异步 I/O)
#         1 = HDD (旋转磁盘)   → cache=writeback            (传统缓存模式)
#
# io_uring 要求: Linux 内核 >= 5.1, QEMU >= 5.0
# =============================================================================
detect_disk_aio() {
    local target_dir
    target_dir=$(dirname "${DISK_PATH}")

    # 找到目标目录所在的挂载点对应的块设备
    local mount_dev
    mount_dev=$(df --output=source "${target_dir}" 2>/dev/null | tail -1)

    # 从设备路径提取基础块设备名 (去掉分区号, 如 /dev/sda1 → sda)
    local base_dev
    base_dev=$(basename "${mount_dev}" | sed 's/[0-9]*$//' | sed 's/p$//')

    local rotational_file="/sys/block/${base_dev}/queue/rotational"

    if [ -f "${rotational_file}" ]; then
        local rotational
        rotational=$(cat "${rotational_file}")
        if [ "${rotational}" -eq 0 ]; then
            # rotational=0 表示 SSD / NVMe
            echo "ssd"
        else
            # rotational=1 表示 HDD
            echo "hdd"
        fi
    else
        # 无法判断 (如网络存储、虚拟磁盘等), 保守使用 HDD 模式
        echo "unknown"
    fi
}

DISK_MEDIUM=$(detect_disk_aio)

case "${DISK_MEDIUM}" in
    ssd)
        # SSD/NVMe: cache=none 避免双重缓存, aio=io_uring 启用内核异步 I/O
        DISK_CACHE_PARAM="cache=none,aio=io_uring"
        echo "磁盘介质检测: SSD/NVMe → 启用 cache=none,aio=io_uring"
        ;;
    hdd)
        # HDD: cache=writeback 利用页缓存提升写入性能
        DISK_CACHE_PARAM="cache=writeback"
        echo "磁盘介质检测: HDD → 使用 cache=writeback"
        ;;
    *)
        # 未知介质: 保守使用 writeback
        DISK_CACHE_PARAM="cache=writeback"
        echo "磁盘介质检测: 未知 → 保守使用 cache=writeback"
        ;;
esac

# =============================================================================
# 操作系统配置映射
# 根据 OS_TYPE 设定差异化参数:
#   ISO_PATH     — 安装镜像完整路径
#   OS_VARIANT   — osinfo-query 对应的变体标识 (osinfo-query os 可查询)
#   DESCRIPTION  — virt-install --description 标签，便于 virsh 管理识别
# =============================================================================
case "$OS_TYPE" in
    centos7)
        ISO_PATH="${ISO_BASE}/centos7.iso"
        OS_VARIANT="centos7.0"
        DESCRIPTION="CentOS 7"
        ;;
    centos8)
        ISO_PATH="${ISO_BASE}/centos8.iso"
        OS_VARIANT="centos8"
        DESCRIPTION="CentOS 8"
        ;;
    centos9)
        ISO_PATH="${ISO_BASE}/centos9.iso"
        OS_VARIANT="centos-stream9"
        DESCRIPTION="CentOS Stream 9"
        ;;
    kylin)
        # 麒麟 Server V10，基于 CentOS 8，os-variant 使用 centos8 兼容
        ISO_PATH="${ISO_BASE}/Kylin-Server-V10.iso"
        OS_VARIANT="centos8"
        DESCRIPTION="Kylin Server V10"
        ;;
    ubuntu20)
        ISO_PATH="${ISO_BASE}/ubuntu-20.04.iso"
        OS_VARIANT="ubuntu20.04"
        DESCRIPTION="Ubuntu 20.04 LTS"
        ;;
    ubuntu22)
        ISO_PATH="${ISO_BASE}/ubuntu-22.04.iso"
        OS_VARIANT="ubuntu22.04"
        DESCRIPTION="Ubuntu 22.04 LTS"
        ;;
    ubuntu24)
        ISO_PATH="${ISO_BASE}/ubuntu-24.04.iso"
        OS_VARIANT="ubuntu24.04"
        DESCRIPTION="Ubuntu 24.04 LTS"
        ;;
    debian11)
        ISO_PATH="${ISO_BASE}/debian-11.iso"
        OS_VARIANT="debian11"
        DESCRIPTION="Debian 11 Bullseye"
        ;;
    debian12)
        ISO_PATH="${ISO_BASE}/debian-12.iso"
        OS_VARIANT="debian12"
        DESCRIPTION="Debian 12 Bookworm"
        ;;
    rocky8)
        ISO_PATH="${ISO_BASE}/rocky8.iso"
        OS_VARIANT="rocky8"
        DESCRIPTION="Rocky Linux 8"
        ;;
    rocky9)
        ISO_PATH="${ISO_BASE}/rocky9.iso"
        OS_VARIANT="rocky9"
        DESCRIPTION="Rocky Linux 9"
        ;;
    *)
        echo "错误: 不支持的系统类型 '${OS_TYPE}'。"
        echo "支持的类型: centos7 | centos8 | centos9 | kylin |"
        echo "            ubuntu20 | ubuntu22 | ubuntu24 | debian11 | debian12 |"
        echo "            rocky8 | rocky9"
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
# Linux 虚拟机固定使用 Q35 芯片组 (更好的 PCIe 支持，适合 virtio 设备)
# UEFI 模式  → --boot uefi,cdrom,hd,network,menu=on
# BIOS 模式  → --boot cdrom,hd,network,menu=on
# =============================================================================
if $USE_UEFI; then
    BOOT_PARAM="--boot uefi,cdrom,hd,network,menu=on"
else
    BOOT_PARAM="--boot cdrom,hd,network,menu=on"
fi

# Linux 虚拟机统一使用 Q35 以获得最佳 virtio 兼容性
MACHINE_PARAM="--machine q35"

# =============================================================================
# virt-install 执行函数
# 将桥接/NAT 两种网络模式的差异收束到参数传入，消除重复代码
#
# 参数1: --network 完整参数字符串
# =============================================================================
run_virt_install() {
    local NET_PARAM="$1"

    virt-install \
        --virt-type kvm \
        --name "${VM_NAME}" \
        --ram="${MEM}" \
        --vcpus="${CPU_TOTAL}" \
        --cpu "${CPU_PARAM}" \
        --accelerate \
        --hvm \
        --description "${DESCRIPTION}" \
        ${NET_PARAM} \
        --cdrom "${ISO_PATH}" \
        --input tablet,bus=usb \
        ${MACHINE_PARAM} \
        --features kvm_hidden=on \
        ${BOOT_PARAM} \
        --serial file,path="${SERIAL_LOG}" \
        --disk path="${DISK_PATH}",size="${DISK_SIZE}",bus=virtio,${DISK_CACHE_PARAM},sparse=true,format=qcow2 \
        --graphics vnc,listen=0.0.0.0,port="${VNC_PORT}",keymap=en-us,password="${VNC_PASS}" \
        --noautoconsole \
        --os-variant="${OS_VARIANT}" \
        --video virtio \
        --clock offset=utc \
        --debug \
        --force \
        --autostart
}

# =============================================================================
# 网络模式判断
# 检测物理桥接网卡 br0:
#   存在   → 桥接模式，VM 直连物理网络，性能最佳
#   不存在 → NAT 模式，通过 libvirt default 网络转发
# =============================================================================
if brctl show 2>/dev/null | grep -v vir | grep -q br0; then
    # ── 桥接模式 ─────────────────────────────────────────────────────────────
    echo "检测到桥接网络 br0，使用桥接模式启动。"
    run_virt_install "--network bridge=br0,model=virtio"
else
    # ── NAT 模式 ─────────────────────────────────────────────────────────────
    echo "未检测到桥接网络 br0，使用 NAT 模式启动。"
    run_virt_install "--network network=default,model=virtio"
fi

# =============================================================================
# 创建结果输出及日志记录
# =============================================================================
if [ $? -eq 0 ]; then
    echo ""
    echo "================================================================"
    echo " 虚拟机创建成功"
    echo "----------------------------------------------------------------"
    echo " 实例名称 : ${VM_NAME}  (${DESCRIPTION})"
    echo " 内存     : ${MEM} MiB"
    echo " CPU      : sockets=${CPU_SOCKETS}, cores=${CPU_CORES}, threads=${CPU_THREADS}"
    echo " 磁盘     : ${DISK_SIZE} GiB  →  ${DISK_PATH}"
    echo " 磁盘模式 : ${DISK_CACHE_PARAM}"
    echo " 芯片组   : Q35"
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
