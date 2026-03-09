#!/bin/bash
# =============================================================================
# add_disk_pro.sh — KVM 虚拟机热添加磁盘脚本
#
# 用法:
#   bash add_disk_pro.sh <VM名称> <磁盘大小(GB)>
#
# 示例:
#   bash add_disk_pro.sh VM10 100
# =============================================================================

set -euo pipefail

# =============================================================================
# ★ 配置区
# =============================================================================
DISKDIR="/data/instance"   # 磁盘镜像存放目录
LOGFILE="/root/instance.log"  # 日志文件路径

# =============================================================================
# 参数校验
# =============================================================================
if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
    echo "用法: $0 <VM名称> <磁盘大小(GB)>"
    echo "示例: $0 VM10 100"
    exit 1
fi

VMNAME="$1"
DISKSIZE="$2"

# 确保日志文件存在
touch "$LOGFILE"

# 统一日志写入函数
# 格式: 时间 | 实例:VMNAME | 磁盘:设备名 | 大小:XG | 路径:文件路径 | 状态:STATUS
log_event() {
    local status="$1"
    local disk="${2:--}"       # 磁盘设备名，未确定时用 -
    local diskfile="${3:--}"   # 磁盘文件路径，未确定时用 -
    local extra="${4:-}"       # 附加信息 (可选)
    local createtime
    createtime=$(date "+%Y-%m-%d %H:%M:%S")

    local logline="${createtime} | 实例:${VMNAME} | 磁盘:${disk} | 大小:${DISKSIZE}G | 路径:${diskfile} | 状态:${status}"
    [ -n "$extra" ] && logline="${logline} | 备注:${extra}"

    echo "$logline" >> "$LOGFILE"
}

# =============================================================================
# 检查虚拟机是否存在
# =============================================================================
if ! virsh dominfo "$VMNAME" >/dev/null 2>&1; then
    echo "错误: 虚拟机 '$VMNAME' 不存在"
    log_event "VM_NOT_EXIST"
    exit 1
fi

# 检查虚拟机运行状态 (运行中才支持 --live 热挂载)
VM_STATE=$(virsh domstate "$VMNAME" 2>/dev/null || echo "unknown")
echo "虚拟机状态: ${VM_STATE}"

# =============================================================================
# 自动查找下一个可用的 virtio 磁盘设备名 (vdb, vdc, ...)
# =============================================================================
USED_DISKS=$(virsh domblklist "$VMNAME" | awk '/vd[a-z]/{print $1}')

DISK=""
for i in {b..z}; do
    candidate="vd${i}"
    if ! echo "$USED_DISKS" | grep -q "$candidate"; then
        DISK="$candidate"
        break
    fi
done

if [ -z "$DISK" ]; then
    echo "错误: 虚拟机已用尽全部 virtio 磁盘槽位 (vdb~vdz)"
    log_event "NO_SLOT_AVAILABLE"
    exit 1
fi

DISKFILE="${DISKDIR}/${VMNAME}_${DISK}.qcow2"

echo "================================================================"
echo " 准备添加磁盘"
echo "----------------------------------------------------------------"
echo " 实例名称 : ${VMNAME}  (${VM_STATE})"
echo " 设备名称 : ${DISK}"
echo " 磁盘大小 : ${DISKSIZE} GB"
echo " 镜像路径 : ${DISKFILE}"
echo "================================================================"

# =============================================================================
# 创建 qcow2 稀疏磁盘镜像
# preallocation=off: 稀疏分配，文件按实际写入增长，节省空间
# =============================================================================
echo "正在创建磁盘镜像..."
if ! qemu-img create -f qcow2 -o preallocation=off "$DISKFILE" "${DISKSIZE}G"; then
    echo "错误: 磁盘镜像创建失败"
    log_event "CREATE_FAIL" "${DISK}" "${DISKFILE}" "qemu-img 返回非零退出码"
    exit 1
fi
echo "磁盘镜像创建成功: ${DISKFILE}"

# =============================================================================
# SSD 检测 → 自动选择 cache / io 参数组合
#
# libvirt/QEMU 的合法组合如下:
#   介质       cache         io           说明
#   -------    -----------   ----------   ----------------------------
#   SSD/NVMe   none          io_uring     最优: 零拷贝 + 内核异步 I/O
#   SSD/NVMe   none          native       备用: 零拷贝 + 原生 AIO
#   HDD/未知   writeback     threads      通用: 页缓存写回 + 线程 I/O
#
# 注意: cache=writeback + io=native 是非法组合 (libvirt 会直接报错)
#       io=native / io=io_uring 必须搭配 cache=none 或 cache=directsync
# =============================================================================
detect_disk_type() {
    local target_dir
    target_dir=$(dirname "${DISKFILE}")

    # 通过挂载点反查块设备
    local mount_dev
    mount_dev=$(df --output=source "${target_dir}" 2>/dev/null | tail -1)

    # 去掉分区号得到基础设备名，需覆盖以下几种格式:
    #   /dev/sda1      → sda      (SATA/SAS: 字母结尾的设备，去掉末尾数字)
    #   /dev/nvme0n1p2 → nvme0n1  (NVMe: pN 是分区后缀，去掉 pN)
    #   /dev/md0       → md0      (软 RAID: 设备名本身含数字，不能裁剪)
    #   /dev/vda1      → vda      (virtio: 同 SATA 逻辑)
    local base_dev
    base_dev=$(basename "${mount_dev}")
    if [[ "$base_dev" =~ ^md[0-9]+$ ]]; then
        # 软件 RAID (md0, md1 ...) — 保留完整设备名，不裁剪
        :
    elif [[ "$base_dev" =~ p[0-9]+$ ]]; then
        # NVMe 分区格式 (nvme0n1p2 → nvme0n1)
        base_dev=$(echo "$base_dev" | sed 's/p[0-9]*$//')
    else
        # 普通分区格式 (sda1 → sda, vda2 → vda)
        base_dev=$(echo "$base_dev" | sed 's/[0-9]*$//')
    fi

    local rotational_file="/sys/block/${base_dev}/queue/rotational"
    if [ -f "${rotational_file}" ] && [ "$(cat "${rotational_file}")" -eq 0 ]; then
        echo "ssd"
    else
        echo "hdd"
    fi
}

DISK_MEDIUM=$(detect_disk_type)

case "${DISK_MEDIUM}" in
    ssd)
        # SSD/NVMe: cache=none 绕过内核页缓存，io=io_uring 启用异步 I/O
        # 若内核 < 5.1 或 QEMU < 5.0 不支持 io_uring，将自动回退到 io=native
        DISK_CACHE="none"
        DISK_IO="io_uring"
        echo "磁盘介质检测: SSD/NVMe → cache=none, io=io_uring"
        ;;
    *)
        # HDD 或无法识别: cache=writeback + io=threads (唯一兼容写回缓存的 io 模式)
        DISK_CACHE="writeback"
        DISK_IO="threads"
        echo "磁盘介质检测: HDD/未知 → cache=writeback, io=threads"
        ;;
esac

# =============================================================================
# 挂载磁盘到虚拟机
#
# 使用 virsh attach-disk (无需生成 XML，参数直观):
#   --driver    qemu       — QEMU 驱动
#   --subdriver qcow2      — 镜像格式
#   --cache     <自动>     — 由 SSD 检测决定
#   --io        <自动>     — 由 SSD 检测决定
#   --targetbus virtio     — virtio 总线，性能最优
#   --persistent           — 写入 VM XML 配置，重启后依然生效
#   --live                 — 运行中时同时热挂载，无需重启
#
# 若 attach-disk 失败 (io_uring 不支持等)，自动回退到 io=native 再试一次，
# 最终仍失败则使用 attach-device (XML) 兜底。
# =============================================================================
echo "正在挂载磁盘..."

# 根据虚拟机运行状态决定是否追加 --live
if [ "$VM_STATE" = "running" ]; then
    ATTACH_OPTS="--persistent --live"
else
    ATTACH_OPTS="--persistent"
    echo "提示: 虚拟机未运行，磁盘将在下次启动后生效"
fi

do_attach_disk() {
    local cache="$1"
    local io="$2"
    virsh attach-disk "$VMNAME" "$DISKFILE" "$DISK" \
        --driver    qemu    \
        --subdriver qcow2   \
        --cache     "$cache" \
        --io        "$io"   \
        --targetbus virtio  \
        $ATTACH_OPTS
}

do_attach_xml() {
    local cache="$1"
    local aio="$2"
    local tmpxml="/tmp/${VMNAME}_${DISK}.xml"
    cat > "$tmpxml" <<EOF
<disk type='file' device='disk'>
  <driver name='qemu' type='qcow2' cache='${cache}' aio='${aio}'/>
  <source file='${DISKFILE}'/>
  <target dev='${DISK}' bus='virtio'/>
</disk>
EOF
    virsh attach-device "$VMNAME" "$tmpxml" $ATTACH_OPTS
    local ret=$?
    rm -f "$tmpxml"
    return $ret
}

ATTACH_METHOD=""
FINAL_CACHE="$DISK_CACHE"
FINAL_IO="$DISK_IO"

if do_attach_disk "$DISK_CACHE" "$DISK_IO"; then
    # 第一次尝试成功
    ATTACH_METHOD="attach-disk"

elif [ "$DISK_IO" = "io_uring" ] && do_attach_disk "none" "native"; then
    # io_uring 不支持，回退到 cache=none + io=native (同样适用于 SSD)
    echo "提示: io_uring 不支持，已回退到 io=native"
    ATTACH_METHOD="attach-disk"
    FINAL_CACHE="none"
    FINAL_IO="native"

elif do_attach_xml "$FINAL_CACHE" "$FINAL_IO"; then
    # attach-disk 不可用，使用 attach-device XML 兜底
    echo "提示: attach-disk 不可用，已使用 attach-device XML 方式"
    ATTACH_METHOD="attach-device-xml"

else
    echo "错误: 所有挂载方式均失败，请检查 libvirt 日志"
    log_event "ATTACH_FAIL" "${DISK}" "${DISKFILE}" \
        "cache=${DISK_CACHE},io=${DISK_IO},medium=${DISK_MEDIUM},state=${VM_STATE}"
    echo "清理已创建的镜像文件: ${DISKFILE}"
    rm -f "$DISKFILE"
    exit 1
fi

echo "磁盘挂载成功 (${ATTACH_METHOD})"
log_event "SUCCESS" "${DISK}" "${DISKFILE}" \
    "method=${ATTACH_METHOD},cache=${FINAL_CACHE},io=${FINAL_IO},medium=${DISK_MEDIUM},state=${VM_STATE}"

# =============================================================================
# 输出当前磁盘列表
# =============================================================================
echo ""
echo "当前磁盘列表 (${VMNAME}):"
virsh domblklist "$VMNAME"

echo ""
echo "日志已写入: ${LOGFILE}"
echo "$(tail -1 "$LOGFILE")"
