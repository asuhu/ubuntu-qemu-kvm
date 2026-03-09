#!/bin/bash
# =========================================
# Rocky安装KVM
# 作者：asuhu
# =========================================

set -e
set -o pipefail

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


[root@bjbj ~]# dnf update
[root@bjbj ~]# dnf install -y qemu-kvm libvirt virt-manager virt-install 
[root@bjbj ~]# dnf -y install virt-top libguestfs-tools libvirt-client virt-viewer
[root@bjbj ~]# systemctl enable libvirtd
[root@bjbj ~]# systemctl start libvirtd
[root@bjbj ~]# nmcli connection show
[root@bjbj ~]# nmcli connection add type bridge autoconnect yes con-name br0 ifname br0

[root@bjbj ~]# nmcli connection modify br0 \
ipv4.addresses 192.168.**.**/24 \
ipv4.gateway 192.168.**.1 \
ipv4.dns "223.5.5.5 223.5.5.6" \
ipv4.method manual

现在，将物理网卡 ens9f0 设置为网桥 br0 的从属（Slave），使其成为网桥的一部分。
[root@bjbj ~]# nmcli connection delete 9a7164fa-7d39-3e7c-92f3-88515395920e
[root@bjbj ~]# nmcli connection add type bridge-slave autoconnect yes con-name ens9f0 ifname ens9f0 master br0
3.4激活br0接口[root@bjbj ~]# nmcli connection up br0
查看：[root@bjbj ~]# nmcli connection show
NAME           UUID                                  TYPE      DEVICE        
br0            17d240e9-f9f3-4b73-b1b5-88ba7e4a4586  bridge    br0           
enp0s20f0u1u6  aeea3b0f-4e21-373b-8eb4-a04f70eaa771  ethernet  enp0s20f0u1u6 
ens9f0         9a7164fa-7d39-3e7c-92f3-88515395920e  ethernet  ens9f0        
lo             f9df6193-cbbc-44b2-9d41-1a7ea856cf1b  loopback  lo            
virbr0         8eb29437-4a2f-4d5a-bf13-fe4879552b1e  bridge    virbr0        
ens9f1         7f03d99f-5ad6-43c5-b1a8-453bbea7a0a2  ethernet  --            
ens9f2         16049f9d-c838-4f65-9530-1646feff3118  ethernet  --            
ens9f3         1bf79154-f9dd-454d-88c2-e9afc3e33296  ethernet  --            

安装Cockpit及虚拟机模块[root@bjbj ~]# dnf install -y cockpit cockpit-machines
4.2启动Cockpit服务[root@bjbj ~]# systemctl enable --now cockpit.socket
[root@bjbj ~]# systemctl status cockpit.socket
4.3登录WEB管理界面用户名和密码为系统用户名和密码，https://ip:9090