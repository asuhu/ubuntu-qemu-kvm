#!/bin/bash

echo "[1/8] 更新系统包..."
apt update -y
sleep 1

echo "[2/8] 安装KVM相关组件..."
apt install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virt-manager virt-v2v  
apt install libosinfo-bin -y
apt install ovmf -y
apt install libguestfs-tools -y
sleep 1

#echo "[3/8] 安装 Cockpit 及其虚拟化插件..."
#apt install -y cockpit cockpit-machines
#systemctl enable --now cockpit.socket
#ufw allow 9090/tcp


echo "[3/8] 开始优化 libvirt 配置..."
# 配置 /etc/libvirt/libvirtd.conf（服务监听）
CONF_LIBVIRTD="/etc/libvirt/libvirtd.conf"

sed -i 's/^#\?\s*listen_tcp\s*=.*/listen_tcp = 1/' "$CONF_LIBVIRTD"
sed -i 's/^#\?\s*listen_tls\s*=.*/listen_tls = 0/' "$CONF_LIBVIRTD"
sed -i 's/^#\?\s*tcp_port\s*=.*/tcp_port = "16509"/' "$CONF_LIBVIRTD"
sed -i 's/^#\?\s*auth_tcp\s*=.*/auth_tcp = "none"/' "$CONF_LIBVIRTD"
sed -i 's@^#\?\s*log_outputs\s*=.*@log_outputs="1:file:/var/log/libvirt/libvirtd.log"@' "$CONF_LIBVIRTD"
sleep 1

echo "[4/8] 开始优化 qemu权限和安全.."
# 配置 /etc/libvirt/qemu.conf（权限和安全）
CONF_QEMU="/etc/libvirt/qemu.conf"

sed -i 's/^#\?\s*user\s*=.*/user = "qemu"/' "$CONF_QEMU"
sed -i 's/^#\?\s*group\s*=.*/group = "qemu"/' "$CONF_QEMU"
sed -i 's/^#\?\s*security_driver\s*=.*/security_driver = "none"/' "$CONF_QEMU"

# 启用 libvirtd 的 TCP 监听（需要在 systemd 配置中启用）
LIBVIRTD_SERVICE="/etc/systemd/system/libvirtd.service.d/tcp.conf"
mkdir -p "$(dirname "$LIBVIRTD_SERVICE")"
cat > "$LIBVIRTD_SERVICE" <<EOF
[Service]
ExecStart=
ExecStart=/usr/sbin/libvirtd --listen
EOF

# 重载 systemd 并重启服务
systemctl daemon-reexec
systemctl daemon-reload
systemctl restart libvirtd

echo "[5/8] 启动并检查 libvirtd 服务..."
systemctl enable --now libvirtd
systemctl status libvirtd --no-pager
sleep 1

set -e
set -o pipefail
echo "[6/8] 是否启用 RBD (Ceph 块设备) 支持..."
QEMU_VERSION="8.2.10"
QEMU_PKGNAME="qemu-kvm-suhu"
PREFIX="/usr/local/qemu"
BUILD_DIR="$HOME/qemu-${QEMU_VERSION}/build"

read -p "是否启用 RBD (Ceph 块设备) 支持？[Y/n]: " enable_rbd
if [[ "$enable_rbd" =~ ^[Nn]$ ]]; then
    echo "已禁用 RBD 支持"
    exit 0
else
    echo "启用 RBD 支持"
fi
echo "[1/8] 安装依赖..."
sudo apt update && sudo apt install -y \
  git build-essential libglib2.0-dev libfdt-dev libpixman-1-dev zlib1g-dev \
  ninja-build meson python3-pip libnfs-dev libiscsi-dev libaio-dev libbluetooth-dev \
  libcap-ng-dev libcurl4-openssl-dev libssh-dev libvte-2.91-dev libgtk-3-dev \
  libspice-server-dev libusb-1.0-0-dev libusbredirparser-dev libseccomp-dev \
  liblzo2-dev librbd-dev libibverbs-dev libnuma-dev libsnappy-dev \
  libbz2-dev libzstd-dev libpam0g-dev libsasl2-dev libselinux1-dev \
  libepoxy-dev libpulse-dev libjack-jackd2-dev libasound2-dev \
  libdrm-dev libgbm-dev libudev-dev libvhost-user-dev \
  librdmacm-dev libibumad-dev libmultipath-dev checkinstall

echo "[2/8] 下载 QEMU 源码..."
cd ~
wget -c https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz
tar -Jxvf qemu-${QEMU_VERSION}.tar.xz

echo "[3/8] 配置构建目录..."
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "[4/8] 运行 configure..."
../configure \
  --prefix=${PREFIX} \
  --libdir=lib \
  --target-list=x86_64-softmmu \
  --enable-kvm \
  --enable-linux-aio \
  --enable-io-uring \
  --enable-rbd \
  --enable-virtfs \
  --enable-vhost-user \
  --enable-vnc \
  --enable-spice \
  --enable-libusb \
  --enable-usb-redir \
  --enable-lzo \
  --enable-seccomp \
  --enable-curl \
  --enable-numa \
  --enable-fdt \
  --enable-tools \
  --enable-coroutine-pool \
  --enable-snappy \
  --enable-bzip2 \
  --enable-zstd \
  --enable-rdma \
  --enable-multipath \
  --buildtype=release

echo "[5/8] 开始编译 QEMU..."
make -j$(nproc)

echo "[6/8] 使用 checkinstall 打包..."
sudo checkinstall --pkgname=${QEMU_PKGNAME} --pkgversion=${QEMU_VERSION} \
  --backup=no --deldoc=yes --fstrans=no --default <<EOF
y
EOF

echo "[7/8] 安装打好的 DEB 包..."
sudo dpkg -i ${BUILD_DIR}/${QEMU_PKGNAME}_${QEMU_VERSION}-1_amd64.deb

echo "[8/8] 创建软链接 (可选)..."
sudo ln -sf ${PREFIX}/bin/qemu-system-x86_64 /usr/bin/qemu-system-x86_64
sudo ln -sf ${PREFIX}/bin/qemu-img /usr/bin/qemu-img

echo "安装完成！使用命令验证："
echo "qemu-system-x86_64 --version"
sleep 2

echo "[7/8]开启虚拟化嵌套和显卡直通支持..."
echo "========== [1/8] 检查 CPU 类型和虚拟化支持 =========="
CPU_MODEL=$(lscpu | grep 'Model name' | awk -F: '{print $2}' | xargs)
VT_SUPPORT=$(egrep -c '(vmx)' /proc/cpuinfo)

echo "当前 CPU: $CPU_MODEL"
if [ "$VT_SUPPORT" -eq 0 ]; then
  echo "当前 CPU 不支持虚拟化（无 vmx 标志）或未在 BIOS 启用 VT-x"
  exit 1
else
  echo "虚拟化支持已开启（vmx 存在）"
fi

echo
echo "========== [2/8] 启用 KVM 嵌套虚拟化（Intel） =========="
sudo modprobe -r kvm_intel || true
sudo modprobe kvm_intel nested=1
echo 'options kvm_intel nested=1' | sudo tee /etc/modprobe.d/kvm-nested.conf

echo
echo "========== [3/8] 修改 GRUB 启用 intel_iommu 和 passthrough =========="
GRUB_FILE="/etc/default/grub"
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash intel_iommu=on iommu=pt"/' $GRUB_FILE
sudo update-grub

echo
echo "========== [4/8] 设置 VFIO 模块自动加载 =========="
sudo tee /etc/modules-load.d/vfio.conf > /dev/null <<EOF
vfio
vfio_iommu_type1
vfio_pci
EOF

echo
echo "========== [5/8] 加载 VFIO 模块并确认状态 =========="
sudo modprobe vfio
sudo modprobe vfio_iommu_type1
sudo modprobe vfio_pci
lsmod | grep vfio || echo "VFIO 模块未正确加载"

echo
echo "========== [6/8] 嵌套虚拟化验证 =========="
cat /sys/module/kvm_intel/parameters/nested

echo
echo "========== [7/8] [INFO] 屏蔽主机加载 NVIDIA 驱动=========="
cat <<EOF | sudo tee /etc/modprobe.d/blacklist-nvidia.conf
blacklist nouveau
blacklist nvidia
blacklist nvidiafb
blacklist rivafb
EOF

echo
echo "========== [8/8][INFO] 更新 initramfs"=========="
sudo update-initramfs -u

echo
echo "配置完成。请重启系统以生效：sudo reboot"