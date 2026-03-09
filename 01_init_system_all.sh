#!/bin/bash
# ======================================
# 初始化系统配置
# 支持：Ubuntu / Debian/Rocky 8 / 9 / Kylin
# 作者：asuhu
# ======================================

# =============== 系统识别部分 ==============
echo "[0/12] 检测系统类型..."

if grep -qi "rocky" /etc/os-release; then
    OS="rocky"
elif grep -qi "kylin" /etc/os-release; then
    OS="kylin"
elif grep -qi "ubuntu" /etc/os-release; then
    OS="ubuntu"
elif grep -qi "debian" /etc/os-release; then
    OS="debian"
else
    OS="unknown"
fi

echo "检测到的系统类型：$OS"
sleep 1


# =============== 通用基础配置（Ubuntu / Debian 原逻辑） ===============
if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then

echo "[1/12] 优化系统升级..."
sudo sed -i 's/^Prompt=.*/Prompt=never/' /etc/update-manager/release-upgrades 2>/dev/null || true
sudo sed -i 's/^APT::Periodic::Update-Package-Lists.*/APT::Periodic::Update-Package-Lists "0";/' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null || true
sudo sed -i 's/^APT::Periodic::Unattended-Upgrade.*/APT::Periodic::Unattended-Upgrade "0";/' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null || true

elif [ "$OS" = "rocky" ]; then

echo "[1/12] 优化系统升级..."
sudo dnf makecache
sudo dnf -y update
sudo systemctl disable dnf-makecache.timer dnf-automatic.timer --now >/dev/null 2>&1

# 检测 SELinux 配置文件是否存在
SELINUX_CONFIG="/etc/selinux/config"
if [ -f "$SELINUX_CONFIG" ]; then
    echo "关闭 SELinux ..."
    # 将 SELINUX=enforcing 或 SELINUX=permissive 修改为 disabled
    sudo sed -i 's/^SELINUX=.*/SELINUX=disabled/' $SELINUX_CONFIG
    echo "SELinux 已设置为 disabled。重启系统后生效。"
else
    echo "SELinux 配置文件不存在，跳过。"
fi

# 临时关闭（无需重启，仅当前运行）
if command -v setenforce >/dev/null 2>&1; then
    sudo setenforce 0 2>/dev/null || true
    echo "当前会话已临时关闭 SELinux (Permissive)。"
fi

elif [ "$OS" = "kylin" ]; then

echo "[1/12] 优化系统升级..."
if command -v apt >/dev/null 2>&1; then
    sudo apt update -y && sudo apt upgrade -y
elif command -v yum >/dev/null 2>&1; then
    sudo yum makecache && sudo yum update -y
# 检测 SELinux 配置文件是否存在
SELINUX_CONFIG="/etc/selinux/config"
if [ -f "$SELINUX_CONFIG" ]; then
    echo "关闭 SELinux ..."
    # 将 SELINUX=enforcing 或 SELINUX=permissive 修改为 disabled
    sudo sed -i 's/^SELINUX=.*/SELINUX=disabled/' $SELINUX_CONFIG
    echo "SELinux 已设置为 disabled。重启系统后生效。"
else
    echo "SELinux 配置文件不存在，跳过。"
fi

# 临时关闭（无需重启，仅当前运行）
if command -v setenforce >/dev/null 2>&1; then
    sudo setenforce 0 2>/dev/null || true
    echo "当前会话已临时关闭 SELinux (Permissive)。"
fi

fi

fi
sleep 1


echo "[2/12] 优化SSH配置.."
sudo sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null || true
sudo sed -i 's/^PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null || true
sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh || true
sleep 1


echo "[3/12] 优化History命令.."
sudo cat > /etc/profile.d/lnamp.sh << "EOF"
# 设置历史记录大小
HISTFILESIZE=1000000000
HISTSIZE=100000000

# 追加命令到历史文件，确保实时记录历史命令
PROMPT_COMMAND="history -a"

# 历史记录时间格式
HISTTIMEFORMAT="%Y-%m-%d_%H:%M:%S `whoami` "

# 自定义命令提示符
PS1="\[\e[37;40m\][\[\e[32;40m\]\u\[\e[37;40m\]@\h \[\e[35;40m\]\W\[\e[0m\]]\$ "

# 定义常用别名
alias l='ls -AFhlt --color=auto'
alias lh='ls -AFhlt --color=auto | head'
EOF
sleep 1


echo "[3.5/12] 修改系统镜像源为中科大 (USTC)..."

if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    VERSION_ID=$(grep -oP '(?<=VERSION_ID=).+' /etc/os-release | tr -d '"' | cut -d'.' -f1)
    BACKUP_DIR="/etc/apt/backup_$(date +%Y%m%d%H%M%S)"
    sudo mkdir -p "$BACKUP_DIR"
    sudo cp /etc/apt/sources.list* "$BACKUP_DIR" 2>/dev/null || true
    sudo cp /etc/apt/sources.list.d/*.sources "$BACKUP_DIR" 2>/dev/null || true
    echo "已备份APT源到：$BACKUP_DIR"

    case "$VERSION_ID" in
      20)
        CODENAME="focal"
        ;;
      22)
        CODENAME="jammy"
        ;;
      24)
        CODENAME="noble"
        ;;
      26)
        CODENAME="oracular"   # Ubuntu 26.04 codename 占位
        ;;
      *)
        CODENAME="noble"
        echo "未识别版本 $VERSION_ID，默认使用 noble"
        ;;
    esac

    if [ "$VERSION_ID" -ge 24 ]; then
        # Ubuntu 24+ 使用 .sources 格式
        sudo bash -c "cat > /etc/apt/sources.list.d/ubuntu.sources" << EOF
Types: deb
URIs: https://mirrors.ustc.edu.cn/ubuntu
Suites: $CODENAME $CODENAME-updates $CODENAME-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: https://mirrors.ustc.edu.cn/ubuntu
Suites: ${CODENAME}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    else
        # Ubuntu 20 / 22 使用传统 sources.list 格式
        sudo bash -c "cat > /etc/apt/sources.list" << EOF
# 默认注释了源码仓库，如有需要可自行取消注释
deb https://mirrors.ustc.edu.cn/ubuntu/ $CODENAME main restricted universe multiverse
# deb-src https://mirrors.ustc.edu.cn/ubuntu/ $CODENAME main restricted universe multiverse

deb https://mirrors.ustc.edu.cn/ubuntu/ ${CODENAME}-security main restricted universe multiverse
# deb-src https://mirrors.ustc.edu.cn/ubuntu/ ${CODENAME}-security main restricted universe multiverse

deb https://mirrors.ustc.edu.cn/ubuntu/ ${CODENAME}-updates main restricted universe multiverse
# deb-src https://mirrors.ustc.edu.cn/ubuntu/ ${CODENAME}-updates main restricted universe multiverse

deb https://mirrors.ustc.edu.cn/ubuntu/ ${CODENAME}-backports main restricted universe multiverse
# deb-src https://mirrors.ustc.edu.cn/ubuntu/ ${CODENAME}-backports main restricted universe multiverse

# 预发布软件源，不建议启用
# deb https://mirrors.ustc.edu.cn/ubuntu/ ${CODENAME}-proposed main restricted universe multiverse
# deb-src https://mirrors.ustc.edu.cn/ubuntu/ ${CODENAME}-proposed main restricted universe multiverse
EOF
    fi

    sudo apt clean all
    sudo apt update -y
    echo "Ubuntu 源已成功切换至中科大镜像源 ($CODENAME)"

elif [[ "$OS" == "rocky" ]]; then
    echo "检测到 Rocky Linux 系统，切换到中科大镜像源..."

    MAJOR_VER=$(grep -oP '(?<=VERSION_ID=")\d+' /etc/os-release)
    BACKUP_TIME=$(date +%Y%m%d%H%M%S)

    if [ "$MAJOR_VER" -eq 8 ]; then
        sudo sed -e 's|^mirrorlist=|#mirrorlist=|g' \
                 -e 's|^#baseurl=http://dl.rockylinux.org/\$contentdir|baseurl=https://mirrors.ustc.edu.cn/rocky|g' \
                 -i.bak_"$BACKUP_TIME" \
                 /etc/yum.repos.d/Rocky-AppStream.repo \
                 /etc/yum.repos.d/Rocky-BaseOS.repo \
                 /etc/yum.repos.d/Rocky-Extras.repo \
                 /etc/yum.repos.d/Rocky-PowerTools.repo
    elif [ "$MAJOR_VER" -eq 9 ]; then
        sudo sed -e 's|^mirrorlist=|#mirrorlist=|g' \
                 -e 's|^#baseurl=http://dl.rockylinux.org/\$contentdir|baseurl=https://mirrors.ustc.edu.cn/rocky|g' \
                 -i.bak_"$BACKUP_TIME" \
                 /etc/yum.repos.d/rocky.repo \
                 /etc/yum.repos.d/rocky-extras.repo
    fi

    sudo dnf clean all && sudo dnf makecache
    echo "Rocky Linux 源已成功切换至中科大镜像源"

elif [[ "$OS" == "kylin" ]]; then
    echo "检测到麒麟 Kylin 系统，切换到中科大镜像源..."
    if command -v apt >/dev/null 2>&1; then
        sudo cp /etc/apt/sources.list /etc/apt/sources.list.bk_$(date +%Y%m%d%H%M%S) 2>/dev/null || true
        sudo bash -c "cat > /etc/apt/sources.list" << 'EOF'
deb https://mirrors.ustc.edu.cn/kylin/ kylin main restricted universe multiverse
EOF
        sudo apt clean all
        sudo apt update -y
    elif command -v dnf >/dev/null 2>&1; then
        sudo bash -c "cat > /etc/yum.repos.d/kylin.repo" << 'EOF'
[kylin-base]
name=Kylin Linux Base - USTC
baseurl=https://mirrors.ustc.edu.cn/kylinlinux/$releasever/os/$basearch/
enabled=1
gpgcheck=0
EOF
        sudo dnf clean all && sudo dnf makecache
    fi
    echo "麒麟 Linux 源已成功切换至中科大镜像源"

else
    echo "未识别的系统类型，跳过镜像源修改。"
fi

sleep 1

# =============== 软件安装逻辑 ===============
echo "[4/12] 软件升级.."

if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a

    sudo apt update -y
    sudo apt -o Dpkg::Options::="--force-confdef" \
             -o Dpkg::Options::="--force-confold" \
             full-upgrade -y

    sudo apt install -y \
    git build-essential vim curl htop gcc python3 python3-pip openjdk-11-jdk net-tools nmap vlc ffmpeg gimp inkscape libreoffice zip unzip tar sysstat strace \
    fail2ban clamav libssl-dev libcurl4-openssl-dev ntpdate chrony iftop iotop fio stress-ng snmp snmpd ifupdown

    sudo apt remove -y vim-common 2>/dev/null || true
    sudo apt install -y vim

elif [ "$OS" = "rocky" ]; then
    sudo dnf -y groupinstall "Development Tools"
    sudo dnf -y install git vim curl htop gcc python3 python3-pip java-11-openjdk net-tools nmap ffmpeg zip unzip tar sysstat strace \
    fail2ban clamav openssl-devel libcurl-devel chrony iftop iotop fio stress-ng net-snmp net-snmp-utils network-scripts



elif [ "$OS" = "kylin" ]; then
    if command -v apt >/dev/null 2>&1; then
        sudo apt install -y git vim curl htop gcc python3 python3-pip openjdk-11-jdk net-tools zip unzip tar sysstat chrony iftop iotop snmp snmpd ifupdown
    else
        sudo yum install -y git vim curl htop gcc python3 java-11-openjdk net-tools zip unzip tar sysstat chrony iftop iotop net-snmp net-snmp-utils network-scripts
    fi
fi
sleep 1


if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    echo "[5/12] 完全禁用 Cloud-Init.."
    sudo touch /etc/cloud/cloud-init.disabled
    sleep 1
fi

echo "[6/12] 优化其他杂项.."
sudo bash -c 'echo "* soft nofile 65535" >> /etc/security/limits.conf'
sudo bash -c 'echo "* hard nofile 65535" >> /etc/security/limits.conf'
sudo sed -i '/^#DefaultLimitNOFILE=/c\DefaultLimitNOFILE=65535' /etc/systemd/user.conf
sudo sed -i '/^#DefaultLimitNOFILE=/c\DefaultLimitNOFILE=65535' /etc/systemd/system.conf
sleep 1


echo "[7/12] 优化内核参数..."
cat <<EOF | sudo tee /etc/sysctl.d/99-custom.conf
# 启用TCP连接重用，加快TIME_WAIT释放
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15

# 增加文件句柄数上限
fs.file-max = 2097152

# 增加网络缓冲区
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# 防止SYN攻击
net.ipv4.tcp_syncookies = 1

# 禁止ICMP广播请求
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# 启用IP转发（如部署K8s或NAT用途）
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system
sleep 1


echo "[8/12] 系统服务与启动优化..."
sudo mkdir -p /etc/systemd/journald.conf.d
cat <<EOF | sudo tee /etc/systemd/journald.conf.d/00-custom.conf
[Journal]
SystemMaxUse=2000M
SystemMaxFileSize=500M
MaxRetentionSec=180day
Compress=yes
EOF
sudo systemctl restart systemd-journald

sudo timedatectl set-timezone Asia/Shanghai
sudo systemctl enable chronyd 2>/dev/null || true
sudo systemctl restart chronyd 2>/dev/null || true
sleep 1


echo "[9/12] 配置 chrony 使用阿里云 NTP 服务器..."
if [ -f /etc/chrony.conf ]; then
    sudo sed -i 's|^server .*|server ntp.aliyun.com iburst|' /etc/chrony.conf
elif [ -f /etc/chrony/chrony.conf ]; then
    sudo sed -i 's|^pool .*|server ntp.aliyun.com iburst|' /etc/chrony/chrony.conf
fi
sudo systemctl restart chronyd
sudo chronyc tracking
sudo chronyc sources
sudo chronyc -a makestep
sleep 1


# ====================== BBR逻辑分支 ======================
if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ] || [ "$OS" = "rocky" ]; then
    echo "[10/12] 启用 BBR 加速（TCP性能）..."
    sudo modprobe tcp_bbr 2>/dev/null || true
    echo "tcp_bbr" | sudo tee -a /etc/modules-load.d/modules.conf
    cat <<EOF | sudo tee /etc/sysctl.d/99-bbr.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sudo sysctl --system
else
    echo "[10/12] 麒麟系统检测到，不启用BBR。"
fi
sleep 1


echo "[11/12] 安装 fio 和 stress-ng（压力测试工具）..."
if [ "$OS" = "rocky" ]; then
    sudo dnf -y install fio stress-ng
elif [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    sudo apt install -y fio stress-ng
fi
sleep 1


echo "[12/12] 安装并配置 SNMP 服务..."
if [ "$OS" = "rocky" ]; then
    sudo dnf -y install net-snmp net-snmp-utils
elif [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    sudo apt install -y snmp snmpd
fi

# 备份原配置文件
sudo cp /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.bak 2>/dev/null

# 写入新配置
sudo cp /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.bak 2>/dev/null
cat <<EOF | sudo tee /etc/snmp/snmpd.conf
# 设置社区字符串（只读），只允许来自 10.53.201.101 的访问
rocommunity ztzbPublic 10.53.201.101
sysLocation IDC
sysContact ops@example.com
agentAddress udp:161
view    systemview    included   .1
EOF
sudo systemctl enable snmpd --now


#[12/12]扩容根分区到整个磁盘
if ! grep -Ei 'debian|ubuntu' /etc/*-release >/dev/null 2>&1; then
    # 非 Ubuntu/Debian 系统直接退出，且不输出任何信息
    exit 0
fi

# 以下代码仅在 Ubuntu/Debian 执行
echo "[INFO] 检测根分区挂载点..."
ROOT_DEV=$(df / | tail -1 | awk '{print $1}')

echo "[INFO] 根分区设备: $ROOT_DEV"

# 检查是否为 LVM
if [[ "$ROOT_DEV" != /dev/mapper/* ]]; then
    echo "[ERROR] 根分区不是 LVM，无法扩容。"
    exit 1
fi

echo "[INFO] 检测文件系统类型..."
FS_TYPE=$(df -Th / | tail -1 | awk '{print $2}')
echo "[INFO] 文件系统类型: $FS_TYPE"

echo "[INFO] 解析 LVM 设备路径..."
LV_PATH="$ROOT_DEV"

echo "[INFO] 扩容 LVM 到全部剩余空间..."
sudo lvextend -l +100%FREE "$LV_PATH"

# 根据文件系统类型选择扩容方式
if [[ "$FS_TYPE" == "ext4" ]]; then
    echo "[INFO] 检测到 ext4 文件系统，使用 resize2fs 扩容..."
    sudo resize2fs "$LV_PATH"
elif [[ "$FS_TYPE" == "xfs" ]]; then
    echo "[INFO] 检测到 xfs 文件系统，使用 xfs_growfs 扩容..."
    sudo xfs_growfs /
else
    echo "[ERROR] 不支持的文件系统类型：$FS_TYPE"
    exit 1
fi

echo "[SUCCESS] 根分区扩容完成！"