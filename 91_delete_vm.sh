#!/bin/bash
# =============================================================================
# delete_vm.sh — KVM 虚拟机删除脚本
#
# 用法:
#   bash delete_vm.sh <VM名称>
#
# 功能:
#   1. 检测虚拟机是否存在
#   2. 删除前记录所有关联磁盘文件路径（无论磁盘数量）
#   3. 若运行中：弹出挂载介质 → 强制关机 → 删除定义及全部存储
#   4. 若已关机：弹出挂载介质 → 删除定义及全部存储
#   5. 写入完整日志（时间、实例、磁盘数量及路径、最终状态）
#
# 示例:
#   bash delete_vm.sh VM10
# =============================================================================

set -euo pipefail

# =============================================================================
# ★ 配置区
# =============================================================================
LOGFILE="/root/instance.log"   # 日志文件路径

# =============================================================================
# 颜色定义
# =============================================================================
YELLOW='\e[1;33;41m'
GREEN='\e[1;32m'
CYAN='\e[1;36m'
RESET='\e[0m'

# =============================================================================
# 参数校验
# =============================================================================
if [[ -z "${1:-}" ]]; then
    echo -e "${YELLOW} 错误: 请指定要删除的虚拟机名称 ${RESET}"
    echo "用法: bash $0 <VM名称>"
    echo "示例: bash $0 VM10"
    exit 1
fi

VMNAME="$1"
touch "$LOGFILE"

# =============================================================================
# 统一日志写入函数
# 格式: 时间 | 操作:DELETE | 实例:NAME | 磁盘数:N | 状态:STATUS | 磁盘:路径列表 | 备注:...
# =============================================================================
log_event() {
    local status="$1"
    local disk_log="${2:--}"   # 磁盘路径列表（分号分隔）
    local extra="${3:-}"       # 附加备注 (可选)
    local deletetime
    deletetime=$(date "+%Y-%m-%d %H:%M:%S")

    local logline="${deletetime} | 操作:DELETE | 实例:${VMNAME} | 磁盘数:${DISK_COUNT} | 状态:${status} | 磁盘:${disk_log}"
    [[ -n "$extra" ]] && logline="${logline} | 备注:${extra}"

    echo "$logline" >> "$LOGFILE"
}

# =============================================================================
# 检查虚拟机是否存在
# =============================================================================
if ! virsh dominfo "$VMNAME" >/dev/null 2>&1; then
    echo -e "${YELLOW} 错误: 虚拟机 '$VMNAME' 不存在 ${RESET}"
    DISK_COUNT=0
    log_event "VM_NOT_EXIST"
    exit 1
fi

# =============================================================================
# 删除前收集所有磁盘文件信息（用于日志记录）
#
# virsh domblklist --details 输出格式:
#   Type   Device   Target   Source
#   file   disk     vda      /data/instance/VM10.qcow2
#   file   cdrom    sda      /data/iso/rocky8.iso
#
# 只取 Device=disk 且 Source 不为 "-" 的行（排除空 cdrom）
# 无论挂载多少块磁盘，--remove-all-storage 会全部删除
# =============================================================================
mapfile -t DISK_ARRAY < <(virsh domblklist "$VMNAME" --details 2>/dev/null \
    | awk '$2=="disk" && $4!="-" {print $4}')

DISK_COUNT=${#DISK_ARRAY[@]}

if [[ $DISK_COUNT -eq 0 ]]; then
    DISK_LOG="-"
else
    # 多块磁盘路径用分号拼接，避免与日志字段分隔符 | 混淆
    DISK_LOG=$(printf '%s;' "${DISK_ARRAY[@]}" | sed 's/;$//')
fi

# =============================================================================
# 获取虚拟机当前运行状态
# =============================================================================
VM_STATE=$(virsh domstate "$VMNAME" 2>/dev/null || echo "unknown")

echo "================================================================"
echo " 准备删除虚拟机"
echo "----------------------------------------------------------------"
echo " 实例名称 : ${VMNAME}"
echo " 当前状态 : ${VM_STATE}"
printf " 磁盘数量 : %d 块\n" "${DISK_COUNT}"
# 逐行列出每块磁盘路径，多磁盘时一目了然
for f in "${DISK_ARRAY[@]}"; do
    echo "            └─ $f"
done
echo "================================================================"

# =============================================================================
# 弹出 CD/DVD 挂载介质
# 遍历常见光驱设备名，静默处理未挂载时的弹出失败
# =============================================================================
eject_media() {
    local live_flag="${1:-}"   # 传入 "--live" 表示需要热弹出（运行中）
    for dev in sda hda hdb; do
        virsh change-media "$VMNAME" "$dev" --eject \
            $live_flag --config --force >/dev/null 2>&1 || true
    done
}

# =============================================================================
# 执行删除
#
# virsh undefine 参数说明:
#   --snapshots-metadata  : 同时清理所有快照元数据
#   --remove-all-storage  : 删除所有关联磁盘镜像（无论磁盘数量）
#   --nvram               : 删除 UEFI NVRAM 变量文件
#                           (非 UEFI 虚拟机的旧版 libvirt 不支持此参数，
#                            第一条命令失败时自动回退到不带 --nvram 的版本)
# =============================================================================
run_undefine() {
    virsh undefine "$VMNAME" \
        --snapshots-metadata \
        --remove-all-storage \
        --nvram 2>/dev/null || \
    virsh undefine "$VMNAME" \
        --snapshots-metadata \
        --remove-all-storage 2>/dev/null
}

# =============================================================================
# 手动清理非托管磁盘文件
#
# virsh undefine --remove-all-storage 只删除 libvirt 存储池托管的磁盘。
# 通过 virsh attach-disk 直接路径挂载的磁盘（如后续追加的 vdb/vdc/vdd）
# 不在存储池管理范围内，undefine 不会自动删除其文件，需要手动 rm。
#
# 逻辑：对 DISK_ARRAY 中每个路径，undefine 后若文件仍存在则手动删除。
# =============================================================================
# remove_unmanaged_disks 返回两个统计值供日志使用:
#   MANUAL_REMOVED  — 手动删除的文件数（libvirt 未覆盖的残留文件）
#   MANUAL_FAILED   — 删除失败的文件数
MANUAL_REMOVED=0
MANUAL_FAILED=0

remove_unmanaged_disks() {
    for diskfile in "${DISK_ARRAY[@]}"; do
        if [[ -f "$diskfile" ]]; then
            # libvirt 未删除，手动清理
            echo "  删除残留磁盘文件: $diskfile"
            if rm -f "$diskfile"; then
                (( MANUAL_REMOVED++ )) || true
            else
                echo "  警告: 删除失败: $diskfile"
                (( MANUAL_FAILED++ )) || true
            fi
        fi
    done
    # libvirt 已删除的文件数 = 总数 - 手动删除 - 失败
    local libvirt_removed=$(( DISK_COUNT - MANUAL_REMOVED - MANUAL_FAILED ))
    [[ $libvirt_removed  -gt 0 ]] && echo "  libvirt 已删除: ${libvirt_removed} 个文件"
    [[ $MANUAL_REMOVED   -gt 0 ]] && echo "  手动清理残留:   ${MANUAL_REMOVED} 个文件"
    [[ $MANUAL_FAILED    -gt 0 ]] && echo "  警告: 删除失败: ${MANUAL_FAILED} 个文件，请手动检查"
}

if echo "$VM_STATE" | grep -Eq "running|运行中"; then
    # ── 运行中: 热弹出介质 → 强制关机 → 删除定义 → 清理残留文件 ─────────────
    echo "虚拟机运行中，正在强制关机..."
    eject_media "--live"
    virsh destroy "$VMNAME" >/dev/null 2>&1
    run_undefine
    remove_unmanaged_disks
    echo -e "${GREEN} 成功删除运行中的虚拟机: ${VMNAME} ${RESET}"
    log_event "SUCCESS" "${DISK_LOG}"         "vm_state=running,force_shutdown=yes,libvirt_del=$(( DISK_COUNT - MANUAL_REMOVED - MANUAL_FAILED )),manual_del=${MANUAL_REMOVED},failed=${MANUAL_FAILED}"
else
    # ── 已关机: 弹出介质 → 删除定义 → 清理残留文件 ──────────────────────────
    echo "虚拟机已关机，正在删除..."
    eject_media
    run_undefine
    remove_unmanaged_disks
    echo -e "${GREEN} 成功删除已关机的虚拟机: ${VMNAME} ${RESET}"
    log_event "SUCCESS" "${DISK_LOG}"         "vm_state=${VM_STATE},libvirt_del=$(( DISK_COUNT - MANUAL_REMOVED - MANUAL_FAILED )),manual_del=${MANUAL_REMOVED},failed=${MANUAL_FAILED}"
fi

echo ""
echo -e "${CYAN} 日志已写入: ${LOGFILE} ${RESET}"
echo "$(tail -1 "$LOGFILE")"
